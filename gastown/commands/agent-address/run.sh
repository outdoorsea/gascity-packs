#!/bin/sh
# gastown agent-address — resolve a sibling agent's address, or refuse.
# Invoked as: gc gastown agent-address <role> [--candidate <addr>] [--quiet]
#
# This wrapper exists for one reason: path resolution. The resolver itself lives
# in assets/scripts/agent-address.sh, but the caller that needs it — a polecat at
# submit time, composing the refinery's address for the handoff — runs in a plain
# agent session where GC_PACK_DIR is NOT set. It is set by `gc` when `gc` invokes
# a pack command, which makes `gc gastown agent-address` the only invocation that
# can locate the script without hardcoding the content-addressed pack cache path.
# See gp-fid: reaching for "${GC_PACK_DIR:-}/assets/scripts/..." from a formula
# step expands to "/assets/scripts/...", fails its own guard, and turns the call
# into a no-op that reads like it ran.
#
# Environment (set by gc):
#   GC_CITY_PATH   — absolute city root
#   GC_PACK_DIR    — absolute pack directory
#   GC_PACK_NAME   — pack name ("gastown")
#   GC_CITY_NAME   — city workspace name
#
# Exit codes are the underlying script's, passed through unchanged:
#   0 = resolved; stdout holds an address safe to write
#   1 = REFUSED — no trustworthy address; the caller MUST NOT write an assignee
#   2 = could not run; nothing was evaluated, which is also a refusal
#
# Every non-zero exit means the same thing to a caller: do not write an
# assignee. A bead pointed at an address no agent answers to is invisible to
# every discovery path and strands silently (gp-0fz).

set -eu

if [ -z "${GC_CITY_PATH:-}" ] || [ -z "${GC_PACK_DIR:-}" ]; then
    echo "gc gastown agent-address: missing Gas City pack context" >&2
    echo "  Run this as 'gc gastown agent-address <role>' — invoking run.sh" >&2
    echo "  directly leaves GC_PACK_DIR unset and the resolver cannot locate itself." >&2
    exit 2
fi

RESOLVER="$GC_PACK_DIR/assets/scripts/agent-address.sh"

if [ ! -r "$RESOLVER" ]; then
    echo "gc gastown agent-address: $RESOLVER not found in this pack version" >&2
    exit 2
fi

exec bash "$RESOLVER" "$@"
