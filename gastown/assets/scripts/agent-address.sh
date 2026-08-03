#!/usr/bin/env bash
# agent-address.sh — resolve the address of a sibling agent in THIS rig, and
# refuse to answer rather than return one nobody answers to.
#
# The gap it closes (gp-0fz): a polecat hands work off by writing the refinery's
# address into `assignee`. That address is composed in the formula as
#
#     "${GC_RIG:+$GC_RIG/}{{binding_prefix}}refinery"
#
# and `{{binding_prefix}}` is substituted at pour time. When that substitution
# yields empty, the composed address degrades to `<rig>/refinery` — which is not
# the refinery. The real agent is `<rig>/gastown.refinery`, because the import is
# bound as `[rigs.imports.gastown]` in city.toml. Nothing rejects the bad write:
#
#   * `gc bd update --assignee=<anything>` accepts any string. There is no
#     referential integrity between a bead's assignee and the agent roster.
#   * the refinery's assigned-work scan queries `--assignee=$GC_AGENT`, i.e.
#     `<rig>/gastown.refinery` — no match.
#   * the routed-orphan scan keys on `gc.routed_to`, which the handoff correctly
#     clears — no match.
#
# So the bead reads healthy in every listing (open, branch pushed, target set)
# while generating zero demand and no wake signal. A misspelled address is
# precisely the case where no fallback fires. Observed across three sessions in
# two rigs; ml-z2z dwelled ~6h before a human noticed.
#
# The fix rests on an observation: the polecat already knows the binding prefix,
# because it is in its OWN address. A session running as
# `gascity-packs/gastown.furiosa` is bound under `gastown.` by construction —
# the same city.toml import that names its sibling refinery named it. Self is
# therefore a ground truth that needs no template substitution, no daemon, and
# no network: whatever `{{binding_prefix}}` was supposed to render, self already
# carries it.
#
# Two independent signals, and the caller is told when they disagree:
#
#   SELF     split $GC_AGENT (or $GC_TEMPLATE) into rig + binding prefix, then
#            recompose with the requested role. Always available — it is
#            environment, not state.
#   ROSTER   `gc agent list --json` .agents[].qualified_name — the set of agent
#            addresses city.toml actually defines. Config-derived, so it lists
#            agents that have never started a session. This is the check the
#            bead write itself does not do.
#
# Disagreement is never silently reconciled. A candidate that loses to SELF is
# reported on stderr, because a wrong candidate means the substitution is still
# broken upstream and that must stay visible after this script repairs the
# symptom.
#
# The CANDIDATE is never a fallback (gp-d23). It is only ever ACCEPTED when the
# roster confirms it, never merely because it looks well-formed. The candidate is
# the value under suspicion — the caller supplies it precisely so it can be
# checked — so trusting it when nothing can check it would make this resolver
# most permissive exactly where its evidence is weakest. When the roster is
# unreadable, SELF is the only thing that can carry a resolution, because SELF is
# derived from an identity the runtime had to get right for the session to exist.
# With no roster AND no self identity, there is nothing to stand on: REFUSE.
# gp-qmd is what accepting a shaped-but-unverified candidate actually costs — a
# bead written to `gascity-packs/refinery` (no binding prefix), invisible to both
# refinery discovery paths, stranded ~2h until a human repaired it by hand.
#
# Usage:
#   agent-address.sh <role> [--candidate <addr>] [--quiet]
#
#   <role>        sibling role to address: refinery, witness, polecat, ...
#   --candidate   the address the caller composed (i.e. what the template
#                 rendered). Optional. Supplying it is what lets this script
#                 detect and report a failed substitution instead of merely
#                 routing around it.
#   --quiet       suppress advisory stderr; refusals still print.
#
# Output: the resolved address on stdout, one line, no trailing commentary.
#         Advisories and refusals go to stderr.
#
# Exit codes:
#   0  resolved — stdout holds an address safe to write.
#   1  REFUSED — no trustworthy address. The caller MUST NOT write an assignee.
#      Writing one anyway is the bug this script exists to prevent.
#   2  could not run (bad arguments). Also a refusal: nothing was evaluated.
#
# Env:
#   GC_AGENT     this session's own address, e.g. gascity-packs/gastown.furiosa
#   GC_TEMPLATE  this session's pool template, e.g. gascity-packs/gastown.polecat
#   GC_RIG       rig name; used only to sanity-check the rig SELF derived
#   GC_BIN       gc binary (default: gc on PATH)

set -uo pipefail

ROLE=""
CANDIDATE=""
QUIET=0

while [ $# -gt 0 ]; do
    case "$1" in
        --candidate)
            [ $# -ge 2 ] || { echo "agent-address: --candidate needs a value" >&2; exit 2; }
            CANDIDATE="$2"
            shift 2
            ;;
        --candidate=*)
            CANDIDATE="${1#--candidate=}"
            shift
            ;;
        --quiet)
            QUIET=1
            shift
            ;;
        -h|--help)
            # Print the whole leading comment block, however long it is. This
            # was a hardcoded `sed -n '2,70p'`, which silently truncated the
            # moment anything was added above line 70 — and that is exactly what
            # happened when this header grew (gp-d23): `Output`, `Exit codes`
            # and `Env` all dropped out of `--help` at once. Losing `Exit codes`
            # is the worst of those, because "1 = REFUSED, do not write an
            # assignee" IS this script's contract. Ending at the first
            # non-comment line keeps help and header in sync by construction.
            awk 'NR < 2 { next } /^#/ { print; next } { exit }' "$0"
            exit 0
            ;;
        -*)
            echo "agent-address: unknown flag: $1" >&2
            exit 2
            ;;
        *)
            [ -z "$ROLE" ] || { echo "agent-address: unexpected argument: $1" >&2; exit 2; }
            ROLE="$1"
            shift
            ;;
    esac
done

if [ -z "$ROLE" ]; then
    echo "agent-address: a role is required (refinery, witness, polecat, ...)" >&2
    exit 2
fi

GC="${GC_BIN:-gc}"

note() {
    [ "$QUIET" -eq 1 ] || echo "agent-address: $*" >&2
}

# Split an address into rig / binding-prefix / role.
#
#   gascity-packs/gastown.furiosa  ->  rig=gascity-packs  prefix=gastown.  role=furiosa
#   gastown.mayor                  ->  rig=              prefix=gastown.  role=mayor
#   meety-local/chuck              ->  rig=meety-local   prefix=          role=chuck
#
# The prefix is everything up to and INCLUDING the last dot of the local part,
# so a multi-segment binding (`a.b.polecat`) keeps its full prefix `a.b.`. An
# unbound agent has no dot and an empty prefix, which is legitimate — this
# script does not assume every city binds its imports.
addr_rig() {
    case "$1" in
        */*) printf '%s' "${1%%/*}" ;;
        *)   printf '' ;;
    esac
}

addr_local() {
    case "$1" in
        */*) printf '%s' "${1#*/}" ;;
        *)   printf '%s' "$1" ;;
    esac
}

addr_prefix() {
    local local_part
    local_part="$(addr_local "$1")"
    case "$local_part" in
        *.*) printf '%s.' "${local_part%.*}" ;;
        *)   printf '' ;;
    esac
}

compose() {
    # compose <rig> <prefix> <role>
    printf '%s%s%s' "${1:+$1/}" "$2" "$3"
}

# An address is structurally sound if it could name a real agent. This rejects
# exactly the shapes a failed substitution produces: an unrendered `{{...}}`, a
# leading slash from an empty rig, or an empty local part.
structurally_sound() {
    local addr="$1"
    [ -n "$addr" ] || return 1
    case "$addr" in
        *'{{'*|*'}}'*) return 1 ;;   # template never rendered
        /*)            return 1 ;;   # empty rig prefix -> "/gastown.refinery"
        */)            return 1 ;;   # empty local part
    esac
    [ -n "$(addr_local "$addr")" ] || return 1
    return 0
}

# --- SELF ------------------------------------------------------------------
# Prefer GC_AGENT (this session's real address). GC_TEMPLATE is the pool
# template and carries the same binding, so it is an equally good source of the
# prefix and a fine fallback.
SELF_ADDR=""
for candidate_self in "${GC_AGENT:-}" "${GC_TEMPLATE:-}"; do
    if [ -n "$candidate_self" ]; then
        SELF_ADDR="$candidate_self"
        break
    fi
done

DERIVED=""
if [ -n "$SELF_ADDR" ]; then
    SELF_RIG="$(addr_rig "$SELF_ADDR")"
    SELF_PREFIX="$(addr_prefix "$SELF_ADDR")"
    # GC_RIG wins over the rig parsed out of self when both are set: a session
    # address is not guaranteed to be rig-qualified, but GC_RIG names the rig
    # whose roster and beads this handoff belongs to.
    DERIVED="$(compose "${GC_RIG:-$SELF_RIG}" "$SELF_PREFIX" "$ROLE")"
fi

# --- ROSTER ----------------------------------------------------------------
# The set of addresses city.toml actually defines. Unreadable is not the same
# as empty: a daemon blip must not be allowed to condemn a correct address, so
# an unreadable roster downgrades to "unverified" rather than to a refusal.
ROSTER=""
ROSTER_OK=0
if ROSTER="$("$GC" agent list --json 2>/dev/null | jq -r '.agents[]?.qualified_name // empty' 2>/dev/null)" \
   && [ -n "$ROSTER" ]; then
    ROSTER_OK=1
fi

in_roster() {
    [ "$ROSTER_OK" -eq 1 ] || return 1
    printf '%s\n' "$ROSTER" | grep -Fxq -- "$1"
}

# --- resolve ---------------------------------------------------------------
# SELF is tried first and the candidate second. That order is deliberate: the
# candidate is the value under suspicion — it is the thing that was observed to
# be wrong — while SELF is derived from an identity the runtime had to get right
# for this session to exist at all.
RESOLVED=""
RESOLVED_VIA=""

if [ -n "$DERIVED" ] && in_roster "$DERIVED"; then
    RESOLVED="$DERIVED"
    RESOLVED_VIA="self+roster"
elif [ -n "$CANDIDATE" ] && in_roster "$CANDIDATE"; then
    # SELF lost to the roster. Trust the roster — it is the definition.
    RESOLVED="$CANDIDATE"
    RESOLVED_VIA="candidate+roster"
elif [ "$ROSTER_OK" -eq 1 ]; then
    echo "agent-address: REFUSED — no known agent for role '$ROLE' in rig '${GC_RIG:-<none>}'." >&2
    echo "  self-derived: ${DERIVED:-<could not derive: GC_AGENT and GC_TEMPLATE both unset>}" >&2
    echo "  candidate:    ${CANDIDATE:-<none supplied>}" >&2
    echo "  Known agent addresses matching '$ROLE':" >&2
    printf '%s\n' "$ROSTER" | grep -F -- "$ROLE" | sed 's/^/    /' >&2 || echo "    (none)" >&2
    echo "  Do NOT write an assignee. A bead assigned to an address no agent" >&2
    echo "  answers to is invisible to every discovery path and strands silently." >&2
    exit 1
elif [ -n "$DERIVED" ] && structurally_sound "$DERIVED"; then
    # Roster unreadable. SELF still stands on its own — it was built from this
    # session's own identity, not from the template under suspicion.
    RESOLVED="$DERIVED"
    RESOLVED_VIA="self (roster unavailable — unverified)"
else
    # There is deliberately NO branch here that accepts an unverified CANDIDATE
    # (gp-d23). Falling back to the candidate when the roster cannot be read
    # inverts the evidence ladder: the branch above refuses when the roster IS
    # readable and disagrees, so accepting one when nothing can be checked at
    # all makes the resolver most permissive exactly where it knows least.
    #
    # `structurally_sound` cannot stand in for the roster here, by construction.
    # It rejects the shapes a substitution failure produces — an unrendered
    # `{{...}}`, a leading `/`, an empty local part — i.e. templates that failed
    # to render. `gascity-packs/refinery` is a template that rendered
    # SUCCESSFULLY TO THE WRONG VALUE: no braces, no empty part, so it passes
    # every structural check. Only the roster distinguishes it from the
    # legitimate bare address of a city that binds nothing, and making the shape
    # check binding-aware (say, requiring a dot) would false-refuse those cities.
    #
    # Refusing is the safe outcome, not a regression. mol-polecat-work's
    # submit-and-exit halts on a non-zero resolver, leaving the bead in_progress
    # and assigned to the live session — the state that formula documents as
    # recoverable, and which also mails the witness. The alternative this
    # replaces wrote an address no agent answers to, which is invisible to every
    # discovery path and strands silently (gp-qmd dwelled ~2h before a human
    # repaired it by hand).
    echo "agent-address: REFUSED — cannot resolve role '$ROLE'." >&2
    echo "  roster:       unreadable ($GC agent list --json)" >&2
    echo "  self-derived: ${DERIVED:-<could not derive: GC_AGENT and GC_TEMPLATE both unset>}" >&2
    echo "  candidate:    ${CANDIDATE:-<none supplied>}" >&2
    if [ -n "$CANDIDATE" ] && structurally_sound "$CANDIDATE"; then
        echo "  The candidate is address-SHAPED, but shape is not evidence: a template" >&2
        echo "  that renders to the wrong value looks identical to a correct one. With" >&2
        echo "  no roster to check it against and no self identity to derive from," >&2
        echo "  nothing here can tell them apart." >&2
    fi
    echo "  Do NOT write an assignee. A bead assigned to an address no agent" >&2
    echo "  answers to is invisible to every discovery path and strands silently." >&2
    exit 1
fi

# Report a losing candidate. The repair below is a symptom fix; the cause is a
# substitution that rendered wrong, and it stays broken for every OTHER call
# site until someone sees this line.
if [ -n "$CANDIDATE" ] && [ "$CANDIDATE" != "$RESOLVED" ]; then
    note "SUBSTITUTION FAILED — caller composed '$CANDIDATE', which is not the"
    note "  address of any '$ROLE' in this rig. Using '$RESOLVED' (via $RESOLVED_VIA)."
    note "  The composed value is wrong at its source; this run was repaired, but"
    note "  every unrepaired call site composing it the same way is still stranding work."
else
    # Always narrate the agreeing case too. It is one stderr line on the happy
    # path, and it is the line an operator wants in the log when a bead turns up
    # stranded later — it says which address was written and how much was known
    # about it, including whether the roster could be consulted at all.
    note "resolved '$ROLE' to '$RESOLVED' (via $RESOLVED_VIA)"
fi

printf '%s\n' "$RESOLVED"
