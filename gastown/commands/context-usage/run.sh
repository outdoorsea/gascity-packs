#!/bin/sh
# gastown context-usage — how full is this session's context?
# Invoked as: gc gastown context-usage
#
# This wrapper exists for one reason: path resolution. The check itself lives in
# assets/scripts/context-usage-check.sh, but its callers are the witness and
# deacon patrols' `check-inbox` step, which run in a plain agent session where
# GC_PACK_DIR is NOT set. It is set by `gc` when `gc` invokes a pack command,
# which makes `gc gastown context-usage` the only invocation that can locate the
# check without hardcoding the content-addressed pack cache path — packs
# materialize one directory per imported SHA, so there is no stable path to
# hardcode and a glob picks an arbitrary stale version.
#
# A formula step that reads "${GC_PACK_DIR:-}/assets/scripts/..." directly
# expands to "/assets/scripts/...", fails its own `[ -x ]` guard, and turns the
# check into a permanent no-op that reads like a considered fallback. usage-stamp
# was routed through `gc` for exactly this reason (gp-fid), parked-check followed
# (gp-px5), progress-check after that, and the deacon's heartbeat check had the
# same dead wiring (gp-3qb). The step this command replaces was inert for a
# sibling reason — it measured the wrong process — so routing it by path would
# have swapped one silent no-op for another.
#
# Session identity and thresholds stay the caller's: GC_SESSION_NAME,
# GC_SESSION_ID, GASTOWN_CONTEXT_LIMIT_TOKENS, GASTOWN_CONTEXT_LIMIT_RSS_MB and
# GASTOWN_CONTEXT_TOKENS_MAX_AGE_SEC all pass through the environment.
#
# Environment (set by gc):
#   GC_CITY_PATH   — absolute city root
#   GC_PACK_DIR    — absolute pack directory
#   GC_PACK_NAME   — pack name ("gastown")
#   GC_CITY_NAME   — city workspace name
#
# Exit codes are the underlying check's, passed through unchanged:
#   0 = ok — a signal was measured and nothing is over its limit
#   1 = heavy — request a restart
#   2 = unmeasured — context pressure was NOT evaluated, which is NOT health,
#       and is NOT a reason to restart

set -eu

if [ -z "${GC_CITY_PATH:-}" ] || [ -z "${GC_PACK_DIR:-}" ]; then
    echo "gc gastown context-usage: missing Gas City pack context" >&2
    echo "  Run this as 'gc gastown context-usage' — invoking run.sh directly" >&2
    echo "  leaves GC_PACK_DIR unset and the check cannot locate itself." >&2
    exit 2
fi

CHECK="$GC_PACK_DIR/assets/scripts/context-usage-check.sh"

if [ ! -r "$CHECK" ]; then
    echo "gc gastown context-usage: $CHECK not found in this pack version" >&2
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
