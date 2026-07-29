#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT/gastown/assets/scripts/polecat-delivery-check.sh"

# gp-nrm: this check exists to stop a polecat building a deliverable that is
# already on the target branch. Its two failure directions are NOT symmetric:
#   * a missed detection costs one wasted pool slot (the status quo), while
#   * a FALSE already-delivered skips real work and silently drops a bead.
# So most of what follows pins the conservative direction — prose must not
# become evidence, a sibling bead id must not match, a local branch must not
# stand in for the remote.

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# The script reads the bead through `gc bd show <id> --json` and nothing else,
# so one stub covers every case; each test writes the payload it wants.
write_gc_stub() {
    local bin="$1"
    mkdir -p "$bin"
    cat >"$bin/gc" <<'SH'
#!/usr/bin/env sh
case "$*" in
    *"bd"*"show"*"--json"*)
        [ -n "${GC_STUB_FAIL:-}" ] && exit 1
        cat "$GC_BEAD_JSON"
        ;;
    *) printf '{}' ;;
esac
SH
    chmod +x "$bin/gc"
}

# bead_json <id> <description> [target-metadata]
bead_json() {
    local id="$1" desc="$2" target="${3:-}"
    if [ -n "$target" ]; then
        jq -n --arg id "$id" --arg d "$desc" --arg t "$target" \
            '[{id:$id,title:("work for " + $id),description:$d,metadata:{target:$t}}]'
    else
        jq -n --arg id "$id" --arg d "$desc" \
            '[{id:$id,title:("work for " + $id),description:$d,metadata:{}}]'
    fi
}

# run_check <bead-json> [args...] — runs in $REPO, captures stdout/stderr/RC.
# The bead id comes out of the payload rather than a second parameter, so a test
# cannot accidentally check one bead while stubbing another.
run_check() {
    local payload="$1" bid
    shift
    printf '%s' "$payload" >"$BEADJSON"
    bid=$(printf '%s' "$payload" | jq -r '.[0].id')
    set +e
    OUT=$(cd "$REPO" && env GC_BEAD_JSON="$BEADJSON" PATH="$BIN:$PATH" \
        bash "$SCRIPT" "$bid" ${1+"$@"} 2>"$ERRFILE")
    RC=$?
    set -e
    ERR=$(cat "$ERRFILE")
}

verdict_of() { printf '%s' "$OUT" | awk -F'\t' '$1=="verdict" {print $3}'; }

git_c() { git -C "$REPO" "$@"; }

# make_repo — a real repo with a real origin, so ref resolution, `git log
# --grep`, `git ls-tree` and `git grep` all exercise the same paths a live
# polecat worktree does. Fixtures are committed on `main` and pushed, so
# origin/main is a genuine remote-tracking ref rather than an alias.
make_repo() {
    REPO="$tmp/repo"
    ORIGIN="$tmp/origin.git"
    git init --quiet --bare "$ORIGIN"
    git init --quiet -b main "$REPO"
    git_c config user.email polecat@test.invalid
    git_c config user.name "Test Polecat"
    git_c config commit.gpgsign false
    git_c remote add origin "$ORIGIN"

    mkdir -p "$REPO/docs" "$REPO/pkg"
    echo "# base" >"$REPO/README.md"
    commit_all "chore: base scaffold"

    # A landed deliverable: file, symbol, and a commit that names its bead the
    # way this ecosystem's convention does — `<type>: <subject> (<bead-id>)`.
    echo "segments_dropped counter on /health" >"$REPO/pkg/recorder.py"
    commit_all "feat: report dropped segments on /health (ml-xob.3)"

    # The sibling-id trap: a commit for ml-dsq.11 exists, but NOT for ml-dsq.1.
    echo "backend setting permission" >"$REPO/docs/apple-silicon.md"
    commit_all "docs: describe the apple silicon backend (ml-dsq.11)"

    git_c push --quiet -u origin main
}

commit_all() {
    git_c add -A
    git_c commit --quiet -m "$1"
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
BIN="$tmp/bin"
BEADJSON="$tmp/bead.json"
ERRFILE="$tmp/stderr.txt"
write_gc_stub "$BIN"
make_repo

# --- S1: the bead-id commit signal -----------------------------------------

test_commit_naming_the_bead_is_already_delivered() {
    run_check "$(bead_json ml-xob.3 'Report dropped segments.')" --target origin/main
    [ "$RC" -eq 1 ] || fail "a commit naming the bead must be a finding (exit 1), got $RC ($OUT) [$ERR]"
    [ "$(verdict_of)" = "already-delivered" ] ||
        fail "expected already-delivered, got: $OUT"
    printf '%s' "$OUT" | grep -q '^evidence	commit	.*ml-xob\.3)' ||
        fail "the naming commit must be cited as evidence, got: $OUT"
}

test_sibling_bead_id_does_not_match() {
    # THE false-positive trap. `ml-dsq.1` is a prefix of `ml-dsq.11`, and
    # sub-bead ids of exactly that shape are routine. An unanchored --grep
    # would report ml-dsq.1 as already delivered by ml-dsq.11's commit and
    # silently drop real work.
    run_check "$(bead_json ml-dsq.1 'Document the backend.')" --target origin/main
    [ "$(verdict_of)" != "already-delivered" ] ||
        fail "ml-dsq.1 must NOT be matched by ml-dsq.11's commit, got: $OUT"
    printf '%s' "$OUT" | grep -q '^evidence	commit' &&
        fail "no commit names ml-dsq.1; none may be cited. got: $OUT"
    [ "$RC" -eq 0 ] || fail "an unmatched bead must exit 0 (go build), got $RC ($OUT)"
    return 0
}

test_exact_sibling_still_matches_itself() {
    # The anchor must not overshoot: ml-dsq.11 IS named by its own commit.
    run_check "$(bead_json ml-dsq.11 'Document the backend.')" --target origin/main
    [ "$(verdict_of)" = "already-delivered" ] ||
        fail "ml-dsq.11 is named by its own commit and must be detected, got: $OUT"
}

test_dot_in_bead_id_is_not_a_regex_wildcard() {
    # An unescaped `.` would let `ml-dsq.11` be matched by a commit for
    # `ml-dsqX11`. Bead ids are literals, not patterns.
    echo "unrelated" >"$REPO/pkg/decoy.txt"
    commit_all "chore: decoy naming ml-dsqX11"
    git_c push --quiet origin main
    run_check "$(bead_json ml-dsq.11x 'Nothing landed for this one.')" --target origin/main
    printf '%s' "$OUT" | grep -q 'ml-dsqX11' &&
        fail "a literal dot must not match an arbitrary character, got: $OUT"
    return 0
}

test_commit_only_on_a_side_branch_is_not_counted() {
    # "Already delivered" means delivered ON THE TARGET. A commit parked on
    # another branch has not landed and must not stop the polecat.
    git_c checkout --quiet -b side
    echo "wip" >"$REPO/pkg/side.txt"
    commit_all "feat: side work (gp-side1)"
    git_c checkout --quiet main

    run_check "$(bead_json gp-side1 'Side work.')" --target origin/main
    [ "$(verdict_of)" != "already-delivered" ] ||
        fail "a commit reachable only from a side branch must not count, got: $OUT"
    [ "$RC" -eq 0 ] || fail "unlanded side work must exit 0, got $RC ($OUT)"
    return 0
}

# --- verify-clause extraction ----------------------------------------------

test_capitalised_verify_label_is_extracted() {
    # The gawk IGNORECASE regression: real bead text writes `Verify:`, and an
    # IGNORECASE-based matcher silently reads it as "no verify clause" on
    # macOS, disabling two of the three signals with no error.
    run_check "$(bead_json gp-cap 'Add it.

Verify: pkg/recorder.py names segments_dropped')" --target origin/main
    printf '%s' "$ERR" | grep -q 'yielded 2 token(s)' ||
        fail "a capitalised 'Verify:' label must be extracted, got stderr: $ERR"
}

test_bracket_verify_clause_is_extracted() {
    run_check "$(bead_json gp-brk 'Do it. [verify: pkg/recorder.py contains segments_dropped] trailing prose')" \
        --target origin/main
    printf '%s' "$ERR" | grep -q 'yielded 2 token(s)' ||
        fail "a [verify: ...] clause must be extracted, got stderr: $ERR"
    printf '%s' "$OUT" | grep -q 'trailing' &&
        fail "text after the closing bracket must not be tokenised, got: $OUT"
    return 0
}

test_markdown_verify_section_is_extracted() {
    run_check "$(bead_json gp-sec 'Do it.

## Verify
pkg/recorder.py names segments_dropped

## Notes
unrelated_symbol_here')" --target origin/main
    printf '%s' "$ERR" | grep -q 'yielded 2 token(s)' ||
        fail "a '## Verify' section must be extracted, got stderr: $ERR"
    printf '%s' "$OUT" | grep -q 'unrelated_symbol_here' &&
        fail "the section must stop at the next heading, got: $OUT"
    return 0
}

# --- tokenisation: prose must never become evidence ------------------------

test_prose_only_clause_abstains() {
    # The real ml-dsq.11 clause shape. There is nothing code-shaped to grep,
    # so the only honest answer is "no signal" — never a confident verdict.
    run_check "$(bead_json gp-prose 'Do it.

Verify: the document names the backend, the setting, and the permission requirement')" \
        --target origin/main
    [ "$(verdict_of)" = "no-signal" ] ||
        fail "a prose-only verify clause must yield no-signal, got: $OUT"
    [ "$RC" -eq 0 ] || fail "no-signal means go build (exit 0), got $RC ($OUT)"
}

test_one_hump_brand_words_are_not_tokens() {
    # macOS, GitHub and JavaScript all pass a naive mixedCase filter and all
    # grep-hit somewhere in any large tree — which is how a prose clause turns
    # into a confident wrong "already delivered".
    echo "runs on macOS via GitHub with JavaScript" >"$REPO/docs/platforms.md"
    commit_all "docs: platform notes"
    git_c push --quiet origin main

    run_check "$(bead_json gp-brand 'Do it.

Verify: it passes on macOS and GitHub and JavaScript')" --target origin/main
    printf '%s' "$ERR" | grep -q 'yielded 0 token(s)' ||
        fail "single-hump brand words must not be tokens, got stderr: $ERR"
    [ "$(verdict_of)" = "no-signal" ] ||
        fail "a clause of brand words alone must abstain, got: $OUT"
}

test_allcaps_prose_emphasis_is_not_a_token() {
    # This ledger writes emphasis in caps (RECORDED, NEVER, STOP). Real
    # constants carry an underscore and are admitted as structural anyway.
    echo "the event is RECORDED here" >"$REPO/pkg/log.txt"
    commit_all "chore: recording note"
    git_c push --quiet origin main

    run_check "$(bead_json gp-caps 'Do it.

Verify: the error is RECORDED and NEVER dropped')" --target origin/main
    printf '%s' "$ERR" | grep -q 'yielded 0 token(s)' ||
        fail "bare ALLCAPS prose must not be tokens, got stderr: $ERR"
}

test_multi_hump_identifier_is_a_token() {
    # The other direction: a real multi-word identifier must still be caught.
    echo "class WheelUpPane: pass" >"$REPO/pkg/panes.py"
    commit_all "feat: panes"
    git_c push --quiet origin main

    run_check "$(bead_json gp-camel 'Do it.

Verify: WheelUpPane exists and pkg/panes.py defines it')" --target origin/main
    printf '%s' "$OUT" | grep -q '^evidence	symbol	WheelUpPane' ||
        fail "a two-hump CamelCase identifier must be tokenised and found, got: $OUT"
}

test_placeholder_prefix_is_stripped() {
    echo "hook log lives at .remember/logs/hook-errors.log" >"$REPO/pkg/scaffold.sh"
    commit_all "feat: scaffold"
    git_c push --quiet origin main

    run_check "$(bead_json gp-ph 'Do it.

Verify: <work_dir>/.remember/logs/hook-errors.log is created and pkg/scaffold.sh writes it')" \
        --target origin/main
    printf '%s' "$OUT" | grep -q '\.remember/logs/hook-errors\.log' ||
        fail "a <placeholder>/ prefix must be stripped so the path stays greppable, got: $OUT"
}

# --- verdict thresholds ----------------------------------------------------

test_all_tokens_present_is_possibly_delivered() {
    run_check "$(bead_json gp-all 'Do it.

Verify: pkg/recorder.py names segments_dropped')" --target origin/main
    [ "$(verdict_of)" = "possibly-delivered" ] ||
        fail "every token present should read possibly-delivered, got: $OUT"
    # ADVISORY, not a halt (gp-nrm, mayor decision). Measured on 28 real beads:
    # the commit signal caught 8/8 already-delivered with zero false positives,
    # while this token heuristic fired zero times. A signal that has never fired
    # must not stop a polecat — a miss costs one pool slot and the refinery
    # still catches it, but a false positive silently drops real work.
    [ "$RC" -eq 0 ] || fail "possibly-delivered is advisory and must NOT halt (exit 0), got $RC ($OUT)"
    printf '%s' "$ERR" | grep -q 'ADVISORY' ||
        fail "an advisory verdict must say so on stderr, got: $ERR"
}

test_only_the_commit_signal_can_halt() {
    # The load-bearing asymmetry, pinned directly: exactly one verdict exits 1.
    # If a future change promotes the token heuristic back to halting, this is
    # the test that must be argued with first.
    grep -q 'possibly-delivered)' "$SCRIPT" ||
        fail "the script must handle possibly-delivered as its own case"
    awk '/^case "\$VERDICT" in/,/^esac/' "$SCRIPT" | grep -c 'exit 1' | grep -qx 1 ||
        fail "exactly one verdict may exit 1 (already-delivered); found more"
    awk '/^case "\$VERDICT" in/,/^esac/' "$SCRIPT" |
        awk '/already-delivered\)/{f=1} f&&/exit 1/{print;exit}' | grep -q 'exit 1' ||
        fail "already-delivered must be the verdict that exits 1"
}

test_partial_token_hit_is_not_delivered() {
    # The ordinary shape of a bead whose neighbourhood exists but whose
    # deliverable does not. This is most beads, and it must read as "build".
    run_check "$(bead_json gp-part 'Do it.

Verify: pkg/recorder.py names segments_dropped and queue_depth_ceiling')" \
        --target origin/main
    [ "$(verdict_of)" = "not-delivered" ] ||
        fail "a partial hit must read not-delivered, got: $OUT"
    [ "$RC" -eq 0 ] || fail "not-delivered means go build (exit 0), got $RC ($OUT)"
    printf '%s' "$OUT" | grep -q '^missing	symbol	queue_depth_ceiling' ||
        fail "the absent token must be reported so the caller can see why, got: $OUT"
}

test_single_token_is_below_the_confidence_floor() {
    # One hit is too thin to abandon work over — a test file named by a verify
    # clause routinely predates the fix the bead asks for.
    run_check "$(bead_json gp-one 'Do it.

Verify: pkg/recorder.py passes')" --target origin/main
    [ "$(verdict_of)" = "not-delivered" ] ||
        fail "a lone token must not carry a delivered verdict, got: $OUT"
    [ "$RC" -eq 0 ] || fail "below the floor means go build, got $RC ($OUT)"
    printf '%s' "$OUT" | grep -q '^evidence	path	pkg/recorder.py' ||
        fail "the evidence should still be shown even when it does not decide, got: $OUT"
}

test_min_tokens_is_configurable() {
    # The floor moves the VERDICT, not the exit code: both sides of it are
    # advisory now, so asserting on RC here would pass no matter what the floor
    # did. Assert the thing the knob actually controls.
    run_check "$(bead_json gp-one2 'Do it.

Verify: pkg/recorder.py passes')" --target origin/main
    [ "$(verdict_of)" = "not-delivered" ] ||
        fail "default floor of 2 should not fire on one token, got: $OUT"
    set +e
    OUT=$(cd "$REPO" && env GC_BEAD_JSON="$BEADJSON" PATH="$BIN:$PATH" \
        GASTOWN_DELIVERY_MIN_TOKENS=1 bash "$SCRIPT" gp-one2 --target origin/main 2>"$ERRFILE")
    RC=$?
    set -e
    [ "$(verdict_of)" = "possibly-delivered" ] ||
        fail "MIN_TOKENS=1 should let a single token decide, got: $OUT"
    [ "$RC" -eq 0 ] || fail "possibly-delivered stays advisory at any floor, got $RC ($OUT)"
}

test_max_tokens_caps_the_work() {
    run_check "$(bead_json gp-cap2 'Do it.

Verify: a_one b_two c_three d_four e_five f_six')" --target origin/main
    local before
    before=$(printf '%s' "$ERR" | sed -n 's/.*yielded \([0-9]*\) token.*/\1/p')
    [ "$before" = "6" ] || fail "expected 6 tokens uncapped, got '$before' from: $ERR"
    set +e
    OUT=$(cd "$REPO" && env GC_BEAD_JSON="$BEADJSON" PATH="$BIN:$PATH" \
        GASTOWN_DELIVERY_MAX_TOKENS=3 bash "$SCRIPT" gp-cap2 --target origin/main 2>"$ERRFILE")
    RC=$?
    set -e
    grep -q 'yielded 3 token(s)' "$ERRFILE" ||
        fail "MAX_TOKENS=3 must cap the token list, got: $(cat "$ERRFILE")"
}

test_verdict_row_is_first() {
    # Callers read the verdict with `head -1` / `grep '^verdict'`; evidence rows
    # must never precede it.
    run_check "$(bead_json ml-xob.3 'Report dropped segments.')" --target origin/main
    printf '%s' "$OUT" | sed -n '1p' | grep -q '^verdict	' ||
        fail "the verdict row must be first on stdout, got: $OUT"
}

# --- target resolution -----------------------------------------------------

test_bare_branch_name_prefers_the_remote() {
    # A local `main` can trail origin/main by many commits, which would hide
    # exactly the commits this check exists to find. A bare name must resolve
    # to the remote-tracking ref.
    git_c branch --quiet -f stale-main HEAD~3 2>/dev/null || git_c branch -f stale-main HEAD~3
    run_check "$(bead_json ml-xob.3 'Report dropped segments.')" --target main
    printf '%s' "$OUT" | grep -q '^verdict	ml-xob\.3	already-delivered	origin/main$' ||
        fail "a bare 'main' should resolve to origin/main, got: $OUT"
}

test_metadata_target_is_used_when_no_flag() {
    run_check "$(bead_json ml-xob.3 'Report dropped segments.' origin/main)"
    printf '%s' "$OUT" | grep -q '	origin/main$' ||
        fail "metadata.target should supply the ref when --target is absent, got: $OUT"
}

test_unresolvable_target_is_not_measured() {
    run_check "$(bead_json ml-xob.3 'Report dropped segments.')" --target origin/nope
    [ "$RC" -eq 2 ] || fail "an unresolvable target must exit 2, got $RC ($OUT)"
    printf '%s' "$ERR" | grep -q 'NOT evaluated' ||
        fail "an unresolvable target must say delivery was NOT evaluated, got: $ERR"
    printf '%s' "$ERR" | grep -q 'fetch first' ||
        fail "the error should tell the caller to fetch, got: $ERR"
}

# --- failure modes: a broken check must never read as "go build" -----------
# Exit 2 is deliberately distinct from exit 0. Collapsing them would make an
# unreadable bead or a bad ref indistinguishable from a cleared one.

test_unreadable_bead_is_not_measured() {
    printf '%s' "$(bead_json ml-xob.3 'x')" >"$BEADJSON"
    set +e
    OUT=$(cd "$REPO" && env GC_BEAD_JSON="$BEADJSON" GC_STUB_FAIL=1 PATH="$BIN:$PATH" \
        bash "$SCRIPT" ml-xob.3 --target origin/main 2>"$ERRFILE")
    RC=$?
    set -e
    [ "$RC" -eq 2 ] || fail "a failing 'gc bd show' must exit 2, got $RC"
    grep -q 'NOT evaluated' "$ERRFILE" || fail "expected a NOT-evaluated message, got: $(cat "$ERRFILE")"
}

test_empty_bead_is_not_measured() {
    run_check '[{"id":"gp-empty","title":"","description":"","metadata":{}}]' --target origin/main
    [ "$RC" -eq 2 ] || fail "a bead with no text must exit 2, got $RC ($OUT)"
}

test_outside_a_git_repo_is_not_measured() {
    printf '%s' "$(bead_json ml-xob.3 'x')" >"$BEADJSON"
    set +e
    OUT=$(cd "$tmp" && env GC_BEAD_JSON="$BEADJSON" PATH="$BIN:$PATH" \
        bash "$SCRIPT" ml-xob.3 2>"$ERRFILE")
    RC=$?
    set -e
    [ "$RC" -eq 2 ] || fail "outside a git repo must exit 2, got $RC"
    grep -q 'not inside a git repository' "$ERRFILE" ||
        fail "expected the git-repo error, got: $(cat "$ERRFILE")"
}

test_missing_bead_argument_is_usage_error() {
    set +e
    OUT=$(cd "$REPO" && PATH="$BIN:$PATH" bash "$SCRIPT" 2>"$ERRFILE")
    RC=$?
    set -e
    [ "$RC" -eq 2 ] || fail "no bead id must exit 2, got $RC"
    grep -q 'usage' "$ERRFILE" || fail "expected a usage message, got: $(cat "$ERRFILE")"
}

test_unknown_flag_is_rejected() {
    set +e
    OUT=$(cd "$REPO" && PATH="$BIN:$PATH" bash "$SCRIPT" gp-x --bogus 2>"$ERRFILE")
    RC=$?
    set -e
    [ "$RC" -eq 2 ] || fail "an unknown flag must exit 2, got $RC"
}

test_bad_thresholds_fail_loudly() {
    printf '%s' "$(bead_json ml-xob.3 'x')" >"$BEADJSON"
    for env_pair in GASTOWN_DELIVERY_MIN_TOKENS=abc GASTOWN_DELIVERY_MAX_TOKENS=0; do
        set +e
        OUT=$(cd "$REPO" && env GC_BEAD_JSON="$BEADJSON" PATH="$BIN:$PATH" "$env_pair" \
            bash "$SCRIPT" ml-xob.3 --target origin/main 2>"$ERRFILE")
        RC=$?
        set -e
        [ "$RC" -eq 2 ] || fail "$env_pair must exit 2, got $RC ($(cat "$ERRFILE"))"
    done
}

# --- source-level invariants ------------------------------------------------

test_no_gawk_ignorecase() {
    # macOS awk parses IGNORECASE as an ordinary variable and ignores it, so a
    # case-insensitive match built on it fails SILENTLY on half the fleet.
    grep -n 'IGNORECASE' "$SCRIPT" | grep -vE '^[0-9]+:[[:space:]]*#' &&
        fail "IGNORECASE is gawk-only; use tolower() + match() instead"
    return 0
}

test_uses_no_bash4_only_constructs() {
    ! grep -nE 'declare -A|local -A|mapfile|readarray|&>>|\[\[ -v ' "$SCRIPT" >/dev/null ||
        fail "the check must stay bash 3.2 compatible (the fleet includes macOS)"
}

test_git_grep_uses_fixed_strings() {
    # Verify clauses carry regex metacharacters (`/health`, `*.md`, `[verify:`).
    # Interpreting them as patterns is both wrong and a hang risk.
    grep -q 'git grep -F' "$SCRIPT" ||
        fail "content search must use 'git grep -F' so tokens match literally"
}

test_script_is_executable() {
    [ -x "$SCRIPT" ] || fail "the check must be executable — the formula runs it via bash, but the witness pattern tests -x"
}

# --- the `gc gastown delivery-check` wrapper --------------------------------
#
# The wrapper exists only to resolve the path, and that is exactly the part this
# check got wrong first: the formula reached for GC_PACK_DIR directly, but
# GC_PACK_DIR is set by `gc` when `gc` invokes a pack command and is absent from
# a plain agent session. The expansion produced `/assets/scripts/...`, the `-x`
# guard failed, the step printed "not resolvable" and moved on — permanently.
#
# That is the worst possible failure for THIS check specifically. A gate meant to
# fire rarely, whose silent no-op is indistinguishable from "checked, found
# nothing", would have shipped as a placebo and gone on costing the pool slots it
# was written to save. gp-fid diagnosed the identical bug in usage-stamp; these
# tests pin the resolution contract so it cannot come back a third time.

WRAPPER="$ROOT/gastown/commands/delivery-check/run.sh"

run_wrapper() {
    local payload="$1" bid
    shift
    printf '%s' "$payload" >"$BEADJSON"
    bid=$(printf '%s' "$payload" | jq -r '.[0].id')
    set +e
    OUT=$(cd "$REPO" && env GC_BEAD_JSON="$BEADJSON" PATH="$BIN:$PATH" \
        GC_CITY_PATH="${WRAP_CITY-$tmp}" GC_PACK_DIR="${WRAP_PACK-$ROOT/gastown}" \
        sh "$WRAPPER" "$bid" ${1+"$@"} 2>"$ERRFILE")
    RC=$?
    set -e
    ERR=$(cat "$ERRFILE")
}

test_wrapper_is_executable() {
    [ -x "$WRAPPER" ] || fail "$WRAPPER must be executable"
}

test_wrapper_rejects_missing_pack_context() {
    # Invoked by path instead of through `gc`: GC_PACK_DIR is empty. This must
    # fail loudly rather than exec'ing `bash /assets/scripts/...`.
    WRAP_PACK="" run_wrapper "$(bead_json ml-xob.3 'Report dropped segments.')"
    [ "$RC" -eq 2 ] || fail "missing GC_PACK_DIR must exit 2, got $RC"
    grep -q "missing Gas City pack context" "$ERRFILE" ||
        fail "the wrapper must name the missing pack context: $ERR"
}

test_wrapper_rejects_missing_city_context() {
    WRAP_CITY="" run_wrapper "$(bead_json ml-xob.3 'Report dropped segments.')"
    [ "$RC" -eq 2 ] || fail "missing GC_CITY_PATH must exit 2, got $RC"
}

test_wrapper_reports_a_pack_without_the_script() {
    # An older pack version predating this check. Must exit 2 (not evaluated),
    # never 0 — "go build" and "could not ask" are different facts.
    WRAP_PACK="$tmp" run_wrapper "$(bead_json ml-xob.3 'Report dropped segments.')"
    [ "$RC" -eq 2 ] || fail "a pack missing the script must exit 2, got $RC"
    grep -q "not found in this pack version" "$ERRFILE" ||
        fail "the wrapper must say the script is missing: $ERR"
}

test_wrapper_passes_findings_exit_through() {
    # Exit 1 is the halt signal. If the wrapper swallowed it the gate would
    # never fire, which is the exact defect the wrapper exists to prevent.
    run_wrapper "$(bead_json ml-xob.3 'Report dropped segments.')" --target origin/main
    [ "$RC" -eq 1 ] || fail "wrapper must pass through exit 1 (findings), got $RC [$ERR]"
    [ "$(verdict_of)" = "already-delivered" ] ||
        fail "wrapper must relay the script's stdout verdict, got: $OUT"
}

test_wrapper_passes_build_exit_and_flags_through() {
    # --target must survive the exec, and exit 0 must pass through: a bead with
    # no commit and no tokens is the common case, and it means BUILD.
    run_wrapper "$(bead_json gp-fresh 'Something not yet done.')" --target origin/main
    [ "$RC" -eq 0 ] || fail "wrapper must pass through exit 0 (build), got $RC [$ERR]"
    printf '%s' "$OUT" | grep -q 'origin/main' ||
        fail "--target must survive the wrapper, got: $OUT"
}

# --- the caller actually invokes it the resolvable way ----------------------

test_formula_invokes_the_command_not_the_path() {
    local formula="$ROOT/gastown/formulas/mol-polecat-work.toml"
    grep -Fq 'gc gastown delivery-check "$WORK_BEAD_ID"' "$formula" ||
        fail "mol-polecat-work must run the gate via 'gc gastown delivery-check'"
    # The regression itself. gp-fid's guard matched `^STAMP=` — one hard-coded
    # variable name — and this check's first draft walked straight through it
    # with `CHECK=`. So match the SHAPE: any variable assigned a GC_PACK_DIR
    # expansion, whatever it is called. The prose under the snippet quotes the
    # broken path deliberately, to say why it is broken, so this must not simply
    # grep for the word.
    ! grep -qE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=["'"'"']?\$\{?GC_PACK_DIR' "$formula" ||
        fail "formula must not resolve a pack script into a path variable"
    ! grep -qE '^[[:space:]]*(bash|sh|exec).*GC_PACK_DIR' "$formula" ||
        fail "formula must not execute a script through ambient GC_PACK_DIR"
}

test_polecat_prompt_documents_the_command() {
    local prompt="$ROOT/gastown/agents/polecat/prompt.template.md"
    grep -Fq 'gc gastown delivery-check' "$prompt" ||
        fail "the polecat prompt must name the command it is told to run"
}

test_help_documents_the_exit_codes() {
    local help="$ROOT/gastown/commands/delivery-check/help.md"
    [ -r "$help" ] || fail "the pack command must ship a help.md"
    for code in 'not-delivered' 'no-signal' 'already-delivered' 'possibly-delivered'; do
        grep -Fq "$code" "$help" || fail "help.md must document the '$code' verdict"
    done
}

test_commit_naming_the_bead_is_already_delivered
test_sibling_bead_id_does_not_match
test_exact_sibling_still_matches_itself
test_dot_in_bead_id_is_not_a_regex_wildcard
test_commit_only_on_a_side_branch_is_not_counted
test_capitalised_verify_label_is_extracted
test_bracket_verify_clause_is_extracted
test_markdown_verify_section_is_extracted
test_prose_only_clause_abstains
test_one_hump_brand_words_are_not_tokens
test_allcaps_prose_emphasis_is_not_a_token
test_multi_hump_identifier_is_a_token
test_placeholder_prefix_is_stripped
test_all_tokens_present_is_possibly_delivered
test_only_the_commit_signal_can_halt
test_partial_token_hit_is_not_delivered
test_single_token_is_below_the_confidence_floor
test_min_tokens_is_configurable
test_max_tokens_caps_the_work
test_verdict_row_is_first
test_bare_branch_name_prefers_the_remote
test_metadata_target_is_used_when_no_flag
test_unresolvable_target_is_not_measured
test_unreadable_bead_is_not_measured
test_empty_bead_is_not_measured
test_outside_a_git_repo_is_not_measured
test_missing_bead_argument_is_usage_error
test_unknown_flag_is_rejected
test_bad_thresholds_fail_loudly
test_no_gawk_ignorecase
test_uses_no_bash4_only_constructs
test_git_grep_uses_fixed_strings
test_script_is_executable
test_wrapper_is_executable
test_wrapper_rejects_missing_pack_context
test_wrapper_rejects_missing_city_context
test_wrapper_reports_a_pack_without_the_script
test_wrapper_passes_findings_exit_through
test_wrapper_passes_build_exit_and_flags_through
test_formula_invokes_the_command_not_the_path
test_polecat_prompt_documents_the_command
test_help_documents_the_exit_codes

echo "polecat delivery check tests passed"
