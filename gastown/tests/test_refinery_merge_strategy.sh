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
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
FORMULA="$ROOT/gastown/formulas/mol-refinery-patrol.toml"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# Emit the single fenced bash block of the merge-push step that contains
# ANCHOR, with {{vars}} rendered from the formula's own defaults the way the
# formula engine would render them.
#
# Requiring EXACTLY one match is deliberate: if the step is reorganised and an
# anchor goes missing or turns ambiguous, the test dies loudly instead of
# quietly exercising nothing.
extract_block() {
    python3 - "$FORMULA" "$1" <<'PY'
import re
import sys
import tomllib

formula, anchor = sys.argv[1], sys.argv[2]
with open(formula, "rb") as handle:
    data = tomllib.load(handle)

step = next(s for s in data["steps"] if s["id"] == "merge-push")
blocks = [
    b for b in re.findall(r"```bash\n(.*?)```", step["description"], re.S)
    if anchor in b
]
if len(blocks) != 1:
    sys.exit(
        f"expected exactly 1 merge-push bash block containing {anchor!r}, "
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

# `gc` stub: reads bead JSON from a file, records every mutation as one line in
# $GC_LOG so tests can assert on what the formula did (and did not) write.
# Dispatch and log lines are both spelled as the full `gc bd ...` command, so
# assertions below match the same string the stub writes.
write_gc_stub() {
    cat >"$1/gc" <<'SH'
#!/usr/bin/env sh
case "gc $1 $2" in
    "gc bd show")
        cat "$GC_BEAD_JSON"
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
#   GH_WATCH_EXIT       exit status of `gh pr checks --watch`
#   GH_CHECKS_JSON      stdout of `gh pr checks --json ...`
#   GH_CHECKS_ERR       stderr of the same
#   GH_CHECKS_EXIT      its exit status
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
# and an empty mutation log.
new_sandbox() {
    SANDBOX=$(mktemp -d)
    BIN="$SANDBOX/bin"
    mkdir -p "$BIN"
    write_gc_stub "$BIN"
    write_gh_stub "$BIN"
    GC_LOG="$SANDBOX/gc.log"
    : >"$GC_LOG"
    GC_BEAD_JSON="$SANDBOX/bead.json"
    # Pin the rig so assertions do not depend on the ambient GC_RIG of whoever
    # runs the suite.
    GC_RIG=testrig
    export GC_LOG GC_BEAD_JSON GC_RIG
    # Unset per-scenario knobs so a previous test cannot leak into the next.
    unset GH_PROTECTION_JSON GH_PROTECTED_FLAG GH_WATCH_EXIT \
        GH_CHECKS_JSON GH_CHECKS_ERR GH_CHECKS_EXIT
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

# Run the strategy-resolution block and report what it decided.
resolve_strategy() {
    extract_block 'probe_target_protection "$TARGET"' >"$SANDBOX/resolve.sh"
    PATH="$BIN:$PATH" WORK=bd-1 bash -c \
        'set -u; . "$1/resolve.sh"; printf "strategy=%s protected=%s pr_mode=%s\n" \
            "$MERGE_STRATEGY" "$TARGET_PROTECTED" "$PR_MODE"' \
        _ "$SANDBOX"
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
    # Real git remote, so the no-gh origin-URL fallback has something to parse.
    # That fallback never runs while gh is present.
    repo="$SANDBOX/repo"
    mkdir -p "$repo"
    git -C "$repo" init -q
    git -C "$repo" remote add origin https://github.com/acme/widgets.git
    extract_block 'probe_target_protection "$TARGET"' >"$SANDBOX/resolve.sh"
    result=$(cd "$repo" && PATH="$ghfree" WORK=bd-1 bash -c \
        'set -u; . "$1/resolve.sh"; printf "strategy=%s protected=%s\n" \
            "$MERGE_STRATEGY" "$TARGET_PROTECTED"' _ "$SANDBOX")
    case "$result" in
        *"strategy=direct"*"protected=unknown_no_gh"*) : ;;
        *) fail "absent gh should keep the legacy direct default, got: $result" ;;
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
    PATH="$BIN:$PATH" WORK=bd-1 PR_NUMBER=42 \
        PR_URL=https://github.com/acme/widgets/pull/42 \
        bash -c 'set -u; . "$1/resolve.sh"; . "$1/checks.sh"' _ "$SANDBOX" \
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

test_protected_target_never_resolves_to_direct
test_unprotected_target_keeps_direct
test_missing_gh_preserves_legacy_direct_default
test_direct_push_guard_refuses_protected_target
test_direct_push_still_lands_on_unprotected_target
test_red_required_checks_block_and_return_bead_to_pool
test_timed_out_checks_block_without_retry
test_required_checks_never_scheduled_block
test_green_required_checks_proceed_to_merge
test_no_required_checks_anywhere_proceeds

echo "PASS: $(basename "${BASH_SOURCE[0]}")"
