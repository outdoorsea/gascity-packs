#!/usr/bin/env bash
# Exercises assets/scripts/deploy-check.sh — the assertion that a merged commit
# is actually LIVE, not merely authored.
#
# The bug this guards (gp-apx, follow-up to gp-9pa): closing a pack bead proves
# the patch is an ancestor of the target branch and nothing more. A city runs a
# commit pinned in packs.lock, and advancing that pin is a separate act. So
# gp-haf, gp-dlq and gp-px5 were all closed while still live as bugs, and read
# exactly like the beads beside them that were genuinely fixed.
#
# Every fixture here is a real git repo, so the ancestry assertions are answered
# by git rather than by a mock that could agree with a broken implementation.
#
# What is nailed down:
#   1. Both conjuncts are required. Pin-contains-fix alone is NOT deployed
#      (the gp-9pa install-skew shape), and neither is a fix ahead of the pin
#      (the gp-px5 shape).
#   2. The two misses are told apart, because their remediations differ.
#   3. It fails CLOSED. No missing tool, unset variable or unreadable pin may
#      ever produce `deployed`.
#   4. `not_applicable` is decided on evidence and is silent — an ordinary
#      application rig gets no deployment noise on its closes.
#   5. URL normalization matches the shapes that actually occur, because a miss
#      lands in `not_applicable`, which is a SILENT pass.
#   6. A close is never broken: a failed stamp still yields its reason suffix.
#   7. The headline regression — a deployed and an undeployed close no longer
#      produce the same close reason.
#   8. Recorded commit ids are the resolved 40-char object name, never the
#      abbreviation handed in. A 7-char short SHA of the shape ^[0-9]+e[0-9]+$
#      is valid scientific notation, so a metadata writer stores it as a float
#      and the id is destroyed — 1 in 53 short SHAs (gp-prt). An id that will
#      not resolve is not recorded as a commit at all.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
CHECK="$ROOT/gastown/assets/scripts/deploy-check.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# `gc` stub. Serves `gc import status --json` from a file so a test can shape the
# city's pins, and records every mutation as one line in $GC_LOG so assertions
# can check what was stamped. GC_STAMP_FAIL makes `gc bd update` fail, which is
# how the "a broken stamp must not break the close" contract is proven.
write_gc_stub() {
    cat >"$1/gc" <<'SH'
#!/usr/bin/env sh
case "gc $1 $2" in
    "gc import status")
        [ -n "${GC_IMPORTS_JSON:-}" ] || exit 1
        cat "$GC_IMPORTS_JSON"
        exit 0
        ;;
    "gc bd update")
        printf 'gc %s\n' "$*" >>"$GC_LOG"
        [ -z "${GC_STAMP_FAIL:-}" ] || exit 1
        exit 0
        ;;
esac
printf 'gc %s\n' "$*" >>"$GC_LOG"
exit 0
SH
    chmod +x "$1/gc"
}

# A pack-source repo with three commits, plus a clone standing in for the
# installed artifact.
#
#   BASE_SHA   an old commit
#   FIX_SHA    the commit under test — "the fix"
#   AHEAD_SHA  a commit after the fix
#
# GC_PACK_DIR is set to "$PACK/gastown", a SUBDIRECTORY of the clone, because
# that is the production shape (packs materialize as <clone>/<packname>). A check
# that only worked when pointed at a clone root would pass a naive fixture and
# fail in every real city.
new_sandbox() {
    SANDBOX=$(mktemp -d)
    BIN="$SANDBOX/bin"
    mkdir -p "$BIN"
    write_gc_stub "$BIN"
    GC_LOG="$SANDBOX/gc.log"
    : >"$GC_LOG"
    # Exported, not just set: the stub runs in a child process and appends to
    # $GC_LOG there. Leaving it unexported makes every mutation assertion read an
    # empty log, which passes the "must NOT have happened" checks vacuously.
    export GC_LOG
    unset GC_IMPORTS_JSON GC_STAMP_FAIL GC_PACK_DIR GC_RIG_ROOT

    REPO="$SANDBOX/repo"
    git init -q "$REPO"
    git -C "$REPO" config user.email t@example.com
    git -C "$REPO" config user.name Tester
    git -C "$REPO" remote add origin https://github.com/acme/packs.git
    mkdir -p "$REPO/gastown"

    echo base >"$REPO/gastown/formula.toml"
    git -C "$REPO" add -A
    git -C "$REPO" commit -qm base
    BASE_SHA=$(git -C "$REPO" rev-parse HEAD)

    echo fixed >"$REPO/gastown/formula.toml"
    git -C "$REPO" commit -qam "the fix"
    FIX_SHA=$(git -C "$REPO" rev-parse HEAD)

    echo later >"$REPO/gastown/formula.toml"
    git -C "$REPO" commit -qam "after the fix"
    AHEAD_SHA=$(git -C "$REPO" rev-parse HEAD)

    PACK="$SANDBOX/pack"
    git clone -q "$REPO" "$PACK"
    GC_PACK_DIR="$PACK/gastown"
}

# Point the installed artifact at $1.
install_pack_at() {
    git -C "$PACK" checkout -q --detach "$1"
}

# Declare the city's imports: one import of $2 (a source URL) pinned at $1.
declare_pin() {
    GC_IMPORTS_JSON="$SANDBOX/imports.json"
    cat >"$GC_IMPORTS_JSON" <<JSON
{"imports":[{"name":"pack:gastown",
             "source":"${2:-https://github.com/acme/packs/tree/$1/gastown}",
             "pin":{"commit":"$1"}}]}
JSON
    export GC_IMPORTS_JSON
}

# Run the check. Extra args pass through. Captures stdout, stderr and status.
run_check() {
    OUT_FILE="$SANDBOX/out"
    ERR_FILE="$SANDBOX/err"
    PATH="$BIN:$PATH" GC_PACK_DIR="${GC_PACK_DIR:-}" GC_CITY="$SANDBOX/city" \
        bash "$CHECK" "$@" --repo "$REPO" >"$OUT_FILE" 2>"$ERR_FILE"
    STATUS=$?
    OUT=$(cat "$OUT_FILE")
    ERR=$(cat "$ERR_FILE")
}

# Read one key= value from whichever stream carries the evidence.
evidence() {
    printf '%s\n%s\n' "$OUT" "$ERR" | sed -n "s/^$1=//p" | head -1
}

assert_status() {
    [ "$STATUS" = "$1" ] ||
        fail "$3: expected exit $1, got $STATUS (out: $OUT | err: $ERR)"
    [ "$(evidence deploy_status)" = "$2" ] ||
        fail "$3: expected deploy_status=$2, got '$(evidence deploy_status)'"
}

# The shape that destroys a SHA: simultaneously valid hex and valid scientific
# notation, so a type-inferring metadata writer stores it as a float.
coerces_to_a_number() {
    [[ "$1" =~ ^[0-9]+[eE][0-9]+$ ]]
}

# Read the value stamped for a metadata key out of the gc stub's call log.
stamped() {
    sed -n "s/.*--set-metadata $1=\([^ ]*\).*/\1/p" "$GC_LOG" | head -1
}

test_both_conjuncts_present_is_deployed() {
    # The control for every negative test below. Without this, an implementation
    # that never returns `deployed` would satisfy all of them.
    new_sandbox
    install_pack_at "$AHEAD_SHA"
    declare_pin "$AHEAD_SHA"

    # Non-vacuity: the fix really is an ancestor of the pin here.
    git -C "$REPO" merge-base --is-ancestor "$FIX_SHA" "$AHEAD_SHA" ||
        fail "fixture is wrong: the fix must be contained in this pin"

    run_check "$FIX_SHA"
    assert_status 0 deployed "deployed"
    [ "$(evidence deploy_pin)" = "$AHEAD_SHA" ] ||
        fail "deployed verdict must record which pin it proved"
}

test_fix_ahead_of_pin_is_authored_not_deployed() {
    # The gp-px5 shape, and the one this whole change exists for: merged, closed,
    # and not running anywhere because the pin never advanced to it.
    new_sandbox
    install_pack_at "$BASE_SHA"
    declare_pin "$BASE_SHA"

    # Non-vacuity: this is a genuine "not contained", not a lookup failure.
    ! git -C "$REPO" merge-base --is-ancestor "$FIX_SHA" "$BASE_SHA" ||
        fail "fixture is wrong: the fix must NOT be contained in this pin"

    run_check "$FIX_SHA"
    assert_status 1 authored_not_deployed "behind"
    case "$(evidence deploy_reason)" in
        *"does not contain"*) : ;;
        *) fail "the reason must say the pin does not contain the fix, got: $(evidence deploy_reason)" ;;
    esac
    # The operator needs the way out, not just the verdict.
    case "$ERR" in
        *"gc import install"*) : ;;
        *) fail "an undeployed verdict must print the remediation, got: $ERR" ;;
    esac
}

test_pin_contains_fix_but_artifact_is_stale() {
    # The gp-9pa shape: conjunct 1 holds, conjunct 2 does not. The pin carries the
    # fix while the artifact agents actually load is older, so the bug is still
    # live. An implementation that checked only the pin would call this deployed —
    # which is precisely how gp-haf stayed live after being closed.
    new_sandbox
    install_pack_at "$BASE_SHA" # artifact behind...
    declare_pin "$AHEAD_SHA"    # ...while the pin already contains the fix

    git -C "$REPO" merge-base --is-ancestor "$FIX_SHA" "$AHEAD_SHA" ||
        fail "fixture is wrong: the pin must contain the fix for this to be a skew test"

    run_check "$FIX_SHA"
    assert_status 1 authored_not_deployed "skew"
    # The two misses must be distinguishable: this one is fixed by installing,
    # the other by advancing the pin.
    case "$(evidence deploy_reason)" in
        *"installed pack is at"*) : ;;
        *) fail "install skew must be reported distinctly from a behind pin, got: $(evidence deploy_reason)" ;;
    esac
}

test_unrelated_repo_is_not_applicable_and_silent() {
    # An ordinary application rig is nobody's pack source. Stamping every one of
    # its closes "not deployed" would be noise that teaches people to ignore the
    # field, so this verdict must be reached AND must add nothing to the reason.
    new_sandbox
    install_pack_at "$AHEAD_SHA"
    declare_pin "$AHEAD_SHA" "https://github.com/acme/some-other-repo/tree/$AHEAD_SHA/gastown"

    run_check "$FIX_SHA"
    assert_status 3 not_applicable "not applicable"

    # And in stamp mode it contributes no suffix at all.
    run_check "$FIX_SHA" --stamp bd-1
    [ -z "$OUT" ] ||
        fail "not_applicable must add no close-reason suffix, got: '$OUT'"
}

test_fails_closed_and_never_reports_deployed() {
    # Each of these is a way the check can be unable to answer. None may read as
    # deployed: a false green recreates the bug, a false red costs one pin check.
    new_sandbox
    declare_pin "$AHEAD_SHA"
    install_pack_at "$AHEAD_SHA"

    # (a) No GC_PACK_DIR — the artifact side is unprovable. This is the exact
    # shape of the wiring bug that shipped four dead checks (gp-fid, gp-px5,
    # gp-3qb): the variable is absent in an agent shell.
    GC_PACK_DIR="" run_check "$FIX_SHA"
    assert_status 2 undetermined "no pack dir"

    # (b) GC_PACK_DIR set but not a git clone (a registry release tarball).
    mkdir -p "$SANDBOX/tarball"
    GC_PACK_DIR="$SANDBOX/tarball" run_check "$FIX_SHA"
    assert_status 2 undetermined "not a clone"

    # (c) The pinned commit is not present in this repo — an unfetched fork or a
    # pruned branch. Unmeasurable, NOT contained.
    new_sandbox
    install_pack_at "$AHEAD_SHA"
    declare_pin 0000000000000000000000000000000000000000
    run_check "$FIX_SHA"
    assert_status 2 undetermined "unresolvable pin"

    # (d) The city's imports cannot be read at all.
    new_sandbox
    install_pack_at "$AHEAD_SHA"
    unset GC_IMPORTS_JSON
    run_check "$FIX_SHA"
    assert_status 2 undetermined "unreadable imports"

    # (e) The commit under test does not exist in the repo.
    new_sandbox
    install_pack_at "$AHEAD_SHA"
    declare_pin "$AHEAD_SHA"
    run_check 1111111111111111111111111111111111111111
    assert_status 2 undetermined "unknown commit"
}

test_source_url_shapes_all_match_the_same_repo() {
    # A normalization miss does not fail loudly — it lands in `not_applicable`,
    # which is silent. So every URL shape that actually occurs has to match:
    # pack sources carry /tree/<ref>/<subpath>, and remotes come as https with or
    # without .git, or scp-style.
    local url
    for url in \
        "https://github.com/acme/packs/tree/PIN/gastown" \
        "https://github.com/acme/packs.git" \
        "https://github.com/acme/packs" \
        "git@github.com:acme/packs.git" \
        "https://GitHub.com/acme/packs" \
        "https://github.com/acme/packs/blob/PIN/gastown" \
        "https://github.com/acme/packs//gastown" \
        "https://github.com/acme/packs.git//gastown" \
        "https://git:token@github.com/acme/packs.git" \
        "https://github.com/acme/packs/tree/PIN/gastown/"; do
        new_sandbox
        install_pack_at "$AHEAD_SHA"
        declare_pin "$AHEAD_SHA" "${url/PIN/$AHEAD_SHA}"
        run_check "$FIX_SHA"
        [ "$STATUS" = 0 ] ||
            fail "import source '$url' should match origin https://github.com/acme/packs.git, got exit $STATUS / $(evidence deploy_status)"
    done

    # Control: normalization must stay precise rather than matching everything.
    # A prefix-matching bug would make the not_applicable verdict unreachable.
    new_sandbox
    install_pack_at "$AHEAD_SHA"
    declare_pin "$AHEAD_SHA" "https://github.com/acme/packs-extra.git"
    run_check "$FIX_SHA"
    assert_status 3 not_applicable "similar-but-different repo"
}

test_stamp_writes_the_verdict_and_never_breaks_a_close() {
    new_sandbox
    install_pack_at "$BASE_SHA"
    declare_pin "$BASE_SHA"

    run_check "$FIX_SHA" --stamp bd-1
    grep -q "deploy_status=authored_not_deployed" "$GC_LOG" ||
        fail "the verdict must be stamped so it is queryable, log: $(cat "$GC_LOG")"
    grep -q "deploy_commit=$FIX_SHA" "$GC_LOG" ||
        fail "the stamp must record which commit was evaluated"
    # Stamp mode keeps stdout clean for splicing into a close reason.
    case "$OUT" in
        *"AUTHORED, NOT DEPLOYED"*) : ;;
        *) fail "stamp mode must print the close-reason suffix, got: '$OUT'" ;;
    esac
    case "$OUT" in
        *deploy_status=*) fail "stamp mode must keep evidence lines off stdout, got: '$OUT'" ;;
    esac

    # A failed stamp must still yield the suffix. The close it feeds is reporting
    # a merge that already landed; aborting it over a metadata write would strand
    # the work, which is worse than the missing field.
    new_sandbox
    install_pack_at "$BASE_SHA"
    declare_pin "$BASE_SHA"
    GC_STAMP_FAIL=1 run_check "$FIX_SHA" --stamp bd-1
    case "$OUT" in
        *"AUTHORED, NOT DEPLOYED"*) : ;;
        *) fail "a failed stamp must still produce a close-reason suffix, got: '$OUT'" ;;
    esac
}

test_deployed_and_undeployed_closes_are_distinguishable() {
    # The headline regression, stated the way gp-apx states it:
    # "Closed-but-undeployed is currently indistinguishable from fixed."
    # Build both close reasons the way the refinery does and require them to
    # differ, and require the undeployed one to SAY so.
    new_sandbox
    install_pack_at "$AHEAD_SHA"
    declare_pin "$AHEAD_SHA"
    run_check "$FIX_SHA" --stamp bd-live
    local live_reason="Merged to main at ${FIX_SHA:0:7}$OUT"

    new_sandbox
    install_pack_at "$BASE_SHA"
    declare_pin "$BASE_SHA"
    run_check "$FIX_SHA" --stamp bd-dead
    local dead_reason="Merged to main at ${FIX_SHA:0:7}$OUT"

    [ "$live_reason" != "$dead_reason" ] ||
        fail "a deployed and an undeployed close still read identically: '$live_reason'"
    case "$dead_reason" in
        *"NOT DEPLOYED"*) : ;;
        *) fail "the undeployed close reason must say so, got: '$dead_reason'" ;;
    esac
}

test_repo_defaults_to_rig_root_over_cwd() {
    # Precedence is --repo, then GC_RIG_ROOT, then cwd. Preferring the resolved
    # rig root matters because the refinery runs part of its merge from a
    # detached worktree, so cwd is not reliably the repo the commit landed in.
    new_sandbox
    install_pack_at "$AHEAD_SHA"
    declare_pin "$AHEAD_SHA"

    # No --repo, and a cwd that is not a git repo at all: GC_RIG_ROOT must carry
    # it. Run from $SANDBOX, which has no .git.
    local out status
    out=$(cd "$SANDBOX" && PATH="$BIN:$PATH" GC_PACK_DIR="$GC_PACK_DIR" \
        GC_RIG_ROOT="$REPO" GC_IMPORTS_JSON="$GC_IMPORTS_JSON" \
        bash "$CHECK" "$FIX_SHA" 2>&1)
    status=$?
    [ "$status" = 0 ] ||
        fail "GC_RIG_ROOT should resolve the repo when --repo is absent, got exit $status: $out"
}

test_abbreviated_sha_is_recorded_in_full() {
    # gp-prt: `gc gastown deploy-check 6001e55 --stamp <bead>` stamped the
    # abbreviation verbatim, `6001e55` is valid scientific notation, and the
    # record became 6.001e+58 — the commit id unrecoverable from the bead.
    # Abbreviations are a SUPPORTED input (--help demonstrates them), so the fix
    # is at the boundary that records the value: resolve, then stamp.
    new_sandbox
    install_pack_at "$AHEAD_SHA"
    declare_pin "$AHEAD_SHA"

    local short
    short=$(git -C "$REPO" rev-parse --short "$FIX_SHA")
    # Non-vacuity: this has to actually be an abbreviation for the test to mean
    # anything — otherwise it passes against the unfixed script.
    [ -n "$short" ] && [ "${#short}" -lt 40 ] ||
        fail "fixture is wrong: --short returned '$short', not an abbreviation"

    run_check "$short" --stamp bd-1
    assert_status 0 deployed "an abbreviated sha must still reach a verdict"

    local recorded
    recorded=$(stamped deploy_commit)
    [ "$recorded" = "$FIX_SHA" ] ||
        fail "an abbreviated sha must be stamped in full: got '$recorded', want '$FIX_SHA'"
    [ "${#recorded}" = 40 ] ||
        fail "the stamped commit must be a 40-char object name, got ${#recorded} chars"
    ! coerces_to_a_number "$recorded" ||
        fail "the stamped commit still parses as a number: '$recorded'"

    # The evidence stream is normalized identically. A caller grepping stdout
    # must not see a different id than the one the bead records.
    run_check "$short"
    [ "$(evidence deploy_commit)" = "$FIX_SHA" ] ||
        fail "evidence output must carry the full sha, got '$(evidence deploy_commit)'"
}

test_unresolvable_ids_are_never_recorded_as_commits() {
    # The other half of gp-prt. An id that does not resolve is not a commit;
    # stamping it would assert something unverified AND reintroduce the
    # coercion. It goes in deploy_reason instead — prose has no numeric reading
    # — so nothing about the request is lost.
    new_sandbox
    install_pack_at "$AHEAD_SHA"
    declare_pin "$AHEAD_SHA"

    # The literal value from the incident. Non-vacuity: confirm it really does
    # have the destroying shape, so this exercises the live case and not a
    # harmless lookalike.
    coerces_to_a_number 6001e55 ||
        fail "fixture is wrong: 6001e55 must have the shape that coerces"

    run_check 6001e55 --stamp bd-1
    assert_status 2 undetermined "unresolvable sha"
    [ -z "$(stamped deploy_commit)" ] ||
        fail "an unresolved id must not be stamped as a commit, log: $(cat "$GC_LOG")"
    [ -z "$(evidence deploy_commit)" ] ||
        fail "an unresolved id must not appear as deploy_commit evidence"
    case "$(evidence deploy_reason)" in
        *6001e55*) : ;;
        *) fail "the requested id must survive in the reason, got: $(evidence deploy_reason)" ;;
    esac

    # Same rule when there is no repo to resolve against at all. run_check
    # appends its own --repo, so this path is invoked directly.
    mkdir -p "$SANDBOX/not-a-repo"
    local out
    out=$(PATH="$BIN:$PATH" GC_PACK_DIR="$GC_PACK_DIR" \
        bash "$CHECK" 6001e55 --repo "$SANDBOX/not-a-repo" 2>&1)
    case "$out" in
        *deploy_commit=*) fail "with no repo there is nothing to resolve, got: $out" ;;
    esac
    case "$out" in
        *6001e55*) : ;;
        *) fail "the requested id must survive in the reason, got: $out" ;;
    esac
}

test_abbreviated_pin_resolves_and_is_recorded_in_full() {
    # deploy_pin is stamped by the same emit(), from a value read out of the
    # city's imports rather than generated here, so it carries the identical
    # exposure. Resolving it also removes a latent WRONG VERDICT: artifact
    # resolution compares the pin against a 40-char `rev-parse HEAD`, so an
    # abbreviated pin could never match and a genuinely deployed fix was
    # reported as install skew.
    new_sandbox
    install_pack_at "$AHEAD_SHA"

    local short_pin
    short_pin=$(git -C "$REPO" rev-parse --short "$AHEAD_SHA")
    [ "${#short_pin}" -lt 40 ] ||
        fail "fixture is wrong: --short returned a full object name"
    declare_pin "$short_pin"

    run_check "$FIX_SHA" --stamp bd-1
    assert_status 0 deployed "an abbreviated pin must still prove artifact resolution"

    local recorded
    recorded=$(stamped deploy_pin)
    [ "$recorded" = "$AHEAD_SHA" ] ||
        fail "an abbreviated pin must be recorded in full: got '$recorded', want '$AHEAD_SHA'"
    ! coerces_to_a_number "$recorded" ||
        fail "the stamped pin still parses as a number: '$recorded'"

    # And a pin that does not resolve is not recorded as one either — the reason
    # names it in full, because that is the only record the operator gets.
    new_sandbox
    install_pack_at "$AHEAD_SHA"
    declare_pin 0000000000000000000000000000000000000000
    run_check "$FIX_SHA" --stamp bd-1
    assert_status 2 undetermined "unresolvable pin"
    [ -z "$(stamped deploy_pin)" ] ||
        fail "an unresolved pin must not be stamped, log: $(cat "$GC_LOG")"
    case "$(evidence deploy_reason)" in
        *0000000000000000000000000000000000000000*) : ;;
        *) fail "an unresolved pin must be named in full, got: $(evidence deploy_reason)" ;;
    esac
}

test_both_conjuncts_present_is_deployed
test_fix_ahead_of_pin_is_authored_not_deployed
test_pin_contains_fix_but_artifact_is_stale
test_unrelated_repo_is_not_applicable_and_silent
test_fails_closed_and_never_reports_deployed
test_source_url_shapes_all_match_the_same_repo
test_stamp_writes_the_verdict_and_never_breaks_a_close
test_deployed_and_undeployed_closes_are_distinguishable
test_repo_defaults_to_rig_root_over_cwd
test_abbreviated_sha_is_recorded_in_full
test_unresolvable_ids_are_never_recorded_as_commits
test_abbreviated_pin_resolves_and_is_recorded_in_full

echo "PASS: $(basename "${BASH_SOURCE[0]}")"
