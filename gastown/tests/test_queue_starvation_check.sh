#!/usr/bin/env bash
# Tests for the queue-starvation check (gp-b3x).
#
# The bead's acceptance clause is the reason this file is shaped the way it is:
#
#   "Not 'the step runs clean' — that is the current broken state. The step must
#    be shown to FIRE on a synthetic starved queue. A check that cannot produce a
#    positive has not been tested."
#
# So the first test below is a true positive, and each confirmed break gets a
# test that fails if it comes back. The step this replaces returned A=0 for every
# session forever and reported clean, because each of its faults degraded to zero
# rows and zero rows read as an empty queue:
#
#   1. `gc agents list --json --active` does not exist. It prints an {"ok":false}
#      envelope to STDOUT and exits 1, but it sat at the head of a pipeline whose
#      status the shell takes from the tail, so nothing noticed.
#   2. `--status=open` cannot see a CLAIMED bead, and claimed is what a session
#      holding work actually looks like.
#   3. `--assignee` is exact, and Gas Town writes several spellings — agent
#      ADDRESS `alpha/gastown.refinery` for a handoff, session NAME
#      `gastown__polecat-gk-2` for a polecat self-claim, and forms like
#      `gascity-packs--gastown__refinery` observed live. Probing one misses the
#      rest entirely, so the identities are unioned per session.
#
# One reported break is deliberately NOT tested as a break, because it is not
# one: `assignee` is present on `gc bd list --json` for any bead that HAS an
# assignee, and absent only where there is none. The report read an unassigned
# bead's key list as proof the field did not exist. What IS real underneath it —
# `owner` is the human who filed the bead, never the agent holding it — is pinned
# by test_owner_is_never_read_as_assignee.
#
# Every fixture here is synthetic. Nothing in this suite touches the real ledger.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT/gastown/assets/scripts/queue-starvation-check.sh"
WRAPPER="$ROOT/gastown/commands/queue-starvation-check/run.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# The `gc` the check talks to. Everything it needs is served from two fixture
# files, so a test declares a city as data rather than by standing one up.
#
# GC_FAIL_MODE injects the failure shapes that matter:
#   roster-unknown-command  the gp-b3x shape — {"ok":false} on STDOUT, exit 1
#   roster-exit             a plain non-zero exit with no payload
#   roster-drift            a well-formed object with no `sessions` key
#   bdlist-exit             the queue query failing
write_gc_stub() {
    local bin="$1"
    mkdir -p "$bin"
    cat >"$bin/gc" <<'SH'
#!/usr/bin/env sh
case "$*" in
    *"session"*"list"*)
        case "${GC_FAIL_MODE:-}" in
            roster-unknown-command)
                # Exactly what `gc agents list --json --active` does: the error
                # envelope goes to STDOUT and the exit code is 1.
                printf '{"schema_version":"1","ok":false,"error":{"code":"json_command_not_found","message":"command \\"agents list\\" was not found","exit_code":1}}'
                exit 1
                ;;
            roster-exit) exit 1 ;;
            roster-drift) printf '{"schema_version":"1","ok":true,"agents":[]}' ;;
            *) cat "$GC_SESSIONS_JSON" ;;
        esac
        ;;
    *"bd"*"list"*)
        case "${GC_FAIL_MODE:-}" in
            bdlist-exit) exit 1 ;;
            *) cat "$GC_BEADS_JSON" ;;
        esac
        ;;
    *) printf '{}' ;;
esac
SH
    chmod +x "$bin/gc"
}

# run_check <sessions-json> <beads-json> [env assignments...]
run_check() {
    local sessions="$1" beads="$2"
    shift 2
    printf '%s' "$sessions" >"$SESSIONS"
    printf '%s' "$beads" >"$BEADS"
    set +e
    # ${1+"$@"} rather than "$@": bash 3.2 under `set -u` treats an empty "$@"
    # as an unbound variable.
    OUT=$(env GC_CITY="$CITY" GC_SESSIONS_JSON="$SESSIONS" GC_BEADS_JSON="$BEADS" \
        PATH="$BIN:$PATH" ${1+"$@"} bash "$SCRIPT" 2>"$ERRFILE")
    RC=$?
    set -e
    ERR=$(cat "$ERRFILE")
}

# run_wrapper — invoke the command wrapper the way `gc` does.
#
# GC_CITY is explicitly UNSET, because that is the state `gc` hands a pack
# command: it exports GC_CITY_PATH, not GC_CITY. It runs from $NOCITY — a
# directory with no city.toml above it — so the wrapper's own resolution is the
# only reason it can succeed. A polecat worktree lives under <city>/.gc/, so
# running these from the repo would let the check's walk-up fallback find the
# developer's real city and pass whether or not the wrapper resolves anything.
run_wrapper() {
    local sessions="$1" beads="$2"
    shift 2
    printf '%s' "$sessions" >"$SESSIONS"
    printf '%s' "$beads" >"$BEADS"
    set +e
    OUT=$(cd "$NOCITY" && env -u GC_CITY \
        GC_CITY_PATH="${WRAP_CITY-$CITY}" GC_PACK_DIR="${WRAP_PACK-$ROOT/gastown}" \
        GC_SESSIONS_JSON="$SESSIONS" GC_BEADS_JSON="$BEADS" \
        PATH="$BIN:$PATH" ${1+"$@"} sh "$WRAPPER" 2>"$ERRFILE")
    RC=$?
    set -e
    ERR=$(cat "$ERRFILE")
}

# GNU spells epoch->RFC3339 `date -d @N`; BSD/macOS spells it `date -r N`. Probe
# once and fail loud rather than chaining, so a broken probe cannot silently
# yield empty timestamps that turn every assertion into a confusing parse error.
if date -u -d '@0' +%Y >/dev/null 2>&1; then
    epoch_utc() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
elif date -u -r 0 +%Y >/dev/null 2>&1; then
    epoch_utc() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }
else
    echo "FAIL: no usable date(1) — neither GNU '-d @<epoch>' nor BSD '-r <epoch>'" >&2
    exit 1
fi

ts_ago() { epoch_utc "$(( $(date -u +%s) - $1 ))"; }
ts_ahead() { epoch_utc "$(( $(date -u +%s) + $1 ))"; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
CITY="$tmp/city"
BIN="$tmp/bin"
SESSIONS="$tmp/sessions.json"
BEADS="$tmp/beads.json"
ERRFILE="$tmp/stderr.txt"
NOCITY="$tmp/nocity"
mkdir -p "$CITY" "$NOCITY"
: >"$CITY/city.toml"
write_gc_stub "$BIN"

FRESH=$(ts_ago 120)      # 2m — well inside every window
STALE=$(ts_ago 2700)     # 45m — past the 30m coordination window, inside 120m
DEAD=$(ts_ago 49320)     # 13h42m — the #1833 refinery stall this check exists for

# A refinery session addressed the way a handoff addresses it.
REFINERY_SESSION='{"sessions":[{"id":"gk-1","name":"alpha/gastown.refinery","rig":"alpha","template":"alpha/gastown.refinery","state":"active","session_name":"gastown__refinery-gk-1","agent_name":"alpha/gastown.refinery","alias":"alpha/gastown.refinery","closed":false}]}'

# A polecat session, which self-claims under its SESSION NAME.
POLECAT_SESSION='{"sessions":[{"id":"gk-2","name":"alpha/gastown.nux","rig":"alpha","template":"alpha/gastown.polecat","state":"active","session_name":"gastown__polecat-gk-2","agent_name":"alpha/gastown.nux","alias":"alpha/gastown.nux","closed":false}]}'

bead() { # bead <id> <assignee> <updated_at> [status]
    printf '{"id":"%s","assignee":"%s","updated_at":"%s","status":"%s","owner":"jeremy@geocaching.com"}' \
        "$1" "$2" "$3" "${4:-open}"
}

# --- the acceptance clause: it must be able to produce a positive -------------

test_starved_queue_fires() {
    # THE test. Seven beads queued on a refinery whose queue has not moved for
    # 13h42m — the shape of upstream #1833, which the old step passed silently.
    local beads='['
    local i
    for i in 1 2 3 4 5 6 7; do
        [ "$i" -eq 1 ] || beads="$beads,"
        beads="$beads$(bead "b-$i" "alpha/gastown.refinery" "$DEAD")"
    done
    beads="$beads]"

    run_check "$REFINERY_SESSION" "$beads"

    [ "$RC" -eq 1 ] || fail "a starved queue MUST exit 1 — this is the acceptance clause, got $RC ($OUT / $ERR)"
    printf '%s' "$OUT" | grep -q '^starved	alpha	alpha/gastown.refinery	' ||
        fail "a starved refinery should report the starved verdict, got: $OUT"
    printf '%s' "$OUT" | grep -q '	7	' ||
        fail "the row should carry the queue depth (7), got: $OUT"
    printf '%s' "$ERR" | grep -q '1 starved' ||
        fail "the summary should count the starved session, got: $ERR"
}

test_idle_session_is_not_flagged() {
    # Step 4 of the patrol: A == 0 is healthy. An idle-but-ready refinery is what
    # a quiet town looks like, and flagging it would make the check unusable.
    run_check "$REFINERY_SESSION" '[]'
    [ "$RC" -eq 0 ] || fail "an idle session must not be flagged, got $RC ($OUT / $ERR)"
    printf '%s' "$OUT" | grep -q '^idle	alpha	alpha/gastown.refinery	' ||
        fail "an empty queue should report idle, got: $OUT"
    printf '%s' "$OUT" | grep -q 'starved' && fail "an idle session must never be starved"
    return 0
}

test_fresh_queue_is_working_not_starved() {
    run_check "$REFINERY_SESSION" "[$(bead b-1 'alpha/gastown.refinery' "$FRESH")]"
    [ "$RC" -eq 0 ] || fail "a moving queue must exit 0, got $RC ($OUT / $ERR)"
    printf '%s' "$OUT" | grep -q '^working	alpha	alpha/gastown.refinery	.*	1	' ||
        fail "a fresh queue should report working with its depth, got: $OUT"
}

# --- break 3: two assignee namespaces, both must be seen ----------------------

test_agent_address_assignee_is_seen() {
    # A refinery handoff writes the agent ADDRESS. A check that probed only the
    # session name would score this queue 0 and report the refinery idle.
    run_check "$REFINERY_SESSION" "[$(bead b-1 'alpha/gastown.refinery' "$DEAD")]"
    [ "$RC" -eq 1 ] || fail "work under the agent ADDRESS must be seen, got $RC ($OUT)"
    printf '%s' "$OUT" | grep -q '^starved	' ||
        fail "an address-assigned queue should starve, got: $OUT"
}

test_session_name_assignee_is_seen() {
    # A polecat self-claim writes the SESSION NAME. A check that probed only the
    # agent address would score this queue 0 and report the polecat idle. Both
    # halves of break 3 need their own test — a fix that swapped which single
    # namespace it probed would pass one of these and fail the other.
    run_check "$POLECAT_SESSION" "[$(bead b-1 'gastown__polecat-gk-2' "$DEAD")]" \
        GASTOWN_STARVATION_POLECAT_MIN=30
    [ "$RC" -eq 1 ] || fail "work under the SESSION NAME must be seen, got $RC ($OUT)"
    printf '%s' "$OUT" | grep -q '^starved	alpha	alpha/gastown.nux	' ||
        fail "a session-name-assigned queue should starve, got: $OUT"
}

test_both_namespaces_union_without_double_counting() {
    # One bead under each spelling on the same session: the union is 2, not 4.
    local beads
    beads="[$(bead b-1 'alpha/gastown.nux' "$DEAD"),$(bead b-2 'gastown__polecat-gk-2' "$DEAD")]"
    run_check "$POLECAT_SESSION" "$beads" GASTOWN_STARVATION_POLECAT_MIN=30
    printf '%s' "$OUT" | grep -q '	2	' ||
        fail "both namespaces should union to a depth of 2, got: $OUT"
}

test_duplicate_identity_spellings_are_not_double_counted() {
    # session_name == agent_name == alias. Summing without `unique` would report
    # three times the real depth and could starve a session on phantom work.
    local sess='{"sessions":[{"id":"gk-3","name":"solo","rig":"alpha","template":"alpha/gastown.refinery","state":"active","session_name":"solo","agent_name":"solo","alias":"solo","closed":false}]}'
    run_check "$sess" "[$(bead b-1 'solo' "$FRESH")]"
    printf '%s' "$OUT" | grep -q '^working	alpha	solo	.*	1	' ||
        fail "a session with one identity spelling repeated should count depth 1, got: $OUT"
}

# --- break 2: the assignee is not on the list payload, and owner is not it ----

test_owner_is_never_read_as_assignee() {
    # `owner` is the human who filed the bead; `assignee` is the agent holding
    # it. A fix that reached for `.owner` would attribute every bead in the city
    # to jeremy@geocaching.com and never match a session. The two are easy to
    # conflate because an unassigned bead omits `assignee` from the payload
    # entirely, leaving `owner` looking like the only identity on offer.
    local beads
    beads="[{\"id\":\"b-1\",\"owner\":\"jeremy@geocaching.com\",\"updated_at\":\"$DEAD\",\"status\":\"open\"}]"
    run_check "$REFINERY_SESSION" "$beads"
    [ "$RC" -eq 0 ] || fail "an unassigned bead must not be attributed to a session, got $RC ($OUT)"
    printf '%s' "$OUT" | grep -q '^idle	' ||
        fail "a bead with only an owner leaves the session idle, got: $OUT"
}

# --- break 2b: claimed work must be visible -----------------------------------

test_claimed_in_progress_work_is_queried() {
    # The replaced step queried `--status=open` alone, so a session holding a
    # CLAIMED bead — the commonest starvation shape — scored 0. Assert the check
    # asks for in_progress too; the stub cannot enforce the filter itself, so
    # this pins the query the check actually issues.
    grep -Fq 'open,in_progress' "$SCRIPT" ||
        fail "the check must query open,in_progress — an open-only query cannot see claimed work"
    # ...and that it uses the comma form. Repeating -s silently overwrites the
    # previous value, so two -s flags would quietly query only the last one.
    ! grep -qE '\-\-status=[a-z_]+ .*--status=' "$SCRIPT" ||
        fail "multi-status must use the comma form; repeated --status silently overwrites"
}

# --- break 1: an absent roster command must never read as an empty city -------

test_unknown_roster_command_fails_loud() {
    # THE gp-b3x shape. `gc agents list --json --active` prints {"ok":false} to
    # STDOUT and exits 1. In the original pipeline the exit status was discarded
    # and jq turned the object into zero rows, so this read as "no sessions" —
    # a clean patrol. It must be exit 2: nothing was measured.
    run_check "$REFINERY_SESSION" '[]' GC_FAIL_MODE=roster-unknown-command
    [ "$RC" -eq 2 ] || fail "an unknown roster command must exit 2, not read as an empty city, got $RC"
    printf '%s' "$ERR" | grep -q 'NOT measured' ||
        fail "the failure must say starvation was not measured, got: $ERR"
    printf '%s' "$OUT" | grep -q 'idle' &&
        fail "a failed roster read must not emit health rows"
    return 0
}

test_ok_false_envelope_is_caught_even_with_a_zero_exit() {
    # The guard must read the PAYLOAD, not just the exit status. The original bug
    # survived precisely because the status was swallowed by a pipeline, so a
    # status-only guard would be defeated again by any refactor that pipes.
    grep -Fq '.ok == false' "$SCRIPT" ||
        fail "the check must reject an {\"ok\":false} envelope by payload, not by exit status alone"
}

test_unreadable_roster_fails_loud() {
    run_check "$REFINERY_SESSION" '[]' GC_FAIL_MODE=roster-exit
    [ "$RC" -eq 2 ] || fail "a failing 'gc session list' must exit 2, got $RC"
    printf '%s' "$ERR" | grep -q 'NOT measured' ||
        fail "a failed roster read should say starvation was not measured, got: $ERR"
}

test_roster_schema_drift_fails_loud() {
    # A well-formed object with no `sessions` key. Without an explicit check this
    # yields zero rows and exits 0 — schema drift reading as a clean town.
    run_check "$REFINERY_SESSION" '[]' GC_FAIL_MODE=roster-drift
    [ "$RC" -eq 2 ] || fail "a roster with no sessions array must exit 2, got $RC ($OUT)"
    printf '%s' "$ERR" | grep -q 'schema drifted' ||
        fail "the drift message should name the drift, got: $ERR"
}

test_empty_city_is_not_drift() {
    # The mirror of the test above: a genuinely empty roster is exit 0. A check
    # that cannot tell "no sessions" from "no sessions key" would cry drift on
    # every quiet city and get muted.
    run_check '{"sessions":[]}' '[]'
    [ "$RC" -eq 0 ] || fail "a genuinely empty roster is not drift, got $RC ($ERR)"
    printf '%s' "$ERR" | grep -q 'nothing to check' ||
        fail "an empty roster should say there was nothing to check, got: $ERR"
}

test_bead_query_failure_fails_loud() {
    run_check "$REFINERY_SESSION" '[]' GC_FAIL_MODE=bdlist-exit
    [ "$RC" -eq 2 ] || fail "a failing 'gc bd list' must exit 2, got $RC"
    printf '%s' "$ERR" | grep -q 'NOT measured' || fail "expected a not-measured message, got: $ERR"
}

test_non_array_queue_payload_fails_loud() {
    # The queue query answering with an error envelope rather than an array is
    # the same shape as break 1, one call further down. It must not be read as
    # an empty queue.
    run_check "$REFINERY_SESSION" '{"ok":false,"error":{"message":"boom"}}'
    [ "$RC" -eq 2 ] || fail "a non-array queue payload must exit 2, got $RC ($OUT)"
    printf '%s' "$ERR" | grep -q 'NOT measured' || fail "expected a not-measured message, got: $ERR"
}

test_queue_is_read_in_one_query() {
    # One `gc bd list` carries id, assignee and updated_at together. An earlier
    # draft added a second `gc bd show` pass on the belief that the listing could
    # not report assignees — it can; the field is simply omitted on beads that have
    # none. Pin the single-query shape so that round trip does not creep back.
    ! grep -qE '^[^#]*gc bd show' "$SCRIPT" ||
        fail "one 'gc bd list' carries the queue — a second 'gc bd show' pass is redundant"
}

test_session_with_no_identity_is_drift_not_idle() {
    # No session_name, agent_name, alias or name: every lookup would return 0 and
    # the session would read idle. That is the silent-green shape, so it is a
    # finding about the check rather than a verdict about the session.
    run_check '{"sessions":[{"id":"gk-9","rig":"alpha","state":"active","template":"alpha/gastown.refinery","closed":false}]}' '[]'
    [ "$RC" -eq 2 ] || fail "a session with no queryable identity must exit 2, got $RC ($OUT)"
    printf '%s' "$OUT" | grep -q '^schema-drift	alpha	gk-9	' ||
        fail "the identity-less session should be named, got: $OUT"
}

test_queued_beads_with_no_timestamp_are_drift_not_working() {
    # Work is present but the signal that says whether it moved is gone. Falling
    # through to "working" would report health that was never measured.
    local beads
    beads="[{\"id\":\"b-1\",\"assignee\":\"alpha/gastown.refinery\",\"status\":\"open\"}]"
    run_check "$REFINERY_SESSION" "$beads"
    [ "$RC" -eq 2 ] || fail "queued beads with no updated_at must exit 2, got $RC ($OUT)"
    printf '%s' "$OUT" | grep -q '^schema-drift	alpha	alpha/gastown.refinery	' ||
        fail "the drifted session should be named, got: $OUT"
    printf '%s' "$OUT" | grep -q 'working' &&
        fail "an unmeasurable signal must never report working"
    return 0
}

# --- windows and scope --------------------------------------------------------

test_polecat_window_is_more_lenient() {
    # 45m of silence starves a refinery but not a polecat, which legitimately
    # spends longer inside one implement step. Exempting polecats entirely is how
    # a stuck polecat becomes invisible, so they get a window rather than a pass.
    run_check "$POLECAT_SESSION" "[$(bead b-1 'gastown__polecat-gk-2' "$STALE")]"
    [ "$RC" -eq 0 ] || fail "45m must be inside the 120m polecat window, got $RC ($OUT)"
    printf '%s' "$OUT" | grep -q '^working	' || fail "expected working, got: $OUT"

    run_check "$REFINERY_SESSION" "[$(bead b-1 'alpha/gastown.refinery' "$STALE")]"
    [ "$RC" -eq 1 ] || fail "45m must breach the 30m coordination window, got $RC ($OUT)"

    # ...and a polecat silent for 13h42m is still caught.
    run_check "$POLECAT_SESSION" "[$(bead b-1 'gastown__polecat-gk-2' "$DEAD")]"
    [ "$RC" -eq 1 ] || fail "a polecat silent for 13h42m must still starve, got $RC ($OUT)"
}

test_windows_are_configurable() {
    run_check "$REFINERY_SESSION" "[$(bead b-1 'alpha/gastown.refinery' "$STALE")]" \
        GASTOWN_STARVATION_STALE_MIN=90
    [ "$RC" -eq 0 ] || fail "a 90m window should tolerate 45m, got $RC ($OUT)"
    printf '%s' "$ERR" | grep -q 'windows 90m' ||
        fail "the summary should report the configured window, got: $ERR"
}

test_bad_window_fails_loudly() {
    run_check '{"sessions":[]}' '[]' GASTOWN_STARVATION_STALE_MIN=abc
    [ "$RC" -eq 2 ] || fail "a non-numeric window must exit 2, got $RC"
    run_check '{"sessions":[]}' '[]' GASTOWN_STARVATION_POLECAT_MIN=0
    [ "$RC" -eq 2 ] || fail "a zero window must exit 2, got $RC"
}

test_controller_owned_states_are_skipped() {
    # start-pending / creating / drained / suspended are the controller's
    # business. A polecat mid-spawn holding a freshly-routed bead is not starved.
    local sess='{"sessions":[
      {"id":"gk-a","name":"a/r","rig":"a","template":"a/gastown.refinery","state":"creating","agent_name":"a/r","closed":false},
      {"id":"gk-b","name":"b/r","rig":"b","template":"b/gastown.refinery","state":"start-pending","agent_name":"b/r","closed":false},
      {"id":"gk-c","name":"c/r","rig":"c","template":"c/gastown.refinery","state":"suspended","agent_name":"c/r","closed":false},
      {"id":"gk-d","name":"d/r","rig":"d","template":"d/gastown.refinery","state":"active","agent_name":"d/r","closed":true}
    ]}'
    local beads
    beads="[$(bead b-1 'a/r' "$DEAD"),$(bead b-2 'b/r' "$DEAD"),$(bead b-3 'c/r' "$DEAD"),$(bead b-4 'd/r' "$DEAD")]"
    run_check "$sess" "$beads"
    [ "$RC" -eq 0 ] || fail "controller-owned states must not be flagged, got $RC ($OUT)"
    [ -z "$OUT" ] || fail "controller-owned states should emit no rows, got: $OUT"
}

test_asleep_session_holding_work_is_checked() {
    # A session that fell asleep on a full queue is precisely the shape this
    # check is for, so `asleep` is in scope even though it looks like rest.
    local sess='{"sessions":[{"id":"gk-s","name":"a/gastown.refinery","rig":"a","template":"a/gastown.refinery","state":"asleep","agent_name":"a/gastown.refinery","closed":false}]}'
    run_check "$sess" "[$(bead b-1 'a/gastown.refinery' "$DEAD")]"
    [ "$RC" -eq 1 ] || fail "an asleep session holding a stale queue must starve, got $RC ($OUT)"
}

test_every_eligible_session_gets_a_row() {
    # A regression test for a silently-dropped session. The queries used to live
    # INSIDE the roster read loop, where a child process reading stdin ate the
    # loop's own here-doc input — 18 sessions in, 17 rows out, one agent never
    # checked and no indication it had been skipped. Measured, not theorised.
    local sess='{"sessions":['
    local beads='['
    local i
    for i in 1 2 3 4 5 6 7 8 9; do
        [ "$i" -eq 1 ] || { sess="$sess,"; beads="$beads,"; }
        sess="$sess{\"id\":\"gk-$i\",\"name\":\"r$i/gastown.refinery\",\"rig\":\"r$i\",\"template\":\"r$i/gastown.refinery\",\"state\":\"active\",\"agent_name\":\"r$i/gastown.refinery\",\"closed\":false}"
        beads="$beads$(bead "b-$i" "r$i/gastown.refinery" "$FRESH")"
    done
    sess="$sess]}"
    beads="$beads]"

    run_check "$sess" "$beads"
    [ "$(printf '%s\n' "$OUT" | grep -c .)" -eq 9 ] ||
        fail "every one of the 9 eligible sessions must get a row, got: $OUT"
    printf '%s' "$ERR" | grep -q 'checked 9 session' ||
        fail "the summary must account for all 9, got: $ERR"
    for i in 1 2 3 4 5 6 7 8 9; do
        printf '%s' "$OUT" | grep -q "r$i/gastown.refinery" ||
            fail "session r$i was silently skipped, got: $OUT"
    done
}

test_future_stamp_is_clock_skew_not_progress() {
    run_check "$REFINERY_SESSION" "[$(bead b-1 'alpha/gastown.refinery' "$(ts_ahead 3600)")]"
    [ "$RC" -eq 0 ] || fail "a future stamp is skew, not staleness, got $RC ($OUT)"
    printf '%s' "$OUT" | grep -q '^working	alpha	alpha/gastown.refinery	.*	1	0	' ||
        fail "a future stamp should clamp the age to 0, got: $OUT"
}

test_zero_time_sentinel_is_drift_not_ancient() {
    # `gc` emits the Go zero-time sentinel for a field it has never set. Parsing
    # it as a real instant would starve a session on a bead it just received.
    run_check "$REFINERY_SESSION" "[$(bead b-1 'alpha/gastown.refinery' '0001-01-01T00:00:00Z')]"
    printf '%s' "$OUT" | grep -q 'starved' &&
        fail "the zero-time sentinel must not be read as an ancient stamp"
    [ "$RC" -eq 2 ] || fail "an unusable stamp means nothing was measured (exit 2), got $RC ($OUT)"
    return 0
}

test_uses_no_bash4_only_constructs() {
    ! grep -nE 'declare -A|local -A|mapfile|readarray|\$\{[A-Za-z_]+\^|\$\{[A-Za-z_]+,,|&>>|\[\[ -v ' "$SCRIPT" >/dev/null ||
        fail "the check must stay bash 3.2 compatible (the fleet includes macOS)"
}

test_check_is_read_only() {
    # It measures and prints. Nudging, mailing and warranting are the deacon's
    # judgment calls, and a check that acted on its own findings would make the
    # patrol step's decision unauditable.
    ! grep -nE '^[^#]*gc (mail|session nudge|bd (create|update|close))' "$SCRIPT" >/dev/null ||
        fail "the check must not mail, nudge, or mutate beads — the deacon owns those decisions"
}

# --- the `gc gastown queue-starvation-check` wrapper --------------------------

test_wrapper_is_executable() {
    # Not merely present: a lost exec bit halts the caller with "permission
    # denied", which reads like a resolver refusal rather than a broken file
    # (gp-ia7).
    [ -x "$WRAPPER" ] || fail "$WRAPPER must be executable"
    [ -f "$ROOT/gastown/commands/queue-starvation-check/help.md" ] ||
        fail "missing commands/queue-starvation-check/help.md"
    [ -x "$SCRIPT" ] || fail "$SCRIPT must be executable"
}

test_wrapper_rejects_missing_pack_context() {
    # Invoked by path instead of through `gc`, so GC_PACK_DIR is empty. It must
    # fail loudly rather than resolving to /assets/scripts/... and reporting a
    # clean scan (gp-3qb).
    WRAP_PACK="" run_wrapper "$REFINERY_SESSION" '[]'
    [ "$RC" -eq 2 ] || fail "missing GC_PACK_DIR must exit 2, got $RC"
    printf '%s' "$ERR" | grep -q 'missing Gas City pack context' ||
        fail "the wrapper must name the missing pack context, got: $ERR"
}

test_wrapper_rejects_missing_city_context() {
    WRAP_CITY="" run_wrapper "$REFINERY_SESSION" '[]'
    [ "$RC" -eq 2 ] || fail "missing GC_CITY_PATH must exit 2, got $RC"
}

test_wrapper_reports_a_pack_without_the_check() {
    # An older pack version that predates the check. Exit 2 — "not measured" —
    # never 0, which would read as "every queue is healthy".
    WRAP_PACK="$tmp" run_wrapper "$REFINERY_SESSION" '[]'
    [ "$RC" -eq 2 ] || fail "a pack missing the check must exit 2, got $RC"
    printf '%s' "$ERR" | grep -q 'not found in this pack version' ||
        fail "the wrapper must say the check is missing, got: $ERR"
}

test_wrapper_resolves_the_city_from_pack_context() {
    run_wrapper "$REFINERY_SESSION" '[]'
    [ "$RC" -eq 0 ] ||
        fail "the wrapper must resolve the city from GC_CITY_PATH, got $RC: $ERR"
    printf '%s' "$OUT" | grep -q '^idle	alpha	alpha/gastown.refinery	' ||
        fail "the wrapper should relay the check's TSV rows, got: $OUT"
}

test_wrapper_passes_findings_exit_through() {
    # Exit 1 is a verdict, not an error to swallow: the deacon branches on it to
    # decide whether to nudge. A wrapper that collapsed it to 0 would restore the
    # original silence through a different route.
    run_wrapper "$REFINERY_SESSION" "[$(bead b-1 'alpha/gastown.refinery' "$DEAD")]"
    [ "$RC" -eq 1 ] || fail "the wrapper must pass through exit 1 (findings), got $RC"
    printf '%s' "$OUT" | grep -q '^starved	alpha	' || fail "expected a starved row, got: $OUT"
}

test_wrapper_passes_the_windows_through() {
    run_wrapper "$REFINERY_SESSION" "[$(bead b-1 'alpha/gastown.refinery' "$FRESH")]" \
        GASTOWN_STARVATION_STALE_MIN=1
    [ "$RC" -eq 1 ] ||
        fail "a 1m window must reach the check and starve a 2m-old queue, got $RC ($OUT)"
}

# --- the caller actually invokes it the resolvable way ------------------------

test_formula_invokes_the_command_not_the_path() {
    local formula="$ROOT/gastown/formulas/mol-deacon-patrol.toml"
    grep -Fq 'gc gastown queue-starvation-check' "$formula" ||
        fail "mol-deacon-patrol must run the check as 'gc gastown queue-starvation-check'"
    # The dead roster call must not survive as CODE. Match the construct — a
    # line that runs it — not the bare string: the prose above the snippet
    # quotes `gc agents list --json --active` on purpose, to record what was
    # broken and why, and a string match would forbid explaining it.
    ! grep -qE '^[[:space:]]*gc agents list' "$formula" ||
        fail "the non-existent 'gc agents list' must not survive as an executable line"
    # It must also never come back as the head of a pipeline, which is what hid
    # its non-zero exit in the first place.
    ! grep -qE '^[[:space:]]*gc [a-z]+ list .*\| *jq' "$formula" ||
        fail "a roster call piped straight into jq hides its exit status — that is the original bug"
    ! grep -qE '^[[:space:]]*CHECK=' "$formula" ||
        fail "formula must not resolve the check into a path variable"
    ! grep -qE '^[[:space:]]*(bash|sh|exec)[[:space:]].*GC_PACK_DIR' "$formula" ||
        fail "formula must not execute a script through ambient GC_PACK_DIR"
}

test_formula_treats_a_silent_failure_as_not_measured() {
    # `gc` reports an unknown pack subcommand with exit 1 and NO stdout, which is
    # otherwise indistinguishable from exit 1 with findings. The step has to
    # separate them, or a city whose pin predates this command reads every patrol
    # as a clean queue — the original bug, restored by deployment lag.
    local formula="$ROOT/gastown/formulas/mol-deacon-patrol.toml"
    grep -Fq 'DID NOT RUN' "$formula" ||
        fail "the step must distinguish 'exit 1 with no rows' (did not run) from findings"
}

test_starved_queue_fires
test_idle_session_is_not_flagged
test_fresh_queue_is_working_not_starved
test_agent_address_assignee_is_seen
test_session_name_assignee_is_seen
test_both_namespaces_union_without_double_counting
test_duplicate_identity_spellings_are_not_double_counted
test_owner_is_never_read_as_assignee
test_claimed_in_progress_work_is_queried
test_unknown_roster_command_fails_loud
test_ok_false_envelope_is_caught_even_with_a_zero_exit
test_unreadable_roster_fails_loud
test_roster_schema_drift_fails_loud
test_empty_city_is_not_drift
test_bead_query_failure_fails_loud
test_non_array_queue_payload_fails_loud
test_queue_is_read_in_one_query
test_session_with_no_identity_is_drift_not_idle
test_queued_beads_with_no_timestamp_are_drift_not_working
test_polecat_window_is_more_lenient
test_windows_are_configurable
test_bad_window_fails_loudly
test_controller_owned_states_are_skipped
test_asleep_session_holding_work_is_checked
test_every_eligible_session_gets_a_row
test_future_stamp_is_clock_skew_not_progress
test_zero_time_sentinel_is_drift_not_ancient
test_uses_no_bash4_only_constructs
test_check_is_read_only
test_wrapper_is_executable
test_wrapper_rejects_missing_pack_context
test_wrapper_rejects_missing_city_context
test_wrapper_reports_a_pack_without_the_check
test_wrapper_resolves_the_city_from_pack_context
test_wrapper_passes_findings_exit_through
test_wrapper_passes_the_windows_through
test_formula_invokes_the_command_not_the_path
test_formula_treats_a_silent_failure_as_not_measured

echo "queue starvation check tests passed"
