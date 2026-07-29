#!/bin/sh
# gastown delivery-check — is this work bead's deliverable ALREADY on the
# target branch?
# Invoked as: gc gastown delivery-check <bead-id> [--target <ref>]
#
# This wrapper exists for one reason: path resolution. The check itself lives
# in assets/scripts/polecat-delivery-check.sh, but the caller that needs it — a
# polecat at workspace-setup, before it builds anything — runs in a plain agent
# session where GC_PACK_DIR is NOT set. It is set by `gc` when `gc` invokes a
# pack command, which makes `gc gastown delivery-check` the only invocation that
# can locate the script without hardcoding the content-addressed pack cache
# path. See gp-fid: reaching for "${GC_PACK_DIR:-}/assets/scripts/..." from a
# formula step expands to "/assets/scripts/...", fails its own -x guard, and
# turns the gate into a permanent no-op that reads like it ran.
#
# Environment (set by gc):
#   GC_CITY_PATH   — absolute city root
#   GC_PACK_DIR    — absolute pack directory
#   GC_PACK_NAME   — pack name ("gastown")
#   GC_CITY_NAME   — city workspace name
#
# Exit codes are the underlying script's, passed through unchanged:
#   0 = go build it (not-delivered, or no-signal — the check abstained)
#   1 = findings on stdout (already-delivered or possibly-delivered); CONFIRM
#       by reading the cited commit before halting
#   2 = the check could not run — delivery was NOT evaluated. Never read a 2 as
#       a verdict in either direction; build as normal and let the refinery's
#       branch_has_real_change() guard remain the backstop.

set -eu

if [ -z "${GC_CITY_PATH:-}" ] || [ -z "${GC_PACK_DIR:-}" ]; then
    echo "gc gastown delivery-check: missing Gas City pack context" >&2
    echo "  Run this as 'gc gastown delivery-check <bead-id>' — invoking run.sh" >&2
    echo "  directly leaves GC_PACK_DIR unset and the check cannot locate itself." >&2
    exit 2
fi

CHECK="$GC_PACK_DIR/assets/scripts/polecat-delivery-check.sh"

if [ ! -r "$CHECK" ]; then
    echo "gc gastown delivery-check: $CHECK not found in this pack version" >&2
    exit 2
fi

exec bash "$CHECK" "$@"
