#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GASTOWN="$ROOT/gastown"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

parse_toml() {
    python3 - "$@" <<'PY'
import sys
import tomllib

for path in sys.argv[1:]:
    with open(path, "rb") as handle:
        tomllib.load(handle)
PY
}

test_dog_assets_are_pack_local() {
    [[ -f "$GASTOWN/agents/dog/agent.toml" ]] || fail "missing dog agent config"
    [[ -f "$GASTOWN/agents/dog/prompt.template.md" ]] || fail "missing dog prompt"
    [[ -f "$GASTOWN/formulas/mol-shutdown-dance.toml" ]] || fail "missing shutdown dance formula"
    parse_toml "$GASTOWN/agents/dog/agent.toml" "$GASTOWN/formulas/mol-shutdown-dance.toml"
    grep -F 'wake_mode = "fresh"' "$GASTOWN/agents/dog/agent.toml" >/dev/null ||
        fail "dog agent should own wake_mode"
    grep -F 'work_dir = ".gc/agents/dogs/{{.AgentBase}}"' "$GASTOWN/agents/dog/agent.toml" >/dev/null ||
        fail "dog agent should own work_dir"
    ! grep -F 'fallback = true' "$GASTOWN/agents/dog/agent.toml" >/dev/null ||
        fail "gastown dog should be authoritative over fallback dog providers"
    ! grep -A3 -F '[[patches.agent]]' "$GASTOWN/pack.toml" | grep -F 'name = "dog"' >/dev/null ||
        fail "dog should not be split between pack-local agent and same-name patch"
    [[ ! -e "$GASTOWN/agents/dog/overlay/.gitkeep" ]] ||
        fail "dog overlay placeholder should not be present without an overlay contract"
}

test_retired_dog_formulas_are_not_reintroduced() {
    [[ ! -e "$GASTOWN/formulas/mol-dog-jsonl.toml" ]] || fail "mol-dog-jsonl formula should remain retired"
    [[ ! -e "$GASTOWN/formulas/mol-dog-reaper.toml" ]] || fail "mol-dog-reaper formula should remain retired"
    ! grep -R --exclude='test_gastown_pack_assets.sh' "mol-dog-jsonl\\|mol-dog-reaper" "$GASTOWN" >/dev/null ||
        fail "gastown pack should not advertise retired dog formulas"
}

test_shutdown_dance_contracts_are_executable() {
    local formula="$GASTOWN/formulas/mol-shutdown-dance.toml"

    ! grep -F '[vars.warrant_id]' "$formula" >/dev/null ||
        fail "warrant_id should be the claimed work bead, not a required formula var"
    grep -F 'gc bd show "$GC_BEAD_ID"' "$formula" >/dev/null ||
        fail "shutdown dance should inspect the claimed warrant bead"
    grep -F 'gc bd close "$GC_BEAD_ID"' "$formula" >/dev/null ||
        fail "shutdown dance should close the claimed warrant bead"
    ! grep -F '<wisp-id>' "$formula" >/dev/null ||
        fail "shutdown dance should not contain raw wisp placeholders"
    ! grep -F '<work-bead>' "$formula" >/dev/null ||
        fail "shutdown dance should not contain raw work bead placeholders"
    ! grep -F 'gc mail send {{requester}}/' "$formula" >/dev/null ||
        fail "routine dog requester reporting must use nudge, not mail"
    grep -F 'requester_endpoint="${requester%/}/"' "$formula" >/dev/null ||
        fail "shutdown dance should normalize requester endpoints"
    grep -F 'gc session nudge "$requester_endpoint" "DOG_DONE:' "$formula" >/dev/null ||
        fail "shutdown dance should notify requester with DOG_DONE nudges"
    ! grep -F 'gc session peek "{{target}}"' "$formula" >/dev/null ||
        fail "shutdown dance should use quoted target shell variables for peeks"
    ! grep -F 'gc session kill "{{target}}"' "$formula" >/dev/null ||
        fail "shutdown dance should use quoted target shell variables for kills"
    grep -F 'Verify the warrant bead exists and is not closed' "$formula" >/dev/null ||
        fail "receive step should verify the warrant is not closed rather than demanding open"
    grep -F 'Both `open` and `in_progress` are valid warrant states' "$formula" >/dev/null ||
        fail "receive step should explicitly accept open and in_progress warrant states"
    ! grep -F 'exists and is open' "$formula" >/dev/null ||
        fail "receive step must not regress to an open-only warrant instruction; claimed warrants are in_progress"
}

test_shutdown_dance_lifecycle_and_audit_contracts() {
    local formula="$GASTOWN/formulas/mol-shutdown-dance.toml"
    local prompt="$GASTOWN/agents/dog/prompt.template.md"

    ! grep -Fi 'burn' "$formula" >/dev/null ||
        fail "early-exit paths should drain-ack and exit, not burn a wisp that was never poured"
    [[ "$(grep -c 'gc runtime drain-ack' "$formula")" -ge 8 ]] ||
        fail "every early-exit path and the epitaph should end with gc runtime drain-ack"
    local malformed_branches malformed_closes malformed_drains
    malformed_branches="$(grep -c 'is missing target or reason' "$formula" || true)"
    malformed_closes="$(grep -A4 'is missing target or reason' "$formula" | grep -cF 'gc bd close "$GC_BEAD_ID"' || true)"
    malformed_drains="$(grep -A4 'is missing target or reason' "$formula" | grep -cF 'gc runtime drain-ack' || true)"
    [[ "$malformed_branches" -ge 1 ]] ||
        fail "shutdown dance should validate warrant target/reason metadata"
    [[ "$malformed_closes" -eq "$malformed_branches" ]] ||
        fail "every malformed-warrant branch must close the claimed warrant before exiting"
    [[ "$malformed_drains" -eq "$malformed_branches" ]] ||
        fail "every malformed-warrant branch must drain-ack before exiting, not leak the claimed warrant"
    grep -F 'MALFORMED_WARRANT' "$formula" >/dev/null ||
        fail "malformed warrants should close with a malformed-warrant audit reason"
    ! grep -E '^\[vars' "$formula" >/dev/null ||
        fail "warrant values come from bead metadata; the formula should not declare pour vars"
    grep -F 'EXECUTE_FAILED: kill did not take effect' "$formula" >/dev/null ||
        fail "kill failures should close the warrant as EXECUTE_FAILED, not Executed"
    grep -F 'DOG_DONE: $target - EXECUTE_FAILED (escalated)' "$formula" >/dev/null ||
        fail "kill failures should notify the requester with EXECUTE_FAILED, not EXECUTED"
    grep -F 'gone or shows fresh startup output' "$formula" >/dev/null ||
        fail "execute verification should treat gone-or-freshly-restarted as kill success"
    ! grep -F '{{requester}}' "$prompt" >/dev/null ||
        fail "dog prompt should use the normalized requester endpoint, not raw requester templates"
    ! grep -F 'nudge deacon/' "$prompt" >/dev/null ||
        fail "dog prompt should notify the warrant's requester, not a hardcoded deacon endpoint"
    grep -F 'gc session nudge "$requester_endpoint"' "$prompt" >/dev/null ||
        fail "dog prompt DOG_DONE guidance should use the normalized requester endpoint"
}

test_composition_is_documented() {
    # The retired maintenance pack is gone: the runtime composes the builtin
    # core pack via explicit city.toml includes, and gastown owns the only
    # mol-shutdown-dance. The docs must describe that model, not the old
    # fallback/ordering workarounds.
    grep -F 'builtin core pack' "$GASTOWN/README.md" >/dev/null ||
        fail "README should attribute mechanical housekeeping to the builtin core pack"
    ! grep -F '[imports.maintenance]' "$GASTOWN/README.md" >/dev/null ||
        fail "README should not reference the retired maintenance pack import"
    ! grep -Fi 'implicit maintenance' "$GASTOWN/README.md" >/dev/null ||
        fail "README should not describe implicit maintenance injection"
    grep -F 'gc formula show mol-shutdown-dance' "$GASTOWN/README.md" >/dev/null ||
        fail "README should document how to verify the effective shutdown-dance formula"
    grep -F 'builtin core' "$GASTOWN/pack.toml" >/dev/null ||
        fail "pack.toml should attribute mechanical housekeeping to the builtin core pack"
    ! grep -F '[imports.maintenance]' "$GASTOWN/pack.toml" >/dev/null ||
        fail "pack.toml should not reference the retired maintenance pack import"
}

test_polecat_startup_uses_standard_hook_claim() {
    local agent prompt propulsion
    agent="$GASTOWN/agents/polecat/agent.toml"
    prompt="$GASTOWN/agents/polecat/prompt.template.md"
    propulsion="$GASTOWN/template-fragments/propulsion.template.md"

    grep -F 'gc hook --claim --json' "$agent" >/dev/null ||
        fail "polecat nudge should call the standard hook claim path"
    grep -F 'gc hook --claim --json' "$prompt" >/dev/null ||
        fail "polecat prompt should call the standard hook claim path"
    grep -F 'gc hook --claim --json' "$propulsion" >/dev/null ||
        fail "polecat propulsion fragment should call the standard hook claim path"
    grep -F 'After closing any formula step bead, immediately run' "$prompt" >/dev/null ||
        fail "polecat prompt must require hook continuation after each formula step"
    grep -F 'After closing a step bead,' "$propulsion" >/dev/null ||
        fail "polecat propulsion fragment must require hook continuation after each formula step"
    ! grep -F 'run `gc hook` or' "$prompt" >/dev/null ||
        fail "polecat prompt must not regress to an unclaimed hook/work-query choice"
    ! grep -F 'run `gc hook` or' "$propulsion" >/dev/null ||
        fail "polecat propulsion fragment must not regress to an unclaimed hook/work-query choice"
}

test_review_leg_contract_forbids_synthetic_mutation() {
    local formula prompt
    formula="$GASTOWN/formulas/mol-review-leg.toml"
    prompt="$GASTOWN/agents/polecat/prompt.template.md"

    grep -F 'Do not create synthetic/test beads' "$formula" >/dev/null ||
        fail "review-leg formula must forbid synthetic test beads"
    grep -F 'Do not create test beads' "$formula" >/dev/null ||
        fail "review-leg load-assignment must forbid test bead creation"
    grep -F 'The only allowed bead mutations are the formula-prescribed' "$formula" >/dev/null ||
        fail "review-leg formula must define allowed mutation boundary"
    grep -F 'treat that text as' "$formula" >/dev/null ||
        fail "review-leg formula must treat plans/checklists as review subject matter"
    grep -F 'Do not start cities, spawn sessions, route extra work' "$formula" >/dev/null ||
        fail "review-leg formula must forbid executing reviewed checklist items"
    grep -F 'Formula-specific non-implementation assignments may explicitly tell you' "$prompt" >/dev/null ||
        fail "polecat prompt must allow formula-specific review/control close steps"
    ! grep -F '`gc bd close`, `gc bd close`' "$prompt" >/dev/null ||
        fail "polecat prompt must not duplicate its close prohibition"
    grep -F 'Default implementation formula: `mol-polecat-work`' "$prompt" >/dev/null ||
        fail "polecat prompt must describe mol-polecat-work as the default implementation formula"
    ! grep -F '**You MUST NOT close beads. EVER. No exceptions.**' "$prompt" >/dev/null ||
        fail "polecat prompt must not globally forbid review-leg close steps"
}

test_refinery_direct_merge_is_worktree_safe_and_fail_closed() {
    local formula direct_block
    formula="$GASTOWN/formulas/mol-refinery-patrol.toml"

    direct_block=$(python3 - "$formula" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
start = text.index('**If MERGE_STRATEGY = "direct"')
end = text.index('**If MERGE_STRATEGY = "mr"')
print(text[start:end])
PY
)

    [[ "$direct_block" == *'git worktree add --detach "$MERGE_WT" "origin/$TARGET"'* ]] ||
        fail "direct refinery merge must use a detached target worktree"
    [[ "$direct_block" == *'+refs/heads/${TARGET}:refs/remotes/origin/${TARGET}'* ]] ||
        fail "direct refinery merge refspecs must brace TARGET for zsh-safe expansion"
    [[ "$direct_block" == *'git -C "$MERGE_WT" push origin "HEAD:$TARGET"'* ]] ||
        fail "direct refinery merge must push the verified merge worktree HEAD"
    [[ "$direct_block" == *'[ "$MERGED_SHA" != "$REMOTE" ]'* ]] ||
        fail "direct refinery merge must compare merged SHA to origin target"
    [[ "$direct_block" == *'STOP. Do not mutate bead state.'* ]] ||
        fail "direct refinery merge must fail closed before metadata writes"
    ! printf '%s\n' "$direct_block" | grep -E '^[[:space:]]*git checkout \$TARGET([[:space:]]|$)' >/dev/null ||
        fail "direct refinery merge must not checkout target branch in the active worktree"

    # The SHA comparison above is vacuous on its own: MERGED_SHA is read from a
    # worktree created at origin/$TARGET, so an aborted merge leaves it equal to
    # REMOTE and the comparison passes. These three guards are what make the
    # verification real.
    [[ "$direct_block" == *'set -euo pipefail'* ]] ||
        fail "direct refinery merge must use set -euo pipefail so a failed merge cannot reach the close"
    [[ "$direct_block" == *'PRE_SHA=$(git -C "$MERGE_WT" rev-parse HEAD)'* ]] ||
        fail "direct refinery merge must capture PRE_SHA before merging"
    [[ "$direct_block" == *'[ "$MERGED_SHA" = "$PRE_SHA" ]'* ]] ||
        fail "direct refinery merge must refuse a merge that advanced nothing"
    [[ "$direct_block" == *'git merge-base --is-ancestor "$TEMP_SHA" "$REMOTE"'* ]] ||
        fail "direct refinery merge must assert the work commit is contained in the pushed target"

    python3 - "$formula" <<'PY' || fail "direct refinery merge guards are misordered: capture PRE_SHA before the merge, refuse a no-op before the push, and assert containment before the merged metadata write"
import sys
text = open(sys.argv[1], encoding="utf-8").read()
start = text.index('**If MERGE_STRATEGY = "direct"')
end = text.index('**If MERGE_STRATEGY = "mr"')
block = text[start:end]
metadata = block.index('--set-metadata merge_result=merged')

# Every gate must sit between its subject and the metadata write.
pre_capture = block.index('PRE_SHA=$(git -C "$MERGE_WT" rev-parse HEAD)')
merge = block.index('git -C "$MERGE_WT" merge --ff-only "$TEMP_SHA"')
no_advance = block.index('[ "$MERGED_SHA" = "$PRE_SHA" ]')
push = block.index('git -C "$MERGE_WT" push origin "HEAD:$TARGET"')
verify = block.index('[ "$MERGED_SHA" != "$REMOTE" ]')
contained = block.index('git merge-base --is-ancestor "$TEMP_SHA" "$REMOTE"')

# PRE_SHA is only a witness if it is read before the merge mutates HEAD, and
# the no-advance guard must fail closed before anything is pushed.
if not pre_capture < merge < no_advance < push:
    raise SystemExit(1)
# The containment assertion is the only non-vacuous gate; it must run after the
# post-push fetch that sets REMOTE and before the bead is closed as merged.
if not verify < contained < metadata:
    raise SystemExit(1)
PY
}

test_witness_salvage_reads_work_dir_metadata() {
    # The polecat's branch-setup step records its worktree as `metadata.work_dir`
    # (see agents/polecat/prompt.template.md). Salvage must read that same key.
    # Reading `.worktree` yields an empty $WORKTREE for every bead, which makes
    # Cases A-D unreachable and silently routes every orphan to Case E
    # ("nothing to salvage"), discarding unpushed polecat work.
    local formula="$GASTOWN/formulas/mol-witness-patrol.toml"

    grep -F "jq -r '.work_dir // empty'" "$formula" >/dev/null ||
        fail "witness salvage must resolve the worktree from metadata.work_dir"
    ! grep -F "jq -r '.worktree // empty'" "$formula" >/dev/null ||
        fail "witness salvage must not regress to metadata.worktree; no bead carries that key"
    # `gc.work_dir` is the agent's persistent HOME workspace — the parent of the
    # per-bead worktree, sitting on the agent's own `gc-<agent>-<sha>` branch. It
    # is a real directory, which is what makes it a plausible-looking but wrong
    # salvage source: committing bead work there and pushing publishes the agent
    # home branch, not `polecat/<bead>`, leaving the bead with no merge target.
    #
    # gp-6k8: this forbids the agent home as the SALVAGE TARGET, not as evidence.
    # Read-only probing of both scopes is required elsewhere in this formula to
    # decide whether anything is at risk on disk; that is a different question
    # from where a branch gets committed and pushed. Keep the two separate.
    ! grep -F "jq -r '.gc.work_dir // empty'" "$formula" >/dev/null ||
        fail "witness salvage must not resolve its worktree from gc.work_dir; that is the agent home, not the bead's worktree"
}

test_polecat_health_check_is_measured_not_improvised() {
    # gp-9ly: check-polecat-health used to say "there are no hardcoded
    # thresholds... this is judgment work", handing the witness a staleness
    # question with no command to run. The witness improvised `date`
    # arithmetic, formatted a LOCAL-time mtime with a `Z` suffix, compared it
    # against a UTC now, and read 4 minutes of healthy work as ~7h stale. A
    # warrant was filed against a polecat that was working correctly.
    local formula check cmd
    formula="$GASTOWN/formulas/mol-witness-patrol.toml"
    check="$GASTOWN/assets/scripts/polecat-progress-check.sh"
    cmd="$GASTOWN/commands/progress-check/run.sh"

    [[ -x "$check" ]] || fail "missing or non-executable assets/scripts/polecat-progress-check.sh"
    [[ -x "$cmd" ]] || fail "missing or non-executable commands/progress-check/run.sh"
    [[ -f "$GASTOWN/commands/progress-check/help.md" ]] ||
        fail "missing commands/progress-check/help.md"

    # gp-3qb: this step used to resolve the check as
    # "${GC_PACK_DIR:-}/assets/scripts/polecat-progress-check.sh". GC_PACK_DIR is
    # set by `gc` for pack COMMANDS and is unset in an agent's shell, so the path
    # expanded to "/assets/scripts/...", the `[ -x ]` guard in front of it failed,
    # and the step fell back to the eyeballing gp-9ly exists to prevent. The
    # earlier version of this very test asserted the path form and the `[ -x ]`
    # guard as the contract, which is why the suite stayed green over a check
    # that never ran.
    grep -F 'gc gastown progress-check' "$formula" >/dev/null ||
        fail "check-polecat-health must run the check as 'gc gastown progress-check'"
    ! grep -F 'GC_PACK_DIR' "$formula" | grep -F 'progress-check' >/dev/null ||
        fail "the progress check must not be resolved via \$GC_PACK_DIR; it is unset in an agent shell"
    grep -F 'GC_PACK_DIR' "$cmd" >/dev/null ||
        fail "commands/progress-check/run.sh must resolve the check through GC_PACK_DIR"
    grep -F 'GASTOWN_POLECAT_STALE_MIN={{polecat_stale_min}}' "$formula" >/dev/null ||
        fail "the staleness window must come from the formula var, not a number invented per cycle"
    grep -F '[vars.polecat_stale_min]' "$formula" >/dev/null ||
        fail "polecat_stale_min must be declared so the window is configurable per rig"
    ! grep -F 'There are no hardcoded thresholds' "$formula" >/dev/null ||
        fail "check-polecat-health must not regress to threshold-free eyeballing; that phrasing invited the gp-9ly improvisation"

    # A `Z` suffix is a claim the value is UTC. Any format string in the
    # formula that emits one must be produced under `date -u` — formatting a
    # local time and appending `Z` is the original bug, in prose form.
    local offenders
    offenders=$(grep -n '%H:%M:%SZ' "$formula" | grep -v 'date -u' || true)
    [[ -z "$offenders" ]] ||
        fail "every Z-suffixed timestamp format in the witness formula must be under 'date -u'; offending lines: $offenders"
    grep -F 'Never format a local mtime with a' "$formula" >/dev/null ||
        fail "the formula must state the local-mtime-with-Z prohibition outright"
}

test_no_formula_step_executes_through_ambient_gc_pack_dir() {
    # The bug class behind gp-fid (usage-stamp), gp-px5 (parked-check) and gp-3qb
    # (witness-heartbeat-check and polecat-progress-check): GC_PACK_DIR is set by
    # `gc` when `gc` invokes a pack command, and by a pack.toml service or an
    # oversight-rig order. It is NOT in an agent's environment, and a formula step
    # is prose an agent shells out by hand in its own session. So
    # "${GC_PACK_DIR:-}/assets/scripts/x.sh" expands to "/assets/scripts/x.sh",
    # and when it sits behind an `[ -x ]` guard the failure is downgraded to a
    # skip that prints a considered-sounding fallback. Four separate checks
    # shipped dead this way.
    #
    # Each of those was caught only after it had been silently no-op in
    # production, so this guard covers the class rather than the instances: no
    # step body may mention GC_PACK_DIR at all. Route it through a pack command.
    #
    # Scoped to FENCED CODE BLOCKS. The prose around these snippets quotes the
    # broken path on purpose — that is how the pack records why it is broken —
    # and a whole-description match would forbid explaining the bug. Fencing is
    # also what makes this construct-agnostic: it catches a path variable of any
    # name, a bare `bash "$GC_PACK_DIR/..."`, and a `cat` of a pack-relative doc,
    # none of which a name-based pattern like `^CHECK=` would see.
    local offenders
    offenders=$(python3 - "$GASTOWN" <<'PY'
import glob, os, sys, tomllib

offenders = []
for path in sorted(glob.glob(os.path.join(sys.argv[1], "formulas", "*.toml"))):
    with open(path, "rb") as handle:
        doc = tomllib.load(handle)
    for step in doc.get("steps", []):
        fenced = False
        for line in step.get("description", "").splitlines():
            if line.lstrip().startswith("```"):
                fenced = not fenced
                continue
            if fenced and "GC_PACK_DIR" in line:
                offenders.append(
                    "%s [%s]: %s"
                    % (os.path.basename(path), step.get("id", "?"), line.strip())
                )
if offenders:
    print("\n".join(offenders))
    raise SystemExit(1)
PY
    ) || {
        fail "formula step bodies must not reach for \$GC_PACK_DIR; it is unset in an agent shell. Add a pack command under commands/ and call it through \`gc\`:
$offenders"
    }
}

# step_description <formula> <step-id> — one step's description text on stdout.
# Guards below have to distinguish "this step says X" from "some other step in
# the same file says X": mol-witness-patrol legitimately files warrants in
# check-polecat-health, and a whole-file grep for warrant filing would pass on a
# parked step that filed one too.
step_description() {
    python3 - "$1" "$2" <<'PY'
import sys, tomllib

with open(sys.argv[1], "rb") as handle:
    doc = tomllib.load(handle)
for step in doc.get("steps", []):
    if step.get("id") == sys.argv[2]:
        sys.stdout.write(step.get("description", ""))
        break
else:
    raise SystemExit(f"no step {sys.argv[2]!r} in {sys.argv[1]}")
PY
}

test_parked_session_detector_is_wired_into_the_patrol() {
    # gp-px5: a session parked at a provider usage-limit prompt reports `active`
    # to `gc session list`, resolves to `active` for liveness, and is not
    # looping — so the controller, orphan recovery, and the stuck-polecat check
    # each correctly declined it, and one held a P1 bead for 17h. The detector
    # is the only thing that models this state; these guards keep it reachable.
    local formula check cmd block
    formula="$GASTOWN/formulas/mol-witness-patrol.toml"
    check="$GASTOWN/assets/scripts/parked-session-check.sh"
    cmd="$GASTOWN/commands/parked-check/run.sh"

    [[ -x "$check" ]] || fail "missing or non-executable assets/scripts/parked-session-check.sh"
    [[ -x "$cmd" ]] || fail "missing or non-executable commands/parked-check/run.sh"
    [[ -f "$GASTOWN/commands/parked-check/help.md" ]] ||
        fail "missing commands/parked-check/help.md"
    parse_toml "$formula"

    # The wrapper is the whole point of the command: gc sets GC_PACK_DIR for
    # pack COMMANDS and never in an agent's shell, so a formula that reads
    # "$GC_PACK_DIR/assets/scripts/..." resolves to "/assets/scripts/..." and
    # silently measures nothing. usage-stamp was routed through gc for exactly
    # this reason (gp-fid); the check must not regress to the path form.
    grep -F 'gc gastown parked-check' "$formula" >/dev/null ||
        fail "the witness patrol must invoke the detector as 'gc gastown parked-check'"
    ! grep -F 'GC_PACK_DIR' "$formula" | grep -F 'parked' >/dev/null ||
        fail "the parked check must not be resolved via \$GC_PACK_DIR; it is unset in an agent shell"
    grep -F 'GC_PACK_DIR' "$cmd" >/dev/null ||
        fail "commands/parked-check/run.sh must resolve the detector through GC_PACK_DIR"

    # A step nothing `needs` never runs. The chain is the wiring.
    python3 - "$formula" <<'PY'
import sys, tomllib

with open(sys.argv[1], "rb") as handle:
    steps = tomllib.load(handle)["steps"]
ids = [s["id"] for s in steps]
if "check-parked-sessions" not in ids:
    raise SystemExit("mol-witness-patrol has no check-parked-sessions step")
needed = {n for s in steps for n in s.get("needs", [])}
if "check-parked-sessions" not in needed:
    raise SystemExit("check-parked-sessions is not in any step's needs — it would never run")
PY

    grep -F '[vars.parked_settle_secs]' "$formula" >/dev/null ||
        fail "parked_settle_secs must be declared so the settle gap is configurable per rig"
    grep -F '{{parked_settle_secs}}' "$formula" >/dev/null ||
        fail "the settle gap must come from the formula var, not a number invented per cycle"

    block=$(step_description "$formula" check-parked-sessions)

    grep -F 'gc session reset' <<<"$block" >/dev/null ||
        fail "check-parked-sessions must name 'gc session reset' as the remedy"
    grep -E 'git -C "\$[A-Z_]+" status --porcelain' <<<"$block" >/dev/null ||
        fail "the reset must be gated on a runnable clean-worktree precondition, not a vibe"
    # gp-6k8: the precondition must probe BOTH directory scopes. A session parked
    # before branch-setup has no `metadata.work_dir` at all, so gating on that key
    # alone reports "nothing is at risk on disk" for precisely the sessions whose
    # uncommitted work is sitting in the `gc.work_dir` agent home.
    grep -F 'gc.work_dir' <<<"$block" >/dev/null ||
        fail "the clean-worktree precondition must also probe the gc.work_dir agent home (gp-6k8)"
    grep -F 'PROBED' <<<"$block" >/dev/null ||
        fail "the precondition must distinguish verified-clean from nothing-measured (gp-6k8)"
    grep -F 'parked_reset_count' <<<"$block" >/dev/null ||
        fail "a reset must be recorded durably so a repeat offender is visible to the next cycle"

    # The two wrong tools, asserted as INVOCATIONS rather than words. The step
    # names both in prose to explain why each is wrong, so a word-level grep
    # matches its own documentation — the first version of this guard failed on
    # the sentence "`gc runtime drain` is COOPERATIVE". A command the witness
    # would actually run starts its line; a backticked mention does not.
    ! grep -F -- '--label=warrant' <<<"$block" >/dev/null ||
        fail "a parked session must not be warranted; the dog would kill an agent over a budget banner"
    ! grep -E '^[[:space:]]*gc runtime drain' <<<"$block" >/dev/null ||
        fail "drain is cooperative and a parked session never polls drain-check; it must not be the remedy"
    ! grep -E 'gc bd update[^|]*--assignee' <<<"$block" >/dev/null ||
        fail "releasing the bead is not the remedy — the parked session re-claims it within minutes (measured)"

    # The misrouting hole: a parked session produces exactly the evidence
    # check-polecat-health treats as a confirmed stall (no writes, no bead
    # updates, an unchanged pane), so without this cross-reference the very
    # next step files a warrant on it.
    block=$(step_description "$formula" check-polecat-health)
    grep -F 'parked' <<<"$block" >/dev/null ||
        fail "check-polecat-health must rule out the parked verdict before reading a failed peek as a stall"
}

test_worktree_reaper_is_wired_into_the_patrol() {
    # gp-a7z: no component owned a polecat worktree's death. The refinery
    # deletes the BRANCH after merge, orphan recovery keys on a
    # live-but-unreachable ASSIGNEE (a landed bead is closed and unassigned),
    # and the controller manages processes. Worktrees accumulated one per
    # completed bead — 5 at filing, 8 two days later. These guards keep the
    # reaper reachable and keep its predicate out of the formula prose.
    local formula check cmd block
    formula="$GASTOWN/formulas/mol-witness-patrol.toml"
    check="$GASTOWN/assets/scripts/polecat-worktree-reap.sh"
    cmd="$GASTOWN/commands/worktree-reap/run.sh"

    [[ -x "$check" ]] || fail "missing or non-executable assets/scripts/polecat-worktree-reap.sh"
    [[ -x "$cmd" ]] || fail "missing or non-executable commands/worktree-reap/run.sh"
    [[ -f "$GASTOWN/commands/worktree-reap/help.md" ]] ||
        fail "missing commands/worktree-reap/help.md"
    parse_toml "$formula"

    # Same GC_PACK_DIR trap parked-check and usage-stamp were both routed
    # through `gc` to escape (gp-fid): the var is set for pack COMMANDS and
    # never in an agent's shell, so a formula reading
    # "$GC_PACK_DIR/assets/scripts/..." resolves to "/assets/scripts/..." and
    # silently reaps nothing while reading like it ran.
    grep -F 'gc gastown worktree-reap' "$formula" >/dev/null ||
        fail "the witness patrol must invoke the reaper as 'gc gastown worktree-reap'"
    ! grep -F 'GC_PACK_DIR' "$formula" | grep -F 'worktree-reap' >/dev/null ||
        fail "the reaper must not be resolved via \$GC_PACK_DIR; it is unset in an agent shell"
    grep -F 'GC_PACK_DIR' "$cmd" >/dev/null ||
        fail "commands/worktree-reap/run.sh must resolve the reaper through GC_PACK_DIR"

    # A step nothing `needs` never runs. The chain is the wiring.
    python3 - "$formula" <<'PY'
import sys, tomllib

with open(sys.argv[1], "rb") as handle:
    steps = tomllib.load(handle)["steps"]
ids = [s["id"] for s in steps]
if "reap-landed-worktrees" not in ids:
    raise SystemExit("mol-witness-patrol has no reap-landed-worktrees step")
needed = {n for s in steps for n in s.get("needs", [])}
if "reap-landed-worktrees" not in needed:
    raise SystemExit("reap-landed-worktrees is not in any step's needs — it would never run")
# Salvage must get first refusal on every tree: recovery pushes stranded work to
# a branch, and only then is the tree disposable. Reaping first would race it.
order = {sid: i for i, sid in enumerate(ids)}
if order["reap-landed-worktrees"] < order["recover-orphaned-beads"]:
    raise SystemExit("reap-landed-worktrees must come AFTER recover-orphaned-beads")
PY

    block=$(step_description "$formula" reap-landed-worktrees)

    # The predicate belongs in the script, and the two checks that carry the
    # safety argument must be named in the step so nobody re-derives them
    # loosely: the formula is a prompt, and a vague one invites improvisation
    # (the gp-9ly failure mode).
    grep -F 'git cherry' <<<"$block" >/dev/null ||
        fail "the step must name the patch-id test; ancestry is the wrong one"
    grep -F 'git status --porcelain' <<<"$block" >/dev/null ||
        fail "the step must name the clean-tree precondition"

    # Ancestry must be named ONLY to reject it. `git cherry` exists because the
    # refinery rebases before merging, so a landed branch is often not an
    # ancestor of the target: measured 2026-07-29, gp-px5 and gp-nrm were both
    # closed and clean with zero unmerged patches and is_ancestor=NO. A step
    # that reached for ancestry would leak exactly those trees forever.
    grep -F 'is-ancestor' <<<"$block" >/dev/null ||
        fail "the step must explicitly rule out merge-base --is-ancestor as the landed test"
    ! grep -E '^[[:space:]]*git (-C [^ ]+ )?merge-base --is-ancestor' <<<"$block" >/dev/null ||
        fail "ancestry must be named as the WRONG test, never invoked as the landed check"

    # Agent liveness is the predicate that would have destroyed gp-px5's
    # in-flight work; the step has to say so, in both directions.
    grep -F 'gp-px5' <<<"$block" >/dev/null ||
        fail "the step must cite the gp-px5 near-miss that rules out keying on agent liveness"
    ! grep -E '^[[:space:]]*gc session list' <<<"$block" >/dev/null ||
        fail "the reaper must not consult session liveness; it keys on the bead's terminal state"

    # Reaping is destructive and the whole point is that it is bounded. A step
    # that widened to agent workspaces would take out running agents' homes.
    grep -F 'agent workspace' <<<"$block" >/dev/null ||
        fail "the step must state that agent workspaces are out of scope"

    # Exit 2 means nothing was measured. Recording it as a clean sweep is how
    # an unbounded leak looks healthy — the same asymmetry parked-check pins.
    grep -F 'exit codes' <<<"$(tr '[:upper:]' '[:lower:]' <<<"$block")" >/dev/null ||
        fail "the step must document the reaper's exit codes, including 2 = not measured"
}

test_parked_remedy_is_documented_for_the_witness() {
    # Ask 2 of gp-px5: make the reset the DOCUMENTED remedy. The formula step is
    # where it is executed; the prompt is where a witness reading its own role
    # finds it — including on a cycle where the check could not run.
    local prompt="$GASTOWN/agents/witness/prompt.template.md"

    grep -F 'gc gastown parked-check' "$prompt" >/dev/null ||
        fail "the witness prompt must name the parked-session detector"
    grep -F 'gc session reset' "$prompt" >/dev/null ||
        fail "the witness prompt must name 'gc session reset' as the parked-session remedy"
    ! grep -F 'GC_PACK_DIR/assets/scripts/parked' "$prompt" >/dev/null ||
        fail "the prompt must not resolve the detector via \$GC_PACK_DIR; it is unset in an agent shell"
    grep -F 'last_active' "$prompt" >/dev/null ||
        fail "the prompt must say why last_active cannot be the freshness signal; that blind spot IS the bug"
    grep -F 'cooperative' "$prompt" >/dev/null ||
        fail "the prompt must record that drain is cooperative and a no-op against a parked session"
}

test_polecat_stall_requires_proof_of_life_not_just_a_timestamp() {
    # The other half of gp-9ly: a timestamp is an inference, a live peek is an
    # observation. A rising token counter must be able to overrule staleness,
    # and ordinary mid-flight state must not read as a stall.
    local formula dance
    formula="$GASTOWN/formulas/mol-witness-patrol.toml"
    dance="$GASTOWN/formulas/mol-shutdown-dance.toml"

    grep -F 'OVERRIDES the' "$formula" >/dev/null ||
        fail "proof of life must be stated as overriding the stale verdict, not merely weighed against it"
    grep -F 'rising token counter' "$formula" >/dev/null ||
        fail "the formula must name the token counter as the concrete proof-of-life signal"
    grep -F 'gc session peek "$TARGET_SESSION" --lines 40' "$formula" >/dev/null ||
        fail "the confirmation peek must be a runnable command, not an instruction to 'use judgment'"
    grep -F 'A `stale` row alone never justifies a warrant' "$formula" >/dev/null ||
        fail "warrant filing must be gated on a failed proof-of-life confirmation"
    grep -F 'A large uncommitted diff with zero commits' "$formula" >/dev/null ||
        fail "normal mid-flight state (dirty tree, no commits) must be named as NOT evidence of a stall"
    grep -F 'progress was NOT measured' "$formula" >/dev/null ||
        fail "a check that cannot run must read as unmeasured, never as health"

    # The dog is the last gate before a kill; it needs the same concrete tell.
    grep -F 'rising counter' "$dance" >/dev/null ||
        fail "the shutdown dance must treat a rising token counter as proof of life"
}

# Every patrol agent must own exactly one wisp. That rule was copy-pasted shell
# in six files and drifted apart in three independent ways at once — bare `bd`
# instead of `gc bd`, `--type=wisp` instead of `--type=molecule`, and a missing
# `--include-infra` — each one silently returning nothing, so the agent
# concluded "no wisp exists" and poured a duplicate on every restart. Two of
# the six carried no reconcile query at all and simply poured.
#
# The fix was to delete all six copies in favour of `gc gastown wisp-reconcile`.
# This test is what keeps them deleted: without it the next hand-rolled query
# reintroduces the leak, and a leak is invisible until someone counts wisps.
test_wisp_reconcile_is_the_only_implementation() {
    local cmd="$GASTOWN/commands/wisp-reconcile/run.sh"
    local script="$GASTOWN/assets/scripts/wisp-reconcile.sh"
    local doc hits

    [[ -f "$script" ]] || fail "missing assets/scripts/wisp-reconcile.sh"
    [[ -f "$cmd" ]] || fail "missing commands/wisp-reconcile/run.sh"
    [[ -x "$cmd" ]] || fail "commands/wisp-reconcile/run.sh must be executable"
    [[ -f "$GASTOWN/commands/wisp-reconcile/help.md" ]] ||
        fail "missing commands/wisp-reconcile/help.md"

    for doc in "$GASTOWN"/formulas/mol-*-patrol.toml \
               "$GASTOWN"/agents/witness/prompt.template.md \
               "$GASTOWN"/agents/refinery/prompt.template.md \
               "$GASTOWN"/agents/deacon/prompt.template.md; do
        # A hand-rolled RECONCILE listing is the original defect: assignee +
        # molecule type is the shape that answers "which wisps do I own", and
        # there is exactly one correct spelling of it, in the script. Listing
        # molecules for other reasons (e.g. closed wisps for predecessor
        # context) is unrelated and stays allowed.
        ! grep -E 'gc bd list[^|]*--assignee[^|]*--type=molecule' "$doc" >/dev/null ||
            fail "${doc#$GASTOWN/}: hand-rolls the wisp reconcile query; call 'gc gastown wisp-reconcile' instead"
        # Not a valid gc bd type — matches nothing, silently. Only flag it in
        # an actual command; prose explaining why it was wrong is welcome.
        ! grep -E 'gc bd [a-z]+[^|]*--type=wisp' "$doc" >/dev/null ||
            fail "${doc#$GASTOWN/}: filters --type=wisp, which matches nothing"
        # An unguarded pour leaks a wisp per restart; `ensure` reuses instead.
        ! grep -E 'gc bd mol wisp mol-[a-z]+-patrol' "$doc" >/dev/null ||
            fail "${doc#$GASTOWN/}: pours a patrol wisp directly; use 'wisp-reconcile ensure'"
        # GC_PACK_DIR is set for pack COMMANDS, never in an agent's shell, so
        # this path resolves to /assets/... and the fail-closed guard behind it
        # halts the patrol loop on its first cycle — worse than the leak.
        ! grep -F 'GC_PACK_DIR' "$doc" | grep -F 'wisp-reconcile' >/dev/null ||
            fail "${doc#$GASTOWN/}: resolves wisp-reconcile via \$GC_PACK_DIR, which is unset in an agent shell"
    done

    # The three patrol formulas must actually call it — a guard that greps only
    # for absence would pass on a file that reconciles nothing at all.
    for doc in "$GASTOWN"/formulas/mol-witness-patrol.toml \
               "$GASTOWN"/formulas/mol-refinery-patrol.toml \
               "$GASTOWN"/formulas/mol-deacon-patrol.toml; do
        grep -F 'gc gastown wisp-reconcile ensure' "$doc" >/dev/null ||
            fail "${doc#$GASTOWN/}: never calls 'gc gastown wisp-reconcile ensure'"
    done

    # `ensure` must never hand back the wisp the caller is about to burn. A
    # patrol loop that selects itself as its own successor burns to zero wisps
    # and dies silently — strictly worse than the duplicate leak.
    #
    # The script defaults --except to $GC_BEAD_ID, which holds only where the
    # runtime injected it. Every successor call therefore resolves the id with
    # `current` and passes it explicitly, so the guard survives an unset
    # GC_BEAD_ID.
    #
    # Checked per CALL SITE, not per file. An earlier version of this test
    # grepped the whole file for '--except' and was vacuous: the prose
    # explaining why the flag matters satisfied it, so dropping the flag from
    # the actual command still passed.
    #
    # `NEXT=` is what distinguishes a successor call from a bootstrap one.
    # Bootstrap calls assign to `WISP=` and correctly carry no --except —
    # an agent with no wisp has nothing to exclude and nothing to burn.
    local folded call
    for doc in "$GASTOWN"/formulas/mol-witness-patrol.toml \
               "$GASTOWN"/formulas/mol-refinery-patrol.toml \
               "$GASTOWN"/formulas/mol-deacon-patrol.toml \
               "$GASTOWN"/agents/refinery/prompt.template.md \
               "$GASTOWN"/agents/deacon/prompt.template.md \
               "$GASTOWN"/agents/witness/prompt.template.md; do
        # Fold backslash continuations first: three of these calls wrap across
        # lines, and a per-line grep would never see their flags.
        folded=$(awk '{while (/\\$/ && (getline nxt) > 0) {sub(/\\$/, ""); $0 = $0 nxt} print}' "$doc")
        hits=$(printf '%s\n' "$folded" | grep -cE 'NEXT=.*wisp-reconcile ensure' || true)
        [[ "$hits" -gt 0 ]] ||
            fail "${doc#$GASTOWN/}: no 'NEXT=... wisp-reconcile ensure' call; the successor pour is missing"
        while IFS= read -r call; do
            [[ -n "$call" ]] || continue
            [[ "$call" == *--except* ]] ||
                fail "${doc#$GASTOWN/}: 'NEXT=... wisp-reconcile ensure' without --except; it can return the wisp being burned"
        done <<<"$(printf '%s\n' "$folded" | grep -E 'NEXT=.*wisp-reconcile ensure' || true)"
    done
}

test_every_close_states_whether_the_fix_is_deployed() {
    # gp-apx: closing a pack bead asserts AUTHORSHIP — the patch is an ancestor of
    # the target branch. It says nothing about DEPLOYMENT. A city runs a commit
    # pinned in packs.lock, and advancing that pin is a separate act no close path
    # performs or waits for. gp-haf, gp-dlq and gp-px5 were each closed while
    # still live as bugs, and read exactly like the beads beside them that were
    # genuinely fixed.
    local formula check cmd
    formula="$GASTOWN/formulas/mol-refinery-patrol.toml"
    check="$GASTOWN/assets/scripts/deploy-check.sh"
    cmd="$GASTOWN/commands/deploy-check/run.sh"

    [[ -x "$check" ]] || fail "missing or non-executable assets/scripts/deploy-check.sh"
    [[ -x "$cmd" ]] || fail "missing or non-executable commands/deploy-check/run.sh"
    [[ -f "$GASTOWN/commands/deploy-check/help.md" ]] ||
        fail "missing commands/deploy-check/help.md"

    # Same wrapper contract as every other check in this pack: gc sets
    # GC_PACK_DIR for pack COMMANDS and never in an agent's shell. Here it is
    # doubly load-bearing — GC_PACK_DIR *is* the installed artifact the check
    # reports on, so resolving it by hand would answer the deployment question
    # against the wrong deployment.
    grep -F 'gc gastown deploy-check' "$formula" >/dev/null ||
        fail "the refinery patrol must invoke the check as 'gc gastown deploy-check'"
    grep -F 'GC_PACK_DIR' "$cmd" >/dev/null ||
        fail "commands/deploy-check/run.sh must resolve the check through GC_PACK_DIR"

    # The load-bearing guard: EVERY close in this formula must state the
    # deployment verdict. A close that forgets it is indistinguishable from a
    # deployed one, which is the whole defect. Checked structurally rather than by
    # counting, so a new close path added later cannot quietly skip it.
    python3 - "$formula" <<'PY' || fail "see above"
import re
import sys
import tomllib

with open(sys.argv[1], "rb") as handle:
    doc = tomllib.load(handle)

problems = []
calls = 0
closes = 0
for step in doc.get("steps", []):
    body = step.get("description", "")
    sid = step.get("id", "?")

    # Fold backslash continuations so a close whose --reason wraps across lines
    # is still seen as one command. Three of these closes wrap.
    folded = re.sub(r"\\\s*\n\s*", " ", body)

    for line in folded.splitlines():
        stripped = line.strip()

        if "gc bd close" in stripped and "--reason" in stripped:
            closes += 1
            if "$DEPLOY_NOTE" not in stripped:
                problems.append(
                    f"{sid}: close without a deployment verdict: {stripped[:120]}"
                )

        if "gc gastown deploy-check" in stripped and "DEPLOY_NOTE=" in stripped:
            calls += 1
            # A non-zero exit is a VERDICT (1 not deployed, 2 undetermined,
            # 3 not applicable), and the merge blocks run under
            # `set -euo pipefail`. Without `|| true` the check would abort a
            # close whose merge already landed — strictly worse than the
            # missing field it was added to record.
            if "|| true" not in stripped:
                problems.append(
                    f"{sid}: deploy-check call without '|| true'; a verdict would abort a landed merge: {stripped[:120]}"
                )
            # Evidence lines belong on stderr; only the reason suffix may reach
            # $DEPLOY_NOTE or the close reason turns into a key=value dump.
            if "2>/dev/null" not in stripped:
                problems.append(
                    f"{sid}: deploy-check call must send evidence to stderr with 2>/dev/null: {stripped[:120]}"
                )
            # The current tip of the target is NOT the fix. A tip that moved past
            # the pin reports "not deployed" for a fix the pin genuinely
            # contains, so the fix's own commit is what gets passed.
            if 'deploy-check "$(git rev-parse' in stripped:
                problems.append(
                    f"{sid}: deploy-check must receive the fix's commit, not a freshly-resolved tip: {stripped[:120]}"
                )

if not closes:
    problems.append("no 'gc bd close --reason' found at all; this guard would be vacuous")
if calls != closes:
    problems.append(f"{closes} close(s) but {calls} deploy-check call(s); every close needs its own")

if problems:
    print("\n".join(problems))
    raise SystemExit(1)
PY
}

test_deployment_verdict_is_documented_for_the_refinery() {
    # The formula step is where the verdict is produced; the prompt is where a
    # refinery reading its own role finds out what it means — including on a cycle
    # where the check could not run. Same split as the parked-session remedy.
    local prompt="$GASTOWN/agents/refinery/prompt.template.md"

    grep -F 'gc gastown deploy-check' "$prompt" >/dev/null ||
        fail "the refinery prompt must name the deployment check"
    grep -F 'authored_not_deployed' "$prompt" >/dev/null ||
        fail "the refinery prompt must name the authored-not-deployed verdict"
    ! grep -F 'GC_PACK_DIR/assets/scripts/deploy' "$prompt" >/dev/null ||
        fail "the prompt must not resolve the check via \$GC_PACK_DIR; it is unset in an agent shell"

    # The two instructions most likely to be "improved" into bugs later: an
    # undeployed bead must still CLOSE (refusing would jam the queue on every
    # fix), and an unevaluable verdict must not read as healthy.
    grep -F 'Still close the bead' "$prompt" >/dev/null ||
        fail "the prompt must say an undeployed bead is still closed; blocking the close would jam the merge queue"
    grep -F 'Treat as NOT deployed' "$prompt" >/dev/null ||
        fail "the prompt must say an undetermined verdict is not deployed; a check that cannot run is not health"
}

test_kill_paths_require_triage_not_judgment() {
    # gp-aik: two patrol steps turned a heuristic signal straight into an
    # irreversible kill. Both fired on a HEALTHY town. orphan-process-cleanup's
    # `ps aux | grep -E 'claude|node'` matched 95 processes across five cities
    # — including this town's OWN tmux server, which appears in that grep
    # because its argv carries the `exec claude ...` it launched, and which sits
    # at ppid=1 with TTY '?' like a textbook orphan. dolt-health's
    # `zombie_count` counted a live, in-use server as a zombie.
    #
    # gp-9ur required pane corroboration before a WARRANT. These guards keep the
    # same rule on the KILL paths, which gp-9ur does not cover.
    local formula check cmd
    formula="$GASTOWN/formulas/mol-deacon-patrol.toml"
    check="$GASTOWN/assets/scripts/kill-triage.sh"
    cmd="$GASTOWN/commands/kill-triage/run.sh"

    [[ -x "$check" ]] || fail "missing or non-executable assets/scripts/kill-triage.sh"
    [[ -x "$cmd" ]] || fail "missing or non-executable commands/kill-triage/run.sh"
    [[ -f "$GASTOWN/commands/kill-triage/help.md" ]] ||
        fail "missing commands/kill-triage/help.md"
    parse_toml "$formula"

    # Both kill paths must route through the triage, via `gc` — the same
    # GC_PACK_DIR trap as worktree-reap. For a triage whose whole job is to
    # REFUSE, a silent no-op is the worst failure: no refusal is printed and
    # the caller proceeds to the kill.
    grep -F 'gc gastown kill-triage' "$formula" >/dev/null ||
        fail "the deacon patrol must triage kill candidates via 'gc gastown kill-triage'"
    grep -F 'gc gastown kill-triage --require-zombie' "$formula" >/dev/null ||
        fail "the dolt-health kill path must pass --require-zombie; zombie_count does not mean stat=Z"
    ! grep -F 'GC_PACK_DIR' "$formula" | grep -F 'kill-triage' >/dev/null ||
        fail "kill-triage must not be resolved via \$GC_PACK_DIR; it is unset in an agent shell"
    grep -F 'GC_PACK_DIR' "$cmd" >/dev/null ||
        fail "commands/kill-triage/run.sh must resolve the triage through GC_PACK_DIR"

    # The struck authorization. "Use judgment" is exactly what failed here:
    # judgment does not survive the fresh-context restarts these agents run on.
    ! grep -F 'Use judgment — this is exactly why an LLM does it' "$formula" >/dev/null ||
        fail "orphan-process-cleanup must not re-authorize killing on judgment alone"

    # The detection query may stay, but only as a candidate generator.
    grep -F 'names suspects, never convicts' "$formula" >/dev/null ||
        fail "the ps/grep detection must be labelled as candidate generation, not an orphan list"

    # zombie_count must never read as "safe to kill".
    grep -F 'zombie_count` does not mean Unix zombie' "$formula" >/dev/null ||
        fail "dolt-health must state that zombie_count is not a Unix zombie count"
}

test_dog_assets_are_pack_local
test_retired_dog_formulas_are_not_reintroduced
test_every_close_states_whether_the_fix_is_deployed
test_deployment_verdict_is_documented_for_the_refinery
test_witness_salvage_reads_work_dir_metadata
test_polecat_health_check_is_measured_not_improvised
test_no_formula_step_executes_through_ambient_gc_pack_dir
test_polecat_stall_requires_proof_of_life_not_just_a_timestamp
test_parked_session_detector_is_wired_into_the_patrol
test_parked_remedy_is_documented_for_the_witness
test_wisp_reconcile_is_the_only_implementation
test_shutdown_dance_contracts_are_executable
test_shutdown_dance_lifecycle_and_audit_contracts
test_composition_is_documented
test_polecat_startup_uses_standard_hook_claim
test_review_leg_contract_forbids_synthetic_mutation
test_refinery_direct_merge_is_worktree_safe_and_fail_closed
test_kill_paths_require_triage_not_judgment

echo "gastown pack asset tests passed"
