#!/bin/sh
# gastown blocked-sweep — which blocked beads are still holding something?
# Invoked as: gc gastown blocked-sweep
#
# This wrapper exists for one reason: path resolution. The check itself lives in
# assets/scripts/blocked-sweep.sh, but its caller is the witness's
# `check-blocked-beads` patrol step, which runs in a plain agent session where
# GC_PACK_DIR is NOT set. It is set by `gc` when `gc` invokes a pack command,
# which makes `gc gastown blocked-sweep` the only invocation that can locate the
# check without hardcoding the content-addressed pack cache path — packs
# materialize one directory per imported SHA, so there is no stable path to
# hardcode and a glob picks an arbitrary stale version.
#
# A formula step that reads "${GC_PACK_DIR:-}/assets/scripts/..." directly
# expands to "/assets/scripts/...", fails its own `[ -x ]` guard, and turns the
# check into a permanent no-op that reads like a considered fallback — the defect
# usage-stamp was routed through `gc` to fix (gp-fid) and the one that kept the
# deacon's heartbeat check from ever running (gp-3qb). A silent no-op is the
# specific failure gp-6ph is about, so it must not be reintroduced by the
# plumbing of its own fix.
#
# The park-route list stays the caller's: GASTOWN_BLOCKED_PARK_ROUTES passes
# through the environment.
#
# Environment (set by gc):
#   GC_CITY_PATH   — absolute city root
#   GC_PACK_DIR    — absolute pack directory
#   GC_PACK_NAME   — pack name ("gastown")
#   GC_CITY_NAME   — city workspace name
#
# Exit codes are the underlying check's, passed through unchanged:
#   0 = no findings (every blocked bead parked, or none at all)
#   1 = findings on stdout (holding-worktree / inert-routing)
#   2 = the check could not run — blocked beads were NOT measured, which is NOT
#       health

set -eu

if [ -z "${GC_CITY_PATH:-}" ] || [ -z "${GC_PACK_DIR:-}" ]; then
    echo "gc gastown blocked-sweep: missing Gas City pack context" >&2
    echo "  Run this as 'gc gastown blocked-sweep' — invoking run.sh" >&2
    echo "  directly leaves GC_PACK_DIR unset and the check cannot locate itself." >&2
    exit 2
fi

CHECK="$GC_PACK_DIR/assets/scripts/blocked-sweep.sh"

if [ ! -r "$CHECK" ]; then
    echo "gc gastown blocked-sweep: $CHECK not found in this pack version" >&2
    exit 2
fi

# Hand the check the city root `gc` already resolved instead of letting it walk
# up from cwd. The script's own fallback searches for city.toml above $PWD, which
# makes the result depend on where the caller happened to stand — the same class
# of ambient resolution this wrapper exists to remove. A deliberately-set GC_CITY
# still wins, so an operator can still point the check at another city.
GC_CITY="${GC_CITY:-$GC_CITY_PATH}"
export GC_CITY

exec bash "$CHECK" "$@"
