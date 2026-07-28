#!/usr/bin/env bash
# Tests for assets/scripts/wisp-reconcile.sh.
#
# The defect this script replaced was invisible precisely because nothing
# exercised it: the reconcile query returned empty, the agent concluded "no
# wisp exists", and poured a duplicate. A test suite that only asserts "exit 0"
# would have passed against the broken version. So every case here asserts what
# the script DID — which query flags it sent, whether it poured, what it burned
# — not merely that it succeeded.

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT/gastown/assets/scripts/wisp-reconcile.sh"

PASS=0
FAIL=0

fail() {
    echo "FAIL: $CASE: $*" >&2
    FAIL=$((FAIL + 1))
}

ok() {
    PASS=$((PASS + 1))
}

# new_stub <dir> — install a fake `gc` that serves wisp listings from files and
# records every mutating call. $STATE/open and $STATE/in_progress hold the ids
# each query returns (one per line, empty file = empty ledger).
new_stub() {
    local dir="$1"
    mkdir -p "$dir/bin" "$dir/state" "$dir/log"
    : >"$dir/state/open"
    : >"$dir/state/in_progress"
    : >"$dir/log/queries"
    : >"$dir/log/burns"
    : >"$dir/log/pours"
    : >"$dir/log/assigns"

    cat >"$dir/bin/gc" <<'SH'
#!/usr/bin/env bash
# Fake gc. STUB_DIR is injected by the test.
state="$STUB_DIR/state"
log="$STUB_DIR/log"

if [ "${1:-}" = "bd" ] && [ "${2:-}" = "list" ]; then
    printf '%s\n' "$*" >>"$log/queries"
    status=''
    for a in "$@"; do
        case "$a" in --status=*) status="${a#--status=}" ;; esac
    done
    if [ -n "${GC_STUB_LIST_FAILS:-}" ]; then exit 1; fi
    if [ -n "${GC_STUB_LIST_BLANK:-}" ]; then printf ''; exit 0; fi
    # Emit a JSON array of {id} from the newline-separated id file.
    printf '['
    first=1
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        [ "$first" = 1 ] || printf ','
        printf '{"id":"%s"}' "$id"
        first=0
    done <"$state/$status"
    printf ']'
    exit 0
fi

if [ "${1:-}" = "bd" ] && [ "${2:-}" = "mol" ] && [ "${3:-}" = "burn" ]; then
    printf '%s\n' "$4" >>"$log/burns"
    exit 0
fi

if [ "${1:-}" = "bd" ] && [ "${2:-}" = "mol" ] && [ "${3:-}" = "wisp" ]; then
    printf '%s\n' "$*" >>"$log/pours"
    if [ -n "${GC_STUB_POUR_FAILS:-}" ]; then echo "pour exploded" >&2; exit 1; fi
    # Real gc writes progress chatter to stderr. Folding it into stdout is the
    # bug this guards: the payload must stay parseable regardless.
    echo "note: pouring wisp..." >&2
    printf '{"new_epic_id":"%s"}' "${GC_STUB_NEW_ID:-new-wisp-1}"
    exit 0
fi

if [ "${1:-}" = "bd" ] && [ "${2:-}" = "update" ]; then
    printf '%s\n' "$*" >>"$log/assigns"
    if [ -n "${GC_STUB_ASSIGN_FAILS:-}" ]; then exit 1; fi
    exit 0
fi

echo "unexpected gc call: $*" >&2
exit 99
SH
    chmod +x "$dir/bin/gc"
}

# run_wr <dir> <args...> — run wisp-reconcile against the stub. Captures stdout
# in $OUT and the exit code in $RC (never aborts the suite).
run_wr() {
    local dir="$1"
    shift
    set +e
    OUT=$(STUB_DIR="$dir" PATH="$dir/bin:$PATH" GC_AGENT="${GC_AGENT_OVERRIDE:-rig/gastown.witness}" \
        "$SCRIPT" "$@" 2>"$dir/log/stderr")
    RC=$?
    set -e
}

count_lines() { [ -s "$1" ] && wc -l <"$1" | tr -d ' ' || echo 0; }

# --- the live leak: three open wisps must reconcile to one ------------------
CASE="startup reconciles a 3-wisp leak to exactly one"
D=$(mktemp -d); new_stub "$D"
printf 'gp-wisp-mtm\ngp-wisp-yww\ngp-wisp-8vo\n' >"$D/state/open"
run_wr "$D" startup
[ "$RC" = 0 ] || fail "exit $RC"
[ "$OUT" = "gp-wisp-mtm" ] || fail "kept '$OUT', want gp-wisp-mtm"
[ "$(count_lines "$D/log/burns")" = 2 ] || fail "burned $(count_lines "$D/log/burns"), want 2"
grep -q 'gp-wisp-yww' "$D/log/burns" && grep -q 'gp-wisp-8vo' "$D/log/burns" || fail "wrong ids burned"
ok

# --- the query itself: the two flags whose absence caused the leak ----------
CASE="every listing query carries --type=molecule and --include-infra"
while IFS= read -r q; do
    case "$q" in *"--type=molecule"*) ;; *) fail "query missing --type=molecule: $q" ;; esac
    case "$q" in *"--include-infra"*) ;; *) fail "query missing --include-infra: $q" ;; esac
    case "$q" in *"--type=wisp"*) fail "query used the invalid --type=wisp: $q" ;; esac
done <"$D/log/queries"
ok

CASE="startup prefers an in_progress wisp over a queued one"
D=$(mktemp -d); new_stub "$D"
printf 'gp-wisp-run\n' >"$D/state/in_progress"
printf 'gp-wisp-queued\n' >"$D/state/open"
run_wr "$D" startup
[ "$OUT" = "gp-wisp-run" ] || fail "kept '$OUT', want the in_progress wisp"
grep -q 'gp-wisp-queued' "$D/log/burns" || fail "surplus queued wisp not burned"
ok

# --- the guard: ensure must NOT pour when a wisp is already queued ----------
CASE="ensure reuses a queued wisp instead of pouring a duplicate"
D=$(mktemp -d); new_stub "$D"
printf 'gp-wisp-next\n' >"$D/state/open"
run_wr "$D" ensure mol-witness-patrol
[ "$RC" = 0 ] || fail "exit $RC"
[ "$OUT" = "gp-wisp-next" ] || fail "returned '$OUT', want gp-wisp-next"
[ "$(count_lines "$D/log/pours")" = 0 ] || fail "poured a duplicate despite a queued wisp"
ok

# --- the pour path, exercised for real -------------------------------------
CASE="ensure pours and assigns when nothing is queued"
D=$(mktemp -d); new_stub "$D"
GC_STUB_NEW_ID=gp-wisp-fresh run_wr "$D" ensure mol-witness-patrol --var binding_prefix=gastown.
[ "$RC" = 0 ] || fail "exit $RC ($(cat "$D/log/stderr"))"
[ "$OUT" = "gp-wisp-fresh" ] || fail "returned '$OUT', want gp-wisp-fresh"
[ "$(count_lines "$D/log/pours")" = 1 ] || fail "expected exactly one pour"
grep -q -- '--var binding_prefix=gastown.' "$D/log/pours" || fail "pour args not passed through"
grep -q 'gp-wisp-fresh' "$D/log/assigns" || fail "poured wisp was never assigned"
ok

CASE="pour survives stderr chatter on the same command"
# The stub always writes to stderr during a pour; a 2>&1 capture would corrupt
# the JSON and lose the id. Reaching here with the right id proves separation.
[ "$OUT" = "gp-wisp-fresh" ] || fail "stderr corrupted the pour payload"
ok

# --- the self-selection trap ------------------------------------------------
CASE="ensure never offers the wisp this session is running as 'next'"
D=$(mktemp -d); new_stub "$D"
printf 'gp-wisp-self\n' >"$D/state/open"   # current wisp, still 'open'
GC_BEAD_ID=gp-wisp-self GC_STUB_NEW_ID=gp-wisp-successor \
    STUB_DIR="$D" PATH="$D/bin:$PATH" GC_AGENT="rig/gastown.witness" \
    bash -c 'set +e; "$0" ensure mol-witness-patrol >"$1/out" 2>"$1/log/stderr"; echo $? >"$1/rc"' \
    "$SCRIPT" "$D"
OUT=$(cat "$D/out"); RC=$(cat "$D/rc")
[ "$RC" = 0 ] || fail "exit $RC ($(cat "$D/log/stderr"))"
[ "$OUT" != "gp-wisp-self" ] || fail "returned the current wisp as next — the loop would burn itself to zero"
[ "$OUT" = "gp-wisp-successor" ] || fail "returned '$OUT', want a freshly poured successor"
grep -q 'gp-wisp-self' "$D/log/burns" && fail "burned the wisp it is still running" || true
ok

CASE="--except overrides the current-wisp exclusion"
D=$(mktemp -d); new_stub "$D"
printf 'gp-wisp-a\n' >"$D/state/open"
run_wr "$D" queued --except gp-wisp-a
[ "$RC" = 0 ] || fail "exit $RC ($(cat "$D/log/stderr"))"
[ -z "$OUT" ] || fail "returned '$OUT', want empty (the only candidate was excluded)"
ok

CASE="--except with a missing value is rejected, not silently ignored"
D=$(mktemp -d); new_stub "$D"
run_wr "$D" queued --except
[ "$RC" = 2 ] || fail "exit $RC, want 2"
ok

# --- fail-closed contract ---------------------------------------------------
CASE="a failed query exits 2 and pours nothing"
D=$(mktemp -d); new_stub "$D"
GC_STUB_LIST_FAILS=1 run_wr "$D" ensure mol-witness-patrol
[ "$RC" = 2 ] || fail "exit $RC, want 2"
[ "$(count_lines "$D/log/pours")" = 0 ] || fail "poured despite a failed query"
ok

CASE="a query that exits 0 but prints nothing exits 2 and pours nothing"
# jq exits 0 on empty input, so this is the case that reads as 'no wisps' and
# pours a duplicate unless the script checks for a blank body explicitly.
D=$(mktemp -d); new_stub "$D"
GC_STUB_LIST_BLANK=1 run_wr "$D" ensure mol-witness-patrol
[ "$RC" = 2 ] || fail "exit $RC, want 2"
[ "$(count_lines "$D/log/pours")" = 0 ] || fail "poured on a blank query result"
ok

CASE="a wisp that cannot be assigned is burned, not leaked"
D=$(mktemp -d); new_stub "$D"
GC_STUB_ASSIGN_FAILS=1 GC_STUB_NEW_ID=gp-wisp-orphan run_wr "$D" ensure mol-witness-patrol
[ "$RC" = 1 ] || fail "exit $RC, want 1"
grep -q 'gp-wisp-orphan' "$D/log/burns" || fail "orphan wisp left unassigned and unburned"
ok

CASE="a failed pour exits 1 so the caller keeps its current wisp"
D=$(mktemp -d); new_stub "$D"
GC_STUB_POUR_FAILS=1 run_wr "$D" ensure mol-witness-patrol
[ "$RC" = 1 ] || fail "exit $RC, want 1"
ok

CASE="missing GC_AGENT exits 2"
D=$(mktemp -d); new_stub "$D"
set +e
OUT=$(STUB_DIR="$D" PATH="$D/bin:$PATH" GC_AGENT="" "$SCRIPT" startup 2>/dev/null)
RC=$?
set -e
[ "$RC" = 2 ] || fail "exit $RC, want 2"
ok

CASE="an unknown verb exits 2"
D=$(mktemp -d); new_stub "$D"
run_wr "$D" frobnicate
[ "$RC" = 2 ] || fail "exit $RC, want 2"
ok

echo "wisp-reconcile: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
