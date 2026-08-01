#!/usr/bin/env bash
# Tests for the orphan liveness re-check (gp-8m6).
#
# The bead's acceptance clause is the reason this file is shaped the way it is:
#
#   "A bead whose assignee is a session absent from the cycle map but present on
#    a fresh lookup is NOT reset, and the re-check is exercised by a test."
#
# So the first test below is that true positive, expressed the way the witness
# actually consumes the check — through the `if` that gates salvage and reset —
# rather than as an exit-code assertion the recipe could disagree with.
#
# The defect: `recover-orphaned-beads` builds its assignee->state map ONCE per
# cycle, before the per-bead loop, then lists beads. A session created between
# those two reads is missing from the map, the classification table resolves an
# unknown assignee to `absent`, and `absent` is definitive — so step 3b resets a
# live agent's bead. The existing fail-safe fires only on an EMPTY map with live
# sessions; a map merely missing recently-spawned sessions passes it cleanly.
#
# The second thing under test is the exit POLARITY, which is inverted relative
# to `gc gastown delivery-check` and is easy to "fix" back the wrong way. There,
# a check that could not run means "build as normal", because the unsafe
# direction is halting on a guess. Here the unsafe direction is proceeding —
# salvage commits into a running agent's worktree and the reset takes its bead —
# so every unmeasurable path must exit non-zero. `test_no_failure_path_is_green`
# asserts that as a class rather than case by case.
#
# Every fixture here is synthetic. Nothing in this suite touches the real ledger
# or the real roster.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT/gastown/assets/scripts/orphan-liveness-recheck.sh"
WRAPPER="$ROOT/gastown/commands/liveness-recheck/run.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

BIN="$TMP/bin"
ROSTER="$TMP/roster.json"
BEADS="$TMP/session-beads.json"
CALLS="$TMP/calls.log"
ERRFILE="$TMP/stderr"

# The `gc` the check talks to. Both listings are served from fixture files, so a
# test declares a city as data rather than standing one up. Every invocation is
# appended to $GC_CALLS so a test can assert on WHICH listings ran and with what
# flags — `--state=all` is load-bearing, and the session-bead probe is supposed
# to be spent only on the path that would authorise a reset.
#
# GC_FAIL_MODE injects the failure shapes that matter:
#   roster-envelope   the gp-b3x shape — {"ok":false} on STDOUT, exit 1
#   roster-envelope-0 the same envelope but exit 0, so only a payload read sees it
#   roster-exit       a plain non-zero exit with no payload
#   roster-drift      a well-formed object carrying no `sessions` key
#   beads-exit        the session-bead listing failing
#   beads-envelope    the session-bead listing returning the error envelope
#   beads-drift       the session-bead listing returning a non-array object
write_gc_stub() {
    mkdir -p "$BIN"
    cat >"$BIN/gc" <<'SH'
#!/usr/bin/env sh
printf '%s\n' "$*" >>"$GC_CALLS"
case "$*" in
    *"session"*"list"*)
        case "${GC_FAIL_MODE:-}" in
            roster-envelope)
                printf '{"schema_version":"1","ok":false,"error":{"code":"json_command_not_found","message":"command \\"session list\\" was not found","exit_code":1}}'
                exit 1
                ;;
            roster-envelope-0)
                printf '{"schema_version":"1","ok":false,"error":{"code":"internal","message":"roster unavailable"}}'
                exit 0
                ;;
            roster-exit) exit 1 ;;
            roster-drift) printf '{"schema_version":"1","ok":true,"agents":[]}' ;;
            *) cat "$GC_ROSTER" ;;
        esac
        ;;
    *"bd"*"list"*)
        case "${GC_FAIL_MODE:-}" in
            beads-exit) exit 1 ;;
            beads-envelope)
                printf '{"schema_version":"1","ok":false,"error":{"code":"internal","message":"ledger unavailable"}}'
                exit 1
                ;;
            beads-drift) printf '{"schema_version":"1","ok":true,"rows":[]}' ;;
            *) cat "$GC_SESSION_BEADS" ;;
        esac
        ;;
    *) printf '{}' ;;
esac
SH
    chmod +x "$BIN/gc"
}

# run_check <roster-json> <session-beads-json> <assignee> [env assignments...]
run_check() {
    local roster="$1" beads="$2" assignee="$3"
    shift 3
    printf '%s' "$roster" >"$ROSTER"
    printf '%s' "$beads" >"$BEADS"
    : >"$CALLS"
    set +e
    # ${1+"$@"} rather than "$@": bash 3.2 under `set -u` treats an empty "$@"
    # as an unbound variable.
    OUT=$(env GC_ROSTER="$ROSTER" GC_SESSION_BEADS="$BEADS" GC_CALLS="$CALLS" \
        PATH="$BIN:$PATH" ${1+"$@"} bash "$SCRIPT" "$assignee" 2>"$ERRFILE")
    RC=$?
    set -e
    ERR=$(cat "$ERRFILE")
    VERDICT=$(printf '%s' "$OUT" | awk -F'\t' 'NF{print $1}' | tail -1)
    STATE=$(printf '%s' "$OUT" | awk -F'\t' 'NF{print $3}' | tail -1)
    SOURCE=$(printf '%s' "$OUT" | awk -F'\t' 'NF{print $4}' | tail -1)
}

# --- fixtures -----------------------------------------------------------------

# The roster as it looked on the meety-local patrol AFTER the polecat spawned —
# i.e. the fresh read. `gastown__polecat-gk-a9xk` is the session the cycle map,
# built seconds earlier, did not contain.
#
# Every identity field holds a DISTINCT value on purpose. Live rosters often
# repeat one string across `name` and `session_name`, and a fixture that copies
# that cannot tell "both keys are matched" from "one key is matched and the
# other happens to agree" — dropping the `session_name` arm passed against such
# a fixture while genuinely losing a spelling.
roster_with_live_polecat() {
    cat <<'JSON'
{"schema_version":"1","ok":true,"sessions":[
  {"id":"gk-0001","name":"witness-name","session_name":"gastown__witness","alias":"witness","agent_name":"meety-local/gastown.witness","state":"active","closed":false},
  {"id":"gk-a9xk","name":"polecat-name-a9xk","session_name":"gastown__polecat-gk-a9xk","alias":"capable","agent_name":"meety-local/gastown.capable","state":"active","closed":false}
]}
JSON
}

roster_without_polecat() {
    cat <<'JSON'
{"schema_version":"1","ok":true,"sessions":[
  {"id":"gk-0001","name":"gastown__witness","session_name":"gastown__witness","alias":"witness","agent_name":"meety-local/gastown.witness","state":"active","closed":false}
]}
JSON
}

roster_with_state() {
    cat <<JSON
{"schema_version":"1","ok":true,"sessions":[
  {"id":"gk-a9xk","name":"gastown__polecat-gk-a9xk","session_name":"gastown__polecat-gk-a9xk","alias":"capable","agent_name":"meety-local/gastown.capable","state":"$1","closed":${2:-false}}
]}
JSON
}

NO_BEADS='[]'

beads_with_named_identity() {
    cat <<JSON
[{"id":"ml-sess-1","status":"${2:-open}","metadata":{"configured_named_identity":"$1","state":"${3:-active}"}}]
JSON
}

# --- tests --------------------------------------------------------------------

test_the_stale_map_race_is_caught() {
    # THE acceptance case. The witness classified this bead orphaned because
    # `gastown__polecat-gk-a9xk` was absent from the cycle map. A fresh lookup
    # finds it active — the map was stale, not the session gone.
    run_check "$(roster_with_live_polecat)" "$NO_BEADS" gastown__polecat-gk-a9xk

    [[ "$VERDICT" == "present" ]] ||
        fail "a session absent from the cycle map but live on a fresh read must verdict 'present', got '$VERDICT'"
    [[ "$RC" -eq 1 ]] ||
        fail "the race must exit 1 so the witness's 'if' refuses the reset, got $RC"
    [[ "$SOURCE" == "session-list" ]] ||
        fail "the roster should have answered this without a second probe, got source '$SOURCE'"

    # And the same fact as the recipe actually consumes it. This is the part the
    # bead asks for — the bead is NOT reset — expressed as control flow rather
    # than as a number, so it fails if the polarity is ever flipped.
    local acted=no
    if env GC_ROSTER="$ROSTER" GC_SESSION_BEADS="$BEADS" GC_CALLS="$CALLS" \
        PATH="$BIN:$PATH" bash "$SCRIPT" gastown__polecat-gk-a9xk >/dev/null 2>&1; then
        acted=yes
    fi
    [[ "$acted" == "no" ]] ||
        fail "the witness's 'if gc gastown liveness-recheck ...' gate ran the recovery branch on a LIVE session"
}

test_a_genuine_orphan_is_still_recoverable() {
    # The check must not become a blanket refusal — that would disable orphan
    # recovery entirely, which is the witness's core job.
    run_check "$(roster_without_polecat)" "$NO_BEADS" gastown__polecat-gk-dead

    [[ "$VERDICT" == "absent" ]] ||
        fail "a session in neither fresh source must verdict 'absent', got '$VERDICT'"
    [[ "$RC" -eq 0 ]] ||
        fail "a re-confirmed orphan must exit 0 so recovery proceeds, got $RC"
}

test_every_not_orphaned_state_withholds_the_reset() {
    # The classification table in `recover-orphaned-beads` names these as NOT
    # orphaned — the controller or operator still owns the session. A re-check
    # that only understood `active` would let the recipe reset a session that is
    # merely asleep or draining.
    local state
    for state in active awake creating asleep drained suspended draining quarantined; do
        run_check "$(roster_with_state "$state")" "$NO_BEADS" gk-a9xk
        [[ "$VERDICT" == "present" ]] ||
            fail "state '$state' is not orphaned per the classification table; verdict was '$VERDICT'"
        [[ "$RC" -eq 1 ]] || fail "state '$state' must exit 1, got $RC"
    done
}

test_terminal_states_confirm_the_orphan() {
    # `archived`/`closed` are the only found-and-still-orphaned states. They exit
    # 0 like `absent`, but report distinctly, because "measured as closed" and
    # "never seen" are different evidence in a cycle log.
    local state
    for state in archived closed; do
        run_check "$(roster_with_state "$state")" "$NO_BEADS" gk-a9xk
        [[ "$VERDICT" == "terminal" ]] ||
            fail "state '$state' must verdict 'terminal', got '$VERDICT'"
        [[ "$RC" -eq 0 ]] || fail "state '$state' must exit 0, got $RC"
    done

    # `closed:true` is terminal whatever state it closed in — the cycle map folds
    # the flag in the same way, and the two must not disagree.
    run_check "$(roster_with_state active true)" "$NO_BEADS" gk-a9xk
    [[ "$VERDICT" == "terminal" ]] ||
        fail "closed:true must be terminal regardless of the state string, got '$VERDICT'"
    [[ "$RC" -eq 0 ]] || fail "closed:true must exit 0, got $RC"
}

test_an_unrecognised_state_is_treated_as_live() {
    # Drift in the state vocabulary must not read as "gone". A state nobody has
    # seen before is a session that EXISTS, and existing is the whole question.
    run_check "$(roster_with_state weird-new-state)" "$NO_BEADS" gk-a9xk
    [[ "$VERDICT" == "present" ]] ||
        fail "an unrecognised state must be treated as live, got '$VERDICT'"
    [[ "$RC" -eq 1 ]] || fail "an unrecognised state must exit 1, got $RC"

    run_check "$(roster_with_state '')" "$NO_BEADS" gk-a9xk
    [[ "$VERDICT" == "present" ]] ||
        fail "an empty state on a present session must be treated as live, got '$VERDICT'"
    [[ "$STATE" == "unknown" ]] ||
        fail "an empty state should report as 'unknown' rather than blank, got '$STATE'"
}

test_every_identity_spelling_resolves() {
    # `--assignee` is exact and Gas Town writes several spellings: session name
    # for a polecat self-claim, agent address for a handoff, plus id and alias.
    # Probing one form misses the rest, and a miss here authorises a reset.
    local key
    for key in gk-a9xk polecat-name-a9xk gastown__polecat-gk-a9xk capable meety-local/gastown.capable; do
        run_check "$(roster_with_live_polecat)" "$NO_BEADS" "$key"
        [[ "$RC" -eq 1 ]] ||
            fail "assignee spelling '$key' must resolve to the live session (exit 1), got $RC"
    done

    # Matching must stay EXACT. A prefix or substring match would resolve one
    # polecat's bead against a different session and silently vouch for it.
    run_check "$(roster_with_live_polecat)" "$NO_BEADS" gk-a9
    [[ "$RC" -eq 0 ]] ||
        fail "a partial identifier must NOT match a live session; lookup has to stay exact"
}

test_the_roster_read_includes_asleep_sessions() {
    # `--state=all` is not cosmetic. The default listing hides asleep sessions,
    # and `asleep` is explicitly NOT orphaned — reading the default listing would
    # report a sleeping agent as absent and authorise the reset this check exists
    # to withhold.
    run_check "$(roster_with_live_polecat)" "$NO_BEADS" gk-a9xk
    grep -Fq -- '--state=all' "$CALLS" ||
        fail "the fresh roster read must pass --state=all or asleep sessions read as absent"
}

test_no_failure_path_is_green() {
    # The polarity guard, asserted as a class. `delivery-check` maps "could not
    # run" onto "proceed"; here proceeding destroys a live agent's uncommitted
    # work, so nothing unmeasurable may exit 0.
    local mode
    for mode in roster-exit roster-envelope roster-envelope-0 roster-drift; do
        run_check "$(roster_with_live_polecat)" "$NO_BEADS" gk-a9xk GC_FAIL_MODE="$mode"
        [[ "$RC" -eq 2 ]] ||
            fail "failure mode '$mode' must exit 2 (nothing measured), got $RC"
        [[ "$VERDICT" == "unavailable" ]] ||
            fail "failure mode '$mode' must verdict 'unavailable', got '$VERDICT'"
        grep -Fq 'NOT measured' <<<"$ERR" ||
            fail "failure mode '$mode' must say on stderr that nothing was measured"
    done
}

test_an_error_envelope_on_exit_zero_is_still_a_failure() {
    # gp-b3x: `gc` reports a failed command by printing {"ok":false} to STDOUT.
    # The status guard catches today's exit-1 spelling, but the payload read is
    # what survives someone reintroducing a pipe, where the shell takes the
    # status from the tail. roster-envelope-0 is that shape with the status
    # already lost.
    run_check "$(roster_with_live_polecat)" "$NO_BEADS" gk-a9xk GC_FAIL_MODE=roster-envelope-0
    [[ "$RC" -eq 2 ]] ||
        fail "an {\"ok\":false} payload must be caught by the payload read even on exit 0, got $RC"

    # Assert on WHICH guard caught it. The schema check downstream also rejects
    # this object — it carries no `sessions` key — so an exit-code-only
    # assertion stays green with the payload read deleted, and this test would
    # be named for a guard it does not cover. The diagnostic is the difference:
    # a failed COMMAND is not schema drift, and an operator chasing the wrong
    # one of those loses the trail.
    grep -Fq 'the roster command failed' <<<"$ERR" ||
        fail "the {\"ok\":false} payload must be reported as a failed command, not as schema drift"
    grep -Fq 'roster unavailable' <<<"$ERR" ||
        fail "the envelope's own error message must reach stderr so the cause is visible"
}

test_a_bare_array_roster_is_tolerated() {
    # That shape shipped previously and the schema has drifted before (gc-3tn8g).
    run_check '[{"id":"gk-a9xk","state":"active","closed":false}]' "$NO_BEADS" gk-a9xk
    [[ "$RC" -eq 1 ]] ||
        fail "a bare top-level array roster must still resolve the session, got $RC"
}

test_session_beads_are_consulted_only_on_a_roster_miss() {
    # The cost argument for probing two sources: the second query is spent only
    # where its answer would authorise a destructive reset.
    run_check "$(roster_with_live_polecat)" "$NO_BEADS" gk-a9xk
    ! grep -Fq 'bd list' "$CALLS" ||
        fail "a roster HIT must answer without the session-bead probe"

    run_check "$(roster_without_polecat)" "$NO_BEADS" gk-nowhere
    grep -Fq 'bd list' "$CALLS" ||
        fail "a roster MISS must consult session beads before authorising a reset"
}

test_a_configured_named_identity_is_not_absent() {
    # The cycle map keys on session beads too. An assignee written in that
    # spelling is invisible to the roster lookup, and the miss is about to be
    # read as proof the session is gone.
    run_check "$(roster_without_polecat)" \
        "$(beads_with_named_identity meety-local/gastown.capable)" \
        meety-local/gastown.capable
    [[ "$VERDICT" == "present" ]] ||
        fail "a live configured_named_identity must verdict 'present', got '$VERDICT'"
    [[ "$RC" -eq 1 ]] || fail "a live configured_named_identity must exit 1, got $RC"
    [[ "$SOURCE" == "session-beads" ]] ||
        fail "the second source must be reported as the answer's origin, got '$SOURCE'"

    # A closed session bead is terminal, exactly as a closed roster entry is.
    run_check "$(roster_without_polecat)" \
        "$(beads_with_named_identity meety-local/gastown.capable closed)" \
        meety-local/gastown.capable
    [[ "$VERDICT" == "terminal" ]] ||
        fail "a closed session bead must verdict 'terminal', got '$VERDICT'"
    [[ "$RC" -eq 0 ]] || fail "a closed session bead must exit 0, got $RC"
}

test_a_failed_second_probe_is_not_an_absence() {
    # The subtlest way to reintroduce the bug: treat an unreadable session-bead
    # listing as "not found there either" and fall through to `absent`. That
    # turns a broken query into permission to reset a live agent's bead.
    local mode
    for mode in beads-exit beads-envelope beads-drift; do
        run_check "$(roster_without_polecat)" "$NO_BEADS" gk-nowhere GC_FAIL_MODE="$mode"
        [[ "$RC" -eq 2 ]] ||
            fail "session-bead failure '$mode' must exit 2, not fall through to absent (got $RC)"
        [[ "$VERDICT" == "unavailable" ]] ||
            fail "session-bead failure '$mode' must verdict 'unavailable', got '$VERDICT'"
    done
}

test_the_second_probe_can_be_skipped_but_never_unsafely() {
    # The opt-out narrows the check to the roster. Narrower is allowed; less safe
    # is not — it may only ever produce `absent` where the full check would also
    # have looked, never override a `present`.
    run_check "$(roster_without_polecat)" \
        "$(beads_with_named_identity meety-local/gastown.capable)" \
        meety-local/gastown.capable GASTOWN_RECHECK_SKIP_SESSION_BEADS=1
    [[ "$RC" -eq 0 ]] || fail "the opt-out must let a roster miss resolve absent, got $RC"
    ! grep -Fq 'bd list' "$CALLS" ||
        fail "the opt-out must actually skip the session-bead probe"

    run_check "$(roster_with_live_polecat)" "$NO_BEADS" gk-a9xk \
        GASTOWN_RECHECK_SKIP_SESSION_BEADS=1
    [[ "$RC" -eq 1 ]] ||
        fail "the opt-out must not weaken a roster HIT — a live session is still live"
}

test_bad_usage_exits_two_not_zero() {
    # A caller that forgets the argument must not be told "confirmed absent".
    set +e
    env PATH="$BIN:$PATH" GC_ROSTER="$ROSTER" GC_SESSION_BEADS="$BEADS" GC_CALLS="$CALLS" \
        bash "$SCRIPT" >/dev/null 2>&1
    local rc_none=$?
    env PATH="$BIN:$PATH" GC_ROSTER="$ROSTER" GC_SESSION_BEADS="$BEADS" GC_CALLS="$CALLS" \
        bash "$SCRIPT" a b >/dev/null 2>&1
    local rc_two=$?
    env PATH="$BIN:$PATH" GC_ROSTER="$ROSTER" GC_SESSION_BEADS="$BEADS" GC_CALLS="$CALLS" \
        bash "$SCRIPT" "" >/dev/null 2>&1
    local rc_empty=$?
    set -e
    [[ "$rc_none" -eq 2 ]] || fail "no argument must exit 2, got $rc_none"
    [[ "$rc_two" -eq 2 ]] || fail "two arguments must exit 2, got $rc_two"
    [[ "$rc_empty" -eq 2 ]] || fail "an empty assignee must exit 2, got $rc_empty"
}

test_the_check_calls_gc_literally() {
    # Shipped pack scripts call `gc` by name so a PATH stub can intercept them —
    # every test above depends on it. A `${GC_BIN:-gc}` indirection escapes PATH
    # onto the live roster, because agent sessions export GC_BIN as an absolute
    # path; this suite would then silently exercise the real city.
    ! grep -Fq 'GC_BIN' "$SCRIPT" ||
        fail "the check must call 'gc' literally, not through \$GC_BIN — that escapes PATH onto the live roster"
}

test_the_wrapper_refuses_without_pack_context() {
    # `gc` sets GC_PACK_DIR for pack COMMANDS only. Invoked directly it is unset,
    # and a wrapper that shrugged and continued would resolve the check to
    # /assets/scripts/... and report "could not run" forever.
    [[ -x "$WRAPPER" ]] || fail "missing or non-executable commands/liveness-recheck/run.sh"
    set +e
    local out rc
    out=$(env -u GC_PACK_DIR -u GC_CITY_PATH sh "$WRAPPER" gk-a9xk 2>&1)
    rc=$?
    set -e
    [[ "$rc" -eq 2 ]] || fail "the wrapper must exit 2 without pack context, got $rc"
    grep -Fq 'missing Gas City pack context' <<<"$out" ||
        fail "the wrapper must say why it refused"

    # And it must pass the real check's exit code through unchanged — a wrapper
    # that swallowed exit 1 into 0 would hand the witness a live session as a
    # confirmed orphan.
    printf '%s' "$(roster_with_live_polecat)" >"$ROSTER"
    printf '%s' "$NO_BEADS" >"$BEADS"
    set +e
    env GC_PACK_DIR="$ROOT/gastown" GC_CITY_PATH="$TMP" GC_ROSTER="$ROSTER" \
        GC_SESSION_BEADS="$BEADS" GC_CALLS="$CALLS" PATH="$BIN:$PATH" \
        sh "$WRAPPER" gk-a9xk >/dev/null 2>&1
    rc=$?
    set -e
    [[ "$rc" -eq 1 ]] ||
        fail "the wrapper must pass exit 1 (still live) through unchanged, got $rc"
}

write_gc_stub

test_the_stale_map_race_is_caught
test_a_genuine_orphan_is_still_recoverable
test_every_not_orphaned_state_withholds_the_reset
test_terminal_states_confirm_the_orphan
test_an_unrecognised_state_is_treated_as_live
test_every_identity_spelling_resolves
test_the_roster_read_includes_asleep_sessions
test_no_failure_path_is_green
test_an_error_envelope_on_exit_zero_is_still_a_failure
test_a_bare_array_roster_is_tolerated
test_session_beads_are_consulted_only_on_a_roster_miss
test_a_configured_named_identity_is_not_absent
test_a_failed_second_probe_is_not_an_absence
test_the_second_probe_can_be_skipped_but_never_unsafely
test_bad_usage_exits_two_not_zero
test_the_check_calls_gc_literally
test_the_wrapper_refuses_without_pack_context

echo "orphan liveness re-check tests passed"
