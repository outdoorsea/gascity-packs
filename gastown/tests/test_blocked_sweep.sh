#!/usr/bin/env bash
# Tests for the blocked-bead sweep (gp-6ph).
#
# The bead's shape dictates this file's shape. Every step of mol-witness-patrol
# selected on open / in_progress / closed and none enumerated status=blocked, so
# a blocked bead was invisible to the entire patrol. A check for an invisible
# thing has to be shown to FIRE — "the sweep runs clean" is indistinguishable
# from the bug — so the first two tests are true positives on the two shapes
# observed live, and each confirmed break below gets a test that fails if it
# returns:
#
#   gp-yjx (P1)  blocked, unassigned, still holding a 17M worktree.
#                recover-orphaned-beads skips unassigned beads and never lists
#                blocked; worktree-reap saw the tree and correctly refused it
#                ("status=blocked; work is still in flight") because it keys on
#                the bead's terminal state and blocked is not terminal.
#   gp-fcd (P2)  five days at gc.routed_to=<rig>/gastown.polecat while blocked.
#                A pool cannot claim a blocked bead, so the routing was inert.
#
# One break was found by this suite's own first smoke run rather than reported,
# and it is pinned by test_absent_work_dir_does_not_shift_columns: TAB is IFS
# *whitespace*, so `IFS=$'\t' read` collapses a run of tabs into one delimiter
# and an absent column silently shifts every later column left. gp-fcd parsed
# with routed_to="human" in the WORKTREE column and its title in routed_to — a
# well-formed row asserting something false, which is the same
# looks-healthy-so-nobody-looks failure the check exists to end.
#
# Every fixture here is synthetic. Nothing in this suite touches the real ledger.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT/gastown/assets/scripts/blocked-sweep.sh"
WRAPPER="$ROOT/gastown/commands/blocked-sweep/run.sh"
FORMULA="$ROOT/gastown/formulas/mol-witness-patrol.toml"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# The `gc` the check talks to. The whole ledger is served from one fixture file,
# and every invocation is appended to $GC_CALL_LOG so a test can assert on the
# QUERY as well as the answer — the bead is about a status nobody ever asked for,
# so "did it actually ask for blocked" is a first-class assertion here.
#
# GC_FAIL_MODE injects the shapes that must not read as health:
#   bdlist-exit      the query failing outright
#   bdlist-envelope  {"ok":false} on STDOUT with exit 0 — the gp-b3x shape
#   bdlist-nonarray  a well-formed object where an array belongs
#   bdlist-unfiltered  the --status=blocked filter silently ignored
write_gc_stub() {
    local bin="$1"
    mkdir -p "$bin"
    cat >"$bin/gc" <<'SH'
#!/usr/bin/env sh
printf '%s\n' "$*" >>"$GC_CALL_LOG"
case "$*" in
    *"bd"*"list"*)
        case "${GC_FAIL_MODE:-}" in
            bdlist-exit) exit 1 ;;
            bdlist-envelope)
                printf '{"schema_version":"1","ok":false,"error":{"code":"json_command_not_found","message":"unknown flag --status"}}'
                exit 0
                ;;
            bdlist-nonarray) printf '{"schema_version":"1","ok":true,"issues":[]}' ;;
            bdlist-unfiltered) cat "$GC_UNFILTERED_JSON" ;;
            *) cat "$GC_BEADS_JSON" ;;
        esac
        ;;
    *) printf '{}' ;;
esac
SH
    chmod +x "$bin/gc"
}

# run_check <beads-json> [env assignments...]
#
# GC_BIN is explicitly unset. Gas Town sessions export it as an absolute path,
# and anything reaching for ${GC_BIN:-gc} would escape the PATH stub onto the
# LIVE ledger — a test that silently measures the developer's real city instead
# of its fixture. The check spells `gc` literally so PATH is authoritative, and
# this keeps it that way if that ever changes.
run_check() {
    local beads="$1"
    shift
    printf '%s' "$beads" >"$BEADS"
    : >"$CALLS"
    set +e
    # ${1+"$@"} rather than "$@": bash 3.2 under `set -u` treats an empty "$@"
    # as an unbound variable.
    OUT=$(env -u GC_BIN GC_CITY="$CITY" GC_BEADS_JSON="$BEADS" GC_CALL_LOG="$CALLS" \
        GC_UNFILTERED_JSON="$UNFILTERED" \
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
    local beads="$1"
    shift
    printf '%s' "$beads" >"$BEADS"
    : >"$CALLS"
    set +e
    OUT=$(cd "$NOCITY" && env -u GC_CITY -u GC_BIN \
        GC_CITY_PATH="${WRAP_CITY-$CITY}" GC_PACK_DIR="${WRAP_PACK-$ROOT/gastown}" \
        GC_BEADS_JSON="$BEADS" GC_CALL_LOG="$CALLS" GC_UNFILTERED_JSON="$UNFILTERED" \
        PATH="$BIN:$PATH" ${1+"$@"} sh "$WRAPPER" 2>"$ERRFILE")
    RC=$?
    set -e
    ERR=$(cat "$ERRFILE")
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
CITY="$tmp/city"
BIN="$tmp/bin"
BEADS="$tmp/beads.json"
UNFILTERED="$tmp/unfiltered.json"
CALLS="$tmp/calls.log"
ERRFILE="$tmp/stderr.txt"
NOCITY="$tmp/nocity"
mkdir -p "$CITY" "$NOCITY"
: >"$CITY/city.toml"
write_gc_stub "$BIN"

# A worktree that exists on disk, and a path that does not. Existence is the
# whole difference between a leaked tree and a dangling pointer.
LIVE_TREE="$tmp/trees/gp-yjx"
DEAD_TREE="$tmp/trees/gp-gone"
mkdir -p "$LIVE_TREE"

# bead <id> <priority> <work_dir> <routed_to> [title] [status]
#
# Empty work_dir / routed_to OMIT the key entirely rather than writing null,
# because that is what `gc bd list --json` does: gp-yjx exposes no `assignee` key
# at all rather than a null one. A fixture that wrote nulls would test a payload
# shape the ledger never produces.
bead() {
    jq -nc --arg id "$1" --argjson pri "$2" --arg wd "$3" --arg route "$4" \
        --arg title "${5:-A blocked bead}" --arg status "${6:-blocked}" '
        {id: $id, priority: $pri, status: $status, title: $title,
         owner: "jeremy@geocaching.com"}
        + {metadata: (({}
             | if $wd != "" then . + {"work_dir": $wd} else . end)
             | if $route != "" then . + {"gc.routed_to": $route} else . end)}
    '
}

beads() { printf '[%s]' "$(IFS=,; echo "$*")"; }

col() { # col <n> <row-grep> — pull one TSV column out of the matching row
    printf '%s' "$OUT" | grep "$2" | head -1 | cut -f"$1"
}

# --- the acceptance clause: it must be able to produce a positive -------------

test_holding_worktree_fires() {
    # THE test, gp-yjx's shape: blocked, unassigned, routed to a human, and a
    # worktree still on disk. Invisible to every patrol step before this check.
    run_check "$(beads "$(bead gp-yjx 1 "$LIVE_TREE" human 'Order failures record no diagnostic')")"

    [ "$RC" -eq 1 ] ||
        fail "a blocked bead holding a worktree MUST exit 1 — this is the acceptance clause, got $RC ($OUT / $ERR)"
    printf '%s' "$OUT" | grep -q "^holding-worktree	gp-yjx	1	$LIVE_TREE	" ||
        fail "expected a holding-worktree row carrying the path, got: $OUT"
    printf '%s' "$ERR" | grep -q '1 holding a worktree' ||
        fail "the summary must count the held worktree, got: $ERR"
}

test_inert_pool_routing_fires() {
    # gp-fcd's shape: blocked with pool routing. A pool cannot claim a blocked
    # bead, so the routing generates zero demand and is silently wrong.
    run_check "$(beads "$(bead gp-fcd 2 "" alpha/gastown.polecat 'Pool claim order is age-only')")"

    [ "$RC" -eq 1 ] || fail "blocked + pool routing MUST exit 1, got $RC ($OUT / $ERR)"
    printf '%s' "$OUT" | grep -q '^inert-routing	gp-fcd	2	-	alpha/gastown.polecat	' ||
        fail "expected an inert-routing row naming the pool, got: $OUT"
    printf '%s' "$ERR" | grep -q '1 with inert pool routing' ||
        fail "the summary must count the inert routing, got: $ERR"
}

test_the_query_actually_asks_for_blocked() {
    # The bead in one assertion. Everything else in the patrol asks for open /
    # in_progress / closed; if this check drifted to any of those it would go
    # green forever while measuring nothing that was missing.
    run_check "$(beads "$(bead gp-1 2 "" human)")"
    grep -q -- '--status=blocked' "$CALLS" ||
        fail "the check must query --status=blocked; calls were: $(cat "$CALLS")"
}

# --- the deliberate park is healthy and must never be flagged -----------------

test_parked_bead_is_not_flagged() {
    # blocked + human is frequently a DELIBERATE park (the 2026-08-03 mayor
    # standing rule). Flagging it is how a sweep gets muted, and rerouting it
    # would override a stated intent rather than a forgotten one.
    run_check "$(beads "$(bead gp-fcd 2 "" human)")"
    [ "$RC" -eq 0 ] || fail "a parked bead must not be a finding, got $RC ($OUT / $ERR)"
    printf '%s' "$OUT" | grep -q '^parked	gp-fcd	' || fail "expected a parked row, got: $OUT"
}

test_bead_with_no_routing_at_all_is_parked() {
    run_check "$(beads "$(bead gp-1 3 "" "")")"
    [ "$RC" -eq 0 ] || fail "blocked with no routing and no tree is parked, got $RC ($OUT)"
    printf '%s' "$OUT" | grep -q '^parked	gp-1	3	-	-	' ||
        fail "expected a parked row with dashes in both columns, got: $OUT"
}

test_no_blocked_beads_is_clean() {
    run_check '[]'
    [ "$RC" -eq 0 ] || fail "an empty blocked set must exit 0, got $RC ($ERR)"
    printf '%s' "$ERR" | grep -q 'nothing to sweep' ||
        fail "expected the nothing-to-sweep summary, got: $ERR"
}

test_stale_worktree_ref_is_reported_but_not_a_finding() {
    # work_dir set, directory already gone. The tree is collected and a dangling
    # pointer harms nothing — reporting it as a finding would train the witness
    # to skim past real ones.
    run_check "$(beads "$(bead gp-1 2 "$DEAD_TREE" human)")"
    [ "$RC" -eq 0 ] || fail "a dangling work_dir is not a finding, got $RC ($OUT / $ERR)"
    printf '%s' "$OUT" | grep -q '^stale-worktree-ref	gp-1	' ||
        fail "expected a stale-worktree-ref row, got: $OUT"
    printf '%s' "$ERR" | grep -q '0 holding a worktree' ||
        fail "a dangling ref must not count as a held worktree, got: $ERR"
}

# --- column integrity: the break this suite's own first run found -------------

test_absent_work_dir_does_not_shift_columns() {
    # TAB is IFS whitespace, so `IFS=$'\t' read` collapses consecutive tabs and
    # an empty column shifts every later column LEFT. Before the "-" placeholders
    # this exact fixture parsed as worktree="human" and routed_to=<title>: a
    # well-formed row asserting something false, which is worse than no row.
    run_check "$(beads "$(bead gp-fcd 2 "" human 'Pool claim order is age-only')")"
    [ "$(col 4 '^parked')" = "-" ] ||
        fail "an absent work_dir must render as '-' in column 4, got: $(col 4 '^parked')"
    [ "$(col 5 '^parked')" = "human" ] ||
        fail "routed_to must stay in column 5, got: $(col 5 '^parked')"
    [ "$(col 6 '^parked')" = "Pool claim order is age-only" ] ||
        fail "the title must stay in column 6, got: $(col 6 '^parked')"
}

test_a_tab_in_the_title_does_not_shift_columns() {
    run_check "$(beads "$(bead gp-1 2 "" human "$(printf 'tabbed\ttitle')")")"
    [ "$(col 5 '^parked')" = "human" ] ||
        fail "a tab inside the title must not displace routed_to, got: $(col 5 '^parked')"
}

# --- both axes at once --------------------------------------------------------

test_both_axes_are_counted_independently() {
    # One bead tripping both. The verdict names the worktree (disk is scarcer and
    # the tree outlives the routing), but the routing must not vanish behind it:
    # the column still carries the pool and the summary counts both.
    run_check "$(beads "$(bead gp-1 1 "$LIVE_TREE" alpha/gastown.polecat)")"
    [ "$RC" -eq 1 ] || fail "a bead tripping both axes must exit 1, got $RC"
    printf '%s' "$OUT" | grep -q '^holding-worktree	gp-1	' ||
        fail "the worktree verdict should win precedence, got: $OUT"
    [ "$(col 5 '^holding-worktree')" = "alpha/gastown.polecat" ] ||
        fail "the inert route must still be visible in its column, got: $(col 5 '^holding-worktree')"
    printf '%s' "$ERR" | grep -q '1 holding a worktree, 1 with inert pool routing' ||
        fail "both axes must be counted independently in the summary, got: $ERR"
}

test_every_blocked_bead_gets_a_row() {
    run_check "$(beads \
        "$(bead gp-1 1 "$LIVE_TREE" human)" \
        "$(bead gp-2 2 "" alpha/gastown.polecat)" \
        "$(bead gp-3 3 "" human)" \
        "$(bead gp-4 2 "$DEAD_TREE" "")")"
    [ "$(printf '%s\n' "$OUT" | grep -c '	gp-')" -eq 4 ] ||
        fail "every blocked bead needs a row — a skipped bead is the original bug: $OUT"
    printf '%s' "$ERR" | grep -q '4 blocked bead(s)' || fail "expected a total of 4, got: $ERR"
}

# --- park routes --------------------------------------------------------------

test_park_routes_are_configurable() {
    run_check "$(beads "$(bead gp-1 2 "" operator)")" GASTOWN_BLOCKED_PARK_ROUTES=human,operator
    [ "$RC" -eq 0 ] || fail "a configured park route must not be a finding, got $RC ($OUT)"
    printf '%s' "$OUT" | grep -q '^parked	' || fail "expected parked, got: $OUT"
}

test_unconfigured_route_is_still_inert() {
    # The same fixture without the config: `operator` is not a park sentinel by
    # default, so it reads as a pool address.
    run_check "$(beads "$(bead gp-1 2 "" operator)")"
    [ "$RC" -eq 1 ] || fail "an unrecognized route must read as a pool, got $RC ($OUT)"
}

test_park_route_match_is_case_insensitive() {
    # `Human` must not be reported as a defect against an operator who parked the
    # bead correctly.
    run_check "$(beads "$(bead gp-1 2 "" Human)")"
    [ "$RC" -eq 0 ] || fail "park matching must be case-insensitive, got $RC ($OUT)"
}

# --- nothing-measured is never health -----------------------------------------

test_query_failure_fails_loud() {
    run_check "$(beads "$(bead gp-1 2 "" human)")" GC_FAIL_MODE=bdlist-exit
    [ "$RC" -eq 2 ] || fail "a failed query must exit 2, not 0, got $RC"
    printf '%s' "$ERR" | grep -q 'NOT measured' || fail "must say nothing was measured, got: $ERR"
}

test_ok_false_envelope_is_caught_even_with_a_zero_exit() {
    # `gc` reports a rejected flag by printing an {"ok":false} envelope to
    # STDOUT. A status-only guard misses it — the gp-b3x shape.
    run_check "$(beads "$(bead gp-1 2 "" human)")" GC_FAIL_MODE=bdlist-envelope
    [ "$RC" -eq 2 ] || fail "an ok:false envelope must exit 2 even on a zero exit, got $RC ($OUT)"
    printf '%s' "$ERR" | grep -q 'NOT measured' || fail "must say nothing was measured, got: $ERR"
}

test_non_array_payload_fails_loud() {
    run_check "$(beads "$(bead gp-1 2 "" human)")" GC_FAIL_MODE=bdlist-nonarray
    [ "$RC" -eq 2 ] || fail "a non-array payload must exit 2, got $RC ($OUT)"
}

test_ignored_status_filter_fails_loud() {
    # This is the one status Gas Town had never queried, so its server-side
    # filter has no operational history. If it were ignored, the whole ledger
    # would arrive here and get classified — a flood of false findings that reads
    # like a catastrophe. A detector inventing a query must verify the query did
    # what it asked.
    bead gp-open 1 "" alpha/gastown.polecat 'An open bead' open >"$tmp/one.json"
    printf '[%s]' "$(cat "$tmp/one.json")" >"$UNFILTERED"
    run_check "$(beads "$(bead gp-1 2 "" human)")" GC_FAIL_MODE=bdlist-unfiltered
    [ "$RC" -eq 2 ] || fail "a non-blocked row in the result must exit 2, got $RC ($OUT)"
    printf '%s' "$ERR" | grep -q 'status filter is not being applied' ||
        fail "must name the unapplied filter, got: $ERR"
}

test_missing_city_fails_loud() {
    set +e
    OUT=$(cd "$NOCITY" && env -u GC_CITY -u GC_BIN GC_BEADS_JSON="$BEADS" \
        GC_CALL_LOG="$CALLS" PATH="$BIN:$PATH" bash "$SCRIPT" 2>"$ERRFILE")
    RC=$?
    set -e
    [ "$RC" -eq 2 ] || fail "no resolvable city must exit 2, got $RC"
}

# --- discipline ---------------------------------------------------------------

test_check_is_read_only() {
    # Report-only is the bead's explicit requirement: blocked+human is frequently
    # a deliberate park and must not be auto-rerouted, and whether a tree is safe
    # to delete is worktree-reap's predicate, not this one's.
    ! grep -nE '^[^#]*gc (mail|session (nudge|wake)|bd (create|update|close))' "$SCRIPT" >/dev/null ||
        fail "the sweep must not mail, nudge, or mutate beads — the witness owns those decisions"
    ! grep -nE '^[^#]*(rm -rf|git worktree remove|rmdir)' "$SCRIPT" >/dev/null ||
        fail "the sweep must never remove a worktree — that is worktree-reap's predicate"
}

test_uses_no_bash4_only_constructs() {
    ! grep -nE 'declare -A|local -A|mapfile|readarray|\$\{[A-Za-z_]+\^|\$\{[A-Za-z_]+,,|&>>|\[\[ -v ' "$SCRIPT" >/dev/null ||
        fail "the check must stay bash 3.2 compatible (the fleet includes macOS)"
}

# --- the `gc gastown blocked-sweep` wrapper -----------------------------------

test_wrapper_is_executable() {
    # Not merely present: a lost exec bit halts the caller with "permission
    # denied", which reads like a resolver refusal rather than a broken file
    # (gp-ia7).
    [ -x "$WRAPPER" ] || fail "$WRAPPER must be executable"
    [ -f "$ROOT/gastown/commands/blocked-sweep/help.md" ] ||
        fail "missing commands/blocked-sweep/help.md"
    [ -x "$SCRIPT" ] || fail "$SCRIPT must be executable"
}

test_wrapper_rejects_missing_pack_context() {
    # Invoked by path instead of through `gc`, so GC_PACK_DIR is empty. It must
    # fail loudly rather than resolving to /assets/scripts/... and reporting a
    # clean sweep (gp-3qb) — a silent no-op is the failure class this bead is
    # about, so it must not return through the plumbing of its own fix.
    WRAP_PACK="" run_wrapper '[]'
    [ "$RC" -eq 2 ] || fail "missing GC_PACK_DIR must exit 2, got $RC"
    printf '%s' "$ERR" | grep -q 'missing Gas City pack context' ||
        fail "the wrapper must name the missing pack context, got: $ERR"
}

test_wrapper_rejects_missing_city_context() {
    WRAP_CITY="" run_wrapper '[]'
    [ "$RC" -eq 2 ] || fail "missing GC_CITY_PATH must exit 2, got $RC"
}

test_wrapper_reports_a_pack_without_the_check() {
    # An older pack pin that predates this command. Exit 2 — "not measured" —
    # never 0, which would read as "no blocked bead is holding anything".
    WRAP_PACK="$tmp" run_wrapper '[]'
    [ "$RC" -eq 2 ] || fail "a pack missing the check must exit 2, got $RC"
    printf '%s' "$ERR" | grep -q 'not found in this pack version' ||
        fail "the wrapper must say the check is missing, got: $ERR"
}

test_wrapper_resolves_the_city_from_pack_context() {
    run_wrapper "$(beads "$(bead gp-1 2 "" human)")"
    [ "$RC" -eq 0 ] ||
        fail "the wrapper must resolve the city from GC_CITY_PATH, got $RC: $ERR"
    printf '%s' "$OUT" | grep -q '^parked	gp-1	' ||
        fail "the wrapper should relay the check's TSV rows, got: $OUT"
}

test_wrapper_passes_findings_exit_through() {
    # Exit 1 is a verdict, not an error to swallow: the witness branches on it.
    run_wrapper "$(beads "$(bead gp-yjx 1 "$LIVE_TREE" human)")"
    [ "$RC" -eq 1 ] || fail "the wrapper must pass through exit 1 (findings), got $RC"
    printf '%s' "$OUT" | grep -q '^holding-worktree	' || fail "expected a finding row, got: $OUT"
}

test_wrapper_passes_park_routes_through() {
    run_wrapper "$(beads "$(bead gp-1 2 "" operator)")" GASTOWN_BLOCKED_PARK_ROUTES=operator
    [ "$RC" -eq 0 ] ||
        fail "GASTOWN_BLOCKED_PARK_ROUTES must reach the check through the wrapper, got $RC ($OUT)"
}

# --- the caller actually invokes it, the resolvable way -----------------------

test_formula_invokes_the_command_not_the_path() {
    grep -Fq 'gc gastown blocked-sweep' "$FORMULA" ||
        fail "mol-witness-patrol must run the sweep as 'gc gastown blocked-sweep'"
    ! grep -qE '^[[:space:]]*BLOCKED_CHECK=' "$FORMULA" ||
        fail "formula must not resolve the check into a path variable"
    ! grep -qE '^[[:space:]]*(bash|sh|exec)[[:space:]].*GC_PACK_DIR' "$FORMULA" ||
        fail "formula must not execute a script through ambient GC_PACK_DIR"
}

test_formula_treats_a_silent_failure_as_not_measured() {
    # `gc` reports an unknown pack subcommand with exit 1 and NO stdout, which is
    # otherwise indistinguishable from exit 1 with findings. A city whose pin
    # predates this command must read as UNMEASURED, not as a clean sweep —
    # otherwise deployment lag silently restores the exact gap being closed.
    grep -Fq 'DID NOT RUN' "$FORMULA" ||
        fail "the step must distinguish 'exit 1 with no rows' (did not run) from findings"
}

test_formula_step_is_wired_into_the_patrol_chain() {
    # A step nothing depends on is a step that never runs. The sweep must sit in
    # the needs chain, not dangle off the side of it.
    grep -Fq 'id = "check-blocked-beads"' "$FORMULA" ||
        fail "mol-witness-patrol must define the check-blocked-beads step"
    grep -Fq 'needs = ["check-blocked-beads"]' "$FORMULA" ||
        fail "a later step must depend on check-blocked-beads or it never runs"
}

test_formula_step_does_not_mutate_blocked_beads() {
    # Report-only is the bead's explicit requirement. Scope the scan to this
    # step's own text: the surrounding patrol legitimately reroutes and closes
    # beads in other steps.
    local step
    step=$(awk '/^id = "check-blocked-beads"$/{f=1} f&&/^\[\[steps\]\]$/&&!/check-blocked-beads/{if(seen)exit} /^\[\[steps\]\]$/{seen=f} f{print}' "$FORMULA")
    [ -n "$step" ] || fail "could not isolate the check-blocked-beads step text"
    ! printf '%s' "$step" | grep -qE 'gc bd update .*(--status=open|routed_to=\$|routed_to="\$)' ||
        fail "the blocked sweep step must report, never reroute — blocked+human is a deliberate park"
}

test_holding_worktree_fires
test_inert_pool_routing_fires
test_the_query_actually_asks_for_blocked
test_parked_bead_is_not_flagged
test_bead_with_no_routing_at_all_is_parked
test_no_blocked_beads_is_clean
test_stale_worktree_ref_is_reported_but_not_a_finding
test_absent_work_dir_does_not_shift_columns
test_a_tab_in_the_title_does_not_shift_columns
test_both_axes_are_counted_independently
test_every_blocked_bead_gets_a_row
test_park_routes_are_configurable
test_unconfigured_route_is_still_inert
test_park_route_match_is_case_insensitive
test_query_failure_fails_loud
test_ok_false_envelope_is_caught_even_with_a_zero_exit
test_non_array_payload_fails_loud
test_ignored_status_filter_fails_loud
test_missing_city_fails_loud
test_check_is_read_only
test_uses_no_bash4_only_constructs
test_wrapper_is_executable
test_wrapper_rejects_missing_pack_context
test_wrapper_rejects_missing_city_context
test_wrapper_reports_a_pack_without_the_check
test_wrapper_resolves_the_city_from_pack_context
test_wrapper_passes_findings_exit_through
test_wrapper_passes_park_routes_through
test_formula_invokes_the_command_not_the_path
test_formula_treats_a_silent_failure_as_not_measured
test_formula_step_is_wired_into_the_patrol_chain
test_formula_step_does_not_mutate_blocked_beads

echo "blocked sweep tests passed"
