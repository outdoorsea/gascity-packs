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
    # `gc.work_dir` is the rig root, not the bead's worktree — a plausible-looking
    # but wrong "fix" that resolves to a non-existent path.
    ! grep -F "jq -r '.gc.work_dir // empty'" "$formula" >/dev/null ||
        fail "witness salvage must not read gc.work_dir; that is the rig root, not the worktree"
}

test_polecat_health_check_is_measured_not_improvised() {
    # gp-9ly: check-polecat-health used to say "there are no hardcoded
    # thresholds... this is judgment work", handing the witness a staleness
    # question with no command to run. The witness improvised `date`
    # arithmetic, formatted a LOCAL-time mtime with a `Z` suffix, compared it
    # against a UTC now, and read 4 minutes of healthy work as ~7h stale. A
    # warrant was filed against a polecat that was working correctly.
    local formula check
    formula="$GASTOWN/formulas/mol-witness-patrol.toml"
    check="$GASTOWN/assets/scripts/polecat-progress-check.sh"

    [[ -x "$check" ]] ||
        fail "polecat-progress-check.sh must exist and be executable; the formula guards on [ -x ]"
    grep -F 'assets/scripts/polecat-progress-check.sh' "$formula" >/dev/null ||
        fail "check-polecat-health must run the deterministic progress check, not improvise timestamp math"
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

test_dog_assets_are_pack_local
test_retired_dog_formulas_are_not_reintroduced
test_witness_salvage_reads_work_dir_metadata
test_polecat_health_check_is_measured_not_improvised
test_polecat_stall_requires_proof_of_life_not_just_a_timestamp
test_shutdown_dance_contracts_are_executable
test_shutdown_dance_lifecycle_and_audit_contracts
test_composition_is_documented
test_polecat_startup_uses_standard_hook_claim
test_review_leg_contract_forbids_synthetic_mutation
test_refinery_direct_merge_is_worktree_safe_and_fail_closed

echo "gastown pack asset tests passed"
