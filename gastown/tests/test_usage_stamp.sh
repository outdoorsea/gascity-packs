#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT/gastown/assets/scripts/usage-stamp.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# The stub records every `gc bd update` invocation to $GC_UPDATE_LOG so the
# assertions can check exactly which metadata keys were written — the whole
# point of this script is what lands on the bead, not what it prints.
write_gc_stub() {
    local bin="$1"
    mkdir -p "$bin"
    cat >"$bin/gc" <<'SH'
#!/usr/bin/env sh
case "$*" in
    *"bd"*"update"*)
        printf '%s\n' "$*" >>"$GC_UPDATE_LOG"
        ;;
    *"bd"*"show"*)
        if [ -n "${GC_BEAD_JSON:-}" ] && [ -r "${GC_BEAD_JSON}" ]; then
            cat "$GC_BEAD_JSON"
        else
            exit 1
        fi
        ;;
    *) printf '{}' ;;
esac
SH
    chmod +x "$bin/gc"
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

CITY="$TMP/city"
BIN="$TMP/bin"
mkdir -p "$CITY/.gc"
: >"$CITY/city.toml"
write_gc_stub "$BIN"

UPDATE_LOG="$TMP/updates.log"
ERRFILE="$TMP/stderr"

# These tests may themselves run inside a Gas City agent session, which exports
# GC_SESSION_ID, GC_SESSION_NAME, GC_CITY_PATH and friends. Clear them so the
# fixtures — not the ambient session — decide what the script joins on.
export GC_CITY="$CITY"
export GC_CITY_PATH=""
export GC_SESSION_ID=""
export GC_SESSION_NAME=""
export GC_DISABLE_USAGE_METRICS=""
export GC_BEAD_JSON=""
export GC_UPDATE_LOG="$UPDATE_LOG"
export PATH="$BIN:$PATH"

# usage_row <session_id> <worker> <model> <input> <output> <cread> <ccreate>
usage_row() {
    printf '{"run_id":"%s","session_id":"%s","worker":"%s","kind":"model","model":"%s","provider":"claude","input_tokens":%s,"output_tokens":%s,"cache_read_tokens":%s,"cache_creation_tokens":%s,"at":1785203090652}\n' \
        "$1" "$1" "$2" "$3" "$4" "$5" "$6" "$7"
}

compute_row() {
    printf '{"run_id":"%s","session_id":"%s","worker":"%s","kind":"compute","wall_seconds":304.34,"at":1785203090652}\n' \
        "$1" "$1" "$2"
}

# run_stamp <script args...> — runs the script against the fixture sink,
# resetting the update log first. Tests that need a different environment
# export it around the call. Sets OUT (stdout), ERR (stderr) and RC.
run_stamp() {
    : >"$UPDATE_LOG"
    set +e
    # ${1+"$@"} rather than "$@": bash 3.2 under `set -u` treats an empty "$@"
    # as an unbound variable.
    OUT=$(bash "$SCRIPT" ${1+"$@"} 2>"$ERRFILE")
    RC=$?
    set -e
    ERR=$(cat "$ERRFILE")
}

updates() { cat "$UPDATE_LOG" 2>/dev/null || printf ''; }

test_single_model_aggregates_and_stamps() {
    {
        usage_row gk-thd gastown__polecat-gk-thd claude-opus-5 10 100 5000 200
        usage_row gk-thd gastown__polecat-gk-thd claude-opus-5 5 50 2000 100
    } >"$CITY/.gc/usage.jsonl"

    run_stamp bd-1 --session gk-thd
    [ "$RC" -eq 0 ] || fail "expected rc 0 for a metered session, got $RC ($ERR)"

    printf '%s\n' "$OUT" | grep -q "^claude-opus-5	claude	2	15	150	7000	300$" ||
        fail "per-model row wrong: $OUT"
    printf '%s\n' "$OUT" | grep -q "^TOTAL	claude	1	15	150	7000	300$" ||
        fail "TOTAL row wrong: $OUT"

    updates | grep -q 'usage.status=metered' || fail "status not stamped: $(updates)"
    updates | grep -q 'usage.input_tokens=15' || fail "input_tokens not stamped: $(updates)"
    updates | grep -q 'usage.output_tokens=150' || fail "output_tokens not stamped: $(updates)"
    updates | grep -q 'usage.cache_read_tokens=7000' || fail "cache_read not stamped: $(updates)"
    updates | grep -q 'usage.cache_creation_tokens=300' || fail "cache_creation not stamped: $(updates)"
    updates | grep -q 'usage.model=claude-opus-5' || fail "model not stamped: $(updates)"
    updates | grep -q 'usage.session_id=gk-thd' || fail "session_id not stamped: $(updates)"
}

test_dominant_model_is_highest_output_and_breakdown_is_kept() {
    {
        usage_row gk-mix gastown__polecat-gk-mix claude-haiku-4-5 1000 40 10 5
        usage_row gk-mix gastown__polecat-gk-mix claude-opus-5 10 900 20 7
    } >"$CITY/.gc/usage.jsonl"

    run_stamp bd-2 --session gk-mix
    [ "$RC" -eq 0 ] || fail "expected rc 0, got $RC ($ERR)"

    # Opus produced fewer input tokens but far more output — output is the cost
    # driver attributable to the model, so it must win the single model field.
    updates | grep -q 'usage.model=claude-opus-5' ||
        fail "dominant model should be the highest-output model: $(updates)"
    updates | grep -q 'usage.input_tokens=1010' || fail "totals must span all models: $(updates)"
    updates | grep -q 'usage.output_tokens=940' || fail "totals must span all models: $(updates)"
    updates | grep -q 'usage.models=' || fail "multi-model breakdown must be kept: $(updates)"
    updates | grep -q 'claude-haiku-4-5=1000/40' ||
        fail "breakdown must name the non-dominant tier: $(updates)"

    # Dominant model sorts first in the TSV so consumers can read row 1.
    printf '%s\n' "$OUT" | head -1 | grep -q '^claude-opus-5' ||
        fail "highest-output model must sort first: $OUT"
}

test_single_model_omits_breakdown() {
    usage_row gk-one gastown__polecat-gk-one claude-opus-5 1 2 3 4 >"$CITY/.gc/usage.jsonl"
    run_stamp bd-3 --session gk-one
    [ "$RC" -eq 0 ] || fail "expected rc 0, got $RC"
    updates | grep -q 'usage.models=' &&
        fail "breakdown is redundant with one model and must be omitted: $(updates)"
    return 0
}

test_unmetered_never_writes_zero_tokens() {
    usage_row gk-other gastown__polecat-gk-other claude-opus-5 10 100 5 5 >"$CITY/.gc/usage.jsonl"

    run_stamp bd-4 --session gk-absent
    [ "$RC" -eq 1 ] || fail "expected rc 1 for an unmetered session, got $RC"

    updates | grep -q 'usage.status=unmetered' || fail "unmetered status not stamped: $(updates)"
    updates | grep -q 'usage.unmetered_reason=' || fail "unmetered reason not stamped: $(updates)"
    # The core invariant: a bead with unknown spend must not claim zero spend.
    updates | grep -q 'usage.input_tokens' &&
        fail "unmetered must write NO token fields — a 0 reads as free work: $(updates)"
    updates | grep -q 'usage.output_tokens' &&
        fail "unmetered must write NO token fields — a 0 reads as free work: $(updates)"
    return 0
}

test_missing_sink_is_unmetered_with_provider_hint() {
    rm -f "$CITY/.gc/usage.jsonl"
    run_stamp bd-5 --session gk-thd
    [ "$RC" -eq 1 ] || fail "expected rc 1 when the sink is absent, got $RC"
    updates | grep -q 'usage.status=unmetered' || fail "missing sink must still stamp status: $(updates)"
    printf '%s' "$ERR" | grep -q "exec:" ||
        fail "a missing sink should point at the non-local usage provider: $ERR"
}

test_disabled_metrics_is_named_in_the_reason() {
    usage_row gk-thd gastown__polecat-gk-thd claude-opus-5 10 100 5 5 >"$CITY/.gc/usage.jsonl"
    export GC_DISABLE_USAGE_METRICS=1
    run_stamp bd-6 --session gk-silent
    export GC_DISABLE_USAGE_METRICS=""
    [ "$RC" -eq 1 ] || fail "expected rc 1, got $RC"
    printf '%s' "$ERR" | grep -q "GC_DISABLE_USAGE_METRICS=1" ||
        fail "the reason must name the switch that turned metering off: $ERR"
}

test_matches_on_worker_name_when_session_id_differs() {
    # Session beads and usage rows do not always agree on the id field; `worker`
    # carries the session NAME, which is the more reliable key for some roles.
    usage_row gk-xyz gascity-packs--gastown__refinery claude-opus-5 7 70 1 1 >"$CITY/.gc/usage.jsonl"
    run_stamp bd-7 --session-name gascity-packs--gastown__refinery
    [ "$RC" -eq 0 ] || fail "worker-name match should meter, got rc $RC ($ERR)"
    updates | grep -q 'usage.output_tokens=70' || fail "worker match did not aggregate: $(updates)"
}

test_compute_rows_are_not_counted_as_tokens() {
    {
        usage_row gk-c gastown__polecat-gk-c claude-opus-5 10 100 5 5
        compute_row gk-c gastown__polecat-gk-c
    } >"$CITY/.gc/usage.jsonl"
    run_stamp bd-8 --session gk-c
    [ "$RC" -eq 0 ] || fail "expected rc 0, got $RC"
    printf '%s\n' "$OUT" | grep -q "^claude-opus-5	claude	1	10	100	5	5$" ||
        fail "compute rows must not inflate the model row count: $OUT"
}

test_other_sessions_are_excluded() {
    {
        usage_row gk-mine gastown__polecat-gk-mine claude-opus-5 10 100 5 5
        usage_row gk-theirs gastown__polecat-gk-theirs claude-opus-5 999 9999 999 999
    } >"$CITY/.gc/usage.jsonl"
    run_stamp bd-9 --session gk-mine
    [ "$RC" -eq 0 ] || fail "expected rc 0, got $RC"
    updates | grep -q 'usage.output_tokens=100' ||
        fail "another session's spend leaked into this bead: $(updates)"
}

test_session_identity_falls_back_to_bead_metadata() {
    usage_row gk-frombead gastown__polecat-gk-frombead claude-opus-5 3 30 3 3 >"$CITY/.gc/usage.jsonl"
    cat >"$TMP/bead.json" <<'JSON'
[{"id":"bd-10","metadata":{"gc.session_id":"gk-frombead","gc.session_name":"gastown__polecat-gk-frombead"}}]
JSON
    export GC_BEAD_JSON="$TMP/bead.json"
    run_stamp bd-10
    export GC_BEAD_JSON=""
    [ "$RC" -eq 0 ] || fail "should resolve the session from the bead, got rc $RC ($ERR)"
    updates | grep -q 'usage.output_tokens=30' ||
        fail "bead-metadata fallback did not meter: $(updates)"
}

test_dry_run_measures_without_stamping() {
    usage_row gk-dry gastown__polecat-gk-dry claude-opus-5 11 22 33 44 >"$CITY/.gc/usage.jsonl"
    run_stamp bd-11 --session gk-dry --dry-run
    [ "$RC" -eq 0 ] || fail "dry run should still exit 0, got $RC"
    printf '%s\n' "$OUT" | grep -q "^TOTAL	claude	1	11	22	33	44$" ||
        fail "dry run must still report the measurement: $OUT"
    [ -z "$(updates)" ] || fail "dry run must not stamp anything: $(updates)"
}

test_dry_run_does_not_stamp_unmetered_either() {
    usage_row gk-x gastown__polecat-gk-x claude-opus-5 1 1 1 1 >"$CITY/.gc/usage.jsonl"
    run_stamp bd-12 --session gk-nope --dry-run
    [ "$RC" -eq 1 ] || fail "unmetered dry run should still report rc 1, got $RC"
    [ -z "$(updates)" ] || fail "dry run must not stamp unmetered either: $(updates)"
}

test_missing_bead_id_fails_loud() {
    usage_row gk-a gastown__polecat-gk-a claude-opus-5 1 1 1 1 >"$CITY/.gc/usage.jsonl"
    run_stamp --session gk-a
    [ "$RC" -eq 2 ] || fail "a missing bead id must exit 2, got $RC"
}

test_unknown_flag_fails_loud() {
    run_stamp bd-13 --nope
    [ "$RC" -eq 2 ] || fail "an unknown flag must exit 2, got $RC"
}

test_no_session_identity_fails_loud() {
    usage_row gk-a gastown__polecat-gk-a claude-opus-5 1 1 1 1 >"$CITY/.gc/usage.jsonl"
    # No --session, no env, and `gc bd show` fails in the stub without
    # GC_BEAD_JSON. Nothing to join on: that is a broken invocation, not an
    # unmetered session, so it must not stamp a misleading "unmetered".
    run_stamp bd-14
    [ "$RC" -eq 2 ] || fail "no resolvable session identity must exit 2, got $RC"
    [ -z "$(updates)" ] || fail "a broken invocation must not stamp anything: $(updates)"
}

test_missing_city_fails_loud() {
    export GC_CITY="$TMP/nope"
    run_stamp bd-15 --session gk-a
    export GC_CITY="$CITY"
    [ "$RC" -eq 2 ] || fail "an unresolvable city must exit 2, got $RC"
}

test_script_is_executable() {
    # gastown/doctor/check-scripts enforces this pack-wide; assert it here too
    # so a lost mode bit fails in the test that owns the script.
    [ -x "$SCRIPT" ] || fail "$SCRIPT must be executable"
}

test_uses_no_bash4_only_constructs() {
    grep -nE 'declare -A|local -A|\$\{[A-Za-z_][A-Za-z0-9_]*,,\}|\$\{[A-Za-z_][A-Za-z0-9_]*\^\^\}|readarray|mapfile' \
        "$SCRIPT" && fail "bash 4-only construct found — the fleet includes macOS bash 3.2"
    return 0
}

test_single_model_aggregates_and_stamps
test_dominant_model_is_highest_output_and_breakdown_is_kept
test_single_model_omits_breakdown
test_unmetered_never_writes_zero_tokens
test_missing_sink_is_unmetered_with_provider_hint
test_disabled_metrics_is_named_in_the_reason
test_matches_on_worker_name_when_session_id_differs
test_compute_rows_are_not_counted_as_tokens
test_other_sessions_are_excluded
test_session_identity_falls_back_to_bead_metadata
test_dry_run_measures_without_stamping
test_dry_run_does_not_stamp_unmetered_either
test_missing_bead_id_fails_loud
test_unknown_flag_fails_loud
test_no_session_identity_fails_loud
test_missing_city_fails_loud
test_script_is_executable
test_uses_no_bash4_only_constructs

echo "usage stamp tests passed"
