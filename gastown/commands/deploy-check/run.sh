#!/bin/sh
# gastown deploy-check — is a merged commit actually live in this city, or was it
# only authored?
# Invoked as: gc gastown deploy-check <sha> [--stamp <bead>] [--repo <dir>]
#
# This wrapper exists for path resolution, and here that reason is unusually
# load-bearing. The check's whole job is to read the INSTALLED pack artifact, and
# GC_PACK_DIR is the only thing that names it: packs materialize one directory
# per imported SHA under the content-addressed cache, so there is no stable path
# to hardcode and a glob picks an arbitrary stale version — i.e. it would answer
# the deployment question against the wrong deployment.
#
# GC_PACK_DIR is set by `gc` when `gc` invokes a pack command, and is NOT set in
# an agent's shell. A formula step that reads "${GC_PACK_DIR:-}/assets/scripts/..."
# expands to "/assets/scripts/...", fails its own `[ -x ]` guard, and turns the
# check into a permanent no-op that reads like a considered fallback. Four checks
# shipped dead exactly that way: usage-stamp (gp-fid), parked-check (gp-px5), and
# the deacon heartbeat plus polecat progress checks (gp-3qb). So `gc gastown
# deploy-check` is the only supported invocation.
#
# Environment (set by gc):
#   GC_CITY_PATH   — absolute city root
#   GC_PACK_DIR    — absolute pack directory (the artifact under assertion)
#   GC_PACK_NAME   — pack name ("gastown")
#
# Exit codes are the underlying check's, passed through unchanged. Callers depend
# on the distinction — see `gc gastown deploy-check --help`:
#   0 = deployed               live in this city; both conjuncts proven
#   1 = authored_not_deployed  merged, but provably not live
#   2 = undetermined           could not evaluate; treat as NOT deployed
#   3 = not_applicable         this repo is not a pack source for this city

set -eu

if [ -z "${GC_CITY_PATH:-}" ] || [ -z "${GC_PACK_DIR:-}" ]; then
    echo "gc gastown deploy-check: missing Gas City pack context" >&2
    echo "  Run this as 'gc gastown deploy-check' — invoking run.sh directly" >&2
    echo "  leaves GC_PACK_DIR unset, and the installed artifact is precisely" >&2
    echo "  what this check has to resolve." >&2
    exit 2
fi

CHECK="$GC_PACK_DIR/assets/scripts/deploy-check.sh"

if [ ! -r "$CHECK" ]; then
    echo "gc gastown deploy-check: $CHECK not found in this pack version" >&2
    exit 2
fi

# Hand the check the city root `gc` already resolved rather than letting it walk
# up from cwd, for the same reason this wrapper exists: ambient resolution makes
# the answer depend on where the caller happened to stand. A deliberately-set
# GC_CITY still wins, so an operator can point the check at another city.
GC_CITY="${GC_CITY:-$GC_CITY_PATH}"
export GC_CITY

# `bash`, not `exec "$CHECK"`: the check needs bash (arrays, [[ ]]) and may not
# carry its executable bit through a pack checkout. `exec` keeps the exit code
# and both streams intact — the caller reads the verdict from stdout and the
# evidence from stderr.
exec bash "$CHECK" "$@"
