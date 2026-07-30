#!/usr/bin/env bash
# Tests for the pin-materialization doctor check (gp-xb9).
#
# The fixtures reproduce the real on-disk shape rather than a convenient one:
# a city with pack.toml + city.toml + .gc/site.toml, rig repositories whose
# .beads/formulas/ entries are SYMLINKS into a content-addressed pack cache, and
# pack caches that are real git clones with remote refs. A check that reads the
# declared pin from TOML and the materialized pin from resolved symlinks cannot
# be tested by any fixture that flattens those layers.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT/gastown/doctor/pin-materialization/run.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

git_q() {
    git -c user.name=test -c user.email=test@example.com -c init.defaultBranch=main \
        -c advice.detachedHead=false "$@" >/dev/null 2>&1
}

# Mirrors the doctor runner's environment contract, verified empirically against
# a real `gc doctor` run with every inherited GC_* var scrubbed: gc injects
# GC_PACK_DIR, GC_CITY, GC_CITY_PATH, GC_PACK_STATE_DIR and GC_BIN, sets cwd to
# the city root, and does NOT set GC_PACK_NAME / GC_RIG / GC_RIG_ROOT. Anything
# this helper adds that gc does not is a way for a bug to pass the suite and
# still be broken in production, so it adds nothing and scrubs the rest.
run_check() {
    local packdir="$1" city="$2"
    shift 2
    (
        cd "$city" || exit 99
        env -u GC_PACK_NAME -u GC_RIG -u GC_RIG_ROOT -u GC_PACK_PIN_REF \
            GC_PACK_DIR="$packdir" GC_CITY="$city" GC_CITY_PATH="$city" \
            "$@" bash "$SCRIPT" 2>"$TMP/stderr"
    )
}

# --- fixture builders ---------------------------------------------------------

# An "upstream" repo with a linear main history, plus an optional side branch
# forked partway back. Returns the upstream path.
make_upstream() {
    local name="$1" total="$2"
    local up="$TMP/$name-upstream"
    git_q init "$up"
    local i
    for ((i = 1; i <= total; i++)); do
        echo "commit $i" >"$up/file.txt"
        mkdir -p "$up/gastown/formulas"
        echo "formula at commit $i" >"$up/gastown/formulas/mol-x.toml"
        git_q -C "$up" add -A
        git_q -C "$up" commit -m "commit $i"
    done
    printf '%s' "$up"
}

# Clone an upstream into the content-addressed cache layout gc uses —
# <cache>/repos/<hash>/<pack> — detached at the requested commit.
#
# `remote_as` overrides the clone's origin URL so a fixture can reproduce the
# file:// contamination from the incident. The clone itself is always made
# locally (there is no network in tests); only the recorded origin differs.
make_cache() {
    local up="$1" hash="$2" at="$3" remote_as="${4:-}" pack="${5:-gastown}"
    local clone="$TMP/cache/repos/$hash"
    mkdir -p "$(dirname "$clone")"
    git_q clone "$up" "$clone"
    git_q -C "$clone" checkout "$at"
    [ -n "$remote_as" ] && git_q -C "$clone" remote set-url origin "$remote_as"
    mkdir -p "$clone/$pack/formulas"
    printf '%s' "$clone/$pack"
}

# A city whose pack.toml declares the city pin and whose city.toml declares one
# rig pin per rig, in the exact nesting gc writes:
#   [[rigs]] / name = ... / [rigs.imports] / [rigs.imports.gastown]
make_city() {
    local name="$1" city_source="$2" city_version="$3"
    local city="$TMP/$name"
    mkdir -p "$city/.gc"
    cat >"$city/pack.toml" <<EOF
[pack]
  name = "$name"
  schema = 2

[imports]
  [imports.core]
    source = "https://github.com/gastownhall/gascity/tree/main/internal/bootstrap/packs/core"
    version = "sha:1111111111111111111111111111111111111111"
  [imports.gastown]
    source = "$city_source"
    version = "$city_version"
EOF
    cat >"$city/city.toml" <<'EOF'
[workspace]
provider = "claude"
EOF
    : >"$city/.gc/site.toml"
    printf '%s' "$city"
}

# Append a rig to a city: a [[rigs]] entry in city.toml, a [[rig]] path entry in
# .gc/site.toml, and a rig repository whose .beads/formulas/ symlinks into the
# given pack dir — which is how the installed artifacts are really wired.
add_rig() {
    local city="$1" rig="$2" source="$3" version="$4" wired_pack_dir="${5:-}"
    cat >>"$city/city.toml" <<EOF

[[rigs]]
name = "$rig"
default_branch = "main"
[rigs.imports]
[rigs.imports.gastown]
source = "$source"
version = "$version"
[rigs.imports.switchyard-mcp]
source = "https://github.com/outdoorsea/switchyard-packs/tree/main/switchyard-mcp"
version = "sha:2222222222222222222222222222222222222222"
EOF
    local rigpath="$TMP/rigs/$rig"
    mkdir -p "$rigpath/.beads/formulas"
    cat >>"$city/.gc/site.toml" <<EOF

[[rig]]
name = "$rig"
path = "$rigpath"
EOF
    if [ -n "$wired_pack_dir" ]; then
        ln -sf "$wired_pack_dir/formulas/mol-x.toml" \
            "$rigpath/.beads/formulas/mol-x.toml"
    fi
    printf '%s' "$rigpath"
}

sha_at() { git -C "$1" rev-parse "$2"; }

# --- the healthy case ---------------------------------------------------------

test_matching_pin_passes() {
    local up head city cache
    up=$(make_upstream happy 5)
    head=$(sha_at "$up" HEAD)
    city=$(make_city happy-city "https://example.com/pk/tree/$head/gastown" "sha:$head")
    cache=$(make_cache "$up" aaaa "$head" "https://example.com/pk.git")
    add_rig "$city" alpha "https://example.com/pk/tree/$head/gastown" "sha:$head" "$cache" >/dev/null

    local out rc
    out=$(run_check "$cache" "$city") && rc=0 || rc=$?

    [ "$rc" -eq 0 ] || fail "matching pin should exit 0, got $rc: $out"
    grep -qi "matches the materialized pin" <<<"$out" ||
        fail "healthy case should say the pins match, got: $out"
}

# --- axis 1: declared != materialized ----------------------------------------

# The incident's core shape: the city declares one commit, the cache the
# artifacts resolve into is parked at a different one.
test_declared_pin_not_materialized_is_an_error() {
    local up head older city cache
    up=$(make_upstream mismatch 8)
    head=$(sha_at "$up" HEAD)
    older=$(sha_at "$up" HEAD~3)
    city=$(make_city mismatch-city "https://example.com/pk/tree/$head/gastown" "sha:$head")
    # Cache is parked three commits back from what the city declares.
    cache=$(make_cache "$up" bbbb "$older" "https://example.com/pk.git")
    add_rig "$city" alpha "https://example.com/pk/tree/$head/gastown" "sha:$head" "$cache" >/dev/null

    local out rc
    out=$(run_check "$cache" "$city") && rc=0 || rc=$?

    [ "$rc" -eq 2 ] || fail "declared != materialized should exit 2, got $rc: $out"
    grep -q "${head:0:12}" <<<"$out" ||
        fail "output should name the declared commit, got: $out"
    grep -q "${older:0:12}" <<<"$out" ||
        fail "output should name the materialized commit, got: $out"
}

# The measurement that actually found the incident: HEAD of GC_PACK_DIR agrees
# with the declaration, but the artifacts symlink into a DIFFERENT cache. A
# check that only reads GC_PACK_DIR reports this as healthy — which is exactly
# how it stayed invisible.
test_artifacts_wired_to_a_different_cache_than_gc_resolves() {
    local up head older city right wrong
    up=$(make_upstream wired 8)
    head=$(sha_at "$up" HEAD)
    older=$(sha_at "$up" HEAD~4)
    city=$(make_city wired-city "https://example.com/pk/tree/$head/gastown" "sha:$head")
    # A correctly-materialized cache for the declared pin exists...
    right=$(make_cache "$up" cccc "$head" "https://example.com/pk.git")
    # ...but the rig's symlinks resolve into a stale one.
    wrong=$(make_cache "$up" dddd "$older" "https://example.com/pk.git")
    add_rig "$city" alpha "https://example.com/pk/tree/$head/gastown" "sha:$head" "$wrong" >/dev/null

    local out rc
    out=$(run_check "$right" "$city") && rc=0 || rc=$?

    [ "$rc" -eq 2 ] || fail "artifacts pointing elsewhere should exit 2, got $rc: $out"
    grep -qi "different cache than gc resolves" <<<"$out" ||
        fail "should report the artifact/GC_PACK_DIR split, got: $out"
    grep -q "$wrong" <<<"$out" ||
        fail "should name the cache the artifacts really use, got: $out"
}

# Two rigs wired to different builds of the same pack. Each may match its own
# declaration; as a set the city is split-brained.
test_rigs_wired_to_different_caches() {
    local up head older city c1 c2
    up=$(make_upstream split 8)
    head=$(sha_at "$up" HEAD)
    older=$(sha_at "$up" HEAD~2)
    city=$(make_city split-city "https://example.com/pk/tree/$head/gastown" "sha:$head")
    c1=$(make_cache "$up" eeee "$head" "https://example.com/pk.git")
    c2=$(make_cache "$up" ffff "$older" "https://example.com/pk.git")
    add_rig "$city" alpha "https://example.com/pk/tree/$head/gastown" "sha:$head" "$c1" >/dev/null
    add_rig "$city" beta "https://example.com/pk/tree/$head/gastown" "sha:$head" "$c2" >/dev/null

    local out rc
    out=$(run_check "$c1" "$city") && rc=0 || rc=$?

    [ "$rc" -eq 2 ] || fail "split caches should exit 2, got $rc: $out"
    grep -qi "different gastown caches" <<<"$out" ||
        fail "should report rigs wired to different caches, got: $out"
}

# Declarations that disagree with each other. This is the cross-pin failure:
# the city pin and a rig pin are each internally fine and wrong as a pair.
test_city_and_rig_pins_disagree() {
    local up head older city cache
    up=$(make_upstream crosspin 8)
    head=$(sha_at "$up" HEAD)
    older=$(sha_at "$up" HEAD~3)
    # City pin at the older commit, rig pin at HEAD.
    city=$(make_city crosspin-city "https://example.com/pk/tree/$older/gastown" "sha:$older")
    cache=$(make_cache "$up" a1a1 "$head" "https://example.com/pk.git")
    add_rig "$city" alpha "https://example.com/pk/tree/$head/gastown" "sha:$head" "$cache" >/dev/null

    local out rc
    out=$(run_check "$cache" "$city") && rc=0 || rc=$?

    [ "$rc" -eq 2 ] || fail "disagreeing declarations should exit 2, got $rc: $out"
    grep -qi "declares 2 different gastown pins" <<<"$out" ||
        fail "should report the count of distinct declared pins, got: $out"
}

# --- axis 2: the clone came from somewhere else -------------------------------

# The wrongly-wired cache in the incident had origin =
# file:///Users/jeremy/GitHub/gascity-packs while city.toml declared https://.
# Its contents track a local working tree, so a commit resolved through it does
# not correspond to the published history at all.
test_file_remote_while_declaring_https_is_an_error() {
    local up head city cache
    up=$(make_upstream fileremote 5)
    head=$(sha_at "$up" HEAD)
    city=$(make_city fileremote-city "https://example.com/pk/tree/$head/gastown" "sha:$head")
    cache=$(make_cache "$up" b1b1 "$head" "file:///Users/someone/GitHub/pk")
    add_rig "$city" alpha "https://example.com/pk/tree/$head/gastown" "sha:$head" "$cache" >/dev/null

    local out rc
    out=$(run_check "$cache" "$city") && rc=0 || rc=$?

    [ "$rc" -eq 2 ] || fail "file:// remote vs https:// declaration should exit 2, got $rc: $out"
    grep -qi "materialized from a local clone" <<<"$out" ||
        fail "should report the local-clone substitution, got: $out"
    grep -q "file:///Users/someone/GitHub/pk" <<<"$out" ||
        fail "should name the offending origin URL, got: $out"
}

# A city that genuinely declares a local source is not misconfigured. The
# finding is the MISMATCH between declared and actual remote, not file:// itself.
test_declared_file_source_with_file_remote_is_fine() {
    local up head city cache
    up=$(make_upstream localdev 5)
    head=$(sha_at "$up" HEAD)
    city=$(make_city localdev-city "file://$up/gastown" "sha:$head")
    cache=$(make_cache "$up" c1c1 "$head" "file://$up")
    add_rig "$city" alpha "file://$up/gastown" "sha:$head" "$cache" >/dev/null

    local out rc
    out=$(run_check "$cache" "$city") && rc=0 || rc=$?

    [ "$rc" -eq 0 ] || fail "declared-local source should not be flagged, got $rc: $out"
}

# --- axis 3: the pin is not on the mainline it claims -------------------------

# 051c35e was on origin/fix/tmux-wheel-mouse-any-flag, six weeks off main. This
# is categorically different from being behind: advancing the pin cannot fix it.
test_pin_on_a_side_branch_is_an_error() {
    local up head side city cache
    up=$(make_upstream sidebranch 8)
    head=$(sha_at "$up" HEAD)
    # Fork a side branch four commits back and add a commit that is on no
    # mainline ancestry path.
    git_q -C "$up" checkout -b fix/some-feature "$(sha_at "$up" HEAD~4)"
    echo "side work" >"$up/side.txt"
    git_q -C "$up" add -A
    git_q -C "$up" commit -m "side commit"
    side=$(sha_at "$up" HEAD)
    git_q -C "$up" checkout main

    city=$(make_city side-city "https://example.com/pk/tree/$side/gastown" "sha:$side")
    cache=$(make_cache "$up" d1d1 "$side" "https://example.com/pk.git")
    add_rig "$city" alpha "https://example.com/pk/tree/$side/gastown" "sha:$side" "$cache" >/dev/null

    local out rc
    out=$(run_check "$cache" "$city") && rc=0 || rc=$?

    [ "$rc" -eq 2 ] || fail "side-branch pin should exit 2, got $rc: $out"
    grep -qi "not an ancestor of" <<<"$out" ||
        fail "should report the pin is not an ancestor, got: $out"
    grep -qi "merge-base" <<<"$out" ||
        fail "should report the merge-base so the divergence is datable, got: $out"
    grep -qi "re-point it\|side branch" <<<"$out" ||
        fail "should say advancing the pin will not help, got: $out"
}

# Behind-but-on-mainline is ordinary staleness. import-drift reports that; this
# check must not double-report it as an ancestry failure.
test_pin_behind_but_on_mainline_is_not_an_ancestry_failure() {
    local up older city cache
    up=$(make_upstream behind 8)
    older=$(sha_at "$up" HEAD~4)
    city=$(make_city behind-city "https://example.com/pk/tree/$older/gastown" "sha:$older")
    cache=$(make_cache "$up" e1e1 "$older" "https://example.com/pk.git")
    add_rig "$city" alpha "https://example.com/pk/tree/$older/gastown" "sha:$older" "$cache" >/dev/null

    local out rc
    out=$(run_check "$cache" "$city") && rc=0 || rc=$?

    [ "$rc" -eq 0 ] || fail "behind-but-ancestor should exit 0, got $rc: $out"
    grep -qi "not an ancestor" <<<"$out" &&
        fail "staleness must not be reported as an ancestry failure, got: $out"
    return 0
}

# origin/HEAD is the field a file:// clone corrupts, so the ancestry test must
# prefer origin/main over it. If origin/HEAD wins, a pin sitting on an abandoned
# branch is "on the mainline" by definition and the incident stays green.
test_contaminated_origin_head_does_not_hide_a_side_branch_pin() {
    local up side city cache
    up=$(make_upstream contaminated 10)
    git_q -C "$up" checkout -b abandoned "$(sha_at "$up" HEAD~5)"
    echo "abandoned work" >"$up/side.txt"
    git_q -C "$up" add -A
    git_q -C "$up" commit -m "abandoned commit"
    side=$(sha_at "$up" HEAD)
    git_q -C "$up" checkout main

    city=$(make_city contaminated-city "https://example.com/pk/tree/$side/gastown" "sha:$side")
    cache=$(make_cache "$up" f1f1 "$side" "https://example.com/pk.git")
    # Reproduce a clone whose origin/HEAD names the abandoned branch, the way a
    # file:// clone of a working repo inherits its checked-out branch.
    git_q -C "$TMP/cache/repos/f1f1" symbolic-ref \
        refs/remotes/origin/HEAD refs/remotes/origin/abandoned
    add_rig "$city" alpha "https://example.com/pk/tree/$side/gastown" "sha:$side" "$cache" >/dev/null

    local out rc
    out=$(run_check "$cache" "$city") && rc=0 || rc=$?

    [ "$rc" -eq 2 ] || fail "side-branch pin must be caught despite origin/HEAD, got $rc: $out"
    grep -q "origin/main" <<<"$out" ||
        fail "ancestry should be measured against origin/main, got: $out"
}

# A source URL naming a branch declares its own mainline; that branch, not the
# repo default, is what the pin must be an ancestor of.
test_branch_named_in_source_url_is_the_mainline() {
    local up side city cache
    up=$(make_upstream namedbranch 8)
    git_q -C "$up" checkout -b release "$(sha_at "$up" HEAD~2)"
    echo "release work" >"$up/rel.txt"
    git_q -C "$up" add -A
    git_q -C "$up" commit -m "release commit"
    side=$(sha_at "$up" HEAD)
    git_q -C "$up" checkout main

    # Declared against the release branch, and the pin IS on release — so this
    # must pass even though the commit is not an ancestor of main.
    city=$(make_city namedbranch-city "https://example.com/pk/tree/release/gastown" "sha:$side")
    cache=$(make_cache "$up" a2a2 "$side" "https://example.com/pk.git")
    add_rig "$city" alpha "https://example.com/pk/tree/release/gastown" "sha:$side" "$cache" >/dev/null

    local out rc
    out=$(run_check "$cache" "$city") && rc=0 || rc=$?

    [ "$rc" -eq 0 ] || fail "pin on its declared branch should pass, got $rc: $out"
}

test_ancestry_ref_override_is_honoured() {
    local up side city cache
    up=$(make_upstream override 8)
    git_q -C "$up" checkout -b release "$(sha_at "$up" HEAD~2)"
    echo "release work" >"$up/rel.txt"
    git_q -C "$up" add -A
    git_q -C "$up" commit -m "release commit"
    side=$(sha_at "$up" HEAD)
    git_q -C "$up" checkout main

    city=$(make_city override-city "https://example.com/pk/tree/$side/gastown" "sha:$side")
    cache=$(make_cache "$up" b2b2 "$side" "https://example.com/pk.git")
    add_rig "$city" alpha "https://example.com/pk/tree/$side/gastown" "sha:$side" "$cache" >/dev/null

    # Against main this pin is a side branch (exit 2); against origin/release it
    # is on the mainline. Only a working override can flip that.
    local rc
    run_check "$cache" "$city" >/dev/null 2>&1 && rc=0 || rc=$?
    [ "$rc" -eq 2 ] || fail "sanity: pin should look like a side branch vs main, got $rc"

    local out
    out=$(run_check "$cache" "$city" GC_PACK_PIN_REF=origin/release) && rc=0 || rc=$?
    [ "$rc" -eq 0 ] || fail "override should place the pin on its branch, got $rc: $out"
}

# No network access happens here, so an absent commit is not evidence that the
# pin is off-mainline. It must warn, not error.
test_absent_commit_warns_rather_than_erroring() {
    local up head city cache absent
    up=$(make_upstream absent 5)
    head=$(sha_at "$up" HEAD)
    absent="0123456789abcdef0123456789abcdef01234567"
    city=$(make_city absent-city "https://example.com/pk/tree/$absent/gastown" "sha:$absent")
    cache=$(make_cache "$up" c2c2 "$head" "https://example.com/pk.git")
    add_rig "$city" alpha "https://example.com/pk/tree/$absent/gastown" "sha:$absent" "$cache" >/dev/null

    local out rc
    out=$(run_check "$cache" "$city") && rc=0 || rc=$?

    # The declared/materialized mismatch is real and hard (exit 2); the point of
    # this test is that the ABSENT commit is described as unverifiable rather
    # than asserted to be off-mainline.
    grep -qi "not present in the cache clone" <<<"$out" ||
        fail "absent commit should be reported as absent, got: $out"
    grep -qi "not an ancestor" <<<"$out" &&
        fail "absent commit must not be asserted off-mainline, got: $out"
    return 0
}

# --- degradation and contract -------------------------------------------------

# Registry release tarballs and the builtin core pack are materialized by copy
# and have no commit identity. Inventing a failure there is noise.
test_non_git_pack_is_not_applicable() {
    local city plain
    city=$(make_city plain-city "https://example.com/pk/tree/main/gastown" "sha:1234567890123456789012345678901234567890")
    plain="$TMP/plain/gastown"
    mkdir -p "$plain"

    local out rc
    out=$(run_check "$plain" "$city") && rc=0 || rc=$?

    [ "$rc" -eq 0 ] || fail "non-git pack should exit 0, got $rc: $out"
    grep -qi "not applicable" <<<"$out" ||
        fail "non-git pack should say not applicable, got: $out"
}

# A floating ref cannot be compared to a materialized commit. Say so instead of
# silently skipping the comparison and reporting a clean bill of health.
test_unpinned_declaration_warns() {
    local up head city cache
    up=$(make_upstream unpinned 5)
    head=$(sha_at "$up" HEAD)
    city=$(make_city unpinned-city "https://example.com/pk/tree/main/gastown" "main")
    cache=$(make_cache "$up" d2d2 "$head" "https://example.com/pk.git")
    add_rig "$city" alpha "https://example.com/pk/tree/main/gastown" "main" "$cache" >/dev/null

    local out rc
    out=$(run_check "$cache" "$city") && rc=0 || rc=$?

    [ "$rc" -eq 1 ] || fail "unpinned declaration should warn, got $rc: $out"
    grep -qi "without a commit pin" <<<"$out" ||
        fail "should report the declaration is unpinned, got: $out"
}

# An unreadable city is a declaration that can never be checked — the very blind
# spot this check closes. It must not pass.
test_missing_city_warns_rather_than_passing() {
    local up head cache nocity
    up=$(make_upstream nocity 5)
    head=$(sha_at "$up" HEAD)
    cache=$(make_cache "$up" e2e2 "$head" "https://example.com/pk.git")
    nocity="$TMP/not-a-city"
    mkdir -p "$nocity"

    local out rc
    out=$(
        cd "$nocity" || exit 99
        env -u GC_CITY -u GC_CITY_PATH -u GC_PACK_NAME \
            GC_PACK_DIR="$cache" bash "$SCRIPT" 2>/dev/null
    ) && rc=0 || rc=$?

    [ "$rc" -eq 1 ] || fail "missing city should warn, got $rc: $out"
    grep -qi "cannot locate the city root" <<<"$out" ||
        fail "should say the city root could not be found, got: $out"
}

# A pack installed with no declaration this check can find means the comparison
# never ran. Reporting OK there is worse than reporting nothing.
test_undeclared_pack_warns() {
    local up head city cache
    up=$(make_upstream undeclared 5)
    head=$(sha_at "$up" HEAD)
    city=$(make_city undeclared-city "https://example.com/pk/tree/$head/gastown" "sha:$head")
    # GC_PACK_DIR names a pack the city never declares.
    cache=$(make_cache "$up" f2f2 "$head" "https://example.com/pk.git" "someotherpack")

    local out rc
    out=$(run_check "$cache" "$city") && rc=0 || rc=$?

    [ "$rc" -eq 1 ] || fail "undeclared pack should warn, got $rc: $out"
    grep -qi "no declaration found" <<<"$out" ||
        fail "should say no declaration was found, got: $out"
}

# gc does not set GC_PACK_NAME for doctor checks. The pack name must come from
# the directory gc actually hands us — proved with a name gc's own layout would
# not produce, so a hardcoded "gastown" cannot pass.
test_pack_name_comes_from_the_pack_dir() {
    local up head city cache
    up=$(make_upstream named 5)
    head=$(sha_at "$up" HEAD)
    city=$(make_city named-city "https://example.com/pk/tree/$head/otherpack" "sha:$head")
    # Declare the pack under its real name so the lookup succeeds by directory.
    perl -pi -e 's/\[imports\.gastown\]/[imports.otherpack]/' "$city/pack.toml"
    cache=$(make_cache "$up" a3a3 "$head" "https://example.com/pk.git" "otherpack")

    local out
    out=$(run_check "$cache" "$city") || true

    grep -q "^otherpack " <<<"$out" ||
        fail "message must name the pack from its directory, got: $out"
}

test_script_is_executable_and_reports_message_first() {
    [ -x "$SCRIPT" ] || fail "doctor check script must be executable"

    local up head older city cache out first
    up=$(make_upstream contract 6)
    head=$(sha_at "$up" HEAD)
    older=$(sha_at "$up" HEAD~2)
    city=$(make_city contract-city "https://example.com/pk/tree/$head/gastown" "sha:$head")
    cache=$(make_cache "$up" b3b3 "$older" "https://example.com/pk.git")
    add_rig "$city" alpha "https://example.com/pk/tree/$head/gastown" "sha:$head" "$cache" >/dev/null

    out=$(run_check "$cache" "$city") || true
    first=$(head -n1 <<<"$out")
    [ -n "$first" ] || fail "first line must be a non-empty message"
    grep -q "gastown" <<<"$first" ||
        fail "first line should summarise the finding, got: $first"
    # gc doctor takes line 1 as the summary; a multi-line first "line" would
    # scramble the report.
    [ "$(wc -l <<<"$first" | tr -d ' ')" = "1" ] ||
        fail "first line must be exactly one line"
}

# The remediation has to name the commands that actually move a materialized
# pin. Neither returning a rig checkout to main nor editing the TOML alone does.
test_error_output_names_the_remediation() {
    local up head older city cache out
    up=$(make_upstream remediation 6)
    head=$(sha_at "$up" HEAD)
    older=$(sha_at "$up" HEAD~2)
    city=$(make_city remediation-city "https://example.com/pk/tree/$head/gastown" "sha:$head")
    cache=$(make_cache "$up" c3c3 "$older" "https://example.com/pk.git")
    add_rig "$city" alpha "https://example.com/pk/tree/$head/gastown" "sha:$head" "$cache" >/dev/null

    out=$(run_check "$cache" "$city") || true
    grep -q "gc import install" <<<"$out" ||
        fail "error output must name gc import install, got: $out"
    grep -q "gc reload" <<<"$out" ||
        fail "error output must name gc reload, got: $out"
}

test_no_fix_script_is_shipped() {
    # A sibling fix.sh is auto-discovered and would opt this check into
    # `gc doctor --fix`. Every failure here is a versioning decision with a
    # restart attached; repairing it unattended is the failure mode, not the fix.
    [ ! -e "$ROOT/gastown/doctor/pin-materialization/fix.sh" ] ||
        fail "pin-materialization must not ship a fix.sh"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
    "$t"
    echo "ok - $t"
done

echo "All pin-materialization check tests passed"
