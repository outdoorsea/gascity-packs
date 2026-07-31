#!/usr/bin/env bash
# polecat-worktree-reap.sh — reap per-bead polecat worktrees whose work has
# already landed. Reports by default; removes only under --reap.
#
# The leak it closes (gp-a7z): no component owned a polecat worktree's death.
# The refinery deletes the BRANCH after merge, not the tree. The witness removes
# a tree only inside orphan recovery, which keys on a live-but-unreachable
# ASSIGNEE — a landed bead is closed and unassigned, so it never enters that
# path. The controller manages processes, not directories. Result: one worktree
# per completed bead, accumulating forever (measured: 5 trees at filing, 8 two
# days later, ~3/day at that throughput).
#
# ## What makes a tree disposable
#
# Gas Town's canonical work chain is `worktree -> (push) -> branch -> (merge) ->
# target`. Each transition moves the canonical copy forward and makes the
# previous location disposable. This script asserts that the work has reached
# the target, and only then treats the tree as garbage.
#
# Two checks carry the safety argument. They are the ones that answer "can
# reaping this directory lose work?":
#
#   C5 clean      `git status --porcelain` is empty — nothing uncommitted or
#                 untracked is sitting in the tree.
#   C6 upstream   `git cherry <target> HEAD` reports no `+` commits — every
#                 local commit's PATCH is already on the target.
#
# The remaining checks answer a different question — "is anyone still using
# it?" — and exist to protect in-flight work that happens to look finished:
#
#   C1 identity   the path has the per-bead shape and its basename resolves to
#                 an EXACTLY matching bead id.
#   C2 terminal   that bead is closed.
#   C3 unclaimed  no non-closed bead points `metadata.work_dir` at this path.
#   C4 cool       the bead closed at least $GASTOWN_REAP_MIN_AGE_MIN ago.
#
# ## C6 uses patch-id, never ancestry
#
# `git merge-base --is-ancestor HEAD <target>` is the wrong test and would keep
# the leak open. The refinery rebases before merging, so a landed branch's
# commits are on the target with DIFFERENT SHAs. Measured on this rig
# (2026-07-29), three landed, closed, clean trees:
#
#   gp-982  is_ancestor=YES  unmerged_patches=0
#   gp-px5  is_ancestor=NO   unmerged_patches=0
#   gp-nrm  is_ancestor=NO   unmerged_patches=0
#
# An ancestry-keyed reaper reaps the first and leaks the other two forever.
# `git cherry` compares patch-ids, so it sees all three as landed. (The same
# trap in the other direction is why gp-zs8 stopped inferring a queue bypass
# from ancestry.)
#
# ## Why agent liveness is never an input
#
# The obvious predicate — "this agent has no session, so its workspace is
# garbage" — is wrong twice over, both observed live (gp-a7z notes):
#
#   1. A rejected bead returns to the pool and is resumed by a DIFFERENT
#      polecat, while `metadata.work_dir` still points into the original
#      polecat's workspace. gp-px5 was in exactly that state — in_progress,
#      one unmerged commit, inside a workspace whose agent had no session at
#      all. A liveness-keyed reaper would have destroyed it. Here C2 and C6
#      both refuse it.
#   2. Polecat names are recycled from the namepool. gascity-packs/gastown
#      .furiosa went from "no session" to state=draining within ~15 minutes.
#      An absent name is not evidence its workspace is garbage.
#
# The converse — refusing to reap anything under a LIVE agent, which the
# original bug report suggested — is also rejected, for a quieter reason:
# `gc session list` reports a polecat's `work_dir` as its AGENT WORKSPACE
# (`polecats/<agent>`), the PARENT of every per-bead tree. Keying on it would
# refuse every tree belonging to any running polecat, which is most of them,
# and the leak would survive the fix. C4's grace window covers the only real
# race here — a session that has drain-acked but not yet been killed — using
# the bead's own `closed_at` rather than an inference about the agent.
#
# ## Scope: per-bead trees only
#
# Only paths shaped `<city>/.gc/worktrees/<rig>/polecats/<agent>/worktrees/
# <bead-id>` are candidates. The parent agent workspace (`polecats/<agent>`),
# the rig repo, the refinery workspace, and crew checkouts are never touched —
# they are long-lived, they hold no per-bead work, and an agent whose workspace
# vanished mid-session is a much worse outcome than a leaked directory.
#
# Candidates come from `git worktree list`, not a filesystem walk: the git
# registry is the authoritative record, `git worktree remove` can only act on
# what it lists, and a wide `find` under $HOME trips macOS TCC prompts.
#
# Output: one TSV row per candidate on stdout, verdict in column 1, header and
# summary on stderr.
#
#   reap          <TAB> <bead> <TAB> <path> <TAB> <evidence>
#   reaped        <TAB> <bead> <TAB> <path> <TAB> <what was removed>   (--reap)
#   reap-failed   <TAB> <bead> <TAB> <path> <TAB> <error>              (--reap)
#   keep-open     <TAB> <bead> <TAB> <path> <TAB> status=<status>
#   keep-claimed  <TAB> <bead> <TAB> <path> <TAB> claimed by <bead>
#   keep-cooling  <TAB> <bead> <TAB> <path> <TAB> closed <n>m ago
#   keep-dirty    <TAB> <bead> <TAB> <path> <TAB> <n> uncommitted paths
#   keep-unmerged <TAB> <bead> <TAB> <path> <TAB> <n> patches not on <target>
#   keep-locked   <TAB> <bead> <TAB> <path> <TAB> worktree is locked
#   keep-self     <TAB> <bead> <TAB> <path> <TAB> we are running inside it
#   unverifiable  <TAB> <bead> <TAB> <path> <TAB> <why it was NOT measured>
#
# `unverifiable` is never reaped. A tree whose bead cannot be read, whose id
# does not match, or whose target ref does not resolve has not been cleared —
# it has been ABSTAINED on. Reaping on an unreadable state is how a reaper
# eats real work; the leak is the cheaper failure.
#
# Exit codes:  0 = nothing to report (no candidates, or every one kept)
#              1 = findings on stdout (reapable, reaped, or unverifiable)
#              2 = the check could not run — nothing was measured, which is
#                  NOT the same as nothing to reap
#
# Env:
#   GC_CITY                      city root (auto-discovered by walking up)
#   GC_RIG                       rig to scan (required unless --rig is given)
#   GASTOWN_REAP_MIN_AGE_MIN     minutes since closed_at before a tree is
#                                eligible (default: 15). Covers the window
#                                between a polecat's drain-ack and the
#                                controller actually killing its session.
#   GASTOWN_REAP_TARGET          override the target ref for every candidate
#
# Usage:
#   polecat-worktree-reap.sh                     # report only (dry run)
#   polecat-worktree-reap.sh --reap              # remove what passed
#   polecat-worktree-reap.sh --rig gascity-packs --target origin/main

set -euo pipefail

ME=polecat-worktree-reap

DO_REAP=0
RIG="${GC_RIG:-}"
TARGET_OVERRIDE="${GASTOWN_REAP_TARGET:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --reap) DO_REAP=1; shift ;;
    --rig)
      [ $# -ge 2 ] || { echo "$ME: --rig needs a rig name" >&2; exit 2; }
      RIG="$2"; shift 2 ;;
    --rig=*) RIG="${1#--rig=}"; shift ;;
    --target)
      [ $# -ge 2 ] || { echo "$ME: --target needs a ref" >&2; exit 2; }
      TARGET_OVERRIDE="$2"; shift 2 ;;
    --target=*) TARGET_OVERRIDE="${1#--target=}"; shift ;;
    -h|--help)
      sed -n '2,126p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "$ME: unexpected argument '$1'" >&2; exit 2 ;;
  esac
done

MIN_AGE_MIN="${GASTOWN_REAP_MIN_AGE_MIN:-15}"
case "$MIN_AGE_MIN" in
  ''|*[!0-9]*)
    echo "$ME: GASTOWN_REAP_MIN_AGE_MIN must be a non-negative integer (got '$MIN_AGE_MIN')" >&2
    exit 2 ;;
esac
MIN_AGE_SECS=$((MIN_AGE_MIN * 60))

# Resolve city root: env wins, else walk up from cwd looking for city.toml.
if [ -z "${GC_CITY:-}" ]; then
  dir=$(pwd)
  while [ "$dir" != "/" ]; do
    if [ -f "$dir/city.toml" ]; then GC_CITY="$dir"; break; fi
    dir=$(dirname "$dir")
  done
fi
if [ -z "${GC_CITY:-}" ] || [ ! -f "$GC_CITY/city.toml" ]; then
  echo "$ME: GC_CITY not set and no city.toml found — nothing was measured" >&2
  exit 2
fi

# Resolve the city to its PHYSICAL path. `git worktree list` always reports
# resolved paths, so a city reached through a symlink (a symlinked $HOME, a
# city under /tmp on macOS where /tmp -> /private/tmp) makes the shape filter
# below match nothing at all. That failure is silent and reads exactly like a
# clean city: "no candidates", exit 0. Every path compared in this script is
# physical on both sides.
GC_CITY=$(cd "$GC_CITY" && pwd -P)

if [ -z "$RIG" ]; then
  echo "$ME: no rig to scan. Set GC_RIG or pass --rig <name>." >&2
  exit 2
fi

# The rig's main repo is where `git worktree list` and `git worktree remove`
# must run — remove refuses to operate from inside the tree it is deleting.
REPO=$(gc rig list --json 2>/dev/null \
  | jq -r --arg r "$RIG" '(.rigs // [])[] | select(.name == $r) | .path // empty' 2>/dev/null || true)
if [ -z "$REPO" ] || { [ ! -d "$REPO/.git" ] && [ ! -f "$REPO/.git" ]; }; then
  echo "$ME: could not resolve a git repo for rig '$RIG' (got '${REPO:-}') — nothing was measured" >&2
  exit 2
fi

RIG_WORKTREES="$GC_CITY/.gc/worktrees/$RIG"

# `date -u +%s` is epoch seconds — identical on every host regardless of $TZ.
# Every comparison below is between two such integers; no formatted local-time
# string is ever compared, which is the gp-9ly defect.
NOW=$(date -u +%s)

# ts_epoch — RFC3339 timestamp to epoch seconds, printing 0 for "no usable
# signal": empty, null, or the Go zero-time sentinel bd emits for an unset
# field. 0 means unknown, never "ancient". Shared idiom with
# polecat-progress-check.sh: GNU `-d` first, BSD `-j -f` second.
#
# The BSD arm strips the colon out of a `±HH:MM` offset as well as rewriting `Z`,
# because BSD `%z` accepts only the compact RFC822 spelling. `bd` stamps closed_at
# in Z form today, so this arm is not currently reached with an offset and the
# rewrite is a no-op here — it is carried anyway because gp-ra8 was exactly this
# line failing in witness-heartbeat-check.sh, where the input DOES arrive as
# `-07:00` from `gc session list`. The two producers already disagree on spelling,
# so leaving the identical helper unhardened here just parks the same silent
# 0-means-unknown misread behind a future field change.
ts_epoch() {
  local ts="$1" norm epoch
  case "$ts" in
    ''|null|0001-*) printf '0'; return 0 ;;
  esac
  norm=$(printf '%s' "$ts" | sed -E 's/\.[0-9]+(Z|[+-][0-9:]+)?$/\1/')
  epoch=$(date -u -d "$norm" +%s 2>/dev/null) \
    || epoch=$(date -u -j -f '%Y-%m-%dT%H:%M:%S%z' \
                 "$(printf '%s' "$norm" | sed -e 's/Z$/+0000/' \
                    -e 's/\([+-][0-9][0-9]\):\([0-9][0-9]\)$/\1\2/')" +%s 2>/dev/null) \
    || epoch=''
  case "$epoch" in
    ''|*[!0-9]*) printf '0'; return 0 ;;
  esac
  printf '%s' "$epoch"
}

row() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4"; }

# normalize_target — submit-and-exit records `metadata.target` as a bare branch
# name ("main"), but a patch-id comparison must run against the REMOTE tip; the
# local branch in a stale worktree lags by definition. Anything already
# qualified is passed through untouched so `integration/<convoy>` bases and
# explicit refs still work.
normalize_target() {
  case "$1" in
    '') printf '' ;;
    origin/*|refs/*) printf '%s' "$1" ;;
    *) printf 'origin/%s' "$1" ;;
  esac
}

# Candidate shape, as one place both the filter and the rm -rf fallback consult.
# The trailing component is a bead id; the `worktrees` segment is what separates
# a per-bead tree from the agent workspace that contains it.
is_per_bead_worktree() {
  case "$1" in
    "$RIG_WORKTREES"/polecats/*/worktrees/*/*) return 1 ;;
    "$RIG_WORKTREES"/polecats/*/worktrees/?*) return 0 ;;
    *) return 1 ;;
  esac
}

# --- Hoisted once: every work_dir claimed by a bead that is NOT closed. -------
# A path in this set belongs to live work even if the bead named by its basename
# is closed — the rejection-resume path re-points a returned bead at an existing
# tree (gp-px5). Streamed through files, never --argjson on argv: bead payloads
# on a busy rig overflow ARG_MAX.
CLAIMED_FILE=$(mktemp)
RAW_CLAIMED_FILE=$(mktemp)
LIST_FILE=$(mktemp)
CANDIDATES_FILE=$(mktemp)
LOCKED_FILE=$(mktemp)
trap 'rm -f "$CLAIMED_FILE" "$RAW_CLAIMED_FILE" "$LIST_FILE" "$CANDIDATES_FILE" "$LOCKED_FILE"' EXIT

# Every stored status that is not `closed`, taken from bd's own enum
# (open, in_progress, blocked, deferred, closed) rather than guessed. A
# non-closed status missing from this list is a bead whose claim on a tree this
# guard cannot see — the quiet fail-OPEN the whole script is built to avoid.
# `escalated` was named here once and is NOT a stored status: bd rejects it, the
# error went to /dev/null, and the iteration bought nothing while `deferred`
# was genuinely missing.
NONCLOSED_STATUSES=open,in_progress,blocked,deferred

: >"$RAW_CLAIMED_FILE"
if ! gc bd --rig "$RIG" list --status="$NONCLOSED_STATUSES" --json --limit=0 \
     >"$LIST_FILE" 2>/dev/null; then
  echo "$ME: could not list non-closed beads for rig '$RIG' — the claimed-tree" >&2
  echo "  guard cannot be evaluated, so nothing was measured" >&2
  exit 2
fi
# `// ""` rather than `// empty`: inside an array constructor, `empty` collapses
# the element away and shifts .id into column 1, which would silently compare a
# bead id against a path.
if ! jq -r 'if type == "array" then .[] else empty end
            | select((.status // "") != "closed")
            | select((.metadata.work_dir // "") != "")
            | [(.metadata.work_dir // ""), .id] | @tsv' \
       "$LIST_FILE" >>"$RAW_CLAIMED_FILE" 2>/dev/null; then
  echo "$ME: could not parse the non-closed bead listing — the claimed-tree" >&2
  echo "  guard cannot be evaluated, so nothing was measured" >&2
  exit 2
fi

# Store BOTH spellings of every claimed path. `metadata.work_dir` is recorded by
# the polecat's workspace-setup step from `$(pwd)`, which is the LOGICAL cwd, so
# it can name a symlinked path differently than the physical one `git worktree
# list` reports. A spelling mismatch here would make this guard fail OPEN — the
# quietest possible way to lose the gp-px5 protection — so the comparison is
# never allowed to depend on which spelling was recorded.
: >"$CLAIMED_FILE"
while IFS="$(printf '\t')" read -r claimed_dir claimed_id; do
  [ -n "${claimed_dir:-}" ] || continue
  printf '%s\t%s\n' "$claimed_dir" "$claimed_id" >>"$CLAIMED_FILE"
  if [ -d "$claimed_dir" ]; then
    claimed_phys=$( (cd "$claimed_dir" && pwd -P) 2>/dev/null || true)
    if [ -n "$claimed_phys" ] && [ "$claimed_phys" != "$claimed_dir" ]; then
      printf '%s\t%s\n' "$claimed_phys" "$claimed_id" >>"$CLAIMED_FILE"
    fi
  fi
done <"$RAW_CLAIMED_FILE"

claimed_by() {
  awk -F'\t' -v p="$1" '$1 == p { print $2; exit }' "$CLAIMED_FILE"
}

# --- Enumerate candidates from the git registry. ------------------------------
: >"$CANDIDATES_FILE"
: >"$LOCKED_FILE"

if ! WT_LIST=$(git -C "$REPO" worktree list --porcelain 2>/dev/null); then
  echo "$ME: 'git worktree list' failed in $REPO — nothing was measured" >&2
  exit 2
fi

current_wt=''
while IFS= read -r line; do
  case "$line" in
    'worktree '*)
      current_wt="${line#worktree }"
      if is_per_bead_worktree "$current_wt"; then
        printf '%s\n' "$current_wt" >>"$CANDIDATES_FILE"
      else
        current_wt=''
      fi
      ;;
    'locked'|'locked '*)
      [ -n "$current_wt" ] && printf '%s\n' "$current_wt" >>"$LOCKED_FILE"
      ;;
  esac
done <<EOF
$WT_LIST
EOF

TOTAL=$(wc -l <"$CANDIDATES_FILE" | tr -d ' ')
if [ "${TOTAL:-0}" -eq 0 ]; then
  echo "$ME: no per-bead polecat worktrees registered under $RIG_WORKTREES" >&2
  exit 0
fi

printf 'verdict\tbead\tpath\tdetail\n' >&2

n_reap=0 n_reaped=0 n_failed=0 n_kept=0 n_unverifiable=0

while IFS= read -r WT; do
  [ -n "$WT" ] || continue
  BEAD=$(basename "$WT")

  # C0: never pull the rug out from under the shell we are running in. Compared
  # physically for the same reason the city root is: a symlinked cwd would slip
  # past this guard and the reaper would delete the directory it is standing in.
  case "$(pwd -P)/" in
    "$WT"/*) row keep-self "$BEAD" "$WT" "we are running inside it"; n_kept=$((n_kept + 1)); continue ;;
  esac

  if grep -Fxq "$WT" "$LOCKED_FILE" 2>/dev/null; then
    row keep-locked "$BEAD" "$WT" "worktree is locked; an operator or a running job claimed it"
    n_kept=$((n_kept + 1)); continue
  fi

  # C1 identity. `gc bd show` FUZZY-MATCHES: `show a7z` returns gp-a7z
  # (verified live). A directory whose basename is a prefix of, or otherwise
  # near, some other bead id would be "verified" against a bead it has nothing
  # to do with — and then reaped on that bead's closed status. Requiring the
  # returned id to equal the basename exactly is what makes the rest of the
  # checks mean anything.
  BEAD_JSON=$(gc bd --rig "$RIG" show "$BEAD" --json 2>/dev/null || true)
  GOT_ID=$(printf '%s' "$BEAD_JSON" \
    | jq -r 'if type == "array" then (.[0].id // empty) else empty end' 2>/dev/null || true)
  if [ -z "$GOT_ID" ]; then
    row unverifiable "$BEAD" "$WT" "no bead read back for this path; NOT cleared"
    n_unverifiable=$((n_unverifiable + 1)); continue
  fi
  if [ "$GOT_ID" != "$BEAD" ]; then
    row unverifiable "$BEAD" "$WT" "basename resolved to a different bead ($GOT_ID) — fuzzy match, NOT cleared"
    n_unverifiable=$((n_unverifiable + 1)); continue
  fi

  STATUS=$(printf '%s' "$BEAD_JSON" | jq -r '.[0].status // empty' 2>/dev/null || true)
  CLOSED_AT=$(printf '%s' "$BEAD_JSON" | jq -r '.[0].closed_at // empty' 2>/dev/null || true)
  META_TARGET=$(printf '%s' "$BEAD_JSON" | jq -r '.[0].metadata.target // empty' 2>/dev/null || true)

  # C2 terminal. Anything not closed is in flight — including a rejected bead
  # back in the pool, whose branch a later polecat will resume from this tree.
  if [ "$STATUS" != "closed" ]; then
    row keep-open "$BEAD" "$WT" "status=${STATUS:-unknown}; work is still in flight"
    n_kept=$((n_kept + 1)); continue
  fi

  # C3 unclaimed by any other live bead.
  OWNER=$(claimed_by "$WT" || true)
  if [ -n "$OWNER" ] && [ "$OWNER" != "$BEAD" ]; then
    row keep-claimed "$BEAD" "$WT" "non-closed bead $OWNER points metadata.work_dir here"
    n_kept=$((n_kept + 1)); continue
  fi

  # C4 cool. Guards the one real race: a polecat that has drain-acked but whose
  # session the controller has not yet killed. An unparseable closed_at reads as
  # 0 = unknown, which must not read as "ancient" — abstain instead.
  CLOSED_EPOCH=$(ts_epoch "$CLOSED_AT")
  if [ "$CLOSED_EPOCH" -eq 0 ]; then
    row unverifiable "$BEAD" "$WT" "closed but closed_at is unreadable ('${CLOSED_AT:-}'); age NOT measured"
    n_unverifiable=$((n_unverifiable + 1)); continue
  fi
  AGE_SECS=$((NOW - CLOSED_EPOCH))
  if [ "$AGE_SECS" -lt "$MIN_AGE_SECS" ]; then
    row keep-cooling "$BEAD" "$WT" "closed $((AGE_SECS / 60))m ago; grace window is ${MIN_AGE_MIN}m"
    n_kept=$((n_kept + 1)); continue
  fi

  # A registered worktree whose directory is already gone has nothing to lose
  # and nothing to check — the registry entry is the only leak left.
  if [ ! -d "$WT" ]; then
    if [ "$DO_REAP" -eq 1 ]; then
      git -C "$REPO" worktree prune >/dev/null 2>&1 || true
      row reaped "$BEAD" "$WT" "directory already gone; pruned the stale registry entry"
      n_reaped=$((n_reaped + 1))
    else
      row reap "$BEAD" "$WT" "directory already gone; only a stale registry entry remains"
      n_reap=$((n_reap + 1))
    fi
    continue
  fi

  # C5 clean — load-bearing. Nothing uncommitted or untracked may be discarded.
  if ! DIRTY=$(git -C "$WT" status --porcelain 2>/dev/null); then
    row unverifiable "$BEAD" "$WT" "'git status' failed here; cleanliness NOT measured"
    n_unverifiable=$((n_unverifiable + 1)); continue
  fi
  if [ -n "$DIRTY" ]; then
    row keep-dirty "$BEAD" "$WT" "$(printf '%s\n' "$DIRTY" | wc -l | tr -d ' ') uncommitted or untracked paths"
    n_kept=$((n_kept + 1)); continue
  fi

  # C6 upstream — load-bearing, and patch-id rather than ancestry.
  TARGET=$(normalize_target "${TARGET_OVERRIDE:-$META_TARGET}")
  if [ -z "$TARGET" ]; then
    TARGET=$(git -C "$WT" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
    [ -n "$TARGET" ] || TARGET=origin/main
  fi
  if ! git -C "$WT" rev-parse --verify --quiet "$TARGET^{commit}" >/dev/null 2>&1; then
    row unverifiable "$BEAD" "$WT" "target ref '$TARGET' does not resolve; landing NOT measured"
    n_unverifiable=$((n_unverifiable + 1)); continue
  fi
  if ! CHERRY=$(git -C "$WT" cherry "$TARGET" HEAD 2>/dev/null); then
    row unverifiable "$BEAD" "$WT" "'git cherry $TARGET HEAD' failed; landing NOT measured"
    n_unverifiable=$((n_unverifiable + 1)); continue
  fi
  AHEAD=$(printf '%s' "$CHERRY" | grep -c '^+' || true)
  if [ "${AHEAD:-0}" -gt 0 ]; then
    row keep-unmerged "$BEAD" "$WT" "$AHEAD commit(s) whose patches are not on $TARGET"
    n_kept=$((n_kept + 1)); continue
  fi

  # Corroborating only, never a gate: the refinery deletes the branch after a
  # successful merge, so its absence is a second landed-signal. Requiring it
  # would reopen the leak for any bead whose branch deletion failed, and C6 is
  # strictly stronger evidence, so it is reported and not enforced.
  if git -C "$REPO" ls-remote --exit-code --heads origin "polecat/$BEAD" >/dev/null 2>&1; then
    ORIGIN_NOTE="origin/polecat/$BEAD still present"
  else
    ORIGIN_NOTE="origin branch deleted"
  fi
  EVIDENCE="closed $CLOSED_AT; clean; 0 patches ahead of $TARGET; $ORIGIN_NOTE"

  if [ "$DO_REAP" -eq 0 ]; then
    row reap "$BEAD" "$WT" "$EVIDENCE"
    n_reap=$((n_reap + 1))
    continue
  fi

  # Removal runs from $REPO, never from inside $WT — `git worktree remove`
  # refuses to delete the tree it is standing in.
  if git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1; then
    REMOVED="git worktree remove"
  elif is_per_bead_worktree "$WT" && [ -n "$WT" ] && rm -rf "$WT" 2>/dev/null; then
    # Fallback for a registry/directory mismatch git will not reconcile itself.
    # Re-asserting the shape here is deliberate: this is the only rm -rf in the
    # script and it must not be reachable with an unvalidated path.
    REMOVED="rm -rf (worktree remove refused)"
  else
    row reap-failed "$BEAD" "$WT" "could not remove; left in place"
    n_failed=$((n_failed + 1))
    continue
  fi

  git -C "$REPO" worktree prune >/dev/null 2>&1 || true
  # The branch is disposable by the same argument as the tree: its patches are
  # on the target. It is only still here because the tree held it checked out.
  # Non-fatal — a branch checked out elsewhere must stay.
  if git -C "$REPO" branch -D "polecat/$BEAD" >/dev/null 2>&1; then
    REMOVED="$REMOVED; deleted local branch polecat/$BEAD"
  fi
  row reaped "$BEAD" "$WT" "$REMOVED"
  n_reaped=$((n_reaped + 1))
done <"$CANDIDATES_FILE"

printf '%s: %s candidate(s) under %s — reapable=%s reaped=%s failed=%s kept=%s unverifiable=%s\n' \
  "$ME" "$TOTAL" "$RIG_WORKTREES" "$n_reap" "$n_reaped" "$n_failed" "$n_kept" "$n_unverifiable" >&2

if [ "$n_reap" -gt 0 ] || [ "$n_reaped" -gt 0 ] || [ "$n_failed" -gt 0 ] || [ "$n_unverifiable" -gt 0 ]; then
  exit 1
fi
exit 0
