#!/usr/bin/env bash
set -euo pipefail

# mol-digest-generate must anchor its window to the wisp's pour time, never to
# the clock at execution time. A wisp poured 2026-07-28T06:34Z was once picked
# up ~38h late and produced the 07-28 window instead of 07-27: 07-27 was never
# digested, and the next wisp recomputed 07-28 and would have duplicated it.
# Both runs "succeeded" — the only evidence was a missing ledger title.
#
# These tests execute the formula's own bash, extracted from the TOML, so they
# gate the shipped step text rather than a copy of it. `gc` is stubbed, so the
# suite is hermetic and needs no city.
#
# The gap-detection tests additionally vary the INTERPRETER. Agents paste these
# snippets into whatever shell their session runs, and gp-74p was a comparison
# that worked in bash, sh and dash while silently reporting the opposite answer
# in zsh -- so a suite that fixes the shell to bash cannot see it. Anything
# touching the ledger comparison must be asserted across $GAP_SHELLS, not
# against one interpreter.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GASTOWN="$ROOT/gastown"
FORMULA="$GASTOWN/formulas/mol-digest-generate.toml"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# A stub city root: the formula asserts city.toml exists before it will query.
mkdir -p "$WORK/city"
touch "$WORK/city/city.toml"

# Stub `gc` on PATH. `gc bd show` returns $STUB_POUR as created_at; `gc bd list`
# returns $STUB_LEDGER as the raw digest JSON. Every mutating subcommand is
# recorded to $STUB_LOG instead of run, so the tests can assert that the
# duplicate path mails nothing. The log keeps the `gc` prefix so assertions
# match the command line the formula actually invoked.
mkdir -p "$WORK/bin"
cat >"$WORK/bin/gc" <<'STUB'
#!/usr/bin/env bash
# Dispatch on verb:subcommand. The ':' join is deliberate -- the repo's
# bare-bd guard scans file text, so a space-joined dispatch label would read as
# an unrouted beads invocation even though this is the stub for `gc` itself.
case "$1:${2:-}" in
  bd:show)
    if [ "${STUB_POUR_MISSING:-0}" = "1" ]; then echo '[{}]'; else
      printf '[{"created_at":"%s"}]\n' "$STUB_POUR"
    fi ;;
  bd:list)
    if [ "${STUB_LEDGER_FAILS:-0}" = "1" ]; then
      echo "stub: ledger query exploded" >&2; exit 7
    fi
    printf '%s\n' "${STUB_LEDGER:-[]}" ;;
  *) echo "MUTATE: gc $*" >>"$STUB_LOG" ;;
esac
STUB
chmod +x "$WORK/bin/gc"

# Extract the bash from determine-period + check-digest-ledger, in order, and
# substitute the formula vars the way the runtime does.
extract_steps() {
    local period="$1" period_date="$2" out="$3"
    python3 - "$FORMULA" "$period" "$period_date" "$out" <<'PY'
import re, sys, tomllib

path, period, period_date, out = sys.argv[1:5]
with open(path, "rb") as fh:
    doc = tomllib.load(fh)
steps = {s["id"]: s["description"] for s in doc["steps"]}
body = []
for sid in ("determine-period", "check-digest-ledger"):
    if sid not in steps:
        raise SystemExit(f"formula is missing the {sid} step")
    body += re.findall(r"```bash\n(.*?)```", steps[sid], re.S)
text = "\n".join(body).replace("{{period}}", period).replace("{{period_date}}", period_date)
if "{{" in text:
    raise SystemExit(f"unsubstituted template vars: {re.findall(r'{{.*?}}', text)}")
with open(out, "w") as fh:
    fh.write(text + '\necho "WINDOW since=$SINCE until=$UNTIL date=$DATE"\n')
PY
}

# Run the extracted steps. Echoes the step output; returns their exit status.
# $3 selects the interpreter: the step text is POSIX shell, and which shell runs
# it is itself under test (see the gap-comparison tests). Defaults to bash so
# the window tests above keep exercising one fixed, known-good interpreter.
run_steps() {
    local period="${1:-daily}" period_date="${2:-}" shell="${3:-bash}"
    rm -f "$WORK/steps.sh"
    extract_steps "$period" "$period_date" "$WORK/steps.sh" ||
        fail "could not extract the formula's bash (period=$period)"
    [[ -s "$WORK/steps.sh" ]] ||
        fail "extraction produced no bash for period=$period"
    : >"$STUB_LOG"
    mkdir -p "$WORK/run"
    set +e
    # Run from a scratch cwd. A comparison that is secretly a REDIRECTION writes
    # a file instead of answering, and that evidence is only observable if we
    # know what the working directory held beforehand.
    ( cd "$WORK/run" &&
      PATH="$WORK/bin:$PATH" GC_CITY="$WORK/city" GC_BEAD_ID="gk-stub" \
        STUB_POUR="$STUB_POUR" STUB_LEDGER="$STUB_LEDGER" STUB_LOG="$STUB_LOG" \
        STUB_POUR_MISSING="${STUB_POUR_MISSING:-0}" \
        STUB_LEDGER_FAILS="${STUB_LEDGER_FAILS:-0}" \
        "$shell" "$WORK/steps.sh" 2>&1 )
    local code=$?
    set -e
    return $code
}

# The shells the gap comparison must survive.
#
# zsh is REQUIRED, never skipped. gp-74p reproduces ONLY under zsh -- bash, sh
# and dash all answered that one correctly -- so a suite that quietly omits zsh
# passes on the broken formula, which is precisely how the defect shipped and
# survived. A missing zsh is a failure of this suite, not a reason to run less
# of it.
#
# dash is optional because it is not standard on macOS, but include it wherever
# it exists: it is the strictest POSIX interpreter available and the only one
# that rules out `[[ ]]` as the fix here.
#
# Resolved ONCE, at top level, into GAP_SHELLS -- deliberately not a function
# the tests call inside `for shell in $(...)`. `fail` runs `exit 1`, and inside
# a command substitution that only kills the substitution subshell: the caller
# would carry on with an empty list, iterate zero times, assert nothing, and
# report success. A guard whose failure path silently reduces coverage is the
# same shape of defect as the one this file is testing for.
GAP_SHELLS=""
for _s in bash sh zsh dash; do
    command -v "$_s" >/dev/null 2>&1 && GAP_SHELLS="$GAP_SHELLS $_s"
done
GAP_SHELLS="${GAP_SHELLS# }"
unset _s

case " $GAP_SHELLS " in
    *" zsh "*) ;;
    *) fail "zsh is not installed.
      The gap-detection regression (gp-74p) reproduces ONLY under zsh; bash, sh
      and dash all report it correctly. Running this suite without zsh would go
      green against the broken formula, so it fails instead of skipping.
      Install zsh to run these tests." ;;
esac

STUB_LOG="$WORK/mutations.log"
: >"$STUB_LOG"

# The ledger as it stood during the incident, minus the day that was skipped.
LEDGER_THROUGH_26='[{"title":"Digest: 2026-07-24","id":"gk-j42"},
                    {"title":"Digest: 2026-07-25","id":"gk-k0a"},
                    {"title":"Digest: 2026-07-26","id":"gk-cc5"}]'

test_window_follows_the_pour_not_the_pickup() {
    # The regression: poured 07-28, executed late. The window must be 07-27 --
    # the day the cooldown was asking for -- whenever the dog gets to it.
    STUB_POUR="2026-07-28T06:34:19Z"
    STUB_LEDGER="$LEDGER_THROUGH_26"
    local out
    out=$(run_steps daily "") || fail "determine-period halted unexpectedly: $out"
    grep -F 'WINDOW since=2026-07-27T00:00:00Z until=2026-07-28T00:00:00Z date=2026-07-27' \
        <<<"$out" >/dev/null ||
        fail "late pickup must still yield the poured day's window, got: $out"
    # And it must not have been computed from today's date.
    local today_minus_1
    today_minus_1=$(date -u -d 'yesterday' +%Y-%m-%d 2>/dev/null ||
                    date -u -j -v-1d +%Y-%m-%d)
    if [[ "$today_minus_1" != "2026-07-27" ]]; then
        ! grep -F "date=$today_minus_1" <<<"$out" >/dev/null ||
            fail "window tracked wall-clock ($today_minus_1) instead of the pour date"
    fi
}

test_consecutive_pours_cover_consecutive_days() {
    # The other half of the fault: two wisps poured a day apart must never
    # resolve to the same period, however close together they execute.
    STUB_LEDGER="$LEDGER_THROUGH_26"
    local a b
    STUB_POUR="2026-07-28T06:34:19Z"; a=$(run_steps daily "" | grep -F WINDOW)
    STUB_POUR="2026-07-29T20:55:41Z"; b=$(run_steps daily "" | grep -F WINDOW)
    [[ "$a" != "$b" ]] || fail "wisps poured a day apart produced the same window: $a"
    grep -F 'date=2026-07-27' <<<"$a" >/dev/null || fail "07-28 pour should cover 07-27: $a"
    grep -F 'date=2026-07-28' <<<"$b" >/dev/null || fail "07-29 pour should cover 07-28: $b"
}

test_month_and_leap_boundaries() {
    STUB_LEDGER='[]'
    local out
    STUB_POUR="2026-03-01T06:30:00Z"; out=$(run_steps daily "")
    grep -F 'date=2026-02-28' <<<"$out" >/dev/null || fail "month boundary wrong: $out"
    STUB_POUR="2024-03-01T06:30:00Z"; out=$(run_steps daily "")
    grep -F 'date=2024-02-29' <<<"$out" >/dev/null || fail "leap day wrong: $out"
    STUB_POUR="2026-01-01T06:30:00Z"; out=$(run_steps daily "")
    grep -F 'date=2025-12-31' <<<"$out" >/dev/null || fail "year boundary wrong: $out"
}

test_weekly_anchors_to_the_pour_week() {
    STUB_POUR="2026-07-29T06:30:00Z"   # a Wednesday
    STUB_LEDGER='[]'
    local out
    out=$(run_steps weekly "")
    grep -F 'since=2026-07-20T00:00:00Z until=2026-07-27T00:00:00Z' <<<"$out" >/dev/null ||
        fail "weekly window should be the last complete Mon..Mon week, got: $out"
}

test_duplicate_period_closes_without_mailing() {
    # Guard 1: a period already on the ledger must not be regenerated. Each
    # duplicate costs a mail bead plus Dolt commits.
    STUB_POUR="2026-07-27T06:33:55Z"    # would cover 07-26, already present
    STUB_LEDGER="$LEDGER_THROUGH_26"
    local out
    out=$(run_steps daily "") || fail "duplicate path should exit 0, got: $out"
    grep -F 'ALREADY_DIGESTED 2026-07-26 by gk-cc5' <<<"$out" >/dev/null ||
        fail "existing digest not detected: $out"
    ! grep -F 'mail send' "$STUB_LOG" >/dev/null ||
        fail "duplicate path mailed the mayor: $(cat "$STUB_LOG")"
    ! grep -F 'gc bd create' "$STUB_LOG" >/dev/null ||
        fail "duplicate path archived a second digest bead: $(cat "$STUB_LOG")"
    grep -F 'gc bd close' "$STUB_LOG" >/dev/null ||
        fail "duplicate path should close the wisp: $(cat "$STUB_LOG")"
}

test_ledger_match_is_exact_not_by_label() {
    # A bug report *about* the digest carries the digest label and must never
    # be mistaken for a digest, or a real run gets skipped as a duplicate.
    STUB_POUR="2026-07-28T06:34:19Z"    # covers 07-27
    STUB_LEDGER='[{"title":"mol-digest-generate skips a day","id":"gp-gqz"},
                  {"title":"Digest: 2026-07-27 (backfill)","id":"gk-bad"}]'
    local out
    out=$(run_steps daily "") || fail "step halted: $out"
    ! grep -F 'ALREADY_DIGESTED' <<<"$out" >/dev/null ||
        fail "a non-digest title was accepted as a digest: $out"
    grep -F 'date=2026-07-27' <<<"$out" >/dev/null || fail "window wrong: $out"
}

test_gap_is_reported_and_not_backfilled() {
    # Guard 2: a hole in the ledger must surface on the next run rather than
    # never -- but a wisp must not fan out digests for every missing day.
    STUB_POUR="2026-08-03T06:30:00Z"    # covers 08-02; newest on record is 07-26
    STUB_LEDGER="$LEDGER_THROUGH_26"
    local out
    out=$(run_steps daily "") || fail "gap path should not halt: $out"
    grep -E '^GAP ' <<<"$out" >/dev/null || fail "gap not reported: $out"
    grep -F '2026-07-27' <<<"$out" >/dev/null ||
        fail "gap should name the first missing period: $out"
    ! grep -F 'mail send' "$STUB_LOG" >/dev/null ||
        fail "gap detection must not mail a backfill run: $(cat "$STUB_LOG")"
}

test_contiguous_window_reports_no_gap() {
    STUB_POUR="2026-07-28T06:34:19Z"    # covers 07-27, right after 07-26
    STUB_LEDGER="$LEDGER_THROUGH_26"
    local out
    out=$(run_steps daily "")
    ! grep -E '^GAP ' <<<"$out" >/dev/null ||
        fail "contiguous window should not report a gap: $out"
}

test_empty_ledger_is_reported_not_asserted() {
    # An empty result is what every mis-scoped query returns, so the step may
    # report the count but must never conclude "first ever digest run".
    STUB_POUR="2026-07-28T06:34:19Z"
    STUB_LEDGER='[]'
    local out
    out=$(run_steps daily "") || fail "empty ledger should not halt: $out"
    grep -F 'digest ledger: 0 entries' <<<"$out" >/dev/null ||
        fail "empty ledger should be reported as a count, got: $out"
    ! grep -Ei 'first (ever )?digest' <<<"$out" >/dev/null ||
        fail "step asserted a first-run conclusion from an empty query"
}

test_unreadable_pour_time_halts() {
    # Fail closed. Falling back to wall-clock is the defect itself.
    STUB_LEDGER='[]'
    local out code
    STUB_POUR_MISSING=1
    set +e; out=$(run_steps daily ""); code=$?; set -e
    STUB_POUR_MISSING=0
    [[ $code -ne 0 ]] || fail "missing created_at must halt, exited 0: $out"
    grep -F 'HALT' <<<"$out" >/dev/null || fail "expected a HALT message, got: $out"

    STUB_POUR="not-a-timestamp"
    set +e; out=$(run_steps daily ""); code=$?; set -e
    [[ $code -ne 0 ]] || fail "garbage created_at must halt, exited 0: $out"
}

test_ledger_query_failure_halts() {
    # A failed query must never be read as "no digests exist".
    STUB_POUR="2026-07-28T06:34:19Z"
    STUB_LEDGER='[]'
    STUB_LEDGER_FAILS=1
    local out code
    set +e; out=$(run_steps daily ""); code=$?; set -e
    STUB_LEDGER_FAILS=0
    [[ $code -ne 0 ]] || fail "failed ledger query must halt, exited 0: $out"
    grep -F 'HALT' <<<"$out" >/dev/null || fail "expected a HALT message, got: $out"
}

test_explicit_period_date_allows_deliberate_backfill() {
    STUB_POUR="2026-08-03T06:30:00Z"
    STUB_LEDGER="$LEDGER_THROUGH_26"
    local out
    out=$(run_steps daily "2026-07-27")
    grep -F 'since=2026-07-27T00:00:00Z until=2026-07-28T00:00:00Z date=2026-07-27' \
        <<<"$out" >/dev/null || fail "period_date override ignored: $out"
}

test_ledger_query_is_city_scoped_and_includes_closed() {
    # Static contract check on the *commands* (prose is allowed to discuss the
    # wrong flags): these are the three whose absence yields a silently empty
    # ledger. `--status=all` is not a valid status value and is ignored.
    local cmds
    cmds=$(python3 - "$FORMULA" <<'PY'
import re, sys, tomllib
with open(sys.argv[1], "rb") as fh:
    doc = tomllib.load(fh)
step = [s for s in doc["steps"] if s["id"] == "check-digest-ledger"][0]
print("\n".join(re.findall(r"```bash\n(.*?)```", step["description"], re.S)))
PY
)
    grep -F 'gc bd list -C "$GC_CITY"' <<<"$cmds" >/dev/null ||
        fail "digest ledger query must be explicitly city-scoped"
    grep -F -- '--all' <<<"$cmds" >/dev/null ||
        fail "digest ledger query must include closed beads"
    ! grep -F -- '--status=all' <<<"$cmds" >/dev/null ||
        fail "--status=all is silently ignored; use --all"
}

test_bead_mutations_are_city_scoped() {
    # The wisp and the digest bead both live in the city ledger. An unscoped
    # `gc bd` mutation resolves against whichever ledger the dog's cwd lands
    # in, and a bare id is fuzzy-matched -- so an unscoped close can close an
    # unrelated bead rather than the wisp. Reads are deliberately not checked
    # here: collect-data's cross-rig queries are a separate defect (gk-5xj).
    local offenders
    offenders=$(python3 - "$FORMULA" <<'PY'
import re, sys, tomllib
with open(sys.argv[1], "rb") as fh:
    doc = tomllib.load(fh)
bad = []
for step in doc["steps"]:
    for block in re.findall(r"```bash\n(.*?)```", step["description"], re.S):
        for line in block.splitlines():
            stripped = line.strip()
            if re.match(r"^gc bd (close|create)\b", stripped) and '-C "$GC_CITY"' not in stripped:
                bad.append(f'{step["id"]}: {stripped}')
print("\n".join(bad))
PY
)
    [[ -z "$offenders" ]] ||
        fail "gc bd mutations must be city-scoped:"$'\n'"$offenders"
}

test_wisp_is_closed_by_id_not_placeholder() {
    # `gc bd close <work-bead>` invites a guessed id, which bd fuzzy-matches.
    local cmds
    cmds=$(python3 - "$FORMULA" <<'PY'
import re, sys, tomllib
with open(sys.argv[1], "rb") as fh:
    doc = tomllib.load(fh)
print("\n".join(
    b for s in doc["steps"]
    for b in re.findall(r"```bash\n(.*?)```", s["description"], re.S)))
PY
)
    ! grep -E '^gc bd close <' <<<"$cmds" >/dev/null ||
        fail "the wisp must be closed by \$GC_BEAD_ID, not a placeholder"
}

test_gap_detection_survives_every_shell() {
    # gp-74p. The shipped comparison was an escaped greater-than inside `[ ]`.
    # zsh's `[` builtin has no such operator: it raised "condition expected" on
    # stderr, took the else path, and reported no gap for a genuine six-day hole.
    # A confident wrong answer, not an error -- the step carried on and the
    # digest header simply omitted the gap block.
    #
    # Every other shell answers this correctly, which is why the bash-only
    # test_gap_is_reported_and_not_backfilled above stayed green for the entire
    # life of the bug. The shell is the variable under test here.
    STUB_POUR="2026-08-03T06:30:00Z"    # covers 08-02; newest on record is 07-26
    STUB_LEDGER="$LEDGER_THROUGH_26"
    local shell out
    for shell in $GAP_SHELLS; do
        out=$(run_steps daily "" "$shell") ||
            fail "[$shell] gap path should not halt: $out"
        grep -E '^GAP ' <<<"$out" >/dev/null ||
            fail "[$shell] a real six-day gap reported no gap; the comparison is inert under this shell: $out"
        grep -F '2026-07-27' <<<"$out" >/dev/null ||
            fail "[$shell] gap should name the first missing period: $out"
    done
}

test_contiguous_reports_no_gap_in_every_shell() {
    # The mirror image, and the guard against "fixing" the test above by simply
    # dropping the backslash. Unescaped, zsh parses the operator as a REDIRECTION:
    # the condition degrades to a non-empty-string check that is always true, so
    # every window -- contiguous or not -- reports a gap. That form passes the
    # test above while being just as wrong.
    STUB_POUR="2026-07-28T06:34:19Z"    # covers 07-27, right after 07-26
    STUB_LEDGER="$LEDGER_THROUGH_26"
    local shell out
    for shell in $GAP_SHELLS; do
        out=$(run_steps daily "" "$shell")
        ! grep -E '^GAP ' <<<"$out" >/dev/null ||
            fail "[$shell] contiguous window reported a gap; the comparison is always-true under this shell: $out"
    done
}

test_gap_comparison_never_redirects() {
    # The other half of the redirection trap. As well as answering wrongly, the
    # unescaped form writes the step's stdout into a file named after $EXPECTED,
    # littering one file per run into whatever directory the dog was sitting in.
    # Behavioural check: run in a pristine cwd, require it to stay pristine.
    STUB_POUR="2026-08-03T06:30:00Z"
    STUB_LEDGER="$LEDGER_THROUGH_26"
    local shell strays
    for shell in $GAP_SHELLS; do
        rm -rf "$WORK/run"; mkdir -p "$WORK/run"
        run_steps daily "" "$shell" >/dev/null
        strays=$(ls -1A "$WORK/run")
        [[ -z "$strays" ]] ||
            fail "[$shell] the gap step created file(s) rather than comparing; the operator is being parsed as a redirection: $strays"
    done
}

test_gap_comparison_is_not_an_inequality_test() {
    # Static backstop for the three tests above, so the contract still holds on a
    # host that lacks a shell to demonstrate it with.
    #
    # `[ ]` has no portable greater-than: zsh rejects the escaped and the quoted
    # spellings outright and silently redirects the bare one. `[[ ]]` fixes zsh
    # but is not POSIX and answers wrongly under dash. Compare ISO-8601 dates by
    # sort order instead -- they sort lexically == chronologically.
    local offenders
    offenders=$(python3 - "$FORMULA" <<'PY'
import re, sys, tomllib
with open(sys.argv[1], "rb") as fh:
    doc = tomllib.load(fh)
step = [s for s in doc["steps"] if s["id"] == "check-digest-ledger"][0]
bad = []
for block in re.findall(r"```bash\n(.*?)```", step["description"], re.S):
    for line in block.splitlines():
        stripped = line.strip()
        if stripped.startswith("#") or "$EXPECTED" not in stripped:
            continue
        if stripped.startswith("EXPECTED="):   # the assignment, not a comparison
            continue
        probe = stripped.replace(">&2", "")    # the stderr redirect is legitimate
        if "[[" in stripped or ">" in probe:
            bad.append(stripped)
print("\n".join(bad))
PY
)
    [[ -z "$offenders" ]] ||
        fail "gap comparison must not test \$EXPECTED with an inequality operator:"$'\n'"$offenders"
}

test_formula_no_longer_derives_the_window_from_wall_clock() {
    local body
    body=$(python3 - "$FORMULA" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as fh:
    doc = tomllib.load(fh)
print("\n".join(s["description"] for s in doc["steps"]))
PY
)
    ! grep -F "date -u -d 'yesterday" <<<"$body" >/dev/null ||
        fail "window must not be derived from 'yesterday' at execution time"
    ! grep -F "date -u -d 'today 00:00'" <<<"$body" >/dev/null ||
        fail "window must not be derived from 'today' at execution time"
    grep -F 'created_at' <<<"$body" >/dev/null ||
        fail "window must be derived from the wisp's created_at"
}

test_window_follows_the_pour_not_the_pickup
test_consecutive_pours_cover_consecutive_days
test_month_and_leap_boundaries
test_weekly_anchors_to_the_pour_week
test_duplicate_period_closes_without_mailing
test_ledger_match_is_exact_not_by_label
test_gap_is_reported_and_not_backfilled
test_contiguous_window_reports_no_gap
test_gap_detection_survives_every_shell
test_contiguous_reports_no_gap_in_every_shell
test_gap_comparison_never_redirects
test_gap_comparison_is_not_an_inequality_test
test_empty_ledger_is_reported_not_asserted
test_unreadable_pour_time_halts
test_ledger_query_failure_halts
test_explicit_period_date_allows_deliberate_backfill
test_ledger_query_is_city_scoped_and_includes_closed
test_bead_mutations_are_city_scoped
test_wisp_is_closed_by_id_not_placeholder
test_formula_no_longer_derives_the_window_from_wall_clock

echo "digest window tests passed"
