#!/usr/bin/env bash
# Tests for the interactive-prompt block detector (gp-ha5).
#
# The bead's shape dictates this file's shape. On 2026-08-03 a witness sat ~103
# minutes on a live selection menu; detection worked (witness-heartbeat-check
# said `stalled`) and both prescribed remedies were wrong. A screen that decides
# whether the ladder applies has to be shown to produce BOTH answers correctly,
# because either mistake is a real incident:
#
#   a false `clear`          nudges a live menu. `gc session nudge` types into
#                            the pane; the text lands on whichever option the
#                            cursor is on and can submit it. The observed menu's
#                            option 1 ran `gc bd close ta-2e1p --force`.
#   a false `prompt-blocked` withdraws a rung the ladder needs. A genuinely hung
#                            witness stops getting its free nudge. Over-firing
#                            does not fail safe, it disables the ladder politely.
#
# So the positives and the negatives are both acceptance clauses here, and the
# negatives get as much weight as the positives — including the one pattern that
# was deliberately CUT during development (`Do you want to `), pinned by
# test_prose_question_is_clear so it cannot be reintroduced. It is prose-shaped,
# so an agent that merely ends its turn with that question matches it and then
# goes heartbeat-stale, because a finished turn is a still pane: its false
# positives correlate with the condition being screened.
#
# Every fixture here is synthetic. Nothing in this suite touches a real session.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT/gastown/assets/scripts/prompt-block-check.sh"
WRAPPER="$ROOT/gastown/commands/prompt-block-check/run.sh"
FORMULA="$ROOT/gastown/formulas/mol-deacon-patrol.toml"
FRAGMENT="$ROOT/gastown/template-fragments/operational-awareness.template.md"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# The `gc` the check talks to. Each session's pane comes from a file named after
# it in $GC_PANE_DIR, so one stub serves a multi-session run with a different
# pane per session. Every invocation is appended to $GC_CALL_LOG so a test can
# assert on what was CALLED — "it never sweeps the roster" and "it never nudges"
# are both claims about calls, not about output.
#
# GC_FAIL_MODE injects the shapes that must not read as a clearance:
#   peek-exit      the peek failing outright
#   peek-envelope  {"ok":false} on STDOUT with exit 0 — the gp-b3x shape
#   peek-empty     a well-formed peek carrying an all-whitespace pane
#   peek-garbage   a payload that is not JSON at all
write_gc_stub() {
    local bin="$1"
    mkdir -p "$bin"
    cat >"$bin/gc" <<'SH'
#!/usr/bin/env sh
printf 'gc %s\n' "$*" >>"$GC_CALL_LOG"
case "$*" in
    *"session"*"peek"*)
        case "${GC_FAIL_MODE:-}" in
            peek-exit) exit 1 ;;
            peek-envelope)
                printf '{"schema_version":"1","ok":false,"error":{"message":"session not found"}}'
                exit 0
                ;;
            peek-garbage) printf 'not json at all' ;;
            peek-empty) jq -n '{schema_version:"1",ok:true,output:"   \n\n  \n"}' ;;
            *)
                # Last argument that is not a flag or a flag value is the session.
                sess=""
                for a in "$@"; do
                    case "$a" in
                        session|peek|--json|--lines|[0-9]*) ;;
                        *) sess="$a" ;;
                    esac
                done
                pane="$GC_PANE_DIR/$(printf '%s' "$sess" | tr '/' '_')"
                [ -f "$pane" ] || pane="$GC_PANE_DIR/default"
                jq -n --arg o "$(cat "$pane")" '{schema_version:"1",ok:true,output:$o}'
                ;;
        esac
        ;;
    *) printf '{}' ;;
esac
SH
    chmod +x "$bin/gc"
}

# run_check <pane-text> [session...] — one pane for every session.
#
# GC_BIN is explicitly unset. Gas Town sessions export it as an absolute path,
# and anything reaching for ${GC_BIN:-gc} would escape the PATH stub onto LIVE
# sessions — a test that peeks the developer's real city instead of its fixture.
# The check spells `gc` literally so PATH is authoritative, and this keeps it so.
run_check() {
    local pane="$1"
    shift
    printf '%s\n' "$pane" >"$PANEDIR/default"
    : >"$CALLS"
    set +e
    OUT=$(env -u GC_BIN GC_PANE_DIR="$PANEDIR" GC_CALL_LOG="$CALLS" \
        PATH="$BIN:$PATH" ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} \
        bash "$SCRIPT" ${1+"$@"} 2>"$ERRFILE")
    RC=$?
    set -e
    ERR=$(cat "$ERRFILE")
}

# run_wrapper — invoke the command wrapper the way `gc` does.
#
# GC_CITY is explicitly UNSET, because that is the state `gc` hands a pack
# command: it exports GC_CITY_PATH, not GC_CITY.
run_wrapper() {
    local pane="$1"
    shift
    printf '%s\n' "$pane" >"$PANEDIR/default"
    : >"$CALLS"
    set +e
    OUT=$(cd "$NOCITY" && env -u GC_CITY -u GC_BIN \
        GC_CITY_PATH="${WRAP_CITY-$CITY}" GC_PACK_DIR="${WRAP_PACK-$ROOT/gastown}" \
        GC_PANE_DIR="$PANEDIR" GC_CALL_LOG="$CALLS" \
        PATH="$BIN:$PATH" sh "$WRAPPER" ${1+"$@"} 2>"$ERRFILE")
    RC=$?
    set -e
    ERR=$(cat "$ERRFILE")
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
CITY="$tmp/city"
BIN="$tmp/bin"
PANEDIR="$tmp/panes"
CALLS="$tmp/calls.log"
ERRFILE="$tmp/stderr.txt"
NOCITY="$tmp/nocity"
mkdir -p "$CITY" "$NOCITY" "$PANEDIR"
: >"$CITY/city.toml"
write_gc_stub "$BIN"
EXTRA_ENV=()

# --- fixtures: the panes ------------------------------------------------------

# The incident shape: a live AskUserQuestion selection menu.
MENU_PANE='⏺ ta-2e1p is blocked with gc.routed_to: human. Deciding whether to close it.
╭──────────────────────────────────────────────╮
│ Close ta-2e1p?                               │
│ ❯ 1. Yes — close it with --force             │
│   2. No — leave it parked                    │
│ ↑/↓ to navigate · Enter to select            │
╰──────────────────────────────────────────────╯'

# A permission prompt. Carries NO footer hint — only the cursor-on-option chrome,
# which is what makes the structural signal load-bearing rather than decorative.
PERMISSION_PANE='⏺ Running: rm -rf build/
  ❯ 1. Yes
    2. No, and tell Claude what to do differently (esc)'

# A healthy pane. The agent asked a question in PROSE and the ordinary input box
# is on screen. Nudging this is harmless and often correct.
PROSE_PANE='⏺ I finished the analysis of the deploy script.
  Do you want to proceed with the rollout?

──────────────────────────────────────────────
❯
──────────────────────────────────────────────
  ⏵⏵ bypass permissions on (shift+tab to cycle) · esc to interrupt'

# A busy pane, mid-turn.
BUSY_PANE='⏺ Reading gastown/formulas/mol-deacon-patrol.toml
✽ Elucidating… (2m 14s · ↓ 3.1k tokens)
──────────────────────────────────────────────
❯
──────────────────────────────────────────────
  ⏵⏵ bypass permissions on (shift+tab to cycle) · esc to interrupt'

# --- acceptance: it must produce a positive ----------------------------------

test_live_menu_fires() {
    # THE test. Everything else is a refinement of this one.
    run_check "$MENU_PANE" rig/gastown.witness

    [ "$RC" -eq 1 ] ||
        fail "a live selection menu MUST exit 1 — this is the acceptance clause, got $RC ($OUT / $ERR)"
    printf '%s' "$OUT" | grep -q '^prompt-blocked	rig/gastown.witness	' ||
        fail "expected a prompt-blocked row, got: $OUT"
    printf '%s' "$ERR" | grep -q '1 prompt-blocked' ||
        fail "stderr summary must count the finding, got: $ERR"
}

test_permission_prompt_fires_on_structure_alone() {
    # No "Enter to select", no arrows — only `❯ 1.`. If the structural signal is
    # ever dropped as redundant, permission prompts stop being detected and the
    # most common blocking shape in the fleet goes back to being nudged.
    run_check "$PERMISSION_PANE" rig/gastown.polecat

    [ "$RC" -eq 1 ] ||
        fail "a permission prompt must be detected by cursor-on-option chrome alone, got $RC ($OUT)"
    printf '%s' "$OUT" | grep -q '^prompt-blocked	' ||
        fail "expected prompt-blocked from the structural signal, got: $OUT"
}

test_arrow_navigation_hint_fires() {
    run_check '⏺ thinking
  ↑/↓ to navigate' rig/gastown.refinery

    [ "$RC" -eq 1 ] || fail "the arrow-navigation hint must fire, got $RC ($OUT)"
}

test_enter_to_select_hint_fires() {
    run_check '⏺ thinking
  Enter to select' rig/gastown.refinery

    [ "$RC" -eq 1 ] || fail "the Enter-to-select hint must fire, got $RC ($OUT)"
}

test_evidence_column_carries_the_matched_line() {
    # The deacon must be able to judge the finding without a second 8s peek.
    run_check "$MENU_PANE" rig/gastown.witness

    printf '%s' "$OUT" | cut -f4 | grep -q '❯ 1. Yes' ||
        fail "the evidence column must carry the matched pane line, got: $OUT"
    printf '%s' "$OUT" | cut -f3 | grep -q 'from-bottom' ||
        fail "the signal column must locate the hit relative to the pane bottom, got: $OUT"
}

# --- acceptance: it must also produce a negative ------------------------------

test_prose_question_is_clear() {
    # Pins the pattern that was deliberately CUT. An agent ending its turn with
    # "Do you want to proceed?" has no menu to inject into; nudging it is
    # harmless and frequently right. Matching prose here would make the check
    # fire on the shape it is least able to distinguish from its own trigger.
    run_check "$PROSE_PANE" rig/gastown.witness

    [ "$RC" -eq 0 ] ||
        fail "a prose question with the ordinary input box must be clear, got $RC ($OUT)"
    printf '%s' "$OUT" | grep -q '^clear	' ||
        fail "expected a clear row, got: $OUT"
}

test_busy_pane_is_clear() {
    run_check "$BUSY_PANE" rig/gastown.deacon
    [ "$RC" -eq 0 ] || fail "a busy mid-turn pane must be clear, got $RC ($OUT)"
}

test_chrome_above_the_tail_window_is_clear() {
    # Tail-only scanning is load-bearing, not a performance tweak: scrollback
    # holds arbitrary agent output, and any agent that ever discusses this defect
    # has "Enter to select" in its transcript. Chrome pushed out of the window by
    # later output is history, not a live menu.
    local pane="$MENU_PANE"
    local i
    for i in $(seq 1 14); do
        pane="$pane
⏺ step $i completed"
    done
    run_check "$pane" rig/gastown.witness

    [ "$RC" -eq 0 ] ||
        fail "menu chrome scrolled out of the tail window must NOT fire — tail-only is the false-positive guard, got $RC ($OUT)"
}

test_tail_window_is_configurable() {
    local pane="$MENU_PANE"
    local i
    for i in $(seq 1 14); do
        pane="$pane
⏺ step $i completed"
    done
    EXTRA_ENV=(GASTOWN_PROMPT_BLOCK_TAIL=40)
    run_check "$pane" rig/gastown.witness
    EXTRA_ENV=()

    [ "$RC" -eq 1 ] ||
        fail "a widened tail window must reach the same chrome, got $RC ($OUT)"
}

test_trailing_blank_lines_do_not_push_chrome_out_of_view() {
    # tmux pads a capture to the pane height. Counting that padding as part of
    # the window would push the footer — where the bottom-anchored signals live —
    # out of view, and the check would clear every real menu on a tall pane.
    local pane="$MENU_PANE




"
    run_check "$pane" rig/gastown.witness

    [ "$RC" -eq 1 ] ||
        fail "trailing blank padding must be trimmed before the tail is taken, got $RC ($OUT)"
}

# --- fail-safe: uncertainty must never read as a clearance --------------------

test_peek_failure_is_unreadable_not_clear() {
    EXTRA_ENV=(GC_FAIL_MODE=peek-exit)
    run_check "$MENU_PANE" rig/gastown.witness
    EXTRA_ENV=()

    [ "$RC" -eq 1 ] ||
        fail "a failed peek must be a finding, not a clearance — got $RC ($OUT / $ERR)"
    printf '%s' "$OUT" | grep -q '^unreadable	' ||
        fail "expected an unreadable row, got: $OUT"
}

test_ok_false_envelope_is_caught_even_with_a_zero_exit() {
    # gp-b3x: `gc` reports a rejected flag by printing {"ok":false} to STDOUT and
    # exiting 0. A status-only guard reads that as a successful peek of an empty
    # pane and clears the session.
    EXTRA_ENV=(GC_FAIL_MODE=peek-envelope)
    run_check "$MENU_PANE" rig/gastown.witness
    EXTRA_ENV=()

    [ "$RC" -eq 1 ] ||
        fail "an {ok:false} envelope with exit 0 must not read as clear, got $RC ($OUT)"
    printf '%s' "$OUT" | grep -q '^unreadable	rig/gastown.witness	peek-rejected	' ||
        fail "expected a peek-rejected row, got: $OUT"
}

test_garbage_payload_is_unreadable() {
    EXTRA_ENV=(GC_FAIL_MODE=peek-garbage)
    run_check "$MENU_PANE" rig/gastown.witness
    EXTRA_ENV=()

    [ "$RC" -eq 1 ] || fail "an unparseable payload must not read as clear, got $RC ($OUT)"
    printf '%s' "$OUT" | grep -q '^unreadable	' || fail "expected unreadable, got: $OUT"
}

test_empty_pane_is_unreadable_not_clear() {
    # An empty capture is not a quiet pane, it is an unmeasured one.
    EXTRA_ENV=(GC_FAIL_MODE=peek-empty)
    run_check "$MENU_PANE" rig/gastown.witness
    EXTRA_ENV=()

    [ "$RC" -eq 1 ] || fail "an all-whitespace pane must not read as clear, got $RC ($OUT)"
    printf '%s' "$OUT" | grep -q '^unreadable	rig/gastown.witness	empty-pane	' ||
        fail "expected an empty-pane row, got: $OUT"
}

test_no_sessions_named_is_exit_2() {
    # Targeted, never a sweep: peeking costs ~8s per session, so a no-arg roster
    # scan would spend minutes inside a patrol step and make the deacon's own
    # heartbeat look stale.
    run_check "$MENU_PANE"

    [ "$RC" -eq 2 ] ||
        fail "naming no sessions must exit 2, not scan the roster, got $RC ($OUT / $ERR)"
    printf '%s' "$ERR" | grep -q 'targeted, not a sweep' ||
        fail "stderr must explain the targeted contract, got: $ERR"
}

test_never_enumerates_the_roster() {
    run_check "$MENU_PANE" rig/gastown.witness

    ! grep -q 'gc session list' "$CALLS" ||
        fail "the check must never enumerate sessions — that is the sweep it refuses to be: $(cat "$CALLS")"
}

test_bad_window_config_fails_loud() {
    local bad
    for bad in 0 abc '-3'; do
        EXTRA_ENV=(GASTOWN_PROMPT_BLOCK_TAIL="$bad")
        run_check "$MENU_PANE" rig/gastown.witness
        EXTRA_ENV=()
        [ "$RC" -eq 2 ] ||
            fail "GASTOWN_PROMPT_BLOCK_TAIL=$bad must exit 2, got $RC"
    done
}

test_window_config_with_a_space_fails_loud() {
    # A packed NAME:value validation loop word-splits this into fragments that
    # each validate clean, and the failure then surfaces inside `tail` as a
    # broken pane rather than a broken config.
    EXTRA_ENV=(GASTOWN_PROMPT_BLOCK_TAIL='1 2')
    run_check "$MENU_PANE" rig/gastown.witness
    EXTRA_ENV=()

    [ "$RC" -eq 2 ] ||
        fail "a window value containing a space must be rejected as config, got $RC ($OUT / $ERR)"
}

test_blank_override_cannot_disable_the_screen() {
    # A check that cannot fire reports clean forever, which is indistinguishable
    # from a healthy fleet right up until a nudge lands on a live menu. Blanking
    # the pattern variable therefore falls back to the defaults rather than
    # matching nothing — there is no accidental off switch.
    EXTRA_ENV=(GASTOWN_PROMPT_BLOCK_PATTERNS=)
    run_check "$MENU_PANE" rig/gastown.witness
    EXTRA_ENV=()

    [ "$RC" -eq 1 ] ||
        fail "a blank pattern override must fall back to the defaults and still fire, got $RC ($OUT)"
    printf '%s' "$OUT" | grep -q '^prompt-blocked	' ||
        fail "expected the default patterns to still apply, got: $OUT"
}

test_unusable_pattern_is_unreadable_not_clear() {
    # grep answers 0 = matched, 1 = no match, 2 = error, and `if grep ...`
    # collapses the error onto "no match". Here that collapse would report
    # `clear` for a pane nobody evaluated — and `clear` is what authorises a
    # nudge into a live menu. An unparseable ERE is the cheapest way to reach
    # grep's error exit on every platform.
    EXTRA_ENV=(GASTOWN_PROMPT_BLOCK_PATTERNS='[')
    run_check "$MENU_PANE" rig/gastown.witness
    EXTRA_ENV=()

    [ "$RC" -eq 1 ] ||
        fail "an unusable pattern must be a finding, not a clearance — got $RC ($OUT / $ERR)"
    printf '%s' "$OUT" | grep -q '^unreadable	rig/gastown.witness	match-failed	' ||
        fail "expected a match-failed row, got: $OUT"
}

test_patterns_are_configurable() {
    EXTRA_ENV=(GASTOWN_PROMPT_BLOCK_PATTERNS='WAITING ON A HUMAN')
    run_check '⏺ idle
  WAITING ON A HUMAN' rig/gastown.witness
    EXTRA_ENV=()

    [ "$RC" -eq 1 ] || fail "a configured pattern must fire, got $RC ($OUT)"
}

# --- behaviour ----------------------------------------------------------------

test_every_named_session_gets_a_row() {
    printf '%s\n' "$MENU_PANE" >"$PANEDIR/rig_gastown.witness"
    printf '%s\n' "$BUSY_PANE" >"$PANEDIR/rig_gastown.refinery"
    : >"$CALLS"
    set +e
    OUT=$(env -u GC_BIN GC_PANE_DIR="$PANEDIR" GC_CALL_LOG="$CALLS" PATH="$BIN:$PATH" \
        bash "$SCRIPT" rig/gastown.witness rig/gastown.refinery 2>"$ERRFILE")
    RC=$?
    set -e
    rm -f "$PANEDIR/rig_gastown.witness" "$PANEDIR/rig_gastown.refinery"

    # printf '%s\n', not '%s': command substitution strips the trailing newline,
    # so counting with '%s' reports one row fewer than there are.
    [ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" -eq 2 ] ||
        fail "expected one row per named session, got: $OUT"
    printf '%s' "$OUT" | grep -q '^prompt-blocked	rig/gastown.witness	' ||
        fail "the blocked session must be reported, got: $OUT"
    printf '%s' "$OUT" | grep -q '^clear	rig/gastown.refinery	' ||
        fail "the healthy session must be reported clear, got: $OUT"
    [ "$RC" -eq 1 ] || fail "a mixed run with a finding must exit 1, got $RC"
}

test_all_clear_exits_zero() {
    run_check "$BUSY_PANE" rig/gastown.witness
    [ "$RC" -eq 0 ] || fail "an all-clear run must exit 0, got $RC ($OUT)"
    printf '%s' "$ERR" | grep -q '0 prompt-blocked, 0 unreadable' ||
        fail "stderr summary must report the clean counts, got: $ERR"
}

test_tabs_in_the_pane_do_not_shift_columns() {
    # The evidence column is last and tab-scrubbed, so a tab on the matched line
    # cannot invent a sixth field or shift the verdict.
    run_check "$(printf '⏺ x\n\t❯ 1.\tYes\there')" rig/gastown.witness

    [ "$(printf '%s' "$OUT" | head -1 | awk -F'\t' '{print NF}')" -eq 4 ] ||
        fail "a tab in the pane must not add columns, got: $(printf '%s' "$OUT" | head -1)"
}

test_check_is_read_only() {
    # Asserted twice, statically and at runtime, and the two catch different
    # things. The source scan is the stronger claim — the check cannot mutate
    # anything because it contains no mutating call. The call-log scan catches an
    # indirect one the source scan would miss.
    #
    # Every pattern is written `gc <verb>` rather than bare `bd <verb>`. That is
    # not cosmetic: a bare `bd` in a shipped asset trips the store-aware routing
    # gate, and the obvious repair — spelling it `gc bd create` in the assertion
    # while the stub logs only "$*" — makes the runtime assertion VACUOUS, since
    # the log would never contain the program name to match against. The stub
    # logs the `gc ` prefix for exactly this reason; keep the two in step.
    ! grep -nE '^[^#]*gc (mail|session (nudge|wake|send-keys)|bd (create|update|close))' "$SCRIPT" >/dev/null ||
        fail "the check must not mail, nudge, or mutate beads — it measures and the step decides"

    run_check "$MENU_PANE" rig/gastown.witness

    ! grep -qE 'gc (mail|session (nudge|wake|send-keys)|bd (create|update|close))' "$CALLS" ||
        fail "the check invoked a mutating command at runtime: $(cat "$CALLS")"

    # Proof the runtime half is not vacuous: the log really does carry the prefix
    # the assertion above searches for, so a mutating call would be seen.
    grep -q '^gc session peek' "$CALLS" ||
        fail "the call log must record invocations as 'gc ...', or the assertion above matches nothing: $(cat "$CALLS")"
}

test_uses_no_bash4_only_constructs() {
    # macOS ships bash 3.2 and the fleet includes macOS.
    ! grep -nE 'declare -A|mapfile|readarray|\$\{[A-Za-z_]+,,\}|\$\{[A-Za-z_]+\^\^\}' "$SCRIPT" ||
        fail "the check must not use bash 4-only constructs"
}

# --- the wrapper --------------------------------------------------------------

test_wrapper_is_executable() {
    [ -x "$WRAPPER" ] ||
        fail "commands/prompt-block-check/run.sh must be executable — a lost exec bit halts the caller"
    [ -f "$ROOT/gastown/commands/prompt-block-check/help.md" ] ||
        fail "missing commands/prompt-block-check/help.md"
}

test_wrapper_resolves_the_check_through_pack_dir() {
    grep -q 'GC_PACK_DIR' "$WRAPPER" ||
        fail "the wrapper must resolve the check through GC_PACK_DIR — that is its only reason to exist"
}

test_wrapper_rejects_missing_pack_context() {
    WRAP_PACK=""
    run_wrapper "$MENU_PANE" rig/gastown.witness
    unset WRAP_PACK

    [ "$RC" -eq 2 ] || fail "a wrapper run without GC_PACK_DIR must exit 2, got $RC"
}

test_wrapper_reports_a_pack_without_the_check() {
    WRAP_PACK="$tmp/emptypack"
    mkdir -p "$WRAP_PACK"
    run_wrapper "$MENU_PANE" rig/gastown.witness
    unset WRAP_PACK

    [ "$RC" -eq 2 ] || fail "a pack lacking the check must exit 2, not silently no-op, got $RC"
    printf '%s' "$ERR" | grep -q 'not found in this pack version' ||
        fail "expected an explicit not-found message, got: $ERR"
}

test_wrapper_passes_sessions_and_findings_through() {
    run_wrapper "$MENU_PANE" rig/gastown.witness

    [ "$RC" -eq 1 ] || fail "the wrapper must pass the findings exit through, got $RC ($OUT / $ERR)"
    printf '%s' "$OUT" | grep -q '^prompt-blocked	rig/gastown.witness	' ||
        fail "the wrapper must pass session arguments through, got: $OUT"
}

# --- the formula wiring -------------------------------------------------------

# step_text <step-id> — isolate one step's description from the formula.
step_text() {
    awk -v want="$1" '
        $0 == "id = \"" want "\"" { f = 1 }
        f && /^\[\[steps\]\]$/ && seen { exit }
        /^\[\[steps\]\]$/ { seen = f }
        f { print }
    ' "$FORMULA"
}

test_formula_invokes_the_command_not_the_path() {
    # GC_PACK_DIR is unset in an agent shell, so a path invocation expands to
    # /assets/scripts/... and turns the gate into a permanent no-op that reads
    # like a considered fallback (gp-3qb, gp-fid). For THIS check that is not a
    # lost signal — it restores the exact behaviour gp-ha5 exists to stop.
    grep -q 'gc gastown prompt-block-check' "$FORMULA" ||
        fail "the formula must invoke the check through 'gc gastown prompt-block-check'"
    ! grep -q 'GC_PACK_DIR.*prompt-block-check' "$FORMULA" ||
        fail "the formula must not reach for \$GC_PACK_DIR; it is unset in an agent shell"
}

test_gate_precedes_both_rungs_in_health_scan() {
    # Ordering IS the fix. A gate that runs after the nudge has already typed
    # into the menu is decoration.
    local step gate nudge warrant
    step=$(step_text health-scan)
    gate=$(printf '%s' "$step" | grep -n 'gc gastown prompt-block-check' | head -1 | cut -d: -f1)
    nudge=$(printf '%s' "$step" | grep -n 'gc session nudge' | head -1 | cut -d: -f1)
    warrant=$(printf '%s' "$step" | grep -n 'label=warrant' | head -1 | cut -d: -f1)

    [ -n "$gate" ] || fail "health-scan does not run the prompt-block gate at all"
    [ -n "$nudge" ] || fail "could not locate the nudge in health-scan"
    [ -n "$warrant" ] || fail "could not locate the warrant in health-scan"
    [ "$gate" -lt "$nudge" ] ||
        fail "the prompt-block gate must precede the nudge in health-scan (gate@$gate nudge@$nudge)"
    [ "$gate" -lt "$warrant" ] ||
        fail "the prompt-block gate must precede the warrant in health-scan (gate@$gate warrant@$warrant)"
}

test_gate_precedes_the_nudge_in_the_starvation_step() {
    # The second nudge site. A menu-blocked session starves its queue for the
    # same reason it goes heartbeat-stale, so it reaches this step too.
    local step gate nudge
    step=$(step_text queue-starvation-check)
    gate=$(printf '%s' "$step" | grep -n 'gc gastown prompt-block-check' | head -1 | cut -d: -f1)
    nudge=$(printf '%s' "$step" | grep -n 'gc session nudge' | head -1 | cut -d: -f1)

    [ -n "$gate" ] ||
        fail "queue-starvation-check nudges without the prompt-block gate — the same injection hazard"
    [ "$gate" -lt "$nudge" ] ||
        fail "the gate must precede the nudge in queue-starvation-check (gate@$gate nudge@$nudge)"
}

test_formula_names_the_injection_risk() {
    # The bead asks specifically for an explicit do-not-nudge warning naming the
    # injection risk. A gate whose rationale is unstated gets optimised away by
    # the next editor who finds it verbose.
    local step
    step=$(step_text health-scan)
    printf '%s' "$step" | grep -q 'Do NOT nudge' ||
        fail "health-scan must carry an explicit do-not-nudge instruction"
    printf '%s' "$step" | grep -qi 'types into' ||
        fail "health-scan must explain that a nudge types into the live menu"
    printf '%s' "$step" | grep -q 'close ta-2e1p --force' ||
        fail "health-scan must name the observed destructive option — the concrete case is the argument"
}

test_formula_treats_unreadable_and_exit_2_as_do_not_nudge() {
    local step
    step=$(step_text health-scan)
    printf '%s' "$step" | grep -q 'unreadable' ||
        fail "health-scan must tell the deacon what to do with an unreadable verdict"
    printf '%s' "$step" | grep -qE 'Exit 2 means the check itself could not run' ||
        fail "health-scan must classify exit 2 as not-measured rather than clear"
}

test_formula_routes_the_decision_to_a_human() {
    # The third rung. Without it the gate only says "do not act", and the
    # decision stays as invisible as it was in the pane.
    local step
    step=$(step_text health-scan)
    printf '%s' "$step" | grep -q '"gc.routed_to":"human"' ||
        fail "health-scan must route the pending decision to a human"
    printf '%s' "$step" | grep -q 'label=human-gate' ||
        fail "the human-gate bead needs a stable label so the dedup query can find it"
    printf '%s' "$step" | grep -q 'EXISTING_GATE' ||
        fail "the human-gate bead must be deduped — this step runs every patrol cycle"
}

test_formula_does_not_warrant_a_prompt_blocked_session() {
    # A warrant discards the pending question and the reasoning behind it.
    local step
    step=$(step_text health-scan)
    printf '%s' "$step" | grep -q 'Do NOT warrant' ||
        fail "health-scan must forbid warranting a prompt-blocked session"
}

# --- the policy ---------------------------------------------------------------

test_global_fragment_forbids_interactive_prompts() {
    # gp-ha5 ask 3, decided: an unattended agent must express the decision as a
    # human-routed bead. operational-awareness is a city.toml global fragment, so
    # this reaches every agent in every rig — including the ones that would
    # otherwise create the hazard the deacon has to screen for.
    grep -q 'Never block on an interactive prompt' "$FRAGMENT" ||
        fail "the global fragment must carry the no-interactive-prompt rule"
    grep -q 'gc.routed_to=human' "$FRAGMENT" ||
        fail "the rule must name the human-routed bead as the required alternative"
    grep -qi 'types into your terminal' "$FRAGMENT" ||
        fail "the rule must explain why a live prompt is injection-reachable"
}

test_live_menu_fires
test_permission_prompt_fires_on_structure_alone
test_arrow_navigation_hint_fires
test_enter_to_select_hint_fires
test_evidence_column_carries_the_matched_line
test_prose_question_is_clear
test_busy_pane_is_clear
test_chrome_above_the_tail_window_is_clear
test_tail_window_is_configurable
test_trailing_blank_lines_do_not_push_chrome_out_of_view
test_peek_failure_is_unreadable_not_clear
test_ok_false_envelope_is_caught_even_with_a_zero_exit
test_garbage_payload_is_unreadable
test_empty_pane_is_unreadable_not_clear
test_no_sessions_named_is_exit_2
test_never_enumerates_the_roster
test_bad_window_config_fails_loud
test_window_config_with_a_space_fails_loud
test_blank_override_cannot_disable_the_screen
test_unusable_pattern_is_unreadable_not_clear
test_patterns_are_configurable
test_every_named_session_gets_a_row
test_all_clear_exits_zero
test_tabs_in_the_pane_do_not_shift_columns
test_check_is_read_only
test_uses_no_bash4_only_constructs
test_wrapper_is_executable
test_wrapper_resolves_the_check_through_pack_dir
test_wrapper_rejects_missing_pack_context
test_wrapper_reports_a_pack_without_the_check
test_wrapper_passes_sessions_and_findings_through
test_formula_invokes_the_command_not_the_path
test_gate_precedes_both_rungs_in_health_scan
test_gate_precedes_the_nudge_in_the_starvation_step
test_formula_names_the_injection_risk
test_formula_treats_unreadable_and_exit_2_as_do_not_nudge
test_formula_routes_the_decision_to_a_human
test_formula_does_not_warrant_a_prompt_blocked_session
test_global_fragment_forbids_interactive_prompts

echo "prompt block check tests passed"
