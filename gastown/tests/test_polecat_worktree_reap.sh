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
# workspace must all survive. Two things are pinned in the permissive
# direction, because each is a way the leak survives a fix:
#   * the patch-id check (C6), because keying on ancestry instead leaks every
#     rebased landing (gp-a7z);
#   * the subject reconciliation (C6b), because patch-id itself is unstable
#     whenever the patch is ADJUSTED on the way in — a conflict resolved by
#     hand, or a reviewer's touch-up — which left three trees permanently
#     unreapable on gascity-packs (gp-3kw).
# C6b's own guards are then pinned in the refusal direction in turn: a subject
# carrying no work reference, a subject landed fewer times than the tree holds
# it, and a merge no attestation confirms must each keep the tree.
#
# gp-psa added a third permissive pin, because C6b's two conjuncts were BOTH
# secretly rig-specific and either one alone kept the leak open:
#   * the anchor demanded the bead id in the subject, a convention only this rig
#     follows — meety-local stamps `(crit:<hash>)`, so C6b was dead code there;
#   * the merge attestation demanded a deleted origin branch, which is another
#     component's cleanup step and measurably is not running (60 undeleted
#     origin/polecat/* refs on meety-local, 53 on tallyup, 2026-07-31).
# Both are now pinned in the permissive direction, and the refusal ROWS are
# pinned too: a row that names the wrong clause is what kept gp-psa invisible.
#
# gp-98n added a fourth: PUBLICATION alone collects a tree. C6c shipped needing
# publication AND a recall flag, and ml-apes — `gc.work_outcome=abandoned`,
# neither flag — leaked 55M with its work on origin at the identical sha. Every
# refusal that guarded the recall conjunct is preserved BELOW the flip, and it
# is worth saying which ones they are, because relaxing a clearance is where a
# reaper destroys work: publication must still be measured against the EXACT
# ref, must still contain the tree's HEAD, and must still keep the tree when
# `ls-remote` could not answer. What went is only "and the bead said so".
#
# The consequence for the C6b fixtures is mechanical and worth knowing before
# reading them: a tree whose branch is merely pushed is now REAPED, so isolating
# a C6b arm needs `push_divergent_tip` rather than `push_branch` — origin
# carrying the ref, but not this tree's work.

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

# set_meta <id> <key> <value> — stamp one extra metadata field onto an existing
# bead. The refinery's merge attestation (`merged_sha`) is written long after
# the bead is created, and only a handful of fixtures care about it, so it is
# set separately rather than made an argument every other `bead` call ignores.
set_meta() {
    local id="$1" key="$2" val="$3" tmpf
    tmpf=$(mktemp)
    jq --arg id "$id" --arg k "$key" --arg v "$val" \
        '[.[] | if .id == $id then .metadata += {($k): $v} else . end]' \
        "$BEADS/all.json" >"$tmpf"
    mv "$tmpf" "$BEADS/all.json"
}

# set_meta_json <id> <key> <json-value> — like set_meta, but stores the value
# with its JSON type intact. The recall flags are written as real booleans on
# the live bead (verified read-only on meety-local/ml-94dh, 2026-08-03:
# `"do_not_merge":true`, not `"true"`), while a hand-stamped or round-tripped
# one can arrive as a string. The reader normalises both, so both are fixtured —
# a reader that matched only the string spelling would pass every test written
# with `set_meta` and do nothing at all in production.
set_meta_json() {
    local id="$1" key="$2" val="$3" tmpf
    tmpf=$(mktemp)
    jq --arg id "$id" --arg k "$key" --argjson v "$val" \
        '[.[] | if .id == $id then .metadata += {($k): $v} else . end]' \
        "$BEADS/all.json" >"$tmpf"
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

# land_adjusted <branch> <file> [subject] — what land_rebased cannot reproduce:
# the work reaches the target, but the patch is EDITED on the way in. A conflict
# resolved by hand, a reviewer's touch-up before the merge, a comment reflowed.
# The subject survives verbatim (rebase rewrites diffs, never messages) while
# the patch-id does not — so `git cherry` reports the tree's commit as missing
# forever. Measured live on gascity-packs: gp-q6i's landed twin has an
# IDENTICAL diffstat and differs by six bytes of reworded comment.
#
# The subject is overridable because C6b's anchor reads it: the default names
# the branch (and so the bead), while gp-psa's cases turn on subjects that
# deliberately do NOT — a criterion hash, a scope, a bare word.
land_adjusted() {
    local branch="$1" file="$2" subject="${3:-feat: $2 ($1)}" sha
    git_c checkout --quiet -b "$branch" origin/main
    printf 'content of %s\n# original wording\n' "$file" >"$REPO/$file"
    commit_all "$subject"
    sha=$(git_c rev-parse HEAD)

    git_c checkout --quiet main
    echo "meanwhile" >>"$REPO/README.md"
    commit_all "chore: unrelated main advance"

    # Same subject, different body — the shape a touched-up landing has.
    printf 'content of %s\n# reworded on the way in\n' "$file" >"$REPO/$file"
    commit_all "$subject"
    git_c push --quiet origin main
    git_c fetch --quiet origin main
    printf '%s' "$sha"
}

# push_branch <branch> — publish a polecat branch to origin, i.e. the state
# before the refinery merges and deletes it. Absent this, every fixture branch
# is local-only, which is the same shape as "already deleted after merge".
push_branch() { git_c push --quiet origin "$1"; }

# push_divergent_tip <branch> — put the branch on origin at a commit this tree
# does NOT contain. The two states a C6b fixture has to hold apart are otherwise
# unreachable together since gp-98n:
#
#   * the branch must be PRESENT on origin, or C6b's branch-absence proxy
#     attests the merge on its own and whichever arm the test is about is never
#     consulted;
#   * the tree must NOT be published, or C6c clears it before the arm under test
#     can refuse — and then a passing `keep-unmerged` assertion would be pinning
#     nothing at all.
#
# `push_branch` gives the first and destroys the second. This gives both: origin
# carries the ref, at work that is not this tree's. The shape is a real one — a
# force-push after a rebase, or a recycled branch name — and it is exactly the
# state `published_state` must refuse, so the fixtures double as its coverage.
push_divergent_tip() {
    local branch="$1" sha
    git_c checkout --quiet --detach origin/main
    echo "origin moved on without this tree" >>"$REPO/README.md"
    git_c add -A
    git_c commit --quiet -m "chore: an unrelated tip pushed to $branch"
    sha=$(git_c rev-parse HEAD)
    git_c push --quiet --force origin "$sha:refs/heads/$branch"
    git_c checkout --quiet main
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

# stage_blob <wt> <file> <content> — write a file inside a per-bead worktree and
# STAGE it, without committing. This is the shape gp-dgu is about: content that
# `ls` shows nothing special about, that no commit references, and that only the
# worktree's own index points at — so removing the directory drops the last
# reference to it.
stage_blob() {
    local wt="$1" file="$2" content="$3"
    printf '%s\n' "$content" >"$wt/$file"
    git -C "$wt" add "$file"
}

# stage_deletion <wt> <file> — stage the removal of a tracked file. Deletions are
# the half of a staged diff that carries no content: the bytes they remove are by
# definition still on the ref they were deleted from, so they must never count
# toward unreachable content. ml-cmai's 59 staged paths were 28 of these.
stage_deletion() {
    local wt="$1" file="$2"
    git -C "$wt" rm --quiet "$file"
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
detail_of() { printf '%s' "$OUT" | awk -F'\t' -v b="$1" '$2 == b { print $4 }'; }

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

# --- The second regression: patch-id is not stable under an ADJUSTED landing -
# gp-3kw. Three trees on gascity-packs (gp-f4m, gp-apx, gp-q6i) were closed,
# clean, branch-deleted, and demonstrably on main — and `git cherry` reported
# `+` on every cycle, so `keep-unmerged` printed forever and the trees could
# never be collected. Patch-id survives a clean rebase; it does not survive one
# that edits the diff at all.
test_adjusted_landing_is_reapable_though_patch_id_differs() {
    make_world
    land_adjusted polecat/gp-adj adjusted.txt >/dev/null

    local wt
    wt=$(add_tree agentA gp-adj polecat/gp-adj)

    # Pin the premise: patch-id genuinely disagrees here, so this test cannot
    # pass by accident through the C6 path it exists to compensate for.
    [ -n "$(git -C "$wt" cherry origin/main HEAD | grep '^+' || true)" ] ||
        fail "fixture is wrong: the adjusted patch must be missing upstream by patch-id"

    bead gp-adj closed "$(long_ago)"
    run_reap

    [ "$(verdict_of gp-adj)" = "reap" ] ||
        fail "an adjusted landing must be reapable via the subject signal; got '$(verdict_of gp-adj)' / rows: $OUT"
    grep -Fq 'adjusted on the way in' <<<"$OUT" ||
        fail "the evidence must name the signal that cleared it, so the two reap paths stay distinguishable; got: $OUT"

    run_reap --reap
    [ ! -d "$wt" ] || fail "the tree was not actually removed"
}

test_subject_match_alone_is_not_a_merge_attestation() {
    # The subject signal alone is not a merge. If the branch the refinery merges
    # is still on origin, no merge has been confirmed — the matching subject
    # could be a partial landing, or another bead's commit that happens to name
    # this one. C6b requires the refinery's own after-merge signal too.
    #
    # The branch is on origin at an unrelated tip rather than at this tree's
    # work: since gp-98n a genuinely published tree is collected by C6c, so a
    # plain `push_branch` here would reap for a reason that has nothing to do
    # with the attestation this test exists to pin.
    make_world
    land_adjusted polecat/gp-live live.txt >/dev/null
    push_divergent_tip polecat/gp-live

    local wt
    wt=$(add_tree agentA gp-live polecat/gp-live)
    bead gp-live closed "$(long_ago)"
    run_reap --reap

    [ "$(verdict_of gp-live)" = "keep-unmerged" ] ||
        fail "a subject match with no attestation must be kept; got '$(verdict_of gp-live)'"
    [ -d "$wt" ] || fail "a tree was reaped without the merge ever being confirmed"
    grep -Fq 'still present' <<<"$OUT" ||
        fail "the row must say the branch is still on origin; got: $OUT"
    grep -Fq 'no merge is attested' <<<"$OUT" ||
        fail "the row must name the attestation as the clause that declined; got: $OUT"
}

test_subject_with_no_work_reference_is_never_reaped() {
    # Anti-collision, and the reason the anchor exists at all. `chore: shared
    # cleanup` names no unit of work, so an identical subject on the target is
    # evidence of nothing. Here the target genuinely carries one, so an
    # existence-only match WOULD have reaped this tree and destroyed the only
    # copy of anon.txt. Relaxing the anchor from "the bead id" to "any work
    # reference" (gp-psa) must not relax it to "any subject".
    make_world
    git_c checkout --quiet -b polecat/gp-anon origin/main
    echo "mine" >"$REPO/anon.txt"
    commit_all "chore: shared cleanup"
    git_c checkout --quiet main
    echo "theirs" >"$REPO/other.txt"
    commit_all "chore: shared cleanup"
    git_c push --quiet origin main
    git_c fetch --quiet origin main

    local wt
    wt=$(add_tree agentA gp-anon polecat/gp-anon)
    bead gp-anon closed "$(long_ago)"
    run_reap --reap

    [ "$(verdict_of gp-anon)" = "keep-unmerged" ] ||
        fail "a subject carrying no work reference must not clear the tree; got '$(verdict_of gp-anon)'"
    [ -d "$wt" ] || fail "a tree was reaped on a subject collision — this is unpublished work destroyed"
    [ -f "$wt/anon.txt" ] || fail "the only copy of the unlanded file is gone"
}

# --- gp-psa: C6b's two conjuncts were both rig-specific ----------------------
# ml-uoa.3's tree was refused every cycle with its work byte-identically on
# origin/main as 2c6abe5. BOTH conjuncts vetoed it, so each of the two tests
# below fails on its own against the pre-gp-psa script — fixing either one
# alone only moves the tree from the first refusal arm to the second.

test_criterion_trailer_anchors_a_subject_match() {
    # The anchor demanded the tree's BEAD ID in the subject, justified by the
    # polecat formula mandating that spelling — which it does, for THIS rig.
    # The script is a pack asset that runs in every rig, and meety-local stamps
    # a criterion hash instead. Verified live: ml-uoa.3's subject is
    # `feat(portal): ... (crit:c84a4764d9a1)`, so the anchor vetoed 100% of C6b
    # there and the fallback was dead code in the rig it was needed in.
    make_world
    land_adjusted polecat/ml-uoa.3 portal.txt \
        'feat(portal): the console reports whether the splash is serving (crit:c84a4764d9a1)' >/dev/null

    local wt
    wt=$(add_tree agentA ml-uoa.3 polecat/ml-uoa.3)

    # Both premises, or this passes through a path it is not testing.
    [ -n "$(git -C "$wt" cherry origin/main HEAD | grep '^+' || true)" ] ||
        fail "fixture is wrong: the adjusted patch must be missing upstream by patch-id"
    ! grep -Fq 'ml-uoa.3' <<<"$(git -C "$wt" log -1 --format=%s)" ||
        fail "fixture is wrong: the subject must NOT contain the bead id, or this tests the old anchor"

    bead ml-uoa.3 closed "$(long_ago)"
    run_reap

    [ "$(verdict_of ml-uoa.3)" = "reap" ] ||
        fail "a criterion-hash trailer must anchor a subject match; got '$(verdict_of ml-uoa.3)' / rows: $OUT"
}

test_merged_sha_attests_a_merge_the_branch_state_cannot() {
    # The deleted origin branch is a PROXY for the merge, and it belongs to
    # another component: mol-refinery-patrol's Cleanup step, behind
    # `delete_merged_branches` (default "true"). Measured 2026-07-31 it is not
    # happening anyway — 60 undeleted origin/polecat/* refs on meety-local, 53
    # on tallyup — so C6b could clear nothing in those rigs however well the
    # subjects matched. merged_sha is the same fact recorded first-hand.
    make_world
    land_adjusted polecat/gp-sha shaland.txt >/dev/null
    # Present on origin so the branch-absence proxy is unavailable, but not
    # carrying this tree's work, so C6c does not clear it first (gp-98n).
    push_divergent_tip polecat/gp-sha
    local landed
    landed=$(git_c rev-parse origin/main)

    local wt
    wt=$(add_tree agentA gp-sha polecat/gp-sha)
    bead gp-sha closed "$(long_ago)"

    # Pin the precondition: with no attestation this is exactly
    # test_adjusted_landing_with_branch_still_on_origin_is_kept, so the flip
    # below is unambiguously the merged_sha and not some other relaxation.
    run_reap
    [ "$(verdict_of gp-sha)" = "keep-unmerged" ] ||
        fail "precondition: with no attestation at all this tree must be kept; got '$(verdict_of gp-sha)'"

    set_meta gp-sha merged_sha "$landed"
    run_reap

    [ "$(verdict_of gp-sha)" = "reap" ] ||
        fail "a merged_sha on the target must attest the merge; got '$(verdict_of gp-sha)' / rows: $OUT"
    grep -Fq 'merged_sha' <<<"$OUT" ||
        fail "the evidence must name the attestation that cleared it, so the two are distinguishable; got: $OUT"
}

test_merged_sha_not_on_the_target_does_not_attest() {
    # The field is CHECKED, not believed — which is the whole reason it can be
    # trusted more than the proxy. A sha from a superseded attempt, or one
    # force-pushed off the target, names a commit that is not there, and a
    # merge that is not on the target is not a merge.
    make_world
    land_adjusted polecat/gp-stale stale.txt >/dev/null
    push_divergent_tip polecat/gp-stale   # proxy unavailable, publication declines

    local wt
    wt=$(add_tree agentA gp-stale polecat/gp-stale)
    bead gp-stale closed "$(long_ago)"
    # A real, resolvable commit that is genuinely not on the target: the tree's
    # own tip. A syntactically valid sha must not be enough.
    set_meta gp-stale merged_sha "$(git -C "$wt" rev-parse HEAD)"
    run_reap --reap

    [ "$(verdict_of gp-stale)" = "keep-unmerged" ] ||
        fail "a merged_sha that is not on the target must not attest; got '$(verdict_of gp-stale)'"
    [ -d "$wt" ] || fail "a tree was reaped on an unchecked merged_sha"
    grep -Fq 'is not on origin/main' <<<"$OUT" ||
        fail "the row must say the recorded sha is not on the target; got: $OUT"
}

test_unresolvable_merged_sha_does_not_attest() {
    # mol-refinery-patrol writes `merged_sha="${AW_MERGE_SHA:-unknown}"` when a
    # PR merge reports no commit. Present-but-meaningless must not read as an
    # attestation. It is rejected on SHAPE, before anything resolves it, which
    # is what also stops a ref-like value ("main", "HEAD") from being resolved
    # into an attestation the refinery never made; a well-formed sha that
    # simply is not here fails one arm further along.
    make_world
    land_adjusted polecat/gp-unk unknown.txt >/dev/null
    push_divergent_tip polecat/gp-unk     # proxy unavailable, publication declines

    local wt
    wt=$(add_tree agentA gp-unk polecat/gp-unk)
    bead gp-unk closed "$(long_ago)"
    set_meta gp-unk merged_sha unknown
    run_reap --reap

    [ "$(verdict_of gp-unk)" = "keep-unmerged" ] ||
        fail "merged_sha=unknown must not attest a merge; got '$(verdict_of gp-unk)'"
    [ -d "$wt" ] || fail "a tree was reaped on a placeholder merged_sha"
    grep -Fq 'is not a commit sha' <<<"$OUT" ||
        fail "the row must say the recorded value is not a sha at all; got: $OUT"

    # A well-formed sha that is simply absent here is the neighbouring arm, and
    # must refuse just as firmly — otherwise the shape check above would be
    # carrying a refusal that the resolution step is supposed to own.
    set_meta gp-unk merged_sha deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
    run_reap --reap
    [ "$(verdict_of gp-unk)" = "keep-unmerged" ] ||
        fail "an absent-but-well-formed merged_sha must not attest; got '$(verdict_of gp-unk)'"
    [ -d "$wt" ] || fail "a tree was reaped on a merged_sha that resolves to nothing"
    grep -Fq 'does not resolve' <<<"$OUT" ||
        fail "the row must say the recorded sha does not resolve; got: $OUT"
}

test_conventional_commit_scope_is_not_a_work_reference() {
    # `feat(router-portal): ...` carries a spaceless, hyphenated parenthesised
    # group — but it is a SCOPE, not a trailer, and scopes are shared across
    # every commit touching that area. Requiring the token to END the subject is
    # the only thing separating the two, so it is pinned here: read a scope as
    # an anchor and any two commits with the same scoped subject clear.
    make_world
    land_adjusted polecat/gp-scope scoped.txt 'feat(router-portal): tidy the console' >/dev/null

    local wt
    wt=$(add_tree agentA gp-scope polecat/gp-scope)
    bead gp-scope closed "$(long_ago)"
    run_reap --reap

    [ "$(verdict_of gp-scope)" = "keep-unmerged" ] ||
        fail "a conventional-commit scope must not anchor a match; got '$(verdict_of gp-scope)'"
    [ -d "$wt" ] || fail "a tree was reaped on a scope mistaken for a work reference"
    grep -Fq 'no work reference' <<<"$OUT" ||
        fail "the row must name the anchor as the clause that declined; got: $OUT"
}

test_anchor_refusal_never_claims_the_work_never_landed() {
    # THE gp-psa defect, as distinct from the leak it caused. ml-uoa.3's row
    # read "no same-subject landing there either" while origin/main demonstrably
    # carried one — the anchor had vetoed before the target was ever consulted.
    # A refusal that misreports its own reason reads as the reaper working
    # correctly, which is how a leak survives patrol after patrol unnoticed.
    #
    # `(wip)` is parenthesised and ends the subject but has no internal
    # structure, so it is not a work reference — bare words like it recur across
    # unrelated commits, which is the collision the anchor exists to stop.
    make_world
    land_adjusted polecat/gp-why why.txt 'chore: tidy up (wip)' >/dev/null

    local wt
    wt=$(add_tree agentA gp-why polecat/gp-why)
    bead gp-why closed "$(long_ago)"

    # The premise that makes the misreport a misreport: the subject IS there.
    local mb
    mb=$(git -C "$wt" merge-base HEAD origin/main)
    [ "$(git -C "$wt" log "$mb..origin/main" --no-merges --format=%s | grep -Fxc 'chore: tidy up (wip)')" -eq 1 ] ||
        fail "fixture is wrong: the target must carry the identical subject"

    run_reap

    [ "$(verdict_of gp-why)" = "keep-unmerged" ] ||
        fail "a bare-word trailer must not anchor a match; got '$(verdict_of gp-why)'"
    grep -Fq 'no work reference' <<<"$OUT" ||
        fail "the row must name the anchor as the clause that declined; got: $OUT"
    ! grep -Fq 'genuinely unpublished' <<<"$OUT" ||
        fail "the row claims the work never landed while the subject IS on the target — the gp-psa misreport"
}

test_duplicate_subjects_need_a_landing_each() {
    # Two commits, one subject, one landing. Existence-checking the subject
    # clears both and loses the second commit; counting per distinct subject
    # refuses. The tree holds it twice, the target holds it once.
    make_world
    git_c checkout --quiet -b polecat/gp-dup origin/main
    echo "one" >"$REPO/dup1.txt"
    commit_all "feat: repeated step (gp-dup)"
    echo "two" >"$REPO/dup2.txt"
    commit_all "feat: repeated step (gp-dup)"
    git_c checkout --quiet main
    echo "meanwhile" >>"$REPO/README.md"
    commit_all "chore: unrelated main advance"
    echo "one (adjusted)" >"$REPO/dup1.txt"
    commit_all "feat: repeated step (gp-dup)"
    git_c push --quiet origin main
    git_c fetch --quiet origin main

    local wt
    wt=$(add_tree agentA gp-dup polecat/gp-dup)
    bead gp-dup closed "$(long_ago)"
    run_reap --reap

    [ "$(verdict_of gp-dup)" = "keep-unmerged" ] ||
        fail "two same-subject commits must not be cleared by one landing; got '$(verdict_of gp-dup)'"
    [ -f "$wt/dup2.txt" ] || fail "the commit that never landed was destroyed"
}

test_unreadable_origin_branch_state_refuses_the_subject_path() {
    # `ls-remote --exit-code` returns 2 for "no such ref" and something else for
    # a transport failure. Collapsing the two would read an offline run as "every
    # branch was deleted" — and since C6b REQUIRES that signal, that fail-open
    # would reap adjusted-landing trees on no merge evidence at all.
    make_world
    land_adjusted polecat/gp-off offline.txt >/dev/null

    local wt
    wt=$(add_tree agentA gp-off polecat/gp-off)
    bead gp-off closed "$(long_ago)"

    # Reachable first: proves the world is otherwise reapable, so the refusal
    # below is unambiguously the unreadable branch state.
    run_reap
    [ "$(verdict_of gp-off)" = "reap" ] ||
        fail "precondition: this world must reap while origin is reachable; got '$(verdict_of gp-off)'"

    rm -rf "$ORIGIN"
    run_reap --reap

    [ "$(verdict_of gp-off)" = "keep-unmerged" ] ||
        fail "an unreadable origin must keep the tree, not read as 'branch deleted'; got '$(verdict_of gp-off)'"
    [ -d "$wt" ] || fail "a tree was reaped while the merge signal was unmeasurable"
}

test_keep_unmerged_says_which_signal_declined() {
    # Why the leak stayed invisible for three cycles: `keep-unmerged` is a
    # refusal verdict and refusals are supposed to be common, so a genuinely
    # unpublished tree and a tree the reaper simply could not recognise printed
    # the identical row. They must now read differently.
    #
    # gp-qmd: this tree really IS the only copy — nothing was ever pushed — so
    # the row must say so. It used to say it by ASSERTING "work looks genuinely
    # unpublished" from a walk of the target, which was right here and wrong on
    # any tree whose branch was still on origin. The claim is now measured
    # against origin, and the row reports what the measurement found.
    make_world
    git_c checkout --quiet -b polecat/gp-never origin/main
    echo "unpushed" >"$REPO/never.txt"
    commit_all "feat: never landed (gp-never)"
    git_c checkout --quiet main

    add_tree agentA gp-never polecat/gp-never >/dev/null
    bead gp-never closed "$(long_ago)"
    run_reap

    grep -Fq 'only copy' <<<"$OUT" ||
        fail "a tree that really is the only copy must say so; got: $OUT"
    grep -Fq 'subject check declined' <<<"$OUT" ||
        fail "the row must still name the clause that declined; got: $OUT"
}

# --- gp-qmd/gp-98n: the tree no predicate could ever satisfy -----------------
# C6 and C6b both answer "did this reach the target?", a proxy for the question
# reaping turns on — "is this directory still the only copy?". For work that is
# never going to the target the proxy can NEVER be satisfied, so the tree leaks
# permanently and the refusal asserted something false about it.
#
# gp-qmd read that class off the bead's recall flags. gp-98n stopped: the flags
# name only two of the ways a bead becomes terminal, and the tree measured below
# is collected on what is ON ORIGIN, whatever the bead says about why.

test_published_tree_is_collected_whatever_the_disposition() {
    # THE leak, in the shape that outlived the first fix. meety-local/ml-apes,
    # mayor-verified 2026-08-04: closed 2026-08-03, clean, DETACHED head at
    # 5a88f5e, `gc.work_outcome=abandoned`, and NEITHER recall flag — with
    # origin carrying refs/heads/polecat/ml-apes at that identical sha. 55M of
    # provably-redundant disk that C6c's recall conjunct vetoed.
    #
    # No metadata is stamped here at all beyond what `bead` writes: that is the
    # point. The clearance must come from the measurement, not from a
    # disposition this script has to know how to spell.
    make_world
    git_c checkout --quiet -b polecat/gp-aband origin/main
    echo "abandoned work" >"$REPO/abandoned.txt"
    commit_all "feat: built, then abandoned (gp-aband)"
    push_branch polecat/gp-aband
    git_c checkout --quiet main

    local wt
    wt=$(add_tree agentA gp-aband polecat/gp-aband)
    # Detached, like the live tree: the polecat's submit step leaves it this way,
    # so publication must be measured against HEAD rather than a checked-out
    # branch name.
    git -C "$wt" checkout --quiet --detach HEAD

    # Every premise, or this passes through a path it is not testing.
    [ -n "$(git -C "$wt" cherry origin/main HEAD | grep '^+' || true)" ] ||
        fail "fixture is wrong: the abandoned commit must be missing from the target"
    [ "$(git -C "$wt" rev-parse HEAD)" = \
      "$(git_c ls-remote origin refs/heads/polecat/gp-aband | awk '{print $1}')" ] ||
        fail "fixture is wrong: origin must carry this tree's HEAD under its own branch"
    [ -z "$(git -C "$wt" symbolic-ref -q HEAD || true)" ] ||
        fail "fixture is wrong: the tree must be detached, like the measured one"

    bead gp-aband closed "$(long_ago)"
    run_reap

    [ "$(verdict_of gp-aband)" = "reap" ] ||
        fail "a published tree must be collectable with no recall flag at all; got '$(verdict_of gp-aband)' / rows: $OUT"
    grep -Fq 'redundant' <<<"$OUT" ||
        fail "the evidence must say the tree is redundant; got: $OUT"
    # The wording pin: C6c reaps on a WEAKER guarantee than the merge paths and
    # the row must not let `reap` be read as "this landed". An operator who
    # believes the work merged will not go looking for it on origin.
    ! grep -Fq 'landed on origin/main' <<<"$OUT" ||
        fail "a publication reap must not claim the work reached the target; got: $OUT"
    grep -Fq 'published: origin/polecat/gp-aband' <<<"$OUT" ||
        fail "the evidence must name the measurement that cleared it; got: $OUT"

    run_reap --reap
    [ ! -d "$wt" ] || fail "the tree was not actually removed"
}

test_recall_is_context_on_the_row_not_the_authorisation() {
    # meety-local/ml-94dh: the case gp-qmd measured, closed 2026-07-31 with
    # do_not_merge, recalled_by_owner AND `gc.work_outcome=no-op`, its branch on
    # origin at the identical sha. It is still collected — but the flag must no
    # longer be what does it, or the next terminal disposition nobody thought to
    # enumerate leaks exactly as ml-apes did.
    make_world
    git_c checkout --quiet -b polecat/gp-recall origin/main
    echo "recalled work" >"$REPO/recalled.txt"
    commit_all "feat: built before the recall was read (gp-recall)"
    push_branch polecat/gp-recall
    git_c checkout --quiet main

    local wt
    wt=$(add_tree agentA gp-recall polecat/gp-recall)
    bead gp-recall closed "$(long_ago)"

    # The flip gp-98n is: publication clears this BEFORE any flag is read.
    run_reap
    [ "$(verdict_of gp-recall)" = "reap" ] ||
        fail "publication alone must collect this tree; got '$(verdict_of gp-recall)'"
    ! grep -Fq 'terminal-and-will-never-merge' <<<"$OUT" ||
        fail "with no flag set the row must not claim a recall; got: $OUT"

    # With the flag, the same verdict — plus the context. Losing this note would
    # be invisible: the verdict does not change, so only the row does.
    set_meta_json gp-recall do_not_merge true
    run_reap
    [ "$(verdict_of gp-recall)" = "reap" ] ||
        fail "a recall must not change the verdict; got '$(verdict_of gp-recall)'"
    grep -Fq 'terminal-and-will-never-merge (do_not_merge)' <<<"$OUT" ||
        fail "the row must carry the recall as context; got: $OUT"

    run_reap --reap
    [ ! -d "$wt" ] || fail "the tree was not actually removed"
}

test_recall_alone_never_destroys_the_only_copy() {
    # The cheap version of this fix — "treat do_not_merge on a closed bead as
    # terminal, so keep-unmerged is skipped outright" — deletes the only copy of
    # a recalled bead whose branch was never pushed. "Do not merge" is not
    # "destroy", and a flag on a bead is not evidence about what is on disk.
    #
    # gp-98n makes this MORE load-bearing rather than less. The disposition is no
    # longer half of a conjunction that publication would have vetoed anyway; it
    # is read only for the row. So the only thing standing between this tree and
    # deletion is the measurement, and a future "the bead says it is terminal, so
    # just skip the refusal" shortcut has nothing left to catch it but this test.
    make_world
    git_c checkout --quiet -b polecat/gp-onlycopy origin/main
    echo "the only copy" >"$REPO/onlycopy.txt"
    commit_all "feat: never pushed anywhere (gp-onlycopy)"
    git_c checkout --quiet main

    local wt
    wt=$(add_tree agentA gp-onlycopy polecat/gp-onlycopy)
    bead gp-onlycopy closed "$(long_ago)"
    set_meta_json gp-onlycopy do_not_merge true
    set_meta_json gp-onlycopy recalled_by_owner true
    run_reap --reap

    [ "$(verdict_of gp-onlycopy)" = "keep-unmerged" ] ||
        fail "a recalled bead with nothing on origin must be kept; got '$(verdict_of gp-onlycopy)'"
    [ -d "$wt" ] || fail "recall alone destroyed a tree holding the only copy"
    [ -f "$wt/onlycopy.txt" ] || fail "the only copy of the recalled work is gone"
    grep -Fq 'operator disposition needed' <<<"$OUT" ||
        fail "an uncollectable tree must ask for disposition, not read as a merge still pending; got: $OUT"
}

test_a_deleted_origin_branch_is_not_a_publication() {
    # The hazard gp-98n's widening introduces, and the reason publication is a
    # LIVE `ls-remote` rather than a look at `refs/remotes/origin/*`. Once
    # publication alone collects a tree, a stale remote-tracking ref left behind
    # by a branch that origin no longer has would authorise deleting the only
    # copy of work — reading a ref that says where origin USED to be as evidence
    # about where it is now.
    #
    # The branch here is pushed, fetched (so the tracking ref exists locally),
    # then deleted from origin, and the work never landed. Every copy is in this
    # directory.
    make_world
    git_c checkout --quiet -b polecat/gp-gone origin/main
    echo "the only copy" >"$REPO/gone.txt"
    commit_all "feat: pushed, then unpushed (gp-gone)"
    push_branch polecat/gp-gone
    git_c fetch --quiet origin
    # Deleted ON ORIGIN rather than via `push --delete`, which would prune this
    # clone's tracking ref as a side effect and leave nothing stale to be fooled
    # by. Another machine's cleanup is what actually produces this state.
    git -C "$ORIGIN" update-ref -d refs/heads/polecat/gp-gone
    git_c checkout --quiet main

    local wt
    wt=$(add_tree agentA gp-gone polecat/gp-gone)

    # The premise that makes this a test and not a tautology: the stale tracking
    # ref really is still here, pointing at the tree's work.
    [ "$(git_c rev-parse refs/remotes/origin/polecat/gp-gone 2>/dev/null)" \
      = "$(git -C "$wt" rev-parse HEAD)" ] ||
        fail "fixture is wrong: the stale remote-tracking ref must survive the delete"
    [ -z "$(git_c ls-remote origin refs/heads/polecat/gp-gone)" ] ||
        fail "fixture is wrong: origin must no longer carry the branch"

    bead gp-gone closed "$(long_ago)"
    run_reap --reap

    [ "$(verdict_of gp-gone)" = "keep-unmerged" ] ||
        fail "a deleted origin branch must not publish a tree; got '$(verdict_of gp-gone)'"
    [ -d "$wt" ] || fail "a tree was reaped on a stale remote-tracking ref"
    [ -f "$wt/gone.txt" ] || fail "the only copy of the unlanded work is gone"
    grep -Fq 'only copy' <<<"$OUT" ||
        fail "the row must say this tree may hold the only copy; got: $OUT"
}

test_publication_requires_origin_to_contain_head() {
    # A pushed branch is not a published HEAD. If the tree carries commits past
    # the tip origin has, those commits exist nowhere else — and a check that
    # merely asked "does this branch exist on origin?" would clear them. This is
    # why containment is tested against HEAD: every commit `git cherry` flags is
    # reachable from it, so one ancestry test covers all of them.
    make_world
    git_c checkout --quiet -b polecat/gp-ahead origin/main
    echo "pushed part" >"$REPO/ahead.txt"
    commit_all "feat: the pushed part (gp-ahead)"
    push_branch polecat/gp-ahead
    git_c checkout --quiet main

    local wt
    wt=$(add_tree agentA gp-ahead polecat/gp-ahead)
    # A further commit that lives ONLY here, leaving the tree clean so C5 passes
    # and the refusal below is unambiguously the publication check.
    echo "never pushed" >"$wt/unpushed.txt"
    git -C "$wt" add -A
    git -C "$wt" commit --quiet -m "feat: the unpushed part (gp-ahead)"

    bead gp-ahead closed "$(long_ago)"
    run_reap --reap

    [ "$(verdict_of gp-ahead)" = "keep-unmerged" ] ||
        fail "a tree ahead of its published tip must be kept; got '$(verdict_of gp-ahead)'"
    [ -d "$wt" ] || fail "a tree holding commits found nowhere else was reaped"
    [ -f "$wt/unpushed.txt" ] || fail "the only copy of the unpushed commit is gone"
    grep -Fq 'does NOT contain this tree' <<<"$OUT" ||
        fail "the row must say origin does not carry this HEAD; got: $OUT"

    # The gp-qmd wording defect, pinned on the refusals that outlived it. The row
    # used to end "work looks genuinely unpublished" — a claim about ORIGIN
    # inferred from a walk of the TARGET, and the sentence an operator reads when
    # deciding whether removing a tree is safe. Every refusal must report what it
    # MEASURED against origin instead, including a partial publication like this
    # one, where saying either "published" or "unpublished" would mislead.
    ! grep -Fq 'genuinely unpublished' <<<"$OUT" ||
        fail "the row asserts publication it did not measure — the gp-qmd defect; got: $OUT"
    grep -Fq "origin/polecat/gp-ahead is at" <<<"$OUT" ||
        fail "the row must report the MEASURED publication state; got: $OUT"
}

test_publication_binds_to_the_exact_ref_not_a_pattern_match() {
    # `ls-remote --heads origin polecat/gp-x` matches a PATTERN against the tail
    # of a ref path on slash boundaries, so `refs/heads/decoy/polecat/gp-x`
    # matches it too — and the output is sorted by refname, so the decoy is
    # returned FIRST. Reading the tip positionally therefore binds publication to
    # a ref this bead does not own. Here the bead's own branch was never pushed,
    # so the tree holds the only copy under its own name, and a decoy carrying
    # the same commit must not clear it.
    make_world
    git_c checkout --quiet -b polecat/gp-decoy origin/main
    echo "only copy under its own name" >"$REPO/decoy.txt"
    commit_all "feat: pushed only under a decoy ref (gp-decoy)"
    # The same commit under a ref whose tail matches the bead's branch but which
    # is emphatically not it.
    git_c push --quiet origin polecat/gp-decoy:refs/heads/decoy/polecat/gp-decoy
    git_c checkout --quiet main

    local wt
    wt=$(add_tree agentA gp-decoy polecat/gp-decoy)

    # Both premises, or this passes through a path it is not testing.
    [ -z "$(git_c ls-remote origin refs/heads/polecat/gp-decoy)" ] ||
        fail "fixture is wrong: the bead's own branch must NOT be on origin"
    [ "$(git_c ls-remote --heads origin polecat/gp-decoy | awk 'NR == 1 { print $2 }')" \
      = "refs/heads/decoy/polecat/gp-decoy" ] ||
        fail "fixture is wrong: the decoy must be the first ref the pattern returns"

    bead gp-decoy closed "$(long_ago)"
    run_reap --reap

    [ "$(verdict_of gp-decoy)" = "keep-unmerged" ] ||
        fail "a decoy ref must never publish a tree; got '$(verdict_of gp-decoy)'"
    [ -d "$wt" ] || fail "a tree was reaped on the strength of a ref its bead does not own"
    [ -f "$wt/decoy.txt" ] || fail "the only copy under the bead's own branch is gone"
    grep -Fq 'NOT measured' <<<"$OUT" ||
        fail "an unresolvable exact ref must read as NOT measured, not as unpublished; got: $OUT"
}

test_recall_flags_are_read_in_both_json_spellings() {
    # Production writes real JSON booleans (ml-94dh: `"do_not_merge":true`),
    # while a hand stamp or a tool round-trip can yield the string "true". A
    # reader matching one spelling passes every test written the same way and
    # does nothing at all live. The `"false"` cases are the sharper hazard: a jq
    # truthiness test reads the non-empty string "false" as a recall.
    #
    # Since gp-98n this decides a ROW, not a verdict — which makes it easier to
    # break unnoticed, not harder, because a regression changes nothing an
    # operator greps for. The tree below is kept either way: unpublished, so the
    # only question is whether its refusal says a human must dispose of it or
    # leaves it reading as a merge still pending, forever.
    make_world
    git_c checkout --quiet -b polecat/gp-spell origin/main
    echo "spelled" >"$REPO/spell.txt"
    commit_all "feat: recalled work (gp-spell)"
    git_c checkout --quiet main
    add_tree agentA gp-spell polecat/gp-spell >/dev/null
    bead gp-spell closed "$(long_ago)"

    local spelling
    for spelling in true '"true"'; do
        set_meta_json gp-spell recalled_by_owner "$spelling"
        run_reap
        [ "$(verdict_of gp-spell)" = "keep-unmerged" ] ||
            fail "an unpublished tree must be kept whatever the flag says; got '$(verdict_of gp-spell)'"
        grep -Fq 'operator disposition needed' <<<"$OUT" ||
            fail "recalled_by_owner=$spelling must be read as a recall; got: $OUT"
    done

    for spelling in false '"false"'; do
        set_meta_json gp-spell recalled_by_owner "$spelling"
        run_reap
        [ "$(verdict_of gp-spell)" = "keep-unmerged" ] ||
            fail "the verdict must not move with the flag; got '$(verdict_of gp-spell)'"
        ! grep -Fq 'operator disposition needed' <<<"$OUT" ||
            fail "recalled_by_owner=$spelling must NOT be read as a recall; got: $OUT"
    done
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

# --- gp-dgu: a kept tree still has to be triageable -------------------------
# C5's refusal is correct and permanent, which is the problem: on a closed,
# unassigned bead whose polecat is gone it prints the same `keep-dirty` row
# forever, indistinguishable from a tree dirty for a boring reason. Measured on
# meety-local (2026-08-03), ml-cmai carried 31 staged blobs on NEITHER HEAD nor
# origin/main — main.py, api.ts, three test files — behind a row that read like
# garbage, one "clean up the old worktrees" reflex away from being destroyed.
#
# So these pin the SPLIT in both directions. Pinning only the alarm would let a
# reaper that shouted on every dirty tree pass, which reproduces the original
# defect with a louder word: an eternal row nobody can triage.
#
# They also pin, twice, that the split stays a REPORT. The reachability answer is
# exactly the line between a tree that is safe to drop and one that is not, which
# is precisely why it must never become a licence to drop one.

test_staged_content_on_no_ref_is_orphaned_not_dirty() {
    make_world
    local wt
    wt=$(add_tree agentA gp-orphan)
    stage_blob "$wt" secret.py "the only copy of this content in the world"
    bead gp-orphan closed "$(long_ago)"
    run_reap

    [ "$(verdict_of gp-orphan)" = "keep-orphaned" ] ||
        fail "staged content on neither HEAD nor the target must be distinguishable from routine dirt; got '$(verdict_of gp-orphan)'"
    grep -Fq '1 staged blob(s) on NEITHER HEAD nor origin/main' <<<"$(detail_of gp-orphan)" ||
        fail "the row must say how much content is at risk and against what; got '$(detail_of gp-orphan)'"
}

test_orphaned_tree_survives_reap_mode() {
    # The whole point of the bead: RECLASSIFY, DO NOT COLLECT. A new verdict that
    # also became a new authorisation to delete would be strictly worse than the
    # eternal keep-dirty it replaced.
    make_world
    local wt
    wt=$(add_tree agentA gp-orphan)
    stage_blob "$wt" secret.py "the only copy of this content in the world"
    bead gp-orphan closed "$(long_ago)"
    run_reap --reap

    [ "$(verdict_of gp-orphan)" = "keep-orphaned" ] ||
        fail "--reap must not change the verdict; got '$(verdict_of gp-orphan)'"
    [ -d "$wt" ] || fail "an orphaned tree was REAPED — the report became an authorisation"
    [ -f "$wt/secret.py" ] || fail "the unreachable content was destroyed"
}

test_staged_content_already_on_a_ref_stays_routine_dirty() {
    # The discriminating case. This blob is staged at a path that exists on no
    # ref, but its CONTENT is byte-identical to README.md on the target — so
    # deleting the tree loses nothing, and the row must not cry orphan.
    # Reachability is asked tree-wide rather than per-path for exactly this
    # reason: a moved file is not lost content.
    make_world
    local wt
    wt=$(add_tree agentA gp-copy)
    stage_blob "$wt" copy.md "# base"
    bead gp-copy closed "$(long_ago)"
    run_reap

    [ "$(verdict_of gp-copy)" = "keep-dirty" ] ||
        fail "staged content already carried by a surviving ref is routine; got '$(verdict_of gp-copy)' / $(detail_of gp-copy)"
    grep -Fq 'already on HEAD or origin/main' <<<"$(detail_of gp-copy)" ||
        fail "the routine row must state what it cleared; got '$(detail_of gp-copy)'"
}

test_staged_deletions_alone_are_not_unreachable_content() {
    # 28 of ml-cmai's 59 staged paths were deletions. A deletion removes bytes
    # that are still on the ref it was deleted from, so counting it as content at
    # risk would raise an alarm on every tree that ever staged a `git rm`.
    make_world
    local wt
    wt=$(add_tree agentA gp-del)
    stage_deletion "$wt" README.md
    bead gp-del closed "$(long_ago)"
    run_reap

    [ "$(verdict_of gp-del)" = "keep-dirty" ] ||
        fail "a staged deletion destroys no content and must stay routine; got '$(verdict_of gp-del)' / $(detail_of gp-del)"
}

test_untracked_only_dirt_does_not_claim_the_worktree_was_priced() {
    # The probe reads the INDEX only. A tree dirty purely with untracked files is
    # correctly routine by that measure, but the row must not let "routine" be
    # read as "safe to delete" when the untracked side was never measured.
    make_world
    local wt
    wt=$(add_tree agentA gp-scratch)
    echo "uncommitted" >"$wt/scratch.txt"
    bead gp-scratch closed "$(long_ago)"
    run_reap

    [ "$(verdict_of gp-scratch)" = "keep-dirty" ] ||
        fail "untracked-only dirt is routine by the index measure; got '$(verdict_of gp-scratch)'"
    grep -Fq 'worktree-side content not priced' <<<"$(detail_of gp-scratch)" ||
        fail "the row must admit what it did NOT measure; got '$(detail_of gp-scratch)'"
}

test_unmeasurable_index_never_reads_as_routine() {
    # Half a reachable universe would report blobs that ARE on the target as
    # existing nowhere. Refusing to measure is right; reporting the refusal as
    # routine is the gp-dgu defect in a new place, so it escalates and names why.
    make_world
    local wt
    wt=$(add_tree agentA gp-noref)
    stage_blob "$wt" secret.py "content whose reachability cannot be judged"
    bead gp-noref closed "$(long_ago)"
    set_meta gp-noref target nonexistent-branch
    run_reap

    [ "$(verdict_of gp-noref)" = "keep-orphaned" ] ||
        fail "an unmeasurable index must not read as routine; got '$(verdict_of gp-noref)'"
    grep -Fq 'NOT measured' <<<"$(detail_of gp-noref)" ||
        fail "the row must name that it abstained rather than imply content at risk; got '$(detail_of gp-noref)'"
    grep -Fq 'origin/nonexistent-branch' <<<"$(detail_of gp-noref)" ||
        fail "the row must name the ref that failed to resolve; got '$(detail_of gp-noref)'"
}

test_orphaned_row_carries_the_triage_fields() {
    # "closed 3d, no owner, N staged" — the operator has to decide whether to go
    # looking for whoever left this here, and a bare path does not answer that.
    make_world
    local wt
    wt=$(add_tree agentA gp-triage)
    stage_blob "$wt" secret.py "unique content"
    bead gp-triage closed "$(long_ago)"
    run_reap

    local d
    d=$(detail_of gp-triage)
    grep -Fq 'closed 3h' <<<"$d" || fail "the row must date the closure; got '$d'"
    grep -Fq 'no owner' <<<"$d" || fail "the row must say whether anyone is left to ask; got '$d'"
    grep -Fq '1 staged' <<<"$d" || fail "the row must size the staged set; got '$d'"
}

test_orphaned_row_is_a_finding_not_a_clean_sweep() {
    # Exit 0 is documented as "nothing to report". An escalation that exits 0 is
    # an escalation nobody reads — the patrol's own step treats 0 as "reported
    # nothing to do" and moves on.
    make_world
    local wt
    wt=$(add_tree agentA gp-orphan)
    stage_blob "$wt" secret.py "the only copy"
    bead gp-orphan closed "$(long_ago)"
    run_reap

    [ "$RC" -eq 1 ] ||
        fail "an orphaned tree is a finding and must exit 1, got $RC"
    grep -Fq 'orphaned=1' <<<"$ERR" ||
        fail "the summary must count orphaned trees so a patrol can act on them; got '$ERR'"
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
    # The header is extracted by shape rather than a line range, so this also
    # pins that the whole block still prints: 'C6b' is near the top and
    # 'Usage' is the last section, and a truncating extractor drops one of them.
    grep -Fq 'C6b' <<<"$OUT" || fail "--help must explain why patch-id alone is not enough"
    grep -Fq 'Usage:' <<<"$OUT" || fail "--help must reach the end of the header block"
    # One comment marker is stripped, so prose starts at column 0 (the `## `
    # section headings keep theirs, which is what makes the output readable).
    grep -q '^Exit codes:' <<<"$OUT" ||
        fail "--help must strip the leading comment marker, not print raw source"
    ! grep -Fq 'set -euo pipefail' <<<"$OUT" ||
        fail "--help must stop at the end of the header, not spill code"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
    "$t"
    echo "ok - $t"
done

echo "All polecat-worktree-reap tests passed."
