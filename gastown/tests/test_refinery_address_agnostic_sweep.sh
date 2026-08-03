#!/usr/bin/env bash
# Guards the refinery's third discovery path: the address-agnostic sweep in
# mol-refinery-patrol's find-work step.
#
# The bug this locks down (gp-q6i, measured on the live tallyup ledger): both
# prescribed discovery paths compare the SAME address string -- find-work
# matches `assignee == $GC_AGENT`, the startup orphan scan matches
# `gc.routed_to ==` this refinery's address -- so both go blind to one defect at
# the same instant. A handoff written to a MISSPELLED refinery address matches
# neither and sits open, branched, pushed and invisible while the refinery
# reports an empty queue and idles. Two live forms were measured on one ledger
# ('tallyup/refinery' and 'tallyup/gastown.refinery'); only one was ever
# queried. Neither stranded bead was found by anything in the formula.
#
# All shell under test is EXTRACTED FROM THE FORMULA ITSELF -- never a copy --
# so an assertion cannot keep passing while the formula drifts away from it.
#
# What is nailed down here:
#   1. A bead the exact-assignee selector CANNOT see is adopted by the sweep,
#      proven against one ledger served through both queries -- so the premise
#      ("the primary path misses it") is demonstrated, not assumed.
#   2. The sweep keys on a DIFFERENT attribute than the paths it backs up. It
#      never reads the assignee, which is the whole point: redundancy that keys
#      on the same field is not redundancy.
#   3. Every ownership marker still excludes -- awaiting_merge, no_code_change,
#      rejection_reason, branch_ready, halt_reason, and any non-empty
#      gc.routed_to -- including the BOOLEAN spelling that `--set-metadata`
#      really stores. `true != "true"` in jq, which is exactly how the
#      awaiting_merge exclusion once shipped inert.
#   4. Adoption demands positive evidence a polecat finished: metadata.target
#      set (only the submit step writes it) and origin/<branch> actually
#      existing, proven against a real git remote. A dead session's half-built
#      branch is never mistaken for a handoff.
#   5. An origin that cannot be reached fails CLOSED -- unreachable is not
#      absent, and guessing either way is worse than waiting a patrol.
#   6. Adoption repairs the address, so the ordinary paths find the bead next
#      patrol and the sweep never has to discover the same bead twice.
#   7. The sweep stays guarded on the idle verdict. When step 3 selects work,
#      the sweep does not run at all.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
FORMULA="$ROOT/gastown/formulas/mol-refinery-patrol.toml"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq is required to exercise the sweep"

# Emit the single fenced bash block of STEP that contains ANCHOR, with {{vars}}
# rendered from the formula's own defaults the way the formula engine renders
# them. Requiring EXACTLY one match is deliberate: if the step is reorganised
# and an anchor goes missing or turns ambiguous, this dies loudly instead of
# quietly exercising nothing.
extract_step_block() {
    python3 - "$FORMULA" "$1" "$2" <<'PY'
import re
import sys
import tomllib

formula, step_id, anchor = sys.argv[1], sys.argv[2], sys.argv[3]
with open(formula, "rb") as handle:
    data = tomllib.load(handle)

step = next(s for s in data["steps"] if s["id"] == step_id)
blocks = [
    b for b in re.findall(r"```bash\n(.*?)```", step["description"], re.S)
    if anchor in b
]
if len(blocks) != 1:
    sys.exit(
        f"expected exactly 1 {step_id} bash block containing {anchor!r}, "
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

# `gc` stub. Both `gc bd list` and `gc bd show` are served from ONE ledger
# file, with the query flags actually applied -- so a test cannot quietly
# encode its own premise by handing the two queries different, hand-tuned
# answers. The primary selector misses the misaddressed bead here for the
# same reason it misses it in production: `--assignee` does not match, and
# the sweep passes no `--assignee` at all.
#
# Mutations are recorded one line per command in $GC_LOG.
write_gc_stub() {
    cat >"$1/gc" <<'SH'
#!/usr/bin/env sh
case "gc $1 $2" in
    "gc bd show")
        jq --arg id "$3" '[.[] | select(.id == $id)]' "$GC_LEDGER"
        exit 0
        ;;
    "gc bd list")
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
                    filter="$filter | map(select((.status // \"open\") == \"open\"))"
                    ;;
            esac
        done
        jq "$filter" "$GC_LEDGER"
        exit 0
        ;;
esac
printf 'gc %s\n' "$*" >>"$GC_LOG"
exit 0
SH
    chmod +x "$1/gc"
}

# Fresh sandbox with a real repo and a real bare origin, so `git ls-remote` in
# the sweep answers from genuine refs rather than a stub. The branch would be
# found if the guard let it through, which is what makes the absence assertions
# non-vacuous.
new_sandbox() {
    SANDBOX=$(mktemp -d)
    BIN="$SANDBOX/bin"
    mkdir -p "$BIN"
    write_gc_stub "$BIN"
    GC_LOG="$SANDBOX/gc.log"
    : >"$GC_LOG"
    GC_LEDGER="$SANDBOX/ledger.json"
    printf '[]\n' >"$GC_LEDGER"
    # Pin the rig and the canonical identity so assertions never depend on the
    # ambient environment of whoever runs the suite.
    GC_RIG=testrig
    GC_AGENT=testrig/gastown.refinery
    export GC_LOG GC_LEDGER GC_RIG GC_AGENT

    ORIGIN="$SANDBOX/origin.git"
    REPO="$SANDBOX/work"
    git init -q --bare "$ORIGIN"
    git init -q "$REPO"
    git -C "$REPO" config user.email t@example.com
    git -C "$REPO" config user.name Tester
    git -C "$REPO" remote add origin "$ORIGIN"
    echo base >"$REPO/file.txt"
    git -C "$REPO" add file.txt
    git -C "$REPO" commit -qm base
    git -C "$REPO" branch -M main
    git -C "$REPO" push -q origin main
}

# Push a branch to origin so the sweep's existence check can find it.
push_branch() {
    git -C "$REPO" checkout -q -b "$1" main
    echo "$1" >"$REPO/$(basename "$1").txt"
    git -C "$REPO" add -A
    git -C "$REPO" commit -qm "work for $1"
    git -C "$REPO" push -q origin "$1"
    git -C "$REPO" checkout -q main
}

# Write the whole ledger. Callers pass a JSON array so the metadata TYPES are
# under their control -- `--set-metadata k=true` stores a JSON boolean, and a
# stringified fixture is exactly how a type-strict comparison passed here while
# the queue misbehaved in production.
write_ledger() {
    printf '%s\n' "$1" >"$GC_LEDGER"
}

# The misaddressed handoff, in the shape the live incident took: open, carrying
# branch and target, gc.routed_to CLEARED (which is what a correct handoff
# does), and addressed to a refinery spelling this refinery does not query.
misaddressed_bead() {
    cat <<JSON
[{"id":"bd-lost","status":"open","assignee":"${1:-testrig/refinery}",
  "metadata":{"branch":"polecat/bd-lost","target":"main","fork_sha":"deadbeef"}}]
JSON
}

# Run step 3's selector and then the sweep, composed exactly as the agent runs
# them: the sweep reads the $WORK the selector left behind. Echoes the final
# bead ($WORK), or "" when the refinery goes idle.
run_selection() {
    extract_step_block find-work 'WORK_JSON_RAW=$(gc bd list' >"$SANDBOX/select.sh"
    extract_step_block find-work 'ADDRESS_AGNOSTIC_SWEEP' >"$SANDBOX/sweep.sh"
    (cd "${1:-$REPO}" && PATH="$BIN:$PATH" bash -c \
        '. "$1/select.sh"; . "$1/sweep.sh"; printf "%s\n" "${WORK:-}"' \
        _ "$SANDBOX") >"$SANDBOX/sweep.out" 2>&1
    tail -1 "$SANDBOX/sweep.out"
}

# Run step 3's selector ALONE and echo what it chose. Used to prove the primary
# path genuinely cannot see a bead before asserting the sweep rescues it.
run_primary_only() {
    extract_step_block find-work 'WORK_JSON_RAW=$(gc bd list' >"$SANDBOX/select.sh"
    (cd "$REPO" && PATH="$BIN:$PATH" bash -c \
        '. "$1/select.sh"; printf "%s\n" "${WORK:-}"' _ "$SANDBOX")
}

assert_not_adopted() {
    ! grep -q "gc bd update" "$GC_LOG" ||
        fail "$1: nothing should have been reassigned, log: $(cat "$GC_LOG")"
    ! grep -q "address_repaired_from" "$GC_LOG" ||
        fail "$1: nothing should have been adopted, log: $(cat "$GC_LOG")"
}

test_sweep_adopts_a_bead_the_exact_assignee_query_cannot_see() {
    # The headline regression, and the exact live shape: a merge handoff wearing
    # an address nothing queries.
    new_sandbox
    push_branch polecat/bd-lost
    write_ledger "$(misaddressed_bead testrig/refinery)"

    # Non-vacuity, from the SAME ledger: the prescribed path selects nothing.
    # Without this the sweep could be rescuing work that was never lost.
    primary=$(run_primary_only)
    [ -z "$primary" ] ||
        fail "fixture is wrong: the exact-assignee selector must MISS the misaddressed bead, got: '$primary'"

    selected=$(run_selection)
    [ "$selected" = "bd-lost" ] ||
        fail "the sweep must adopt the misaddressed handoff, got: '$selected' (out: $(cat "$SANDBOX/sweep.out"))"

    grep -q "SWEEP: adopted bd-lost" "$SANDBOX/sweep.out" ||
        fail "adoption must say so out loud, got: $(cat "$SANDBOX/sweep.out")"
    grep -q "session nudge.*witness" "$GC_LOG" ||
        fail "a bead invisible to both paths must surface to the witness, log: $(cat "$GC_LOG")"
}

test_sweep_ignores_the_assignee_entirely() {
    # The design assertion. If the sweep ever grows an address comparison it
    # will pass the test above (which uses one known-wrong spelling) while still
    # being blind to "forms not yet invented" -- the case it exists for. An
    # address with no recognisable refinery token at all pins that.
    for addr in "testrig/refinery" "refinery" "testrig/gastown.refinary" "wat/000-not-an-address"; do
        new_sandbox
        push_branch polecat/bd-lost
        write_ledger "$(misaddressed_bead "$addr")"

        selected=$(run_selection)
        [ "$selected" = "bd-lost" ] ||
            fail "the sweep must adopt regardless of address form '$addr', got: '$selected' (out: $(cat "$SANDBOX/sweep.out"))"
    done

    # Including the degenerate one: no address at all.
    new_sandbox
    push_branch polecat/bd-lost
    write_ledger '[{"id":"bd-lost","status":"open",
      "metadata":{"branch":"polecat/bd-lost","target":"main"}}]'
    selected=$(run_selection)
    [ "$selected" = "bd-lost" ] ||
        fail "an unassigned but completed handoff must still be adopted, got: '$selected'"
    grep -q "address_repaired_from=<unassigned>" "$GC_LOG" ||
        fail "the repair must record that there was no address, log: $(cat "$GC_LOG")"
}

test_sweep_does_not_run_when_the_primary_query_found_work() {
    # The sweep reads every open branch-carrying bead in the ledger. Step 3 is
    # cheaper and authoritative when it answers, and idle is the only symptom
    # the bug produces -- so the guard is load-bearing, not an optimisation.
    new_sandbox
    push_branch polecat/bd-mine
    push_branch polecat/bd-lost
    write_ledger '[{"id":"bd-mine","status":"open","assignee":"testrig/gastown.refinery",
      "metadata":{"branch":"polecat/bd-mine","target":"main"}},
     {"id":"bd-lost","status":"open","assignee":"testrig/refinery",
      "metadata":{"branch":"polecat/bd-lost","target":"main"}}]'

    selected=$(run_selection)
    [ "$selected" = "bd-mine" ] ||
        fail "correctly addressed work must win, got: '$selected'"
    assert_not_adopted "primary query answered"
    ! grep -q "SWEEP:" "$SANDBOX/sweep.out" ||
        fail "the sweep must not run at all when step 3 answered, got: $(cat "$SANDBOX/sweep.out")"
}

test_sweep_respects_every_ownership_marker() {
    # Ignoring the assignee is only affordable because the OTHER metadata still
    # says who owns the bead. Each marker below hands the bead to someone else,
    # and the sweep stealing it would be a regression in a different direction:
    # re-merging a rejected branch, merging a deliberately unpushed one, or
    # racing the polecat pool for its own work.
    #
    # The flags are exercised in BOTH the boolean spelling that `--set-metadata`
    # really stores and the string spelling a hand-written fixture takes. In jq
    # `true != "true"` is TRUE, so a reader that handles only the string
    # excludes nothing while still reading as load-bearing.
    for flag in 'true' '"true"'; do
        for marker in "\"awaiting_merge\":$flag" "\"no_code_change\":$flag" "\"branch_ready\":$flag"; do
            new_sandbox
            push_branch polecat/bd-lost
            write_ledger "[{\"id\":\"bd-lost\",\"status\":\"open\",\"assignee\":\"testrig/refinery\",
              \"metadata\":{\"branch\":\"polecat/bd-lost\",\"target\":\"main\",$marker}}]"

            selected=$(run_selection)
            [ -z "$selected" ] ||
                fail "a bead marked {$marker} belongs to another path and must not be swept, got: '$selected'"
            assert_not_adopted "marker {$marker}"
        done
    done

    # String-valued markers: a rejected bead is the polecat pool's, a halted one
    # is the caller's, and any non-empty routing names its own owner.
    for marker in '"rejection_reason":"conflicts with main"' \
                  '"halt_reason":"auto_push_false"' \
                  '"gc.routed_to":"testrig/gastown.polecat"' \
                  '"gc.routed_to":"human"'; do
        new_sandbox
        push_branch polecat/bd-lost
        write_ledger "[{\"id\":\"bd-lost\",\"status\":\"open\",\"assignee\":\"testrig/refinery\",
          \"metadata\":{\"branch\":\"polecat/bd-lost\",\"target\":\"main\",$marker}}]"

        selected=$(run_selection)
        [ -z "$selected" ] ||
            fail "a bead carrying {$marker} is owned elsewhere and must not be swept, got: '$selected'"
        assert_not_adopted "marker {$marker}"
    done

    # Control: strip every marker and the SAME bead is adopted. Without this an
    # always-refusing filter would look correct on all of the above.
    new_sandbox
    push_branch polecat/bd-lost
    write_ledger "$(misaddressed_bead testrig/refinery)"
    selected=$(run_selection)
    [ "$selected" = "bd-lost" ] ||
        fail "control: an unmarked misaddressed handoff must still be adopted, got: '$selected'"
}

test_sweep_demands_evidence_a_polecat_actually_finished() {
    # `workspace-setup` records metadata.branch EARLY, before any implementation
    # exists, so a branch alone proves nothing. Only the submit step writes
    # `target`, and only a real push puts the ref on origin. Both are required,
    # because the alternative is merging whatever a dead session left behind.

    # (a) No target: the polecat never reached submit.
    new_sandbox
    push_branch polecat/bd-lost
    write_ledger '[{"id":"bd-lost","status":"open","assignee":"testrig/refinery",
      "metadata":{"branch":"polecat/bd-lost"}}]'
    selected=$(run_selection)
    [ -z "$selected" ] ||
        fail "a bead with no metadata.target is not a completed handoff, got: '$selected'"
    assert_not_adopted "no target"
    grep -q "no metadata.target" "$SANDBOX/sweep.out" ||
        fail "a stranded branch-carrying bead must still be reported, got: $(cat "$SANDBOX/sweep.out")"

    # (b) Branch never pushed. Everything else is valid, so the missing ref is
    # the only thing that can stop the adoption -- which is what makes this
    # assertion meaningful rather than incidental.
    new_sandbox
    write_ledger "$(misaddressed_bead testrig/refinery)"
    ! git -C "$REPO" ls-remote --exit-code --heads origin polecat/bd-lost >/dev/null 2>&1 ||
        fail "fixture is wrong: origin must NOT carry the branch for this case"
    selected=$(run_selection)
    [ -z "$selected" ] ||
        fail "a branch absent from origin is a dead polecat, not a merge, got: '$selected'"
    assert_not_adopted "branch absent"
    grep -q "died before pushing" "$SANDBOX/sweep.out" ||
        fail "an unpushed branch must be named as a dead polecat, got: $(cat "$SANDBOX/sweep.out")"
}

test_unreachable_origin_fails_closed() {
    # Unreachable is not absent. `git ls-remote --exit-code` returns 2 for "no
    # such ref" and something else for "could not ask", and collapsing the two
    # would either strand real work or merge on a guess. Waiting one patrol
    # costs nothing.
    new_sandbox
    write_ledger "$(misaddressed_bead testrig/refinery)"
    git -C "$REPO" remote set-url origin "$SANDBOX/no-such-origin.git"

    selected=$(run_selection)
    [ -z "$selected" ] ||
        fail "an unverifiable branch must not be adopted, got: '$selected'"
    assert_not_adopted "unreachable origin"
    grep -q "could not reach origin" "$SANDBOX/sweep.out" ||
        fail "an unreachable origin must be distinguished from a missing branch, got: $(cat "$SANDBOX/sweep.out")"
}

test_adoption_repairs_the_address() {
    # The repair is what stops this sweep being the permanent discovery path for
    # the bead: once the assignee is canonical, step 3 and the orphan scan both
    # see it on every later patrol.
    new_sandbox
    push_branch polecat/bd-lost
    write_ledger "$(misaddressed_bead testrig/refinery)"

    run_selection >/dev/null
    grep -q -- "--assignee=testrig/gastown.refinery" "$GC_LOG" ||
        fail "adoption must reassign to the canonical identity, log: $(cat "$GC_LOG")"
    grep -q "address_repaired_from=testrig/refinery" "$GC_LOG" ||
        fail "the wrong address must be preserved as the producer-side bug report, log: $(cat "$GC_LOG")"

    # And the repair is sufficient: replay the ledger as it now stands and the
    # PRIMARY path finds it, with no sweep involved.
    write_ledger '[{"id":"bd-lost","status":"open","assignee":"testrig/gastown.refinery",
      "metadata":{"branch":"polecat/bd-lost","target":"main"}}]'
    primary=$(run_primary_only)
    [ "$primary" = "bd-lost" ] ||
        fail "after repair the ordinary selector must find the bead, got: '$primary'"
}

test_sweep_selects_one_bead_and_stops() {
    # The merge pipeline below find-work handles one branch per iteration, so
    # adopting the whole backlog at once would reassign beads this session will
    # never get to -- and hide them from the next sweep, which now sees them as
    # correctly addressed and waiting.
    new_sandbox
    push_branch polecat/bd-lost
    push_branch polecat/bd-lost2
    write_ledger '[{"id":"bd-lost","status":"open","assignee":"testrig/refinery",
      "metadata":{"branch":"polecat/bd-lost","target":"main"}},
     {"id":"bd-lost2","status":"open","assignee":"testrig/refinery",
      "metadata":{"branch":"polecat/bd-lost2","target":"main"}}]'

    selected=$(run_selection)
    [ -n "$selected" ] || fail "the sweep must adopt something from a queue of two"
    adoptions=$(grep -c "address_repaired_from" "$GC_LOG" || true)
    [ "$adoptions" -eq 1 ] ||
        fail "exactly one bead should be adopted per patrol, got $adoptions, log: $(cat "$GC_LOG")"
}

test_sweep_adopts_a_bead_the_exact_assignee_query_cannot_see
test_sweep_ignores_the_assignee_entirely
test_sweep_does_not_run_when_the_primary_query_found_work
test_sweep_respects_every_ownership_marker
test_sweep_demands_evidence_a_polecat_actually_finished
test_unreachable_origin_fails_closed
test_adoption_repairs_the_address
test_sweep_selects_one_bead_and_stops

echo "PASS: $(basename "${BASH_SOURCE[0]}")"
