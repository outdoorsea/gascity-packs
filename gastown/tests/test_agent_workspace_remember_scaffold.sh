#!/usr/bin/env bash
# Behavioral tests for the .remember/ scaffold on NON-worktree agent workspaces.
#
# test_worktree_setup_remember_scaffold.sh covers the agents whose work_dir is a
# git worktree (polecat, refinery), which are scaffolded as a side effect of
# worktree-setup.sh. witness, mayor, deacon, dog and boot declare a plain
# work_dir under .gc/agents/ and had no pre_start at all, so nothing scaffolded
# them and a freshly provisioned rig or city started blind.
#
# Blind is the operative word. The remember plugin registers its hooks as
#     bash "$CLAUDE_PLUGIN_ROOT/scripts/post-tool-hook.sh" \
#         2>> "${CLAUDE_PROJECT_DIR:-.}/.remember/logs/hook-errors.log"
# and the shell opens that append target before forking, so a missing
# .remember/logs/ does not lose a line — it stops the hook from running. The
# hook it stops is the one that records hook errors.
#
# These tests assert the log is WRITTEN THROUGH, not merely that a directory
# exists: a scaffold producing an unwritable path would satisfy an existence
# check while leaving the blind spot exactly where it was.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GASTOWN="$ROOT/gastown"
SCAFFOLD="$GASTOWN/assets/scripts/remember-scaffold.sh"

# Agents whose work_dir is a plain directory — the subject of this suite.
NON_WORKTREE_AGENTS=(witness mayor deacon dog boot)
# Agents whose work_dir is a git worktree, scaffolded via worktree-setup.sh.
WORKTREE_AGENTS=(polecat refinery)

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/gastown-agent-scaffold.XXXXXX")
cleanup() {
    # A test below chmods a directory to 000 to exercise an unwritable parent;
    # restore traversal first or the cleanup itself fails and masks the result.
    chmod -R u+rwX "$TMPROOT" 2>/dev/null || true
    rm -rf "$TMPROOT"
}
trap cleanup EXIT

# Replays the plugin's hook shape: a command whose stderr is appended to the
# log. What matters is whether the shell can open the append target at all —
# the hook's own non-zero exit is expected and irrelevant.
run_hook_like_plugin() {
    local target="$1" message="$2"
    local script="$TMPROOT/fake-hook.sh"
    cat > "$script" <<EOF
#!/bin/sh
echo "$message" >&2
exit 3
EOF
    bash "$script" 2>> "$target" || true
}

# Emits one line per pre_start entry declared by an agent config.
agent_pre_start() {
    python3 - "$1" <<'PY'
import sys
import tomllib

with open(sys.argv[1], "rb") as handle:
    config = tomllib.load(handle)

for entry in config.get("pre_start", []):
    print(entry)
PY
}

# ── The fix, end to end ───────────────────────────────────────────────────

test_agent_pre_start_command_actually_scaffolds_a_fresh_workspace() {
    # The bead's own verification, minus the controller: render each agent's
    # pre_start exactly as the controller would and run the resulting command
    # against a work_dir that does NOT yet exist — the fresh-provision case.
    #
    # Running the rendered string is the point. A grep-shaped test passes on a
    # typo'd script name, a flag the script does not accept, or a template
    # variable that renders empty; every one of those is a silent no-op in
    # production that still reads like the fix landed.
    local agent workdir cmd log
    for agent in "${NON_WORKTREE_AGENTS[@]}"; do
        workdir="$TMPROOT/fresh/$agent"
        [[ ! -e "$workdir" ]] || fail "fixture: $workdir should not exist yet"

        cmd=$(agent_pre_start "$GASTOWN/agents/$agent/agent.toml")
        [[ -n "$cmd" ]] || fail "$agent declares no pre_start"

        # Only ConfigDir and WorkDir are legitimate here: mayor, deacon, boot
        # and dog are city-scoped and have no rig, so anything else left
        # unrendered would reach the shell as a literal brace in production.
        cmd=${cmd//\{\{.ConfigDir\}\}/$GASTOWN}
        cmd=${cmd//\{\{.WorkDir\}\}/$workdir}
        [[ "$cmd" != *'{{'* ]] ||
            fail "$agent pre_start still has unrendered template vars: $cmd"

        sh -c "$cmd" || fail "$agent pre_start command exited non-zero: $cmd"

        [[ -d "$workdir/.remember/logs" ]] ||
            fail "$agent pre_start did not scaffold .remember/logs in a fresh $workdir"
        [[ -d "$workdir/.remember/tmp" ]] ||
            fail "$agent pre_start did not scaffold .remember/tmp in a fresh $workdir"

        log="$workdir/.remember/logs/hook-errors.log"
        run_hook_like_plugin "$log" "canary-$agent"
        grep -qF "canary-$agent" "$log" ||
            fail "$agent workspace still discards hook stderr — the blind spot is open"
    done
}

test_the_assertion_would_catch_a_regression() {
    # Guards against a vacuous suite: prove the same redirection genuinely
    # fails without the scaffold, so the assertions above are load-bearing.
    local missing="$TMPROOT/no-scaffold/.remember/logs/hook-errors.log"
    if bash -c ': 2>> "$1"' _ "$missing" 2>/dev/null; then
        fail "expected appending into a missing directory to fail; the other assertions would be vacuous"
    fi
}

# ── --create semantics ────────────────────────────────────────────────────

test_create_makes_the_target_and_default_still_skips_it() {
    # The ordering question this flag exists for: the controller that consumes
    # pre_start lives in gastownhall/gascity, so whether it creates work_dir
    # before or after pre_start cannot be verified from this repo. --create
    # makes the scaffold correct either way.
    local created="$TMPROOT/flag/created"
    sh "$SCAFFOLD" --create "$created" || fail "--create exited non-zero"
    [[ -d "$created/.remember/logs" ]] || fail "--create did not create a missing target"

    # And the default must keep skipping, or callers that DISCOVER paths
    # (worktree-setup.sh globs, config-supplied paths) start materializing
    # stray .remember trees at stale or mistyped locations.
    local skipped="$TMPROOT/flag/skipped"
    sh "$SCAFFOLD" "$skipped" || fail "default mode exited non-zero on a missing target"
    [[ ! -e "$skipped" ]] ||
        fail "default mode created $skipped; the typo guard was dropped, not made opt-in"
}

test_create_matches_the_layout_of_worktree_scaffolded_peers() {
    # Same tree the plugin and worktree-setup.sh produce, so an agent workspace
    # is not subtly different from a polecat's. A `*` pattern in a directory's
    # own .gitignore also ignores that .gitignore, keeping the tree invisible.
    local dir="$TMPROOT/layout/agent"
    sh "$SCAFFOLD" --create "$dir" || fail "--create exited non-zero"
    [[ -f "$dir/.remember/.gitignore" ]] || fail "missing .remember/.gitignore"
    [[ "$(cat "$dir/.remember/.gitignore")" == "*" ]] ||
        fail ".remember/.gitignore should be '*' to match peer agent workspaces"
}

test_create_is_idempotent_and_preserves_logs() {
    # pre_start runs on every session start. Truncating here would discard the
    # accumulated hook errors this scaffold exists to collect.
    local dir="$TMPROOT/idempotent/agent"
    local log="$dir/.remember/logs/hook-errors.log"
    sh "$SCAFFOLD" --create "$dir" || fail "--create exited non-zero"
    printf 'sentinel-line\n' >> "$log"
    printf 'custom\n' > "$dir/.remember/.gitignore"

    sh "$SCAFFOLD" --create "$dir" || fail "--create exited non-zero on re-run"

    grep -qF "sentinel-line" "$log" || fail "re-running the scaffold destroyed hook-error history"
    [[ "$(cat "$dir/.remember/.gitignore")" == "custom" ]] ||
        fail "re-running the scaffold clobbered a workspace-local .gitignore"
}

test_flags_are_positional_and_terminated_by_double_dash() {
    # A directory literally named --create is not realistic, but `--` costs one
    # line and keeps the argument contract unambiguous for future callers.
    local dir="$TMPROOT/terminator/--create"
    mkdir -p "$dir"
    sh "$SCAFFOLD" -- "$dir" || fail "-- terminator exited non-zero"
    [[ -d "$dir/.remember/logs" ]] || fail "path after -- was not treated as a directory"
}

test_unrecognized_flag_is_reported_without_failing() {
    # A typo'd flag must not stop an agent from starting, and must not pass
    # silently either: falling through to skip-mode would turn a configured
    # scaffold into a no-op indistinguishable from success.
    local dir="$TMPROOT/unknown-flag/agent"
    local err="$TMPROOT/unknown-flag/stderr.txt"
    mkdir -p "$(dirname "$err")"

    local rc=0
    sh "$SCAFFOLD" --creat --create "$dir" 2>"$err" || rc=$?
    [[ $rc -eq 0 ]] || fail "an unrecognized flag should exit 0, got $rc"
    grep -qF "unrecognized option '--creat'" "$err" ||
        fail "an unrecognized flag should be reported on stderr, got: $(cat "$err")"
    # Parsing must resume past it, or one stray flag silently disables --create.
    [[ -d "$dir/.remember/logs" ]] ||
        fail "an unrecognized flag swallowed the rest of the argument list"
}

# ── pre_start failure semantics ───────────────────────────────────────────

test_scaffold_always_exits_zero() {
    # The second question the bead left open: adding a pre_start to agents that
    # never had one is a change on the startup path, and a non-zero pre_start
    # may gate session creation. The script answers it by construction — no
    # `set -e`, every failure degrades to a skipped directory, unconditional
    # `exit 0` — and this locks that in. A log directory must never be the
    # reason an agent fails to boot.
    local rc

    rc=0; sh "$SCAFFOLD" || rc=$?
    [[ $rc -eq 0 ]] || fail "no arguments should exit 0, got $rc"

    rc=0; sh "$SCAFFOLD" --create || rc=$?
    [[ $rc -eq 0 ]] || fail "--create with no directories should exit 0, got $rc"

    rc=0; sh "$SCAFFOLD" --create "" || rc=$?
    [[ $rc -eq 0 ]] || fail "an empty directory argument should exit 0, got $rc"

    rc=0; sh "$SCAFFOLD" "$TMPROOT/definitely/missing" || rc=$?
    [[ $rc -eq 0 ]] || fail "a missing directory without --create should exit 0, got $rc"

    # Target path is an existing FILE: mkdir -p cannot win, and must not throw.
    local as_file="$TMPROOT/exit-zero/as-file"
    mkdir -p "$(dirname "$as_file")"
    : > "$as_file"
    rc=0; sh "$SCAFFOLD" --create "$as_file" || rc=$?
    [[ $rc -eq 0 ]] || fail "a target that is a file should exit 0, got $rc"
    [[ -f "$as_file" ]] || fail "the scaffold replaced a regular file"

    # Unwritable parent. root ignores the mode bits, so skip rather than
    # assert something the environment cannot express.
    if [[ "$(id -u)" -ne 0 ]]; then
        local locked="$TMPROOT/exit-zero/locked"
        mkdir -p "$locked"
        chmod 000 "$locked"
        rc=0; sh "$SCAFFOLD" --create "$locked/child" || rc=$?
        chmod u+rwx "$locked"
        [[ $rc -eq 0 ]] || fail "an unwritable parent should exit 0, got $rc"
    fi
}

# ── Configuration coverage ────────────────────────────────────────────────

test_every_non_worktree_agent_scaffolds_its_workspace() {
    local agent entries
    for agent in "${NON_WORKTREE_AGENTS[@]}"; do
        entries=$(agent_pre_start "$GASTOWN/agents/$agent/agent.toml")
        grep -qF 'remember-scaffold.sh --create {{.WorkDir}}' <<<"$entries" ||
            fail "$agent must scaffold its work_dir at pre_start, got: ${entries:-<none>}"
    done
}

test_no_gastown_agent_is_left_without_a_scaffold() {
    # The completeness guard, and the reason this bead exists: gp-0kz wired the
    # scaffold through worktree-setup.sh, which only two agents call, and the
    # gap was invisible because nothing asserted coverage. A new agent added
    # without either path fails here instead of starting blind.
    local config agent entries
    for config in "$GASTOWN"/agents/*/agent.toml; do
        agent=$(basename "$(dirname "$config")")
        entries=$(agent_pre_start "$config")
        grep -qE 'remember-scaffold\.sh|worktree-setup\.sh' <<<"$entries" ||
            fail "agent '$agent' has no pre_start that scaffolds .remember/logs; it will start blind"
    done
}

test_worktree_agents_keep_their_own_scaffold_path() {
    # polecat and refinery must NOT gain a direct remember-scaffold call: their
    # work_dir is created by `git worktree add`, which refuses a non-empty
    # target, and worktree-setup.sh already scaffolds both the workspace and
    # the per-bead worktrees underneath it.
    local agent entries
    for agent in "${WORKTREE_AGENTS[@]}"; do
        entries=$(agent_pre_start "$GASTOWN/agents/$agent/agent.toml")
        grep -qF 'worktree-setup.sh' <<<"$entries" ||
            fail "$agent lost its worktree-setup.sh pre_start"
        ! grep -qF 'remember-scaffold.sh' <<<"$entries" ||
            fail "$agent should scaffold via worktree-setup.sh, not a second direct call"
    done
}

test_city_scoped_agents_do_not_reference_rig_templates() {
    # mayor, deacon, boot and dog are town-scoped and have no rig, so
    # {{.RigRoot}} and {{.Rig}} have nothing to render from. remember-scaffold.sh
    # needs only the work dir, which is why it takes just that.
    local config scope entries
    for config in "$GASTOWN"/agents/*/agent.toml; do
        scope=$(python3 -c 'import sys,tomllib;print(tomllib.load(open(sys.argv[1],"rb")).get("scope",""))' "$config")
        [[ "$scope" == "city" ]] || continue
        entries=$(agent_pre_start "$config")
        ! grep -qE '\{\{\.Rig(Root)?\}\}' <<<"$entries" ||
            fail "city-scoped $(basename "$(dirname "$config")") references a rig template var: $entries"
    done
}

test_agent_configs_parse() {
    python3 - "$GASTOWN"/agents/*/agent.toml <<'PY'
import sys
import tomllib

for path in sys.argv[1:]:
    with open(path, "rb") as handle:
        tomllib.load(handle)
PY
}

test_agent_pre_start_command_actually_scaffolds_a_fresh_workspace
test_the_assertion_would_catch_a_regression
test_create_makes_the_target_and_default_still_skips_it
test_create_matches_the_layout_of_worktree_scaffolded_peers
test_create_is_idempotent_and_preserves_logs
test_flags_are_positional_and_terminated_by_double_dash
test_unrecognized_flag_is_reported_without_failing
test_scaffold_always_exits_zero
test_every_non_worktree_agent_scaffolds_its_workspace
test_no_gastown_agent_is_left_without_a_scaffold
test_worktree_agents_keep_their_own_scaffold_path
test_city_scoped_agents_do_not_reference_rig_templates
test_agent_configs_parse

echo "agent workspace .remember scaffold tests passed"
