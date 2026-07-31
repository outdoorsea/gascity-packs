#!/usr/bin/env bash
# Guards the no-patch routing path: a bead whose deliverable is NOT a patch
# (metadata.no_code_change=true) must never be selected by the refinery's merge
# queue, and must terminate through the refinery's no-patch triage instead.
#
# The bug this locks down (gp-d5u, observed on ta-af7): a validation-only bead
# produces a zero-diff branch, gets routed into the merge queue anyway, and the
# queue cannot assert "merged" for a branch with no change -- so
# branch_has_real_change() refuses and halt_false_completion fires EVERY time.
# The halt is correct. The defect was handing non-patch work to a patch-merger.
#
# All shell under test is EXTRACTED FROM THE FORMULAS THEMSELVES -- never a copy
# -- so an assertion cannot keep passing while the formula drifts away from it.
#
# What is nailed down here:
#   1. branch_is_empty() in find-work is the EXACT complement of
#      branch_has_real_change() in merge-push, on every arm, proven against real
#      git repositories. If the two ever disagree, a bead falls between them and
#      NEITHER path accepts it -- strictly worse than either arm alone.
#   2. The merge selector excludes both `awaiting_merge` and `no_code_change`,
#      and does so through `tostring`. `--set-metadata k=true` stores a JSON
#      BOOLEAN, and in jq `true != "true"` is TRUE, so a raw string comparison
#      excludes nothing while still reading as a load-bearing filter. That is
#      exactly how the awaiting_merge exclusion shipped inert.
#   3. A confirmed zero-diff flagged bead is blocked, routed to `human`, and
#      carries positive evidence -- distinguishable at a glance from
#      refused_false_completion, which is the cost this fix actually removes.
#   4. A flagged bead whose branch carries a REAL change has the flag cleared
#      and is released to the merge queue. Always fail toward merging real work:
#      a dropped patch is unrecoverable, a spurious merge attempt costs one
#      iteration.
#   5. A branch that is missing on origin is left completely alone. Absence is
#      what a polecat that died before pushing also looks like, so it is never
#      evidence of a deliberate no-patch outcome.
#   6. The triage NEVER closes a bead. Metadata carries no provenance
#      (`gc bd history` versions the issue row but not its metadata), so an
#      auto-close on the flag would hand every polecat a one-key escape from the
#      false-completion guard -- a quieter false completion than the one the
#      halt catches.
#   7. The polecat reconciles the flag against its own diff before handing off,
#      reads it through `tostring`, and never closes the bead itself.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
REFINERY_FORMULA="$ROOT/gastown/formulas/mol-refinery-patrol.toml"
POLECAT_FORMULA="$ROOT/gastown/formulas/mol-polecat-work.toml"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq is required to exercise the merge selector"

# Emit fenced bash block(s) of STEP containing ANCHOR, with {{vars}} rendered
# from the formula's own defaults the way the formula engine renders them.
#
#   extract_step_block FORMULA STEP ANCHOR         -> the one match; dies if != 1
#   extract_step_block FORMULA STEP ANCHOR INDEX   -> the INDEXth match, 0-based
#   count_step_blocks  FORMULA STEP ANCHOR         -> how many blocks match
#
# The unindexed form's exactly-one requirement is deliberate: if a step is
# reorganised and an anchor goes missing or turns ambiguous, this dies loudly
# instead of quietly exercising nothing.
#
# An anchor that legitimately has more than one site takes the indexed form and
# asserts over EVERY one of them. Widening it to "just check the first" would be
# the same silent under-assertion the exactly-one rule exists to prevent, only
# reached by a different route -- and the second site is precisely where a
# guard goes missing, because the first one is the one everybody reads.
extract_step_block() {
    python3 - "$1" "$2" "$3" "${4-}" <<'PY'
import re
import sys
import tomllib

formula, step_id, anchor, index = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(formula, "rb") as handle:
    data = tomllib.load(handle)

step = next(s for s in data["steps"] if s["id"] == step_id)
blocks = [
    b for b in re.findall(r"```bash\n(.*?)```", step["description"], re.S)
    if anchor in b
]
if index == "":
    if len(blocks) != 1:
        sys.exit(
            f"expected exactly 1 {step_id} bash block containing {anchor!r}, "
            f"found {len(blocks)}"
        )
    chosen = blocks[0]
else:
    if int(index) >= len(blocks):
        sys.exit(
            f"asked for {step_id} bash block {index} containing {anchor!r}, "
            f"but only {len(blocks)} match"
        )
    chosen = blocks[int(index)]

rendered = chosen
values = {name: spec.get("default", "") for name, spec in data.get("vars", {}).items()}
values.setdefault("rig_name", "testrig")
values.setdefault("target_branch", "main")
values.setdefault("base_branch", "main")
for name, value in values.items():
    rendered = rendered.replace("{{%s}}" % name, str(value))
sys.stdout.write(rendered)
PY
}

count_step_blocks() {
    python3 - "$1" "$2" "$3" <<'PY'
import re
import sys
import tomllib

formula, step_id, anchor = sys.argv[1], sys.argv[2], sys.argv[3]
with open(formula, "rb") as handle:
    data = tomllib.load(handle)
step = next(s for s in data["steps"] if s["id"] == step_id)
blocks = [
    b for b in re.findall(r"```bash\n(.*?)```", step["description"], re.S)
    if anchor in b
]
sys.stdout.write(str(len(blocks)))
PY
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

TRIAGE="$TMP/triage.sh"
extract_step_block "$REFINERY_FORMULA" find-work NO_PATCH_TRIAGE >"$TRIAGE"
REAL_CHANGE_FN="$TMP/real_change.sh"
extract_step_block "$REFINERY_FORMULA" merge-push 'branch_has_real_change() {' >"$REAL_CHANGE_FN"
SELECTOR="$TMP/selector.sh"
extract_step_block "$REFINERY_FORMULA" find-work 'WORK=$(gc bd list' >"$SELECTOR"
POLECAT_GATE="$TMP/polecat_gate.sh"
extract_step_block "$POLECAT_FORMULA" submit-and-exit 'NO_CODE_CHANGE=$(gc bd show' >"$POLECAT_GATE"

bash -n "$TRIAGE" || fail "the NO_PATCH_TRIAGE block is not valid shell as the formula renders it"

# ---------------------------------------------------------------------------
# 1. branch_is_empty() is the exact complement of branch_has_real_change().
#
# Both functions are pulled from the formulas and run side by side over real
# git history. The scenarios that matter are the ones where a naive inverse
# diverges: commits that revert each other (net-zero diff but a non-zero commit
# count) and a deliberately empty commit. branch_has_real_change() calls both
# "no real change", so branch_is_empty() must call both "empty" -- otherwise the
# triage releases them to a merge queue that then refuses them.
# ---------------------------------------------------------------------------
complement_repo="$TMP/complement"
mkdir -p "$complement_repo"
(
    cd "$complement_repo"
    git init -q .
    git config user.email test@example.com
    git config user.name Test
    printf 'base\n' >file
    git add file
    git commit -qm base
    git branch main-target

    git checkout -q -b tip-equals-target main-target

    git checkout -q -b real-change main-target
    printf 'more\n' >>file
    git commit -qam "a real change"

    git checkout -q -b net-zero main-target
    printf 'x\n' >>file
    git commit -qam "add x"
    git revert --no-edit HEAD >/dev/null

    git checkout -q -b empty-commit main-target
    git commit -q --allow-empty -m "an empty commit"
)

complement_check() {
    # Sourcing both extracted blocks would run their `gc bd list` calls, so pull
    # out just the function definitions by sourcing in a subshell where only the
    # definitions are needed: sed the function bodies out by brace matching.
    (
        cd "$complement_repo"
        # shellcheck disable=SC1090
        eval "$(python3 - "$TRIAGE" branch_is_empty <<'PY'
import sys
src = open(sys.argv[1]).read()
name = sys.argv[2]
start = src.index(f"{name}() {{")
depth = 0
for i in range(start, len(src)):
    if src[i] == "{":
        depth += 1
    elif src[i] == "}":
        depth -= 1
        if depth == 0:
            sys.stdout.write(src[start:i + 1])
            break
else:
    sys.exit(f"could not brace-match {name}")
PY
)"
        eval "$(python3 - "$REAL_CHANGE_FN" branch_has_real_change <<'PY'
import sys
src = open(sys.argv[1]).read()
name = sys.argv[2]
start = src.index(f"{name}() {{")
depth = 0
for i in range(start, len(src)):
    if src[i] == "{":
        depth += 1
    elif src[i] == "}":
        depth -= 1
        if depth == 0:
            sys.stdout.write(src[start:i + 1])
            break
else:
    sys.exit(f"could not brace-match {name}")
PY
)"
        set +e
        branch_has_real_change main-target "$1"
        real=$?
        branch_is_empty main-target "$1"
        empty=$?
        set -e
        printf '%s:%s\n' "$real" "$empty"
    )
}

for scenario in tip-equals-target real-change net-zero empty-commit no-such-ref; do
    verdict=$(complement_check "$scenario")
    case "$verdict" in
        0:1|1:0|2:2) ;;
        *)
            fail "branch_is_empty is not the complement of branch_has_real_change for '$scenario': got has_real:is_empty=$verdict (want 0:1, 1:0, or 2:2)"
            ;;
    esac
done

# Pin the direction too, not just the complement relation: a pair of functions
# that both inverted would still "complement" each other while routing every
# bead the wrong way.
[ "$(complement_check tip-equals-target)" = "1:0" ] \
    || fail "a branch whose tip equals the target must read has_real=1 / is_empty=0"
[ "$(complement_check real-change)" = "0:1" ] \
    || fail "a branch with a real change must read has_real=0 / is_empty=1"
[ "$(complement_check net-zero)" = "1:0" ] \
    || fail "a net-zero branch (commits that cancel out) must read as EMPTY, not as a merge candidate"
[ "$(complement_check no-such-ref)" = "2:2" ] \
    || fail "an unevaluable ref must fail closed (status 2) in both predicates"

# ---------------------------------------------------------------------------
# 2. The merge selector excludes both markers, in either JSON spelling.
# ---------------------------------------------------------------------------
SEL_PROGRAM=$(python3 - "$SELECTOR" <<'PY'
import re
import sys
src = open(sys.argv[1]).read()
match = re.search(r"jq -r '(.*?)'\)", src, re.S)
if not match:
    sys.exit("could not find the jq selector program in the work-selection block")
sys.stdout.write(match.group(1))
PY
)

# The selector program yields only the FIRST survivor, which cannot tell "every
# excluded bead was dropped" from "the one excluded bead that happened to sort
# first was dropped". Rewrite its tail to emit the whole survivor set, and fail
# loudly if the tail is not the shape this rewrite expects -- silently falling
# back to the weaker single-id check is how an assertion stops asserting.
SEL_ALL=$(python3 - <<'PY' "$SEL_PROGRAM"
import sys
program = sys.argv[1]
tail = "][0].id // empty"
if not program.endswith(tail):
    sys.exit(
        "the merge selector no longer ends in %r, so this test cannot widen it "
        "to all survivors; update the rewrite below to match the new shape" % tail
    )
sys.stdout.write(program[: -len(tail)] + '] | map(.id) | join(",")')
PY
)

cat >"$TMP/beads.json" <<'JSON'
[{"id":"aw-bool","metadata":{"awaiting_merge":true,"branch":"b"}},
 {"id":"aw-string","metadata":{"awaiting_merge":"true","branch":"b"}},
 {"id":"ncc-bool","metadata":{"no_code_change":true,"branch":"b"}},
 {"id":"ncc-string","metadata":{"no_code_change":"true","branch":"b"}},
 {"id":"ncc-false","metadata":{"no_code_change":false,"branch":"b"}},
 {"id":"mergeable","metadata":{"branch":"b"}}]
JSON

survivors=$(jq -r "$SEL_ALL" "$TMP/beads.json") \
    || fail "the widened merge selector is not a valid jq program: $SEL_ALL"

for excluded in aw-bool aw-string ncc-bool ncc-string; do
    case ",$survivors," in
        *",$excluded,"*)
            fail "merge selector did not exclude '$excluded' (survivors: $survivors). --set-metadata k=true stores a JSON boolean, so the comparison must go through tostring."
            ;;
    esac
done
for kept in ncc-false mergeable; do
    case ",$survivors," in
        *",$kept,"*) ;;
        *) fail "merge selector wrongly excluded '$kept' (survivors: $survivors)" ;;
    esac
done

# The selector must also still pick something, or "excludes everything" would
# satisfy every exclusion assertion above.
first=$(jq -r "$SEL_PROGRAM" "$TMP/beads.json")
case "$first" in
    ncc-false|mergeable) ;;
    *) fail "merge selector picked '$first'; a mergeable bead must still be selectable" ;;
esac

# The cast is the fix; assert it textually too, so a future edit that drops
# `tostring` fails here with the reason rather than only failing the data test.
for marker in awaiting_merge no_code_change; do
    printf '%s' "$SEL_PROGRAM" | grep -Fq ".metadata.$marker // \"\") | tostring" \
        || fail "the merge selector must compare .metadata.$marker through tostring; a raw jq comparison against \"true\" never matches the stored boolean"
done

# ---------------------------------------------------------------------------
# 3-6. Run the triage against a real remote, once per outcome.
# ---------------------------------------------------------------------------
write_gc_stub() {
    cat >"$1/gc" <<'SH'
#!/usr/bin/env sh
case "gc $1 $2" in
    "gc bd show")
        cat "$GC_BEAD_JSON"
        exit 0
        ;;
    "gc bd list")
        case "$*" in
            *no_code_change=true*)
                if [ -n "${GC_LIST_NOPATCH:-}" ]; then cat "$GC_LIST_NOPATCH"; else printf '[]\n'; fi
                ;;
            *)
                printf '[]\n'
                ;;
        esac
        exit 0
        ;;
esac
printf 'gc %s\n' "$*" >>"$GC_LOG"
exit 0
SH
    chmod +x "$1/gc"
}

# Build a sandbox with a bare origin, a target branch, and BRANCH_KIND deciding
# what the flagged branch looks like on origin:
#   empty   -> pushed, tip identical to the target (the benign case)
#   real    -> pushed, carries a real commit (the flag is wrong)
#   missing -> never pushed (indistinguishable from a dead polecat)
run_triage() {
    branch_kind="$1"
    sandbox="$TMP/triage-$branch_kind"
    mkdir -p "$sandbox/bin"
    write_gc_stub "$sandbox/bin"

    git init -q --bare "$sandbox/origin.git"
    git init -q "$sandbox/work"
    (
        cd "$sandbox/work"
        git config user.email test@example.com
        git config user.name Test
        git remote add origin "$sandbox/origin.git"
        printf 'base\n' >file
        git add file
        git commit -qm base
        git push -q origin HEAD:refs/heads/main
        git checkout -q -b polecat/np-1
        case "$branch_kind" in
            real)
                printf 'patch\n' >>file
                git commit -qam "a real patch"
                git push -q origin HEAD:refs/heads/polecat/np-1
                ;;
            empty)
                git push -q origin HEAD:refs/heads/polecat/np-1
                ;;
            missing) ;;
        esac
    )

    cat >"$sandbox/bead.json" <<'JSON'
[{"id":"np-1","metadata":{"branch":"polecat/np-1","target":"main","no_code_change":true,
  "no_code_change_evidence":"switchyard: 4 PRD-263 verdicts recorded; verified by list_criteria"}}]
JSON
    printf '[{"id":"np-1"}]\n' >"$sandbox/list.json"
    : >"$sandbox/gc.log"

    (
        cd "$sandbox/work"
        PATH="$sandbox/bin:$PATH" \
        GC_AGENT=testrig/gastown.refinery \
        GC_RIG=testrig \
        GC_BEAD_JSON="$sandbox/bead.json" \
        GC_LIST_NOPATCH="$sandbox/list.json" \
        GC_LOG="$sandbox/gc.log" \
        bash "$TRIAGE" >"$sandbox/stdout.log" 2>&1
    ) || fail "the triage block exited non-zero for branch_kind=$branch_kind"

    cat "$sandbox/gc.log"
}

# --- the benign case: confirmed zero-diff -> blocked, routed to human ---
empty_log=$(run_triage empty)
printf '%s' "$empty_log" | grep -Fq -- "--status=blocked" \
    || fail "a confirmed zero-diff flagged bead must be blocked; got: $empty_log"
printf '%s' "$empty_log" | grep -Fq -- "--set-metadata gc.routed_to=human" \
    || fail "a confirmed zero-diff flagged bead must route to human, never back to the polecat pool; got: $empty_log"
printf '%s' "$empty_log" | grep -Fq -- "--set-metadata merge_result=no_patch_needs_human" \
    || fail "the terminal state must be named no_patch_needs_human so it is distinguishable at a glance from refused_false_completion; got: $empty_log"
printf '%s' "$empty_log" | grep -Fq "no_code_change_evidence" \
 || printf '%s' "$empty_log" | grep -Fq "switchyard: 4 PRD-263 verdicts" \
    || fail "the polecat's evidence must travel onto the terminal note -- carrying it is what turns an investigation into a seconds-long call; got: $empty_log"
printf '%s' "$empty_log" | grep -Fq -- "--assignee=\"\"" \
    || printf '%s' "$empty_log" | grep -Fq -- "--assignee=" \
    || fail "the bead must be unassigned when it is handed to a human; got: $empty_log"

# The no-auto-close invariant. This is the self-certification hole staying shut:
# metadata has no provenance, so the flag alone must never terminate a bead as
# done.
printf '%s' "$empty_log" | grep -Eq 'gc bd close|--status=closed' \
    && fail "the triage must NEVER close a bead: metadata carries no provenance, so closing on no_code_change alone would let any polecat self-certify out of the false-completion guard; got: $empty_log"

# --- the flag is wrong: a real change -> flag cleared, released to merge ---
real_log=$(run_triage real)
printf '%s' "$real_log" | grep -Fq -- "--unset-metadata no_code_change" \
    || fail "a flagged branch carrying a real change must have the flag cleared so the merge queue takes it; got: $real_log"
printf '%s' "$real_log" | grep -Fq -- "--status=blocked" \
    && fail "a flagged branch carrying a real change must NOT be blocked -- a patch that exists must be merged, whatever the flag claimed; got: $real_log"
printf '%s' "$real_log" | grep -Eq 'gc bd close|--status=closed' \
    && fail "the triage must never close a bead that carries a real change; got: $real_log"

# --- absence is not evidence: branch missing on origin -> no mutation at all ---
missing_log=$(run_triage missing)
printf '%s' "$missing_log" | grep -Fq "gc bd update" \
    && fail "a flagged bead whose branch is absent from origin must be left untouched: absence is exactly what a polecat that died before pushing looks like, so it is never evidence of a deliberate no-patch outcome; got: $missing_log"

# ---------------------------------------------------------------------------
# 7. The polecat reconciles the flag against its own diff before handing off.
# ---------------------------------------------------------------------------
grep -Fq 'no_code_change | tostring' "$POLECAT_GATE" \
    || fail "the polecat must read metadata.no_code_change through tostring; --set-metadata k=true stores a JSON boolean"

# Assert on the CONDITION of each branch, not merely on the block containing it.
# `COMMITS_AHEAD` appears in the surrounding notes too, so a block-level grep
# stays green even when the guard itself is deleted -- which is precisely the
# mutation that turns the flag into a self-certifying escape hatch.
guard_condition() {
    # Emit the `if` line of BLOCK that opens the branch containing NEEDLE.
    python3 - "$1" "$2" <<'PY'
import sys
block, needle = sys.argv[1], sys.argv[2]
lines = block.splitlines()
target = next((i for i, line in enumerate(lines) if needle in line), None)
if target is None:
    sys.exit(f"{needle!r} not found in the extracted block")
for i in range(target, -1, -1):
    if lines[i].lstrip().startswith("if "):
        sys.stdout.write(lines[i].strip())
        break
else:
    sys.exit(f"no enclosing `if` found for {needle!r}")
PY
}

POLECAT_CLEAR=$(extract_step_block "$POLECAT_FORMULA" submit-and-exit '--unset-metadata no_code_change')
clear_guard=$(guard_condition "$POLECAT_CLEAR" '--unset-metadata no_code_change')
printf '%s' "$clear_guard" | grep -Fq 'COMMITS_AHEAD' \
    || fail "the polecat's flag-clearing branch must be guarded on the real commit count, not on the flag alone; guard was: $clear_guard"
printf '%s' "$clear_guard" | grep -Fq -- '-gt 0' \
    || fail "the flag is cleared only when the branch actually carries commits; guard was: $clear_guard"

# EVERY site that records no-patch evidence must be guarded on a genuinely empty
# branch -- not merely the first one. The formula has more than one legitimately:
# one reconciles a flag someone else filed at dispatch, another sets the flag on
# an unflagged empty branch (gp-dn1, the case that previously had no exit at
# all). Asserting only the first would leave the newer site free to record
# evidence -- or set the marker -- on a branch carrying real commits.
evidence_sites=$(count_step_blocks "$POLECAT_FORMULA" submit-and-exit 'no_code_change_evidence')
[ "$evidence_sites" -ge 1 ] \
    || fail "submit-and-exit records no_code_change_evidence nowhere; the refinery's no-patch triage has nothing to carry to the human"
site=0
while [ "$site" -lt "$evidence_sites" ]; do
    evidence_block=$(extract_step_block "$POLECAT_FORMULA" submit-and-exit 'no_code_change_evidence' "$site")
    evidence_guard=$(guard_condition "$evidence_block" 'no_code_change_evidence') \
        || fail "no_code_change_evidence site $site is not inside any \`if\` at all, so nothing stops it running on a branch that carries commits"
    printf '%s' "$evidence_guard" | grep -Fq 'COMMITS_AHEAD' \
        || fail "the polecat must confirm the branch is genuinely empty before recording no-patch evidence (site $site of $evidence_sites); guard was: $evidence_guard"
    printf '%s' "$evidence_guard" | grep -Fq '"0"' \
        || fail "no-patch evidence is recorded only for a branch with zero commits ahead (site $site of $evidence_sites); guard was: $evidence_guard"
    site=$((site + 1))
done

# Setting the marker is the strictly stronger act: evidence is a note, but the
# flag is what routes the bead out of the merge queue. An unguarded set is a
# one-line self-certification out of the false-completion guard, so every site
# that sets it carries the same zero-commit guard.
setter_sites=$(count_step_blocks "$POLECAT_FORMULA" submit-and-exit '--set-metadata no_code_change=true')
[ "$setter_sites" -ge 1 ] \
    || fail "no submit-and-exit block SETS no_code_change; the refinery's triage selects on a marker nothing writes, which is the gp-dn1 defect exactly"
site=0
while [ "$site" -lt "$setter_sites" ]; do
    setter_block=$(extract_step_block "$POLECAT_FORMULA" submit-and-exit '--set-metadata no_code_change=true' "$site")
    setter_guard=$(guard_condition "$setter_block" '--set-metadata no_code_change=true') \
        || fail "the block setting no_code_change (site $site) is not inside any \`if\`; a bare set flags any branch it is run against, whatever the diff says"
    printf '%s' "$setter_guard" | grep -Fq 'COMMITS_AHEAD' \
        || fail "setting no_code_change must be guarded on the real commit count, never on the polecat's belief about its own work (site $site); guard was: $setter_guard"
    printf '%s' "$setter_guard" | grep -Fq '"0"' \
        || fail "no_code_change is set only for a branch with zero commits ahead (site $site); guard was: $setter_guard"
    site=$((site + 1))
done

SUBMIT_STEP=$(python3 - "$POLECAT_FORMULA" <<'PY'
import sys
import tomllib
data = tomllib.load(open(sys.argv[1], "rb"))
step = next(s for s in data["steps"] if s["id"] == "submit-and-exit")
sys.stdout.write(step["description"])
PY
)
printf '%s' "$SUBMIT_STEP" | grep -Eq '^gc bd close|gc bd close "\$WORK_BEAD_ID"' \
    && fail "the polecat must never close its own implementation bead, no-patch or not"

echo "PASS: no_code_change routing (predicate complement, selector exclusions, triage outcomes, no auto-close, polecat reconciliation)"
