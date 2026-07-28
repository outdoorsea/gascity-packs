#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GASTOWN="$ROOT/gastown"
SCRIPT="$GASTOWN/doctor/import-drift/run.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Git needs an identity and a predictable default branch; agent sessions and CI
# runners disagree about both, so pin them for the fixtures rather than
# inheriting whatever the host happens to have configured.
git_q() {
    git -c user.name=test -c user.email=test@example.com -c init.defaultBranch=main \
        -c advice.detachedHead=false "$@" >/dev/null 2>&1
}

# Build an "upstream" repo with a linear history, then clone it and park the
# clone `behind` commits back — the shape of a pinned pack import.
#
# The clone is what GC_PACK_DIR points at, so the fixture reproduces the real
# thing: a full clone with remote refs, detached at the pinned commit.
make_pack_clone() {
    local name="$1" total="$2" behind="$3" packsub="${4:-gastown}"
    local up="$TMP/$name-upstream" clone="$TMP/$name-clone"

    git_q init "$up"
    local i
    for ((i = 1; i <= total; i++)); do
        echo "commit $i" >"$up/file.txt"
        git_q -C "$up" add file.txt
        git_q -C "$up" commit -m "commit $i"
    done

    git_q clone "$up" "$clone"
    local target
    target=$(git -C "$clone" rev-parse "HEAD~$behind" 2>/dev/null)
    git_q -C "$clone" checkout "$target"

    # gc points GC_PACK_DIR at the pack SUBDIRECTORY of the clone
    # (<clone>/gastown), never at the clone root. Fixtures must reproduce that
    # shape: a path bug one level down from the git dir is invisible when the
    # fixture hands the check a repo root.
    mkdir -p "$clone/$packsub"
    printf '%s' "$clone/$packsub"
}

# Mirrors the doctor runner's environment contract exactly: gc passes
# GC_PACK_DIR plus city/pack-state vars, and nothing else. Anything this helper
# adds that gc does not is a way for a bug to pass the suite and still be broken
# in `gc doctor` — so it adds nothing, and scrubs the vars a developer shell
# might be carrying.
run_check() {
    local packdir="$1"
    shift
    env -u GC_PACK_NAME -u GC_PACK_DRIFT_REF GC_PACK_DIR="$packdir" "$@" \
        bash "$SCRIPT" 2>"$TMP/stderr"
}

# --- a pack with no upstream cannot drift ------------------------------------

test_non_git_pack_is_not_applicable() {
    local plain="$TMP/plain-pack"
    mkdir -p "$plain"

    local out rc
    out=$(run_check "$plain") && rc=0 || rc=$?

    [ "$rc" -eq 0 ] || fail "non-git pack should exit 0, got $rc"
    grep -qi "not applicable" <<<"$out" ||
        fail "non-git pack should say drift is not applicable, got: $out"
}

# --- the healthy case ---------------------------------------------------------

test_current_pin_passes() {
    local clone
    clone=$(make_pack_clone current 3 0)

    local out rc
    out=$(run_check "$clone") && rc=0 || rc=$?

    [ "$rc" -eq 0 ] || fail "current pin should exit 0, got $rc: $out"
    grep -qi "is current" <<<"$out" ||
        fail "current pin should report it is current, got: $out"
    # The OK path is the one place this check can be quietly wrong, so it must
    # still disclose how fresh its view of upstream is.
    grep -qi "upstream view" <<<"$out" ||
        fail "OK path must still report upstream freshness, got: $out"

    # And that disclosure has to be a real number. The age probe resolves paths
    # against the git dir, which sits one level above GC_PACK_DIR; when that
    # resolution broke, the line still printed but degraded to "unknown" and no
    # assertion noticed. Pin the number, not the label.
    grep -qE "last fetched [0-9]+ day" <<<"$out" ||
        fail "upstream freshness must report a numeric age, got: $out"
}

# --- the case this check was written for --------------------------------------

test_stale_pin_warns_with_count() {
    local clone
    clone=$(make_pack_clone stale 10 6)

    local out rc
    out=$(run_check "$clone") && rc=0 || rc=$?

    [ "$rc" -eq 1 ] || fail "stale pin should exit 1 (warning), got $rc: $out"
    grep -q "6 commit(s) behind" <<<"$out" ||
        fail "stale pin should report the exact drift count, got: $out"
}

test_stale_pin_explains_the_pin_is_what_agents_load() {
    local clone
    clone=$(make_pack_clone explain 10 4)

    local out
    out=$(run_check "$clone") || true

    # The whole incident behind this check was an operator returning the rig
    # working tree to main and reasonably assuming that fixed it. The warning is
    # only useful if it says, in the message itself, that it did not.
    grep -qi "working tree does not move this pin\|does not move this pin" <<<"$out" ||
        fail "warning must say returning a checkout does not move the pin, got: $out"
    grep -q "gc import install" <<<"$out" ||
        fail "warning must name the remediation command, got: $out"
}

# --- reference-branch resolution ----------------------------------------------

test_explicit_ref_override_is_used() {
    local clone
    clone=$(make_pack_clone override 8 3)

    # Point the override at the pinned commit itself: zero drift by definition,
    # which is only reachable if the override actually won over origin/HEAD.
    local pinned
    pinned=$(git -C "$clone" rev-parse HEAD)
    git_q -C "$clone" branch drift-ref "$pinned"

    local out rc
    out=$(run_check "$clone" GC_PACK_DRIFT_REF=drift-ref) && rc=0 || rc=$?

    [ "$rc" -eq 0 ] || fail "override ref should be measured against, got $rc: $out"
    grep -q "drift-ref" <<<"$out" ||
        fail "output should name the overridden ref, got: $out"
}

# This is the file:// contamination case observed in gp-0xl: a pack cloned from
# a local repo inherits that repo's checked-out branch as origin/HEAD. If the
# source repo was sitting on an abandoned feature branch, origin/HEAD points at
# it, and measuring against it compares a stale pin to a stale branch and calls
# the result healthy. The override must be able to rescue that.
test_override_beats_a_contaminated_origin_head() {
    local clone
    clone=$(make_pack_clone contaminated 12 0)

    # Fork a feature branch 8 commits back, make it the clone's origin/HEAD, and
    # park the pin on it — reproducing "cloned while a stale branch was checked
    # out". Against that branch the pin looks current; against main it is not.
    local fork
    fork=$(git -C "$clone" rev-parse HEAD~8)
    git_q -C "$clone" branch -f abandoned "$fork"
    git_q -C "$clone" update-ref refs/remotes/origin/abandoned "$fork"
    git_q -C "$clone" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/abandoned
    git_q -C "$clone" checkout "$fork"

    local out rc
    out=$(run_check "$clone") && rc=0 || rc=$?
    [ "$rc" -eq 0 ] || fail "sanity: pin should look current against contaminated origin/HEAD, got $rc: $out"

    out=$(run_check "$clone" GC_PACK_DRIFT_REF=origin/main) && rc=0 || rc=$?
    [ "$rc" -eq 1 ] || fail "override should expose drift hidden by origin/HEAD, got $rc: $out"
    grep -q "8 commit(s) behind" <<<"$out" ||
        fail "override should report drift against the real default branch, got: $out"
}

test_unresolvable_ref_warns_rather_than_passing() {
    local clone
    clone=$(make_pack_clone unresolvable 4 1)

    # A pin whose freshness can never be evaluated is the blind spot this check
    # exists to close, so it must not report OK.
    local out rc
    out=$(run_check "$clone" GC_PACK_DRIFT_REF=origin/does-not-exist) && rc=0 || rc=$?

    [ "$rc" -eq 1 ] || fail "unresolvable ref should warn, got $rc: $out"
    grep -qi "unmeasurable\|cannot resolve" <<<"$out" ||
        fail "unresolvable ref should say drift cannot be measured, got: $out"
}

# --- doctor contract ----------------------------------------------------------

# The doctor runner does NOT set GC_PACK_NAME — it injects GC_PACK_DIR and the
# city/pack-state vars and nothing more. An earlier draft read the pack name
# from GC_PACK_NAME with a "pack" fallback, so every message in a real
# `gc doctor` run said "pack is N commit(s) behind" while the suite, which set
# the variable itself, stayed green. Name the pack from the directory gc
# actually hands us, and prove it with a directory gc's own layout wouldn't
# produce, so a hardcoded "gastown" cannot pass this.
test_pack_name_comes_from_the_pack_dir_not_an_unset_env_var() {
    local clone
    clone=$(make_pack_clone named 6 2 someotherpack)

    local out
    out=$(run_check "$clone") || true

    grep -q "^someotherpack is 2 commit(s) behind" <<<"$out" ||
        fail "message must name the pack from its directory, got: $out"
}

test_script_is_executable_and_reports_message_first() {
    [ -x "$SCRIPT" ] || fail "doctor check script must be executable"

    local clone out
    clone=$(make_pack_clone contract 5 2)
    out=$(run_check "$clone") || true

    # gc doctor takes line 1 as the summary and the remainder as details.
    local first
    first=$(head -n1 <<<"$out")
    [ -n "$first" ] || fail "first line must be a non-empty message"
    grep -q "behind" <<<"$first" ||
        fail "first line should summarise the drift, got: $first"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
    "$t"
    echo "ok - $t"
done

echo "All import-drift check tests passed"
