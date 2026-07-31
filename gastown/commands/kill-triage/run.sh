#!/bin/sh
# gastown kill-triage — may this PID be killed by an automated patrol step?
# Invoked as: gc gastown kill-triage --pid <pid> [--require-zombie]
#
# This wrapper exists for one reason: path resolution. The triage itself lives
# in assets/scripts/kill-triage.sh, but its callers are the deacon's
# orphan-process-cleanup and dolt-health patrol steps, which run in a plain
# agent session where GC_PACK_DIR is NOT set. It is set by `gc` when `gc`
# invokes a pack command, which makes `gc gastown kill-triage` the only
# invocation that can locate the triage without hardcoding the
# content-addressed pack cache path — packs materialize one directory per
# imported SHA, so there is no stable path to hardcode and a glob picks an
# arbitrary stale version.
#
# A formula step that reads "${GC_PACK_DIR:-}/assets/scripts/..." directly
# expands to "/assets/scripts/...", fails its own `[ -x ]` guard, and turns the
# check into a permanent no-op that reads like a considered fallback (gp-fid,
# gp-3qb). For a triage whose entire job is to REFUSE, a silent no-op is the
# worst possible failure: the caller sees no refusal and proceeds to the kill.
#
# Environment (set by gc):
#   GC_CITY_PATH   — absolute city root
#   GC_PACK_DIR    — absolute pack directory
#
# Exit codes are the underlying triage's, passed through unchanged:
#   0 = no kill candidates — everything was refused, or nothing was asked about
#   1 = at least one kill-candidate on stdout
#   2 = the triage could not run — nothing was triaged, which is NOT a
#       clearance to kill anything

set -eu

if [ -z "${GC_CITY_PATH:-}" ] || [ -z "${GC_PACK_DIR:-}" ]; then
    echo "gc gastown kill-triage: missing Gas City pack context" >&2
    echo "  Run this as 'gc gastown kill-triage' — invoking run.sh directly" >&2
    echo "  leaves GC_PACK_DIR unset and the triage cannot locate itself." >&2
    exit 2
fi

TRIAGE="$GC_PACK_DIR/assets/scripts/kill-triage.sh"

if [ ! -r "$TRIAGE" ]; then
    echo "gc gastown kill-triage: $TRIAGE not found in this pack version" >&2
    echo "  Treat this as 'not triaged'. Do not fall back to killing." >&2
    exit 2
fi

# Hand the triage the city root `gc` already resolved instead of letting it walk
# up from cwd. Which town owns a process is the whole question here, so it must
# not depend on where the caller happened to be standing. A deliberately-set
# GC_CITY still wins, so an operator can point the triage at another city.
GC_CITY="${GC_CITY:-$GC_CITY_PATH}"
export GC_CITY

exec bash "$TRIAGE" "$@"
