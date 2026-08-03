#!/usr/bin/env bash
# Guards the refinery's most consequential reading: "is the merge queue empty?"
#
# The bug this locks down (gp-2uw, escalated from the tallyup refinery as
# ta-giys): every ledger query in mol-refinery-patrol's find-work step was
# spelled `gc bd ... 2>/dev/null | jq ...`. That spelling destroys BOTH channels
# that could report a failure, and it needs both to be destroyed to hide:
#
#   1. `2>/dev/null` discards the line that says WHICH failure happened.
#   2. The pipe discards the verdict. In `gc bd list | jq`, `$?` is JQ's status,
#      never gc's -- so a crashed `gc bd` arrives downstream as a clean success.
#
# What is left is stdout, and on stdout a crashed `gc bd` and a query that
# legitimately matched nothing are BYTE-IDENTICAL: empty. jq then yields
# nothing, the refinery concludes the merge queue is drained, and the turn ends
# as `IDLE: no work, exiting turn.` -- the exact line a healthy idle refinery
# prints, so nothing downstream trips.
#
# The reading was therefore not merely wrong under failure. It was
# UNFALSIFIABLE: no value of stdout distinguished "no work" from "the tool did
# not run". That is the property this file exists to keep dead, and it is why
# the central assertion below is a DIFFERENTIAL one -- the crash and the drained
# queue must not be observationally identical.
#
# How it fired: a ~2min pack-pin install window (7272a9a -> 125f74c) left the
# gastown import unlocked, and every `gc bd` exited 1 before reaching the ledger.
# All four of the refinery's queries returned empty. All four hard failures read
# as clean results. The queue happened to be genuinely empty at the time,
# confirmed on three independent axes -- so the refinery was right BY LUCK, NOT
# BY MEASUREMENT. With a single branch waiting, that same patrol would have
# declared IDLE on a full queue.
#
# All shell under test is EXTRACTED FROM THE FORMULA ITSELF -- never a copy --
# so an assertion cannot keep passing while the formula drifts away from it.
#
# What is nailed down:
#
#   1. A crashed ledger read does NOT end the turn as idle. The find-work
#      selector takes the restart exit instead of falling through with an empty
#      WORK, which is the value the idle path acts on.
#   2. A GENUINELY DRAINED queue still idles. This is the other half and it is
#      not optional: a fix that restarts on every empty result livelocks the
#      refinery into a restart loop and never merges anything. The two cases are
#      asserted against the same extracted block, so neither can be satisfied by
#      breaking the other.
#   3. Crash and drained are DISTINGUISHABLE in what the step emits. This is the
#      falsifiability property stated directly: if these two runs ever become
#      observationally identical again, the defect is back regardless of how the
#      code reads.
#   4. The exit status consulted is gc's, not a pipeline's. gp-2uw calls this
#      the companion trap: `gc bd ... | head` reports exit 0 because `$?` is
#      head's, so a piped spot-check of this very bug comes back green. Any fix
#      that checks `$?` downstream of a pipe is checking the wrong process.
#   5. `2>/dev/null` is gone from the ledger queries, so the failure can still
#      say which failure it was.
#   6. A TRANSIENT failure recovers instead of restarting. The reported instance
#      was a ~2min window, so a read moments later is likely the real answer;
#      restarting on the first blip would trade a silent stall for a noisy one.
#   7. The backoff does not sleep after the FINAL attempt -- that sleep only
#      delays a restart already decided.
#   8. The address-agnostic sweep, which is the LAST thing between a misaddressed
#      handoff and an idle turn, gets the same treatment.
#   9. The awaiting-merge poll and the no-patch triage REPORT an unmeasured pass
#      rather than no-oping silently. Neither ends the turn, so neither restarts
#      -- but a poll that did not happen must not pass for a poll that found
#      nothing parked.
#
# One discipline runs through all of it: every assertion about what a step DOES
# runs against its FENCED CODE BLOCKS or against the OBSERVED BEHAVIOUR of those
# blocks, never against the description. A formula step is prose interleaved
# with shell, and the prose here necessarily discusses `2>/dev/null` and `IDLE:`
# while explaining why they are wrong -- so a description-wide grep is satisfied
# by the documentation of the bug rather than by its absence.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
FORMULA="$ROOT/gastown/formulas/mol-refinery-patrol.toml"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq is required to exercise the ledger queries"

# Emit the single fenced bash block of find-work that contains ANCHOR, with
# {{vars}} rendered from the formula's own defaults. Requiring EXACTLY one match
# is deliberate: if the step is reorganised and an anchor goes missing or turns
# ambiguous, this dies loudly instead of quietly exercising nothing.
extract_step_block() {
    python3 - "$FORMULA" "$1" <<'PY'
import re
import sys
import tomllib

formula, anchor = sys.argv[1], sys.argv[2]
with open(formula, "rb") as handle:
    data = tomllib.load(handle)

step = next(s for s in data["steps"] if s["id"] == "find-work")
blocks = [
    b for b in re.findall(r"```bash\n(.*?)```", step["description"], re.S)
    if anchor in b
]
if len(blocks) != 1:
    sys.exit(
        f"expected exactly 1 find-work bash block containing {anchor!r}, "
        f"found {len(blocks)}"
    )

rendered = blocks[0]
values = {name: spec.get("default", "") for name, spec in data.get("vars", {}).items()}
values.setdefault("rig_name", "testrig")
for name, value in values.items():
    rendered = rendered.replace("{{%s}}" % name, str(value))
sys.stdout.write(rendered)
PY
}

# Every fenced bash block of find-work, joined. Structural assertions run
# against this rather than the description, for the reason in the header.
all_find_work_code() {
    python3 - "$FORMULA" <<'PY'
import re
import sys
import tomllib

with open(sys.argv[1], "rb") as handle:
    data = tomllib.load(handle)
step = next(s for s in data["steps"] if s["id"] == "find-work")
sys.stdout.write("\n".join(re.findall(r"```bash\n(.*?)```", step["description"], re.S)))
PY
}

# Join shell line-continuations so a command written across several lines reads
# as one. Every ledger query here is spelled that way, so anything that greps
# per-line sees only the fragment carrying `gc bd list` and never the tail where
# a redirect would actually sit.
fold_continuations() {
    python3 -c 'import re,sys; sys.stdout.write(re.sub(r"\\\n\s*", " ", open(sys.argv[1]).read()))' "$1"
}

SANDBOX=$(mktemp -d)
BIN="$SANDBOX/bin"
mkdir -p "$BIN"
trap 'rm -rf "$SANDBOX"' EXIT

GC_LOG="$SANDBOX/gc.log"
SLEEP_LOG="$SANDBOX/sleep.log"
STATE="$SANDBOX/state"
mkdir -p "$STATE"
export GC_LOG SLEEP_LOG STATE

# `gc` stub.
#
# Crash behaviour is per-QUERY-KIND, not global, because the blocks run in
# sequence against one stub and a test that could only crash everything at once
# could not show that the sweep is reached after a clean-but-empty selector.
#
# A crash reproduces the production shape exactly: nothing on stdout, a
# diagnostic on stderr, non-zero exit. Emitting nothing on stdout is the whole
# point -- that is what makes it indistinguishable from a drained queue to any
# reader that consults stdout alone.
cat >"$BIN/gc" <<'SH'
#!/usr/bin/env sh
printf '%s\n' "gc $*" >>"$GC_LOG"

case "gc $1 $2" in
    "gc runtime request-restart")
        exit "${GC_RESTART_CODE:-0}"
        ;;
    "gc session nudge")
        exit 0
        ;;
    "gc bd update")
        exit 0
        ;;
    "gc bd show")
        jq --arg id "$3" '[.[] | select(.id == $id)]' "$GC_LEDGER"
        exit 0
        ;;
    "gc bd list")
        # Classify the query by the flags the formula actually passes. The
        # selector and the sweep differ ONLY in whether --assignee is present,
        # which is also the real distinction between them in production.
        kind=other
        has_assignee=0
        for arg in "$@"; do
            case "$arg" in
                --assignee=*) has_assignee=1 ;;
                --metadata-field=awaiting_merge=true) kind=awaiting ;;
                --metadata-field=no_code_change=true) kind=nopatch ;;
            esac
        done
        if [ "$kind" = other ]; then
            for arg in "$@"; do
                case "$arg" in
                    --has-metadata-key=branch)
                        if [ "$has_assignee" -eq 1 ]; then kind=selector; else kind=sweep; fi
                        ;;
                esac
            done
        fi

        # Fail the first N calls of this kind, where N comes from
        # GC_FAIL_<KIND>. Counting per kind is what lets a test fail read 1 and
        # answer read 2, which is the transient-recovery case.
        eval "budget=\${GC_FAIL_$(printf '%s' "$kind" | tr '[:lower:]' '[:upper:]'):-0}"
        seen_file="$STATE/$kind.count"
        seen=$(cat "$seen_file" 2>/dev/null || echo 0)
        seen=$((seen + 1))
        printf '%s' "$seen" >"$seen_file"
        if [ "$seen" -le "$budget" ]; then
            echo "gc: ledger unreachable (simulated $kind failure $seen)" >&2
            exit 1
        fi

        filter='.'
        for arg in "$@"; do
            case "$arg" in
                --assignee=*)
                    who=${arg#--assignee=}
                    filter="$filter | map(select(.assignee == \"$who\"))"
                    ;;
                --metadata-field=awaiting_merge=true)
                    filter="$filter | map(select((.metadata.awaiting_merge // \"\" | tostring) == \"true\"))"
                    ;;
                --metadata-field=no_code_change=true)
                    filter="$filter | map(select((.metadata.no_code_change // \"\" | tostring) == \"true\"))"
                    ;;
                --has-metadata-key=branch)
                    filter="$filter | map(select(.metadata.branch != null))"
                    ;;
                --status=open)
                    filter="$filter | map(select(.status == \"open\"))"
                    ;;
            esac
        done
        jq "$filter" "$GC_LEDGER"
        exit 0
        ;;
esac
exit 0
SH
chmod +x "$BIN/gc"

# `sleep` stub: records the requested backoff and returns instantly, so the
# retry loop's timing is asserted rather than waited out.
cat >"$BIN/sleep" <<'SH'
#!/usr/bin/env sh
printf '%s\n' "$1" >>"$SLEEP_LOG"
exit 0
SH
chmod +x "$BIN/sleep"

# `git` stub for the sweep's ls-remote evidence check. Exit 2 is "origin has no
# such ref", which routes the sweep to leave the bead alone -- the conservative
# branch, and the one that keeps these tests about measurement rather than about
# adoption, which test_refinery_address_agnostic_sweep.sh already owns.
cat >"$BIN/git" <<'SH'
#!/usr/bin/env sh
exit 2
SH
chmod +x "$BIN/git"

export GC_LEDGER="$SANDBOX/ledger.json"
echo '[]' >"$GC_LEDGER"

reset_run() {
    : >"$GC_LOG"
    : >"$SLEEP_LOG"
    rm -f "$STATE"/*.count
    echo "${1:-[]}" >"$GC_LEDGER"
}

extract_step_block 'WORK_JSON_RAW=$(gc bd list' >"$SANDBOX/select.sh"
extract_step_block 'ADDRESS_AGNOSTIC_SWEEP' >"$SANDBOX/sweep.sh"
extract_step_block 'AWAITING_MERGE_RECHECK' >"$SANDBOX/awaiting.sh"
extract_step_block 'NO_PATCH_TRIAGE' >"$SANDBOX/nopatch.sh"
all_find_work_code >"$SANDBOX/code.txt"
CODE="$SANDBOX/code.txt"

# Run one or more extracted blocks in sequence and echo everything the step
# emitted, plus a FELL_THROUGH marker carrying the values the idle path would
# act on. The marker is the load-bearing part: a block that takes the restart
# exit never reaches it, so its ABSENCE is how "this turn did not end as idle"
# is observed, and its presence with an empty WORK is exactly the bug.
run_blocks() {
    (cd "$SANDBOX" && PATH="$BIN:$PATH" GC_AGENT=testrig/gastown.refinery GC_RIG=testrig \
        bash -c '
            for b in "$@"; do . "$b"; done
            printf "FELL_THROUGH WORK=[%s] MEASURED=[%s]\n" "${WORK:-}" "${WORK_MEASURED:-}"
        ' _ "$@") 2>&1
}

ONE_BEAD='[{"id":"gp-999","status":"open","assignee":"testrig/gastown.refinery",
            "metadata":{"branch":"polecat/gp-999","target":"main"}}]'

# ---------------------------------------------------------------------------

test_crashed_ledger_does_not_render_as_idle() {
    # The headline case. Every read fails, so the step has NO answer -- and the
    # value it would otherwise carry forward is an empty WORK, byte-identical to
    # a drained queue. It must take the restart exit instead.
    reset_run "$ONE_BEAD"
    OUT=$(GC_FAIL_SELECTOR=99 run_blocks "$SANDBOX/select.sh")

    if grep -q 'FELL_THROUGH' <<<"$OUT"; then
        fail "an unreadable ledger fell through to the idle path (output: $OUT); UNMEASURED must never reach the value the IDLE line is written on"
    fi
    grep -q 'UNMEASURED' <<<"$OUT" \
        || fail "an unreadable ledger produced no UNMEASURED signal; it is once again indistinguishable from an empty queue (output: $OUT)"
    grep -q 'gc runtime request-restart' "$GC_LOG" \
        || fail "an unreadable ledger did not restart the session; the turn ends with the merge queue unread and nothing to revive it"
}

test_drained_queue_still_idles() {
    # The other half, and the reason the assertion above is not enough on its
    # own: restarting whenever WORK is empty would livelock the refinery and
    # merge nothing. A drained queue must still fall through to the idle path.
    reset_run '[]'
    OUT=$(run_blocks "$SANDBOX/select.sh")

    grep -q 'FELL_THROUGH WORK=\[\] MEASURED=\[true\]' <<<"$OUT" \
        || fail "a genuinely drained queue did not reach the idle path as measured-and-empty (output: $OUT); a fix that restarts on every empty result never merges anything"
    if grep -q 'request-restart' "$GC_LOG"; then
        fail "a drained queue restarted the session; that is a restart loop, not a merge queue"
    fi
}

test_crash_and_drained_are_distinguishable() {
    # The falsifiability property, asserted directly rather than inferred from
    # the code. gp-2uw's core claim is that NO value of stdout separated these
    # two runs. If they ever collapse back into the same observation, the defect
    # has returned no matter how the source reads.
    reset_run '[]'
    DRAINED=$(run_blocks "$SANDBOX/select.sh")
    reset_run '[]'
    CRASHED=$(GC_FAIL_SELECTOR=99 run_blocks "$SANDBOX/select.sh")

    [ "$DRAINED" != "$CRASHED" ] \
        || fail "a crashed ledger and a drained queue are observationally identical again (both: $DRAINED); the queue-empty reading is unfalsifiable"
}

test_status_checked_is_gcs_not_a_pipelines() {
    # The companion trap named in gp-2uw: `gc bd ... | head` reports exit 0
    # because `$?` is head's status, so a piped spot-check of this bug comes
    # back green. Assert structurally that the ledger reads assign first and
    # filter second -- a status captured after a pipeline is the wrong process's.
    grep -q 'WORK_JSON_RAW=\$(gc bd list' "$CODE" \
        || fail "the find-work selector no longer captures the ledger reply before filtering it; if gc bd list feeds jq directly, \$? is jq's and a crash reads as success"
    grep -q 'WORK_CODE=\$?' "$CODE" \
        || fail "the find-work selector does not capture an exit status for the ledger read"

    # And behaviourally: with gc crashing, the step must not conclude anything.
    # A pipeline-based status would have reported success here.
    reset_run '[]'
    OUT=$(GC_FAIL_SELECTOR=99 run_blocks "$SANDBOX/select.sh")
    grep -q 'MEASURED=\[true\]' <<<"$OUT" \
        && fail "a crashed read was recorded as measured; the status being consulted belongs to some other process (output: $OUT)"
    return 0
}

test_ledger_reads_keep_their_stderr() {
    # `2>/dev/null` on a ledger query is the half of the defect that erases WHY.
    # The blocks route stderr to a file they then report; none may discard it.
    #
    # Fold continuations FIRST. Every one of these queries spans two lines, and
    # the redirect goes at the END of the command -- on the continuation line,
    # which does not contain `gc bd list`. A per-line grep therefore inspects
    # the wrong half and reports clean no matter what the redirect says. That
    # was not hypothetical: the line-scoped spelling of this assertion survived
    # a mutation that put `2>/dev/null` back on the sweep query, which is the
    # precise defect this file exists to catch.
    for b in select sweep awaiting nopatch; do
        if fold_continuations "$SANDBOX/$b.sh" | grep 'gc bd list' | grep -q '2>/dev/null'; then
            fail "the $b ledger query discards stderr again; the failure can no longer say which failure it was"
        fi
    done
    grep -q 'gc bd show "\$GC_SESSION_ID" --json 2>/dev/null' "$CODE" \
        && fail "the sleep-policy read discards stderr again (formula line ~728 in gp-2uw); an unreadable policy and an unconfigured one are different facts about the city"
    return 0
}

test_transient_failure_recovers_without_restarting() {
    # The reported instance was a ~2min install window. A read moments later is
    # likely the real answer, so the first blip must not cost a restart.
    reset_run "$ONE_BEAD"
    OUT=$(GC_FAIL_SELECTOR=1 run_blocks "$SANDBOX/select.sh")

    grep -q 'FELL_THROUGH WORK=\[gp-999\] MEASURED=\[true\]' <<<"$OUT" \
        || fail "a transient ledger failure did not recover on retry (output: $OUT); the queue was readable and a waiting branch was missed"
    if grep -q 'request-restart' "$GC_LOG"; then
        fail "a transient ledger failure restarted the session instead of re-reading; that trades a silent stall for a noisy one"
    fi
}

test_backoff_does_not_sleep_after_the_final_attempt() {
    # Sleeping after the last read only delays a restart already decided.
    reset_run '[]'
    GC_FAIL_SELECTOR=99 run_blocks "$SANDBOX/select.sh" >/dev/null
    SLEEPS=$(wc -l <"$SLEEP_LOG" | tr -d ' ')
    TRIES=$(grep -c 'gc bd list' "$GC_LOG" || true)

    [ "$TRIES" -ge 2 ] \
        || fail "the selector did not retry an unreadable ledger at all (reads: $TRIES)"
    [ "$SLEEPS" -eq "$((TRIES - 1))" ] \
        || fail "backoff slept $SLEEPS times across $TRIES reads; expected $((TRIES - 1)) -- a sleep after the final read only delays the restart"
}

test_sweep_crash_does_not_render_as_idle() {
    # The sweep runs only once the selector has already said "empty", so it is
    # the LAST thing standing between a misaddressed handoff and an idle turn.
    # An unreadable sweep arriving there wearing the same empty stdout as
    # "nothing stranded" is the identical defect one door further down.
    reset_run '[]'
    OUT=$(GC_FAIL_SWEEP=99 run_blocks "$SANDBOX/select.sh" "$SANDBOX/sweep.sh")

    if grep -q 'FELL_THROUGH' <<<"$OUT"; then
        fail "an unreadable sweep fell through to the idle path (output: $OUT); the ledger was never swept and the turn would print IDLE"
    fi
    grep -q 'SWEEP: UNMEASURED' <<<"$OUT" \
        || fail "an unreadable sweep produced no UNMEASURED signal (output: $OUT)"
    grep -q 'gc runtime request-restart' "$GC_LOG" \
        || fail "an unreadable sweep did not restart the session"
}

test_sweep_still_runs_when_the_selector_measured_empty() {
    # Guards the premise of the test above: the sweep must actually be reached
    # on a clean empty selector, or its crash assertion proves nothing.
    reset_run '[]'
    run_blocks "$SANDBOX/select.sh" "$SANDBOX/sweep.sh" >/dev/null
    SWEEP_READS=$(grep -c 'gc bd list' "$GC_LOG" || true)
    [ "$SWEEP_READS" -ge 2 ] \
        || fail "the sweep did not query the ledger after a measured-empty selector (reads: $SWEEP_READS); its crash test would be vacuous"
}

test_awaiting_poll_reports_an_unmeasured_pass() {
    # This poll is the ONLY place an `mr` bead closes. It does not end the turn,
    # so it correctly continues on '[]' -- but a poll that never happened must
    # not pass for a poll that found nothing parked.
    reset_run '[]'
    OUT=$(GC_FAIL_AWAITING=99 run_blocks "$SANDBOX/awaiting.sh")

    grep -q 'AWAITING_MERGE: UNMEASURED' <<<"$OUT" \
        || fail "a crashed awaiting-merge poll was silent (output: $OUT); every parked PR went unpolled and nothing said so"
    grep -q 'FELL_THROUGH' <<<"$OUT" \
        || fail "the awaiting-merge poll ended the turn on an unreadable ledger; it is a poll, not the queue-empty verdict, and must not stop the patrol"
}

test_no_patch_triage_reports_an_unmeasured_pass() {
    reset_run '[]'
    OUT=$(GC_FAIL_NOPATCH=99 run_blocks "$SANDBOX/nopatch.sh")

    grep -q 'NO_PATCH: UNMEASURED' <<<"$OUT" \
        || fail "a crashed no-patch triage was silent (output: $OUT); no-patch beads went untriaged and nothing said so"
    grep -q 'FELL_THROUGH' <<<"$OUT" \
        || fail "the no-patch triage ended the turn on an unreadable ledger; it must not stop the patrol"
}

test_restart_failure_still_leaves_a_record() {
    # `request-restart` blocks until the controller acts and can itself fail. If
    # it does, the step must still say so rather than exiting quietly -- the
    # heartbeat nag becomes the only remaining backstop and that fact has to be
    # visible to whoever reads the pane.
    reset_run '[]'
    OUT=$(GC_FAIL_SELECTOR=99 GC_RESTART_CODE=1 run_blocks "$SANDBOX/select.sh")

    grep -q 'request-restart failed' <<<"$OUT" \
        || fail "a failed request-restart left no record (output: $OUT); the turn ends unmeasured with nothing naming the remaining backstop"
}

run_case() {
    "$1"
    echo "  ok: ${1#test_}"
}

run_case test_crashed_ledger_does_not_render_as_idle
run_case test_drained_queue_still_idles
run_case test_crash_and_drained_are_distinguishable
run_case test_status_checked_is_gcs_not_a_pipelines
run_case test_ledger_reads_keep_their_stderr
run_case test_transient_failure_recovers_without_restarting
run_case test_backoff_does_not_sleep_after_the_final_attempt
run_case test_sweep_crash_does_not_render_as_idle
run_case test_sweep_still_runs_when_the_selector_measured_empty
run_case test_awaiting_poll_reports_an_unmeasured_pass
run_case test_no_patch_triage_reports_an_unmeasured_pass
run_case test_restart_failure_still_leaves_a_record

echo "PASS: test_refinery_unmeasured_queue.sh"
