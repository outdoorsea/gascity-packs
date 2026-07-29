#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT/gastown/assets/scripts/parked-session-check.sh"

# gp-px5: a session parked at a usage-limit prompt reads as `active` to every
# existing detector. The pane fixtures below are transcribed from real captures
# taken during that incident and from healthy sessions in the same city, so the
# patterns are tested against the output shape `gc session peek` actually
# produces rather than an idealized one.

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# ---------------------------------------------------------------- gc stub ----
# Only `gc session list --json` and `gc session peek <id> --lines N` are
# exercised. peek is call-counting per session so a fixture can differ between
# the two peeks — that is the only way to test the stability comparison, which
# is the check's core activity signal.
write_gc_stub() {
    local bin="$1"
    mkdir -p "$bin"
    cat >"$bin/gc" <<'SH'
#!/usr/bin/env sh
if [ "$1" = "session" ] && [ "$2" = "list" ]; then
    if [ -n "${GC_SESSIONS_FAIL:-}" ]; then
        echo "session list exploded" >&2
        exit 1
    fi
    cat "$GC_SESSIONS_JSON"
    exit 0
fi
if [ "$1" = "session" ] && [ "$2" = "peek" ]; then
    id="$3"
    count_file="$GC_PEEK_COUNTS/$id"
    n=$(cat "$count_file" 2>/dev/null || echo 0)
    n=$((n + 1))
    printf '%s' "$n" >"$count_file"
    # A per-call fixture ("<id>.2") wins over the steady-state one ("<id>"),
    # so a test can make the pane change between peeks.
    if [ -f "$GC_PANES/$id.$n" ]; then
        cat "$GC_PANES/$id.$n"
        exit 0
    fi
    if [ -f "$GC_PANES/$id" ]; then
        cat "$GC_PANES/$id"
        exit 0
    fi
    echo "no such session: $id" >&2
    exit 1
fi
printf '{}'
SH
    chmod +x "$bin/gc"

    # A `sleep` shim that records each call and returns immediately. Counting
    # invocations is how the settle gap is asserted: measuring wall-clock instead
    # would need a gap long enough to out-run jq/peek startup overhead, making
    # the test both slow and flaky.
    cat >"$bin/sleep" <<'SH'
#!/usr/bin/env sh
printf '%s\n' "$1" >>"$GC_SLEEP_LOG"
exit 0
SH
    chmod +x "$bin/sleep"
}

# ------------------------------------------------------------- fixtures ------
# A parked pane, transcribed from the gp-px5 incident: the limit banner sits
# immediately above the input box and there is no "esc to interrupt".
pane_parked() {
    cat <<'PANE'
⏺ Running the affected tests before the done sequence.

  ⎿  $ go vet ./...

You've hit your weekly limit - resets Aug 2 at 2pm (America/Los_Angeles)
/usage-credits to finish what you're working on.

────────────────────────────────────────────────────────────────────────────────
❯
────────────────────────────────────────────────────────────────────────────────
  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents
PANE
}

# A working pane: live spinner with an elapsed timer and token counter, and the
# interrupt affordance in the status bar.
pane_working() {
    cat <<'PANE'
⏺ All green on the restored tree at HEAD. Now the done sequence.

✽ Creating… (10m 4s · ↓ 1.3k tokens · thinking with max effort)
────────────────────────────────────────────────────────────────────────────────
❯
────────────────────────────────────────────────────────────────────────────────
  ⏵⏵ bypass permissions on (shift+tab to cycle) · esc to interrupt · ← for age…
PANE
}

# An idle-but-healthy pane. This is the case that makes "lacks esc to interrupt"
# useless on its own: a correctly idle session between turns also lacks it, and
# reports `✻ Worked for …` in the past tense.
pane_idle_healthy() {
    cat <<'PANE'
  IDLE: no work, exiting turn.

✻ Worked for 2m 11s
                                       ✘ Auto-update failed · Run claude doctor
────────────────────────────────────────────────────────────────────────────────
❯ keep waiting for work
────────────────────────────────────────────────────────────────────────────────
  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents
PANE
}

sessions_json() {
    cat <<'JSON'
{"ok":true,"schema_version":"1","sessions":[
  {"id":"gk-park","session_name":"gastown__polecat-gk-park","alias":"tallyup/gastown.slit","rig":"tallyup","state":"active"},
  {"id":"gk-work","session_name":"gastown__polecat-gk-work","alias":"tallyup/gastown.furiosa","rig":"tallyup","state":"active"},
  {"id":"gk-idle","session_name":"gastown__witness-gk-idle","alias":"tallyup/gastown.witness","rig":"tallyup","state":"active"},
  {"id":"gk-slep","session_name":"gastown__refinery-gk-slep","alias":"tallyup/gastown.refinery","rig":"tallyup","state":"asleep"}
]}
JSON
}

# ------------------------------------------------------------- harness -------
# run_check [session-id...] — sets OUT (TSV rows), ERR, RC. Per-case config goes
# in the CHECK_ENV array, which must be an array rather than a string: a pattern
# override legitimately contains spaces, and a word-split `VAR=two words` would
# hand `words` to env as the command to run.
run_check() {
    set +e
    # ${arr[@]+"${arr[@]}"} rather than "${arr[@]}": bash 3.2 under `set -u`
    # treats an empty array expansion as an unbound variable.
    OUT=$(env GC_CITY="$CITY" \
              GC_SESSIONS_JSON="$SESSIONS" \
              GC_PANES="$PANES" \
              GC_PEEK_COUNTS="$COUNTS" \
              GC_SLEEP_LOG="$SLEEPLOG" \
              GC_RIG="${RIGFILTER:-}" \
              PATH="$BIN:$PATH" \
              GASTOWN_PARKED_SETTLE_SECS="${SETTLE:-0}" \
              ${CHECK_ENV[@]+"${CHECK_ENV[@]}"} \
              bash "$SCRIPT" ${1+"$@"} 2>"$ERRFILE")
    RC=$?
    set -e
    ERR=$(cat "$ERRFILE")
}

# verdict_for <session-id> — the verdict column of that session's row, or empty.
verdict_for() {
    printf '%s\n' "$OUT" | awk -v id="$1" -F'\t' '$2 == id { print $1 }'
}

# reset_fixtures — every active session starts with a healthy idle pane, so a
# case only writes the fixture it is actually about. Leaving a session without
# any pane would make the stub's peek fail and report `unpeekable`, which is a
# finding — exit-code assertions would then be measuring the harness rather than
# the case.
reset_fixtures() {
    rm -rf "$PANES" "$COUNTS"
    mkdir -p "$PANES" "$COUNTS"
    : >"$SLEEPLOG"
    sessions_json >"$SESSIONS"
    pane_idle_healthy >"$PANES/gk-park"
    pane_idle_healthy >"$PANES/gk-work"
    pane_idle_healthy >"$PANES/gk-idle"
    CHECK_ENV=()
    SETTLE=0
    RIGFILTER=''
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

CITY="$tmp/city"
BIN="$tmp/bin"
PANES="$tmp/panes"
COUNTS="$tmp/counts"
SESSIONS="$tmp/sessions.json"
ERRFILE="$tmp/stderr"
SLEEPLOG="$tmp/sleeps"

mkdir -p "$CITY"
touch "$CITY/city.toml"
write_gc_stub "$BIN"

# ---------------------------------------------------------------- cases ------

test_parked_session_is_detected() {
    reset_fixtures
    pane_parked >"$PANES/gk-park"
    pane_working >"$PANES/gk-work"
    pane_idle_healthy >"$PANES/gk-idle"

    run_check
    [[ "$RC" -eq 1 ]] || fail "a parked session must be a finding (exit 1), got $RC"
    [[ "$(verdict_for gk-park)" == "parked" ]] ||
        fail "gk-park should be parked, got '$(verdict_for gk-park)'"
    printf '%s\n' "$OUT" | grep -F 'gastown__polecat-gk-park' >/dev/null ||
        fail "the row must carry session_name — it is the join key to the bead assignee"
}

test_working_session_is_never_parked() {
    reset_fixtures
    pane_parked >"$PANES/gk-park"
    pane_working >"$PANES/gk-work"
    pane_idle_healthy >"$PANES/gk-idle"

    run_check
    [[ "$(verdict_for gk-work)" == "busy" ]] ||
        fail "a session showing the interrupt affordance is executing, got '$(verdict_for gk-work)'"
}

test_idle_healthy_session_is_clear_not_parked() {
    # The discriminator is the BANNER, not the absence of "esc to interrupt".
    # A healthy idle session lacks the marker too; if absence were the signal
    # every between-turns session in the city would be reset.
    reset_fixtures
    pane_idle_healthy >"$PANES/gk-idle"
    pane_idle_healthy >"$PANES/gk-park"
    pane_idle_healthy >"$PANES/gk-work"

    run_check
    [[ "$RC" -eq 0 ]] || fail "no banner anywhere means nothing to report, got exit $RC"
    [[ "$(verdict_for gk-idle)" == "clear" ]] ||
        fail "an idle healthy session must be clear, got '$(verdict_for gk-idle)'"
}

test_truncated_interrupt_marker_still_vetoes() {
    # `gc session peek` returns width-truncated lines. If a narrow pane clips
    # "esc to interrupt" mid-word the veto must still fire, because the failure
    # direction matters: a missed detection costs a patrol cycle, a false
    # positive resets a working session.
    reset_fixtures
    pane_parked >"$PANES/gk-park"
    {
        printf 'You'\''ve hit your weekly limit - resets Aug 2 at 2pm\n'
        printf '  ⏵⏵ bypass permissions on (shift+tab to cycle) · esc to inter…\n'
    } >"$PANES/gk-work"

    run_check
    [[ "$(verdict_for gk-work)" == "busy" ]] ||
        fail "a truncated interrupt marker must still veto, got '$(verdict_for gk-work)'"
}

test_banner_in_scrollback_above_tail_is_not_parked() {
    # THE false-positive guard. An agent working on the usage-limit bug quotes
    # the banner verbatim in its own pane. Scanning all of scrollback would
    # reset that healthy agent. Only the pane TAIL counts.
    reset_fixtures
    {
        printf 'You'\''ve hit your weekly limit - resets Aug 2 at 2pm\n'
        printf '/usage-credits to finish what you'\''re working on.\n'
        printf '  ^ quoted from the bead I am fixing\n'
        for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14; do
            printf 'ordinary work line %s\n' "$i"
        done
        printf '  IDLE: no work, exiting turn.\n'
    } >"$PANES/gk-park"

    run_check
    [[ "$(verdict_for gk-park)" == "clear" ]] ||
        fail "a banner scrolled out of the tail window must not be parked, got '$(verdict_for gk-park)'"
    [[ "$RC" -eq 0 ]] || fail "quoted banner text in scrollback must not be a finding, got exit $RC"
}

test_banner_inside_widened_tail_is_detected() {
    # The counterpart to the guard above: the tail window is the knob that
    # decides how far back a banner counts, and widening it must actually widen
    # detection. This pins the window as the mechanism, not an accident.
    reset_fixtures
    {
        printf 'You'\''ve hit your weekly limit - resets Aug 2 at 2pm\n'
        for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14; do
            printf 'ordinary work line %s\n' "$i"
        done
    } >"$PANES/gk-park"

    CHECK_ENV=(GASTOWN_PARKED_TAIL_LINES=30)
    run_check
    [[ "$(verdict_for gk-park)" == "parked" ]] ||
        fail "with a 30-line tail the banner is in window and must be parked, got '$(verdict_for gk-park)'"
}

test_advancing_pane_is_settling_not_parked() {
    # A banner with a pane that is still moving may be auto-retrying. Resetting
    # would interrupt a recovery already under way.
    reset_fixtures
    pane_parked >"$PANES/gk-park.1"
    {
        pane_parked
        printf '⏺ Retrying after the limit cleared.\n'
    } >"$PANES/gk-park.2"

    run_check
    [[ "$(verdict_for gk-park)" == "settling" ]] ||
        fail "an advancing pane must be settling, got '$(verdict_for gk-park)'"
    [[ "$RC" -eq 0 ]] || fail "settling is not actionable and must not be a finding, got exit $RC"
}

test_session_that_wakes_during_settle_gap_is_busy() {
    # It resumed while we waited. The veto is re-checked on the second peek for
    # exactly this case.
    reset_fixtures
    pane_parked >"$PANES/gk-park.1"
    pane_working >"$PANES/gk-park.2"

    run_check
    [[ "$(verdict_for gk-park)" == "busy" ]] ||
        fail "a session that resumed during the gap must be busy, got '$(verdict_for gk-park)'"
    [[ "$RC" -eq 0 ]] || fail "a resumed session must not be a finding, got exit $RC"
}

test_failed_peek_reads_as_unmeasured_not_healthy() {
    reset_fixtures
    # Drop gk-park's pane entirely so the stub's peek exits non-zero.
    rm -f "$PANES/gk-park"

    run_check
    [[ "$(verdict_for gk-park)" == "unpeekable" ]] ||
        fail "a failed peek must report unpeekable, got '$(verdict_for gk-park)'"
    [[ "$RC" -eq 1 ]] || fail "an unmeasured session must not read as health, got exit $RC"
}

test_rig_filter_scopes_the_scan() {
    # The witness is a per-rig agent, and a serial fleet-wide scan costs ~5s per
    # session. GC_RIG bounds it. Town-level sessions (mayor, deacon, dogs) are
    # the deacon's concern, not a rig witness's.
    reset_fixtures
    pane_parked >"$PANES/gk-park"

    RIGFILTER='someotherrig'
    run_check
    [[ "$RC" -eq 0 ]] || fail "a rig with no active sessions has nothing to check, got exit $RC"
    [[ -z "$(verdict_for gk-park)" ]] ||
        fail "a session outside GC_RIG must not be scanned"
    printf '%s' "$ERR" | grep -F "no active session in rig 'someotherrig'" >/dev/null ||
        fail "an empty rig scan must say so plainly rather than reading as health; got: $ERR"

    RIGFILTER='tallyup'
    run_check
    [[ "$(verdict_for gk-park)" == "parked" ]] ||
        fail "a session inside GC_RIG must be scanned, got '$(verdict_for gk-park)'"
}

test_explicit_ids_bypass_the_rig_filter() {
    # An operator triaging a named session should not have to know or match the
    # rig, and the witness's own GC_RIG must not silently suppress the request.
    reset_fixtures
    pane_parked >"$PANES/gk-park"

    RIGFILTER='someotherrig'
    run_check gk-park
    [[ "$(verdict_for gk-park)" == "parked" ]] ||
        fail "an explicitly named session must be scanned regardless of GC_RIG, got '$(verdict_for gk-park)'"
}

test_non_active_sessions_are_skipped() {
    reset_fixtures
    pane_parked >"$PANES/gk-slep"
    pane_idle_healthy >"$PANES/gk-park"
    pane_idle_healthy >"$PANES/gk-work"
    pane_idle_healthy >"$PANES/gk-idle"

    run_check
    [[ -z "$(verdict_for gk-slep)" ]] ||
        fail "an asleep session has no live pane and must not be scanned, got '$(verdict_for gk-slep)'"
    [[ "$RC" -eq 0 ]] || fail "expected exit 0 when only the asleep session has a banner, got $RC"
}

test_explicit_ids_narrow_the_scan() {
    reset_fixtures
    pane_parked >"$PANES/gk-park"
    pane_parked >"$PANES/gk-work"

    run_check gk-park
    [[ "$(verdict_for gk-park)" == "parked" ]] ||
        fail "the requested session must be scanned, got '$(verdict_for gk-park)'"
    [[ -z "$(verdict_for gk-work)" ]] ||
        fail "a session not named on the command line must not be scanned"
}

test_explicit_alias_is_accepted() {
    reset_fixtures
    pane_parked >"$PANES/gk-park"

    run_check tallyup/gastown.slit
    [[ "$(verdict_for gk-park)" == "parked" ]] ||
        fail "an alias must resolve like an id — that is how operators name sessions"
}

test_bare_array_schema_is_tolerated() {
    reset_fixtures
    cat >"$SESSIONS" <<'JSON'
[{"id":"gk-park","session_name":"gastown__polecat-gk-park","alias":"a/b","rig":"tallyup","state":"active"}]
JSON
    pane_parked >"$PANES/gk-park"

    run_check
    [[ "$(verdict_for gk-park)" == "parked" ]] ||
        fail "a bare top-level array must parse; this schema has drifted before"
}

test_tab_in_banner_cannot_forge_columns() {
    reset_fixtures
    printf 'You'\''ve hit your weekly limit\tresets\tAug 2\n' >"$PANES/gk-park"

    run_check
    [[ "$(verdict_for gk-park)" == "parked" ]] || fail "expected parked verdict"
    local cols
    cols=$(printf '%s\n' "$OUT" | awk -F'\t' '$2 == "gk-park" { print NF }')
    [[ "$cols" -eq 6 ]] ||
        fail "a tab in the banner must not forge TSV columns; row had $cols fields, want 6"
}

test_session_list_failure_is_exit_2() {
    reset_fixtures
    CHECK_ENV=(GC_SESSIONS_FAIL=1)
    run_check
    [[ "$RC" -eq 2 ]] || fail "an unreadable session list means nothing was measured (exit 2), got $RC"
    printf '%s' "$ERR" | grep -F 'no session was inspected' >/dev/null ||
        fail "the failure must say plainly that nothing was inspected"
}

test_bad_config_is_exit_2() {
    reset_fixtures
    pane_parked >"$PANES/gk-park"

    CHECK_ENV=(GASTOWN_PARKED_TAIL_LINES=0)
    run_check
    [[ "$RC" -eq 2 ]] || fail "a zero tail window must be rejected, got $RC"

    CHECK_ENV=(GASTOWN_PARKED_TAIL_LINES=abc)
    run_check
    [[ "$RC" -eq 2 ]] || fail "a non-numeric tail window must be rejected, got $RC"

    CHECK_ENV=(GASTOWN_PARKED_SETTLE_SECS=-5)
    run_check
    [[ "$RC" -eq 2 ]] || fail "a negative settle gap must be rejected, got $RC"

    CHECK_ENV=(GASTOWN_PARKED_TAIL_LINES=99 GASTOWN_PARKED_PEEK_LINES=10)
    run_check
    [[ "$RC" -eq 2 ]] || fail "a tail window larger than the capture must be rejected, got $RC"
}

test_custom_patterns_are_honored() {
    # Provider UI copy is not ours and can change without notice. A rig must be
    # able to correct the pattern list without waiting on a pack release.
    reset_fixtures
    printf 'Some brand new limit wording we have never seen\n' >"$PANES/gk-park"

    run_check
    [[ "$(verdict_for gk-park)" == "clear" ]] ||
        fail "unknown wording should not match the built-in patterns"

    CHECK_ENV=('GASTOWN_PARKED_PATTERNS=brand new limit wording')
    run_check
    [[ "$(verdict_for gk-park)" == "parked" ]] ||
        fail "an overridden pattern must take effect, got '$(verdict_for gk-park)'"
}

test_no_active_sessions_is_clean_exit() {
    reset_fixtures
    cat >"$SESSIONS" <<'JSON'
{"sessions":[{"id":"gk-slep","session_name":"s","alias":"a/b","rig":"tallyup","state":"asleep"}]}
JSON
    run_check
    [[ "$RC" -eq 0 ]] || fail "nothing to check is exit 0, got $RC"
    printf '%s' "$ERR" | grep -F 'no active session to check' >/dev/null ||
        fail "stderr should say there was nothing to check"
}

test_summary_line_reports_what_was_measured() {
    reset_fixtures
    pane_parked >"$PANES/gk-park"
    pane_working >"$PANES/gk-work"
    pane_idle_healthy >"$PANES/gk-idle"

    run_check
    printf '%s' "$ERR" | grep -E 'checked 3 active session\(s\), 1 parked' >/dev/null ||
        fail "the summary must state how many sessions were measured and how many parked; got: $ERR"
}

test_settle_gap_is_paid_once_for_the_fleet() {
    # Two candidates, one gap. A per-candidate sleep would turn a sub-minute
    # check into a quarter hour on a 20-session city and stall the patrol cycle.
    reset_fixtures
    pane_parked >"$PANES/gk-park"
    pane_parked >"$PANES/gk-work"
    pane_idle_healthy >"$PANES/gk-idle"

    SETTLE=45
    run_check
    [[ "$(verdict_for gk-park)" == "parked" ]] || fail "gk-park should be parked"
    [[ "$(verdict_for gk-work)" == "parked" ]] || fail "gk-work should be parked"

    local sleeps
    sleeps=$(grep -c . "$SLEEPLOG" 2>/dev/null || echo 0)
    [[ "$sleeps" -eq 1 ]] ||
        fail "the settle gap must be slept once for the whole fleet, not per candidate; sleep was called $sleeps time(s) for 2 candidates"
    grep -Fx '45' "$SLEEPLOG" >/dev/null ||
        fail "the configured settle gap must be the value actually slept; got: $(cat "$SLEEPLOG")"
}

test_multiple_parked_sessions_are_all_reported() {
    # Regression: candidates were accumulated with CANDIDATES=$(printf ...),
    # and command substitution strips trailing newlines — so the second
    # candidate was glued onto the first row and silently disappeared. Two
    # parked sessions must produce two rows.
    reset_fixtures
    pane_parked >"$PANES/gk-park"
    pane_parked >"$PANES/gk-work"
    pane_idle_healthy >"$PANES/gk-idle"

    run_check
    local parked_rows
    parked_rows=$(printf '%s\n' "$OUT" | awk -F'\t' '$1 == "parked" { n++ } END { print n + 0 }')
    [[ "$parked_rows" -eq 2 ]] ||
        fail "two parked sessions must yield two parked rows, got $parked_rows"
    printf '%s' "$ERR" | grep -F '2 parked' >/dev/null ||
        fail "the summary must count both parked sessions; got: $ERR"
}

# code_only — the script with whole-line comments stripped. The header
# deliberately NAMES the mutating commands it must not run (`gc session reset` is
# the documented remedy, and the drain caveat has to be written down somewhere),
# so a grep over the raw file would match its own documentation.
code_only() {
    grep -vE '^[[:space:]]*#' "$SCRIPT"
}

test_script_is_read_only() {
    # The pack convention: checks measure, formula steps decide. A script that
    # reset sessions on its own judgment would take the clean-worktree
    # precondition out of the loop.
    local offenders
    offenders=$(code_only | grep -nE 'gc[[:space:]]+session[[:space:]]+(reset|kill|nudge|suspend|close)' || true)
    [[ -z "$offenders" ]] ||
        fail "parked-session-check must not act on sessions; it measures and prints. Offending: $offenders"

    offenders=$(code_only | grep -nE 'gc[[:space:]]+(bd[[:space:]]+(update|close|create)|mail[[:space:]]+send|runtime[[:space:]]+drain)' || true)
    [[ -z "$offenders" ]] ||
        fail "parked-session-check must not mutate beads, send mail, or drain. Offending: $offenders"
}

test_last_active_is_not_used_as_a_freshness_signal() {
    # last_active tracks pane redraws, so a parked session reports ~now forever.
    # It is also a LOCAL time with an explicit offset. Reintroducing it as a
    # freshness input would rebuild the exact blind spot gp-px5 is about, so it
    # may appear only in the commentary that explains why it is unusable.
    local offenders
    offenders=$(code_only | grep -n 'last_active' || true)
    [[ -z "$offenders" ]] ||
        fail "last_active must not be read as a freshness signal. Offending: $offenders"
}

run_case() {
    printf '  %s ... ' "$1"
    "$1"
    printf 'ok\n'
}

echo "test_parked_session_check:"
run_case test_parked_session_is_detected
run_case test_working_session_is_never_parked
run_case test_idle_healthy_session_is_clear_not_parked
run_case test_truncated_interrupt_marker_still_vetoes
run_case test_banner_in_scrollback_above_tail_is_not_parked
run_case test_banner_inside_widened_tail_is_detected
run_case test_advancing_pane_is_settling_not_parked
run_case test_session_that_wakes_during_settle_gap_is_busy
run_case test_failed_peek_reads_as_unmeasured_not_healthy
run_case test_rig_filter_scopes_the_scan
run_case test_explicit_ids_bypass_the_rig_filter
run_case test_non_active_sessions_are_skipped
run_case test_explicit_ids_narrow_the_scan
run_case test_explicit_alias_is_accepted
run_case test_bare_array_schema_is_tolerated
run_case test_tab_in_banner_cannot_forge_columns
run_case test_session_list_failure_is_exit_2
run_case test_bad_config_is_exit_2
run_case test_custom_patterns_are_honored
run_case test_no_active_sessions_is_clean_exit
run_case test_summary_line_reports_what_was_measured
run_case test_settle_gap_is_paid_once_for_the_fleet
run_case test_multiple_parked_sessions_are_all_reported
run_case test_script_is_read_only
run_case test_last_active_is_not_used_as_a_freshness_signal

echo "PASS: parked-session-check"
