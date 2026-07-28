#!/bin/sh
# remember-scaffold.sh — ensure a directory can record hook errors.
#
# Usage: remember-scaffold.sh <dir> [<dir>...]
#
# The `remember` plugin registers its hooks with the stderr redirect baked into
# the command string:
#
#     bash "$CLAUDE_PLUGIN_ROOT/scripts/session-start-hook.sh" \
#         2>> "${CLAUDE_PROJECT_DIR:-.}/.remember/logs/hook-errors.log"
#
# The shell opens that append target BEFORE forking, so a missing
# .remember/logs/ does not merely lose the log line — the redirection fails and
# the hook body never runs at all.
#
# That makes the failure self-perpetuating: session-start-hook.sh is itself the
# thing that would `mkdir -p "$PROJECT/.remember/logs"`, but it cannot run until
# the directory it creates already exists. The plugin can never bootstrap into a
# fresh directory, and fixing it inside the plugin scripts is impossible — the
# shell has given up before any script could mkdir anything. The redirect lives
# in the plugin's vendored hooks.json, which this repo does not own and which is
# overwritten on every plugin update, so the scaffold has to come from our side.
#
# The cost of getting this wrong is not transcript noise. The discarded hook is
# the one whose job is to RECORD hook errors, so every hook failure town-wide is
# silently dropped — a monitoring blind spot rather than a cosmetic one.
#
# Called from pre_start (before any session exists) and from the polecat work
# formula (when a per-bead worktree is cut mid-session).

# Deliberately no `set -e`: a log directory must never be the reason an agent
# fails to start. Every failure below degrades to a skipped directory.

for DIR in "$@"; do
    [ -n "$DIR" ] || continue
    [ -d "$DIR" ] || continue

    # `tmp` matters as much as `logs`: post-tool-hook.sh writes
    # .remember/tmp/save-session.pid on every tool call, and without it the hook
    # errors on each invocation — the exact failure this scaffold first caught
    # once the log became writable.
    mkdir -p "$DIR/.remember/logs" "$DIR/.remember/tmp" 2>/dev/null || continue

    # Matches the layout the plugin creates for itself. A `*` pattern in a
    # directory's own .gitignore also ignores that .gitignore, so the whole tree
    # stays invisible to `git status` without touching the repo's .gitignore.
    [ -e "$DIR/.remember/.gitignore" ] ||
        printf '*\n' > "$DIR/.remember/.gitignore" 2>/dev/null || true
done

# Always succeed. Callers include pre_start hooks that gate session startup.
exit 0
