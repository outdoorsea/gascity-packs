#!/bin/sh
# gastown usage-stamp — attribute a session's model spend to the bead it was
# spent on.
# Invoked as: gc gastown usage-stamp <bead-id> [--dry-run] [--session <id>]
#
# This wrapper exists for one reason: path resolution. The join itself lives in
# assets/scripts/usage-stamp.sh, but the callers that need it — a polecat at
# submit time, a refinery bridge at close — run in plain agent sessions where
# GC_PACK_DIR is NOT set. It is set by `gc` when `gc` invokes a pack command,
# which makes `gc gastown usage-stamp` the only invocation that can locate the
# script without hardcoding the content-addressed pack cache path.
#
# Environment (set by gc):
#   GC_CITY_PATH   — absolute city root
#   GC_PACK_DIR    — absolute pack directory
#   GC_PACK_NAME   — pack name ("gastown")
#   GC_CITY_NAME   — city workspace name
#
# Exit codes are the underlying script's, passed through unchanged:
#   0 = spend measured (and stamped unless --dry-run)
#   1 = unmetered — nothing to measure; the reason was recorded on the bead
#   2 = the join could not run

set -eu

if [ -z "${GC_CITY_PATH:-}" ] || [ -z "${GC_PACK_DIR:-}" ]; then
    echo "gc gastown usage-stamp: missing Gas City pack context" >&2
    echo "  Run this as 'gc gastown usage-stamp <bead-id>' — invoking run.sh" >&2
    echo "  directly leaves GC_PACK_DIR unset and the join cannot locate itself." >&2
    exit 2
fi

STAMP="$GC_PACK_DIR/assets/scripts/usage-stamp.sh"

if [ ! -r "$STAMP" ]; then
    echo "gc gastown usage-stamp: $STAMP not found in this pack version" >&2
    exit 2
fi

exec bash "$STAMP" "$@"
