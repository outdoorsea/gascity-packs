#!/bin/sh
# gastown worktree-reap — reap per-bead polecat worktrees whose work has landed.
# Invoked as: gc gastown worktree-reap [--reap] [--rig <name>] [--target <ref>]
#
# This wrapper exists for one reason: path resolution. The reaper itself lives in
# assets/scripts/polecat-worktree-reap.sh, but its caller is the witness's
# `reap-landed-worktrees` patrol step, which runs in a plain agent session where
# GC_PACK_DIR is NOT set. It is set by `gc` when `gc` invokes a pack command,
# which makes `gc gastown worktree-reap` the only invocation that can locate the
# reaper without hardcoding the content-addressed pack cache path. A formula that
# reads "$GC_PACK_DIR/assets/scripts/..." directly resolves to
# "/assets/scripts/..." in an agent shell and silently reaps nothing while
# reading like it ran — the same defect usage-stamp was routed through `gc` to
# fix (gp-fid), and parked-check after it.
#
# Rig scoping is inherited, not decided here: the reaper scans GC_RIG, and every
# rig agent's shell has it. Unlike parked-check there is no town-wide mode — the
# reaper needs one rig's git repo to enumerate and remove worktrees, so a caller
# with no GC_RIG must pass --rig.
#
# Environment (set by gc):
#   GC_CITY_PATH   — absolute city root
#   GC_PACK_DIR    — absolute pack directory
#   GC_PACK_NAME   — pack name ("gastown")
#   GC_CITY_NAME   — city workspace name
#
# Exit codes are the underlying reaper's, passed through unchanged:
#   0 = nothing to report (no candidates, or every one kept)
#   1 = findings on stdout (reapable, reaped, or unverifiable)
#   2 = the reaper could not run — nothing was measured, which is NOT the same
#       as nothing to reap

set -eu

if [ -z "${GC_CITY_PATH:-}" ] || [ -z "${GC_PACK_DIR:-}" ]; then
    echo "gc gastown worktree-reap: missing Gas City pack context" >&2
    echo "  Run this as 'gc gastown worktree-reap' — invoking run.sh directly" >&2
    echo "  leaves GC_PACK_DIR unset and the reaper cannot locate itself." >&2
    exit 2
fi

REAP="$GC_PACK_DIR/assets/scripts/polecat-worktree-reap.sh"

if [ ! -r "$REAP" ]; then
    echo "gc gastown worktree-reap: $REAP not found in this pack version" >&2
    exit 2
fi

exec bash "$REAP" "$@"
