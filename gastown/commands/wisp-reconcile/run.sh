#!/bin/sh
# gastown wisp-reconcile — reconcile this agent's patrol wisps to exactly one.
# Invoked as: gc gastown wisp-reconcile <verb> [args...]
#
# This wrapper exists so agents can reach assets/scripts/wisp-reconcile.sh
# WITHOUT knowing where the pack lives. A pack is a cached git checkout —
# in a real city it sits at ~/.gc/cache/repos/<sha256>/gastown, a path no
# prompt or formula can hardcode. GC_PACK_DIR resolves it, but gc sets that
# variable only for pack commands like this one; it is NOT present in an
# agent's shell. A formula that reads "$GC_PACK_DIR/assets/scripts/..."
# directly therefore resolves "/assets/scripts/..." and finds nothing.
#
# That matters more than it looks. The script it guards fails CLOSED: when it
# cannot answer, callers must not pour and must not burn. A path that never
# resolves turns that safety property into a patrol loop which halts on its
# first cycle — the "silently dead loop" failure that is strictly worse than
# the duplicate-wisp leak this whole change exists to fix. So the only
# supported way to call it is through this command.
#
# Environment (set by gc):
#   GC_PACK_DIR    — absolute pack directory
#
# Exit codes pass through from wisp-reconcile.sh unchanged, and callers
# depend on the distinction:
#   0 = reconciled (id on stdout; empty means the agent genuinely owns none)
#   1 = could not pour/assign — caller must NOT burn its current wisp
#   2 = could not run at all — nothing was reconciled, nothing may be poured
#
# See `gc gastown wisp-reconcile --help` for the verbs.

set -e

SCRIPT="${GC_PACK_DIR:-}/assets/scripts/wisp-reconcile.sh"

if [ -z "${GC_PACK_DIR:-}" ] || [ ! -f "$SCRIPT" ]; then
    echo "gastown wisp-reconcile: cannot locate assets/scripts/wisp-reconcile.sh" \
         "(GC_PACK_DIR='${GC_PACK_DIR:-}'). NOT reconciling — do not pour and do not burn." >&2
    exit 2
fi

# `bash`, not `exec "$SCRIPT"`: the script needs bash (arrays, ${1+"$@"}) and
# may not carry its executable bit through a pack checkout. `exec` keeps the
# exit code and both streams intact without an extra process in between.
exec bash "$SCRIPT" "$@"
