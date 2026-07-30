#!/usr/bin/env bash
# polecat-progress-check.sh — deterministic progress measurement for in-flight
# polecat work beads. Read-only: it measures, prints, and exits. It never
# nudges, mails, or files warrants — `check-polecat-health` in
# mol-witness-patrol owns those decisions.
#
# The gap it closes: the witness patrol step used to ask an LLM to eyeball
# "is this polecat still making progress?" with no command to run, so the
# model improvised `date` arithmetic every cycle. One improvisation stat'd a
# file, got a LOCAL-time mtime, formatted it with a `Z` suffix, and compared it
# against a UTC `now`. On a PDT host that is a 7-hour error: a file touched 4
# minutes earlier read as ~7h stale, and a warrant was filed against a polecat
# that was working correctly (gp-9ly).
#
# Timestamp arithmetic here is epoch-to-epoch and never touches a local-time
# string. `stat` yields raw epoch seconds, which carry no timezone at all;
# the only formatting happens in epoch_to_utc(), on the way OUT, explicitly
# under `date -u`. There is deliberately no code path that can format a local
# mtime — that is the bug this script exists to make unrepeatable.
#
# For each in_progress work bead assigned to a polecat, the heartbeat is the
# NEWER of the bead's `updated_at` and the newest file mtime under the polecat's
# working directory. Either alone is misleading: a polecat editing files for
# an hour without touching bd looks stale by bead time, and a polecat mid
# `go test` touches no files but is plainly alive.
#
# Which directory that is takes TWO keys, in different namespaces, because the
# bead carries two directories with different scopes (gp-6k8):
#
#   metadata.work_dir      the PER-BEAD worktree, e.g. <home>/worktrees/ta-sec.
#                          Written by the polecat's branch-setup step.
#   metadata.gc.work_dir   the agent's PERSISTENT HOME workspace, e.g.
#                          <city>/.gc/worktrees/<rig>/polecats/gastown.slit.
#                          Written by gc core when the session is stamped.
#
# These are NOT two spellings of one field — the second is the parent of the
# first — so this check reads the per-bead worktree by preference and falls back
# to the agent home. The fallback is the point: a polecat parked BEFORE
# branch-setup has no `metadata.work_dir` at all, and its edits are sitting in
# the agent home. Reading only the unprefixed key made that case measure nothing
# and report `-`, which a caller reads as "nothing is at risk on disk" — the
# false negative that authorized resetting a session over live unpushed work.
# An absent per-bead worktree means "look at the home", never "nothing at risk".
#
# Output: one TSV row per checked bead on stdout, column header on stderr.
#
#   verdict <TAB> bead <TAB> assignee <TAB> age_seconds <TAB> heartbeat <TAB>
#   source <TAB> commits <TAB> dirty
#
#   fresh         heartbeat inside the window
#   stale         heartbeat older than the window — NOT proof of a stall, see below
#   no-heartbeat  no usable timestamp at all — nothing was measured
#
#   source        which signal won: `worktree`, `home`, `bead`, or `-`
#   commits       commits ahead of upstream/origin-main, or `-` if unresolvable
#   dirty         count of uncommitted+untracked paths, or `-`
#
# `source` distinguishes the two directory scopes, so the caller never has to
# guess which one the `commits`/`dirty` counts describe:
#
#   worktree  the per-bead worktree — counts belong to this bead's branch
#   home      the agent home workspace — counts are the AGENT's, not this
#             bead's. Still real work at risk on disk, but attributing it to
#             this bead's branch would be wrong; there is no branch yet.
#
# Exit codes:  0 = every checked polecat is fresh (or none to check)
#              1 = findings on stdout (stale and/or no-heartbeat)
#              2 = the check could not run (bad env, unreadable bead list, or
#                  no usable `stat` — freshness was NOT measured)
#
# A `stale` verdict is NECESSARY BUT NOT SUFFICIENT to file a warrant. It means
# only "no file or bead activity in the window", which a polecat blocked in one
# long tool call legitimately produces. Confirm with a live proof-of-life peek
# before escalating; a rising token counter across two peeks OVERRIDES this
# verdict. See `check-polecat-health` in mol-witness-patrol.
#
# `commits` and `dirty` are reported so the caller does not mistake normal
# mid-flight state for a stall. A long-lived polecat legitimately shows a large
# `dirty` count with `commits` at 0 — it has not reached its commit step yet.
# That combination is NOT evidence of a stall and must never be read as one.
#
# Env:
#   GC_CITY                    city root (auto-discovered if unset, walks up)
#   GASTOWN_POLECAT_STALE_MIN  staleness window in minutes (default: 45)
#   GASTOWN_POLECAT_ROLE       assignee token to match (default: polecat)
#
# Usage:
#   polecat-progress-check.sh
#   GASTOWN_POLECAT_STALE_MIN=90 polecat-progress-check.sh

set -euo pipefail

# Resolve city root: env wins, else walk up from cwd looking for city.toml.
if [ -z "${GC_CITY:-}" ]; then
  dir=$(pwd)
  while [ "$dir" != "/" ]; do
    if [ -f "$dir/city.toml" ]; then
      GC_CITY="$dir"
      break
    fi
    dir=$(dirname "$dir")
  done
fi

if [ -z "${GC_CITY:-}" ] || [ ! -f "$GC_CITY/city.toml" ]; then
  echo "polecat-progress-check: GC_CITY not set and no city.toml found" >&2
  exit 2
fi

# Default window: a polecat's longest legitimate silence is one full
# build/vet/test cycle inside a single tool call. Observed cycles on this fleet
# run ~4 minutes, and a large rebase or a cold module download can multiply
# that. 45m leaves an order of magnitude of headroom over the common case while
# still surfacing a genuine multi-hour wedge within one patrol cycle. Raise it
# for rigs whose test suites run long.
STALE_MIN="${GASTOWN_POLECAT_STALE_MIN:-45}"
ROLE="${GASTOWN_POLECAT_ROLE:-polecat}"

case "$STALE_MIN" in
  ''|*[!0-9]*)
    echo "polecat-progress-check: GASTOWN_POLECAT_STALE_MIN must be a positive integer (got '$STALE_MIN')" >&2
    exit 2
    ;;
esac
if [ "$STALE_MIN" -le 0 ]; then
  echo "polecat-progress-check: GASTOWN_POLECAT_STALE_MIN must be a positive integer (got '$STALE_MIN')" >&2
  exit 2
fi

STALE_SECS=$((STALE_MIN * 60))

# `date -u +%s` is epoch seconds — identical on every host regardless of $TZ.
# Every comparison below is between two such integers. Nothing in this script
# compares formatted time strings, which is what made the original check
# timezone-dependent.
NOW=$(date -u +%s)

# Detect the local `stat` flavour once. BSD (macOS) spells mtime `-f %m`; GNU
# spells it `-c %Y` and rejects `-f`. Both print a bare epoch integer, so once
# the flavour is known the rest of the script is identical on either platform.
if stat -f %m . >/dev/null 2>&1; then
  STAT_MTIME='-f %m'
elif stat -c %Y . >/dev/null 2>&1; then
  STAT_MTIME='-c %Y'
else
  echo "polecat-progress-check: no usable 'stat' (tried BSD -f %m and GNU -c %Y) — progress NOT measured" >&2
  exit 2
fi

# epoch_to_utc — epoch seconds to an RFC3339 UTC string, for DISPLAY only.
# The `-u` is what makes the `Z` suffix truthful; every `Z`-producing format in
# this file is paired with it, and the test suite asserts that invariant.
# GNU spells the input `-d @EPOCH`; BSD spells it `-r EPOCH`. (BSD `-r` takes
# epoch seconds, GNU `-r` takes a FILENAME — never feed a path to either.)
epoch_to_utc() {
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || printf '-'
}

# ts_epoch — RFC3339 timestamp to epoch seconds, printing 0 for "no usable
# signal": empty, null, or the Go zero-time sentinel bd emits for a field it has
# never set. 0 means unknown, never "ancient".
ts_epoch() {
  local ts="$1" norm epoch
  case "$ts" in
    ''|null|0001-*) printf '0'; return 0 ;;
  esac
  norm=$(printf '%s' "$ts" | sed -E 's/\.[0-9]+(Z|[+-][0-9:]+)?$/\1/')
  epoch=$(date -u -d "$norm" +%s 2>/dev/null) \
    || epoch=$(date -u -j -f '%Y-%m-%dT%H:%M:%S%z' \
                 "$(printf '%s' "$norm" | sed 's/Z$/+0000/')" +%s 2>/dev/null) \
    || epoch=''
  case "$epoch" in
    ''|*[!0-9]*) printf '0'; return 0 ;;
  esac
  [ "$epoch" -gt 0 ] && printf '%s' "$epoch" || printf '0'
}

# newest_mtime — newest file mtime under a directory, as epoch seconds; 0 when
# nothing is readable. `.git` is pruned because the witness's own `git status`
# calls touch index files, which would make every worktree look eternally busy.
# `node_modules` is pruned for walk cost. No timezone is involved at any point:
# `stat` emits integers and they are compared as integers.
#
# `.remember` and `.gc` are pruned for the same reason as `.git`: they are
# written by tooling, not by the polecat doing work. Measured on a PARKED agent
# home (gp-6k8), the four newest files were all plumbing — `.remember/tmp/
# save-session.pid`, `.remember/logs/memory-<date>.log`, `.gc/tmp/skill-catalog-
# *.b64` — all stamped while the session sat idle at a prompt. Counting those as
# activity makes an idle agent home read fresh forever, which matters most for
# the home-scope fallback above: those beads have no other directory signal, so
# the staleness check would go permanently blind on exactly them.
newest_mtime() {
  local dir="$1" newest
  # shellcheck disable=SC2086 # $STAT_MTIME must word-split into two args.
  newest=$(find "$dir" \
      \( -name .git -o -name node_modules -o -name .remember -o -name .gc \) -prune -o -type f -print0 2>/dev/null \
    | xargs -0 stat $STAT_MTIME 2>/dev/null \
    | sort -rn 2>/dev/null \
    | sed -n '1p') || newest=''
  # `sed -n 1p` rather than `head -1`: it drains stdin instead of closing the
  # pipe early, so `xargs` never dies of SIGPIPE under `pipefail`.
  case "$newest" in
    ''|*[!0-9]*) printf '0' ;;
    *) printf '%s' "$newest" ;;
  esac
}

if ! BEADS=$(gc bd list --status=in_progress --json --limit=0 2>/dev/null); then
  echo "polecat-progress-check: 'gc bd list --status=in_progress --json' failed — progress NOT measured" >&2
  exit 2
fi

# Tolerate both the bare top-level array bd returns today and an object wrapper,
# the way the sibling witness heartbeat check does — this schema has drifted before.
JQ_ISSUES='def issues_of: (.issues? // .) | if type == "array" then . else [] end;'

# Emit `-` for an absent path rather than an empty field. This is load-bearing,
# not cosmetic: tab is an IFS *whitespace* character, so `IFS=$'\t' read`
# COLLAPSES a run of tabs. A bead carrying only `gc.work_dir` would emit
# `...<TAB><TAB>/agent/home` and `read` would land the home path in $work_dir —
# measuring the agent home as if it were the per-bead worktree, and inverting
# this fix in exactly the case it exists for. A literal directory named `-`
# would be misread as absent; that is not a path any of this writes.
JQ_DASH='def dash: if . == null then "-" else tostring | if . == "" then "-" else . end end;'

if ! TOTAL=$(printf '%s' "$BEADS" | jq -r "$JQ_ISSUES issues_of | length" 2>/dev/null); then
  echo "polecat-progress-check: could not parse the bead list — progress NOT measured" >&2
  exit 2
fi

# Match the role as a delimited token inside the assignee, never a bare
# substring: `gastown__polecat-gk-z5s` and `alpha/polecat` both match, while an
# unrelated agent named `policy-cat` does not.
ROWS=$(printf '%s' "$BEADS" | jq -r --arg role "$ROLE" "
  $JQ_ISSUES
  $JQ_DASH
  issues_of
  | .[]
  | select((.assignee // \"\") | test(\"(^|[^a-zA-Z0-9])\" + \$role + \"([^a-zA-Z0-9]|\$)\"))
  | [ (.id // \"?\"),
      (.assignee // \"-\"),
      (.updated_at // \"\"),
      (.metadata.work_dir | dash),
      (.metadata[\"gc.work_dir\"] | dash)
    ]
  | @tsv
" 2>/dev/null) || ROWS=''

printf 'verdict\tbead\tassignee\tage_seconds\theartbeat\tsource\tcommits\tdirty\n' >&2

CHECKED=0
FINDINGS=0
STALE=0

while IFS=$'\t' read -r bead assignee updated work_dir gc_work_dir; do
  [ -n "${bead:-}" ] || continue
  CHECKED=$((CHECKED + 1))

  bead_epoch=$(ts_epoch "$updated")

  # Resolve the directory to measure across both namespaces. Prefer the
  # per-bead worktree; fall back to the agent home when it is absent OR its
  # directory is gone. Both halves of that fallback matter: `metadata.work_dir`
  # is missing entirely before branch-setup runs, and it outlives the directory
  # after a worktree is cleaned up. In both states the agent home is still on
  # disk and can still be holding uncommitted work.
  dir=''
  scope='-'
  if [ "$work_dir" != '-' ] && [ -d "$work_dir" ]; then
    dir=$work_dir
    scope='worktree'
  elif [ "$gc_work_dir" != '-' ] && [ -d "$gc_work_dir" ]; then
    dir=$gc_work_dir
    scope='home'
  fi

  tree_epoch=0
  commits='-'
  dirty='-'
  if [ -n "$dir" ]; then
    tree_epoch=$(newest_mtime "$dir")
    # Commits ahead of wherever this branch forked from. Reported, never
    # judged: 0 commits alongside a large `dirty` count is ordinary mid-flight
    # state for a polecat that has not reached its commit step.
    commits=$(git -C "$dir" rev-list --count '@{upstream}..HEAD' 2>/dev/null) \
      || commits=$(git -C "$dir" rev-list --count 'origin/main..HEAD' 2>/dev/null) \
      || commits='-'
    dirty=$(git -C "$dir" status --porcelain 2>/dev/null | wc -l | tr -d ' ') || dirty='-'
  fi

  # Newest signal wins. Both operands are epoch integers. When the directory
  # signal wins, `source` names WHICH scope it came from, so a caller reading
  # `home` knows the counts are the agent's and not this bead's branch.
  if [ "$tree_epoch" -gt "$bead_epoch" ]; then
    best=$tree_epoch
    source=$scope
  elif [ "$bead_epoch" -gt 0 ]; then
    best=$bead_epoch
    source='bead'
  else
    best=0
    source='-'
  fi

  if [ "$best" -eq 0 ]; then
    FINDINGS=$((FINDINGS + 1))
    printf 'no-heartbeat\t%s\t%s\t-\t-\t-\t%s\t%s\n' "$bead" "$assignee" "$commits" "$dirty"
    continue
  fi

  age=$((NOW - best))
  # A heartbeat in the future is clock skew, not staleness.
  [ "$age" -lt 0 ] && age=0

  if [ "$age" -ge "$STALE_SECS" ]; then
    STALE=$((STALE + 1))
    FINDINGS=$((FINDINGS + 1))
    printf 'stale\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$bead" "$assignee" "$age" "$(epoch_to_utc "$best")" "$source" "$commits" "$dirty"
  else
    printf 'fresh\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$bead" "$assignee" "$age" "$(epoch_to_utc "$best")" "$source" "$commits" "$dirty"
  fi
done <<EOF
$ROWS
EOF

if [ "$CHECKED" -eq 0 ]; then
  echo "polecat-progress-check: no in_progress '$ROLE' bead among $TOTAL in_progress bead(s) — nothing to check" >&2
  exit 0
fi

echo "polecat-progress-check: checked $CHECKED '$ROLE' bead(s), $STALE stale (window ${STALE_MIN}m)" >&2

[ "$FINDINGS" -eq 0 ] || exit 1
