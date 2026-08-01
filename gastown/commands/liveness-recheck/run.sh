#!/bin/sh
# gastown liveness-recheck — re-resolve ONE assignee against a fresh session
# roster, immediately before the witness acts on a bead it classified orphaned.
# Invoked as: gc gastown liveness-recheck <assignee>
#
# This wrapper exists for one reason: path resolution. The check itself lives in
# assets/scripts/orphan-liveness-recheck.sh, but its caller is the witness's
# `recover-orphaned-beads` patrol step, which runs in a plain agent session
# where GC_PACK_DIR is NOT set. It is set by `gc` when `gc` invokes a pack
# command, which makes `gc gastown liveness-recheck` the only invocation that
# can locate the check without hardcoding the content-addressed pack cache path.
# A formula that reads "$GC_PACK_DIR/assets/scripts/..." directly resolves to
# "/assets/scripts/..." in an agent shell and silently measures nothing — the
# same defect usage-stamp and delivery-check were routed through `gc` to fix
# (gp-fid). For this check that failure would be worse than usual: it would read
# as "could not run", and the caller must treat that as a refusal to reset.
#
# Environment (set by gc):
#   GC_CITY_PATH   — absolute city root
#   GC_PACK_DIR    — absolute pack directory
#   GC_PACK_NAME   — pack name ("gastown")
#   GC_CITY_NAME   — city workspace name
#
# Exit codes are the underlying check's, passed through unchanged:
#   0 = re-confirmed gone (`absent` or `terminal`) — recovery may proceed
#   1 = still live (`present`) — the cycle map was stale; do NOT reset the bead
#   2 = the check could not run — nothing was measured, which is NOT a
#       confirmation of absence; do NOT reset the bead
#
# Note the polarity against `gc gastown delivery-check`, where exit 2 means
# "proceed anyway". It is inverted here on purpose: proceeding on an unmeasured
# roster destroys a running agent's uncommitted work.

set -eu

if [ -z "${GC_CITY_PATH:-}" ] || [ -z "${GC_PACK_DIR:-}" ]; then
    echo "gc gastown liveness-recheck: missing Gas City pack context" >&2
    echo "  Run this as 'gc gastown liveness-recheck' — invoking run.sh directly" >&2
    echo "  leaves GC_PACK_DIR unset and the check cannot locate itself." >&2
    exit 2
fi

CHECK="$GC_PACK_DIR/assets/scripts/orphan-liveness-recheck.sh"

if [ ! -r "$CHECK" ]; then
    echo "gc gastown liveness-recheck: $CHECK not found in this pack version" >&2
    exit 2
fi

exec bash "$CHECK" "$@"
