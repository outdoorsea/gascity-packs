#!/bin/sh
# gastown reopen-source — reopen a source bead for a NEW round, and leave
# nothing from the previous round readable as current state.
# Invoked as: gc gastown reopen-source <bead-id> [--route <addr>] [--dry-run]
#
# This wrapper exists for the same reason delivery-check's does: path
# resolution. The sweep lives in assets/scripts/reopen-source-sweep.sh and needs
# a sibling from that same directory — assets/scripts/agent-address.sh, which is
# how it self-derives the pool address instead of making the caller supply one.
# Both are found through GC_PACK_DIR, and GC_PACK_DIR is set only when `gc`
# invokes a pack command. It is NOT part of an agent session's environment, so
# `gc gastown reopen-source` is the only invocation that can locate the pair
# without hardcoding the content-addressed pack cache path (gp-fid).
#
# Callers should prefer this over the raw `gc workflow delete-source <bead>
# --apply && gc workflow reopen-source <bead>` pair. That pair reopens and
# unassigns, and does nothing else: the previous round's merge disposition and
# claim identity survive into the new round as CURRENT state, and the bead lands
# unrouted unless the caller remembers to route it. This command does both, so
# the caller has nothing left to forget (gp-8r1).
#
# Environment (set by gc):
#   GC_CITY_PATH   — absolute city root
#   GC_PACK_DIR    — absolute pack directory
#   GC_PACK_NAME   — pack name ("gastown")
#   GC_CITY_NAME   — city workspace name
#
# Exit codes are the underlying script's, passed through unchanged:
#   0  reopened and swept.
#   1  REFUSED — nothing was reopened (unreadable bead, unresolvable route, or
#      delete-source/reopen-source itself failed).
#   2  could not run (bad arguments, missing pack context, no jq).
#   3  REOPENED BUT NOT SWEPT — the reopen landed and the sweep did not. This is
#      the one state the command exists to prevent, so it gets its own code and
#      prints the exact recovery command. Never read a 3 as success: the bead is
#      open and advertising the previous round's verdict.

set -eu

if [ -z "${GC_CITY_PATH:-}" ] || [ -z "${GC_PACK_DIR:-}" ]; then
    echo "gc gastown reopen-source: missing Gas City pack context" >&2
    echo "  Run this as 'gc gastown reopen-source <bead-id>' — invoking run.sh" >&2
    echo "  directly leaves GC_PACK_DIR unset and the sweep cannot locate" >&2
    echo "  agent-address.sh to resolve the pool route." >&2
    exit 2
fi

SWEEP="$GC_PACK_DIR/assets/scripts/reopen-source-sweep.sh"

if [ ! -r "$SWEEP" ]; then
    echo "gc gastown reopen-source: $SWEEP not found in this pack version" >&2
    exit 2
fi

exec bash "$SWEEP" "$@"
