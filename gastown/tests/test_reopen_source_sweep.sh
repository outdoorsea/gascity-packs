#!/usr/bin/env bash
# Guards the round-boundary invariant that `gc gastown reopen-source` exists to
# uphold:
#
#   a bead reopened for a new round carries NO current-round merge disposition
#   and NO previous round's claim identity
#
# `gc workflow reopen-source` reopens a bead and clears its assignee. It clears
# nothing else. A bead reopened for round 2 therefore still carries round 1's
# refinery verdict in the CURRENT-round keys -- merge_result, no_patch_verified,
# no_code_change, no_code_change_evidence, work_dir -- and anything reading them
# concludes the bead is already dispositioned. That reading is exactly true of
# round 1 and exactly false of round 2, which had no verdict at all. Zero-diff is
# ALSO the expected shape of a legitimately passing validation bead, so the wrong
# reading is the plausible-looking one, and it closes a P0 criterion without ever
# validating it. Observed live on ml-cmai (PRD #261 crit:8d5572e9cf37); gp-8r1.
#
# The claim identity is the more dangerous half. ml-cmai was reassigned to one
# agent while still carrying a dead session's gc.session_id/gc.session_name and a
# gc.work_dir pointing into the worktree of the very agent its own
# validation_barred_agent BARS from validating it. Anything resolving a working
# directory from gc.work_dir pre-claim lands inside the barred agent's worktree
# -- a separation-of-duties bypass, not cosmetic drift.
#
# What is nailed down here:
#
#   1. The sweep runs against the REAL script, never a copy, so a change to the
#      field list is judged by these assertions rather than escaping them.
#   2. The POST-STATE is modelled, not just the plan: the recorded update args
#      are applied to the fixture metadata and the result is asserted to carry
#      no current-round disposition. This is the invariant in the bead's own
#      words, tested as a state rather than as a spelling.
#   3. Round numbering increments, so a second reopen cannot overwrite round1.*.
#   4. Values round-trip byte-for-byte, including evidence strings containing
#      `verdict=fail` -- `--set-metadata key=value` splits on the FIRST `=` only.
#   5. Fields that survive a round boundary honestly (branch, fork_sha, pr_url,
#      the witness's `recovered` counter) are NOT swept. Sweeping `branch` would
#      lose the artifact the next round resumes; sweeping `pr_url` would make
#      round 2 open a second PR; sweeping `recovered` would destroy the
#      crash-LOOP signal the witness reads.
#   6. Every disposition field the refinery ACTUALLY writes is covered -- read
#      out of mol-refinery-patrol.toml itself, so a new disposition added later
#      fails here instead of silently surviving the next reopen.
#   7. Routing happens in the SAME update as the namespacing. Splitting them
#      leaves a crash window in which the bead is open and either unroutable or
#      still advertising the previous round's verdict -- both are the bug.
#   8. A validator-roster bead routes to `human`, never the pool. A pool claim
#      never consults `eligible_validators`, so pool-routing it would hand the
#      barred agent the bead it is barred from validating.
#   9. The command fails CLOSED. Every refusal path must leave the bead
#      un-reopened; a reopen that happened without its sweep is the one state
#      this command exists to prevent, and it gets its own exit code.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SWEEP="$ROOT/gastown/assets/scripts/reopen-source-sweep.sh"
WRAPPER="$ROOT/gastown/commands/reopen-source/run.sh"
REFINERY_FORMULA="$ROOT/gastown/formulas/mol-refinery-patrol.toml"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq is required by the sweep under test"
[ -r "$SWEEP" ] || fail "sweep script missing: $SWEEP"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# A stub `gc` that serves one fixture bead and records every mutation. The sweep
# is exercised for real against it -- the only thing faked is the data plane.
# It is reached by putting this bin dir first on PATH, which is how the sibling
# suites (test_polecat_delivery_check.sh, test_deploy_check.sh) stub gc and why
# the sweep can call `gc` literally instead of through an indirection.
#
# Every call site also unsets GC_BIN, and that is load-bearing rather than
# tidiness: an agent session exports GC_BIN as an absolute path to the real
# binary, and agent-address.sh -- which the sweep runs for real to derive the
# pool address -- resolves `${GC_BIN:-gc}`. Leave it set and that one hop
# escapes PATH, reads the live agent roster, and refuses this fixture's
# `testrig/` address, so the suite passes or fails on the developer's ambient
# environment instead of on the sweep.
#
# The verb pair is joined with `:` rather than a space because
# tests/test_no_bare_bd_commands.py flags the literal token `bd` followed by a
# subcommand anywhere in a tracked file. It reads raw text, so it cannot tell a
# stub's case label from a real invocation -- and treating an indirection as a
# way around that is exactly what the gate self-asserts is a bypass.
mkdir -p "$WORK/bin"
cat >"$WORK/bin/gc" <<'STUB'
#!/usr/bin/env bash
case "$1:$2" in
    "bd:show")                cat "$STUB_BEAD"; exit 0 ;;
    "bd:update")              printf '%s\n' "$@" >>"$STUB_LOG"; exit "${STUB_UPDATE_RC:-0}" ;;
    "workflow:delete-source") echo "CALL delete-source" >>"$STUB_LOG"; exit "${STUB_DELETE_RC:-0}" ;;
    "workflow:reopen-source") echo "CALL reopen-source" >>"$STUB_LOG"; exit "${STUB_REOPEN_RC:-0}" ;;
esac
exit 99
STUB
chmod +x "$WORK/bin/gc"

# The ml-cmai shape, field for field, as the mayor's ruling recorded it.
write_fixture() {
    cat >"$1" <<'JSON'
[{"id":"ml-cmai","status":"blocked","assignee":"","metadata":{
  "merge_result":"no_patch_needs_human",
  "no_patch_verified":"confirmed zero-diff vs origin/main by the refinery; deliberate no-patch outcome, NOT a dead polecat",
  "no_code_change":true,
  "no_code_change_evidence":"verdict=fail, validator_agent_ref=gastown.capable, recorded 2026-07-31T19:18:04Z",
  "work_dir":"/city/.gc/worktrees/rig/polecats/gastown.capable/worktrees/ml-cmai",
  "gc.session_id":"gk-bbb7",
  "gc.session_name":"gastown__polecat-gk-bbb7",
  "gc.work_dir":"/city/.gc/worktrees/rig/polecats/gastown.nux",
  "gc.work_branch":"main",
  "branch":"polecat/ml-cmai",
  "fork_sha":"765333bd7d721abc50e7383aecb0480b316dfc99",
  "target":"main",
  "pr_url":"https://github.com/example/repo/pull/261",
  "pr_number":"261",
  "rejection_reason":"tests failed on round 1",
  "recovered":"true",
  "polecat_session":"gastown__polecat-gk-bbb7"}}]
JSON
}

# Run the real sweep. Extra args are passed through; stdout is the TSV plan.
#
# GC_PACK_DIR/GC_AGENT are real, not stubbed: with no --route the sweep resolves
# the pool address through the actual assets/scripts/agent-address.sh, so this
# exercises the self-derivation that retires the caller's routing obligation
# rather than trusting it.
run_sweep() {
    local bead_json="$1"
    shift
    : >"$WORK/log"
    env -u GC_TEMPLATE -u GC_RIG -u GC_BIN \
        STUB_BEAD="$bead_json" STUB_LOG="$WORK/log" PATH="$WORK/bin:$PATH" \
        GC_PACK_DIR="$ROOT/gastown" GC_AGENT="testrig/gastown.slit" \
        bash "$SWEEP" ml-cmai "$@"
}

# Apply the recorded `gc bd update` args to the fixture metadata and print the
# resulting metadata as JSON. This is what the bead LOOKS LIKE afterwards, which
# is the thing the invariant is actually about.
post_state() {
    python3 - "$1" "$WORK/log" <<'PY'
import json
import sys

meta = json.load(open(sys.argv[1]))[0]["metadata"]
args = [line.rstrip("\n") for line in open(sys.argv[2])]

# Trim the stub's marker lines and the leading update verb pair plus bead id.
args = [a for a in args if not a.startswith("CALL ")]
i = 0
while i < len(args):
    a = args[i]
    if a == "--set-metadata":
        key, _, value = args[i + 1].partition("=")
        meta[key] = value
        i += 2
    elif a == "--unset-metadata":
        meta.pop(args[i + 1], None)
        i += 2
    else:
        i += 1
json.dump(meta, sys.stdout)
PY
}

# The fields whose presence means "this round already has a verdict".
CURRENT_ROUND_DISPOSITION=(
    merge_result merged_sha merged_target no_patch_verified
    no_code_change no_code_change_evidence no_code_change_source
    no_code_change_cleared false_completion_suspected blocked_reason
    already_delivered_suspected awaiting_merge awaiting_merge_since
    awaiting_merge_since_epoch awaiting_merge_stale branch_ready halt_reason
)
# The fields that say who claimed it last and where they worked.
CLAIM_IDENTITY=(work_dir gc.session_id gc.session_name gc.work_dir polecat_session)

# 1 + 2. The invariant, as a post-state: nothing current-round survives.
test_reopened_bead_has_no_current_round_disposition() {
    write_fixture "$WORK/bead.json"
    run_sweep "$WORK/bead.json" >/dev/null || fail "sweep exited non-zero on the ml-cmai shape"
    local after
    after=$(post_state "$WORK/bead.json")

    local field
    for field in "${CURRENT_ROUND_DISPOSITION[@]}" "${CLAIM_IDENTITY[@]}"; do
        if printf '%s' "$after" | jq -e --arg k "$field" 'has($k)' >/dev/null; then
            fail "reopened bead still carries current-round '$field' -- the next reader takes the previous round's verdict as this round's"
        fi
    done

    # ...and it is parked, not destroyed. Round 1 stays auditable.
    printf '%s' "$after" | jq -e '.["round1.merge_result"] == "no_patch_needs_human"' >/dev/null ||
        fail "round1.merge_result was not parked -- the sweep must namespace, not delete"
    printf '%s' "$after" | jq -e '.["round1.gc.work_dir"] | test("gastown.nux")' >/dev/null ||
        fail "round1.gc.work_dir was not parked -- claim identity must sweep with the verdict"
}

# 3. A second reopen must not overwrite the first round's parked state.
#
#    Round 2 is simulated the way it actually happens: the bead comes back from
#    the first sweep with the current-round keys ABSENT, a polecat works it, and
#    the refinery writes a FRESH disposition. Reopening again must park that new
#    verdict under round2.* while round1.* stays exactly as it was.
test_round_number_increments() {
    write_fixture "$WORK/bead.json"
    run_sweep "$WORK/bead.json" >/dev/null || fail "first sweep failed"
    post_state "$WORK/bead.json" | python3 -c '
import json, sys
meta = json.load(sys.stdin)
meta["merge_result"] = "blocked"
meta["work_dir"] = "/city/.gc/worktrees/rig/polecats/gastown.rictus/worktrees/ml-cmai"
json.dump([{"id": "ml-cmai", "metadata": meta}], open(sys.argv[1], "w"))
' "$WORK/bead2.json"

    run_sweep "$WORK/bead2.json" >/dev/null || fail "second sweep failed"
    local after
    after=$(post_state "$WORK/bead2.json")

    printf '%s' "$after" | jq -e '.["round1.merge_result"] == "no_patch_needs_human"' >/dev/null ||
        fail "second reopen clobbered round1.merge_result -- rounds must accumulate, not overwrite"
    printf '%s' "$after" | jq -e '.["round2.merge_result"] == "blocked"' >/dev/null ||
        fail "second reopen did not park round 2's verdict under round2.*"
    printf '%s' "$after" | jq -e '.["round1.work_dir"] | test("gastown.capable")' >/dev/null ||
        fail "round1.work_dir was overwritten by round 2's worktree"
    printf '%s' "$after" | jq -e '.["round2.work_dir"] | test("gastown.rictus")' >/dev/null ||
        fail "round 2's work_dir was not parked under round2.*"
    printf '%s' "$after" | jq -e 'has("merge_result") or has("work_dir") | not' >/dev/null ||
        fail "current-round keys survived the second reopen"
}

# 4. Byte-for-byte round-trip, including the `=` inside an evidence string.
test_values_round_trip_verbatim() {
    write_fixture "$WORK/bead.json"
    run_sweep "$WORK/bead.json" >/dev/null || fail "sweep failed"
    local want got
    want=$(jq -r '.[0].metadata.no_code_change_evidence' "$WORK/bead.json")
    got=$(post_state "$WORK/bead.json" | jq -r '.["round1.no_code_change_evidence"]')
    [ "$want" = "$got" ] ||
        fail "evidence did not round-trip. --set-metadata splits on the FIRST '=' only, so 'verdict=fail' must be re-injected, never retyped.
  want: $want
  got:  $got"
}

# 5. Fields that survive a round boundary honestly are left alone.
test_round_durable_fields_are_not_swept() {
    write_fixture "$WORK/bead.json"
    run_sweep "$WORK/bead.json" >/dev/null || fail "sweep failed"
    local after field
    after=$(post_state "$WORK/bead.json")
    # branch/fork_sha/target: the artifact round 2 RESUMES.
    # pr_url/pr_number: a durable external artifact; sweeping them opens a 2nd PR.
    # rejection_reason: round-N input, written after reopen -- not round-N-1 output.
    # recovered: a cross-round counter the witness reads to detect a crash LOOP.
    # gc.work_branch: the rig's base branch, a gc-core stamp, not claim identity.
    for field in branch fork_sha target pr_url pr_number rejection_reason recovered gc.work_branch; do
        printf '%s' "$after" | jq -e --arg k "$field" 'has($k)' >/dev/null ||
            fail "sweep removed '$field', which survives a round boundary honestly"
    done
}

# 6. Every disposition the refinery actually writes is covered by the sweep.
#    Read out of the formula, so adding a disposition field without teaching the
#    sweep about it fails HERE rather than surviving the next reopen silently.
test_sweep_covers_every_refinery_disposition() {
    python3 - "$REFINERY_FORMULA" "$SWEEP" <<'PY' || exit 1
import re
import sys
import tomllib

with open(sys.argv[1], "rb") as handle:
    data = tomllib.load(handle)
text = "\n".join(
    [data.get("description", "")]
    + [s.get("description", "") for s in data.get("steps", [])]
)
text = re.sub(r"\\\n\s*", " ", text)

written = set()
for cmd in re.findall(r"gc bd update[^\n`]*", text):
    if "merge_result=" not in cmd:
        continue
    written.update(re.findall(r"--set-metadata\s+([A-Za-z_][\w.]*)=", cmd))

# Co-written with a disposition, but round-durable by design. Each is justified
# in the sweep's own NOT-SWEPT block; keep the two in agreement.
DURABLE = {
    "gc.routed_to",      # the sweep rewrites this itself
    "pr_url",            # durable external artifact; sweeping opens a 2nd PR
    "pr_number",
    "rejection_reason",  # round-N input, not round-N-1 output
}

body = open(sys.argv[2], encoding="utf-8").read()
block = re.search(r"SWEEP_FIELDS=\((.*?)\n\)", body, re.S)
if not block:
    sys.exit("FAIL: cannot find SWEEP_FIELDS in the sweep script")
# Strip comments before splitting. A commented-out field, or prose that merely
# NAMES one, must not vouch for a field that was deleted from the list -- that
# would make this check pass on exactly the regression it exists to catch.
swept = set()
for line in block.group(1).splitlines():
    swept.update(line.split("#", 1)[0].split())

missing = sorted(f for f in written - DURABLE if f not in swept)
if missing:
    sys.exit(
        "FAIL: mol-refinery-patrol writes disposition field(s) the sweep does "
        f"not clear: {', '.join(missing)}. A field left in the current-round "
        "keys reads as the NEW round's verdict. Add it to SWEEP_FIELDS, or to "
        "this test's DURABLE set with a reason if it genuinely outlives a round."
    )
PY
}

# 7. Namespacing and routing land in ONE update. Two updates leave a crash
#    window in which the bead is open and either unroutable or still carrying
#    the previous verdict.
test_sweep_and_route_are_one_atomic_update() {
    write_fixture "$WORK/bead.json"
    run_sweep "$WORK/bead.json" --route testrig/gastown.polecat >/dev/null || fail "sweep failed"

    local updates
    updates=$(grep -c '^update$' "$WORK/log" || true)
    [ "$updates" -eq 1 ] ||
        fail "expected exactly 1 gc bd update, found $updates -- splitting the sweep from the routing is the bug"

    grep -qx 'gc.routed_to=testrig/gastown.polecat' "$WORK/log" ||
        fail "routing was not set in the sweep update"
    # The reopen must precede the sweep, and delete-source must precede both.
    grep -n 'CALL ' "$WORK/log" | head -2 | tr '\n' ' ' |
        grep -q 'CALL delete-source.*CALL reopen-source' ||
        fail "delete-source must run before reopen-source: reopening a bead whose stale subtree is still open re-races the steps being retired"
    # Post-condition is asserted by the command, not inherited from reopen-source.
    grep -qx -- '--status=open' "$WORK/log" || fail "sweep must assert --status=open"
    grep -qx -- '--assignee=' "$WORK/log" || fail "sweep must assert an empty --assignee"
}

# 8. A validator-roster bead must never be pool-routed.
test_validator_roster_bead_routes_to_human() {
    python3 - "$WORK/bead.json" "$WORK/roster.json" <<'PY'
import json
import sys

bead = json.load(open(sys.argv[1]))
bead[0]["metadata"]["eligible_validators"] = "rictus,slit,capable"
bead[0]["metadata"]["validation_barred_agent"] = "nux"
json.dump(bead, open(sys.argv[2], "w"))
PY

    # Even an explicit pool --route must not win: the roster is the stronger fact.
    run_sweep "$WORK/roster.json" --route testrig/gastown.polecat >/dev/null 2>&1 ||
        fail "sweep failed on a roster-bearing bead"

    grep -qx 'gc.routed_to=human' "$WORK/log" ||
        fail "a bead carrying eligible_validators/validation_barred_agent must route to human, not the pool -- a pool claim never consults the roster, so pool routing lets the barred agent claim the bead it is barred from validating"
    grep -q '^reopen_route_withheld=' "$WORK/log" ||
        fail "withholding the pool route must be recorded on the bead, not just decided"
    if grep -qx 'gc.routed_to=testrig/gastown.polecat' "$WORK/log"; then
        fail "an explicit --route overrode the roster check"
    fi

    # The roster itself is a standing contract, not a verdict -- it must survive.
    local after
    after=$(post_state "$WORK/roster.json")
    printf '%s' "$after" | jq -e 'has("eligible_validators") and has("validation_barred_agent")' >/dev/null ||
        fail "the validator roster was swept; it is the bead's standing contract, not a round disposition"
}

# 9. Every refusal path leaves the bead un-reopened, and a reopen whose sweep
#    failed is reported as its own state rather than as success.
test_failures_are_fail_closed() {
    local rc
    # Unreadable bead: refuse before touching anything.
    : >"$WORK/log"
    rc=0
    env -u GC_BIN \
        STUB_BEAD="/nonexistent/bead.json" STUB_LOG="$WORK/log" PATH="$WORK/bin:$PATH" \
        bash "$SWEEP" ml-cmai >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 1 ] || fail "unreadable bead must refuse with exit 1, got $rc"
    if grep -q 'CALL ' "$WORK/log"; then
        fail "refused run still called delete-source/reopen-source -- the refusal must come first"
    fi

    # No route resolvable and no pack context: refuse, do not guess.
    write_fixture "$WORK/bead.json"
    : >"$WORK/log"
    rc=0
    env -u GC_PACK_DIR -u GC_BIN STUB_BEAD="$WORK/bead.json" STUB_LOG="$WORK/log" PATH="$WORK/bin:$PATH" \
        bash "$SWEEP" ml-cmai >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 2 ] || fail "unresolvable route must refuse with exit 2, got $rc"
    if grep -q 'CALL ' "$WORK/log"; then
        fail "unroutable bead was reopened anyway -- it would land unclaimable"
    fi

    # A resolver that SUCCEEDS but yields nothing must not be trusted. Routing a
    # bead to "" leaves it exactly as unclaimable as never routing it, and the
    # exit status alone does not distinguish the two.
    mkdir -p "$WORK/emptypack/assets/scripts"
    printf '#!/bin/sh\nexit 0\n' >"$WORK/emptypack/assets/scripts/agent-address.sh"
    : >"$WORK/log"
    rc=0
    env -u GC_TEMPLATE -u GC_RIG -u GC_BIN \
        STUB_BEAD="$WORK/bead.json" STUB_LOG="$WORK/log" PATH="$WORK/bin:$PATH" \
        GC_PACK_DIR="$WORK/emptypack" GC_AGENT="testrig/gastown.slit" \
        bash "$SWEEP" ml-cmai >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 1 ] || fail "an empty resolved route must refuse with exit 1, got $rc"
    if grep -q 'CALL ' "$WORK/log"; then
        fail "bead was reopened with an empty route -- it would land unclaimable"
    fi

    # delete-source must GATE the reopen, not merely precede it. Reopening a bead
    # whose stale workflow subtree is still open re-races the steps being retired.
    : >"$WORK/log"
    rc=0
    env -u GC_TEMPLATE -u GC_RIG -u GC_BIN \
        STUB_BEAD="$WORK/bead.json" STUB_LOG="$WORK/log" PATH="$WORK/bin:$PATH" \
        STUB_DELETE_RC=1 \
        bash "$SWEEP" ml-cmai --route testrig/gastown.polecat >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 1 ] || fail "a failed delete-source must refuse with exit 1, got $rc"
    if grep -q 'CALL reopen-source' "$WORK/log"; then
        fail "reopen-source ran after delete-source failed -- the stale workflow subtree is still open and re-races the steps being retired"
    fi

    # Sweep update fails after a successful reopen: the one state to shout about.
    : >"$WORK/log"
    rc=0
    env -u GC_BIN \
        STUB_BEAD="$WORK/bead.json" STUB_LOG="$WORK/log" PATH="$WORK/bin:$PATH" STUB_UPDATE_RC=1 \
        bash "$SWEEP" ml-cmai --route testrig/gastown.polecat >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 3 ] ||
        fail "a reopen whose sweep failed must exit 3, not $rc -- it is neither success nor a clean refusal, and the bead is now advertising a stale disposition"

    # A dry run must never mutate.
    : >"$WORK/log"
    run_sweep "$WORK/bead.json" --route testrig/gastown.polecat --dry-run >/dev/null ||
        fail "dry run failed"
    [ ! -s "$WORK/log" ] || fail "dry run mutated the bead: $(tr '\n' ' ' <"$WORK/log")"
}

# 10. The command is reachable as `gc gastown reopen-source`. The sweep resolves
#     agent-address.sh through GC_PACK_DIR, which only `gc` sets, so without the
#     wrapper the self-routing form documented in every caller cannot run.
test_command_is_wired_up() {
    [ -r "$WRAPPER" ] || fail "missing command wrapper: $WRAPPER"
    [ -x "$WRAPPER" ] || fail "command wrapper is not executable: $WRAPPER"
    [ -r "$ROOT/gastown/commands/reopen-source/help.md" ] ||
        fail "missing help.md for gc gastown reopen-source"
    grep -q 'assets/scripts/reopen-source-sweep.sh' "$WRAPPER" ||
        fail "wrapper does not dispatch to the sweep script"

    # Missing pack context must be a refusal, not a silent no-op (gp-fid).
    local rc=0
    env -u GC_PACK_DIR -u GC_CITY_PATH sh "$WRAPPER" ml-cmai >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 2 ] || fail "wrapper without pack context must exit 2, got $rc"
}

test_reopened_bead_has_no_current_round_disposition
test_round_number_increments
test_values_round_trip_verbatim
test_round_durable_fields_are_not_swept
test_sweep_covers_every_refinery_disposition
test_sweep_and_route_are_one_atomic_update
test_validator_roster_bead_routes_to_human
test_failures_are_fail_closed
test_command_is_wired_up

echo "PASS: $(basename "${BASH_SOURCE[0]}")"
