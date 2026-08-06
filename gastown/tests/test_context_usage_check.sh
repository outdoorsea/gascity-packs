#!/usr/bin/env bash
# Tests for `gc gastown context-usage` (gp-ay9).
#
# The bug under test is a guard that could not fire. Three patrol formulas ran
#
#     RSS=$(ps -o rss= -p $$ | tr -d ' ')
#
# against a 1500 MB threshold. `$$` is the per-tool-call harness shell (~2 MB),
# not the agent runtime (~520 MB), so the comparison was unreachable at every
# context depth and the step reported CLEAN forever.
#
# That shape is why this file leans on two assertions that look pedantic:
#   - the check must resolve the runtime through the tmux PANE pid, never the
#     caller's own shell (test_measures_runtime_not_caller_shell), and
#   - an unmeasurable state must exit 2, never a reassuring 0
#     (test_unmeasured_is_not_ok).
# A check that silently returns the comforting answer is the defect class, so
# the tests that matter most here are the ones that fail if it ever does again.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT/gastown/assets/scripts/context-usage-check.sh"
WRAPPER="$ROOT/gastown/commands/context-usage/run.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

BIN="$TMP/bin"
mkdir -p "$BIN"

# A ps(1) that prints a fixture process table. The script only ever calls
# `ps -eo pid=,ppid=,rss=`, so ignoring argv is faithful enough.
cat >"$BIN/ps" <<'SH'
#!/usr/bin/env sh
cat "$PS_TABLE"
SH
chmod +x "$BIN/ps"

# A tmux(1) serving one pane pid, and recording argv so the exact-match
# assertion below can inspect how the session was addressed.
cat >"$BIN/tmux" <<'SH'
#!/usr/bin/env sh
printf '%s\n' "$*" >>"$TMUX_ARGV_LOG"
case "$*" in
    *list-panes*)
        [ -n "${TMUX_PANE_PID:-}" ] || exit 1
        printf '%s\n' "$TMUX_PANE_PID"
        ;;
    *) exit 1 ;;
esac
SH
chmod +x "$BIN/tmux"

export PS_TABLE="$TMP/ps.txt"
export TMUX_ARGV_LOG="$TMP/tmux-argv.txt"
: >"$TMUX_ARGV_LOG"

CITY="$TMP/city"
mkdir -p "$CITY/.gc"
: >"$CITY/city.toml"
SINK="$CITY/.gc/usage.jsonl"
: >"$SINK"

NOW_MS=$(( $(date +%s) * 1000 ))

# usage_row <session_id> <input> <cache_read> <cache_creation> <age_seconds>
usage_row() {
    printf '{"kind":"model","session_id":"%s","worker":"w-%s","input_tokens":%s,"cache_read_tokens":%s,"cache_creation_tokens":%s,"at":%s}\n' \
        "$1" "$1" "$2" "$3" "$4" "$(( NOW_MS - $5 * 1000 ))" >>"$SINK"
}

# run_check — invoke the check with a stubbed PATH. Echoes "<exit>|<tsv row>".
# PATH is PREPENDED, not replaced: awk/jq/date/head/tail must stay real.
run_check() {
    local out code=0
    # `env` is required, not stylistic: assignment words are recognised before
    # expansion, so a bare `"$@" bash ...` would run "TMUX_PANE_PID=100" as the
    # command and exit 127.
    out=$(env PATH="$BIN:$PATH" GC_CITY="$CITY" "$@" bash "$SCRIPT" 2>/dev/null) || code=$?
    printf '%s|%s' "$code" "$out"
}

field() { printf '%s' "$1" | cut -d'|' -f2 | awk -F'\t' -v n="$2" '{print $n}'; }
code_of() { printf '%s' "$1" | cut -d'|' -f1; }

# --- RSS signal ---------------------------------------------------------------

test_rss_ok_and_heavy() {
    # pane pid 100 is the runtime; 101 is a helper child.
    printf '100 1 532480\n101 100 9040\n' >"$PS_TABLE"

    local r
    r=$(run_check TMUX_PANE_PID=100 GC_SESSION_NAME=s1 GC_SESSION_ID= )
    [ "$(code_of "$r")" = "0" ] || fail "rss under limit should exit 0, got $(code_of "$r")"
    [ "$(field "$r" 1)" = "ok" ] || fail "expected verdict ok, got '$(field "$r" 1)'"
    [ "$(field "$r" 2)" = "rss" ] || fail "expected signal rss, got '$(field "$r" 2)'"
    [ "$(field "$r" 5)" = "520" ] || fail "expected 520 MB, got '$(field "$r" 5)'"

    r=$(run_check TMUX_PANE_PID=100 GC_SESSION_NAME=s1 GC_SESSION_ID= GASTOWN_CONTEXT_LIMIT_RSS_MB=400)
    [ "$(code_of "$r")" = "1" ] || fail "rss over limit must exit 1, got $(code_of "$r")"
    [ "$(field "$r" 1)" = "heavy" ] || fail "expected heavy, got '$(field "$r" 1)'"
}

# The regression guard for the original defect. The caller's own shell is in the
# fixture table with a tiny RSS; if the check ever measures `$$` again it will
# report that instead of the runtime.
test_measures_runtime_not_caller_shell() {
    # 100 = runtime (520 MB). $$ = this test's shell, deliberately given a 2 MB
    # row parented outside the pane subtree, mirroring the real topology.
    printf '100 1 532480\n%s 999 2656\n' "$$" >"$PS_TABLE"

    local r
    r=$(run_check TMUX_PANE_PID=100 GC_SESSION_NAME=s1 GC_SESSION_ID= )
    [ "$(field "$r" 6)" = "100" ] || fail "must report the pane-subtree runtime pid, got '$(field "$r" 6)'"
    [ "$(field "$r" 5)" = "520" ] || fail "must measure the runtime, not the caller shell; got '$(field "$r" 5)' MB"

    # And the inert comparison must now be reachable: the same reading trips a
    # threshold the old snippet could never have reached from a 2 MB shell.
    r=$(run_check TMUX_PANE_PID=100 GC_SESSION_NAME=s1 GC_SESSION_ID= GASTOWN_CONTEXT_LIMIT_RSS_MB=500)
    [ "$(code_of "$r")" = "1" ] || fail "a real runtime reading must be able to trip the gate"
}

# The runtime is not always the pane's root process; a pane that starts a shell
# which then spawns the runtime puts it a level down.
test_finds_runtime_below_pane_root() {
    printf '100 1 2656\n200 100 532480\n300 200 4096\n' >"$PS_TABLE"

    local r
    r=$(run_check TMUX_PANE_PID=100 GC_SESSION_NAME=s1 GC_SESSION_ID= )
    [ "$(field "$r" 6)" = "200" ] || fail "grandchild runtime not found, got pid '$(field "$r" 6)'"
    [ "$(field "$r" 5)" = "520" ] || fail "expected 520 MB from the descendant, got '$(field "$r" 5)'"
}

# MAX, not sum: helper processes must not inflate the reading past the gate.
test_rss_is_max_not_sum() {
    # Four 300 MB helpers alongside a 200 MB runtime. Summing gives 1400 MB and
    # would trip a 1200 MB gate; the correct reading is 200 MB.
    printf '100 1 204800\n101 100 307200\n102 100 307200\n103 100 307200\n104 100 307200\n' >"$PS_TABLE"

    local r
    r=$(run_check TMUX_PANE_PID=100 GC_SESSION_NAME=s1 GC_SESSION_ID= )
    [ "$(field "$r" 5)" = "300" ] || fail "expected max child 300 MB, got '$(field "$r" 5)'"
    [ "$(code_of "$r")" = "0" ] || fail "summing helpers must not trip the gate; exit was $(code_of "$r")"
}

# Exact session addressing: a prefix collision must not measure another agent.
test_session_addressed_exactly() {
    printf '100 1 532480\n' >"$PS_TABLE"
    : >"$TMUX_ARGV_LOG"
    run_check TMUX_PANE_PID=100 GC_SESSION_NAME=gastown__witness GC_SESSION_ID= >/dev/null
    grep -q -- '-t =gastown__witness' "$TMUX_ARGV_LOG" \
        || fail "tmux must be addressed with an exact '=name' target; got: $(cat "$TMUX_ARGV_LOG")"
}

# --- token signal -------------------------------------------------------------

test_tokens_fresh() {
    : >"$PS_TABLE"
    : >"$SINK"
    usage_row tok1 10 120000 5000 30      # 125,010 tokens, 30s old

    local r
    r=$(run_check GC_SESSION_NAME= GC_SESSION_ID=tok1)
    [ "$(code_of "$r")" = "0" ] || fail "fresh under-limit tokens should exit 0, got $(code_of "$r")"
    [ "$(field "$r" 2)" = "tokens" ] || fail "expected signal tokens, got '$(field "$r" 2)'"
    [ "$(field "$r" 3)" = "125010" ] || fail "expected 125010 tokens, got '$(field "$r" 3)'"

    r=$(run_check GC_SESSION_NAME= GC_SESSION_ID=tok1 GASTOWN_CONTEXT_LIMIT_TOKENS=100000)
    [ "$(code_of "$r")" = "1" ] || fail "tokens over limit must exit 1, got $(code_of "$r")"
}

# The newest row wins, and "newest" is FILE order — a batch flush stamps many
# rows with an identical `at`, so `at` cannot order within a batch.
test_newest_row_wins_in_file_order() {
    : >"$PS_TABLE"
    : >"$SINK"
    local same=$(( NOW_MS - 5000 ))
    printf '{"kind":"model","session_id":"tok2","input_tokens":0,"cache_read_tokens":90000,"cache_creation_tokens":0,"at":%s}\n' "$same" >>"$SINK"
    printf '{"kind":"model","session_id":"tok2","input_tokens":0,"cache_read_tokens":95000,"cache_creation_tokens":0,"at":%s}\n' "$same" >>"$SINK"

    local r
    r=$(run_check GC_SESSION_NAME= GC_SESSION_ID=tok2)
    [ "$(field "$r" 3)" = "95000" ] || fail "expected the last line in file order (95000), got '$(field "$r" 3)'"
}

# Non-model rows carry no prompt side and must not be read as context.
test_ignores_non_model_rows() {
    : >"$PS_TABLE"
    : >"$SINK"
    usage_row tok3 0 150000 0 10
    printf '{"kind":"compute","session_id":"tok3","wall_seconds":12.5,"at":%s}\n' "$NOW_MS" >>"$SINK"

    local r
    r=$(run_check GC_SESSION_NAME= GC_SESSION_ID=tok3)
    [ "$(field "$r" 3)" = "150000" ] || fail "a compute row must not displace the model reading, got '$(field "$r" 3)'"
}

# An unset selector must not match rows that merely lack the field.
test_empty_selector_matches_nothing() {
    : >"$PS_TABLE"
    : >"$SINK"
    printf '{"kind":"model","input_tokens":0,"cache_read_tokens":700000,"cache_creation_tokens":0,"at":%s}\n' "$NOW_MS" >>"$SINK"

    local r
    r=$(run_check GC_SESSION_NAME= GC_SESSION_ID= )
    [ "$(code_of "$r")" = "2" ] || fail "an empty selector must match nothing, got exit $(code_of "$r")"
}

# --- staleness asymmetry ------------------------------------------------------

# Context only grows between compactions, so an OLD reading above the limit is
# still evidence of heaviness.
test_stale_over_limit_still_trips() {
    : >"$PS_TABLE"
    : >"$SINK"
    usage_row tok4 0 500000 0 7200        # 500,000 tokens, 2 hours old

    local r
    r=$(run_check GC_SESSION_NAME= GC_SESSION_ID=tok4)
    [ "$(code_of "$r")" = "1" ] || fail "stale but over-limit must still trip, got exit $(code_of "$r")"
    [ "$(field "$r" 1)" = "heavy" ] || fail "expected heavy, got '$(field "$r" 1)'"
}

# ...but an old reading BELOW the limit says nothing about now, so it must not
# be counted as health. With no RSS to fall back to, that is `unmeasured`.
test_stale_under_limit_is_discarded() {
    : >"$PS_TABLE"
    : >"$SINK"
    usage_row tok5 0 100000 0 7200        # 100,000 tokens, 2 hours old

    local r
    r=$(run_check GC_SESSION_NAME= GC_SESSION_ID=tok5)
    [ "$(code_of "$r")" = "2" ] || fail "a stale under-limit reading must not grant health, got exit $(code_of "$r")"
    [ "$(field "$r" 1)" = "unmeasured" ] || fail "expected unmeasured, got '$(field "$r" 1)'"
    # The number is still reported — discarded as a verdict, not hidden.
    [ "$(field "$r" 3)" = "100000" ] || fail "the stale reading should still be shown, got '$(field "$r" 3)'"

    # Widening the freshness window makes the same reading usable.
    r=$(run_check GC_SESSION_NAME= GC_SESSION_ID=tok5 GASTOWN_CONTEXT_TOKENS_MAX_AGE_SEC=99999)
    [ "$(code_of "$r")" = "0" ] || fail "inside the window the reading should count, got exit $(code_of "$r")"
}

# A stale under-limit token reading must fall through to RSS rather than
# suppressing it.
test_stale_tokens_fall_back_to_rss() {
    printf '100 1 532480\n' >"$PS_TABLE"
    : >"$SINK"
    usage_row tok6 0 100000 0 7200

    local r
    r=$(run_check TMUX_PANE_PID=100 GC_SESSION_NAME=s1 GC_SESSION_ID=tok6)
    [ "$(field "$r" 2)" = "rss" ] || fail "expected the verdict to fall to rss, got '$(field "$r" 2)'"
    [ "$(code_of "$r")" = "0" ] || fail "rss under limit should exit 0, got $(code_of "$r")"
}

# An age that cannot be computed must resolve to stale, not fresh. Defaulting
# an unknown to "recent" would grant health on a reading whose currency was
# never established.
test_unknown_age_counts_as_stale() {
    : >"$PS_TABLE"
    : >"$SINK"
    printf '{"kind":"model","session_id":"tok8","input_tokens":0,"cache_read_tokens":100000,"cache_creation_tokens":0}\n' >>"$SINK"

    local r
    r=$(run_check GC_SESSION_NAME= GC_SESSION_ID=tok8)
    [ "$(field "$r" 4)" = "-" ] || fail "an unparseable age should render '-', got '$(field "$r" 4)'"
    [ "$(code_of "$r")" = "2" ] || fail "an unknown age must not grant health, got exit $(code_of "$r")"

    # ...but it is still a reading, so an unknown-age value OVER the limit trips
    # for the same reason a stale one does.
    r=$(run_check GC_SESSION_NAME= GC_SESSION_ID=tok8 GASTOWN_CONTEXT_LIMIT_TOKENS=50000)
    [ "$(code_of "$r")" = "1" ] || fail "unknown-age over-limit must still trip, got exit $(code_of "$r")"
}

test_both_signals_reported() {
    printf '100 1 532480\n' >"$PS_TABLE"
    : >"$SINK"
    usage_row tok7 0 120000 0 10

    local r
    r=$(run_check TMUX_PANE_PID=100 GC_SESSION_NAME=s1 GC_SESSION_ID=tok7)
    [ "$(field "$r" 2)" = "tokens+rss" ] || fail "expected 'tokens+rss', got '$(field "$r" 2)'"
}

# --- unmeasured ---------------------------------------------------------------

# The single most important assertion in this file: no signal must never read
# as healthy. Exit 0 here would recreate the defect the bead reported.
test_unmeasured_is_not_ok() {
    : >"$PS_TABLE"
    : >"$SINK"

    local r
    r=$(run_check GC_SESSION_NAME= GC_SESSION_ID= )
    [ "$(code_of "$r")" = "2" ] || fail "no signal must exit 2, not $(code_of "$r")"
    [ "$(field "$r" 1)" = "unmeasured" ] || fail "expected unmeasured, got '$(field "$r" 1)'"
    [ "$(field "$r" 3)" = "-" ] || fail "absent tokens must render '-', not a number, got '$(field "$r" 3)'"
    [ "$(field "$r" 5)" = "-" ] || fail "absent rss must render '-', not a number, got '$(field "$r" 5)'"
}

# A named session with no tmux pane resolves nothing — still unmeasured, not ok.
test_missing_pane_is_unmeasured() {
    : >"$PS_TABLE"
    : >"$SINK"

    local r
    r=$(run_check GC_SESSION_NAME=ghost GC_SESSION_ID= )   # TMUX_PANE_PID unset -> stub exits 1
    [ "$(code_of "$r")" = "2" ] || fail "an unresolvable pane must exit 2, got $(code_of "$r")"
}

# --- wrapper ------------------------------------------------------------------

test_wrapper_requires_pack_context() {
    local code=0
    ( env -u GC_PACK_DIR -u GC_CITY_PATH sh "$WRAPPER" >/dev/null 2>&1 ) || code=$?
    [ "$code" = "2" ] || fail "wrapper without pack context must exit 2, got $code"

    code=0
    ( env GC_PACK_DIR="$TMP/nope" GC_CITY_PATH="$CITY" sh "$WRAPPER" >/dev/null 2>&1 ) || code=$?
    [ "$code" = "2" ] || fail "wrapper with a pack missing the check must exit 2, got $code"
}

test_wrapper_dispatches_and_passes_exit_through() {
    printf '100 1 532480\n' >"$PS_TABLE"
    : >"$SINK"
    local code=0
    ( PATH="$BIN:$PATH" TMUX_PANE_PID=100 GC_SESSION_NAME=s1 GC_SESSION_ID= \
        GASTOWN_CONTEXT_LIMIT_RSS_MB=400 GC_PACK_DIR="$ROOT/gastown" GC_CITY_PATH="$CITY" \
        sh "$WRAPPER" >/dev/null 2>&1 ) || code=$?
    [ "$code" = "1" ] || fail "wrapper must pass the check's exit through; expected 1, got $code"
}

# --- the formulas actually use it ---------------------------------------------

# Without this the command could ship perfect and the patrols keep the dead
# snippet, which is materially the state the bead reported.
test_formulas_dropped_the_inert_snippet() {
    # Match the EXECUTABLE shape, not the mention. All three formulas keep a
    # prose warning naming `ps -o rss= -p $$` so a future author knows why not
    # to reintroduce it; a bare substring check cannot tell that warning from
    # the guard it warns about, and would force the docs to delete the one
    # sentence explaining the bug.
    local f
    for f in mol-witness-patrol mol-deacon-patrol mol-refinery-patrol; do
        local path="$ROOT/gastown/formulas/$f.toml"
        [ -f "$path" ] || fail "missing formula $path"
        ! grep -F -q -e 'RSS=$(ps -o rss= -p $$' "$path" \
            || fail "$f assigns RSS from \$\$ again — the inert guard is back"
        ! grep -F -q -e 'RSS_MB=$((RSS / 1024))' "$path" \
            || fail "$f still derives RSS_MB from the \$\$ reading"
        ! grep -F -q -e 'If RSS > 1500 MB' "$path" \
            || fail "$f still gates on the unreachable 1500 MB threshold"
        grep -q 'gc gastown context-usage' "$path" \
            || fail "$f does not invoke 'gc gastown context-usage'"
    done
}

# The witness and deacon must act on the exit code, not just print it.
test_patrols_wire_restart_to_exit_1() {
    local f
    for f in mol-witness-patrol mol-deacon-patrol; do
        grep -q 'gc runtime request-restart' "$ROOT/gastown/formulas/$f.toml" \
            || fail "$f lost its request-restart call"
    done
}

test_command_is_dispatchable() {
    [ -x "$ROOT/gastown/assets/scripts/context-usage-check.sh" ] \
        || fail "assets/scripts/context-usage-check.sh must be executable"
    [ -x "$WRAPPER" ] || fail "commands/context-usage/run.sh must be executable"
    [ -r "$ROOT/gastown/commands/context-usage/help.md" ] \
        || fail "commands/context-usage/help.md is required for dispatch coverage"
}

test_rss_ok_and_heavy
test_measures_runtime_not_caller_shell
test_finds_runtime_below_pane_root
test_rss_is_max_not_sum
test_session_addressed_exactly
test_tokens_fresh
test_newest_row_wins_in_file_order
test_ignores_non_model_rows
test_empty_selector_matches_nothing
test_stale_over_limit_still_trips
test_stale_under_limit_is_discarded
test_stale_tokens_fall_back_to_rss
test_unknown_age_counts_as_stale
test_both_signals_reported
test_unmeasured_is_not_ok
test_missing_pane_is_unmeasured
test_wrapper_requires_pack_context
test_wrapper_dispatches_and_passes_exit_through
test_formulas_dropped_the_inert_snippet
test_patrols_wire_restart_to_exit_1
test_command_is_dispatchable

echo "PASS: context-usage-check (21 checks)"
