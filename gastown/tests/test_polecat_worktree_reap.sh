#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT/gastown/assets/scripts/polecat-worktree-reap.sh"

# gp-a7z: this reaper deletes directories, so its two failure directions are
# wildly asymmetric:
#   * a missed reap leaks one directory (the status quo, ~3/day), while
#   * a WRONG reap destroys a polecat's unpushed work permanently.
# So most of what follows pins the refusal direction — an in-flight bead, a
# dirty tree, an unmerged commit, a fuzzy-matched basename, and an agent
# workspace must all survive. The one thing pinned in the permissive direction
# is the patch-id check, because keying on ancestry instead is what would let
# the leak survive the fix.

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

RIG=testrig

# The script reads the world through `gc rig list --json` and
# `gc bd --rig <rig> {show,list} --json`, so one stub covers everything. It
# deliberately emulates bd's FUZZY id matching (verified live: `gc bd show a7z`
# returns gp-a7z) so the identity guard is tested against the real hazard
# rather than an idealised CLI.
write_gc_stub() {
    mkdir -p "$BIN"
    cat >"$BIN/gc" <<'SH'
#!/usr/bin/env sh
ALL="$GC_STUB_BEADS/all.json"
case "$*" in
    "rig list --json"*)
        jq -n --arg p "$GC_STUB_REPO" --arg r "$GC_STUB_RIG" '{rigs:[{name:$r,path:$p}]}'
        ;;
    *" show "*)
        id=''; prev=''
        for a in "$@"; do
            if [ "$prev" = show ]; then id="$a"; break; fi
            prev="$a"
        done
        out=$(jq --arg i "$id" '[.[] | select(.id == $i)]' "$ALL")
        if [ "$(printf '%s' "$out" | jq 'length')" -eq 0 ]; then
            # bd's fuzzy match: a bare suffix resolves to the full id.
            out=$(jq --arg i "$id" '[.[] | select(.id | endswith($i))]' "$ALL")
        fi
        if [ "$(printf '%s' "$out" | jq 'length')" -eq 0 ]; then
            printf '{"error":"no issues found matching the provided IDs","schema_version":1}\n'
        else
            printf '%s\n' "$out"
        fi
        ;;
    *" list "*)
        # Fault injection for the claim-set read, so a test can break ONLY the
        # listing while `show` stays healthy.
        [ -n "${GC_STUB_LIST_FAILS:-}" ] && exit 7
        status=''
        for a in "$@"; do
            case "$a" in --status=*) status="${a#--status=}" ;; esac
        done
        # Real bd rejects an unknown status outright rather than returning an
        # empty set, and accepts a comma-separated list. Both matter: the
        # reaper asks for every non-closed status in ONE call, and a stub that
        # answered "[]" to a name bd would have REJECTED would hide a typo'd
        # status behind an empty claimed-set — i.e. behind a silently disarmed
        # guard, which is the exact failure this suite exists to catch.
        for one in $(printf '%s' "$status" | tr ',' ' '); do
            case "$one" in
                open|in_progress|blocked|deferred|closed) ;;
                *) printf 'Error: invalid status "%s" (valid: open, in_progress, blocked, deferred, closed, pinned, hooked)\n' "$one" >&2
                   exit 1 ;;
            esac
        done
        jq --arg s "$status" '[.[] | select(.status as $x | ($s | split(",")) | index($x))]' "$ALL"
        ;;
    *) printf '{}\n' ;;
esac
SH
    chmod +x "$BIN/gc"
}

# bead <id> <status> [closed_at] [work_dir] — appends one bead to the ledger.
bead() {
    local id="$1" status="$2" closed="${3:-}" work_dir="${4:-}"
    local tmpf
    tmpf=$(mktemp)
    jq --arg id "$id" --arg st "$status" --arg c "$closed" --arg w "$work_dir" \
        '. + [{
            id: $id,
            status: $st,
            closed_at: (if $c == "" then null else $c end),
            metadata: ({target: "main"} + (if $w == "" then {} else {work_dir: $w} end))
         }]' "$BEADS/all.json" >"$tmpf"
    mv "$tmpf" "$BEADS/all.json"
}

git_c() { git -C "$REPO" "$@"; }

commit_all() {
    git_c add -A
    git_c commit --quiet -m "$1"
}

# make_world — a real repo with a real bare origin and a real city layout, so
# path-shape matching, `git worktree list --porcelain`, `git cherry`,
# `git status` and `git worktree remove` all exercise the same code paths a
# live witness does. Nothing here is mocked except the bd/rig reads.
make_world() {
    tmp=$(mktemp -d)
    BIN="$tmp/bin"
    BEADS="$tmp/beads"
    REPO="$tmp/repo"
    ORIGIN="$tmp/origin.git"
    CITY="$tmp/city"
    WTROOT="$CITY/.gc/worktrees/$RIG/polecats"

    mkdir -p "$BEADS" "$WTROOT"
    printf '[]\n' >"$BEADS/all.json"
    printf 'name = "test"\n' >"$CITY/city.toml"

    git init --quiet --bare "$ORIGIN"
    git init --quiet -b main "$REPO"
    git_c config user.email witness@test.invalid
    git_c config user.name "Test Witness"
    git_c config commit.gpgsign false
    git_c remote add origin "$ORIGIN"

    echo "# base" >"$REPO/README.md"
    commit_all "chore: base"
    git_c push --quiet -u origin main

    write_gc_stub
}

# land_rebased <branch> <file> — reproduce what the refinery actually does: cut a
# branch, let the target move on underneath it, then replay the branch's PATCH
# onto the target. The intervening commit on main is what makes the replayed
# commit's SHA differ; cherry-picking onto an undiverged target reproduces the
# identical SHA and would test nothing.
land_rebased() {
    local branch="$1" file="$2" sha
    git_c checkout --quiet -b "$branch" origin/main
    echo "content of $file" >"$REPO/$file"
    commit_all "feat: $file ($branch)"
    sha=$(git_c rev-parse HEAD)

    git_c checkout --quiet main
    echo "meanwhile" >>"$REPO/README.md"
    commit_all "chore: unrelated main advance"

    git_c cherry-pick --quiet "$sha" >/dev/null 2>&1
    git_c push --quiet origin main
    git_c fetch --quiet origin main

    [ "$(git_c rev-parse HEAD)" != "$sha" ] ||
        fail "fixture is wrong: the replayed commit must have a different SHA than $sha"
    printf '%s' "$sha"
}

# add_tree <agent> <bead> [branch] — a per-bead worktree at the canonical path.
# With no branch, the tree is detached at origin/main, which is the shape a
# polecat leaves behind after submit-and-exit detaches and deletes its branch.
add_tree() {
    local agent="$1" bead="$2" branch="${3:-}" path
    path="$WTROOT/$agent/worktrees/$bead"
    mkdir -p "$WTROOT/$agent"
    if [ -n "$branch" ]; then
        git_c worktree add --quiet "$path" "$branch" >/dev/null 2>&1
    else
        git_c worktree add --quiet --detach "$path" origin/main >/dev/null 2>&1
    fi
    printf '%s' "$path"
}

# run_reap [args...] — runs the reaper from a neutral cwd so the keep-self
# guard never fires by accident.
run_reap() {
    set +e
    OUT=$(cd "$tmp" && env \
        GC_CITY="$CITY" GC_RIG="$RIG" \
        GC_STUB_BEADS="$BEADS" GC_STUB_REPO="$REPO" GC_STUB_RIG="$RIG" \
        GASTOWN_REAP_MIN_AGE_MIN="${MIN_AGE:-0}" \
        PATH="$BIN:$PATH" \
        bash "$SCRIPT" ${1+"$@"} 2>"$tmp/err")
    RC=$?
    set -e
    ERR=$(cat "$tmp/err")
}

verdict_of() { printf '%s' "$OUT" | awk -F'\t' -v b="$1" '$2 == b { print $1 }'; }

long_ago() { date -u -d '-3 hours' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-3H +%Y-%m-%dT%H:%M:%SZ; }
just_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

cleanup() { [ -n "${tmp:-}" ] && rm -rf "$tmp"; }
trap cleanup EXIT

# --- The regression that defines the fix ------------------------------------
# A branch the refinery REBASED before merging is on the target with a
# different SHA. `merge-base --is-ancestor` says NO; `git cherry` says the patch
# is upstream. Measured live on gascity-packs (2026-07-29): gp-px5 and gp-nrm
# were both closed, clean, non-ancestors, with zero unmerged patches. Keying on
# ancestry reaps neither, and the leak survives the fix.
test_rebased_landing_is_reapable_though_not_an_ancestor() {
    make_world
    land_rebased polecat/gp-land feature.txt >/dev/null

    local wt
    wt=$(add_tree agentA gp-land polecat/gp-land)

    # Pin the premise: ancestry genuinely disagrees with patch-id here.
    ! git -C "$wt" merge-base --is-ancestor HEAD origin/main 2>/dev/null ||
        fail "fixture is wrong: HEAD must NOT be an ancestor of origin/main"
    [ -z "$(git -C "$wt" cherry origin/main HEAD | grep '^+' || true)" ] ||
        fail "fixture is wrong: no patch should be missing upstream"

    bead gp-land closed "$(long_ago)"
    run_reap

    [ "$(verdict_of gp-land)" = "reap" ] ||
        fail "a rebased landing must be reapable (patch-id, not ancestry); got '$(verdict_of gp-land)' / rows: $OUT"
    [ "$RC" -eq 1 ] || fail "findings must exit 1, got $RC"
}

# --- Refusals: work that must survive --------------------------------------

test_in_flight_bead_is_never_reaped() {
    make_world
    local wt
    wt=$(add_tree agentA gp-work)
    # in_progress with a pristine tree is the shape a polecat has for most of
    # its life; nothing about "clean" means "finished".
    bead gp-work in_progress
    run_reap

    [ "$(verdict_of gp-work)" = "keep-open" ] ||
        fail "an in_progress bead's tree must be kept; got '$(verdict_of gp-work)'"
    [ -d "$wt" ] || fail "report mode must never remove anything"

    run_reap --reap
    [ -d "$wt" ] || fail "--reap must not remove an in-flight tree"
}

test_rejection_resume_shape_is_never_reaped() {
    # gp-px5, live: a rejected bead returned to the pool and was resumed by a
    # DIFFERENT polecat, while metadata.work_dir still pointed into the
    # ORIGINAL polecat's workspace — whose agent had no session at all. Both
    # the open status and the unmerged commit must refuse it independently.
    make_world
    git_c checkout --quiet -b polecat/gp-rej origin/main
    echo "wip" >"$REPO/wip.txt"
    commit_all "feat: partial work (gp-rej)"
    git_c checkout --quiet main

    local wt
    wt=$(add_tree deadagent gp-rej polecat/gp-rej)
    bead gp-rej open "" "$wt"
    run_reap --reap

    [ "$(verdict_of gp-rej)" = "keep-open" ] ||
        fail "a rejected-and-resumed bead must be kept; got '$(verdict_of gp-rej)'"
    [ -d "$wt" ] || fail "the rejection-resume tree was destroyed — this is the gp-px5 data-loss case"
    [ -n "$(git -C "$REPO" log --oneline main..polecat/gp-rej 2>/dev/null)" ] ||
        fail "the unpushed commit must still exist"
}

test_unmerged_commit_is_never_reaped() {
    make_world
    git_c checkout --quiet -b polecat/gp-ahead origin/main
    echo "unpushed" >"$REPO/unpushed.txt"
    commit_all "feat: never landed (gp-ahead)"
    git_c checkout --quiet main

    local wt
    wt=$(add_tree agentA gp-ahead polecat/gp-ahead)
    # Closed bead, clean tree — everything looks finished except the one thing
    # that matters: the patch is not upstream.
    bead gp-ahead closed "$(long_ago)"
    run_reap --reap

    [ "$(verdict_of gp-ahead)" = "keep-unmerged" ] ||
        fail "a commit whose patch is not upstream must be kept; got '$(verdict_of gp-ahead)'"
    [ -d "$wt" ] || fail "a tree with unmerged work was destroyed"
}

test_dirty_tree_is_never_reaped() {
    make_world
    local wt
    wt=$(add_tree agentA gp-dirty)
    echo "uncommitted" >"$wt/scratch.txt"
    bead gp-dirty closed "$(long_ago)"
    run_reap --reap

    [ "$(verdict_of gp-dirty)" = "keep-dirty" ] ||
        fail "an untracked file must keep the tree; got '$(verdict_of gp-dirty)'"
    [ -f "$wt/scratch.txt" ] || fail "uncommitted work was destroyed"
}

test_fuzzy_matched_basename_is_unverifiable_not_reaped() {
    # `gc bd show a7z` returns gp-a7z (verified live). Without an exact-id
    # guard, a directory named after a bead-id SUFFIX would be verified against
    # a different bead entirely and reaped on that bead's closed status.
    make_world
    local wt
    wt=$(add_tree agentA land)
    bead gp-land closed "$(long_ago)"
    run_reap --reap

    [ "$(verdict_of land)" = "unverifiable" ] ||
        fail "a fuzzy-matched basename must be unverifiable; got '$(verdict_of land)'"
    [ -d "$wt" ] || fail "a tree was reaped on a bead it does not belong to"
    grep -F 'gp-land' <<<"$OUT" >/dev/null ||
        fail "the row should name the bead it actually resolved to, so the mismatch is visible"
}

test_unreadable_bead_is_unverifiable_not_reaped() {
    make_world
    local wt
    wt=$(add_tree agentA gp-ghost)
    # No bead in the ledger at all.
    run_reap --reap

    [ "$(verdict_of gp-ghost)" = "unverifiable" ] ||
        fail "an unreadable bead must abstain, not clear the tree; got '$(verdict_of gp-ghost)'"
    [ -d "$wt" ] || fail "a tree was reaped without its bead ever being read"
    [ "$RC" -eq 1 ] || fail "unverifiable rows are findings and must exit 1, got $RC"
}

test_tree_claimed_by_another_live_bead_is_kept() {
    # The generalisation of the gp-px5 lesson: the bead named by the DIRECTORY
    # is closed, but a different, still-open bead has been pointed at this same
    # tree. Basename identity is not ownership.
    make_world
    local wt
    wt=$(add_tree agentA gp-done)
    bead gp-done closed "$(long_ago)"
    bead gp-other in_progress "" "$wt"
    run_reap --reap

    [ "$(verdict_of gp-done)" = "keep-claimed" ] ||
        fail "a tree claimed by a non-closed bead must be kept; got '$(verdict_of gp-done)'"
    [ -d "$wt" ] || fail "a tree still claimed by live work was destroyed"
}

test_every_non_closed_status_can_claim_a_tree() {
    # The claimed-tree guard is only as wide as the status list it asks bd for,
    # and a status missing from that list is a claim the guard cannot SEE — it
    # does not refuse the tree, it reaps it. `deferred` was missing exactly this
    # way while a bogus `escalated` sat in its place, so a deferred bead's
    # workspace was reapable out from under it.
    #
    # Asserting each status separately, rather than trusting one representative,
    # is deliberate: the failure is per-status and silent.
    local st wt
    for st in open in_progress blocked deferred; do
        make_world
        wt=$(add_tree agentA "gp-$st")
        bead "gp-$st" closed "$(long_ago)"
        bead "gp-claim-$st" "$st" "" "$wt"
        run_reap --reap

        [ "$(verdict_of "gp-$st")" = "keep-claimed" ] ||
            fail "a tree claimed by a '$st' bead must be kept; got '$(verdict_of "gp-$st")'"
        [ -d "$wt" ] ||
            fail "a tree claimed by a '$st' bead was destroyed"
    done
}

test_unreadable_claim_set_abstains_entirely() {
    # If the non-closed listing cannot be read, the claimed-tree guard cannot
    # fire for ANY tree. Continuing with an empty claim set would reap on a
    # guard that is silently disarmed — the script's own rule is that nothing
    # measured is NOT the same as nothing to reap, so it must abstain (exit 2)
    # and remove nothing.
    make_world
    local wt
    wt=$(add_tree agentA gp-landed)
    bead gp-landed closed "$(long_ago)"

    # Break only the `list` path; `show` stays healthy so the failure under
    # test is unambiguously the claim-set read.
    export GC_STUB_LIST_FAILS=1
    run_reap --reap
    unset GC_STUB_LIST_FAILS

    [ "$RC" -eq 2 ] ||
        fail "an unreadable claim set must exit 2 (nothing measured), got $RC"
    grep -Fq 'nothing was measured' <<<"$ERR" ||
        fail "the abstention must say nothing was measured; got: $ERR"
    [ -d "$wt" ] ||
        fail "a tree was reaped while the claimed-tree guard was unevaluable"

    # And the same world reaps normally once the listing is readable again —
    # proves the refusal was the broken read, not some other check declining it.
    run_reap --reap
    [ "$(verdict_of gp-landed)" = "reaped" ] ||
        fail "once the claim set is readable the tree must reap; got '$(verdict_of gp-landed)'"
}

test_grace_window_defers_a_freshly_closed_bead() {
    # Covers the one real race: a polecat that has drain-acked but whose session
    # the controller has not killed yet.
    make_world
    local wt
    wt=$(add_tree agentA gp-fresh)
    bead gp-fresh closed "$(just_now)"

    MIN_AGE=15
    run_reap --reap
    MIN_AGE=0

    [ "$(verdict_of gp-fresh)" = "keep-cooling" ] ||
        fail "a bead closed seconds ago must cool first; got '$(verdict_of gp-fresh)'"
    [ -d "$wt" ] || fail "a cooling tree was reaped"

    # Same tree, same bead, window elapsed — proves the refusal was the window
    # and not some other check quietly declining it.
    run_reap --reap
    [ "$(verdict_of gp-fresh)" = "reaped" ] ||
        fail "once the window elapses the same tree must reap; got '$(verdict_of gp-fresh)'"
}

test_unparseable_closed_at_abstains() {
    make_world
    local wt
    wt=$(add_tree agentA gp-nots)
    bead gp-nots closed "not-a-timestamp"
    run_reap --reap

    [ "$(verdict_of gp-nots)" = "unverifiable" ] ||
        fail "an unreadable closed_at must abstain rather than read as ancient; got '$(verdict_of gp-nots)'"
    [ -d "$wt" ] || fail "a tree was reaped without its age being measured"
}

# --- Scope: what is never even a candidate ---------------------------------

test_agent_workspace_is_never_a_candidate() {
    # An agent workspace is a registered worktree at polecats/<agent> — one
    # path segment short of a per-bead tree. Reaping one takes out a running
    # agent's home, which is far worse than the leak this script fixes.
    make_world
    local ws
    ws="$WTROOT/agentA"
    mkdir -p "$(dirname "$ws")"
    git_c worktree add --quiet --detach "$ws" origin/main >/dev/null 2>&1
    add_tree agentB gp-ok >/dev/null
    bead gp-ok closed "$(long_ago)"
    run_reap --reap

    [ -z "$(verdict_of agentA)" ] ||
        fail "the agent workspace must not appear as a candidate; got '$(verdict_of agentA)'"
    [ -d "$ws" ] || fail "the agent workspace was destroyed"
    [ "$(verdict_of gp-ok)" = "reaped" ] ||
        fail "the sibling per-bead tree should still have been reaped; got '$(verdict_of gp-ok)'"
}

test_rig_repo_and_foreign_worktrees_are_never_candidates() {
    make_world
    local outside
    outside="$tmp/outside-tree"
    git_c worktree add --quiet --detach "$outside" origin/main >/dev/null 2>&1
    run_reap --reap

    ! grep -F "$outside" <<<"$OUT" >/dev/null ||
        fail "a worktree outside the rig's polecats tree must never be a candidate"
    ! grep -F "	$REPO	" <<<"$OUT" >/dev/null ||
        fail "the rig repo itself must never be a candidate"
    [ -d "$outside" ] || fail "a foreign worktree was destroyed"
}

test_self_is_never_reaped() {
    make_world
    local wt
    wt=$(add_tree agentA gp-self)
    bead gp-self closed "$(long_ago)"
    set +e
    OUT=$(cd "$wt" && env \
        GC_CITY="$CITY" GC_RIG="$RIG" \
        GC_STUB_BEADS="$BEADS" GC_STUB_REPO="$REPO" GC_STUB_RIG="$RIG" \
        GASTOWN_REAP_MIN_AGE_MIN=0 PATH="$BIN:$PATH" \
        bash "$SCRIPT" --reap 2>/dev/null)
    set -e

    [ "$(verdict_of gp-self)" = "keep-self" ] ||
        fail "the tree we are standing in must not be reaped; got '$(verdict_of gp-self)'"
    [ -d "$wt" ] || fail "the reaper deleted its own working directory"
}

# --- Removal actually happens, and only under --reap -----------------------

test_reap_removes_tree_registration_and_stale_branch() {
    make_world
    land_rebased polecat/gp-gone landed.txt >/dev/null

    local wt
    wt=$(add_tree agentA gp-gone polecat/gp-gone)
    bead gp-gone closed "$(long_ago)"

    run_reap
    [ "$(verdict_of gp-gone)" = "reap" ] || fail "expected a dry-run 'reap' row"
    [ -d "$wt" ] || fail "report mode removed a directory"

    run_reap --reap
    [ "$(verdict_of gp-gone)" = "reaped" ] ||
        fail "expected 'reaped'; got '$(verdict_of gp-gone)' / rows: $OUT"
    [ ! -d "$wt" ] || fail "the tree was not actually removed"
    ! git_c worktree list --porcelain | grep -Fq "worktree $wt" ||
        fail "the worktree registration was left behind"
    ! git_c show-ref --verify --quiet refs/heads/polecat/gp-gone ||
        fail "the stale local branch was left behind"
}

test_nothing_to_do_exits_zero() {
    make_world
    run_reap
    [ "$RC" -eq 0 ] || fail "no candidates must exit 0, got $RC ($ERR)"
}

test_missing_rig_cannot_run() {
    make_world
    set +e
    OUT=$(cd "$tmp" && env GC_CITY="$CITY" GC_STUB_BEADS="$BEADS" \
        GC_STUB_REPO="$REPO" GC_STUB_RIG="$RIG" PATH="$BIN:$PATH" \
        bash "$SCRIPT" 2>"$tmp/err")
    RC=$?
    set -e
    [ "$RC" -eq 2 ] ||
        fail "no rig means nothing was measured and must exit 2, not 0; got $RC"
}

test_registered_tree_with_missing_directory_is_pruned() {
    make_world
    local wt
    wt=$(add_tree agentA gp-vanish)
    rm -rf "$wt"
    bead gp-vanish closed "$(long_ago)"
    run_reap --reap

    [ "$(verdict_of gp-vanish)" = "reaped" ] ||
        fail "a registered tree whose directory is gone should be pruned; got '$(verdict_of gp-vanish)'"
    ! git_c worktree list --porcelain | grep -Fq "worktree $wt" ||
        fail "the stale registry entry survived"
}

test_help_is_self_documenting() {
    make_world
    set +e
    OUT=$(bash "$SCRIPT" --help 2>&1)
    RC=$?
    set -e
    [ "$RC" -eq 0 ] || fail "--help must exit 0, got $RC"
    grep -Fq 'patch-id' <<<"$OUT" || fail "--help must explain the patch-id choice"
    grep -Fq 'Exit codes' <<<"$OUT" || fail "--help must document exit codes"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
    "$t"
    echo "ok - $t"
done

echo "All polecat-worktree-reap tests passed."
