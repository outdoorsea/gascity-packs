#!/usr/bin/env bash
# orphan-liveness-recheck.sh — is this assignee STILL absent, right now?
#
# Read-only. It measures one assignee against a freshly-read session roster,
# prints a verdict, and exits. It never resets a bead, never touches a worktree,
# and never mails — the witness's `recover-orphaned-beads` step owns those
# decisions, exactly as it owns them for the rest of the recovery recipe.
#
# ## The race it closes (gp-8m6)
#
# `recover-orphaned-beads` builds its assignee->state liveness map ONCE per
# cycle, "before the per-bead loop", and only then lists beads. Any session
# created between those two reads is missing from the map. The classification
# table resolves an unknown assignee to `absent`, and `absent` is treated as
# DEFINITIVE — "the owning session is gone and will never come back" — so step
# 3b resets that bead back into the pool.
#
# The map's freshness is therefore load-bearing for a destructive action, and it
# was a snapshot with no staleness check. Measured on the meety-local witness
# patrol of 2026-07-31T23:29-23:34Z:
#
#   * the cycle map held 18 sessions / 54 keys and did NOT contain
#     `gastown__polecat-gk-a9xk`;
#   * 23:33Z `gc gastown parked-check` found that session present and active;
#   * 23:34Z `gc gastown progress-check` found it holding bead `ml-0txz.4`,
#     in_progress, heartbeat age 1s, dirty=1 — UNCOMMITTED work.
#
# A live polecat holding unpublished work was invisible to a map built seconds
# earlier. That bead escaped only because it was not yet in_progress when the
# bead list was taken; reverse the ordering by a few seconds and the recipe
# resets an actively-worked bead out from under a running agent.
#
# The existing fail-safe does not cover this. It fires only on
# MAP_COUNT==0 && SESSION_COUNT>0 — the map-is-EMPTY case. A map that is
# non-empty but merely missing recently-spawned sessions passes it cleanly, and
# every unknown assignee still resolves to `absent`. This is the PARTIAL
# staleness case.
#
# ## Why a re-lookup rather than rebuilding the map
#
# Rebuilding the whole map per bead would re-run the same two listings for every
# assignee and still be a snapshot by the time it was used. What actually
# matters is the answer for the ONE assignee about to be acted on, read as late
# as possible. Cost in the common case is zero, because the common case is zero
# orphans and this script is never invoked.
#
# ## Why it can only ever withhold a reset
#
# This check never turns a `present` cycle-map classification into a reset — the
# witness calls it only for beads ALREADY classified orphaned. Its sole output
# is permission to proceed or a refusal, so the worst case of a probe that is
# narrower than the cycle map (see the two sources below) is that it agrees with
# today's behaviour. It cannot orphan anything the current recipe would not.
#
# ## Two sources, probed in cost order
#
# The cycle map keys on two listings: `gc session list` and the session BEADS
# (for `metadata.configured_named_identity`). This script probes the roster
# first and consults the session beads ONLY when the roster says absent — the
# extra query is spent exclusively on the path whose answer authorises a
# destructive reset, never on the path that is about to refuse one anyway.
#
# ## Output
#
#   verdict <TAB> assignee <TAB> state <TAB> source        (stdout, one row)
#
#   present      found in a fresh read, in a state the classification table
#                does NOT treat as orphaned — the cycle map was STALE. This is
#                the race, caught. FINDING.
#   terminal     found, but `archived`/`closed` — the orphan classification
#                holds, for a reason that was actually measured
#   absent       not found in either fresh source — the orphan classification
#                holds
#   unavailable  the roster could not be read (call failed, error envelope, or
#                schema drift) — NOTHING was measured
#
# ## Exit codes — note the polarity, it is deliberately NOT delivery-check's
#
#   0 = `absent` or `terminal`. The orphan classification was re-confirmed
#       against fresh data. The witness may proceed with salvage and reset.
#   1 = `present`. Live session. DO NOT salvage, DO NOT reset, skip this bead.
#   2 = `unavailable`. Nothing was measured, which is NOT a confirmation of
#       absence. DO NOT salvage, DO NOT reset, skip this bead.
#
# `gc gastown delivery-check` maps exit 2 onto "build as normal", because there
# the unsafe direction is halting a polecat over an unmeasured guess. Here the
# unsafe direction is the opposite one: proceeding destroys a live agent's
# uncommitted work. So an unmeasurable roster must NOT clear the way, and the
# plain shell idiom is the safe one — only exit 0 is green:
#
#     if gc gastown liveness-recheck "$ASSIGNEE"; then
#         ... salvage and reset ...
#     else
#         ... skip this bead this cycle ...
#     fi
#
# Env:
#   GASTOWN_RECHECK_SKIP_SESSION_BEADS=1   probe the roster only; treat a
#                                          roster miss as `absent` without
#                                          consulting session beads. For a city
#                                          whose session-bead listing is slow.
#                                          Narrower, never less safe.

set -euo pipefail

if [ "$#" -ne 1 ] || [ -z "${1:-}" ]; then
    echo "usage: gc gastown liveness-recheck <assignee>" >&2
    echo "  Re-resolves ONE assignee against a fresh session roster." >&2
    echo "  Exit 0 = re-confirmed gone (safe to recover), 1 = still live," >&2
    echo "  2 = not measured. Only exit 0 authorises a reset." >&2
    exit 2
fi

ASSIGNEE="$1"

emit() {
    printf 'verdict\tassignee\tstate\tsource\n' >&2
    printf '%s\t%s\t%s\t%s\n' "$1" "$ASSIGNEE" "$2" "$3"
}

# `--state=all` is not optional. The default listing hides asleep sessions, and
# `asleep` is one of the states the classification table explicitly treats as
# NOT orphaned — the controller still owns it. Reading the default listing would
# report a sleeping agent as absent and authorise the very reset this check
# exists to withhold.
if ! ROSTER=$(gc session list --state=all --json 2>/dev/null); then
    echo "orphan-liveness-recheck: 'gc session list --state=all --json' failed — liveness NOT measured for '$ASSIGNEE'" >&2
    emit unavailable - -
    exit 2
fi

# `gc` reports an unknown or failed command by printing an {"ok":false} envelope
# to STDOUT and exiting non-zero. The status guard above catches that today, but
# it is kept as a separate payload read for the reason spelled out in
# queue-starvation-check: the moment anyone reintroduces a pipe, the shell takes
# the status from the tail and a status-only guard stops seeing this.
if printf '%s' "$ROSTER" | jq -e '(type == "object") and (.ok == false)' >/dev/null 2>&1; then
    ROSTER_ERR=$(printf '%s' "$ROSTER" | jq -r '.error.message // "unknown error"' 2>/dev/null)
    echo "orphan-liveness-recheck: the roster command failed (${ROSTER_ERR}) — liveness NOT measured for '$ASSIGNEE'" >&2
    emit unavailable - -
    exit 2
fi

# `gc session list --json` returns an OBJECT with a `sessions` array (gc-3tn8g).
# Tolerate a bare top-level array, which shipped previously. Anything else is
# drift, and drift must not present as "no such session" — that reading is
# indistinguishable from a confirmed absence and would authorise a reset for
# every bead in the cycle.
if ! printf '%s' "$ROSTER" | jq -e '(type == "array") or (type == "object" and has("sessions"))' >/dev/null 2>&1; then
    echo "orphan-liveness-recheck: roster exposes no 'sessions' array — gc session list schema drifted; liveness NOT measured for '$ASSIGNEE'" >&2
    emit unavailable - -
    exit 2
fi

JQ_SESSIONS='def sessions_of: (.sessions? // .) | if type == "array" then . else [] end;'

# Resolve by EXACT identifier lookup across every form an assignee may take —
# never a regex or a fixed prefix list. Rig prefixes are configuration-derived,
# and an assignee may be a session bead ID, session name, alias, agent name, or
# a configured named identity. This mirrors the cycle map's own key set so the
# two agree on what "this assignee" means.
#
# `closed` is folded in here rather than left to the state string because a
# closed session is terminal regardless of the state it closed in.
if ! HIT=$(printf '%s' "$ROSTER" | jq -r "
    $JQ_SESSIONS
    sessions_of
    | map(select(
        (.id // \"\")           == \$a or
        (.name // \"\")         == \$a or
        (.session_name // \"\") == \$a or
        (.alias // \"\")        == \$a or
        (.agent_name // \"\")   == \$a))
    | if length == 0 then \"\"
      else (.[0] | if (.closed // false) then \"closed\" else ((.state // \"\") | if . == \"\" then \"unknown\" else . end) end)
      end" --arg a "$ASSIGNEE" 2>/dev/null); then
    echo "orphan-liveness-recheck: could not parse the session roster — liveness NOT measured for '$ASSIGNEE'" >&2
    emit unavailable - -
    exit 2
fi

# classify <state> — the classification table from `recover-orphaned-beads`,
# applied to a state string that was read seconds ago instead of at the top of
# the cycle. `archived`/`closed` are the only found-and-still-orphaned states;
# everything else the table names is a session the controller or operator still
# owns, and anything unrecognised is treated as live because that is the
# direction that cannot destroy work.
classify() {
    case "$1" in
        archived|closed) printf 'terminal' ;;
        *)               printf 'present' ;;
    esac
}

if [ -n "$HIT" ]; then
    VERDICT=$(classify "$HIT")
    emit "$VERDICT" "$HIT" session-list
    if [ "$VERDICT" = "present" ]; then
        exit 1
    fi
    exit 0
fi

# Roster miss. Before authorising a reset, consult the second source the cycle
# map keys on: session beads carrying `metadata.configured_named_identity`. An
# assignee written in that spelling is invisible to the roster lookup above, and
# a miss here is about to be read as proof the session is gone.
if [ "${GASTOWN_RECHECK_SKIP_SESSION_BEADS:-}" = "1" ]; then
    emit absent - session-list
    exit 0
fi

if ! SESSION_BEADS=$(gc bd list --type=session --label=gc:session --include-infra --include-gates --all --json --limit=0 2>/dev/null </dev/null); then
    echo "orphan-liveness-recheck: the session-bead listing failed — '$ASSIGNEE' is unconfirmed, NOT confirmed absent" >&2
    emit unavailable - -
    exit 2
fi

if printf '%s' "$SESSION_BEADS" | jq -e '(type == "object") and (.ok == false)' >/dev/null 2>&1; then
    BEADS_ERR=$(printf '%s' "$SESSION_BEADS" | jq -r '.error.message // "unknown error"' 2>/dev/null)
    echo "orphan-liveness-recheck: the session-bead listing failed (${BEADS_ERR}) — '$ASSIGNEE' is unconfirmed, NOT confirmed absent" >&2
    emit unavailable - -
    exit 2
fi

# Top-level array is the shape the cycle map's `$session_beads[0] // []` reads.
# An object carrying `issues` is tolerated; anything else is drift and must not
# read as "no such identity".
if ! printf '%s' "$SESSION_BEADS" | jq -e '(type == "array") or (type == "object" and has("issues"))' >/dev/null 2>&1; then
    echo "orphan-liveness-recheck: the session-bead listing exposes no array — schema drifted; '$ASSIGNEE' is unconfirmed, NOT confirmed absent" >&2
    emit unavailable - -
    exit 2
fi

if ! BEAD_HIT=$(printf '%s' "$SESSION_BEADS" | jq -r '
    def beads_of: (.issues? // .) | if type == "array" then . else [] end;
    beads_of
    | map(select((.metadata.configured_named_identity // "") == $a))
    | if length == 0 then ""
      else (.[0] | if (.status == "closed") then "closed" else ((.metadata.state // "") | if . == "" then "unknown" else . end) end)
      end' --arg a "$ASSIGNEE" 2>/dev/null); then
    echo "orphan-liveness-recheck: could not parse the session-bead listing — '$ASSIGNEE' is unconfirmed, NOT confirmed absent" >&2
    emit unavailable - -
    exit 2
fi

if [ -n "$BEAD_HIT" ]; then
    VERDICT=$(classify "$BEAD_HIT")
    emit "$VERDICT" "$BEAD_HIT" session-beads
    if [ "$VERDICT" = "present" ]; then
        exit 1
    fi
    exit 0
fi

emit absent - session-beads
exit 0
