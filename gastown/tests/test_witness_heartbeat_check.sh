#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT/gastown/assets/scripts/witness-heartbeat-check.sh"
WRAPPER="$ROOT/gastown/commands/witness-heartbeat-check/run.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

write_gc_stub() {
    local bin="$1"
    mkdir -p "$bin"
    cat >"$bin/gc" <<'SH'
#!/usr/bin/env sh
# Only `gc session list --state=all --json` is exercised here.
case "$*" in
    *"session"*"list"*"--json"*) cat "$GC_SESSIONS_JSON" ;;
    *) printf '{}' ;;
esac
SH
    chmod +x "$bin/gc"
}

# run_check <sessions-json-literal> [env assignments...] — prints the TSV rows,
# sets RC to the exit code. stderr is captured separately so row assertions stay
# clean.
run_check() {
    local payload="$1"
    shift
    printf '%s' "$payload" >"$SESSIONS"
    set +e
    # ${1+"$@"} rather than "$@": bash 3.2 under `set -u` treats an empty "$@"
    # as an unbound variable.
    OUT=$(env GC_CITY="$CITY" GC_SESSIONS_JSON="$SESSIONS" PATH="$BIN:$PATH" ${1+"$@"} \
        bash "$SCRIPT" 2>"$ERRFILE")
    RC=$?
    set -e
    ERR=$(cat "$ERRFILE")
}

# run_wrapper <sessions-json-literal> [env assignments...] — invoke the command
# wrapper the way `gc` does, and capture stdout/stderr/exit like run_check.
#
# GC_CITY is explicitly UNSET here, because that is the state `gc` hands a pack
# command: it exports GC_CITY_PATH, not GC_CITY. Without `-u` this would pass on
# a developer machine inside a city (where GC_CITY is exported into every shell)
# while failing in CI — and it would stop testing the wrapper's city resolution
# at all.
#
# WRAP_PACK/WRAP_CITY override the two variables gc supplies, so the
# missing-context paths can be exercised without unsetting them for real.
#
# It runs from $NOCITY — a directory with no city.toml anywhere above it —
# because the check's fallback is to walk up from cwd. A polecat worktree lives
# at <city>/.gc/worktrees/..., so running these from the repo would let that
# walk-up find the developer's REAL city and pass whether or not the wrapper
# resolves anything. That version of this test was vacuous locally and only
# meaningful on a CI runner; $NOCITY makes the wrapper's resolution the single
# reason it can succeed, on both.
run_wrapper() {
    local payload="$1"
    shift
    printf '%s' "$payload" >"$SESSIONS"
    set +e
    # ${1+"$@"} rather than "$@": bash 3.2 under `set -u` treats an empty "$@"
    # as an unbound variable.
    OUT=$(cd "$NOCITY" && env -u GC_CITY \
        GC_CITY_PATH="${WRAP_CITY-$CITY}" GC_PACK_DIR="${WRAP_PACK-$ROOT/gastown}" \
        GC_SESSIONS_JSON="$SESSIONS" PATH="$BIN:$PATH" ${1+"$@"} \
        sh "$WRAPPER" 2>"$ERRFILE")
    RC=$?
    set -e
    ERR=$(cat "$ERRFILE")
}

# epoch_utc — epoch seconds -> RFC3339 UTC. GNU spells this `date -d @<epoch>`;
# BSD/macOS spells it `date -r <epoch>`. The flavour is probed once here rather
# than with a per-call `||` chain for two reasons: a chain that falls through
# both arms yields an empty string, which turns every assertion below into a
# confusing parse failure instead of a clear one; and GNU's `-r` means "mtime of
# FILE", so a BSD-first chain would silently print a file's mtime on GNU if a
# file named like the epoch happened to exist. Probe GNU first, fail loud if
# neither works.
if date -u -d '@0' +%Y >/dev/null 2>&1; then
    epoch_utc() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
elif date -u -r 0 +%Y >/dev/null 2>&1; then
    epoch_utc() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }
else
    echo "FAIL: no usable date(1) — neither GNU '-d @<epoch>' nor BSD '-r <epoch>'" >&2
    exit 1
fi

ts_ago() {
    epoch_utc "$(( $(date -u +%s) - $1 ))"
}

ts_ahead() {
    epoch_utc "$(( $(date -u +%s) + $1 ))"
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
CITY="$tmp/city"
BIN="$tmp/bin"
SESSIONS="$tmp/sessions.json"
ERRFILE="$tmp/stderr.txt"
# A cwd with no city.toml above it, for the wrapper tests. mktemp -d roots this
# under the system temp dir, which is not inside any city.
NOCITY="$tmp/nocity"
mkdir -p "$CITY" "$NOCITY"
: >"$CITY/city.toml"
write_gc_stub "$BIN"

FRESH=$(ts_ago 45)
STALE=$(ts_ago 72000)   # 20h — inside the 14h-63h band this check exists for

test_fresh_heartbeat_is_not_flagged() {
    run_check "$(printf '{"sessions":[{"id":"s1","name":"alpha/witness","rig":"alpha","template":"gastown.witness","state":"asleep","last_active":"%s","closed":false}]}' "$FRESH")"
    [ "$RC" -eq 0 ] || fail "a fresh witness must exit 0, got $RC ($OUT)"
    printf '%s' "$OUT" | grep -q '^fresh	alpha	alpha/witness	asleep	' ||
        fail "a fresh witness should report the fresh verdict, got: $OUT"
    printf '%s' "$OUT" | grep -q 'stalled' &&
        fail "a fresh witness must never be reported stalled"
    return 0
}

test_stale_heartbeat_is_stalled() {
    run_check "$(printf '{"sessions":[{"id":"s1","name":"alpha/witness","rig":"alpha","template":"gastown.witness","state":"asleep","last_active":"%s","closed":false}]}' "$STALE")"
    [ "$RC" -eq 1 ] || fail "a stalled witness must exit 1, got $RC ($OUT)"
    printf '%s' "$OUT" | grep -q '^stalled	alpha	alpha/witness	asleep	7[0-9][0-9][0-9][0-9]	' ||
        fail "a 20h-silent witness should report stalled with its age, got: $OUT"
}

test_zero_time_sentinel_is_no_heartbeat_not_stalled() {
    run_check '{"sessions":[{"id":"s1","name":"alpha/witness","rig":"alpha","state":"asleep","last_active":"0001-01-01T00:00:00Z","closed":false}]}'
    printf '%s' "$OUT" | grep -q '^no-heartbeat	alpha	alpha/witness	asleep	-	-$' ||
        fail "the Go zero-time sentinel should report no-heartbeat, got: $OUT"
    printf '%s' "$OUT" | grep -q 'stalled' &&
        fail "the zero-time sentinel must never be parsed as an ancient heartbeat"
    [ "$RC" -eq 1 ] || fail "an unmeasurable heartbeat is a finding (exit 1), got $RC"
    return 0
}

test_malformed_timestamp_is_no_heartbeat_not_stalled() {
    run_check '{"sessions":[{"id":"s1","name":"alpha/witness","rig":"alpha","state":"active","last_active":"not-a-timestamp","closed":false}]}'
    printf '%s' "$OUT" | grep -q '^no-heartbeat	alpha	alpha/witness	active	-	-$' ||
        fail "an unparseable timestamp should report no-heartbeat, got: $OUT"
    printf '%s' "$OUT" | grep -q 'stalled' &&
        fail "an unparseable timestamp must not be reported stalled"
    [ "$RC" -eq 1 ] || fail "an unparseable heartbeat is a finding (exit 1), got $RC"
    return 0
}

test_newer_of_the_two_stamps_wins() {
    # Stale last_active + fresh self-nudge = healthy. This is the pairing that
    # makes the check usable on an asleep witness at all.
    run_check "$(printf '{"sessions":[{"id":"s1","name":"alpha/witness","rig":"alpha","state":"asleep","last_active":"%s","last_nudge_delivered_at":"%s","closed":false}]}' "$STALE" "$FRESH")"
    [ "$RC" -eq 0 ] || fail "a fresh self-nudge should keep the witness fresh, got $RC ($OUT)"
    printf '%s' "$OUT" | grep -q "^fresh	alpha	alpha/witness	asleep	[0-9]*	$FRESH\$" ||
        fail "the newer of last_active/last_nudge_delivered_at should win, got: $OUT"

    # ...and the reverse ordering must give the same answer.
    run_check "$(printf '{"sessions":[{"id":"s1","name":"alpha/witness","rig":"alpha","state":"asleep","last_active":"%s","last_nudge_delivered_at":"%s","closed":false}]}' "$FRESH" "$STALE")"
    [ "$RC" -eq 0 ] || fail "stamp order must not change the verdict, got $RC ($OUT)"
}

test_fractional_seconds_parse() {
    run_check "$(printf '{"sessions":[{"id":"s1","name":"alpha/witness","rig":"alpha","state":"asleep","last_active":"%s","closed":false}]}' "${FRESH%Z}.123456789Z")"
    [ "$RC" -eq 0 ] || fail "a fractional-second timestamp should parse as fresh, got $RC ($OUT)"
    printf '%s' "$OUT" | grep -q '^fresh	' ||
        fail "a fractional-second timestamp should report fresh, got: $OUT"
}

test_future_heartbeat_is_clock_skew_not_stale() {
    run_check "$(printf '{"sessions":[{"id":"s1","name":"alpha/witness","rig":"alpha","state":"asleep","last_active":"%s","closed":false}]}' "$(ts_ahead 3600)")"
    [ "$RC" -eq 0 ] || fail "a future heartbeat is skew, not staleness, got $RC ($OUT)"
    printf '%s' "$OUT" | grep -q '^fresh	alpha	alpha/witness	asleep	0	' ||
        fail "a future heartbeat should clamp to age 0, got: $OUT"
}

test_threshold_is_configurable() {
    local ninety_one_min
    ninety_one_min=$(ts_ago 5460)
    # Inside the 90m default...
    run_check "$(printf '{"sessions":[{"id":"s1","name":"alpha/witness","rig":"alpha","state":"asleep","last_active":"%s","closed":false}]}' "$(ts_ago 3600)")"
    [ "$RC" -eq 0 ] || fail "a 1h-old heartbeat is inside the 90m default, got $RC ($OUT)"
    # ...outside it.
    run_check "$(printf '{"sessions":[{"id":"s1","name":"alpha/witness","rig":"alpha","state":"asleep","last_active":"%s","closed":false}]}' "$ninety_one_min")"
    [ "$RC" -eq 1 ] || fail "a 91m-old heartbeat should breach the 90m default, got $RC ($OUT)"
    # ...and a tighter window flags what the default tolerates.
    run_check "$(printf '{"sessions":[{"id":"s1","name":"alpha/witness","rig":"alpha","state":"asleep","last_active":"%s","closed":false}]}' "$(ts_ago 3600)")" \
        GASTOWN_WITNESS_STALE_MIN=15
    [ "$RC" -eq 1 ] || fail "GASTOWN_WITNESS_STALE_MIN=15 should flag a 1h-old heartbeat, got $RC ($OUT)"
    printf '%s' "$ERR" | grep -q 'window 15m' ||
        fail "the summary should report the configured window, got: $ERR"
}

test_bad_threshold_fails_loudly() {
    run_check '{"sessions":[]}' GASTOWN_WITNESS_STALE_MIN=abc
    [ "$RC" -eq 2 ] || fail "a non-numeric window must exit 2, got $RC"
    run_check '{"sessions":[]}' GASTOWN_WITNESS_STALE_MIN=0
    [ "$RC" -eq 2 ] || fail "a zero window must exit 2, got $RC"
}

test_controller_owned_states_are_skipped() {
    run_check "$(printf '{"sessions":[
      {"id":"s1","name":"a/witness","rig":"a","state":"creating","last_active":"%s","closed":false},
      {"id":"s2","name":"b/witness","rig":"b","state":"suspended","last_active":"%s","closed":false},
      {"id":"s3","name":"c/witness","rig":"c","state":"drained","last_active":"%s","closed":false},
      {"id":"s4","name":"d/witness","rig":"d","state":"closed","last_active":"%s","closed":true}
    ]}' "$STALE" "$STALE" "$STALE" "$STALE")"
    [ "$RC" -eq 0 ] || fail "controller/operator-owned states must not be flagged, got $RC ($OUT)"
    [ -z "$OUT" ] || fail "controller/operator-owned states should emit no rows, got: $OUT"
    printf '%s' "$ERR" | grep -q "no patrolling 'witness' session among 4" ||
        fail "the summary should say nothing was checked, got: $ERR"
}

test_non_witness_sessions_are_ignored() {
    run_check "$(printf '{"sessions":[
      {"id":"s1","name":"deacon","template":"gastown.deacon","state":"asleep","last_active":"%s","closed":false},
      {"id":"s2","name":"a/refinery","rig":"a","template":"gastown.refinery","state":"asleep","last_active":"%s","closed":false},
      {"id":"s3","name":"a/witnessing-tool","rig":"a","state":"asleep","last_active":"%s","closed":false},
      {"id":"s4","name":"a/witness","rig":"a","template":"gastown.witness","state":"asleep","last_active":"%s","closed":false}
    ]}' "$STALE" "$STALE" "$STALE" "$FRESH")"
    [ "$RC" -eq 0 ] || fail "only witness sessions should be checked, got $RC ($OUT)"
    [ "$(printf '%s\n' "$OUT" | grep -c .)" -eq 1 ] ||
        fail "exactly one row (the witness) expected, got: $OUT"
    printf '%s' "$OUT" | grep -q 'a/witness	asleep' ||
        fail "the witness row should be the one reported, got: $OUT"
    printf '%s' "$OUT" | grep -q 'witnessing-tool' &&
        fail "a bare substring match must not pull in unrelated session names"
    return 0
}

test_binding_prefixed_template_matches() {
    run_check "$(printf '{"sessions":[{"id":"s1","state":"asleep","template":"gastown.witness","last_active":"%s","closed":false}]}' "$STALE")"
    [ "$RC" -eq 1 ] || fail "a binding-prefixed template should still match, got $RC ($OUT)"
    printf '%s' "$OUT" | grep -q '^stalled	-	s1	asleep	' ||
        fail "a session with no name/rig should fall back to its id, got: $OUT"
}

test_role_override() {
    run_check "$(printf '{"sessions":[{"id":"s1","name":"a/scout","rig":"a","state":"asleep","last_active":"%s","closed":false}]}' "$STALE")" \
        GASTOWN_WITNESS_ROLE=scout
    [ "$RC" -eq 1 ] || fail "GASTOWN_WITNESS_ROLE should retarget the check, got $RC ($OUT)"
    printf '%s' "$OUT" | grep -q '^stalled	a	a/scout	' ||
        fail "the overridden role should be checked, got: $OUT"
}

test_legacy_top_level_array_is_tolerated() {
    run_check "$(printf '[{"id":"s1","name":"alpha/witness","rig":"alpha","state":"asleep","last_active":"%s","closed":false}]' "$STALE")"
    [ "$RC" -eq 1 ] || fail "the legacy top-level array shape should still parse, got $RC ($OUT)"
    printf '%s' "$OUT" | grep -q '^stalled	alpha	alpha/witness	' ||
        fail "the legacy array shape should yield the same verdict, got: $OUT"
}

test_missing_last_active_field_fails_loud() {
    # Schema drift must never read as health: nothing was measured, so say so
    # instead of quietly reporting every witness fresh.
    run_check '{"sessions":[{"id":"s1","name":"alpha/witness","rig":"alpha","state":"asleep","closed":false}]}'
    [ "$RC" -eq 2 ] || fail "a roster with no last_active field must exit 2, got $RC ($OUT)"
    printf '%s' "$OUT" | grep -q '^schema-drift	alpha	alpha/witness	asleep	-	-$' ||
        fail "the drifted session should be named, got: $OUT"
    printf '%s' "$ERR" | grep -q 'NOT measured' ||
        fail "the drift message should say freshness was not measured, got: $ERR"
}

test_unreadable_roster_fails_loud() {
    mkdir -p "$tmp/badbin"
    printf '#!/usr/bin/env sh\nexit 1\n' >"$tmp/badbin/gc"
    chmod +x "$tmp/badbin/gc"
    set +e
    OUT=$(GC_CITY="$CITY" PATH="$tmp/badbin:$PATH" bash "$SCRIPT" 2>"$ERRFILE")
    RC=$?
    set -e
    [ "$RC" -eq 2 ] || fail "a failing 'gc session list' must exit 2, got $RC"
    grep -q 'NOT measured' "$ERRFILE" ||
        fail "a failing roster read should say freshness was not measured"
}

test_missing_city_fails_loud() {
    set +e
    OUT=$(cd "$tmp" && GC_CITY="$tmp/nope" PATH="$BIN:$PATH" bash "$SCRIPT" 2>"$ERRFILE")
    RC=$?
    set -e
    [ "$RC" -eq 2 ] || fail "a missing city must exit 2, got $RC"
    grep -q 'no city.toml found' "$ERRFILE" || fail "expected the city-resolution error"
}

test_multiple_rigs_report_every_witness() {
    run_check "$(printf '{"sessions":[
      {"id":"s1","name":"a/witness","rig":"a","state":"asleep","last_active":"%s","closed":false},
      {"id":"s2","name":"b/witness","rig":"b","state":"active","last_active":"%s","closed":false},
      {"id":"s3","name":"c/witness","rig":"c","state":"asleep","last_active":"0001-01-01T00:00:00Z","closed":false}
    ]}' "$FRESH" "$STALE")"
    [ "$RC" -eq 1 ] || fail "a mixed roster with findings must exit 1, got $RC ($OUT)"
    printf '%s' "$OUT" | grep -q '^fresh	a	a/witness	' || fail "rig a should be fresh: $OUT"
    printf '%s' "$OUT" | grep -q '^stalled	b	b/witness	active	' || fail "rig b should be stalled: $OUT"
    printf '%s' "$OUT" | grep -q '^no-heartbeat	c	c/witness	' || fail "rig c should be no-heartbeat: $OUT"
    printf '%s' "$ERR" | grep -q "checked 3 'witness' session(s), 1 stalled (window 90m)" ||
        fail "the summary should count what was checked, got: $ERR"
}

test_uses_no_bash4_only_constructs() {
    ! grep -nE 'declare -A|local -A|mapfile|readarray|\$\{[A-Za-z_]+\^|\$\{[A-Za-z_]+,,|&>>|\[\[ -v ' "$SCRIPT" >/dev/null ||
        fail "the check must stay bash 3.2 compatible (the fleet includes macOS)"
}

# --- the `gc gastown witness-heartbeat-check` wrapper -----------------------
#
# The wrapper exists only to resolve the path, and that is exactly the part that
# was wrong the first time (gp-3qb): mol-deacon-patrol reached for
# "${GC_PACK_DIR:-}/assets/scripts/witness-heartbeat-check.sh", but GC_PACK_DIR
# is set by `gc` when `gc` invokes a pack command and is absent from a plain
# agent session. The path expanded to "/assets/scripts/...", the `[ -x ]` guard
# in front of it failed, and the step fell through to a message that reads like a
# considered fallback — so the check never ran once and every patrol recorded a
# clean health scan it had not performed.
#
# These tests pin the resolution contract, not the measurement. The measurement
# is covered by the run_check tests above.

test_wrapper_is_executable() {
    [ -x "$WRAPPER" ] || fail "$WRAPPER must be executable"
    [ -f "$ROOT/gastown/commands/witness-heartbeat-check/help.md" ] ||
        fail "missing commands/witness-heartbeat-check/help.md"
}

test_wrapper_rejects_missing_pack_context() {
    # Invoked by path instead of through `gc`, so GC_PACK_DIR is empty. This is
    # the gp-3qb defect's exact input: it must fail loudly rather than resolving
    # to /assets/scripts/... and reporting a clean scan.
    WRAP_PACK="" run_wrapper '{"sessions":[]}'
    [ "$RC" -eq 2 ] || fail "missing GC_PACK_DIR must exit 2, got $RC"
    printf '%s' "$ERR" | grep -q 'missing Gas City pack context' ||
        fail "the wrapper must name the missing pack context, got: $ERR"
}

test_wrapper_rejects_missing_city_context() {
    WRAP_CITY="" run_wrapper '{"sessions":[]}'
    [ "$RC" -eq 2 ] || fail "missing GC_CITY_PATH must exit 2, got $RC"
}

test_wrapper_reports_a_pack_without_the_check() {
    # An older pack version that predates the check. Exit 2 — "freshness was not
    # measured" — never 0, which would read as "every witness is fresh".
    WRAP_PACK="$tmp" run_wrapper '{"sessions":[]}'
    [ "$RC" -eq 2 ] || fail "a pack missing the check must exit 2, got $RC"
    printf '%s' "$ERR" | grep -q 'not found in this pack version' ||
        fail "the wrapper must say the check is missing, got: $ERR"
}

test_wrapper_resolves_the_city_from_pack_context() {
    # GC_CITY unset and cwd outside any city — the deacon's actual situation when
    # `gc` invokes the command. The wrapper must use the city root gc resolved
    # rather than walking up from cwd, which would find no city.toml and exit 2.
    run_wrapper "$(printf '{"sessions":[{"id":"s1","name":"alpha/witness","rig":"alpha","state":"asleep","last_active":"%s","closed":false}]}' "$FRESH")"
    [ "$RC" -eq 0 ] ||
        fail "the wrapper must resolve the city from GC_CITY_PATH, got $RC: $ERR"
    printf '%s' "$OUT" | grep -q '^fresh	alpha	alpha/witness	' ||
        fail "the wrapper should relay the check's TSV rows, got: $OUT"
}

test_wrapper_passes_findings_exit_through() {
    # Exit 1 is a verdict, not an error to swallow: the deacon branches on it to
    # decide whether to nudge. A wrapper that collapsed it to 0 would restore the
    # original silence through a different route.
    run_wrapper "$(printf '{"sessions":[{"id":"s1","name":"alpha/witness","rig":"alpha","state":"asleep","last_active":"%s","closed":false}]}' "$STALE")"
    [ "$RC" -eq 1 ] || fail "the wrapper must pass through exit 1 (findings), got $RC"
    printf '%s' "$OUT" | grep -q '^stalled	alpha	' || fail "expected a stalled row, got: $OUT"
}

test_wrapper_passes_the_stale_window_through() {
    # The formula supplies the window as an environment prefix on the `gc` call.
    # If the wrapper dropped it, every rig would silently fall back to 90m — a
    # quieter version of the same bug, since the check would still print rows.
    run_wrapper "$(printf '{"sessions":[{"id":"s1","name":"alpha/witness","rig":"alpha","state":"asleep","last_active":"%s","closed":false}]}' "$(ts_ago 3600)")" \
        GASTOWN_WITNESS_STALE_MIN=30
    [ "$RC" -eq 1 ] ||
        fail "a 60m-old heartbeat must be stalled under a 30m window, got $RC ($OUT)"
    printf '%s' "$ERR" | grep -q 'window 30m' ||
        fail "the 30m window must reach the check, got: $ERR"
}

# --- the caller actually invokes it the resolvable way ----------------------

test_formula_invokes_the_command_not_the_path() {
    local formula="$ROOT/gastown/formulas/mol-deacon-patrol.toml"
    grep -Fq 'gc gastown witness-heartbeat-check' "$formula" ||
        fail "mol-deacon-patrol must run the check as 'gc gastown witness-heartbeat-check'"
    grep -Fq 'GASTOWN_WITNESS_STALE_MIN={{witness_stale_min}}' "$formula" ||
        fail "the window must come from the formula var, not a number invented per cycle"
    # The regression itself. Match the code CONSTRUCT, not the string
    # GC_PACK_DIR: the prose under the snippet quotes the broken path on purpose,
    # to record why it was broken, and a string match would forbid explaining it.
    ! grep -qE '^[[:space:]]*CHECK=' "$formula" ||
        fail "formula must not resolve the check into a path variable"
    ! grep -qE '^[[:space:]]*(bash|sh|exec)[[:space:]].*GC_PACK_DIR' "$formula" ||
        fail "formula must not execute a script through ambient GC_PACK_DIR"
}

test_fresh_heartbeat_is_not_flagged
test_stale_heartbeat_is_stalled
test_zero_time_sentinel_is_no_heartbeat_not_stalled
test_malformed_timestamp_is_no_heartbeat_not_stalled
test_newer_of_the_two_stamps_wins
test_fractional_seconds_parse
test_future_heartbeat_is_clock_skew_not_stale
test_threshold_is_configurable
test_bad_threshold_fails_loudly
test_controller_owned_states_are_skipped
test_non_witness_sessions_are_ignored
test_binding_prefixed_template_matches
test_role_override
test_legacy_top_level_array_is_tolerated
test_missing_last_active_field_fails_loud
test_unreadable_roster_fails_loud
test_missing_city_fails_loud
test_multiple_rigs_report_every_witness
test_uses_no_bash4_only_constructs
test_wrapper_is_executable
test_wrapper_rejects_missing_pack_context
test_wrapper_rejects_missing_city_context
test_wrapper_reports_a_pack_without_the_check
test_wrapper_resolves_the_city_from_pack_context
test_wrapper_passes_findings_exit_through
test_wrapper_passes_the_stale_window_through
test_formula_invokes_the_command_not_the_path

echo "witness heartbeat check tests passed"
