#!/usr/bin/env bash
# Guards the polecat->refinery handoff address (gp-0fz).
#
#   an address written into `assignee` must be one an agent answers to
#
# Gas Town addresses agents as `<rig>/<binding-prefix><role>`, and formulas used
# to compose that by string concatenation:
#
#     "${GC_RIG:+$GC_RIG/}{{binding_prefix}}refinery"
#
# `{{binding_prefix}}` is substituted at pour time. When it rendered empty the
# result degraded to `<rig>/refinery` — not the refinery, which is
# `<rig>/gastown.refinery` because the import is bound as `[rigs.imports.gastown]`.
#
# Nothing at runtime rejects that write, and this is the crux: `gc bd update
# --assignee=` takes any string, so there is no referential integrity between a
# bead's assignee and the agent roster. Both discovery paths then miss it —
# assigned-work scans `--assignee=$GC_AGENT` (`<rig>/gastown.refinery`, no
# match) and the routed-orphan scan keys on `gc.routed_to`, which the handoff
# correctly clears. The bead reads healthy in every listing (open, branch
# pushed, target set) while generating zero demand and no wake signal. A
# misspelled address is precisely the case where no fallback fires. Observed
# across three sessions in two rigs; ml-z2z dwelled ~6h.
#
# Because the failure is invisible at runtime, it has to be caught at build
# time. What is nailed down here:
#
#   1. No address that flows into a WRITE (--assignee=, session wake/nudge) is
#      composed from {{binding_prefix}} in mol-polecat-work. Composition is
#      allowed in exactly one place: a `--candidate` argument handed to the
#      resolver, whose whole job is to detect that the composition went wrong.
#   2. The handoff is FAIL-CLOSED. A resolver refusal must halt, never fall
#      through to writing the composed value — falling through reintroduces the
#      bug with extra steps.
#   3. The resolver's contract holds on the shapes actually observed in the
#      field, including the two degenerate ones (empty prefix, unrendered
#      template) and the legitimate one this must NOT break (an unbound city,
#      where an empty prefix is correct).
#   4. stdout stays capture-safe: exactly one address, no commentary, so
#      `TARGET=$(...)` cannot swallow a diagnostic and write it as an assignee.
#   5. The resolver is reachable as a pack command, since a formula can only
#      call it as `gc gastown agent-address`.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
POLECAT_FORMULA="$ROOT/gastown/formulas/mol-polecat-work.toml"
RESOLVER="$ROOT/gastown/assets/scripts/agent-address.sh"
COMMAND_DIR="$ROOT/gastown/commands/agent-address"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq is required to stub the agent roster"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# --- part 1: build-time invariants over the formula ---------------------------

# Emit every logical shell command in FILE that WRITES an address somewhere.
#
# "Logical" matters: these are written across several physical lines with
# trailing backslashes, so a line-oriented grep sees the `--assignee=` and the
# value that feeds it as unrelated lines. TOML basic strings fold line-ending
# backslashes during parse (which is how the formula engine renders them to the
# agent), so fold them here the same way before matching.
address_write_commands() {
    python3 - "$1" <<'PY'
import re
import sys
import tomllib

with open(sys.argv[1], "rb") as handle:
    data = tomllib.load(handle)

# Gather every place a step description could live, so a relocated block cannot
# escape the scan.
text = "\n".join(
    [data.get("description", "")]
    + [s.get("description", "") for s in data.get("steps", [])]
)

# Fold surviving line-ending backslashes into one logical line.
text = re.sub(r"\\\n\s*", " ", text)

# Commands that put an address somewhere it has to be correct.
patterns = [
    r"gc bd update[^\n`]*--assignee=[^\n`]*",
    r"gc session (?:wake|nudge)[^\n`]*",
]
for pattern in patterns:
    for match in re.findall(pattern, text):
        sys.stdout.write(" ".join(match.split()) + "\n")
PY
}

# 1. No write may take a composed address.
#
# The one legitimate appearance of {{binding_prefix}} in an executable line is
# as a `--candidate` value: that is the caller handing the resolver the very
# string under suspicion so it can be checked and reported. Anywhere else, the
# composed value is reaching a write unvalidated.
test_no_write_takes_a_composed_address() {
    local scanned=0
    while IFS= read -r cmd; do
        [ -n "$cmd" ] || continue
        scanned=$((scanned + 1))
        case "$cmd" in
            *'{{binding_prefix}}'*) ;;
            *) continue ;;
        esac
        # Strip every --candidate argument; anything left holding the composed
        # form is a real violation.
        local stripped
        stripped=$(printf '%s' "$cmd" | sed -E 's/--candidate[= ]"[^"]*"//g')
        case "$stripped" in
            *'{{binding_prefix}}'*)
                fail "composed address reaches a write in mol-polecat-work: $cmd"
                ;;
        esac
    done < <(address_write_commands "$POLECAT_FORMULA")
    [ "$scanned" -gt 0 ] || fail "scan found no address writes at all — the extractor is broken, not the formula"
    echo "ok: $scanned address write(s) in mol-polecat-work, none composed from {{binding_prefix}}"
}

# 2. The refinery handoff resolves, and a refusal halts.
#
# Checked against the parsed step text rather than a copy, so moving the block
# cannot silently drop the guard.
test_handoff_is_fail_closed() {
    local step
    step=$(python3 - "$POLECAT_FORMULA" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as handle:
    data = tomllib.load(handle)
for s in data.get("steps", []):
    if s.get("id") == "submit-and-exit":
        sys.stdout.write(s.get("description", ""))
        break
PY
)
    [ -n "$step" ] || fail "mol-polecat-work has no submit-and-exit step"

    grep -q 'gc gastown agent-address refinery' <<<"$step" \
        || fail "submit-and-exit must resolve the refinery address via 'gc gastown agent-address refinery'"

    # The reassign must consume the resolved variable, never a composed string.
    grep -qE 'gc bd update "\$WORK_BEAD_ID".*--assignee="\$REFINERY_TARGET"' <<<"$step" \
        || fail "the reassign must write \$REFINERY_TARGET, the resolved value"

    # A refusal has to stop the handoff, and the halt has to be attached to THIS
    # failure. Grepping the whole step for `exit 1` is not enough — the step
    # contains other halts, so that check passes even when the resolver's own
    # failure branch quietly substitutes a fallback. Extract the failure handler
    # by brace-matching and assert on it directly.
    local handler
    handler=$(python3 - "$POLECAT_FORMULA" <<'PY'
import sys, tomllib

with open(sys.argv[1], "rb") as handle:
    data = tomllib.load(handle)
step = next(s.get("description", "") for s in data.get("steps", []) if s.get("id") == "submit-and-exit")

lines = step.splitlines()
start = next(
    (i for i, l in enumerate(lines)
     if "gc gastown agent-address refinery" in l and "--quiet" not in l),
    None,
)
if start is None:
    sys.exit(0)

# Walk forward to the `|| {` that opens the failure handler, then brace-match.
# Emit only the BODY — the opening line is the resolve itself, and it assigns
# REFINERY_TARGET by definition, so including it would defeat the fallback check
# below.
# depth is seeded from the opening line, which already contains the handler's
# `{`, so the matching `}` brings it back to 0 — not below. Break on <= 0 and do
# not append the closing line.
depth = 0
opened = False
out = []
for line in lines[start:]:
    if opened:
        depth += line.count("{") - line.count("}")
        if depth <= 0:
            break
        out.append(line)
        continue
    if "|| {" in line or "||{" in line:
        opened = True
        depth = line.count("{") - line.count("}")
sys.stdout.write("\n".join(out))
PY
)
    [ -n "$handler" ] \
        || fail "the refinery resolve has no '|| { ... }' failure handler — a refusal would fall straight through to the write"

    grep -q 'exit 1' <<<"$handler" \
        || fail "the resolver's failure handler must halt with 'exit 1', not continue: $handler"

    # The handler must not rescue the handoff by assigning a fallback address.
    # That is the original bug reintroduced one level down.
    grep -qE '^\s*REFINERY_TARGET=' <<<"$handler" \
        && fail "the failure handler assigns a fallback REFINERY_TARGET — a refusal must halt, not guess: $handler"

    echo "ok: refinery handoff resolves its address; refusal halts with no fallback"
}

# --- part 2: the resolver's contract -----------------------------------------

# A stub `gc` whose roster is whatever the test says it is. The resolver reads
# the roster through GC_BIN precisely so it can be pinned here.
make_stub_gc() {
    local path="$1"
    shift
    {
        echo '#!/usr/bin/env bash'
        echo 'if [ "$1" = "agent" ] && [ "$2" = "list" ]; then'
        printf '  cat <<'"'"'JSON'"'"'\n'
        printf '%s\n' "$(jq -nc --args '{agents: ($ARGS.positional | map({qualified_name: .}))}' "$@")"
        printf 'JSON\n'
        echo '  exit 0'
        echo 'fi'
        echo 'exit 1'
    } >"$path"
    chmod +x "$path"
}

# Roster of a normally-bound rig.
BOUND_GC="$TMP/gc-bound"
make_stub_gc "$BOUND_GC" \
    "myrig/gastown.refinery" "myrig/gastown.witness" "myrig/gastown.polecat"

# Roster of a city that binds nothing — an empty prefix is CORRECT here.
UNBOUND_GC="$TMP/gc-unbound"
make_stub_gc "$UNBOUND_GC" "myrig/refinery" "myrig/witness" "myrig/polecat"

resolve() {
    # resolve <stub-gc> <self-addr> [args...]
    local stub="$1" self="$2"
    shift 2
    # `env` options must precede the assignments; `-u` after them is parsed as
    # the command name.
    env -u GC_TEMPLATE GC_BIN="$stub" GC_RIG=myrig GC_AGENT="$self" \
        bash "$RESOLVER" "$@" 2>"$TMP/stderr"
}

# 3a. THE BUG: an empty binding prefix is repaired, and reported.
test_empty_prefix_is_repaired_and_reported() {
    local out
    out=$(resolve "$BOUND_GC" "myrig/gastown.furiosa" refinery --candidate "myrig/refinery") \
        || fail "resolver refused a repairable address"
    [ "$out" = "myrig/gastown.refinery" ] \
        || fail "expected myrig/gastown.refinery, got '$out'"
    grep -q "SUBSTITUTION FAILED" "$TMP/stderr" \
        || fail "a losing candidate must be reported — silent repair hides the upstream bug"
    echo "ok: '<rig>/refinery' repaired to '<rig>/gastown.refinery', and reported"
}

# 3b. An unrendered template is the same failure wearing a different hat.
test_unrendered_template_is_repaired() {
    local out
    out=$(resolve "$BOUND_GC" "myrig/gastown.furiosa" refinery \
        --candidate 'myrig/{{binding_prefix}}refinery') \
        || fail "resolver refused an unrendered template"
    [ "$out" = "myrig/gastown.refinery" ] \
        || fail "expected myrig/gastown.refinery, got '$out'"
    echo "ok: unrendered '{{binding_prefix}}' repaired"
}

# 3c. A correct candidate passes through untouched and unaccused.
test_correct_candidate_passes_clean() {
    local out
    out=$(resolve "$BOUND_GC" "myrig/gastown.furiosa" refinery \
        --candidate "myrig/gastown.refinery") \
        || fail "resolver refused the correct address"
    [ "$out" = "myrig/gastown.refinery" ] || fail "expected passthrough, got '$out'"
    grep -q "SUBSTITUTION FAILED" "$TMP/stderr" \
        && fail "a correct candidate must not be accused of failing"
    echo "ok: correct candidate passes through clean"
}

# 3d. An unbound city must NOT have a prefix invented for it. This is the
#     regression that a naive "always prepend gastown." fix would cause, and it
#     would strand work in exactly the same way, just for different cities.
test_unbound_city_keeps_empty_prefix() {
    local out
    out=$(resolve "$UNBOUND_GC" "myrig/chuck" refinery --candidate "myrig/refinery") \
        || fail "resolver refused a valid unbound-city address"
    [ "$out" = "myrig/refinery" ] \
        || fail "unbound city must resolve to 'myrig/refinery', got '$out'"
    echo "ok: unbound city keeps its empty prefix — no invented binding"
}

# 3e. No known agent for the role: REFUSE. Returning a guess here is the whole
#     bug, so the contract is that stdout stays empty and the exit is non-zero.
test_unknown_role_refuses() {
    local out status
    set +e
    out=$(resolve "$BOUND_GC" "myrig/gastown.furiosa" nonesuch --candidate "myrig/gastown.nonesuch")
    status=$?
    set -e
    [ "$status" -ne 0 ] || fail "resolver must refuse a role no agent fills (exit was 0)"
    [ -z "$out" ] || fail "a refusal must print nothing on stdout, got '$out'"
    grep -q "REFUSED" "$TMP/stderr" || fail "a refusal must say so on stderr"
    echo "ok: unknown role refused, stdout empty"
}

# 3f. An unreadable roster is not an empty one. A daemon blip must not condemn
#     a correct address — self-derivation still stands on its own.
test_unreadable_roster_degrades_not_refuses() {
    local out
    out=$(resolve "$TMP/gc-does-not-exist" "myrig/gastown.furiosa" refinery \
        --candidate "myrig/refinery") \
        || fail "an unreadable roster must degrade to unverified, not refuse"
    [ "$out" = "myrig/gastown.refinery" ] || fail "expected self-derived address, got '$out'"
    grep -q "unverified" "$TMP/stderr" \
        || fail "an unverified result must be labelled as such"
    echo "ok: unreadable roster degrades to unverified self-derivation"
}

# 3g. Nothing to stand on: no roster, no identity, junk candidate. Refuse.
test_no_signal_at_all_refuses() {
    local out status
    set +e
    out=$(env -u GC_AGENT -u GC_TEMPLATE GC_BIN="$TMP/gc-does-not-exist" GC_RIG=myrig \
        bash "$RESOLVER" refinery --candidate '{{binding_prefix}}refinery' 2>"$TMP/stderr")
    status=$?
    set -e
    [ "$status" -ne 0 ] || fail "with no roster, no identity and a junk candidate, resolver must refuse"
    [ -z "$out" ] || fail "a refusal must print nothing on stdout, got '$out'"
    echo "ok: no usable signal anywhere -> refuse"
}

# 4. stdout is capture-safe.
#
# Callers use TARGET=$(...). If a diagnostic ever leaked to stdout it would be
# written verbatim into `assignee` — the same silent strand, sourced from the
# fix instead of the bug.
test_stdout_is_capture_safe() {
    local out
    out=$(resolve "$BOUND_GC" "myrig/gastown.furiosa" refinery --candidate "myrig/refinery")
    [ "$(printf '%s' "$out" | wc -l | tr -d ' ')" = "0" ] \
        || fail "stdout must be a single line with no trailing newline content: '$out'"
    case "$out" in
        *[[:space:]]*) fail "stdout must contain no whitespace: '$out'" ;;
    esac
    echo "ok: stdout is a single bare address, safe to capture"
}

# 5. Reachable as a pack command. A formula cannot call assets/scripts directly
#    — GC_PACK_DIR is unset in an agent session — so the wrapper is load-bearing.
test_command_is_dispatchable() {
    [ -f "$COMMAND_DIR/run.sh" ] \
        || fail "missing $COMMAND_DIR/run.sh — a directory without run.sh is not dispatchable"
    [ -f "$COMMAND_DIR/help.md" ] || fail "missing $COMMAND_DIR/help.md"
    grep -q 'assets/scripts/agent-address.sh' "$COMMAND_DIR/run.sh" \
        || fail "the command wrapper must delegate to assets/scripts/agent-address.sh"
    grep -q 'GC_PACK_DIR' "$COMMAND_DIR/run.sh" \
        || fail "the wrapper must resolve the script through GC_PACK_DIR"
    echo "ok: 'gc gastown agent-address' is dispatchable and delegates correctly"
}

[ -f "$POLECAT_FORMULA" ] || fail "missing formula: $POLECAT_FORMULA"
[ -f "$RESOLVER" ] || fail "missing resolver: $RESOLVER"

test_no_write_takes_a_composed_address
test_handoff_is_fail_closed
test_empty_prefix_is_repaired_and_reported
test_unrendered_template_is_repaired
test_correct_candidate_passes_clean
test_unbound_city_keeps_empty_prefix
test_unknown_role_refuses
test_unreadable_roster_degrades_not_refuses
test_no_signal_at_all_refuses
test_stdout_is_capture_safe
test_command_is_dispatchable

echo "PASS: refinery handoff address invariants hold"
