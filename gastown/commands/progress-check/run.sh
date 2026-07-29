#!/bin/sh
# gastown progress-check — are the in-flight polecat work beads still moving?
# Invoked as: gc gastown progress-check
#
# This wrapper exists for one reason: path resolution. The check itself lives in
# assets/scripts/polecat-progress-check.sh, but its caller is the witness's
# `check-polecat-health` patrol step, which runs in a plain agent session where
# GC_PACK_DIR is NOT set. It is set by `gc` when `gc` invokes a pack command,
# which makes `gc gastown progress-check` the only invocation that can locate the
# check without hardcoding the content-addressed pack cache path — packs
# materialize one directory per imported SHA, so there is no stable path to
# hardcode and a glob picks an arbitrary stale version.
#
# A formula step that reads "${GC_PACK_DIR:-}/assets/scripts/..." directly
# expands to "/assets/scripts/...", fails its own `[ -x ]` guard, and turns the
# check into a permanent no-op that reads like a considered fallback. usage-stamp
# was routed through `gc` for exactly this reason (gp-fid), parked-check followed
# (gp-px5), and the deacon's heartbeat check had the same dead wiring (gp-3qb).
# mol-witness-patrol already carried the warning in prose one step above this
# one while still resolving this check by path.
#
# The staleness window stays the caller's: GASTOWN_POLECAT_STALE_MIN and
# GASTOWN_POLECAT_ROLE pass through the environment, exactly as they did when
# the formula invoked the script by path.
#
# Environment (set by gc):
#   GC_CITY_PATH   — absolute city root
#   GC_PACK_DIR    — absolute pack directory
#   GC_PACK_NAME   — pack name ("gastown")
#   GC_CITY_NAME   — city workspace name
#
# Exit codes are the underlying check's, passed through unchanged:
#   0 = every checked polecat is fresh (or none to check)
#   1 = findings on stdout (stale and/or no-heartbeat)
#   2 = the check could not run — freshness was NOT measured, which is NOT health

set -eu

if [ -z "${GC_CITY_PATH:-}" ] || [ -z "${GC_PACK_DIR:-}" ]; then
    echo "gc gastown progress-check: missing Gas City pack context" >&2
    echo "  Run this as 'gc gastown progress-check' — invoking run.sh directly" >&2
    echo "  leaves GC_PACK_DIR unset and the check cannot locate itself." >&2
    exit 2
fi

CHECK="$GC_PACK_DIR/assets/scripts/polecat-progress-check.sh"

if [ ! -r "$CHECK" ]; then
    echo "gc gastown progress-check: $CHECK not found in this pack version" >&2
    exit 2
fi

# Hand the check the city root `gc` already resolved instead of letting it walk
# up from cwd. The script's own fallback searches for city.toml above $PWD, which
# makes the result depend on where the caller happened to stand — the same class
# of ambient resolution this wrapper exists to remove. A deliberately-set
# GC_CITY still wins, so an operator can still point the check at another city.
GC_CITY="${GC_CITY:-$GC_CITY_PATH}"
export GC_CITY

exec bash "$CHECK" "$@"
