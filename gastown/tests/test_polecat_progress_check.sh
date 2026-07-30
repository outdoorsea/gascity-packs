#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT/gastown/assets/scripts/polecat-progress-check.sh"

# gp-9ly: the bug this suite exists for is a LOCAL mtime formatted with a `Z`
# suffix and compared against a UTC now. On a UTC host that error is invisible —
# a UTC-only test passes vacuously. So the timezone-sensitive cases below force
# a non-UTC $TZ explicitly rather than trusting the host's, which keeps them
# meaningful on the UTC CI runner where they would otherwise prove nothing.
OFFSET_TZ="America/Los_Angeles"   # whole-hour offset, DST-observing (the reported host)
HALF_TZ="Asia/Kolkata"            # +05:30 — catches half-hour-offset arithmetic too

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

write_gc_stub() {
    local bin="$1"
    mkdir -p "$bin"
    cat >"$bin/gc" <<'SH'
#!/usr/bin/env sh
# Only `gc bd list --status=in_progress --json` is exercised here.
case "$*" in
    *"bd"*"list"*"--json"*) cat "$GC_BEADS_JSON" ;;
    *) printf '{}' ;;
esac
SH
    chmod +x "$bin/gc"
}

# run_check <beads-json-literal> [env assignments...] — prints the TSV rows,
# sets RC to the exit code. stderr is captured separately so row assertions stay
# clean.
run_check() {
    local payload="$1"
    shift
    printf '%s' "$payload" >"$BEADS"
    set +e
    # ${1+"$@"} rather than "$@": bash 3.2 under `set -u` treats an empty "$@"
    # as an unbound variable.
    OUT=$(env GC_CITY="$CITY" GC_BEADS_JSON="$BEADS" PATH="$BIN:$PATH" ${1+"$@"} \
        bash "$SCRIPT" 2>"$ERRFILE")
    RC=$?
    set -e
    ERR=$(cat "$ERRFILE")
}

# run_wrapper <beads-json-literal> [env assignments...] — invoke the command
# wrapper the way `gc` does, and capture stdout/stderr/exit like run_check.
#
# GC_CITY is explicitly UNSET here, because that is the state `gc` hands a pack
# command: it exports GC_CITY_PATH, not GC_CITY. Without `-u` this would pass on
# a developer machine inside a city (where GC_CITY is exported into every shell)
# while failing in CI — and it would stop testing the wrapper's city resolution
# at all.
#
# WRAP_PACK/WRAP_CITY override the two variables gc supplies, so the
# missing-context paths can be exercised without unsetting them for real.
#
# It runs from $NOCITY — a directory with no city.toml anywhere above it —
# because the check's fallback is to walk up from cwd. A polecat worktree lives
# at <city>/.gc/worktrees/..., so running these from the repo would let that
# walk-up find the developer's REAL city and pass whether or not the wrapper
# resolves anything. $NOCITY makes the wrapper's resolution the single reason
# these can succeed, locally and on CI alike.
run_wrapper() {
    local payload="$1"
    shift
    printf '%s' "$payload" >"$BEADS"
    set +e
    # ${1+"$@"} rather than "$@": bash 3.2 under `set -u` treats an empty "$@"
    # as an unbound variable.
    OUT=$(cd "$NOCITY" && env -u GC_CITY \
        GC_CITY_PATH="${WRAP_CITY-$CITY}" GC_PACK_DIR="${WRAP_PACK-$ROOT/gastown}" \
        GC_BEADS_JSON="$BEADS" PATH="$BIN:$PATH" ${1+"$@"} \
        sh "$WRAPPER" 2>"$ERRFILE")
    RC=$?
    set -e
    ERR=$(cat "$ERRFILE")
}

# set_mtime <file> <epoch> — portable absolute-time stamp.
# GNU touch takes `-d @EPOCH`. BSD touch only takes `-t`, which it reads in
# LOCAL time, so the epoch is formatted with a local `date -r`. That local
# formatting is correct HERE precisely because `-t`'s input is local — the two
# cancel and the file lands on the intended absolute instant. It is the same
# pairing the script under test must never make with a UTC `Z` suffix.
set_mtime() {
    local f="$1" epoch="$2"
    touch -d "@$epoch" "$f" 2>/dev/null && return 0
    touch -t "$(date -r "$epoch" +%Y%m%d%H%M.%S)" "$f"
}

now_epoch() { date -u +%s; }

# age_tree <worktree> <epoch> — stamp every file outside .git to one absolute
# instant, so the worktree reads as that age as a whole. Aging a single file is
# not enough: the repo scaffolding make_worktree just wrote would still be the
# newest thing in the tree, and the check measures the NEWEST file by design.
age_tree() {
    local wt="$1" epoch="$2" f
    find "$wt" -name .git -prune -o -type f -print | while IFS= read -r f; do
        set_mtime "$f" "$epoch"
    done
}

# ts_ago <seconds> — RFC3339 UTC, for bead `updated_at` fixtures.
ts_ago() {
    local epoch=$(( $(now_epoch) - $1 ))
    date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ
}

# make_worktree <name> — a real git repo with an origin, so the `commits` and
# `dirty` columns exercise the same code paths a live polecat worktree does.
make_worktree() {
    local name="$1" wt="$tmp/$1" origin="$tmp/$1.git"
    git init --quiet --bare "$origin"
    git init --quiet "$wt"
    git -C "$wt" config user.email polecat@test.invalid
    git -C "$wt" config user.name "Test Polecat"
    git -C "$wt" config commit.gpgsign false
    echo base >"$wt/README.md"
    git -C "$wt" add -A
    git -C "$wt" commit --quiet -m base
    git -C "$wt" remote add origin "$origin"
    git -C "$wt" push --quiet -u origin HEAD:refs/heads/main >/dev/null 2>&1
    git -C "$wt" branch --quiet --set-upstream-to=origin/main >/dev/null 2>&1 || true
    printf '%s' "$wt"
}

# bead_json <bead> <assignee> <updated_at> <work_dir>
bead_json() {
    printf '[{"id":"%s","assignee":"%s","status":"in_progress","updated_at":"%s","metadata":{"work_dir":"%s"}}]' \
        "$1" "$2" "$3" "$4"
}

# bead_json_scoped <bead> <assignee> <updated_at> <work_dir> <gc_work_dir> —
# gp-6k8: a bead carrying either or both directory scopes. Pass `-` for a scope
# to OMIT that key entirely, which is how a real bead looks before branch-setup
# has run (no `work_dir`, only the `gc.work_dir` agent home). Omitting rather
# than emptying matters: an absent key and a present-but-empty one take
# different paths through the check's jq.
bead_json_scoped() {
    local wd="$4" gwd="$5" fields=''
    [ "$wd" = '-' ] || fields="\"work_dir\":\"$wd\""
    if [ "$gwd" != '-' ]; then
        [ -z "$fields" ] || fields="$fields,"
        fields="$fields\"gc.work_dir\":\"$gwd\""
    fi
    printf '[{"id":"%s","assignee":"%s","status":"in_progress","updated_at":"%s","metadata":{%s}}]' \
        "$1" "$2" "$3" "$fields"
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
CITY="$tmp/city"
BIN="$tmp/bin"
BEADS="$tmp/beads.json"
ERRFILE="$tmp/stderr.txt"
NOCITY="$tmp/nocity"
WRAPPER="$ROOT/gastown/commands/progress-check/run.sh"
mkdir -p "$CITY" "$NOCITY"
: >"$CITY/city.toml"
write_gc_stub "$BIN"

POLECAT="gastown__polecat-gk-z5s"
ANCIENT=$(ts_ago 86400)   # a day-old bead stamp: forces the worktree to be the signal

# --- the gp-9ly regression -------------------------------------------------

test_recent_mtime_is_fresh_under_non_utc_tz() {
    # THE regression. A file touched seconds ago, measured on a PDT host.
    # The original check formatted that local mtime with a `Z` suffix and
    # compared it to a UTC now — a 7-hour error that read ~4 minutes of healthy
    # work as ~7h stale and put a warrant on a working polecat.
    local wt
    wt=$(make_worktree wt_fresh_tz)
    echo 'package main' >"$wt/site_invites.go"

    run_check "$(bead_json gp-9ly "$POLECAT" "$ANCIENT" "$wt")" TZ="$OFFSET_TZ"
    [ "$RC" -eq 0 ] || fail "a just-touched worktree on a $OFFSET_TZ host must exit 0, got $RC ($OUT) [$ERR]"
    printf '%s' "$OUT" | grep -q "^fresh	gp-9ly	$POLECAT	" ||
        fail "a file touched seconds ago must read fresh on a non-UTC host, got: $OUT"
    printf '%s' "$OUT" | grep -q 'stale' &&
        fail "gp-9ly regression: a fresh local mtime was reported stale on a $OFFSET_TZ host"
    return 0
}

test_four_minute_old_worktree_is_fresh_under_non_utc_tz() {
    # The exact observed shape: mtime ~4 minutes back — one build/vet/test
    # cycle. Under the local-mtime-with-Z bug this landed ~7h in the past and
    # tripped every plausible window.
    local wt
    wt=$(make_worktree wt_four_min)
    echo 'package main' >"$wt/site_invites.go"
    age_tree "$wt" "$(( $(now_epoch) - 240 ))"

    run_check "$(bead_json gp-9ly "$POLECAT" "$ANCIENT" "$wt")" TZ="$OFFSET_TZ"
    [ "$RC" -eq 0 ] || fail "a 4-minute-old worktree is a healthy test cadence, got $RC ($OUT) [$ERR]"
    printf '%s' "$OUT" | grep -qE "^fresh	gp-9ly	$POLECAT	2[0-9][0-9]	" ||
        fail "a 4-minute-old mtime should report an age near 240s, got: $OUT"
}

test_verdict_is_identical_across_timezones() {
    # Same fixture, three offsets including a half-hour one. Verdict, heartbeat
    # and source must be byte-identical: $TZ may not influence the arithmetic.
    local wt sig_utc sig_offset sig_half
    wt=$(make_worktree wt_tz_matrix)
    echo work >"$wt/file.txt"
    age_tree "$wt" "$(( $(now_epoch) - 300 ))"
    local payload
    payload=$(bead_json gp-tz "$POLECAT" "$ANCIENT" "$wt")

    # Columns 1,2,5,6 = verdict, bead, heartbeat, source. age_seconds is
    # excluded only because it advances with the wall clock between runs.
    run_check "$payload" TZ=UTC
    sig_utc=$(printf '%s' "$OUT" | awk -F'\t' '{print $1, $2, $5, $6}')
    run_check "$payload" TZ="$OFFSET_TZ"
    sig_offset=$(printf '%s' "$OUT" | awk -F'\t' '{print $1, $2, $5, $6}')
    run_check "$payload" TZ="$HALF_TZ"
    sig_half=$(printf '%s' "$OUT" | awk -F'\t' '{print $1, $2, $5, $6}')

    [ "$sig_utc" = "$sig_offset" ] ||
        fail "TZ changed the verdict: UTC gave [$sig_utc], $OFFSET_TZ gave [$sig_offset]"
    [ "$sig_utc" = "$sig_half" ] ||
        fail "a half-hour offset changed the verdict: UTC gave [$sig_utc], $HALF_TZ gave [$sig_half]"
    [ -n "$sig_utc" ] || fail "the timezone matrix compared two empty outputs — it proved nothing"
}

test_heartbeat_column_is_utc_not_local() {
    # The displayed heartbeat must be the true UTC instant. Under the bug the
    # `Z`-suffixed string was the host's local wall time, off by the UTC offset.
    local wt stamp expected
    wt=$(make_worktree wt_heartbeat)
    echo work >"$wt/file.txt"
    stamp=$(( $(now_epoch) - 600 ))
    age_tree "$wt" "$stamp"
    expected=$(date -u -d "@$stamp" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || date -u -r "$stamp" +%Y-%m-%dT%H:%M:%SZ)

    run_check "$(bead_json gp-hb "$POLECAT" "$ANCIENT" "$wt")" TZ="$OFFSET_TZ"
    printf '%s' "$OUT" | grep -q "	$expected	worktree	" ||
        fail "the heartbeat should render as the UTC instant $expected, got: $OUT"
}

# --- staleness semantics ---------------------------------------------------

test_genuinely_stale_worktree_is_flagged() {
    # The check must still do its job: real silence is still reported.
    local wt
    wt=$(make_worktree wt_stale)
    echo work >"$wt/file.txt"
    age_tree "$wt" "$(( $(now_epoch) - 14400 ))"   # 4h

    run_check "$(bead_json gp-old "$POLECAT" "$ANCIENT" "$wt")" TZ="$OFFSET_TZ"
    [ "$RC" -eq 1 ] || fail "a 4h-silent polecat must exit 1, got $RC ($OUT) [$ERR]"
    printf '%s' "$OUT" | grep -q "^stale	gp-old	$POLECAT	1[0-9][0-9][0-9][0-9]	" ||
        fail "a 4h-silent worktree should report stale with its age, got: $OUT"
}

test_worktree_activity_overrides_stale_bead_stamp() {
    # A polecat editing files for an hour without touching bd is working.
    # Bead time alone would call it stale; the newer signal must win.
    local wt
    wt=$(make_worktree wt_override)
    echo work >"$wt/file.txt"

    run_check "$(bead_json gp-ovr "$POLECAT" "$ANCIENT" "$wt")" TZ="$OFFSET_TZ"
    [ "$RC" -eq 0 ] || fail "live worktree edits should outweigh a day-old bead stamp, got $RC ($OUT)"
    printf '%s' "$OUT" | grep -q '	worktree	' ||
        fail "the worktree should be named as the winning signal, got: $OUT"
}

test_bead_stamp_carries_when_worktree_is_gone() {
    # No worktree is not "no information" — the bead stamp still measures.
    run_check "$(bead_json gp-nowt "$POLECAT" "$(ts_ago 60)" "$tmp/does-not-exist")" TZ="$OFFSET_TZ"
    [ "$RC" -eq 0 ] || fail "a fresh bead stamp with no worktree is still fresh, got $RC ($OUT)"
    printf '%s' "$OUT" | grep -q '^fresh	gp-nowt	.*	bead	-	-$' ||
        fail "a missing worktree should fall back to the bead stamp with '-' git columns, got: $OUT"
}

test_uncommitted_diff_with_zero_commits_is_not_stale() {
    # A long-lived polecat legitimately shows a large uncommitted diff and zero
    # commits — it has not reached its commit step. That is normal mid-flight
    # state, and the check must report it as fresh, with the counts visible so
    # the caller cannot mistake the diff for evidence of a stall.
    local wt i
    wt=$(make_worktree wt_midflight)
    for i in 1 2 3 4 5 6 7; do
        echo "change $i" >"$wt/file_$i.go"
    done

    run_check "$(bead_json gp-mid "$POLECAT" "$ANCIENT" "$wt")" TZ="$OFFSET_TZ"
    [ "$RC" -eq 0 ] || fail "mid-flight uncommitted work is not a stall, got $RC ($OUT) [$ERR]"
    printf '%s' "$OUT" | grep -q '^fresh	gp-mid	' ||
        fail "a big uncommitted diff with no commits must read fresh, got: $OUT"
    printf '%s' "$OUT" | grep -q '	0	7$' ||
        fail "commits=0 and dirty=7 should both be reported, got: $OUT"
}

# --- the gp-6k8 regression: two directory scopes, one of them ignored --------

test_agent_home_is_measured_when_per_bead_worktree_is_absent() {
    # THE gp-6k8 regression. A polecat parked BEFORE its branch-setup step has
    # no `metadata.work_dir` at all — only `gc.work_dir`, the agent home. The
    # check read the unprefixed key alone, measured nothing, and printed
    # `commits=-  dirty=-`. The witness patrol reads that as "nothing is at risk
    # on disk" and treats it as authorization to reset the session. The home was
    # holding three uncommitted files the entire time.
    local home
    home=$(make_worktree home_only)
    echo 'unpushed work' >"$home/a.go"
    echo 'more'          >"$home/b.go"
    echo 'and more'      >"$home/c.go"

    run_check "$(bead_json_scoped gp-home "$POLECAT" "$ANCIENT" - "$home")" TZ="$OFFSET_TZ"
    printf '%s' "$OUT" | grep -q '	home	0	3$' ||
        fail "a bead carrying only gc.work_dir must still measure the agent home (source=home, dirty=3), got: $OUT"
}

test_absent_worktree_does_not_shift_the_home_into_the_worktree_column() {
    # The TSV between jq and the read loop is tab-separated, and tab is an IFS
    # *whitespace* character — so `IFS=$'\t' read` COLLAPSES a run of tabs. If
    # the absent `work_dir` were emitted as an empty field, `read` would land
    # the agent home path in $work_dir and label it `worktree`, attributing the
    # agent's uncommitted work to a bead that has no branch yet. That inverts
    # the fix in exactly the case it exists for, so the scope label is asserted
    # explicitly, not just the presence of counts.
    local home
    home=$(make_worktree collapse_home)
    echo work >"$home/x.go"

    run_check "$(bead_json_scoped gp-collapse "$POLECAT" "$ANCIENT" - "$home")" TZ="$OFFSET_TZ"
    printf '%s' "$OUT" | grep -q '	worktree	' &&
        fail "the agent home must never be reported as a per-bead worktree, got: $OUT"
    printf '%s' "$OUT" | grep -q '	home	' ||
        fail "expected source=home for a bead with no per-bead worktree, got: $OUT"
    return 0
}

test_per_bead_worktree_wins_over_agent_home() {
    # Both scopes present is the normal post-branch-setup state — ta-sec carries
    # all four keys, with `work_dir` a CHILD of `gc.work_dir`. The bead's own
    # worktree is the bead's own work and must win; the home is only a fallback.
    # The home is given more dirty files than the worktree so a precedence
    # inversion cannot pass by coincidence.
    local wt home
    wt=$(make_worktree pref_wt)
    home=$(make_worktree pref_home)
    echo one >"$wt/only_here.go"
    echo a >"$home/h1.go"
    echo b >"$home/h2.go"
    echo c >"$home/h3.go"
    echo d >"$home/h4.go"

    run_check "$(bead_json_scoped gp-pref "$POLECAT" "$ANCIENT" "$wt" "$home")" TZ="$OFFSET_TZ"
    printf '%s' "$OUT" | grep -q '	worktree	0	1$' ||
        fail "the per-bead worktree must win over the agent home (dirty=1, not 4), got: $OUT"
}

test_home_is_measured_when_the_per_bead_worktree_is_gone() {
    # ta-af7's shape: `work_dir` names a worktree that has since been cleaned
    # up, while `gc.work_dir` still points at a live agent home. A stale path
    # must not suppress the fallback — the home is still on disk and can still
    # be holding work worth salvaging.
    local home
    home=$(make_worktree gone_home)
    echo salvageable >"$home/keep.go"

    run_check "$(bead_json_scoped gp-gone "$POLECAT" "$ANCIENT" "$tmp/cleaned-up-worktree" "$home")" TZ="$OFFSET_TZ"
    printf '%s' "$OUT" | grep -q '	home	0	1$' ||
        fail "a vanished per-bead worktree must fall back to the agent home, got: $OUT"
}

test_neither_scope_on_disk_still_reports_no_measurement() {
    # The honest negative. When neither directory exists there genuinely is
    # nothing to measure, and the row must say so with `-` rather than inventing
    # a zero — `dirty=0` would read as "verified clean", which is the false
    # assurance this whole change exists to remove.
    run_check "$(bead_json_scoped gp-none "$POLECAT" "$(ts_ago 60)" "$tmp/no-wt" "$tmp/no-home")" TZ="$OFFSET_TZ"
    printf '%s' "$OUT" | grep -q '^fresh	gp-none	.*	bead	-	-$' ||
        fail "with neither scope on disk the git columns must be '-', not 0, got: $OUT"
}

test_git_dir_churn_does_not_mask_staleness() {
    # The witness's own `git status` calls touch .git. If .git counted as
    # activity every worktree would read fresh forever and the check would be
    # decorative.
    local wt
    wt=$(make_worktree wt_gitchurn)
    echo work >"$wt/file.txt"
    age_tree "$wt" "$(( $(now_epoch) - 14400 ))"
    find "$wt/.git" -type f -exec touch {} + 2>/dev/null || true

    run_check "$(bead_json gp-churn "$POLECAT" "$ANCIENT" "$wt")" TZ="$OFFSET_TZ"
    printf '%s' "$OUT" | grep -q '^stale	gp-churn	' ||
        fail "a freshly-touched .git must not mask a stale worktree, got: $OUT"
}

test_future_mtime_is_skew_not_stale() {
    local wt
    wt=$(make_worktree wt_future)
    echo work >"$wt/file.txt"
    set_mtime "$wt/file.txt" "$(( $(now_epoch) + 3600 ))"

    run_check "$(bead_json gp-skew "$POLECAT" "$ANCIENT" "$wt")" TZ="$OFFSET_TZ"
    [ "$RC" -eq 0 ] || fail "a future mtime is clock skew, not staleness, got $RC ($OUT)"
    printf '%s' "$OUT" | grep -q '^fresh	gp-skew	.*	0	' ||
        fail "a future mtime should clamp to age 0, got: $OUT"
}

test_zero_time_sentinel_is_no_heartbeat_not_ancient() {
    run_check "$(bead_json gp-zero "$POLECAT" "0001-01-01T00:00:00Z" "$tmp/does-not-exist")" TZ="$OFFSET_TZ"
    printf '%s' "$OUT" | grep -q '^no-heartbeat	gp-zero	.*	-	-	-	-	-$' ||
        fail "the zero-time sentinel should report no-heartbeat, got: $OUT"
    printf '%s' "$OUT" | grep -q 'stale' &&
        fail "the zero-time sentinel must never be parsed as an ancient heartbeat"
    [ "$RC" -eq 1 ] || fail "an unmeasurable heartbeat is a finding (exit 1), got $RC"
    return 0
}

test_malformed_bead_stamp_is_no_heartbeat() {
    run_check "$(bead_json gp-bad "$POLECAT" "not-a-timestamp" "$tmp/does-not-exist")" TZ="$OFFSET_TZ"
    printf '%s' "$OUT" | grep -q '^no-heartbeat	gp-bad	' ||
        fail "an unparseable stamp should report no-heartbeat, got: $OUT"
    [ "$RC" -eq 1 ] || fail "an unparseable heartbeat is a finding (exit 1), got $RC"
}

test_fractional_seconds_parse() {
    local fresh
    fresh=$(ts_ago 45)
    run_check "$(bead_json gp-frac "$POLECAT" "${fresh%Z}.123456789Z" "$tmp/does-not-exist")" TZ="$OFFSET_TZ"
    [ "$RC" -eq 0 ] || fail "a fractional-second stamp should parse as fresh, got $RC ($OUT)"
    printf '%s' "$OUT" | grep -q '^fresh	gp-frac	' ||
        fail "a fractional-second stamp should report fresh, got: $OUT"
}

test_non_utc_offset_stamp_parses() {
    # bd normally emits Z, but an offset-bearing stamp must not be mis-read.
    local epoch stamp
    epoch=$(( $(now_epoch) - 60 ))
    stamp=$(TZ="$OFFSET_TZ" date -d "@$epoch" +%Y-%m-%dT%H:%M:%S%z 2>/dev/null \
        || TZ="$OFFSET_TZ" date -r "$epoch" +%Y-%m-%dT%H:%M:%S%z)
    run_check "$(bead_json gp-off "$POLECAT" "$stamp" "$tmp/does-not-exist")" TZ=UTC
    [ "$RC" -eq 0 ] || fail "an offset-bearing stamp one minute old must read fresh, got $RC ($OUT)"
    printf '%s' "$OUT" | grep -q '^fresh	gp-off	' ||
        fail "an offset-bearing stamp must be converted, not truncated, got: $OUT"
}

# --- selection and configuration -------------------------------------------

test_non_polecat_assignees_are_ignored() {
    run_check "$(printf '[
      {"id":"gp-a","assignee":"gastown.refinery","status":"in_progress","updated_at":"%s","metadata":{}},
      {"id":"gp-b","assignee":"gastown.witness","status":"in_progress","updated_at":"%s","metadata":{}},
      {"id":"gp-c","assignee":"policycat-7","status":"in_progress","updated_at":"%s","metadata":{}},
      {"id":"gp-d","assignee":"%s","status":"in_progress","updated_at":"%s","metadata":{}}
    ]' "$ANCIENT" "$ANCIENT" "$ANCIENT" "$POLECAT" "$(ts_ago 30)")" TZ="$OFFSET_TZ"
    [ "$RC" -eq 0 ] || fail "only polecat beads should be checked, got $RC ($OUT) [$ERR]"
    [ "$(printf '%s\n' "$OUT" | grep -c .)" -eq 1 ] ||
        fail "exactly one row (the polecat) expected, got: $OUT"
    printf '%s' "$OUT" | grep -q 'policycat' &&
        fail "a bare substring match must not pull in unrelated assignees"
    return 0
}

test_rig_qualified_assignee_matches() {
    run_check "$(bead_json gp-rig "alpha/polecat" "$ANCIENT" "$tmp/nope")" TZ="$OFFSET_TZ"
    [ "$RC" -eq 1 ] || fail "a rig-qualified polecat assignee should still be checked, got $RC ($OUT)"
    printf '%s' "$OUT" | grep -q '	alpha/polecat	' ||
        fail "the rig-qualified assignee should be reported, got: $OUT"
}

test_threshold_is_configurable() {
    local wt
    wt=$(make_worktree wt_window)
    echo work >"$wt/file.txt"
    age_tree "$wt" "$(( $(now_epoch) - 1800 ))"   # 30m
    local payload
    payload=$(bead_json gp-win "$POLECAT" "$ANCIENT" "$wt")

    run_check "$payload" TZ="$OFFSET_TZ"
    [ "$RC" -eq 0 ] || fail "30m is inside the 45m default, got $RC ($OUT)"
    run_check "$payload" TZ="$OFFSET_TZ" GASTOWN_POLECAT_STALE_MIN=15
    [ "$RC" -eq 1 ] || fail "GASTOWN_POLECAT_STALE_MIN=15 should flag a 30m-quiet worktree, got $RC ($OUT)"
    printf '%s' "$ERR" | grep -q 'window 15m' ||
        fail "the summary should report the configured window, got: $ERR"
}

test_bad_threshold_fails_loudly() {
    run_check '[]' GASTOWN_POLECAT_STALE_MIN=abc
    [ "$RC" -eq 2 ] || fail "a non-numeric window must exit 2, got $RC"
    run_check '[]' GASTOWN_POLECAT_STALE_MIN=0
    [ "$RC" -eq 2 ] || fail "a zero window must exit 2, got $RC"
}

test_role_override() {
    run_check "$(bead_json gp-role "alpha/scout" "$ANCIENT" "$tmp/nope")" GASTOWN_POLECAT_ROLE=scout
    [ "$RC" -eq 1 ] || fail "GASTOWN_POLECAT_ROLE should retarget the check, got $RC ($OUT)"
    printf '%s' "$OUT" | grep -q '	alpha/scout	' ||
        fail "the overridden role should be checked, got: $OUT"
}

test_empty_pool_is_not_a_finding() {
    run_check '[]'
    [ "$RC" -eq 0 ] || fail "no in_progress beads is not a finding, got $RC ($OUT)"
    printf '%s' "$ERR" | grep -q 'nothing to check' ||
        fail "the summary should say nothing was checked, got: $ERR"
}

test_object_wrapper_shape_is_tolerated() {
    run_check "$(printf '{"issues":[{"id":"gp-w","assignee":"%s","status":"in_progress","updated_at":"%s","metadata":{}}]}' \
        "$POLECAT" "$(ts_ago 30)")" TZ="$OFFSET_TZ"
    [ "$RC" -eq 0 ] || fail "the object-wrapper shape should still parse, got $RC ($OUT) [$ERR]"
    printf '%s' "$OUT" | grep -q '^fresh	gp-w	' ||
        fail "the wrapped shape should yield the same verdict, got: $OUT"
}

# --- failure modes ---------------------------------------------------------

test_unreadable_bead_list_fails_loud() {
    # Schema drift or a down Dolt must never read as health.
    mkdir -p "$tmp/badbin"
    printf '#!/usr/bin/env sh\nexit 1\n' >"$tmp/badbin/gc"
    chmod +x "$tmp/badbin/gc"
    set +e
    OUT=$(GC_CITY="$CITY" PATH="$tmp/badbin:$PATH" bash "$SCRIPT" 2>"$ERRFILE")
    RC=$?
    set -e
    [ "$RC" -eq 2 ] || fail "a failing 'gc bd list' must exit 2, got $RC"
    grep -q 'NOT measured' "$ERRFILE" ||
        fail "a failing bead read should say progress was not measured"
}

test_missing_city_fails_loud() {
    set +e
    OUT=$(cd "$tmp" && GC_CITY="$tmp/nope" PATH="$BIN:$PATH" bash "$SCRIPT" 2>"$ERRFILE")
    RC=$?
    set -e
    [ "$RC" -eq 2 ] || fail "a missing city must exit 2, got $RC"
    grep -q 'no city.toml found' "$ERRFILE" || fail "expected the city-resolution error"
}

# --- source-level invariants ------------------------------------------------

test_every_z_suffixed_format_is_explicitly_utc() {
    # gp-9ly in one assertion: a `Z` suffix is a claim that the value is UTC, so
    # every format string that emits one must be produced under `date -u`.
    # Formatting a local time and appending `Z` is the original bug.
    local offenders
    offenders=$(grep -n '%H:%M:%SZ' "$SCRIPT" | grep -vE '^[0-9]+:[[:space:]]*#' | grep -v 'date -u' || true)
    [ -z "$offenders" ] ||
        fail "every Z-suffixed timestamp format must be produced under 'date -u'; offending lines: $offenders"
}

test_file_mtimes_come_from_stat_not_date() {
    # `date -r` means epoch-seconds on BSD but a FILENAME on GNU. Reading a file
    # mtime through it is unportable in opposite directions on the two
    # platforms, so mtimes must come from `stat`, which prints a bare epoch.
    grep -q 'stat \$STAT_MTIME' "$SCRIPT" ||
        fail "file mtimes should be read with the detected stat flavour"
    grep -nE 'date [^|#]*-r [^ ]*(dir|file|path|wt|work_dir)' "$SCRIPT" &&
        fail "a file path must never be passed to 'date -r' — use stat"
    return 0
}

test_both_work_dir_namespaces_are_read() {
    # gp-6k8: the fallback IS the fix. Collapsing this back to a single
    # unprefixed lookup is a one-line "simplification" that silently restores
    # the false negative for every polecat parked before branch-setup, so the
    # three moving parts are pinned at the source level.
    grep -q 'gc\.work_dir' "$SCRIPT" ||
        fail "the check must read the gc.work_dir agent home as a fallback (gp-6k8)"
    grep -q 'metadata\.work_dir' "$SCRIPT" ||
        fail "the check must still prefer the per-bead metadata.work_dir"
    grep -q 'read -r bead assignee updated work_dir gc_work_dir' "$SCRIPT" ||
        fail "the read loop must consume both directory columns"
    grep -q 'def dash:' "$SCRIPT" ||
        fail "absent paths must be emitted as '-', never as an empty field: tab collapses under IFS (gp-6k8)"
}

test_uses_no_bash4_only_constructs() {
    ! grep -nE 'declare -A|local -A|mapfile|readarray|\$\{[A-Za-z_]+\^|\$\{[A-Za-z_]+,,|&>>|\[\[ -v ' "$SCRIPT" >/dev/null ||
        fail "the check must stay bash 3.2 compatible (the fleet includes macOS)"
}

# --- the `gc gastown progress-check` wrapper --------------------------------
#
# gp-b68: everything above was correct and completely unreachable. The witness's
# check-polecat-health step resolved the check as
# "${GC_PACK_DIR:-}/assets/scripts/polecat-progress-check.sh", but GC_PACK_DIR is
# set by `gc` when `gc` invokes a pack command and is absent from a plain agent
# session. The path expanded to "/assets/scripts/...", the `[ -x ]` guard in
# front of it failed, and the step printed a message that reads like a considered
# fallback — so the deterministic staleness pass never ran once, and every patrol
# fell back to eyeballing while looking like it had measured.
#
# gp-3qb routed the command and pinned this contract for the DEACON's heartbeat
# check. The witness's progress check was routed in the same sweep but its
# wrapper was left unpinned, so nothing here failed if the wrapper broke. These
# tests close that asymmetry: they cover the resolution contract, not the
# measurement, which the run_check tests above already own.

test_wrapper_is_executable() {
    [ -x "$WRAPPER" ] || fail "$WRAPPER must be executable"
    [ -f "$ROOT/gastown/commands/progress-check/help.md" ] ||
        fail "missing commands/progress-check/help.md"
}

test_wrapper_rejects_missing_pack_context() {
    # Invoked by path instead of through `gc`, so GC_PACK_DIR is empty. This is
    # the gp-b68 defect's exact input: it must fail loudly rather than resolving
    # to /assets/scripts/... and reporting nothing measured as nothing wrong.
    WRAP_PACK="" run_wrapper '[]'
    [ "$RC" -eq 2 ] || fail "missing GC_PACK_DIR must exit 2, got $RC"
    printf '%s' "$ERR" | grep -q 'missing Gas City pack context' ||
        fail "the wrapper must name the missing pack context, got: $ERR"
}

test_wrapper_rejects_missing_city_context() {
    WRAP_CITY="" run_wrapper '[]'
    [ "$RC" -eq 2 ] || fail "missing GC_CITY_PATH must exit 2, got $RC"
}

test_wrapper_reports_a_pack_without_the_check() {
    # An older pack version that predates the check. Exit 2 — "freshness was not
    # measured" — never 0, which would read as "every polecat is fresh".
    WRAP_PACK="$tmp" run_wrapper '[]'
    [ "$RC" -eq 2 ] || fail "a pack missing the check must exit 2, got $RC"
    printf '%s' "$ERR" | grep -q 'not found in this pack version' ||
        fail "the wrapper must say the check is missing, got: $ERR"
}

test_wrapper_resolves_the_city_from_pack_context() {
    # GC_CITY unset and cwd outside any city — the witness's actual situation
    # when `gc` invokes the command. The wrapper must use the city root gc
    # resolved rather than walking up from cwd, which would find no city.toml.
    local wt
    wt=$(make_worktree wt_wrapper_city)
    echo 'package main' >"$wt/live.go"
    run_wrapper "$(bead_json bd-wcity "$POLECAT" "$ANCIENT" "$wt")"
    [ "$RC" -eq 0 ] ||
        fail "the wrapper must resolve the city from GC_CITY_PATH, got $RC: $ERR"
    printf '%s' "$OUT" | grep -q "^fresh	bd-wcity	$POLECAT	" ||
        fail "the wrapper should relay the check's TSV rows, got: $OUT"
}

test_wrapper_passes_findings_exit_through() {
    # Exit 1 is a verdict, not an error to swallow: the witness branches on it to
    # decide whether to peek for proof of life. A wrapper that collapsed it to 0
    # would restore the original silence through a different route.
    run_wrapper "$(bead_json bd-wfind "$POLECAT" "$(ts_ago 6000)" "$tmp/absent")"
    [ "$RC" -eq 1 ] || fail "the wrapper must pass through exit 1 (findings), got $RC"
    printf '%s' "$OUT" | grep -q "^stale	bd-wfind	" || fail "expected a stale row, got: $OUT"
}

test_wrapper_passes_the_stale_window_through() {
    # The formula supplies the window as an environment prefix on the `gc` call.
    # If the wrapper dropped it, every rig would silently fall back to 45m — a
    # quieter version of the same bug, since the check would still print rows.
    run_wrapper "$(bead_json bd-wwin "$POLECAT" "$(ts_ago 3600)" "$tmp/absent")" \
        GASTOWN_POLECAT_STALE_MIN=30
    [ "$RC" -eq 1 ] ||
        fail "a 60m-old heartbeat must be stale under a 30m window, got $RC ($OUT)"
    printf '%s' "$ERR" | grep -q 'window 30m' ||
        fail "the 30m window must reach the check, got: $ERR"
}

# --- the caller actually invokes it the resolvable way ----------------------

test_formula_invokes_the_command_not_the_path() {
    local formula="$ROOT/gastown/formulas/mol-witness-patrol.toml"
    grep -Fq 'gc gastown progress-check' "$formula" ||
        fail "mol-witness-patrol must run the check as 'gc gastown progress-check'"
    grep -Fq 'GASTOWN_POLECAT_STALE_MIN={{polecat_stale_min}}' "$formula" ||
        fail "the window must come from the formula var, not a number invented per cycle"
    # The regression itself. Match the code CONSTRUCT, not the string
    # GC_PACK_DIR: the prose under the snippet quotes the broken path on purpose,
    # to record why it was broken, and a string match would forbid explaining it.
    ! grep -qE '^[[:space:]]*CHECK=' "$formula" ||
        fail "formula must not resolve the check into a path variable"
    ! grep -qE '^[[:space:]]*(bash|sh|exec)[[:space:]].*GC_PACK_DIR' "$formula" ||
        fail "formula must not execute a script through ambient GC_PACK_DIR"
}

test_recent_mtime_is_fresh_under_non_utc_tz
test_four_minute_old_worktree_is_fresh_under_non_utc_tz
test_verdict_is_identical_across_timezones
test_heartbeat_column_is_utc_not_local
test_genuinely_stale_worktree_is_flagged
test_worktree_activity_overrides_stale_bead_stamp
test_bead_stamp_carries_when_worktree_is_gone
test_uncommitted_diff_with_zero_commits_is_not_stale
test_agent_home_is_measured_when_per_bead_worktree_is_absent
test_absent_worktree_does_not_shift_the_home_into_the_worktree_column
test_per_bead_worktree_wins_over_agent_home
test_home_is_measured_when_the_per_bead_worktree_is_gone
test_neither_scope_on_disk_still_reports_no_measurement
test_git_dir_churn_does_not_mask_staleness
test_future_mtime_is_skew_not_stale
test_zero_time_sentinel_is_no_heartbeat_not_ancient
test_malformed_bead_stamp_is_no_heartbeat
test_fractional_seconds_parse
test_non_utc_offset_stamp_parses
test_non_polecat_assignees_are_ignored
test_rig_qualified_assignee_matches
test_threshold_is_configurable
test_bad_threshold_fails_loudly
test_role_override
test_empty_pool_is_not_a_finding
test_object_wrapper_shape_is_tolerated
test_unreadable_bead_list_fails_loud
test_missing_city_fails_loud
test_every_z_suffixed_format_is_explicitly_utc
test_file_mtimes_come_from_stat_not_date
test_both_work_dir_namespaces_are_read
test_uses_no_bash4_only_constructs
test_wrapper_is_executable
test_wrapper_rejects_missing_pack_context
test_wrapper_rejects_missing_city_context
test_wrapper_reports_a_pack_without_the_check
test_wrapper_resolves_the_city_from_pack_context
test_wrapper_passes_findings_exit_through
test_wrapper_passes_the_stale_window_through
test_formula_invokes_the_command_not_the_path

echo "polecat progress check tests passed"
