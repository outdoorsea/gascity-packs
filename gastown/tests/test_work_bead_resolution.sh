#!/usr/bin/env bash
# Guards how a polecat resolves WHICH BEAD IT IS WORKING ON.
#
# The bug this locks down (gp-wqu, 5 occurrences, witness escalation
# 2026-07-30T21:24Z): pool-routed work can reach a polecat with no molecule
# poured, so `{{convoy_id}}` / `$GC_BEAD_ID` render EMPTY and there is no convoy
# to ask. Every derivation site was `gc convoy status <convoy> | .children[0].id`,
# so every one of them answered "" -- and "" did not stop the run. It flowed into
# `EXPECTED_BRANCH="polecat/$WORK_BEAD_ID"`, which became the literal `polecat/`,
# so the branch-shape gate three steps later reported a branch MISMATCH that had
# nothing to do with the branch, and its recovery text sent the polecat back to a
# step that failed identically. The polecat could not terminate.
#
# The weaker form is just as real and is what this file was written under: the
# molecule WAS attached and steps WERE present, but $GC_BEAD_ID was still empty
# on the pool claim.
#
# All shell under test is EXTRACTED FROM THE FORMULA/TEMPLATES THEMSELVES --
# never a copy -- so an assertion cannot keep passing while the source drifts
# away from it. Branch state is exercised against real git repositories.
#
# What is nailed down here:
#   1. All three topologies resolve: A (poured id is a convoy -> its single
#      child), B (poured id is the work bead itself), C (poured id empty ->
#      recovered from the hook claim, or from the `polecat/<bead-id>` branch).
#   2. Topology C reaches the branch-shape gate and PASSES it. This is the
#      actual defect: the gate must accept a correct branch, not report a
#      mismatch manufactured by an empty id.
#   3. `EXPECTED_BRANCH` is NEVER the bare `polecat/`. An unresolvable bead
#      halts loudly BEFORE the gate, with a message about resolution rather
#      than about branch shape -- the two failures need different fixes and a
#      polecat reading the wrong one loops forever.
#   4. The branch is CONFIRMED, not trusted. `gc bd show` fuzzy-matches ("wqu"
#      resolves to "gp-wqu"), so a branch named `polecat/wqu` must NOT adopt
#      "gp-wqu": acting on a fuzzy hit is how `bd` reassigns the wrong bead.
#   5. Classification is on `issue_type`, not on `gc convoy status` exit codes.
#      That command exits 1 both for "not a convoy" (an answer) and for an
#      unreachable Dolt (a fault); conflating them turns an outage into a
#      confident wrong id.
#   6. No derivation site regresses to convoy-only. A reintroduced
#      `WORK_BEAD_ID=$(... convoy status ...)` with no fallback fails here.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
FORMULA="$ROOT/gastown/formulas/mol-polecat-work.toml"
PROMPT="$ROOT/gastown/agents/polecat/prompt.template.md"
FRAGMENT="$ROOT/gastown/template-fragments/approval-fallacy.template.md"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq is required to exercise the derivation snippets"

for f in "$FORMULA" "$PROMPT" "$FRAGMENT"; do
    [ -f "$f" ] || fail "missing source under test: $f"
done

# Emit the fenced bash block of STEP containing ANCHOR, with {{vars}} rendered
# from the formula's own defaults. Dies unless exactly one block matches, so a
# reorganised step fails loudly instead of quietly exercising nothing.
extract_step_block() {
    python3 - "$1" "$2" "$3" <<'PY'
import re
import sys
import tomllib

formula, step_id, anchor = sys.argv[1], sys.argv[2], sys.argv[3]
with open(formula, "rb") as handle:
    data = tomllib.load(handle)

step = next((s for s in data["steps"] if s["id"] == step_id), None)
if step is None:
    sys.exit(f"no step {step_id!r} in {formula}")

blocks = [
    b for b in re.findall(r"```bash\n(.*?)```", step["description"], re.S)
    if anchor in b
]
if len(blocks) != 1:
    sys.exit(
        f"expected exactly 1 {step_id} bash block containing {anchor!r}, "
        f"found {len(blocks)}"
    )

rendered = blocks[0]
values = {name: spec.get("default", "") for name, spec in data.get("vars", {}).items()}
values.setdefault("base_branch", "main")
values.setdefault("target_branch", "main")
values.setdefault("rig_name", "testrig")
for name, value in values.items():
    rendered = rendered.replace("{{%s}}" % name, str(value))
sys.stdout.write(rendered)
PY
}

# Emit the fenced bash block of a MARKDOWN file containing ANCHOR. Same
# exactly-one discipline as above.
extract_md_block() {
    python3 - "$1" "$2" <<'PY'
import re
import sys

path, anchor = sys.argv[1], sys.argv[2]
body = open(path).read()
blocks = [
    b for b in re.findall(r"```bash\n(.*?)```", body, re.S)
    if anchor in b
]
if len(blocks) != 1:
    sys.exit(
        f"expected exactly 1 bash block containing {anchor!r} in {path}, "
        f"found {len(blocks)}"
    )
sys.stdout.write(blocks[0])
PY
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"
mkdir -p "$BIN"

# Fixture-driven `gc` stub. Each case writes only the fixtures it wants to
# exist; an absent fixture is a non-zero exit, which is what a real `gc` does
# for an unknown id and what an unreachable Dolt looks like from the snippet's
# side. Fuzzy matching is modelled honestly: a fixture named `wqu` whose record
# carries "id":"gp-wqu" is exactly what `gc bd show wqu` really returns.
#
# The call log records the space-joined argv tail, which is what the
# `convoy status` assertions below match on. Dispatch, though, joins the verb
# and its subcommand with a COLON: space-joined, the bd/show pair reads as a
# bare beads invocation to tests/test_no_bare_bd_commands.py -- which scans
# comments too -- even though this stub IS `gc` and "$1 $2" is its own argv
# tail rather than a command line. Keep the two joins distinct: respelling the
# log to match the dispatch is what would silently void those guards.
cat > "$BIN/gc" <<'STUB'
#!/usr/bin/env bash
FIX="${GC_STUB_FIX:?GC_STUB_FIX unset}"
printf '%s\n' "$*" >> "$FIX/calls.log"
case "${1-}:${2-}" in
    bd:show)
        f="$FIX/bd_show/${3-}"
        [ -f "$f" ] || exit 1
        cat "$f" ;;
    convoy:status)
        f="$FIX/convoy_status/${3-}"
        [ -f "$f" ] || exit 1
        cat "$f" ;;
    hook:--claim)
        f="$FIX/hook_claim"
        [ -f "$f" ] || exit 1
        cat "$f" ;;
    runtime:drain-ack)
        printf 'DRAIN_ACK\n' >> "$FIX/calls.log" ;;
    *) : ;;
esac
exit 0
STUB
chmod +x "$BIN/gc"

# ---------------------------------------------------------------------------
# Fixture + run helpers
# ---------------------------------------------------------------------------

new_fixture() {
    FIX=$(mktemp -d "$TMP/fix.XXXXXX")
    mkdir -p "$FIX/bd_show" "$FIX/convoy_status"
    : > "$FIX/calls.log"
}

bead() { # bead <query-id> <returned-id> <issue_type>
    printf '[{"id":"%s","issue_type":"%s","status":"in_progress"}]\n' "$2" "$3" \
        > "$FIX/bd_show/$1"
}

convoy_with_children() { # convoy_with_children <id> <child...>
    local id="$1"; shift
    local kids="" c
    for c in "$@"; do
        kids="${kids:+$kids,}{\"id\":\"$c\",\"status\":\"in_progress\"}"
    done
    printf '{"id":"%s","children":[%s]}\n' "$id" "$kids" > "$FIX/convoy_status/$id"
}

hook_claim() { # hook_claim <bead-id>
    printf '{"action":"work","reason":"existing_assignment","bead_id":"%s"}\n' "$1" \
        > "$FIX/hook_claim"
}

# A real git repo with a real origin, on branch $1.
new_repo() {
    local branch="$1"
    REPO=$(mktemp -d "$TMP/repo.XXXXXX")
    local bare="$TMP/origin.$(basename "$REPO").git"
    git init --quiet --bare "$bare"
    git init --quiet -b main "$REPO"
    git -C "$REPO" config user.email t@t
    git -C "$REPO" config user.name t
    git -C "$REPO" commit --quiet --allow-empty -m init
    git -C "$REPO" remote add origin "$bare"
    git -C "$REPO" push --quiet origin main
    if [ "$branch" != "main" ]; then
        git -C "$REPO" checkout --quiet -b "$branch"
    fi
}

# Substitute the poured id into an extracted block. Asserts the placeholder is
# really there first: if the formula stops using {{convoy_id}}, a silent no-op
# substitution would leave every topology test passing vacuously.
render_poured() { # render_poured <block-text> <poured-id>
    local block="$1" poured="$2"
    case "$block" in
        *'{{convoy_id}}'*) : ;;
        *) fail "block no longer contains {{convoy_id}}; the poured-id tests would be vacuous" ;;
    esac
    printf '%s' "${block//\{\{convoy_id\}\}/$poured}"
}

# Run a block in REPO with the stub on PATH. Echoes RESOLVED=<id> on success.
# GC_BIN is unset deliberately: sessions export it as an absolute path and any
# `${GC_BIN:-gc}` would escape the PATH stub straight onto the live roster.
run_block() { # run_block <block-text>  -> stdout, sets RC
    local script="$FIX/block.sh"
    { printf '%s\n' "$1"
      printf 'printf "RESOLVED=%%s\\n" "${WORK_BEAD_ID-}"\n'
      printf 'printf "EXPECTED=%%s\\n" "${EXPECTED_BRANCH-}"\n'
    } > "$script"
    set +e
    OUT=$(cd "$REPO" && env -u GC_BIN GC_STUB_FIX="$FIX" PATH="$BIN:$PATH" \
        bash "$script" 2>&1)
    RC=$?
    set -e
    printf '%s' "$OUT"
}

pass() { printf '  ok  %s\n' "$1"; }

# ---------------------------------------------------------------------------
SETUP_BLOCK=$(extract_step_block "$FORMULA" workspace-setup 'POURED_ID=')
SUBMIT_BLOCK=$(extract_step_block "$FORMULA" submit-and-exit 'EXPECTED_BRANCH="polecat/$WORK_BEAD_ID"')
COMMIT_BLOCK=$(extract_step_block "$FORMULA" self-review 'git commit -m')

echo "workspace-setup: all three topologies resolve"

# -- Topology A: poured id is a convoy -> its single tracked child.
new_fixture; new_repo main
bead cv-1 cv-1 convoy
convoy_with_children cv-1 gp-aaa
run_block "$(render_poured "$SETUP_BLOCK" cv-1)" >/dev/null
[ "$RC" -eq 0 ] || fail "topology A exited $RC: $OUT"
case "$OUT" in *"RESOLVED=gp-aaa"*) pass "A convoy -> single child" ;;
    *) fail "topology A resolved wrong: $OUT" ;; esac
# Pins the call log's format on the one topology that MUST reach convoy status.
# Topology B below proves a negative against this same log, so if the log writer
# ever stopped recording the space-joined argv tail, that guard would pass by
# matching nothing rather than by nothing having happened.
grep -q -e 'convoy status' "$FIX/calls.log" \
    || fail "call log never recorded 'convoy status'; topology B's guard is vacuous"

# -- Topology B: poured id is the work bead itself, not a convoy.
new_fixture; new_repo main
bead gp-bbb gp-bbb bug
run_block "$(render_poured "$SETUP_BLOCK" gp-bbb)" >/dev/null
[ "$RC" -eq 0 ] || fail "topology B exited $RC: $OUT"
case "$OUT" in *"RESOLVED=gp-bbb"*) pass "B non-convoy poured id -> itself" ;;
    *) fail "topology B resolved wrong: $OUT" ;; esac
# It must NOT have asked convoy status about a non-convoy.
grep -q -e 'convoy status' "$FIX/calls.log" \
    && fail "topology B called 'convoy status' on a non-convoy bead"
pass "B classifies on issue_type, never on convoy-status exit code"

# -- Topology C: poured id EMPTY. This is gp-wqu.
new_fixture; new_repo main
hook_claim gp-ccc
run_block "$(render_poured "$SETUP_BLOCK" '')" >/dev/null
[ "$RC" -eq 0 ] || fail "topology C exited $RC: $OUT"
case "$OUT" in *"RESOLVED=gp-ccc"*) pass "C empty poured id -> recovered from hook claim" ;;
    *) fail "topology C resolved wrong (this is the gp-wqu bug): $OUT" ;; esac

# -- Nothing resolves: must halt loudly, not carry "" forward.
new_fixture; new_repo main
run_block "$(render_poured "$SETUP_BLOCK" '')" >/dev/null
[ "$RC" -ne 0 ] || fail "unresolvable work bead exited 0; '' would flow into the branch gate"
grep -q -e 'DRAIN_ACK' "$FIX/calls.log" || fail "unresolvable path never drain-acked; the session would hang"
pass "unresolvable -> non-zero + drain-ack"

# -- A convoy with two children is ambiguous and must not pick one.
new_fixture; new_repo main
bead cv-2 cv-2 convoy
convoy_with_children cv-2 gp-d1 gp-d2
run_block "$(render_poured "$SETUP_BLOCK" cv-2)" >/dev/null
[ "$RC" -ne 0 ] || fail "ambiguous 2-child convoy resolved anyway: $OUT"
pass "ambiguous convoy refuses rather than guessing"

echo "submit-and-exit: the branch-shape gate"

# -- THE REGRESSION: topology C reaches the gate and PASSES on a correct branch.
new_fixture; new_repo polecat/gp-ccc
bead gp-ccc gp-ccc bug
run_block "$(render_poured "$SUBMIT_BLOCK" '')" >/dev/null
[ "$RC" -eq 0 ] || fail "no-molecule polecat failed its own correct branch (gp-wqu): $OUT"
case "$OUT" in *"EXPECTED=polecat/gp-ccc"*) : ;;
    *) fail "expected branch wrong: $OUT" ;; esac
case "$OUT" in *"BRANCH SHAPE GATE FAILED"*) fail "correct branch reported a mismatch: $OUT" ;; esac
pass "C resolves from the branch and clears the gate"

# -- EXPECTED_BRANCH is never the bare `polecat/`, and the halt names the real
#    problem. A polecat handed "branch shape" advice for a resolution failure
#    re-runs workspace-setup and fails identically, forever.
new_fixture; new_repo not-a-polecat-branch
run_block "$(render_poured "$SUBMIT_BLOCK" '')" >/dev/null
[ "$RC" -ne 0 ] || fail "unresolvable bead passed the gate: $OUT"
# Whole-line match: `EXPECTED=polecat/` is the poisoned value, and it is the LAST
# line printed, so any pattern needing a character after it can never fire ($( )
# strips the trailing newline). `-x` compares the line itself.
grep -q -x -e 'EXPECTED=polecat/' <<<"$OUT" \
    && fail "EXPECTED_BRANCH was poisoned to a bare polecat/: $OUT"
grep -q -e 'HALT: cannot resolve the work bead' <<<"$OUT" \
    || fail "halt did not name resolution as the cause: $OUT"
grep -q -e 'BRANCH SHAPE GATE FAILED' <<<"$OUT" \
    && fail "reported a branch mismatch for a resolution failure -- the gp-wqu loop"
pass "unresolvable halts on resolution, not on a manufactured branch mismatch"

# -- Fuzzy-match guard. `gc bd show wqu` really does return gp-wqu; adopting
#    that would hand the refinery a bead the branch does not name.
new_fixture; new_repo polecat/ccc
bead ccc gp-ccc bug          # fuzzy hit: queried "ccc", got "gp-ccc"
run_block "$(render_poured "$SUBMIT_BLOCK" '')" >/dev/null
[ "$RC" -ne 0 ] || fail "adopted a fuzzy bd match; 'bd' would reassign the wrong bead: $OUT"
case "$OUT" in *"RESOLVED=gp-ccc"*) fail "fuzzy match was adopted: $OUT" ;; esac
pass "fuzzy bd match refused; only an exact id echo is proof"

# -- A branch naming a bead that does not exist resolves nothing.
new_fixture; new_repo polecat/gp-nope
run_block "$(render_poured "$SUBMIT_BLOCK" '')" >/dev/null
[ "$RC" -ne 0 ] || fail "branch naming a nonexistent bead resolved anyway: $OUT"
pass "branch is a hypothesis, not an authority"

# -- Convoy still wins when there IS one, even on a polecat branch.
new_fixture; new_repo polecat/gp-aaa
bead cv-3 cv-3 convoy
convoy_with_children cv-3 gp-aaa
run_block "$(render_poured "$SUBMIT_BLOCK" cv-3)" >/dev/null
[ "$RC" -eq 0 ] || fail "topology A at submit exited $RC: $OUT"
case "$OUT" in *"RESOLVED=gp-aaa"*) pass "A still preferred at submit when a convoy exists" ;;
    *) fail "submit topology A resolved wrong: $OUT" ;; esac

echo "self-review: the residual-commit block"

new_fixture; new_repo polecat/gp-ccc
bead gp-ccc gp-ccc bug
printf 'x\n' > "$REPO/f.txt"
run_block "$COMMIT_BLOCK" >/dev/null
case "$OUT" in *"RESOLVED=gp-ccc"*) pass "commit block resolves from the branch with no convoy" ;;
    *) fail "commit block failed to resolve from branch: $OUT" ;; esac

new_fixture; new_repo main
printf 'x\n' > "$REPO/f.txt"
run_block "$COMMIT_BLOCK" >/dev/null
[ "$RC" -ne 0 ] || fail "commit block committed from a non-polecat branch: $OUT"
pass "commit block refuses off a polecat/<bead-id> branch"

echo "prompt + fragment: the agent-facing copies stay in step"

# The done-sequence check and the resume check are the two places an agent acts
# on WITHOUT a formula step to guide it. Both must survive an empty $GC_BEAD_ID
# -- which is the state this very bead was worked under.
for pair in "$FRAGMENT|ALREADY_SUBMITTED" "$PROMPT|OWNERSHIP_LOST" "$PROMPT|RESUME_INDETERMINATE"; do
    path="${pair%%|*}"; anchor="${pair##*|}"
    block=$(extract_md_block "$path" "$anchor") \
        || fail "could not extract the $anchor block from $path"
    # Unlike the formula blocks above, these are only string-matched, never run,
    # so a syntax error in an edit would ship silently -- and an agent pastes
    # them verbatim into a shell. Parse without executing.
    printf '%s\n' "$block" > "$TMP/md_block.sh"
    bash -n "$TMP/md_block.sh" 2>/dev/null \
        || fail "$anchor block in $path is not valid bash; an agent pastes it verbatim"
    case "$block" in
        *'polecat/'*) : ;;
        *) fail "$anchor block in $path has no branch fallback; an empty \$GC_BEAD_ID strands it (gp-wqu)" ;;
    esac
    case "$block" in
        *'.[0].id // empty'*) : ;;
        *) fail "$anchor block in $path adopts the branch without confirming it against an exact id" ;;
    esac
    pass "$(basename "$path"): $anchor survives an empty \$GC_BEAD_ID"
done

# With no molecule there is no step bead to read, so the PROMPT is the only
# thing telling the polecat where its steps live. It must name a formula that
# actually exists: a renamed formula file would leave this text pointing at a
# `gc formula show` that prints nothing -- the same dead end by a quieter route.
NO_MOLECULE_FORMULA=$(python3 - "$PROMPT" <<'PY'
import re
import sys

body = open(sys.argv[1]).read()
m = re.search(r"gc formula show (\S+)", body)
sys.stdout.write(m.group(1) if m else "")
PY
)
[ -n "$NO_MOLECULE_FORMULA" ] \
    || fail "prompt no longer tells a molecule-less polecat where to read its steps (gp-wqu)"
[ -f "$ROOT/gastown/formulas/$NO_MOLECULE_FORMULA.toml" ] \
    || fail "prompt points at formula '$NO_MOLECULE_FORMULA', which has no file under gastown/formulas/"
pass "prompt.template.md: no-molecule path names a formula that exists ($NO_MOLECULE_FORMULA)"

echo "regression: no derivation site is convoy-only again"

# A reintroduced convoy-only derivation is the exact shape of the original bug.
# Every site that assigns WORK_BEAD_ID from a convoy must be followed, in the
# same block, by a fallback that does not depend on a convoy existing.
python3 - "$FORMULA" "$PROMPT" "$FRAGMENT" <<'PY' || fail "a convoy-only derivation site was reintroduced"
import re
import sys
import tomllib

def blocks(path):
    if path.endswith(".toml"):
        with open(path, "rb") as h:
            data = tomllib.load(h)
        for s in data["steps"]:
            for b in re.findall(r"```bash\n(.*?)```", s["description"], re.S):
                yield f"{path}:{s['id']}", b
    else:
        body = open(path).read()
        for i, b in enumerate(re.findall(r"```bash\n(.*?)```", body, re.S)):
            yield f"{path}:block{i}", b

bad = []
for path in sys.argv[1:]:
    for where, b in blocks(path):
        if "WORK_BEAD_ID=" not in b:
            continue
        if "convoy status" not in b:
            continue
        # A convoy-derived block is only safe if it also has a non-convoy route.
        has_fallback = ("polecat/" in b) or ("hook --claim" in b)
        if not has_fallback:
            bad.append(where)

for w in bad:
    print(f"convoy-only WORK_BEAD_ID derivation with no fallback: {w}", file=sys.stderr)
sys.exit(1 if bad else 0)
PY
pass "every convoy derivation carries a non-convoy fallback"

echo "PASS: work-bead resolution survives a missing molecule (gp-wqu)"
