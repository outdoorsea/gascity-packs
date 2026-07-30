#!/usr/bin/env bash
# Tests for the command-coverage doctor check (gp-xb9).
#
# The invariant under test is CROSS-PIN, so no fixture that materializes a single
# pin can exercise it. Each fixture here builds two independently-versioned pack
# caches — one wired up as the city pin (which supplies `gc <pack> <sub>`) and one
# wired up as a rig pin (which supplies prompts and formulas) — and asserts on
# what the check makes of the pair.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT/gastown/doctor/command-coverage/run.sh"

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
# a real `gc doctor` run: GC_PACK_DIR, GC_CITY, GC_CITY_PATH and cwd=city root
# are injected; GC_PACK_NAME / GC_RIG / GC_RIG_ROOT are not.
run_check() {
    local packdir="$1" city="$2"
    shift 2
    (
        cd "$city" || exit 99
        env -u GC_PACK_NAME -u GC_RIG -u GC_RIG_ROOT \
            GC_PACK_DIR="$packdir" GC_CITY="$city" GC_CITY_PATH="$city" \
            "$@" bash "$SCRIPT" 2>"$TMP/stderr"
    )
}

# --- fixture builders ---------------------------------------------------------

# A pack cache: a git clone in the content-addressed layout, holding a given set
# of dispatchable commands and a formula invoking a given set of subcommands.
#
# `commands` and `invokes` are space-separated. A command is dispatchable only
# when its directory contains run.sh, which is the distinction the check relies
# on to avoid counting a help-only directory as an available command.
make_pin() {
    local hash="$1" commands="$2" invokes="$3" pack="${4:-gastown}"
    local clone="$TMP/cache/repos/$hash"
    local packdir="$clone/$pack"
    mkdir -p "$packdir/commands" "$packdir/formulas" "$packdir/agents"

    local c
    for c in $commands; do
        mkdir -p "$packdir/commands/$c"
        printf '#!/usr/bin/env bash\nexit 0\n' >"$packdir/commands/$c/run.sh"
        printf 'help for %s\n' "$c" >"$packdir/commands/$c/help.md"
    done

    {
        printf 'name = "mol-test"\n\n[[step]]\ndescription = """\n'
        for c in $invokes; do
            printf 'Run gc %s %s || exit 1\n' "$pack" "$c"
        done
        printf '"""\n'
    } >"$packdir/formulas/mol-test.toml"

    git_q init "$clone"
    git_q -C "$clone" add -A
    git_q -C "$clone" commit -m "pin $hash"
    printf '%s' "$packdir"
}

# A city whose pack.toml pins the command namespace to a specific commit.
make_city() {
    local name="$1" city_pin_dir="$2"
    local city="$TMP/$name"
    local commit=""
    [ -n "$city_pin_dir" ] && commit=$(git -C "$city_pin_dir" rev-parse HEAD)
    mkdir -p "$city/.gc"
    cat >"$city/pack.toml" <<EOF
[pack]
  name = "$name"
  schema = 2

[imports]
  [imports.gastown]
    source = "https://example.com/pk/tree/$commit/gastown"
    version = "sha:$commit"
EOF
    cat >"$city/city.toml" <<'EOF'
[workspace]
provider = "claude"
EOF
    : >"$city/.gc/site.toml"
    printf '%s' "$city"
}

# A rig whose .beads/formulas/ symlinks into the given pin — the wiring the
# check follows to discover which pin the rig's prompts really come from.
add_rig() {
    local city="$1" rig="$2" pin_dir="$3"
    local rigpath="$TMP/rigs/$rig"
    mkdir -p "$rigpath/.beads/formulas"
    cat >>"$city/.gc/site.toml" <<EOF

[[rig]]
name = "$rig"
path = "$rigpath"
EOF
    ln -sf "$pin_dir/formulas/mol-test.toml" "$rigpath/.beads/formulas/mol-test.toml"
    printf '%s' "$rigpath"
}

# --- the incident ------------------------------------------------------------

# The exact state observed 2026-07-29, verified against the real caches still on
# disk: the city pin (f69ec02) shipped only `status`, while the rig pins
# (10a553ac) had prompts invoking wisp-reconcile and usage-stamp. Both pins were
# individually consistent; every existing check was green.
test_rig_prompts_demand_commands_the_city_pin_lacks() {
    local citypin rigpin city
    citypin=$(make_pin cityold "status" "")
    rigpin=$(make_pin rignew "status wisp-reconcile usage-stamp" "wisp-reconcile usage-stamp")
    city=$(make_city incident-city "$citypin")
    add_rig "$city" alpha "$rigpin" >/dev/null

    local out rc
    out=$(run_check "$citypin" "$city") && rc=0 || rc=$?

    [ "$rc" -eq 2 ] || fail "missing commands should exit 2, got $rc: $out"
    grep -q "wisp-reconcile" <<<"$out" ||
        fail "should name the missing wisp-reconcile, got: $out"
    grep -q "usage-stamp" <<<"$out" ||
        fail "should name the missing usage-stamp, got: $out"
    grep -qi "MISSING" <<<"$out" ||
        fail "should mark the commands missing, got: $out"
    grep -qi "invoked by rig alpha" <<<"$out" ||
        fail "should attribute the demand to the rig that makes it, got: $out"
}

# The failure is fail-closed, not degraded — the prompts use `|| exit 1`. The
# message has to say so, or an operator triaging a red doctor will deprioritise
# the one finding that is about to kill every patrol.
test_error_explains_the_failure_is_fail_closed() {
    local citypin rigpin city out
    citypin=$(make_pin failclosed-city "status" "")
    rigpin=$(make_pin failclosed-rig "status wisp-reconcile" "wisp-reconcile")
    city=$(make_city failclosed-city-dir "$citypin")
    add_rig "$city" alpha "$rigpin" >/dev/null

    out=$(run_check "$citypin" "$city") || true
    grep -qi "fails the patrol closed\|fail.*closed" <<<"$out" ||
        fail "should explain the fail-closed consequence, got: $out"
    grep -q "gc import install" <<<"$out" ||
        fail "should name the remediation command, got: $out"
    grep -qi "versioned independently" <<<"$out" ||
        fail "should explain the two pins are versioned independently, got: $out"
}

# --- the healthy case ---------------------------------------------------------

test_matching_pins_pass() {
    local citypin rigpin city
    citypin=$(make_pin healthy-city "status wisp-reconcile usage-stamp" "")
    rigpin=$(make_pin healthy-rig "status wisp-reconcile usage-stamp" "wisp-reconcile usage-stamp")
    city=$(make_city healthy-city-dir "$citypin")
    add_rig "$city" alpha "$rigpin" >/dev/null

    local out rc
    out=$(run_check "$citypin" "$city") && rc=0 || rc=$?

    [ "$rc" -eq 0 ] || fail "covered commands should exit 0, got $rc: $out"
    grep -qi "all 2 invoked subcommand" <<<"$out" ||
        fail "should report the invoked count, got: $out"
}

# A city pin that ships MORE than is invoked is fine — the assertion is coverage,
# not equality. Reporting unused commands as a problem would fail every city
# whose pack is broader than one rig's usage.
test_extra_available_commands_are_not_a_finding() {
    local citypin rigpin city
    citypin=$(make_pin extra-city "status wisp-reconcile usage-stamp delivery-check parked-check" "")
    rigpin=$(make_pin extra-rig "status wisp-reconcile" "wisp-reconcile")
    city=$(make_city extra-city-dir "$citypin")
    add_rig "$city" alpha "$rigpin" >/dev/null

    local rc
    run_check "$citypin" "$city" >/dev/null && rc=0 || rc=$?
    [ "$rc" -eq 0 ] || fail "unused available commands must not fail, got $rc"
}

test_no_demand_is_not_a_finding() {
    local citypin city
    citypin=$(make_pin nodemand "status" "")
    city=$(make_city nodemand-city "$citypin")

    local out rc
    out=$(run_check "$citypin" "$city") && rc=0 || rc=$?

    [ "$rc" -eq 0 ] || fail "no demand should exit 0, got $rc: $out"
    grep -qi "no prompt or formula invokes" <<<"$out" ||
        fail "should say there is nothing to verify, got: $out"
}

# --- resolving the right pin --------------------------------------------------

# gc may hand this check any materialized cache dir. The command namespace comes
# from the CITY pin specifically, so when GC_PACK_DIR is some other pin the check
# must go find the one pack.toml actually declares. Getting this wrong means
# grading the rig pin against itself, which is always green.
test_city_pin_is_resolved_even_when_gc_hands_us_another() {
    local citypin rigpin city
    citypin=$(make_pin resolve-city "status" "")
    rigpin=$(make_pin resolve-rig "status wisp-reconcile" "wisp-reconcile")
    city=$(make_city resolve-city-dir "$citypin")
    add_rig "$city" alpha "$rigpin" >/dev/null

    # Hand the check the RIG pin. Graded against the rig pin alone, wisp-reconcile
    # is present and this passes; graded against the declared city pin, it is
    # missing and this must fail.
    local out rc
    out=$(run_check "$rigpin" "$city") && rc=0 || rc=$?

    [ "$rc" -eq 2 ] || fail "must grade against the declared city pin, got $rc: $out"
    grep -q "$citypin" <<<"$out" ||
        fail "should report the city pin it resolved, got: $out"
}

# --- what counts as available -------------------------------------------------

# A commands/<name>/ directory with only help.md is documentation, not something
# gc can dispatch. Counting it would mask a genuinely missing command.
test_help_only_command_dir_is_not_available() {
    local citypin rigpin city
    citypin=$(make_pin helponly-city "status" "")
    # Add a help-only directory for the command the rig invokes.
    mkdir -p "$citypin/commands/wisp-reconcile"
    printf 'help\n' >"$citypin/commands/wisp-reconcile/help.md"
    rigpin=$(make_pin helponly-rig "status wisp-reconcile" "wisp-reconcile")
    city=$(make_city helponly-city-dir "$citypin")
    add_rig "$city" alpha "$rigpin" >/dev/null

    local out rc
    out=$(run_check "$citypin" "$city") && rc=0 || rc=$?

    [ "$rc" -eq 2 ] || fail "help-only dir must not count as available, got $rc: $out"
    grep -q "wisp-reconcile" <<<"$out" ||
        fail "should still report wisp-reconcile missing, got: $out"
}

test_city_pin_with_no_commands_at_all_is_an_error() {
    local citypin rigpin city
    citypin=$(make_pin nocommands-city "" "")
    rigpin=$(make_pin nocommands-rig "status wisp-reconcile" "wisp-reconcile")
    city=$(make_city nocommands-city-dir "$citypin")
    add_rig "$city" alpha "$rigpin" >/dev/null

    local out rc
    out=$(run_check "$citypin" "$city") && rc=0 || rc=$?

    [ "$rc" -eq 2 ] || fail "empty namespace with demand should exit 2, got $rc: $out"
    grep -qi "ships none" <<<"$out" ||
        fail "should say the command pin ships no commands, got: $out"
}

# --- what counts as demand ----------------------------------------------------

# `gc gastown wisp-reconcile ensure mol-x` invokes wisp-reconcile; `ensure` is
# its argument. Treating the second token as a subcommand invents a missing
# command on every correctly-written invocation.
test_only_the_first_token_is_the_subcommand() {
    local citypin rigpin city
    citypin=$(make_pin firsttoken-city "wisp-reconcile" "")
    rigpin=$(make_pin firsttoken-rig "wisp-reconcile" "")
    # Hand-write an invocation with arguments after the subcommand.
    printf 'Run gc gastown wisp-reconcile ensure mol-deacon-patrol || exit 1\n' \
        >"$rigpin/formulas/mol-test.toml"
    git_q -C "$(dirname "$rigpin")" add -A
    git_q -C "$(dirname "$rigpin")" commit -m "args"
    city=$(make_city firsttoken-city-dir "$citypin")
    add_rig "$city" alpha "$rigpin" >/dev/null

    local out rc
    out=$(run_check "$citypin" "$city") && rc=0 || rc=$?

    [ "$rc" -eq 0 ] || fail "arguments must not be read as subcommands, got $rc: $out"
    grep -q "ensure" <<<"$out" &&
        fail "'ensure' is an argument, not a subcommand, got: $out"
    return 0
}

# Documentation placeholders and flags are not invocations. A check that reads
# `gc gastown <sub>` out of a prose sentence reports a permanently-missing
# command called "<sub>" and gets muted.
test_placeholders_and_flags_are_not_demand() {
    local citypin rigpin city
    citypin=$(make_pin placeholder-city "status" "")
    rigpin=$(make_pin placeholder-rig "status" "")
    {
        printf 'Call gc gastown <sub> to run a subcommand.\n'
        printf 'Do not probe with gc gastown --help, it exits 0.\n'
        printf 'See gc gastown SOMETHING for the uppercase case.\n'
    } >"$rigpin/formulas/mol-test.toml"
    git_q -C "$(dirname "$rigpin")" add -A
    git_q -C "$(dirname "$rigpin")" commit -m "prose"
    city=$(make_city placeholder-city-dir "$citypin")
    add_rig "$city" alpha "$rigpin" >/dev/null

    local out rc
    out=$(run_check "$citypin" "$city") && rc=0 || rc=$?

    [ "$rc" -eq 0 ] || fail "prose placeholders must not become demand, got $rc: $out"
    grep -qi "no prompt or formula invokes" <<<"$out" ||
        fail "should find no real demand, got: $out"
}

# Demand from a city-authored prompt in the city tree, which belongs to no pin.
test_city_authored_prompts_contribute_demand() {
    local citypin city
    citypin=$(make_pin cityauthored "status" "")
    city=$(make_city cityauthored-city "$citypin")
    mkdir -p "$city/agents/chuck"
    printf 'Run gc gastown wisp-reconcile || exit 1\n' \
        >"$city/agents/chuck/prompt.template.md"

    local out rc
    out=$(run_check "$citypin" "$city") && rc=0 || rc=$?

    [ "$rc" -eq 2 ] || fail "city-authored demand should be counted, got $rc: $out"
    grep -qi "city-authored prompts" <<<"$out" ||
        fail "should attribute demand to the city-authored prompt, got: $out"
}

# Scanning tests/ would make the pack's own test fixtures look like runtime
# demand; scanning commands/ help text is self-referential.
test_tests_and_command_help_are_not_scanned() {
    local citypin rigpin city
    citypin=$(make_pin notscanned-city "status" "")
    rigpin=$(make_pin notscanned-rig "status" "")
    mkdir -p "$rigpin/tests"
    printf 'gc gastown from-a-test || exit 1\n' >"$rigpin/tests/test_x.sh"
    printf 'see also gc gastown from-a-help-file\n' \
        >"$citypin/commands/status/help.md"
    city=$(make_city notscanned-city-dir "$citypin")
    add_rig "$city" alpha "$rigpin" >/dev/null

    local out rc
    out=$(run_check "$citypin" "$city") && rc=0 || rc=$?

    [ "$rc" -eq 0 ] || fail "tests/ and commands/ help must not be scanned, got $rc: $out"
    grep -q "from-a-test" <<<"$out" &&
        fail "tests/ must not contribute demand, got: $out"
    grep -q "from-a-help-file" <<<"$out" &&
        fail "command help text must not contribute demand, got: $out"
    return 0
}

# --- contract -----------------------------------------------------------------

# The tempting wrong implementation. Cobra prints the PARENT command's help and
# exits 0 for an unknown subcommand, so a --help probe reports every command as
# present and the check is green precisely when it should be red. This asserts
# the implementation never reaches for it.
test_does_not_probe_with_a_help_flag() {
    # Comment lines are stripped first: the script documents this pitfall at
    # length, and an assertion that trips over its own rationale is worse than no
    # assertion — it gets deleted rather than understood.
    local code
    code=$(grep -vE '^[[:space:]]*#' "$SCRIPT")
    grep -nE '(gc|GC_BIN|\$\{GC_BIN)[^#]*--help' <<<"$code" &&
        fail "must not probe command existence with --help (Cobra parent-help exits 0)"

    # The positive half: pin the mechanism that replaces the probe. Availability
    # must be read off the filesystem — a commands/<name>/ directory containing
    # run.sh — so this stays green only while that is how it is done.
    grep -q 'commands' <<<"$code" ||
        fail "must determine availability from the pin's commands/ directory"
    grep -q 'run\.sh' <<<"$code" ||
        fail "must require run.sh for a command to count as dispatchable"
    return 0
}

# The pack name must come from the directory gc hands us, since gc does not set
# GC_PACK_NAME for doctor checks. Proved with a name gc's own layout would not
# produce, so a hardcoded "gastown" cannot pass.
test_pack_name_comes_from_the_pack_dir() {
    local citypin rigpin city out
    citypin=$(make_pin othername-city "status" "" otherpack)
    rigpin=$(make_pin othername-rig "status doit" "doit" otherpack)
    city=$(make_city othername-city-dir "$citypin")
    # Declare the import under the pack's real name.
    perl -pi -e 's/\[imports\.gastown\]/[imports.otherpack]/' "$city/pack.toml"
    add_rig "$city" alpha "$rigpin" >/dev/null

    out=$(run_check "$citypin" "$city") || true
    grep -q "^otherpack" <<<"$out" ||
        fail "message must name the pack from its directory, got: $out"
    grep -q "gc otherpack doit" <<<"$out" ||
        fail "should report the invocation using the real pack name, got: $out"
}

test_missing_city_warns_rather_than_passing() {
    local citypin nocity out rc
    citypin=$(make_pin nocity "status" "")
    nocity="$TMP/not-a-city"
    mkdir -p "$nocity"

    out=$(
        cd "$nocity" || exit 99
        env -u GC_CITY -u GC_CITY_PATH -u GC_PACK_NAME \
            GC_PACK_DIR="$citypin" bash "$SCRIPT" 2>/dev/null
    ) && rc=0 || rc=$?

    [ "$rc" -eq 1 ] || fail "missing city should warn, got $rc: $out"
    grep -qi "cannot locate the city root" <<<"$out" ||
        fail "should say the city root could not be found, got: $out"
}

test_script_is_executable_and_reports_message_first() {
    [ -x "$SCRIPT" ] || fail "doctor check script must be executable"

    local citypin rigpin city out first
    citypin=$(make_pin contract-city "status" "")
    rigpin=$(make_pin contract-rig "status wisp-reconcile" "wisp-reconcile")
    city=$(make_city contract-city-dir "$citypin")
    add_rig "$city" alpha "$rigpin" >/dev/null

    out=$(run_check "$citypin" "$city") || true
    first=$(head -n1 <<<"$out")
    [ -n "$first" ] || fail "first line must be a non-empty message"
    [ "$(wc -l <<<"$first" | tr -d ' ')" = "1" ] ||
        fail "first line must be exactly one line"
    grep -q "do not exist in the command pin" <<<"$first" ||
        fail "first line should summarise the finding, got: $first"
}

test_no_fix_script_is_shipped() {
    [ ! -e "$ROOT/gastown/doctor/command-coverage/fix.sh" ] ||
        fail "command-coverage must not ship a fix.sh"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
    "$t"
    echo "ok - $t"
done

echo "All command-coverage check tests passed"
