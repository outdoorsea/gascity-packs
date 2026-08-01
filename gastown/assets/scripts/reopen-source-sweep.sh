#!/usr/bin/env bash
# reopen-source-sweep.sh — reopen a source bead for a NEW round, and leave
# nothing from the previous round readable as current state.
#
# The gap it closes (gp-8r1): `gc workflow reopen-source` reopens a bead and
# clears its assignee. It clears nothing else. A bead reopened for round 2
# therefore still carries round 1's refinery verdict in the CURRENT-round keys,
# and anything that reads them concludes the bead is already dispositioned:
#
#     merge_result            = no_patch_needs_human
#     no_patch_verified       = "...confirmed zero-diff vs origin/main..."
#     no_code_change          = true
#     no_code_change_evidence = "...verdict=fail, recorded 2026-07-31T19:18:04Z"
#     work_dir                = .../polecats/<some other agent>/worktrees/<bead>
#
# Every one of those was true of round 1 and false of round 2, which had no
# verdict at all. Zero-diff is ALSO the expected shape of a legitimately passing
# validation bead, so "already dispositioned, empty branch is correct, nothing
# to do" is the PLAUSIBLE reading — which is how this closes a P0 criterion
# without validating it. Observed live on ml-cmai (PRD #261 crit:8d5572e9cf37).
#
# The staleness is not only the verdict. The CLAIM IDENTITY survives too, and
# it is the more dangerous half. ml-cmai was reassigned to one agent while still
# carrying `gc.session_id`/`gc.session_name` of a confirmed-dead session and a
# `gc.work_dir` pointing into the worktree of `gastown.nux` — the very agent
# that bead's own `validation_barred_agent` BARS from validating it. Anything
# resolving a working directory from `gc.work_dir` pre-claim lands inside the
# barred agent's worktree. That is a separation-of-duties bypass, not drift.
#
# WHY THIS IS ONE COMMAND AND NOT A RULE CALLERS FOLLOW
#
# The refinery's write is correct: it records an accurate, atomic disposition at
# a moment when no future reopen is knowable, and `merge_result` alone has nine
# write sites in mol-refinery-patrol.toml. Namespacing at write time is both
# impossible (the refinery has no round number) and a permanent tax on every
# future disposition field. Reopen is the ONE actor that knows a round boundary
# is being crossed — it already sweeps the assignee for exactly that reason.
# Clearing the assignee but not the disposition is an inconsistent half-sweep.
#
# Pushing the obligation onto callers has already failed once in this exact
# spot. `reopen-source` also does not route, so `gc.routed_to` was made a caller
# duty and then policed by gastown/tests/test_pool_return_routing.sh — a test
# that exists because callers forget. On ml-cmai the ENFORCED lesson took
# (routing was set) and the unenforced one did not (the whole round-1
# disposition survived). Same bead, same reopen, same operator. So routing is
# folded in here too, and the test now enforces an invariant this command
# upholds itself rather than compensating for one it does not.
#
# Usage:
#   reopen-source-sweep.sh <bead-id> [--route <addr>] [--dry-run]
#
#   <bead-id>   the source bead to reopen for a new round
#   --route     pool address to route to. Optional, and normally omitted:
#               the route is self-derived via agent-address.sh from $GC_AGENT,
#               which is environment rather than template substitution and so
#               cannot render empty the way "${GC_RIG:+$GC_RIG/}{{binding_prefix}}polecat"
#               can (gp-0fz). Pass it only to override the derived pool.
#   --dry-run   print the planned sweep and exit without touching the bead.
#
# Output: a TSV plan on stdout, one row per field moved, then a ROUTE row.
#         Commentary and refusals go to stderr.
#
#   move  <TAB> <field>            <TAB> round<N>.<field>
#   route <TAB> gc.routed_to       <TAB> <addr>
#
# Exit codes:
#   0  reopened and swept.
#   1  REFUSED — nothing was reopened. Preconditions failed (unreadable bead,
#      unresolvable route, delete-source/reopen-source failed).
#   2  could not run (bad arguments, missing pack context, no jq).
#   3  REOPENED BUT NOT SWEPT — the reopen succeeded and the follow-up sweep
#      did not. This is the one state this script exists to prevent, so it is
#      reported as its own code with the exact recovery command on stderr.
#      Never treat a 3 as success; the bead is now carrying a stale disposition.

set -uo pipefail

BEAD=""
ROUTE=""
DRY_RUN=0

die() {
    local code="$1"
    shift
    echo "reopen-source-sweep: $*" >&2
    exit "$code"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --route)
            [ $# -ge 2 ] || die 2 "--route needs a value"
            ROUTE="$2"
            shift 2
            ;;
        --route=*)
            ROUTE="${1#--route=}"
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            sed -n '2,80p' "$0"
            exit 0
            ;;
        -*)
            die 2 "unknown flag: $1"
            ;;
        *)
            [ -z "$BEAD" ] || die 2 "unexpected argument: $1"
            BEAD="$1"
            shift
            ;;
    esac
done

[ -n "$BEAD" ] || die 2 "usage: reopen-source-sweep.sh <bead-id> [--route <addr>] [--dry-run]"
command -v jq >/dev/null 2>&1 || die 2 "jq is required to read and re-inject metadata"

# Fields whose value describes THE ROUND THAT JUST ENDED. Left in place they
# read as the current round's answer, which is the defect.
#
# Two classes, both named in the gp-8r1 ruling:
#
#   verdict   what the refinery (or a polecat halt) concluded about the patch.
#   identity  which session claimed the bead and where it worked. Stale identity
#             is the separation-of-duties vector, so it sweeps with the verdict.
#
# Deliberately NOT swept, because each survives a round boundary honestly:
#
#   branch, fork_sha, target   the artifact the next round RESUMES. The refinery
#                              explicitly keeps the branch on reject so a new
#                              polecat can resolve the conflict.
#   rejection_reason           written AFTER reopen as the next round's
#                              instruction. It is round-N input, not round-N-1
#                              output.
#   pr_url, pr_number,         a PR is a durable external artifact that outlives
#   existing_pr                the round. Sweeping these makes round 2 open a
#                              SECOND PR for the same bead.
#   recovered,                 cross-round counters. The witness reads
#   parked_reset_count,        `recovered` precisely to detect a crash LOOP, so
#   parked_reset_at            namespacing it per round destroys the signal.
#   eligible_validators,       the standing contract on the bead, not a verdict.
#   validation_barred_agent    See the route reconciliation below.
#   gc.work_branch             the rig's base branch (a gc-core session stamp),
#                              not claim identity. `gc.work_dir` is the agent
#                              home; `gc.work_branch` is NOT the branch checked
#                              out in it, so it says nothing about the round.
SWEEP_FIELDS=(
    merge_result
    merged_sha
    merged_target
    no_patch_verified
    no_code_change
    no_code_change_evidence
    no_code_change_source
    no_code_change_cleared
    false_completion_suspected
    blocked_reason
    already_delivered_suspected
    awaiting_merge
    awaiting_merge_since
    awaiting_merge_since_epoch
    awaiting_merge_stale
    branch_ready
    halt_reason
    work_dir
    gc.session_id
    gc.session_name
    gc.work_dir
    polecat_session
)

read_metadata() {
    local json
    json=$(gc bd show "$BEAD" --json 2>/dev/null) || return 1
    # An id must come back, or we read an empty result and would sweep nothing
    # while reporting success -- the silence-that-reads-as-data failure.
    printf '%s' "$json" | jq -e '.[0].id' >/dev/null 2>&1 || return 1
    printf '%s' "$json" | jq -c '.[0].metadata // {}'
}

# Read with retry. An unreadable bead is transient far more often than it is
# terminal, and treating a blip as "no fields to sweep" would silently produce
# exactly the half-swept bead this script exists to prevent.
read_metadata_retrying() {
    local try=0 meta
    while [ "$try" -lt 3 ]; do
        try=$((try + 1))
        if meta=$(read_metadata); then
            printf '%s' "$meta"
            return 0
        fi
        sleep 1
    done
    return 1
}

META=$(read_metadata_retrying) ||
    die 1 "cannot read $BEAD after retries; refusing to reopen a bead whose prior round cannot be swept"

# Next round number: one past the highest already parked on the bead, so a
# second reopen produces round2.* without overwriting round1.*.
NEXT_ROUND=$(printf '%s' "$META" |
    jq -r '[keys_unsorted[] | capture("^round(?<n>[0-9]+)\\.") | .n | tonumber] | (max // 0) + 1') ||
    die 1 "cannot derive the next round number for $BEAD"

# Route reconciliation. A bead carrying a validator roster enforces separation
# of duties through its ASSIGNEE and nothing else -- a pool claim never consults
# `eligible_validators`. reopen-source clears that assignee, so pool-routing the
# bead here would hand the barred agent a clean path to claim the very bead it
# is barred from validating. gp-8r1's notes call this out as load-bearing
# behaviour nobody declared. Fail closed to a human instead of guessing which
# validator should get it: picking one is a policy call, not a sweep.
BARRED=$(printf '%s' "$META" | jq -r '(.validation_barred_agent // "") | tostring')
ELIGIBLE=$(printf '%s' "$META" | jq -r '(.eligible_validators // "") | tostring')
ROUTE_WITHHELD=""

if [ -n "$BARRED" ] || [ -n "$ELIGIBLE" ]; then
    if [ -n "$ROUTE" ]; then
        echo "reopen-source-sweep: $BEAD carries a validator roster (eligible=${ELIGIBLE:-none} barred=${BARRED:-none}); --route $ROUTE ignored" >&2
    fi
    ROUTE_WITHHELD="validator roster present (eligible=${ELIGIBLE:-none} barred=${BARRED:-none}); pool routing would let the barred agent claim it"
    ROUTE="human"
    echo "reopen-source-sweep: routing $BEAD to human, not the pool -- $ROUTE_WITHHELD" >&2
elif [ -z "$ROUTE" ]; then
    # Self-derived from $GC_AGENT, so the caller has no routing obligation to
    # forget. This is the half of the fix that retires the caller-pairing rule.
    ADDR_SCRIPT="${GC_PACK_DIR:-}/assets/scripts/agent-address.sh"
    [ -r "$ADDR_SCRIPT" ] ||
        die 2 "cannot locate agent-address.sh (GC_PACK_DIR unset?); run this as 'gc gastown reopen-source <bead>' or pass --route"
    ROUTE=$(bash "$ADDR_SCRIPT" polecat --quiet) ||
        die 1 "cannot resolve the polecat pool address for $BEAD; refusing to reopen a bead that would land unroutable"
fi

[ -n "$ROUTE" ] || die 1 "empty route for $BEAD; refusing to reopen a bead that would land unroutable"

# Build the plan. Values are read back and re-injected verbatim rather than
# retyped: `--set-metadata key=value` splits on the FIRST `=` only, so evidence
# strings containing `verdict=fail` round-trip safely.
UPDATE_ARGS=()
MOVED=0
for field in "${SWEEP_FIELDS[@]}"; do
    value=$(printf '%s' "$META" |
        jq -r --arg k "$field" 'if has($k) then (.[$k] | if type == "string" then . else tojson end) else empty end')
    # Absent AND empty-string both skip, deliberately. An empty value asserts
    # nothing about the round that just ended, so parking it would manufacture a
    # `round<N>.merge_result=` that reads like a recorded verdict, and there is
    # nothing to preserve by moving it. The defect is a field that SAYS
    # something stale, not a field that is present and silent.
    [ -n "$value" ] || continue
    UPDATE_ARGS+=(--set-metadata "round${NEXT_ROUND}.${field}=${value}")
    UPDATE_ARGS+=(--unset-metadata "$field")
    MOVED=$((MOVED + 1))
    printf 'move\t%s\tround%s.%s\n' "$field" "$NEXT_ROUND" "$field"
done

# Assert the post-condition rather than inheriting it. `gc workflow
# reopen-source` is expected to reopen and unassign, but every caller this
# replaces ALSO wrote `--status=open --assignee=""` explicitly, and none of them
# documented whether that was redundancy or a real backstop. Restating it here
# is idempotent, costs one flag each, and makes the guarantee this command
# offers -- open, unassigned, routed, swept -- true by construction instead of
# by trust in another command's internals. A caller that dropped the pair on
# migration must not silently get a weaker outcome than it had before.
UPDATE_ARGS+=(--status=open --assignee="")

UPDATE_ARGS+=(--set-metadata "gc.routed_to=$ROUTE")
printf 'route\tgc.routed_to\t%s\n' "$ROUTE"

if [ -n "$ROUTE_WITHHELD" ]; then
    UPDATE_ARGS+=(--set-metadata "reopen_route_withheld=$ROUTE_WITHHELD")
    printf 'route\treopen_route_withheld\t%s\n' "$ROUTE_WITHHELD"
fi

if [ "$DRY_RUN" -eq 1 ]; then
    echo "reopen-source-sweep: dry run -- $BEAD not modified ($MOVED field(s) would move to round${NEXT_ROUND}.*)" >&2
    exit 0
fi

# Reopen through gc core. delete-source first, and only reopen if it succeeded:
# reopening a bead whose stale workflow subtree is still open re-races the very
# steps being retired.
gc workflow delete-source "$BEAD" --apply ||
    die 1 "delete-source failed for $BEAD; nothing reopened"
gc workflow reopen-source "$BEAD" ||
    die 1 "reopen-source failed for $BEAD; nothing swept"

# One update, not several. Splitting the namespacing from the routing leaves a
# crash window in which the bead is open, unassigned, and either unroutable or
# still advertising the previous round's verdict -- both of which are the bug.
if ! gc bd update "$BEAD" "${UPDATE_ARGS[@]}"; then
    {
        echo "reopen-source-sweep: $BEAD WAS REOPENED BUT NOT SWEPT."
        echo "  It is now open and carrying round $((NEXT_ROUND - 1))'s disposition as current state."
        echo "  Re-run the sweep by hand before letting anything claim it:"
        echo "    gc bd update $BEAD ${UPDATE_ARGS[*]}"
    } >&2
    exit 3
fi

echo "reopen-source-sweep: $BEAD reopened for round $NEXT_ROUND -- $MOVED field(s) parked under round${NEXT_ROUND}.*, routed to $ROUTE" >&2
exit 0
