#!/usr/bin/env bash
# Exercises the merge-push strategy gate of mol-refinery-patrol.
#
# The formula's guardrails are prose plus shell, and prose does not fail a
# build. These tests run the shell blocks EXTRACTED FROM THE FORMULA ITSELF --
# never a copy -- so the assertions cannot pass while the formula drifts.
#
# What is nailed down here:
#   1. A protected target never resolves to `direct`, whichever way protection
#      is observed, and an explicit metadata.merge_strategy=direct is upgraded.
#   2. The second, independent guard in the direct script physically refuses to
#      push to a protected branch -- proven against a real git remote, where
#      the push WOULD otherwise succeed.
#   3. Red / timed-out / never-scheduled required checks block the bead and
#      return it to the pool without pushing, merging, or closing.
#   4. Green checks still proceed, so the gate is precise rather than a
#      blanket refusal.
#   5. A squash-merged MULTI-commit PR closes -- the case the git-side patch-id
#      predicate is blind to, where GitHub's `mergedAt` is the only evidence --
#      and a gh query that gh REJECTS is loud rather than silently downgraded
#      to "no API". The field names themselves are pinned against the real gh
#      binary in test_gh_json_fields.sh; a fixture cannot catch a rename.
#   6. Protection is probed against the repo the refinery PUSHES TO -- origin --
#      and not against whatever `gh repo view` calls the current repo. On a fork
#      those differ: gh reports the PARENT, so a protected upstream silently
#      turned an unprotected origin into pr-merge and then had the direct path
#      refuse the push too. The fixture makes the two repos disagree, so a probe
#      that reads the wrong one gets the wrong verdict rather than the right one
#      by luck.
#   7. The awaiting_merge park/skip contract, INCLUDING the stored value's type.
#      `--set-metadata awaiting_merge=true` stores a JSON boolean, and a
#      type-strict jq compare against the string "true" silently kept the parked
#      bead -- livelocking the queue and force-pushing over a published PR. The
#      fixtures here therefore carry the real types, and one test parks through
#      the real `gc bd` writer so no assertion rests on a believed type.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
FORMULA="$ROOT/gastown/formulas/mol-refinery-patrol.toml"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# Emit the single fenced bash block of STEP that contains ANCHOR, with
# {{vars}} rendered from the formula's own defaults the way the formula engine
# would render them.
#
# Requiring EXACTLY one match is deliberate: if the step is reorganised and an
# anchor goes missing or turns ambiguous, the test dies loudly instead of
# quietly exercising nothing.
extract_step_block() {
    python3 - "$FORMULA" "$1" "$2" <<'PY'
import re
import sys
import tomllib

formula, step_id, anchor = sys.argv[1], sys.argv[2], sys.argv[3]
with open(formula, "rb") as handle:
    data = tomllib.load(handle)

step = next(s for s in data["steps"] if s["id"] == step_id)
blocks = [
    b for b in re.findall(r"```bash\n(.*?)```", step["description"], re.S)
    if anchor in b
]
if len(blocks) != 1:
    sys.exit(
        f"expected exactly 1 {step_id} bash block containing {anchor!r}, "
        f"found {len(blocks)}"
    )

rendered = blocks[0]
values = {name: spec.get("default", "") for name, spec in data.get("vars", {}).items()}
values.setdefault("rig_name", "testrig")
for name, value in values.items():
    rendered = rendered.replace("{{%s}}" % name, str(value))
sys.stdout.write(rendered)
PY
}

# Most blocks under test live in merge-push; keep the short spelling for them.
extract_block() {
    extract_step_block merge-push "$1"
}

# `gc` stub: reads bead JSON from a file, records every mutation as one line in
# $GC_LOG so tests can assert on what the formula did (and did not) write.
# Dispatch and log lines are both spelled as the full `gc bd ...` command, so
# assertions below match the same string the stub writes.
#
# `gc bd list` is served from two files so one sandbox can answer both queries
# the find-work step makes, told apart by the awaiting_merge filter:
#   GC_LIST_AWAITING  the --metadata-field=awaiting_merge=true query
#   GC_LIST_WORK      the --has-metadata-key=branch work-selection query
# Both default to an empty array rather than empty output -- `jq` errors on an
# empty stdin, and a test must not pass because jq died.
write_gc_stub() {
    cat >"$1/gc" <<'SH'
#!/usr/bin/env sh
case "gc $1 $2" in
    "gc bd show")
        cat "$GC_BEAD_JSON"
        exit 0
        ;;
    "gc bd list")
        case "$*" in
            *awaiting_merge=true*)
                if [ -n "${GC_LIST_AWAITING:-}" ]; then cat "$GC_LIST_AWAITING"; else printf '[]\n'; fi
                ;;
            *)
                if [ -n "${GC_LIST_WORK:-}" ]; then cat "$GC_LIST_WORK"; else printf '[]\n'; fi
                ;;
        esac
        exit 0
        ;;
esac
printf 'gc %s\n' "$*" >>"$GC_LOG"
exit 0
SH
    chmod +x "$1/gc"
}

# `gh` stub. Protection is served from two env vars so a test can reproduce the
# non-admin case exactly: /protection 404s while /branches/<t> still reports
# .protected == true.
#
#   GH_PROTECTION_JSON  body for repos/*/branches/*/protection; unset => 404
#   GH_PROTECTED_FLAG   .protected for repos/*/branches/*; unset => failure
#   GH_REPO             what `gh repo view` claims the current repo is. On a
#                       fork that is the PARENT, not origin -- which is why
#                       nothing may resolve repo IDENTITY through it.
#   GH_FORK_PARENT      repo that answers with the GH_PARENT_* values below
#                       instead of the GH_PROTEC* ones; unset => no such repo
#   GH_PARENT_PROTECTION_JSON  /protection body for GH_FORK_PARENT; unset => 404
#   GH_PARENT_PROTECTED_FLAG   .protected for GH_FORK_PARENT; unset => failure
#   GH_WATCH_EXIT       exit status of `gh pr checks --watch`
#   GH_CHECKS_JSON      stdout of `gh pr checks --json ...`
#   GH_CHECKS_ERR       stderr of the same
#   GH_CHECKS_EXIT      its exit status
#   GH_PR_VIEW_JSON     stdout of `gh pr view --json state,mergedAt,...`;
#                       unset => the command answers nothing, which is how a
#                       test reaches the git-side merge_landed fallback
#   GH_PR_VIEW_ERR      stderr of `gh pr view`, with a nonzero exit. This is the
#                       "gh is installed and REJECTED the query" case, which is
#                       NOT the same as "gh is absent" and must not be silent.
#   GH_PR_VIEW_EXIT     exit status paired with GH_PR_VIEW_ERR (default 1)
write_gh_stub() {
    cat >"$1/gh" <<'SH'
#!/usr/bin/env sh
printf 'gh %s\n' "$*" >>"$GC_LOG"
case "$1" in
    repo)
        printf '%s\n' "${GH_REPO:-acme/widgets}"
        exit 0
        ;;
    api)
        # The fork parent, when a test declares one, answers DIFFERENTLY from
        # every other repo. That asymmetry is the whole point: it is what makes
        # "which repo did the probe ask about?" observable in the verdict itself,
        # so a probe pointed at the parent cannot reach the right answer by luck.
        if [ -n "${GH_FORK_PARENT:-}" ]; then
            case "$2" in
                "repos/$GH_FORK_PARENT/"*/protection)
                    [ -n "${GH_PARENT_PROTECTION_JSON:-}" ] || exit 1
                    printf '%s\n' "$GH_PARENT_PROTECTION_JSON"
                    exit 0
                    ;;
                "repos/$GH_FORK_PARENT/"*)
                    [ -n "${GH_PARENT_PROTECTED_FLAG:-}" ] || exit 1
                    printf '%s\n' "$GH_PARENT_PROTECTED_FLAG"
                    exit 0
                    ;;
            esac
        fi
        case "$2" in
            */protection)
                [ -n "${GH_PROTECTION_JSON:-}" ] || exit 1
                printf '%s\n' "$GH_PROTECTION_JSON"
                exit 0
                ;;
            *)
                [ -n "${GH_PROTECTED_FLAG:-}" ] || exit 1
                printf '%s\n' "$GH_PROTECTED_FLAG"
                exit 0
                ;;
        esac
        ;;
    pr)
        case "$2" in
            view)
                if [ -n "${GH_PR_VIEW_ERR:-}" ]; then
                    printf '%s\n' "$GH_PR_VIEW_ERR" >&2
                    exit "${GH_PR_VIEW_EXIT:-1}"
                fi
                [ -n "${GH_PR_VIEW_JSON:-}" ] || exit 1
                printf '%s\n' "$GH_PR_VIEW_JSON"
                exit 0
                ;;
            checks)
                case "$*" in
                    *--watch*) exit "${GH_WATCH_EXIT:-0}" ;;
                    *)
                        [ -n "${GH_CHECKS_JSON:-}" ] && printf '%s\n' "$GH_CHECKS_JSON"
                        [ -n "${GH_CHECKS_ERR:-}" ] && printf '%s\n' "$GH_CHECKS_ERR" >&2
                        exit "${GH_CHECKS_EXIT:-0}"
                        ;;
                esac
                ;;
        esac
        ;;
esac
exit 0
SH
    chmod +x "$1/gh"
}

# Fresh sandbox: stub bin on PATH, a bead whose metadata the test can shape,
# an empty mutation log, and a git repo whose `origin` is the repo under test.
# $1 overrides the origin URL (default: the ordinary non-fork case).
#
# That repo is load-bearing, not scenery. The formula resolves ORIGIN_REPO with
# `git remote get-url origin`, so a block run anywhere else would read the
# remote of whatever checkout the suite happens to be invoked from -- passing or
# failing on the contributor's own fork rather than on the formula. Every test
# that runs a block touching ORIGIN_REPO runs it inside $SANDBOX_REPO.
new_sandbox() {
    SANDBOX=$(mktemp -d)
    BIN="$SANDBOX/bin"
    mkdir -p "$BIN"
    write_gc_stub "$BIN"
    write_gh_stub "$BIN"
    GC_LOG="$SANDBOX/gc.log"
    : >"$GC_LOG"
    GC_BEAD_JSON="$SANDBOX/bead.json"
    SANDBOX_REPO="$SANDBOX/repo"
    mkdir -p "$SANDBOX_REPO"
    git -C "$SANDBOX_REPO" init -q >/dev/null 2>&1
    git -C "$SANDBOX_REPO" remote add origin \
        "${1:-https://github.com/acme/widgets.git}"
    # Pin the rig so assertions do not depend on the ambient GC_RIG of whoever
    # runs the suite.
    GC_RIG=testrig
    export GC_LOG GC_BEAD_JSON GC_RIG
    # Unset per-scenario knobs so a previous test cannot leak into the next.
    unset GH_PROTECTION_JSON GH_PROTECTED_FLAG GH_WATCH_EXIT \
        GH_CHECKS_JSON GH_CHECKS_ERR GH_CHECKS_EXIT GH_PR_VIEW_JSON \
        GH_PR_VIEW_ERR GH_PR_VIEW_EXIT GC_LIST_AWAITING GC_LIST_WORK \
        GH_REPO GH_FORK_PARENT GH_PARENT_PROTECTION_JSON GH_PARENT_PROTECTED_FLAG
}

# Bead with the given merge_strategy ("" = unset, i.e. let the formula decide).
write_bead() {
    strategy_field=""
    [ -n "$1" ] && strategy_field=",\"merge_strategy\":\"$1\""
    cat >"$GC_BEAD_JSON" <<JSON
[{"id":"bd-1","title":"Fix the thing",
  "metadata":{"branch":"polecat/bd-1","target":"main"$strategy_field}}]
JSON
}

# Run the strategy-resolution block and report what it decided. Runs inside the
# sandbox repo because the block resolves ORIGIN_REPO from origin.
resolve_strategy() {
    extract_block 'probe_target_protection "$TARGET"' >"$SANDBOX/resolve.sh"
    (cd "$SANDBOX_REPO" && PATH="$BIN:$PATH" WORK=bd-1 bash -c \
        'set -u; . "$1/resolve.sh"; printf "strategy=%s protected=%s pr_mode=%s repo=%s\n" \
            "$MERGE_STRATEGY" "$TARGET_PROTECTED" "$PR_MODE" "$ORIGIN_REPO"' \
        _ "$SANDBOX")
}

test_protected_target_never_resolves_to_direct() {
    # (a) Protection readable: the ordinary admin-token case.
    new_sandbox
    write_bead ""
    export GH_PROTECTION_JSON='{"required_status_checks":{"contexts":["build"]}}'
    export GH_PROTECTED_FLAG=true
    result=$(resolve_strategy)
    case "$result" in
        *"strategy=pr-merge"*"protected=true"*"pr_mode=true"*) : ;;
        *) fail "protected target should default to pr-merge, got: $result" ;;
    esac

    # (b) The non-admin case that a naive probe gets backwards: /protection
    # 404s, yet the branch IS protected. A 404 must never read as unprotected.
    new_sandbox
    write_bead ""
    unset GH_PROTECTION_JSON
    export GH_PROTECTED_FLAG=true
    result=$(resolve_strategy)
    case "$result" in
        *"strategy=pr-merge"*"protected=true"*) : ;;
        *) fail "404 on /protection with .protected=true must still be protected, got: $result" ;;
    esac

    # (c) An explicit, stale metadata.merge_strategy=direct is upgraded rather
    # than obeyed -- it has no legal route to a protected branch.
    new_sandbox
    write_bead direct
    export GH_PROTECTION_JSON='{"required_status_checks":{"contexts":["build"]}}'
    export GH_PROTECTED_FLAG=true
    result=$(resolve_strategy)
    case "$result" in
        *"strategy=pr-merge"*) : ;;
        *) fail "metadata merge_strategy=direct must be upgraded on a protected target, got: $result" ;;
    esac

    # (d) Protection unreadable while gh works => fail closed to pr-merge.
    new_sandbox
    write_bead ""
    unset GH_PROTECTION_JSON GH_PROTECTED_FLAG
    result=$(resolve_strategy)
    case "$result" in
        *"strategy=pr-merge"*"protected=unknown"*) : ;;
        *) fail "unreadable protection must fail closed to pr-merge, got: $result" ;;
    esac
}

test_unprotected_target_keeps_direct() {
    # The gate has to stay precise: an unprotected branch keeps the cheap path.
    new_sandbox
    write_bead ""
    unset GH_PROTECTION_JSON
    export GH_PROTECTED_FLAG=false
    result=$(resolve_strategy)
    case "$result" in
        *"strategy=direct"*"protected=false"*"pr_mode=false"*) : ;;
        *) fail "unprotected target should stay direct, got: $result" ;;
    esac
}

test_protection_is_probed_against_origin_not_the_fork_parent() {
    # Measured on rig gascity-packs: origin is outdoorsea/gascity-packs (a fork,
    # and the only repo this refinery ever pushes to) while `gh repo view`
    # reports gastownhall/gascity-packs, whose main IS protected. Resolving
    # identity through gh therefore probed a branch in a repo the refinery never
    # writes to, and the wrong answer was silent in three places at once:
    # merge_strategy flipped to pr-merge, the direct path's own guard refused
    # the push it was about to make, and any PR opened was scoped to the wrong
    # repository. A refinery following the formula literally could not land work.
    #
    # The two repos disagree here on purpose. A probe that reads the parent gets
    # protected=true and resolves pr-merge, so this test fails against the
    # gh-resolved identity rather than passing on it by coincidence.
    new_sandbox https://github.com/outdoorsea/gascity-packs.git
    write_bead ""
    export GH_REPO=gastownhall/gascity-packs
    export GH_FORK_PARENT=gastownhall/gascity-packs
    # Faithful to the measured asymmetry: the parent 404s on /protection for a
    # non-admin token yet reports .protected=true, while the fork genuinely is
    # unprotected. Both arrive as a 404 on /protection -- only the repo differs.
    export GH_PARENT_PROTECTED_FLAG=true
    export GH_PROTECTED_FLAG=false

    result=$(resolve_strategy)
    case "$result" in
        *"strategy=direct"*"protected=false"*"repo=outdoorsea/gascity-packs"*) : ;;
        *) fail "protection must be read from origin, the push target, not the fork parent, got: $result" ;;
    esac

    # Behaviour pinned above; this pins the mechanism, so a future rewrite that
    # reaches the right verdict by some other route still cannot start probing
    # the wrong repository.
    grep -q "gh api repos/outdoorsea/gascity-packs/branches/main" "$GC_LOG" ||
        fail "the protection probe must name origin, log: $(cat "$GC_LOG")"
    ! grep -q "gastownhall/gascity-packs" "$GC_LOG" ||
        fail "no API call may name the fork parent, log: $(cat "$GC_LOG")"
    # gh stays available for API calls; what it must never do again is answer
    # the question "which repo is this?".
    ! grep -q "^gh repo" "$GC_LOG" ||
        fail "repo identity must come from git remote, not gh repo view, log: $(cat "$GC_LOG")"
}

test_non_github_origin_is_reported_rather_than_guessed() {
    # The REST fallback hardcodes api.github.com and every PR-URL parser in this
    # step matches on github.com, so a non-github origin has nowhere to go. It
    # has to surface as a NAMED error and a hard stop -- an unresolved origin
    # that merely failed closed to pr-merge would be indistinguishable from a
    # transient API problem, and would retry against nothing forever.
    new_sandbox https://gitlab.com/acme/widgets.git
    write_bead ""
    export GH_PROTECTED_FLAG=false

    status=0
    result=$(resolve_strategy) || status=$?
    [ "$status" -ne 0 ] ||
        fail "an unusable origin must stop, not proceed, got: $result"
    case "$result" in
        *"Only github.com origin remotes are supported"*"gitlab.com/acme/widgets"*) : ;;
        *) fail "the stop must name the origin it could not use, got: $result" ;;
    esac
    # No probe fired, and -- the load-bearing half -- no bead state was touched
    # on the way out.
    ! grep -q "gh api" "$GC_LOG" ||
        fail "an unresolved origin must not be probed, log: $(cat "$GC_LOG")"
    ! grep -q "gc bd" "$GC_LOG" ||
        fail "an unresolved origin must not mutate the bead, log: $(cat "$GC_LOG")"
}

# A PATH on which gh genuinely does not exist. Deleting the stub is not enough
# -- a real gh lives in /opt/homebrew/bin on macOS and /usr/bin on CI -- so
# build an allow-list of just the tools the block needs and nothing else.
make_gh_free_path() {
    ghfree="$SANDBOX/nogh"
    mkdir -p "$ghfree"
    cp "$BIN/gc" "$ghfree/gc"
    for tool in bash sh env jq git sed tr grep head cat mktemp rm printf; do
        resolved=$(command -v "$tool" 2>/dev/null) || continue
        ln -sf "$resolved" "$ghfree/$tool"
    done
    ! command -v gh >/dev/null 2>&1 || [ ! -x "$ghfree/gh" ] ||
        fail "gh-free PATH still contains gh"
    printf '%s' "$ghfree"
}

test_missing_gh_preserves_legacy_direct_default() {
    # pr-merge needs `gh pr checks` / `gh pr merge`. With no gh at all,
    # promoting to pr-merge would trade a clean push rejection for a broken PR
    # flow, so the historical default stands.
    new_sandbox
    write_bead ""
    ghfree=$(make_gh_free_path)
    extract_block 'probe_target_protection "$TARGET"' >"$SANDBOX/resolve.sh"
    result=$(cd "$SANDBOX_REPO" && PATH="$ghfree" WORK=bd-1 bash -c \
        'set -u; . "$1/resolve.sh"; printf "strategy=%s protected=%s repo=%s\n" \
            "$MERGE_STRATEGY" "$TARGET_PROTECTED" "$ORIGIN_REPO"' _ "$SANDBOX")
    case "$result" in
        *"strategy=direct"*"protected=unknown_no_gh"*) : ;;
        *) fail "absent gh should keep the legacy direct default, got: $result" ;;
    esac

    # Identity still resolves with gh gone, because it never came from gh. This
    # used to be a separate no-gh-only fallback; the gh and no-gh paths can no
    # longer disagree about which repo they mean, because there is only one path.
    case "$result" in
        *"repo=acme/widgets"*) : ;;
        *) fail "origin repo must resolve from git with no gh present, got: $result" ;;
    esac
}

# Build a real repo + bare origin so the direct-push block runs against genuine
# refs. The push would SUCCEED here if the guard let it through, which is what
# makes the refusal assertion non-vacuous.
setup_direct_repo() {
    ORIGIN="$SANDBOX/origin.git"
    REPO="$SANDBOX/work"
    git init -q --bare "$ORIGIN"
    git init -q "$REPO"
    git -C "$REPO" config user.email t@example.com
    git -C "$REPO" config user.name Tester
    git -C "$REPO" remote add origin "$ORIGIN"
    echo base >"$REPO/file.txt"
    git -C "$REPO" add file.txt
    git -C "$REPO" commit -qm base
    git -C "$REPO" branch -M main
    git -C "$REPO" push -q origin main
    git -C "$REPO" checkout -q -b temp
    echo work >>"$REPO/file.txt"
    git -C "$REPO" commit -qam work
    ORIGIN_MAIN_BEFORE=$(git -C "$ORIGIN" rev-parse main)
}

run_direct_block() {
    extract_block 'REFUSING direct push' >"$SANDBOX/direct.sh"
    (cd "$REPO" && PATH="$BIN:$PATH" WORK=bd-1 TARGET=main ORIGIN_REPO=acme/widgets \
        bash "$SANDBOX/direct.sh" >"$SANDBOX/direct.out" 2>&1)
}

test_direct_push_guard_refuses_protected_target() {
    new_sandbox
    write_bead direct
    setup_direct_repo
    export GH_PROTECTED_FLAG=true

    status=0
    run_direct_block || status=$?
    [ "$status" -ne 0 ] || fail "direct push to a protected target must exit non-zero"

    grep -q "REFUSING direct push" "$SANDBOX/direct.out" ||
        fail "expected an explicit refusal, got: $(cat "$SANDBOX/direct.out")"

    # The load-bearing assertion: the protected branch did not move.
    after=$(git -C "$ORIGIN" rev-parse main)
    [ "$after" = "$ORIGIN_MAIN_BEFORE" ] ||
        fail "protected main advanced ($ORIGIN_MAIN_BEFORE -> $after); the guard did not hold"

    ! grep -q "gc bd close" "$GC_LOG" || fail "a refused push must not close the bead"
    ! grep -q "merge_result=merged" "$GC_LOG" || fail "a refused push must not record a merge"
}

test_direct_push_still_lands_on_unprotected_target() {
    # Control for the test above: same code path, protection off, work lands.
    # Without this, an always-refusing guard would look correct.
    new_sandbox
    write_bead direct
    setup_direct_repo
    export GH_PROTECTED_FLAG=false

    run_direct_block || fail "unprotected direct push should succeed: $(cat "$SANDBOX/direct.out")"

    after=$(git -C "$ORIGIN" rev-parse main)
    [ "$after" != "$ORIGIN_MAIN_BEFORE" ] || fail "unprotected main should have advanced"
    grep -q "merge_result=merged" "$GC_LOG" || fail "a verified push should record merge_result=merged"
    grep -q "gc bd close" "$GC_LOG" || fail "a verified push should close the bead"
}

# Resolve strategy (to populate REQUIRED_CONTEXTS and define block_pr_checks),
# then run the 4a checks-verdict block on top of it -- composed exactly as the
# agent runs them.
run_checks_block() {
    extract_block 'probe_target_protection "$TARGET"' >"$SANDBOX/resolve.sh"
    extract_block 'CHECKS_VERDICT' >"$SANDBOX/checks.sh"
    (cd "$SANDBOX_REPO" && PATH="$BIN:$PATH" WORK=bd-1 PR_NUMBER=42 \
        PR_URL=https://github.com/acme/widgets/pull/42 \
        bash -c 'set -u; . "$1/resolve.sh"; . "$1/checks.sh"' _ "$SANDBOX") \
        >"$SANDBOX/checks.out" 2>&1
}

# Every blocked verdict owes the same contract: bead reopened and returned to
# the pool with a reason, and nothing merged, closed, or pushed.
assert_blocked_with_reason() {
    grep -q "merge_result=blocked" "$GC_LOG" || fail "$1: expected merge_result=blocked"
    grep -q "rejection_reason=" "$GC_LOG" ||
        fail "$1: blocked bead must carry a rejection_reason, log: $(cat "$GC_LOG")"
    grep -q "$2" "$GC_LOG" ||
        fail "$1: expected the reason to mention '$2', log: $(cat "$GC_LOG")"
    grep -q -- "--status=open" "$GC_LOG" || fail "$1: blocked bead must be reopened"
    grep -q "gc.routed_to=.*polecat" "$GC_LOG" || fail "$1: blocked bead must return to the polecat pool"
    ! grep -q "gc bd close" "$GC_LOG" || fail "$1: a blocked bead must never be closed"
    ! grep -q "pr merge" "$GC_LOG" || fail "$1: a blocked PR must never be merged"
}

test_red_required_checks_block_and_return_bead_to_pool() {
    new_sandbox
    write_bead ""
    export GH_PROTECTION_JSON='{"required_status_checks":{"contexts":["build","lint"]}}'
    export GH_PROTECTED_FLAG=true
    # gh exits 1 for red -- the same status it uses for "no checks reported".
    # The failing rows on stdout are what separate the two.
    export GH_WATCH_EXIT=1
    export GH_CHECKS_EXIT=1
    export GH_CHECKS_JSON='[{"name":"build","state":"FAILURE","bucket":"fail","link":"x"},
                            {"name":"lint","state":"SUCCESS","bucket":"pass","link":"y"}]'

    run_checks_block
    grep -q "verdict=red" "$SANDBOX/checks.out" ||
        fail "failing checks should read as red, got: $(cat "$SANDBOX/checks.out")"
    # The failing check is named, so the next polecat knows what to fix.
    assert_blocked_with_reason "red" "required checks failing: build"
}

test_timed_out_checks_block_without_retry() {
    new_sandbox
    write_bead ""
    export GH_PROTECTION_JSON='{"required_status_checks":{"contexts":["build"]}}'
    export GH_PROTECTED_FLAG=true
    export GH_WATCH_EXIT=124
    export GH_CHECKS_EXIT=8
    export GH_CHECKS_JSON='[{"name":"build","state":"PENDING","bucket":"pending","link":"x"}]'

    run_checks_block
    grep -q "verdict=timeout" "$SANDBOX/checks.out" ||
        fail "a fired timeout should read as timeout, got: $(cat "$SANDBOX/checks.out")"
    assert_blocked_with_reason "timeout" "required checks did not finish"
}

test_required_checks_never_scheduled_block() {
    # The subtle one: gh reports nothing, but protection demands contexts.
    # Believing gh here would merge past a gate that was never enforced.
    new_sandbox
    write_bead ""
    export GH_PROTECTION_JSON='{"required_status_checks":{"checks":[{"context":"build"}]}}'
    export GH_PROTECTED_FLAG=true
    export GH_WATCH_EXIT=1
    export GH_CHECKS_EXIT=1
    export GH_CHECKS_JSON=''
    export GH_CHECKS_ERR='no required checks reported on the '"'"'polecat/bd-1'"'"' branch'

    run_checks_block
    grep -q "verdict=unscheduled" "$SANDBOX/checks.out" ||
        fail "protection-required-but-unreported checks should read as unscheduled, got: $(cat "$SANDBOX/checks.out")"
    assert_blocked_with_reason "unscheduled" "never reported"
}

test_green_required_checks_proceed_to_merge() {
    new_sandbox
    write_bead ""
    export GH_PROTECTION_JSON='{"required_status_checks":{"contexts":["build"]}}'
    export GH_PROTECTED_FLAG=true
    export GH_WATCH_EXIT=0
    export GH_CHECKS_EXIT=0
    export GH_CHECKS_JSON='[{"name":"build","state":"SUCCESS","bucket":"pass","link":"x"}]'

    run_checks_block
    grep -q "verdict=green" "$SANDBOX/checks.out" ||
        fail "passing checks should read as green, got: $(cat "$SANDBOX/checks.out")"
    grep -q "PROCEED" "$SANDBOX/checks.out" || fail "green checks should proceed to the merge"
    ! grep -q "merge_result=blocked" "$GC_LOG" || fail "green checks must not block the bead"
}

test_no_required_checks_anywhere_proceeds() {
    # Nothing reported AND protection lists no required contexts: there is
    # genuinely nothing to wait on, so waiting forever would be the bug.
    new_sandbox
    write_bead ""
    export GH_PROTECTION_JSON='{"required_status_checks":{"contexts":[]}}'
    export GH_PROTECTED_FLAG=true
    export GH_WATCH_EXIT=1
    export GH_CHECKS_EXIT=1
    export GH_CHECKS_JSON=''
    export GH_CHECKS_ERR='no required checks reported'

    run_checks_block
    grep -q "verdict=none" "$SANDBOX/checks.out" ||
        fail "no checks anywhere should read as none, got: $(cat "$SANDBOX/checks.out")"
    ! grep -q "merge_result=blocked" "$GC_LOG" || fail "an empty required set must not block"
}

# ---------------------------------------------------------------------------
# `mr` mode: a published PR parks the bead, it does not complete it.
#
# The bug these lock down: `mr` used to close the work bead the moment the PR
# verified as OPEN. A closed bead leaves `gc bd ready`, pool-demand queries and
# orphan scans in the same instant, so a green PR nobody merged had no open
# bead, no assignee and no sling -- nothing re-dispatched it and nothing merged
# it. Three PRs stranded that way in one day; measured against the GitHub API,
# beads closed 40-78 minutes before their PR merged, and one never merged.
# ---------------------------------------------------------------------------

# An `mr` bead already parked at awaiting_merge, as find-work will find it.
# since_epoch/stale shape the staleness arithmetic; fork is the recorded fork
# point the git-side predicate needs to tell "landed" from "empty branch".
#
# The JSON types here mirror what `--set-metadata` actually stores, which is NOT
# all strings: `awaiting_merge=true` and `awaiting_merge_stale=true` land as
# booleans, `pr_number=42` and `awaiting_merge_since_epoch=<epoch>` as numbers.
# Keeping the fixture faithful is the point -- a stringified copy is what let a
# type-strict jq compare on awaiting_merge pass here while the merge queue
# livelocked in production. The recheck block survives the real types because it
# lifts them out with `jq -r`, which renders a boolean as the bare text `true`
# and a number as its digits before any shell test or arithmetic sees them; this
# fixture is what proves that rather than assuming it.
write_awaiting_bead() {
    aw_since="$1"
    aw_stale_field=""
    [ -n "${2:-}" ] && aw_stale_field=",\"awaiting_merge_stale\":$2"
    aw_fork_field=""
    [ -n "${3:-}" ] && aw_fork_field=",\"fork_sha\":\"$3\""
    cat >"$GC_BEAD_JSON" <<JSON
[{"id":"bd-1","title":"Fix the thing",
  "metadata":{"branch":"polecat/bd-1","target":"main","merge_strategy":"mr",
    "awaiting_merge":true,"pr_number":42,
    "pr_url":"https://github.com/acme/widgets/pull/42",
    "awaiting_merge_since_epoch":$aw_since$aw_stale_field$aw_fork_field}}]
JSON
    GC_LIST_AWAITING="$SANDBOX/awaiting.json"
    printf '[{"id":"bd-1"}]\n' >"$GC_LIST_AWAITING"
    export GC_LIST_AWAITING
}

# Run the find-work re-check. Optional $1 = directory to run it in, so a test
# can point it at a real git repo for the content-aware fallback.
run_recheck_block() {
    extract_step_block find-work 'AWAITING_MERGE_RECHECK' >"$SANDBOX/recheck.sh"
    (cd "${1:-$SANDBOX}" && PATH="$BIN:$PATH" GC_AGENT=testrig/refinery \
        bash "$SANDBOX/recheck.sh" >"$SANDBOX/recheck.out" 2>&1)
}

assert_not_closed() {
    ! grep -q "gc bd close" "$GC_LOG" ||
        fail "$1: an unmerged PR must never close the bead, log: $(cat "$GC_LOG")"
    ! grep -q "merge_result=merged" "$GC_LOG" ||
        fail "$1: an unmerged PR must never record a merge, log: $(cat "$GC_LOG")"
}

test_mr_parks_bead_open_instead_of_closing_on_pr_open() {
    # The headline regression. Publishing the PR is the whole of `mr`'s work,
    # and it must still leave an OPEN, findable bead behind.
    new_sandbox
    write_bead mr
    extract_block 'AWAITING_MERGE_PARK' >"$SANDBOX/park.sh"
    PATH="$BIN:$PATH" WORK=bd-1 TARGET=main PR_NUMBER=42 \
        PR_URL=https://github.com/acme/widgets/pull/42 \
        bash "$SANDBOX/park.sh" >"$SANDBOX/park.out" 2>&1 ||
        fail "parking an mr bead should succeed: $(cat "$SANDBOX/park.out")"

    assert_not_closed "mr park"
    grep -q "awaiting_merge=true" "$GC_LOG" ||
        fail "a published PR must park the bead at awaiting_merge, log: $(cat "$GC_LOG")"
    grep -q -- "--status=open" "$GC_LOG" ||
        fail "the parked bead must stay open so gc bd ready and patrols still see it"
    grep -q "pr_url=https://github.com/acme/widgets/pull/42" "$GC_LOG" ||
        fail "the parked bead must carry the PR URL as its tracking handle"
    # Staleness arithmetic needs an epoch: parsing RFC3339 back to epoch needs
    # date -d on GNU and date -j -f on BSD, and the refinery runs on both.
    grep -qE "awaiting_merge_since_epoch=[0-9]+" "$GC_LOG" ||
        fail "the parked bead must record a machine-comparable epoch, log: $(cat "$GC_LOG")"
}

test_recheck_closes_bead_once_github_reports_merged() {
    # The other half of the contract: the poll must actually close landed work,
    # or "never close early" would just become "never close".
    new_sandbox
    write_awaiting_bead "$(date -u +%s)"
    # Shape copied from real gh: `mergeCommit` is an object, not a flat sha.
    export GH_PR_VIEW_JSON='{"state":"MERGED","mergedAt":"2026-07-28T21:42:50Z","mergeCommit":{"oid":"abc123def456"}}'

    run_recheck_block
    grep -q "gc bd close" "$GC_LOG" ||
        fail "a merged PR must close its bead, log: $(cat "$GC_LOG")"
    grep -q "merge_result=merged" "$GC_LOG" ||
        fail "a merged PR must record merge_result=merged"
    grep -q "merged_sha=abc123def456" "$GC_LOG" ||
        fail "the close must carry the merge commit as forensics, log: $(cat "$GC_LOG")"
    grep -q -- "--unset-metadata awaiting_merge" "$GC_LOG" ||
        fail "closing must clear awaiting_merge so the bead stops being polled"
}

test_recheck_leaves_unmerged_pr_open() {
    # mergedAt null is a real verdict, not a missing answer: leave it alone.
    new_sandbox
    write_awaiting_bead "$(date -u +%s)"
    export GH_PR_VIEW_JSON='{"state":"OPEN","mergedAt":null,"mergeCommit":null}'

    run_recheck_block
    assert_not_closed "unmerged"
    grep -q "still unmerged" "$SANDBOX/recheck.out" ||
        fail "an unmerged PR should be reported as left open, got: $(cat "$SANDBOX/recheck.out")"
    ! grep -q "awaiting_merge_stale=true" "$GC_LOG" ||
        fail "a PR published seconds ago must not escalate as stale"
}

# A repo where the branch's work LANDED as a rebase: the same patch sits on
# main under a different SHA, so the branch tip is not an ancestor of main.
# This is the shape the refinery itself creates -- it rebases before publishing
# -- and the shape that SHA ancestry gets wrong.
setup_rebased_landing_repo() {
    ORIGIN="$SANDBOX/origin.git"
    REPO="$SANDBOX/rebased"
    git init -q --bare "$ORIGIN"
    git init -q "$REPO"
    git -C "$REPO" config user.email t@example.com
    git -C "$REPO" config user.name Tester
    git -C "$REPO" remote add origin "$ORIGIN"
    echo base >"$REPO/file.txt"
    git -C "$REPO" add file.txt
    git -C "$REPO" commit -qm base
    git -C "$REPO" branch -M main
    git -C "$REPO" push -q origin main
    FORK_SHA=$(git -C "$REPO" rev-parse main)

    git -C "$REPO" checkout -q -b polecat/bd-1
    echo work >"$REPO/feature.txt"
    git -C "$REPO" add feature.txt
    git -C "$REPO" commit -qm "the work"
    git -C "$REPO" push -q origin polecat/bd-1

    # main moves on, then takes the same patch under a new SHA.
    git -C "$REPO" checkout -q main
    echo other >"$REPO/other.txt"
    git -C "$REPO" add other.txt
    git -C "$REPO" commit -qm "unrelated"
    git -C "$REPO" cherry-pick polecat/bd-1 >/dev/null
    git -C "$REPO" push -q origin main
    git -C "$REPO" fetch -q origin
}

test_recheck_detects_rebased_landing_without_github() {
    # With no answer from the API, the git fallback has to be content-aware.
    new_sandbox
    setup_rebased_landing_repo
    write_awaiting_bead "$(date -u +%s)" "" "$FORK_SHA"
    unset GH_PR_VIEW_JSON   # gh answers nothing => fall through to git

    # Non-vacuity: the check the formula must NOT rely on says "not merged"
    # for this branch. Without this assertion the test could pass on ancestry.
    ! git -C "$REPO" merge-base --is-ancestor origin/polecat/bd-1 origin/main ||
        fail "fixture is wrong: the rebased branch must NOT be an ancestor of main"

    run_recheck_block "$REPO"
    grep -q "gc bd close" "$GC_LOG" ||
        fail "a rebased-and-landed branch must close, log: $(cat "$GC_LOG")\nout: $(cat "$SANDBOX/recheck.out")"
    grep -q "merge_result=merged" "$GC_LOG" ||
        fail "a rebased-and-landed branch must record merge_result=merged"
}

test_recheck_leaves_unlanded_branch_open_without_github() {
    # Control for the test above: same fallback, work genuinely not on main.
    # Without this, a predicate that always returned "landed" would look right.
    new_sandbox
    setup_rebased_landing_repo
    # Add a second, un-landed commit so the branch is no longer fully upstream.
    git -C "$REPO" checkout -q polecat/bd-1
    echo more >"$REPO/unlanded.txt"
    git -C "$REPO" add unlanded.txt
    git -C "$REPO" commit -qm "not landed anywhere"
    git -C "$REPO" push -q origin polecat/bd-1
    git -C "$REPO" fetch -q origin
    write_awaiting_bead "$(date -u +%s)" "" "$FORK_SHA"
    unset GH_PR_VIEW_JSON

    run_recheck_block "$REPO"
    assert_not_closed "unlanded branch"
}

# A repo where a MULTI-commit branch was SQUASH-merged: the target carries ONE
# commit whose diff is the sum of the branch's two, so no per-commit patch-id
# matches and `git cherry` reports both as absent. This is the formula's
# documented blind spot, and the only thing that sees through it is GitHub's
# `mergedAt` -- which is why a broken --json query here strands the bead.
setup_squash_landing_repo() {
    ORIGIN="$SANDBOX/origin.git"
    REPO="$SANDBOX/squashed"
    git init -q --bare "$ORIGIN"
    git init -q "$REPO"
    git -C "$REPO" config user.email t@example.com
    git -C "$REPO" config user.name Tester
    git -C "$REPO" remote add origin "$ORIGIN"
    echo base >"$REPO/file.txt"
    git -C "$REPO" add file.txt
    git -C "$REPO" commit -qm base
    git -C "$REPO" branch -M main
    git -C "$REPO" push -q origin main
    FORK_SHA=$(git -C "$REPO" rev-parse main)

    # Two commits on the branch -- the multi-commit precondition.
    git -C "$REPO" checkout -q -b polecat/bd-1
    echo one >"$REPO/a.txt"
    git -C "$REPO" add a.txt
    git -C "$REPO" commit -qm "part one"
    echo two >"$REPO/b.txt"
    git -C "$REPO" add b.txt
    git -C "$REPO" commit -qm "part two"
    git -C "$REPO" push -q origin polecat/bd-1

    # The squash merge: both changes land on main as a single new commit.
    git -C "$REPO" checkout -q main
    git -C "$REPO" merge -q --squash polecat/bd-1 >/dev/null
    git -C "$REPO" commit -qm "Fix the thing (#42)"
    git -C "$REPO" push -q origin main
    git -C "$REPO" fetch -q origin
    SQUASH_SHA=$(git -C "$REPO" rev-parse main)
}

test_recheck_closes_squash_merged_multi_commit_pr() {
    # The headline regression: the case that strands a bead when the GitHub
    # query is broken. gh's answer is the ONLY evidence available here, so this
    # test fails outright if the --json field list is rejected.
    new_sandbox
    setup_squash_landing_repo
    write_awaiting_bead "$(date -u +%s)" "" "$FORK_SHA"

    # Non-vacuity: prove the git-side predicate genuinely cannot see this
    # landing. Without this the test could pass on the git fallback and prove
    # nothing about the API path.
    git -C "$REPO" cherry origin/main origin/polecat/bd-1 | grep -q '^+' ||
        fail "fixture is wrong: a squash of a multi-commit branch must leave git cherry reporting '+'"

    export GH_PR_VIEW_JSON="{\"state\":\"MERGED\",\"mergedAt\":\"2026-07-30T04:00:00Z\",\"mergeCommit\":{\"oid\":\"$SQUASH_SHA\"}}"
    run_recheck_block "$REPO"

    grep -q "gc bd close" "$GC_LOG" ||
        fail "a squash-merged multi-commit PR must close its bead, log: $(cat "$GC_LOG")\nout: $(cat "$SANDBOX/recheck.out")"
    grep -q "merge_result=merged" "$GC_LOG" ||
        fail "the squash-merged bead must record merge_result=merged"
    # Pins the nested read: `.mergeCommit.oid`, not a flat `mergeCommitOid`.
    grep -q "merged_sha=$SQUASH_SHA" "$GC_LOG" ||
        fail "the merge sha must be read out of the mergeCommit object, log: $(cat "$GC_LOG")"
}

test_recheck_strands_squash_merge_when_gh_query_is_rejected() {
    # The failure this bug caused, pinned as a test: with gh's answer lost, the
    # same landed work does NOT close. That is the correct conservative
    # behaviour, but it must be LOUD -- silence here is what let the defect
    # survive, because a stranded bead looks exactly like a waiting one.
    new_sandbox
    setup_squash_landing_repo
    write_awaiting_bead "$(date -u +%s)" "" "$FORK_SHA"
    export GH_PR_VIEW_ERR='Unknown JSON field: "mergeCommitOid"'
    export GH_PR_VIEW_EXIT=1

    run_recheck_block "$REPO"
    assert_not_closed "rejected gh query on a squash merge"
    grep -q "Unknown JSON field" "$SANDBOX/recheck.out" ||
        fail "the stranding must report gh's own stderr, got: $(cat "$SANDBOX/recheck.out")"
}

test_recheck_makes_a_rejected_gh_query_loud() {
    # `2>/dev/null || printf ''` made "gh REJECTED my query" indistinguishable
    # from "gh is not installed", and only the latter is a legitimate reason to
    # fall back quietly. A rejected field list is a code defect that retrying
    # cannot fix, so it must be named as one.
    new_sandbox
    write_awaiting_bead "$(date -u +%s)"
    export GH_PR_VIEW_ERR='Unknown JSON field: "mergeCommitOid"'
    export GH_PR_VIEW_EXIT=1

    run_recheck_block
    grep -qi "FORMULA BUG" "$SANDBOX/recheck.out" ||
        fail "a rejected --json field list must be reported as a formula bug, got: $(cat "$SANDBOX/recheck.out")"
    grep -q "mergeCommitOid" "$SANDBOX/recheck.out" ||
        fail "the diagnostic must name the field gh rejected, got: $(cat "$SANDBOX/recheck.out")"
    assert_not_closed "rejected gh query"

    # A transient failure must be loud too, but must NOT be mislabelled a code
    # defect: an operator who cannot tell the two apart can act on neither.
    new_sandbox
    write_awaiting_bead "$(date -u +%s)"
    export GH_PR_VIEW_ERR='error connecting to api.github.com'
    export GH_PR_VIEW_EXIT=1

    run_recheck_block
    grep -q "could not answer" "$SANDBOX/recheck.out" ||
        fail "a transient gh failure must still be reported, got: $(cat "$SANDBOX/recheck.out")"
    ! grep -qi "FORMULA BUG" "$SANDBOX/recheck.out" ||
        fail "a network blip must not be reported as a formula bug"
    assert_not_closed "transient gh failure"
}

test_recheck_escalates_a_stale_pr_exactly_once() {
    # Leaving the bead open is only half of "make it loud". A PR nobody merges
    # has to surface -- but nagging every patrol iteration is how alerts get
    # ignored, so the escalation fires once, on the transition.
    new_sandbox
    write_awaiting_bead "$(( $(date -u +%s) - 7200 ))"
    export GH_PR_VIEW_JSON='{"state":"OPEN","mergedAt":null,"mergeCommit":null}'

    run_recheck_block
    assert_not_closed "stale"
    grep -q "awaiting_merge_stale=true" "$GC_LOG" ||
        fail "a 2h-unmerged PR must be flagged stale, log: $(cat "$GC_LOG")"
    grep -q "session nudge.*witness" "$GC_LOG" ||
        fail "going stale must escalate to the witness, log: $(cat "$GC_LOG")"

    # Second pass, bead already flagged: silence.
    new_sandbox
    write_awaiting_bead "$(( $(date -u +%s) - 7200 ))" true
    export GH_PR_VIEW_JSON='{"state":"OPEN","mergedAt":null,"mergeCommit":null}'
    run_recheck_block
    ! grep -q "session nudge" "$GC_LOG" ||
        fail "an already-flagged stale PR must not re-escalate every patrol"
}

# Feed QUEUE_JSON to the find-work selection block and echo the bead it chose
# ("" = the refinery goes idle). Requires $SANDBOX/select.sh already extracted.
select_work_from() {
    printf '%s' "$1" >"$GC_LIST_WORK"
    PATH="$BIN:$PATH" GC_AGENT=testrig/refinery bash -c \
        '. "$1/select.sh"; printf "%s\n" "$WORK"' _ "$SANDBOX"
}

test_awaiting_bead_never_starves_the_merge_queue() {
    # Parked beads stay open and assigned to the refinery on purpose, so a
    # naive --limit=1 work query would hand back the same waiting-on-a-human PR
    # forever and every other branch would queue behind it.
    #
    # BOTH spellings of the flag are exercised, because the reader has to
    # tolerate both. `--set-metadata awaiting_merge=true` stores a JSON
    # *boolean*, which is what every bead parked in the wild carries and what
    # the type-strict jq compare silently let through; the quoted string is the
    # shape a hand-written fixture takes. A reader that handles only one of them
    # is the bug -- and pinning only the string is how this passed while the
    # merge queue livelocked in production.
    new_sandbox
    extract_step_block find-work 'WORK_JSON_RAW=$(gc bd list' >"$SANDBOX/select.sh"
    GC_LIST_WORK="$SANDBOX/work.json"
    export GC_LIST_WORK

    for parked_flag in 'true' '"true"'; do
        # Parked bead listed FIRST so `[0]` lands on it unless the filter truly
        # skips it. Ordering is load-bearing in this fixture: real query order is
        # not specified, and a queue that happens to put fresh work first passes
        # even with the filter deleted outright.
        selected=$(select_work_from \
"[{\"id\":\"bd-parked\",\"metadata\":{\"branch\":\"polecat/bd-parked\",\"awaiting_merge\":$parked_flag}},
 {\"id\":\"bd-fresh\",\"metadata\":{\"branch\":\"polecat/bd-fresh\"}}]")
        [ "$selected" = "bd-fresh" ] ||
            fail "work selection must skip the parked bead (awaiting_merge=$parked_flag) and take fresh work, got: '$selected'"

        # Only parked work: the refinery must go idle, not re-process the PR.
        # This is the exact shape the live incident took -- a single parked bead
        # in the queue -- and the case that rebases, re-tests and force-pushes a
        # published PR, resetting its checks on every patrol.
        selected=$(select_work_from \
"[{\"id\":\"bd-parked\",\"metadata\":{\"branch\":\"polecat/bd-parked\",\"awaiting_merge\":$parked_flag}}]")
        [ -z "$selected" ] ||
            fail "a queue of only parked beads (awaiting_merge=$parked_flag) must select nothing, got: '$selected'"
    done

    # Not-parked must stay selectable. `//` is jq's alternative operator, so it
    # falls through on `false` as well as `null` -- correct here, but only by
    # coincidence, so pin it before a rewrite "simplifies" it away.
    selected=$(select_work_from \
'[{"id":"bd-unparked","metadata":{"branch":"polecat/bd-unparked","awaiting_merge":false}}]')
    [ "$selected" = "bd-unparked" ] ||
        fail "awaiting_merge=false is not parked and must remain selectable, got: '$selected'"
}

test_real_park_path_writes_a_flag_the_selector_excludes() {
    # The regression test that cannot pass while production is broken: it parks
    # a bead with the REAL writer and hands the REAL stored JSON to the formula's
    # own selection block. No fixture anywhere in the path.
    #
    # This exists because a fixture can only ever assert the type its author
    # believed was stored, and believing "string" is exactly how this bug
    # survived a green suite.
    #
    # The writer is spelled `gc bd`, matching the park path in merge-push
    # verbatim -- that routing wrapper is part of the contract under test, not
    # incidental, so reaching for the bare binary would test something the
    # formula never runs. Beads drives an embedded Dolt engine, so a throwaway
    # city needs no server; it does need the `gc` binary, which the PR gate
    # (ci.yml) installs for the lint step but does not put on PATH for this
    # suite. Where it is missing the check announces the skip instead of passing
    # quietly, and the fixture test above still covers both spellings.
    if ! command -v gc >/dev/null 2>&1; then
        echo "SKIP: gc not on PATH; the real-park-path round trip did not run" >&2
        return 0
    fi
    new_sandbox
    extract_step_block find-work 'WORK_JSON_RAW=$(gc bd list' >"$SANDBOX/select.sh"
    GC_LIST_WORK="$SANDBOX/work.json"
    export GC_LIST_WORK

    # Throwaway city with a throwaway ledger inside it. `gc bd` refuses to run
    # outside a city, and a stub city.toml plus .gc/ is all it needs to route.
    # Every ambient BEADS_*/GC_* pointer is dropped and HOME is redirected, so a
    # test run can never reach a real rig's bead database. It warns about
    # unimported builtin packs, which is harmless here and why stderr is quiet.
    city="$SANDBOX/city"
    mkdir -p "$city/.gc" "$SANDBOX/home"
    (cd "$city" && git init -q .)
    printf 'name = "refinerytest"\n' >"$city/city.toml"
    gc_bd_hermetic() {
        (cd "$city" && env \
            -u BEADS_DIR -u BEADS_DOLT_SERVER_PORT -u BEADS_DOLT_AUTO_START \
            -u BEADS_HOLDER_TOKEN -u BEADS_ACTOR -u GC_BEADS_SCOPE_ROOT \
            -u GC_RIG -u GC_CITY -u GC_CITY_PATH -u GC_DIR -u GC_AGENT \
            HOME="$SANDBOX/home" BD_NON_INTERACTIVE=1 BD_METRICS_ENABLED=0 \
            BEADS_DIR="$city/.beads" \
            gc bd "$@")
    }
    if ! gc_bd_hermetic init --prefix=aw --non-interactive >/dev/null 2>&1; then
        echo "SKIP: hermetic 'gc bd init' failed; the real-park-path round trip did not run" >&2
        return 0
    fi

    parked=$(gc_bd_hermetic q "parked pull request" 2>/dev/null | tail -1 | tr -d '[:space:]')
    # Match the prefix, not merely non-empty: first-run notices on stdout would
    # otherwise be mistaken for a bead id and the failure would be inscrutable.
    case "$parked" in
        aw-*) : ;;
        *) fail "hermetic 'gc bd q' did not return a bead id, got: '$parked'" ;;
    esac

    # THE PARK PATH, spelled exactly as the mr branch of merge-push writes it.
    gc_bd_hermetic update "$parked" --set-metadata branch="polecat/$parked" \
        --set-metadata awaiting_merge=true >/dev/null 2>&1 ||
        fail "the real park path failed to write awaiting_merge"

    # Canary. If the store ever holds this as something other than a boolean the
    # hermetic fixtures above no longer mirror production -- fail loudly and name
    # the test to update rather than let the two drift apart in silence.
    stored=$(gc_bd_hermetic show "$parked" --json 2>/dev/null | jq -r '.[0].metadata.awaiting_merge | type')
    [ "$stored" = "boolean" ] ||
        fail "'--set-metadata awaiting_merge=true' now stores a '$stored', not a boolean; test_awaiting_bead_never_starves_the_merge_queue encodes boolean and must be updated to match"

    # The queue a refinery would really be handed. A single parked bead is the
    # decisive case: with anything else in the list `[0]` can land on fresh work
    # and hide a filter that never fired -- which is what real list ordering did
    # when this test was written.
    queue=$(gc_bd_hermetic list --status=open --has-metadata-key=branch --limit=0 --json 2>/dev/null)
    selected=$(select_work_from "$queue")
    # Summarise rather than dumping whole bead records, which run to hundreds of
    # lines and would bury the assertion message.
    [ -z "$selected" ] || fail "a bead parked through the real writer must not be selected as merge work, got: '$selected' (queue: $(printf '%s' "$queue" | jq -c '[.[] | {id, awaiting_merge: .metadata.awaiting_merge, type: (.metadata.awaiting_merge | type)}]'))"
}

test_protected_target_never_resolves_to_direct
test_unprotected_target_keeps_direct
test_protection_is_probed_against_origin_not_the_fork_parent
test_non_github_origin_is_reported_rather_than_guessed
test_missing_gh_preserves_legacy_direct_default
test_direct_push_guard_refuses_protected_target
test_direct_push_still_lands_on_unprotected_target
test_red_required_checks_block_and_return_bead_to_pool
test_timed_out_checks_block_without_retry
test_required_checks_never_scheduled_block
test_green_required_checks_proceed_to_merge
test_no_required_checks_anywhere_proceeds
test_mr_parks_bead_open_instead_of_closing_on_pr_open
test_recheck_closes_bead_once_github_reports_merged
test_recheck_leaves_unmerged_pr_open
test_recheck_detects_rebased_landing_without_github
test_recheck_leaves_unlanded_branch_open_without_github
test_recheck_closes_squash_merged_multi_commit_pr
test_recheck_strands_squash_merge_when_gh_query_is_rejected
test_recheck_makes_a_rejected_gh_query_loud
test_recheck_escalates_a_stale_pr_exactly_once
test_awaiting_bead_never_starves_the_merge_queue
test_real_park_path_writes_a_flag_the_selector_excludes

echo "PASS: $(basename "${BASH_SOURCE[0]}")"
