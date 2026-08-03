#!/bin/sh
# gastown prompt-block-check — is this session waiting on a HUMAN, or is it hung?
# Invoked as: gc gastown prompt-block-check <session> [<session>...]
#
# This wrapper exists for one reason: path resolution. The check itself lives in
# assets/scripts/prompt-block-check.sh, but its caller is the deacon's
# `health-scan` patrol step, which runs in a plain agent session where
# GC_PACK_DIR is NOT set. It is set by `gc` when `gc` invokes a pack command,
# which makes `gc gastown prompt-block-check` the only invocation that can locate
# the check without hardcoding the content-addressed pack cache path — packs
# materialize one directory per imported SHA, so there is no stable path to
# hardcode and a glob picks an arbitrary stale version.
#
# A formula step that reads "${GC_PACK_DIR:-}/assets/scripts/..." directly
# expands to "/assets/scripts/...", fails its own `[ -x ]` guard, and turns the
# check into a permanent no-op that reads like a considered fallback — the defect
# usage-stamp was routed through `gc` to fix (gp-fid) and the one that kept the
# deacon's heartbeat check from ever running (gp-3qb). That failure mode matters
# more here than usual: this check's whole job is to VETO an action the step
# would otherwise take, so a silent no-op does not merely lose a signal, it
# restores the exact behaviour gp-ha5 exists to stop.
#
# Session arguments and the pattern/window overrides pass through unchanged.
#
# Environment (set by gc):
#   GC_CITY_PATH   — absolute city root
#   GC_PACK_DIR    — absolute pack directory
#   GC_PACK_NAME   — pack name ("gastown")
#   GC_CITY_NAME   — city workspace name
#
# Exit codes are the underlying check's, passed through unchanged:
#   0 = every named session is `clear`
#   1 = findings on stdout (prompt-blocked and/or unreadable)
#   2 = the check could not run — no sessions named, or bad config. Nothing was
#       measured, which is NOT a clearance

set -eu

if [ -z "${GC_CITY_PATH:-}" ] || [ -z "${GC_PACK_DIR:-}" ]; then
    echo "gc gastown prompt-block-check: missing Gas City pack context" >&2
    echo "  Run this as 'gc gastown prompt-block-check' — invoking run.sh" >&2
    echo "  directly leaves GC_PACK_DIR unset and the check cannot locate itself." >&2
    exit 2
fi

CHECK="$GC_PACK_DIR/assets/scripts/prompt-block-check.sh"

if [ ! -r "$CHECK" ]; then
    echo "gc gastown prompt-block-check: $CHECK not found in this pack version" >&2
    exit 2
fi

# Hand the check the city root `gc` already resolved instead of letting it walk
# up from cwd, matching blocked-sweep. A deliberately-set GC_CITY still wins, so
# an operator can still point the check at another city.
GC_CITY="${GC_CITY:-$GC_CITY_PATH}"
export GC_CITY

exec bash "$CHECK" "$@"
