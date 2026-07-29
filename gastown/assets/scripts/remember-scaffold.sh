#!/bin/sh
# remember-scaffold.sh — ensure a directory can record hook errors.
#
# Usage: remember-scaffold.sh [--create] <dir> [<dir>...]
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
#
# --create makes a missing target instead of skipping it, and is opt-in because
# the default skip is a real guard. Callers that DISCOVER paths — worktree-setup.sh
# globbing <workspace>/worktrees/*, or anything reading a path out of config —
# should no-op on a stale or mistyped entry rather than materialize a stray
# .remember tree somewhere nobody will look. Callers that OWN the path opt in: an
# agent's pre_start is handed {{.WorkDir}} rendered by the controller, so there is
# no typo to defend against, and running before anything else has made that
# directory is the entire point.
#
# That distinction is load-bearing rather than stylistic. Whether the controller
# creates work_dir before or after pre_start is not observable from this repo —
# the controller lives in gastownhall/gascity — so the scaffold must not depend on
# the answer. With --create it is correct either way: it creates the directory if
# it is first, and mkdir -p is a no-op if the controller already did. Without it,
# a controller that runs pre_start first would make this whole fix a silent no-op
# that still reads like it landed.
#
# Flags must precede directories; `--` ends them, for a directory named like one.

# Deliberately no `set -e`: a log directory must never be the reason an agent
# fails to start. Every failure below degrades to a skipped directory.

CREATE=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --create) CREATE=1; shift ;;
        --) shift; break ;;
        # An unrecognized flag is still not fatal — nothing here may stop an
        # agent from starting — but it must not pass silently either. A typo'd
        # `--creat` would otherwise fall through to skip-mode and turn a
        # configured scaffold into a no-op that reads exactly like success,
        # which is the failure class this script exists to close.
        --*)
            echo "remember-scaffold.sh: ignoring unrecognized option '$1'" >&2
            shift
            ;;
        *) break ;;
    esac
done

for DIR in "$@"; do
    [ -n "$DIR" ] || continue

    # Under --create, make the target itself. A failure here (the path is a
    # file, an unwritable parent, a read-only mount) deliberately falls through
    # to the [ -d ] guard rather than aborting, so pre_start still exits 0.
    if [ "$CREATE" -eq 1 ] && [ ! -d "$DIR" ]; then
        mkdir -p "$DIR" 2>/dev/null || true
    fi

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
