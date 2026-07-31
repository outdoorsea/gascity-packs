#!/usr/bin/env bash
# test_kill_triage.sh — the acceptance evidence for gp-aik.
#
# The bead's acceptance criteria is explicit: each step must be shown to REFUSE
# on the exact false positives observed, "not merely to run clean". So the
# refusal cases below are the point of this file, not its edge cases.
#
# It also asserts the opposite direction. A triage that refuses everything would
# satisfy every refusal test here while quietly disabling real cleanup, and that
# failure is invisible from the refusal side alone — so a genuine orphan must
# still come back as a kill-candidate. Both directions or neither.
#
# Fixtures are ordinary `sleep` processes in a throwaway city root. Ownership is
# established by working directory, which is what the triage actually reads on
# macOS, so the fixtures exercise the real attribution path rather than a stub.

set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT/gastown/assets/scripts/kill-triage.sh"

FAILURES=0
fail() { echo "FAIL: $*" >&2; FAILURES=$((FAILURES + 1)); }
pass() { echo "  ok: $*"; }

[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT missing or not executable" >&2; exit 1; }

TMPCITY=$(mktemp -d)
OTHERCITY=$(mktemp -d)
KIDS=""
cleanup() {
    # shellcheck disable=SC2086
    [ -n "$KIDS" ] && kill $KIDS 2>/dev/null
    rm -rf "$TMPCITY" "$OTHERCITY"
}
trap cleanup EXIT
printf 'name = "test-city"\n' > "$TMPCITY/city.toml"
printf 'name = "other-city"\n' > "$OTHERCITY/city.toml"

track() { KIDS="$KIDS $1"; }

# spawn_detached <cwd> -> pid of a process reparented to init with that cwd
spawn_detached() {
    ( cd "$1" && sh -c 'sleep 120 >/dev/null 2>&1 & echo $!' )
}

# verdict_for <expected> <label> <args...>
verdict_for() {
    local expected="$1" label="$2"; shift 2
    local out got
    out=$(GC_CITY="$TMPCITY" GC_TRIAGE_ANCHOR="$ANCHOR" bash "$SCRIPT" "$@" 2>/dev/null)
    got=$(printf '%s' "$out" | awk 'NR==1{print $1}')
    if [ "$got" = "$expected" ]; then
        pass "$label -> $got"
    else
        fail "$label: expected '$expected', got '${got:-<no output>}'"
        printf '       full output: %s\n' "$out" >&2
    fi
}

# The stand-in session host. The real one is a tmux server, which cannot be
# assumed on a CI runner, so the anchor is pinned with GC_TRIAGE_ANCHOR.
sleep 120 & ANCHOR=$!; track "$ANCHOR"

# A live parent inside our city with a child of its own.
( cd "$TMPCITY" && exec sh -c 'sleep 120 & wait' ) &
LIVE_PARENT=$!; track "$LIVE_PARENT"
sleep 0.5
LIVE_CHILD=$(pgrep -P "$LIVE_PARENT" 2>/dev/null | head -1)

echo "== refusals =="

# 1. Another city's process. On the reporting host `ps aux | grep -E
#    'claude|node'` matched five separate cities and every match was a live
#    agent somewhere.
FOREIGN=$(spawn_detached "$OTHERCITY"); track "$FOREIGN"
sleep 0.3
verdict_for refuse-not-ours "process rooted in another city" --pid "$FOREIGN"

# 2. A process we cannot attribute at all — Discord, Claude.app, gemini, and
#    every unrelated daemon land here. Unattributable is a refusal.
UNKNOWN=$(spawn_detached /); track "$UNKNOWN"
sleep 0.3
verdict_for refuse-not-ours "unattributable process" --pid "$UNKNOWN"

# 3. A live process of THIS town, recognised through the process tree rather
#    than command text. Zero true orphans existed on the reporting host; all 11
#    processes shared the live session host as an ancestor.
if [ -n "$LIVE_CHILD" ]; then
    ANCHOR_SAVE=$ANCHOR; ANCHOR=$LIVE_PARENT
    verdict_for refuse-live-agent "live process descending from the session host" --pid "$LIVE_CHILD"
    ANCHOR=$ANCHOR_SAVE
else
    fail "fixture: could not create a child under LIVE_PARENT"
fi

# 4. Something with live dependents is never killable, however it was flagged.
verdict_for refuse-session-host "process with live children" --pid "$LIVE_PARENT"

# 5. The dolt case: a server the reporter called a zombie that the kernel does
#    not. pid 61677 was stat=Ss, six minutes old, 669MB resident, and in use.
NOTZOMBIE=$(spawn_detached "$TMPCITY"); track "$NOTZOMBIE"
sleep 0.3
verdict_for refuse-not-zombie "non-Z process reported as a zombie" --require-zombie --pid "$NOTZOMBIE"

# 6. A pid that is gone. Never invent a verdict for something unreadable.
verdict_for refuse-unverifiable "process that no longer exists" --pid 999999

echo "== the other direction: a real orphan must still be actionable =="

# 7. Positive control. Ours by working directory, reparented to init, hosting
#    nothing. Without this, "refuse everything" would pass every test above.
ORPHAN=$(spawn_detached "$TMPCITY"); track "$ORPHAN"
sleep 0.5
ORPHAN_PPID=$(ps -o ppid= -p "$ORPHAN" 2>/dev/null | tr -d ' ')
if [ "$ORPHAN_PPID" = "1" ]; then
    verdict_for kill-candidate "genuine orphan of this town" --pid "$ORPHAN"
    GC_CITY="$TMPCITY" GC_TRIAGE_ANCHOR="$ANCHOR" bash "$SCRIPT" --pid "$ORPHAN" >/dev/null 2>&1
    rc=$?
    if [ "$rc" -eq 1 ]; then pass "kill-candidate exits 1"
    else fail "a surviving kill-candidate must exit 1, got $rc"; fi
else
    fail "fixture: orphan did not reparent to init (ppid=$ORPHAN_PPID)"
fi

echo "== an unusable anchor is a refusal, not a clearance =="

# 8. If the town's session host cannot be identified, nothing is attributable,
#    so nothing may be killed. Exit 2 means NOT TRIAGED — the one outcome that
#    must never be read as permission.
GC_CITY=/nonexistent-city bash "$SCRIPT" --pid 1 >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then pass "unresolvable city exits 2 (not triaged)"
else fail "unresolvable city must exit 2, got $rc"; fi

# 9. No pids at all is 0 candidates — not an error, and not a licence.
GC_CITY="$TMPCITY" GC_TRIAGE_ANCHOR="$ANCHOR" bash "$SCRIPT" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ]; then pass "no pids exits 0 (nothing to kill)"
else fail "no pids must exit 0, got $rc"; fi

if [ "$FAILURES" -gt 0 ]; then
    echo "$FAILURES kill-triage test(s) failed." >&2
    exit 1
fi
echo "All kill-triage tests passed."
