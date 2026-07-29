#!/bin/sh
# gastown parked-check — detect sessions parked at a provider usage-limit prompt.
# Invoked as: gc gastown parked-check [session-id-or-alias...]
#
# This wrapper exists for one reason: path resolution. The detector itself lives
# in assets/scripts/parked-session-check.sh, but its caller is the witness's
# `check-parked-sessions` patrol step, which runs in a plain agent session where
# GC_PACK_DIR is NOT set. It is set by `gc` when `gc` invokes a pack command,
# which makes `gc gastown parked-check` the only invocation that can locate the
# detector without hardcoding the content-addressed pack cache path. A formula
# that reads "$GC_PACK_DIR/assets/scripts/..." directly resolves to
# "/assets/scripts/..." in an agent shell and silently measures nothing — the
# same defect usage-stamp was routed through `gc` to fix (gp-fid).
#
# Rig scoping is inherited, not decided here: the detector scans GC_RIG when it
# is set, and every rig agent's shell has it. A town-level caller with no GC_RIG
# scans the whole city.
#
# Environment (set by gc):
#   GC_CITY_PATH   — absolute city root
#   GC_PACK_DIR    — absolute pack directory
#   GC_PACK_NAME   — pack name ("gastown")
#   GC_CITY_NAME   — city workspace name
#
# Exit codes are the underlying detector's, passed through unchanged:
#   0 = no parked and no unmeasured session (or nothing to check)
#   1 = findings on stdout (parked and/or unpeekable)
#   2 = the check could not run — nothing was measured, which is NOT health

set -eu

if [ -z "${GC_CITY_PATH:-}" ] || [ -z "${GC_PACK_DIR:-}" ]; then
    echo "gc gastown parked-check: missing Gas City pack context" >&2
    echo "  Run this as 'gc gastown parked-check' — invoking run.sh directly" >&2
    echo "  leaves GC_PACK_DIR unset and the detector cannot locate itself." >&2
    exit 2
fi

CHECK="$GC_PACK_DIR/assets/scripts/parked-session-check.sh"

if [ ! -r "$CHECK" ]; then
    echo "gc gastown parked-check: $CHECK not found in this pack version" >&2
    exit 2
fi

exec bash "$CHECK" "$@"
