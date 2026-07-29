#!/usr/bin/env bash
# Guards the pool-return routing invariant across the Gastown pack.
#
#   open + unassigned + metadata.branch present => gc.routed_to non-empty
#
# Pool demand keys on `gc.routed_to` and nothing else -- not open status, not
# `gc bd ready` membership. A bead returned to the pool without it generates
# zero demand: no polecat is spawned for it and none auto-claims it. The bead
# still reads as perfectly healthy in every listing (open, ready, unassigned,
# branch intact on origin, good actionable rejection_reason), so no other check
# in the town can see it and it sits forever. That is gp-982, which stranded
# `ml-b2y.1` and `ml-5qc.7` in meety-local by two different routes at once.
#
# Because the failure is invisible at runtime, it has to be caught at build
# time. What is nailed down here:
#
#   1. EVERY pool return in the pack routes. The scan is over logical commands
#      extracted from the formulas and prompt templates THEMSELVES -- never a
#      copy -- so a new reject path added later without routing fails CI
#      instead of silently parking beads.
#   2. The refinery's reject sites route to the polecat pool specifically, and
#      do it in the same `gc bd update` that reopens the bead (splitting the
#      chain leaves a crash window where the bead is open but unroutable).
#   3. EVERY `gc workflow reopen-source` call routes. It reopens and unassigns
#      but does NOT route, so a bare call strands the very work it just
#      rescued -- and because no `--assignee=""` appears, check 1 cannot see it.
#      This is the second route into the bug and the one `ml-b2y.1` took.
#      Scanned in prompt templates as well as formulas: a quick-reference table
#      row is the form an agent actually copies, and the witness's "Recover
#      orphaned bead" row shipped unrouted while the prose above it explained
#      routing at length.
#   4. The witness patrol actually runs the invariant sweep, and the sweep is
#      wired into the step chain rather than orphaned.
#   5. The sweep catches both real-world arrival paths (refinery rejection and
#      witness salvage) while sparing deliberate `auto_push=false` halts, which
#      set gc.routed_to="" ON PURPOSE. Re-routing those would resume work an
#      operator explicitly opted out of -- a worse bug than the one being fixed.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WITNESS_FORMULA="$ROOT/gastown/formulas/mol-witness-patrol.toml"
REFINERY_FORMULA="$ROOT/gastown/formulas/mol-refinery-patrol.toml"
POLECAT_FORMULA="$ROOT/gastown/formulas/mol-polecat-work.toml"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq is required to exercise the sweep filter"

# Emit every logical `gc bd update` command in FILE, one per line.
#
# "Logical" is the whole point. These commands are written across several
# physical lines with trailing backslashes, so a line-oriented grep sees
# `--assignee=""` and the `--set-metadata gc.routed_to=...` that satisfies it
# as unrelated lines and reports a false violation. TOML basic strings fold
# line-ending backslashes during parse (which is how the formula engine renders
# them to the agent); markdown templates are folded here the same way.
bd_update_commands() {
    python3 - "$1" <<'PY'
import re
import sys
import tomllib

path = sys.argv[1]

if path.endswith(".toml"):
    with open(path, "rb") as handle:
        data = tomllib.load(handle)
    # tomllib has already folded the continuations; gather every place a step
    # description could live so a relocated block cannot escape the scan.
    text = "\n".join(
        [data.get("description", "")]
        + [s.get("description", "") for s in data.get("steps", [])]
    )
else:
    with open(path, encoding="utf-8") as handle:
        text = handle.read()

# Fold any surviving line-ending backslashes into one logical line.
text = re.sub(r"\\\n\s*", " ", text)

for match in re.findall(r"gc bd update[^\n`]*", text):
    sys.stdout.write(" ".join(match.split()) + "\n")
PY
}

# Every scanned file that can hand a bead back to a pool.
scanned_files() {
    printf '%s\n' \
        "$ROOT/gastown/formulas/mol-witness-patrol.toml" \
        "$ROOT/gastown/formulas/mol-refinery-patrol.toml" \
        "$ROOT/gastown/formulas/mol-polecat-work.toml" \
        "$ROOT/gastown/agents/refinery/prompt.template.md" \
        "$ROOT/gastown/agents/witness/prompt.template.md" \
        "$ROOT/gastown/agents/polecat/prompt.template.md"
}

# 1. No pool return anywhere may drop routing.
test_every_pool_return_sets_routing() {
    local found=0
    while IFS= read -r file; do
        [ -f "$file" ] || fail "scanned file missing: $file"
        while IFS= read -r cmd; do
            [ -n "$cmd" ] || continue
            case "$cmd" in
                *'--assignee=""'*) ;;
                *) continue ;;
            esac
            found=$((found + 1))
            # Must SET the field, not just name it -- see the note on
            # test_reopen_source_calls_are_routed.
            case "$cmd" in
                *'--set-metadata gc.routed_to='*) ;;
                *)
                    fail "pool return without gc.routed_to in $(basename "$file"): $cmd"
                    ;;
            esac
        done < <(bd_update_commands "$file")
    done < <(scanned_files)

    # A scan that silently matches nothing would pass forever.
    [ "$found" -ge 5 ] ||
        fail "expected to scan at least 5 pool returns, found $found -- extraction is broken"
}

# 2. The refinery's two reject sites return work to the POLECAT pool, in one
#    atomic update alongside the reopen.
test_refinery_rejects_route_to_polecat_pool() {
    local rejects=0
    while IFS= read -r cmd; do
        case "$cmd" in
            *'--status=open'*'--assignee=""'*rejection_reason*) ;;
            *) continue ;;
        esac
        rejects=$((rejects + 1))
        case "$cmd" in
            *'gc.routed_to="${GC_RIG:+$GC_RIG/}'*polecat*) ;;
            *) fail "refinery reject must route to the polecat pool: $cmd" ;;
        esac
    done < <(bd_update_commands "$REFINERY_FORMULA")

    [ "$rejects" -ge 2 ] ||
        fail "expected >=2 refinery reject sites (rebase conflict, test failure), found $rejects"

    # The prose the refinery agent actually reads must agree with the formula.
    bd_update_commands "$ROOT/gastown/agents/refinery/prompt.template.md" |
        grep -q 'assignee="".*--set-metadata gc\.routed_to=' ||
        fail "refinery prompt Rejection Flow must document gc.routed_to in the same update"
}

# 3. `gc workflow reopen-source` reopens a bead and clears its assignee but does
#    NOT route it, so every CALL of it must be accompanied by a routing update.
#    This is the second way into the bug and the way `ml-b2y.1` actually took:
#    no `--assignee=""` appears anywhere, so check 1 cannot see it.
#
#    Three shapes have to be judged differently, or the check is useless:
#
#      * A call in a fenced block whose routing lands in the NEXT numbered step
#        (mol-refinery-patrol: "2. reopen" then "3. put back with reason +
#        routing"). Correct -- so the unit of judgement must be the whole step
#        description, not the individual fence.
#      * A call in a markdown table row. A quick-reference row is a
#        self-contained copy-paste unit, so it must route on its own line.
#        Judging it by its enclosing section would let an unrelated
#        `gc.routed_to` elsewhere in the table vouch for it -- which is exactly
#        how the witness's "Recover orphaned bead" row shipped unrouted while
#        the section above it discussed routing at length.
#      * A bare prose mention with no operand ("`reopen-source` does not
#        route"). Not a call; must not be flagged.
#
#    The discriminator between a call and a reference is an operand: a call
#    names a bead (`<id>`, `$WORK`, `<bead>`), a reference does not.
#
#    A unit must SET routing, not merely mention it: the predicate is
#    `--set-metadata gc.routed_to=`, never the bare token. These steps explain
#    the invariant in prose right beside the command that upholds it, so a
#    substring test for `gc.routed_to` is satisfied by the explanation alone --
#    delete the command and the surrounding paragraph still vouches for it.
#    Verified by mutation: the loose form passed with the real setter removed.
test_reopen_source_calls_are_routed() {
    local found=0 n
    while IFS= read -r file; do
        [ -f "$file" ] || fail "scanned file missing: $file"
        n=$(python3 - "$file" <<'PY'
import re
import sys
import tomllib

path = sys.argv[1]

# Judgement units: (label, text). A unit passes if it sets gc.routed_to.
units = []
if path.endswith(".toml"):
    with open(path, "rb") as handle:
        data = tomllib.load(handle)
    for step in data.get("steps", []):
        units.append((f"step {step.get('id', '?')}", step.get("description", "")))
    units.append(("formula description", data.get("description", "")))
else:
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    # A table row stands alone; everything else is judged by its ## section.
    section, buf = "(preamble)", []
    for line in text.splitlines():
        if line.lstrip().startswith("|"):
            units.append((f"table row in {section}", line))
            continue
        if line.startswith("#"):
            units.append((section, "\n".join(buf)))
            section, buf = line.strip("# ").strip(), []
        buf.append(line)
    units.append((section, "\n".join(buf)))

# `reopen-source` followed by an operand -- i.e. an actual call, not a mention.
call = re.compile(r"reopen-source\s+(?:[`'\"]*[\$<][\w.\-]|[\w.\-]*\$?\{?[A-Za-z_])")
# Setting routing, not talking about it. See the note above.
sets_routing = re.compile(r"--set-metadata\s+gc\.routed_to=")

calls = 0
for label, text in units:
    folded = re.sub(r"\\\n\s*", " ", text)
    if not call.search(folded):
        continue
    calls += 1
    if not sets_routing.search(folded):
        sys.exit(
            f"FAIL: reopen-source call in {label} of {path} returns a bead to "
            f"the pool without setting gc.routed_to. `reopen-source` reopens "
            f"and unassigns but never routes, so the bead is unclaimable."
        )
print(calls)
PY
) || exit 1
        found=$((found + n))
    done < <(scanned_files)

    # reopen-source is called in mol-refinery-patrol (x2), mol-witness-patrol,
    # and the witness quick-reference. A drop here means extraction rotted.
    [ "$found" -ge 4 ] ||
        fail "expected to scan at least 4 reopen-source calls, found $found -- extraction is broken"
}

# 4. The sweep exists and is reachable in the patrol's step chain -- a step that
#    nothing depends on never runs.
test_witness_patrol_runs_the_sweep() {
    python3 - "$WITNESS_FORMULA" <<'PY' || exit 1
import sys
import tomllib

with open(sys.argv[1], "rb") as handle:
    data = tomllib.load(handle)

steps = {s["id"]: s for s in data["steps"]}
if "check-unroutable-beads" not in steps:
    sys.exit("FAIL: mol-witness-patrol has no check-unroutable-beads step")

# Walk back from the terminal step; the sweep must be transitively required.
terminal = data["steps"][-1]["id"]
seen, stack = set(), [terminal]
while stack:
    node = stack.pop()
    if node in seen:
        continue
    seen.add(node)
    stack.extend(steps.get(node, {}).get("needs", []))

if "check-unroutable-beads" not in seen:
    sys.exit(
        "FAIL: check-unroutable-beads is orphaned -- no step depends on it, "
        "so the patrol never reaches it"
    )
PY
}

# Emit the sweep's jq filter straight from the formula, so these behavioural
# assertions cannot pass against a filter the patrol no longer uses.
sweep_filter() {
    python3 - "$WITNESS_FORMULA" <<'PY'
import re
import sys
import tomllib

with open(sys.argv[1], "rb") as handle:
    data = tomllib.load(handle)

step = next(s for s in data["steps"] if s["id"] == "check-unroutable-beads")
blocks = [
    b
    for b in re.findall(r"```bash\n(.*?)```", step["description"], re.S)
    if "gc bd list" in b
]
if len(blocks) != 1:
    sys.exit(f"expected exactly 1 sweep query block, found {len(blocks)}")

body = blocks[0].split("jq -r '", 1)[1].rsplit("'", 1)[0]
sys.stdout.write(body)
PY
}

# Shared fixture: every shape the sweep must judge, correct answer in the id.
#
# The real auto_push=false halt sets halt_reason AND branch_ready together, so
# SPARED-deliberate-halt is the realistic case -- but with only that bead a test
# cannot tell the two exclusions apart, and dropping either one still passes.
# SPARED-halt-reason-only and SPARED-branch-ready isolate one field each, so
# each exclusion has to carry its own weight.
write_fixture() {
    cat >"$1" <<'JSON'
[
 {"id":"VIOLATION-refinery-reject","assignee":"","issue_type":"bug",
  "metadata":{"branch":"polecat/ml-5qc.7","gc.routed_to":"","rejection_reason":"semantic sibling collision"}},
 {"id":"VIOLATION-witness-salvage","assignee":"","issue_type":"task",
  "metadata":{"branch":"polecat/ml-b2y.1","recovered":"true"}},
 {"id":"SPARED-deliberate-halt","assignee":"","issue_type":"task",
  "metadata":{"branch":"polecat/x1","gc.routed_to":"","halt_reason":"auto_push_false","branch_ready":true}},
 {"id":"SPARED-halt-reason-only","assignee":"","issue_type":"task",
  "metadata":{"branch":"polecat/x7","gc.routed_to":"","halt_reason":"auto_push_false"}},
 {"id":"SPARED-branch-ready","assignee":"","issue_type":"task",
  "metadata":{"branch":"polecat/x2","gc.routed_to":"","branch_ready":true}},
 {"id":"SPARED-already-routed","assignee":"","issue_type":"task",
  "metadata":{"branch":"polecat/x3","gc.routed_to":"testrig/gastown.polecat"}},
 {"id":"SPARED-escalated-to-human","assignee":"","issue_type":"bug",
  "metadata":{"branch":"polecat/x4","gc.routed_to":"human"}},
 {"id":"SPARED-assigned","assignee":"testrig/gastown.refinery","issue_type":"task",
  "metadata":{"branch":"polecat/x5","gc.routed_to":""}},
 {"id":"SPARED-no-branch","assignee":"","issue_type":"task",
  "metadata":{"gc.routed_to":""}},
 {"id":"SPARED-epic","assignee":"","issue_type":"epic",
  "metadata":{"branch":"polecat/x6","gc.routed_to":""}}
]
JSON
}

# 5. Both real arrival paths are caught.
test_sweep_catches_both_arrival_paths() {
    local dir filter matched
    dir=$(mktemp -d)
    trap 'rm -rf "$dir"' RETURN
    sweep_filter >"$dir/filter.jq"
    write_fixture "$dir/beads.json"

    matched=$(jq -r -f "$dir/filter.jq" "$dir/beads.json" | jq -r '.[].id' | sort | tr '\n' ' ')
    case "$matched" in
        *VIOLATION-refinery-reject*) ;;
        *) fail "sweep missed the refinery-rejection shape (ml-5qc.7); matched: $matched" ;;
    esac
    case "$matched" in
        *VIOLATION-witness-salvage*) ;;
        *) fail "sweep missed the witness-salvage shape (ml-b2y.1); matched: $matched" ;;
    esac
}

# 6. Deliberate opt-outs and every healthy shape are spared. This is the half
#    that protects operators: auto_push=false parks work at branch-ready on
#    purpose, and re-routing it silently resumes work someone stopped.
test_sweep_spares_deliberate_halts_and_healthy_beads() {
    local dir matched
    dir=$(mktemp -d)
    trap 'rm -rf "$dir"' RETURN
    sweep_filter >"$dir/filter.jq"
    write_fixture "$dir/beads.json"

    matched=$(jq -r -f "$dir/filter.jq" "$dir/beads.json" | jq -r '.[].id')
    if printf '%s\n' "$matched" | grep -q 'SPARED'; then
        fail "sweep re-routed a bead it must leave alone: $(printf '%s' "$matched" | grep SPARED | tr '\n' ' ')"
    fi

    [ "$(printf '%s\n' "$matched" | grep -c .)" -eq 2 ] ||
        fail "sweep must match exactly the 2 violations, got: $(printf '%s' "$matched" | tr '\n' ' ')"
}

# 7. The deliberate halt still opts out. If someone "fixes" mol-polecat-work by
#    routing this path, auto_push=false stops meaning anything.
test_polecat_halt_still_clears_routing() {
    bd_update_commands "$POLECAT_FORMULA" |
        grep -q 'halt_reason=auto_push_false.*gc.routed_to=""' ||
        fail "mol-polecat-work auto_push=false halt must still set gc.routed_to=\"\" to opt out of the pool"
}

test_every_pool_return_sets_routing
test_refinery_rejects_route_to_polecat_pool
test_reopen_source_calls_are_routed
test_witness_patrol_runs_the_sweep
test_sweep_catches_both_arrival_paths
test_sweep_spares_deliberate_halts_and_healthy_beads
test_polecat_halt_still_clears_routing

echo "PASS: $(basename "${BASH_SOURCE[0]}")"
