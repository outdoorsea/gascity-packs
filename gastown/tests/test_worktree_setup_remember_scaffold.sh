#!/usr/bin/env bash
# Behavioral tests for the .remember/ scaffold in worktree-setup.sh.
#
# The `remember` plugin's hooks are registered as
#     bash "$CLAUDE_PLUGIN_ROOT/scripts/post-tool-hook.sh" \
#         2>> "${CLAUDE_PROJECT_DIR:-.}/.remember/logs/hook-errors.log"
# and the shell opens that append target before forking the command. A missing
# .remember/logs/ therefore kills the hook outright instead of merely losing a
# line, which silently disables the town's only hook-error channel.
#
# These tests assert the log is actually WRITTEN THROUGH, not just that the
# directory exists — a scaffold that produced an unwritable path would satisfy a
# mere existence check while leaving the blind spot in place.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SETUP="$ROOT/gastown/assets/scripts/worktree-setup.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/gastown-remember-scaffold.XXXXXX")
cleanup() {
    # Worktrees hold no locks once the parent repo is gone; plain rm is enough.
    rm -rf "$TMPROOT"
}
trap cleanup EXIT

# ── Fixture: a minimal rig repo the script can cut a worktree from ────────
RIG="$TMPROOT/rig"
mkdir -p "$RIG"
git -C "$RIG" init --quiet
git -C "$RIG" config user.email "test@example.invalid"
git -C "$RIG" config user.name "Gastown Test"
echo "seed" > "$RIG/README.md"
git -C "$RIG" add README.md
git -C "$RIG" commit --quiet -m "seed"

WT="$TMPROOT/worktrees/polecat-1"
LOG="$WT/.remember/logs/hook-errors.log"

# Replays the plugin's hook shape: a command whose stderr is appended to the log.
# Returns non-zero when the redirection itself fails, exactly as the real hook does.
run_hook_like_plugin() {
    local target="$1" message="$2"
    local script="$TMPROOT/fake-hook.sh"
    cat > "$script" <<EOF
#!/bin/sh
echo "$message" >&2
exit 3
EOF
    # The hook's own non-zero exit is expected and irrelevant; what matters is
    # whether the shell could open the append target at all.
    bash "$script" 2>> "$target" || true
}

test_fresh_worktree_gets_a_writable_hook_error_log() {
    sh "$SETUP" "$RIG" "$WT" "polecat-1" || fail "worktree-setup.sh failed on a fresh worktree"

    [[ -d "$WT/.git" || -f "$WT/.git" ]] || fail "expected a git worktree at $WT"
    [[ -d "$WT/.remember/logs" ]] || fail "fresh worktree is missing .remember/logs"
    [[ -d "$WT/.remember/tmp" ]] || fail "fresh worktree is missing .remember/tmp"
    [[ -f "$WT/.remember/.gitignore" ]] || fail "fresh worktree is missing .remember/.gitignore"
    [[ "$(cat "$WT/.remember/.gitignore")" == "*" ]] ||
        fail ".remember/.gitignore should be '*' to match peer agent workspaces"

    # The point of the fix: a hook error is RECORDED, not merely un-messaged.
    run_hook_like_plugin "$LOG" "canary-fresh"
    [[ -f "$LOG" ]] || fail "hook-errors.log was not created by an appending hook"
    grep -qF "canary-fresh" "$LOG" ||
        fail "hook stderr was not recorded in hook-errors.log — the blind spot is still open"
}

test_the_assertion_would_catch_a_regression() {
    # Guards against a vacuous suite: prove the same redirection genuinely fails
    # when the scaffold is absent, so the checks above are load-bearing.
    local missing="$TMPROOT/no-scaffold/.remember/logs/hook-errors.log"
    if bash -c ': 2>> "$1"' _ "$missing" 2>/dev/null; then
        fail "expected appending into a missing directory to fail; the other assertions would be vacuous"
    fi
}

test_existing_worktree_is_healed_in_place() {
    # Worktrees created before this scaffold existed must be repaired on their
    # next pre_start, not left broken until someone recreates them. This is the
    # early-exit path in worktree-setup.sh, which returns before the fresh-clone
    # provisioning block ever runs.
    rm -rf "$WT/.remember"
    [[ ! -d "$WT/.remember" ]] || fail "fixture setup: .remember should be gone"

    sh "$SETUP" "$RIG" "$WT" "polecat-1" || fail "worktree-setup.sh failed on an existing worktree"

    [[ -d "$WT/.remember/logs" ]] ||
        fail "existing worktree was not healed — scaffold must run before the idempotent early exit"

    run_hook_like_plugin "$LOG" "canary-healed"
    grep -qF "canary-healed" "$LOG" ||
        fail "healed worktree still does not record hook stderr"
}

test_scaffold_is_idempotent_and_preserves_logs() {
    # pre_start runs on every session start; it must not truncate accumulated
    # hook errors or clobber a workspace-local .gitignore.
    printf 'sentinel-line\n' >> "$LOG"
    sh "$SETUP" "$RIG" "$WT" "polecat-1" || fail "worktree-setup.sh failed on re-run"

    grep -qF "sentinel-line" "$LOG" || fail "re-running the scaffold destroyed existing hook-error history"
    grep -qF "canary-healed" "$LOG" || fail "re-running the scaffold truncated the log"
}

test_scaffold_does_not_pollute_git_status() {
    # A worktree whose status is permanently dirty trains agents to ignore
    # `git status`, and can sweep .remember/ into an unrelated commit.
    local status
    status=$(git -C "$WT" status --porcelain)
    [[ -z "$status" ]] ||
        fail "worktree status should stay clean, got: $status"
}

test_nested_bead_worktrees_are_healed() {
    # A polecat's session runs in the per-bead worktree the work formula cuts at
    # <workspace>/worktrees/<bead-id>, not in the workspace pre_start sets up.
    # Worktrees cut before the formula scaffolded them must be repaired by the
    # next pre_start, or the agent that actually emits hook errors keeps
    # discarding them.
    local bead_wt="$WT/worktrees/gp-000"
    mkdir -p "$bead_wt"
    rm -rf "$bead_wt/.remember"

    sh "$SETUP" "$RIG" "$WT" "polecat-1" || fail "worktree-setup.sh failed with a nested bead worktree"

    [[ -d "$bead_wt/.remember/logs" ]] || fail "nested bead worktree was not healed"
    run_hook_like_plugin "$bead_wt/.remember/logs/hook-errors.log" "canary-nested"
    grep -qF "canary-nested" "$bead_wt/.remember/logs/hook-errors.log" ||
        fail "nested bead worktree still does not record hook stderr"

    # A stray non-directory under worktrees/ must not abort startup: this script
    # runs under `set -e` before any session exists, so a crash here means the
    # agent never boots at all.
    touch "$WT/worktrees/not-a-worktree"
    sh "$SETUP" "$RIG" "$WT" "polecat-1" ||
        fail "a non-directory under worktrees/ must not fail pre_start"
    rm -f "$WT/worktrees/not-a-worktree"
}

test_scaffold_survives_a_lost_executable_bit() {
    # The scaffold is invoked through `sh`, not executed directly, so a dropped
    # mode bit cannot silently delete this fix. Guarding on -x instead would
    # turn any mode loss into a no-op with no signal — the same silent-failure
    # class this bead exists to close.
    local scaffold="$ROOT/gastown/assets/scripts/remember-scaffold.sh"
    local saved_mode
    saved_mode=$(stat -f '%Lp' "$scaffold" 2>/dev/null || stat -c '%a' "$scaffold")
    # Restore on any exit path, so a failure here cannot leave the tree dirty.
    # shellcheck disable=SC2064
    trap "chmod $saved_mode '$scaffold'; cleanup" EXIT

    chmod -x "$scaffold"
    rm -rf "$WT/.remember"
    sh "$SETUP" "$RIG" "$WT" "polecat-1" || fail "worktree-setup.sh failed with a non-executable scaffold"
    [[ -d "$WT/.remember/logs" ]] ||
        fail "scaffold was skipped when its executable bit was absent"

    chmod "$saved_mode" "$scaffold"
    trap cleanup EXIT
}

test_scaffold_precedes_the_early_exit_in_source() {
    # Structural guard. The behavioral test above catches this today, but the
    # ordering is the whole fix: moving scaffold_remember below the early exit
    # would silently restore the "new worktrees only" behavior the bead rejects.
    python3 - "$SETUP" <<'PY' || fail "scaffold_remember must be invoked before the idempotent early exit"
import sys

text = open(sys.argv[1], encoding="utf-8").read()
early_exit = text.index('# Idempotent: skip if worktree already exists.')
guard_end = text.index('mkdir -p "$(dirname "$WT")"')

# The early-exit block must call the scaffold before it exits, otherwise
# pre-existing worktrees are never repaired.
if 'scaffold_remember' not in text[early_exit:guard_end]:
    raise SystemExit(1)

# And the helper must be defined above that block, or the call is a no-op
# under `set -u`/strict shells.
if text.index('scaffold_remember()') > early_exit:
    raise SystemExit(1)
PY
}

test_fresh_worktree_gets_a_writable_hook_error_log
test_the_assertion_would_catch_a_regression
test_existing_worktree_is_healed_in_place
test_scaffold_is_idempotent_and_preserves_logs
test_scaffold_does_not_pollute_git_status
test_nested_bead_worktrees_are_healed
test_scaffold_survives_a_lost_executable_bit
test_scaffold_precedes_the_early_exit_in_source

echo "worktree-setup .remember scaffold tests passed"
