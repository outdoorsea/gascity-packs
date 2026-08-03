#!/usr/bin/env bash
# Guards mol-witness-patrol's closing contract: the witness must VERIFY the
# idle-restart mechanism, never assert it.
#
# `session_sleep` is a real gc mechanism, but it is OFF unless a city or rig
# configures one: with nothing set, ResolveSessionSleepPolicy returns `off` with
# source `legacy_off`. The formula used to end its turn on the flat claim that
# "the session_sleep policy will restart this session after the configured idle
# interval", which is simply false on such a city -- and false in the most
# expensive way available, because every health signal keeps reading fine. The
# controller stays healthy, the session stays `active`, `last_active` keeps
# updating, so nothing anywhere reports the stall. Two effects, measured on two
# rigs (gp-5bg):
#
#   1. Patrol cadence collapsed onto the 90m heartbeat nag (~92-105m observed),
#      which is a backstop, not a schedule.
#   2. The witness NEVER shed context. A session nagged awake resumes with all
#      prior context, so it grows every cycle -- ~68% after three -- and rides
#      into compaction instead of starting clean. This is the harmful one: a
#      compacted witness loses exactly the state its recovery job depends on.
#
# What is nailed down here:
#
#   1. The step READS the resolved policy off its own session bead instead of
#      assuming one, and the old bare assertion is gone.
#   2. It calls `gc runtime request-restart` itself when no policy is configured.
#   3. The decision logic is exercised as EXTRACTED FROM THE FORMULA -- never a
#      copy -- so an edit that inverts or loosens it fails CI rather than
#      silently restoring the stall.
#   4. That logic is fail-SAFE: only a duration-shaped value takes the quiet
#      IDLE path. `off`, empty, unreadable and unparseable all restart. The
#      inverted spelling ("restart only when the value is off or empty") passes
#      a naive eyeball and reintroduces the bug on any malformed value, so it is
#      tested for directly.
#   5. The `IDLE: no work, exiting turn.` literal survives for the configured
#      branch -- test_parked_session_check.sh uses that exact pane shape to
#      represent a healthy idle witness.
#
# One discipline runs through all of it: assertions about what the step DOES are
# made against its FENCED CODE BLOCKS, never against the description. A formula
# step is prose interleaved with shell, and the prose necessarily names the same
# commands and variables the code uses. A description-wide grep is therefore
# satisfied by the documentation of a mechanism rather than the mechanism, and a
# line-level sweep for a token will happily lift a markdown bullet -- or a
# command from an unrelated block -- into a file about to be sourced.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
FORMULA="$ROOT/gastown/formulas/mol-witness-patrol.toml"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

command -v python3 >/dev/null 2>&1 || fail "python3 is required to parse the formula"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Render the next-iteration step description through a real TOML parse, so the
# assertions below see what an agent sees -- not the raw file bytes. The
# distinction is load-bearing: these are """ basic strings, where a trailing
# backslash silently eats its newline and the following indentation, so a
# snippet can read fine in the file and arrive at the agent joined together.
python3 - "$FORMULA" "$WORK" <<'PY'
import sys, tomllib, pathlib

formula, work = sys.argv[1], pathlib.Path(sys.argv[2])
with open(formula, "rb") as fh:
    doc = tomllib.load(fh)

steps = [s for s in doc.get("steps", []) if s.get("id") == "next-iteration"]
if len(steps) != 1:
    sys.exit(f"expected exactly one next-iteration step, found {len(steps)}")
desc = steps[0]["description"]
(work / "step.txt").write_text(desc)

# Pull the decision snippet out of the step itself. Extracting rather than
# restating is the whole point: a test that hardcodes its own copy of the logic
# keeps passing after the formula drifts away from it.
#
# Select STRUCTURALLY -- a fenced code block -- not by "any line mentioning the
# variable". The step is prose interleaved with code, and several prose bullets
# name NEEDS_RESTART inside backticks. A lexical sweep drags those into a file
# that is about to be sourced as shell, and worse, it also drags in the ACTING
# line from the separate block below (`gc runtime request-restart`), which
# blocks until the controller kills the session. A test must classify policy
# values, never perform the restart it is reasoning about.
blocks, cur, fence = [], None, None
for ln in desc.splitlines():
    stripped = ln.strip()
    if fence is None:
        if stripped.startswith("```"):
            fence, cur = stripped[:3], []
    elif stripped.startswith(fence):
        blocks.append(cur)
        fence, cur = None, None
    else:
        cur.append(ln)

# The decision block is the one that both reads a policy and classifies it; the
# acting block names NEEDS_RESTART but never SLEEP_POLICY, which separates them.
decision = [b for b in blocks
            if any("SLEEP_POLICY" in ln for ln in b)
            and any("NEEDS_RESTART" in ln for ln in b)]
if len(decision) != 1:
    sys.exit(f"expected exactly one SLEEP_POLICY/NEEDS_RESTART decision block, found {len(decision)}")

# Keep only the classifier. The two SLEEP_POLICY assignments source the value
# from the live session bead -- that is the step's job, not the classifier's,
# and leaving them in would both clobber the value each case injects and make
# the result depend on whatever policy the machine running CI happens to have.
# Drop the echo too: diagnostics, and it would pollute harness stdout.
keep = [ln for ln in decision[0]
        if not ln.strip().startswith("SLEEP_POLICY=")
        and "gc bd show" not in ln
        and not ln.strip().startswith("echo ")]
if not any("NEEDS_RESTART" in ln for ln in keep):
    sys.exit("decision block has no NEEDS_RESTART logic left after dropping the policy read")

# Fail loudly if the classifier ever grows a side effect. Sourcing this file is
# only safe while it is pure computation over SLEEP_POLICY.
for ln in keep:
    if ln.strip().startswith(("gc ", "git ")) or " gc runtime " in ln:
        sys.exit(f"classifier would execute a live command, refusing to source it: {ln.strip()!r}")

(work / "decide.sh").write_text("\n".join(keep) + "\n")

# Every fenced block, joined. Assertions about what the step DOES must run
# against this and not against the whole description: the step's prose names
# `gc runtime request-restart` while explaining it, so grepping the description
# is satisfied by the documentation of the call rather than the call itself,
# and deleting the real one still passes.
(work / "code.txt").write_text("\n".join("\n".join(b) for b in blocks) + "\n")
PY

STEP="$WORK/step.txt"
DECIDE="$WORK/decide.sh"
CODE="$WORK/code.txt"

test_step_reads_the_policy_instead_of_asserting_it() {
    # Target the READ -- the jq path against the session bead -- not the bare
    # token. `effective_sleep_after_idle` also appears in the step's diagnostic
    # echo, so a token grep survives swapping the jq path to a different key
    # and would report a step that reads the wrong field as healthy.
    grep -q 'metadata\.effective_sleep_after_idle' "$CODE" \
        || fail "no fenced block reads metadata.effective_sleep_after_idle; the step is assuming a policy again, or reading the wrong key"
    grep -q 'gc bd show "\$GC_SESSION_ID"' "$CODE" \
        || fail "the policy is not read off this session's own bead; a policy resolved for some other session says nothing about this one"

    # The exact sentence the bug shipped as. Its return means the step went back
    # to promising a restart it cannot verify.
    if grep -q "The session_sleep policy will restart this session after the configured idle interval" "$STEP"; then
        fail "next-iteration still carries the bare session_sleep assertion (gp-5bg)"
    fi
}

test_step_restarts_itself_when_unconfigured() {
    # Assert the GATED form specifically, in a fenced block. Two weaker
    # spellings were tried first and both are vacuous here:
    #
    #   grep "gc runtime request-restart" "$STEP" -- the step's own prose names
    #     the command while explaining it ("an explicit `gc runtime
    #     request-restart` without one"), so deleting the real call still passes.
    #   grep "gc runtime request-restart" "$CODE" -- narrower, but this step
    #     ALREADY carried a bare `gc runtime request-restart` on origin/main, in
    #     the context-exhaustion snippet near the top. That pre-existing line
    #     satisfies the grep on its own, so it guards nothing this change added.
    #
    # The gated form is what is actually new, and it is also the only correct
    # shape: an ungated restart fires under a configured policy too, trading the
    # silent stall for a session that can never stay up.
    grep -q 'NEEDS_RESTART.*request-restart' "$CODE" \
        || fail "no fenced block calls 'gc runtime request-restart' gated on NEEDS_RESTART; either nothing sheds witness context, or the restart is unconditional"
}

test_idle_literal_survives_for_the_configured_branch() {
    grep -qF "IDLE: no work, exiting turn." "$STEP" \
        || fail "the 'IDLE: no work, exiting turn.' literal is gone; the configured branch and the parked-session fixture both depend on it"
}

# Run the EXTRACTED decision logic over a table of policy values.
decide() {
    local policy="$1"
    (
        set +u
        SLEEP_POLICY="$policy"
        # shellcheck disable=SC1090
        . "$DECIDE"
        printf '%s' "$NEEDS_RESTART"
    )
}

test_decision_is_failsafe() {
    local restart_cases=(
        "off"                 # explicitly disabled
        ""                    # unset, or the bead read failed
        "legacy_off"          # the source string, if it ever lands in the value
        "30x"                 # malformed unit
        "mmm"                 # unit letters, no magnitude
        "OFF"                 # case variant the resolver would have normalized
        "unknown"             # anything a future gc might mirror
    )
    local idle_cases=(
        "30m"
        "1h"
        "1h30m"
        "1.5h"
        "90s"
    )

    local v got
    for v in "${restart_cases[@]}"; do
        got=$(decide "$v")
        [ "$got" = "1" ] \
            || fail "policy '${v:-<empty>}' selected the quiet IDLE path (needs_restart=$got); it must fail toward the restart"
    done
    for v in "${idle_cases[@]}"; do
        got=$(decide "$v")
        [ "$got" = "0" ] \
            || fail "configured policy '$v' selected a forced restart (needs_restart=$got); a real policy must be left to do its job"
    done
}

test_decision_is_not_the_inverted_spelling() {
    # The tempting inversion is `[ -z "$SLEEP_POLICY" ] || [ "$SLEEP_POLICY" = "off" ]`.
    # It agrees with the correct test on every value EXCEPT a malformed one, so
    # the table above is what actually separates them -- but catching the
    # spelling directly makes the failure legible instead of arriving as a
    # confusing single-case mismatch.
    if grep -q 'SLEEP_POLICY" = "off"' "$DECIDE"; then
        fail "decision logic tests for equality with 'off'; it must positively match a duration shape so unparseable values restart"
    fi
}

test_read_is_guarded_on_session_id() {
    # An unset GC_SESSION_ID under `set -u` would abort the step mid-cycle,
    # after the successor wisp was poured and this one burned.
    grep -q 'GC_SESSION_ID:-' "$STEP" \
        || fail "the session-bead read does not guard on \${GC_SESSION_ID:-}; an unset id would abort the step"
}

test_step_reads_the_policy_instead_of_asserting_it
test_step_restarts_itself_when_unconfigured
test_idle_literal_survives_for_the_configured_branch
test_decision_is_failsafe
test_decision_is_not_the_inverted_spelling
test_read_is_guarded_on_session_id

echo "PASS: $(basename "${BASH_SOURCE[0]}")"
