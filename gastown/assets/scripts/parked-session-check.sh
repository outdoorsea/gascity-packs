#!/usr/bin/env bash
# parked-session-check.sh — deterministic detection of sessions parked at a
# provider usage-limit prompt. Read-only: it measures, prints, and exits. It
# never resets, kills, nudges, mails, or files warrants — `check-parked-sessions`
# in mol-witness-patrol owns those decisions.
#
# THE THIRD STATE
#
# Gas Town models two session states and has a detector for each:
#
#   alive-and-working   controller sees the process; witness sees progress
#   dead-or-orphaned    controller restarts it; witness recovers the bead
#
# A session parked at an interactive usage-limit prompt is NEITHER, and every
# existing detector reads it as healthy (gp-px5, measured 2026-07-29):
#
#   * `gc session list` reports `active`, so the controller will not restart it.
#   * Witness liveness resolves the assignee to `active`, so orphan recovery
#     correctly refuses it — it is not an orphan.
#   * It is not "stuck" in the mol-witness-patrol sense: no infinite loop, no
#     long tool call. It is not executing at all.
#   * The shutdown dance cannot help. A parked session cannot answer an
#     interrogation, and killing an agent over a perceived budget problem is
#     the wrong tool.
#   * `gc runtime drain` is COOPERATIVE — it sets GC_DRAIN and waits for the
#     agent to poll `gc runtime drain-check`. A parked session never polls, so
#     drain is a no-op against exactly the case you most want to drain.
#
# The measured incident: tallyup/gastown.slit (gk-4sb4) held a P1 bead for 17h
# doing nothing, its pane showing a weekly-limit banner with no "esc to
# interrupt". It was NOT out of quota — the banner was stale session state. A
# `gc session reset` restored it in under 60 seconds and it resumed work. The
# cost was purely 17h of a P1 fix not being worked.
#
# It also acts as a BEAD SINK. Releasing the bead does not help while the
# session lives: measured, a bead set to open/unassigned at 19:26:41Z was back
# in_progress under the parked session by 19:29:30Z, with no operator action in
# between. A parked pool member silently absorbs pool demand and holds it, and
# polecat instance names are not addressable (`gc sling <rig>/gastown.rictus`
# fails — the pool target is the only address), so one parked member can swallow
# a whole rig's dispatch. Detection is therefore the only lever: the session has
# to be reset, not routed around.
#
# WHY THE OBVIOUS SIGNALS DO NOT WORK
#
# `last_active` from `gc session list --json` is NOT an activity signal. It
# tracks pane redraws, so a parked session reports a last_active of ~now
# forever — that is precisely why "reports active" fooled every detector above.
# It is also a LOCAL time with an explicit offset (e.g.
# "2026-07-29T13:21:48-07:00"), so anything that parsed it would have to honor
# that offset. Do not reintroduce it as a freshness input; it cannot distinguish
# this state from health.
#
# The activity signal used here is pane STABILITY across two peeks separated by
# a settle gap. A parked pane is static text above an input box: it does not
# change. That is an observation of the session, not an inference about it —
# the same reason `check-polecat-health` confirms staleness with a live peek
# rather than trusting a timestamp.
#
# WHY THE BANNER SEARCH IS CONFINED TO THE PANE TAIL
#
# The banner patterns are ordinary English that an agent may legitimately have
# on screen. An agent working on the usage-limit bug itself quotes the banner
# verbatim in its own pane — this script's own author did. Searching all of
# scrollback would flag that agent as parked and reset a healthy session.
#
# A real parked banner is the LAST thing rendered, immediately above the prompt.
# Quoted text scrolls away as work continues. So the banner must appear within
# the trailing GASTOWN_PARKED_TAIL_LINES lines, not anywhere in the capture.
# Widening that window trades away the only defense against this false positive.
#
# COST, AND WHY THE PEEKS ARE PARALLEL
#
# Measured on this fleet: one `gc session peek` costs ~5s and `gc session list
# --json` ~7s. Scanned serially, a 20-session city needs ~100s PER PASS, and
# this check makes two passes — over three minutes, every patrol cycle. That is
# not a check a patrol can afford to run.
#
# Two things bound it. Peeks run in bounded parallel batches, so a pass costs
# roughly one BATCH rather than N. And the scan is rig-scoped by default: the
# witness is a per-rig agent, and town-level sessions (mayor, deacon, dogs) are
# the deacon's concern, not a rig witness's.
#
# End-to-end, measured on this fleet at MAX_JOBS=8, with no candidate to
# re-peek: 17s for a 5-session rig (one batch), 57s for a 20-session city
# (three batches). So a batch costs noticeably more than the ~5s of a single
# peek — concurrent peeks contend — but the growth is per-batch, not per
# session. The rig-scoped default is what keeps this inside a patrol cycle;
# the settle gap is paid on top, once, and only when some pane is showing a
# banner.
#
# Env:
#   GC_CITY                       city root (auto-discovered if unset, walks up)
#   GC_RIG                        limit the scan to this rig (unset: every rig)
#   GASTOWN_PARKED_PEEK_LINES     lines to request per peek (default: 40)
#   GASTOWN_PARKED_TAIL_LINES     trailing lines searched for the banner (default: 12)
#   GASTOWN_PARKED_SETTLE_SECS    gap between the two peeks (default: 45)
#   GASTOWN_PARKED_MAX_JOBS       concurrent peeks per batch (default: 8)
#   GASTOWN_PARKED_PATTERNS       case-insensitive ERE for limit banners (override)
#   GASTOWN_PARKED_BUSY_PATTERNS  case-insensitive ERE for mid-turn markers (override)
#
# Output: one TSV row per inspected session on stdout, column header on stderr.
#
#   verdict <TAB> session <TAB> session_name <TAB> alias <TAB> rig <TAB> detail
#
#   parked      limit banner in the pane tail, no mid-turn marker, pane
#               unchanged across the settle gap. THE finding this check exists
#               for. Remedy is `gc session reset`, not a warrant.
#   settling    banner present but the pane is still advancing — possibly
#               auto-retrying. Not actionable; resetting would interrupt a
#               recovery already under way.
#   busy        a mid-turn marker is present. The session is executing.
#   clear       no limit banner in the pane tail.
#   unpeekable  the peek failed — this session's state was NOT measured.
#
# Exit codes:  0 = no parked and no unmeasured session (or none to check)
#              1 = findings on stdout (parked and/or unpeekable)
#              2 = the check could not run (bad config, unreadable session list)
#
# Usage:
#   parked-session-check.sh                 # every active session in GC_RIG
#   parked-session-check.sh gk-4sb4 gk-9nj  # only these sessions or aliases
#   GASTOWN_PARKED_SETTLE_SECS=90 parked-session-check.sh

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
  echo "parked-session-check: GC_CITY not set and no city.toml found" >&2
  exit 2
fi

PEEK_LINES="${GASTOWN_PARKED_PEEK_LINES:-40}"
TAIL_LINES="${GASTOWN_PARKED_TAIL_LINES:-12}"
SETTLE_SECS="${GASTOWN_PARKED_SETTLE_SECS:-45}"
MAX_JOBS="${GASTOWN_PARKED_MAX_JOBS:-8}"
RIG="${GC_RIG:-}"

require_positive_int() {
  local name="$1" value="$2"
  case "$value" in
    ''|*[!0-9]*)
      echo "parked-session-check: $name must be a positive integer (got '$value')" >&2
      exit 2
      ;;
  esac
  if [ "$value" -le 0 ]; then
    echo "parked-session-check: $name must be a positive integer (got '$value')" >&2
    exit 2
  fi
}

require_positive_int GASTOWN_PARKED_PEEK_LINES "$PEEK_LINES"
require_positive_int GASTOWN_PARKED_TAIL_LINES "$TAIL_LINES"
require_positive_int GASTOWN_PARKED_MAX_JOBS "$MAX_JOBS"

# 0 is legal for the settle gap alone: the test suite and an operator triaging a
# known incident both want the two peeks back to back without a 45s wait.
case "$SETTLE_SECS" in
  ''|*[!0-9]*)
    echo "parked-session-check: GASTOWN_PARKED_SETTLE_SECS must be a non-negative integer (got '$SETTLE_SECS')" >&2
    exit 2
    ;;
esac

if [ "$TAIL_LINES" -gt "$PEEK_LINES" ]; then
  echo "parked-session-check: GASTOWN_PARKED_TAIL_LINES ($TAIL_LINES) exceeds GASTOWN_PARKED_PEEK_LINES ($PEEK_LINES) — the tail window cannot be larger than the capture" >&2
  exit 2
fi

# Limit-banner patterns. Provider UI copy is the fragile input here: these are
# strings owned by the coding-agent CLI, not by Gas Town, so they can change
# without notice. GASTOWN_PARKED_PATTERNS exists so a rig can correct the list
# without waiting on a pack release.
#
# Provenance:
#   "hit your weekly limit"     verbatim from the gp-px5 incident pane
#   "/usage-credits"            verbatim second line of that banner
#   "usage limit reached"       limit banner emitted on the 5-hour window
#   "hit your usage limit"      wording variant of the same banner
#   "reached your usage limit"  wording variant of the same banner
#   "limit - resets"            the "resets <date> at <time>" tail of the banner
#
# Matching is case-insensitive (grep -iE). Keep every alternative anchored to
# distinctive banner wording — a pattern as loose as "limit" would match any
# agent discussing rate limits and reset healthy sessions.
DEFAULT_PATTERNS='hit your weekly limit|/usage-credits|usage limit reached|hit your usage limit|reached your usage limit|limit - resets'
PATTERNS="${GASTOWN_PARKED_PATTERNS:-$DEFAULT_PATTERNS}"

# Mid-turn markers. Their presence VETOES a parked verdict: a session rendering
# an interrupt affordance is executing, whatever else is on screen.
#
# "esc to inter" is deliberately a truncated prefix of "esc to interrupt".
# `gc session peek` returns width-truncated lines — an observed capture ended
# "· ← for age…" — so a narrow pane can clip the marker mid-word. Matching the
# prefix keeps the veto working at widths where the full phrase is cut off.
# Erring toward "busy" is the safe direction: a missed detection costs one more
# patrol cycle, a false positive resets a working session and discards its
# in-flight reasoning.
DEFAULT_BUSY_PATTERNS='esc to inter'
BUSY_PATTERNS="${GASTOWN_PARKED_BUSY_PATTERNS:-$DEFAULT_BUSY_PATTERNS}"

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

if ! SESSIONS_JSON=$(gc session list --json 2>/dev/null); then
  echo "parked-session-check: 'gc session list --json' failed — no session was inspected" >&2
  exit 2
fi

# Tolerate both a bare top-level array and the documented {"sessions": [...]}
# wrapper, the way the sibling witness and polecat checks do — this schema has
# drifted before.
JQ_SESSIONS='def sessions_of: (.sessions? // .) | if type == "array" then . else [] end;'

if ! TOTAL=$(printf '%s' "$SESSIONS_JSON" | jq -r "$JQ_SESSIONS sessions_of | length" 2>/dev/null); then
  echo "parked-session-check: could not parse the session list — no session was inspected" >&2
  exit 2
fi

# Only `active` sessions can be parked at a prompt. An asleep or suspended
# session has no live pane to peek, and peeking it would fail per-session and
# add noise for a state that is already correctly modelled elsewhere.
#
# Explicit ids or aliases may be passed to scan a single suspect. They are still
# filtered to active — so a typo, or an id that has since been suspended, reports
# as "nothing to check" rather than silently scanning nothing — but they BYPASS
# the rig filter, so an operator can name a session in any rig.
if [ "$#" -gt 0 ]; then
  WANTED=$(printf '%s\n' "$@" | jq -R . | jq -s .)
  ROWS=$(printf '%s' "$SESSIONS_JSON" | jq -r --argjson wanted "$WANTED" "
    $JQ_SESSIONS
    sessions_of
    | .[]
    | select((.state // \"\") == \"active\")
    | select((.id // \"\") as \$id | (.alias // \"\") as \$alias
             | (\$wanted | index(\$id) != null or index(\$alias) != null))
    | [ (.id // \"?\"), (.session_name // \"-\"), (.alias // \"-\"), (.rig // \"-\") ]
    | @tsv
  " 2>/dev/null) || ROWS=''
else
  ROWS=$(printf '%s' "$SESSIONS_JSON" | jq -r --arg rig "$RIG" "
    $JQ_SESSIONS
    sessions_of
    | .[]
    | select((.state // \"\") == \"active\")
    | select(\$rig == \"\" or (.rig // \"\") == \$rig)
    | [ (.id // \"?\"), (.session_name // \"-\"), (.alias // \"-\"), (.rig // \"-\") ]
    | @tsv
  " 2>/dev/null) || ROWS=''
fi

# sanitize — collapse a pane excerpt into one TSV-safe field. Tabs would forge
# column boundaries and newlines would forge rows, so both are squeezed to
# spaces before the value is printed.
sanitize() {
  printf '%s' "$1" | tr '\t\n\r' '   ' | tr -s ' ' | cut -c1-120
}

# fs_key <session-id> — a filesystem-safe token for naming this session's
# capture files. Every non-alphanumeric byte collapses to `_`, so an id can
# never escape $WORKDIR.
fs_key() {
  printf '%s' "$1" | tr -c '[:alnum:]' '_'
}

# peek_tail <session-id> — the trailing window of a session's pane on stdout;
# non-zero if the peek failed. Whitespace-only trailing lines are dropped first:
# the input box and status bar render as blank padding, so a fixed `tail` would
# otherwise spend the window on whitespace and miss a banner just above it.
peek_tail() {
  local id="$1" out
  out=$(gc session peek "$id" --lines "$PEEK_LINES" 2>/dev/null) || return 1
  printf '%s\n' "$out" \
    | awk '
        { line[n++] = $0 }
        END {
          last = -1
          for (i = n - 1; i >= 0; i--) {
            if (line[i] ~ /[^[:space:]]/) { last = i; break }
          }
          for (i = 0; i <= last; i++) print line[i]
        }' \
    | tail -n "$TAIL_LINES"
}

# capture_pass <pass-label> <id>... — peek every named session concurrently,
# leaving "<pass>.<key>" on success and "<pass>.<key>.failed" on failure.
#
# Batched rather than a rolling window: `wait -n` is bash 4.3+, and the floor
# here is bash 3.2 (the macOS system shell). Waiting for a whole batch costs the
# slowest peek in it, which is still N/MAX_JOBS peeks instead of N.
capture_pass() {
  local pass="$1"
  shift
  local running=0 id key
  for id in "$@"; do
    key=$(fs_key "$id")
    (
      if peek_tail "$id" >"$WORKDIR/$pass.$key.part" 2>/dev/null; then
        mv "$WORKDIR/$pass.$key.part" "$WORKDIR/$pass.$key"
      else
        rm -f "$WORKDIR/$pass.$key.part"
        : >"$WORKDIR/$pass.$key.failed"
      fi
    ) &
    running=$((running + 1))
    if [ "$running" -ge "$MAX_JOBS" ]; then
      wait
      running=0
    fi
  done
  wait
}

printf 'verdict\tsession\tsession_name\talias\trig\tdetail\n' >&2

# Collect the session list into parallel index arrays. bash 3.2 has no
# associative arrays, so the four fields travel as same-index entries.
IDS=()
NAMES=()
ALIASES=()
RIGS=()
while IFS=$'\t' read -r id session_name alias rig; do
  [ -n "${id:-}" ] || continue
  IDS+=("$id")
  NAMES+=("$session_name")
  ALIASES+=("$alias")
  RIGS+=("$rig")
done <<EOF
$ROWS
EOF

CHECKED=${#IDS[@]}

if [ "$CHECKED" -eq 0 ]; then
  if [ -n "$RIG" ]; then
    echo "parked-session-check: no active session in rig '$RIG' among $TOTAL session(s) — nothing to check" >&2
  else
    echo "parked-session-check: no active session to check among $TOTAL session(s)" >&2
  fi
  exit 0
fi

PARKED=0
FINDINGS=0

# --- Pass 1: classify, and shortlist the candidates that need a stability peek.
capture_pass p1 ${IDS[@]+"${IDS[@]}"}

CAND_IDX=()
i=0
while [ "$i" -lt "$CHECKED" ]; do
  id="${IDS[$i]}"
  key=$(fs_key "$id")
  if [ ! -f "$WORKDIR/p1.$key" ]; then
    # A peek that fails proves nothing about the session — report it as
    # unmeasured rather than letting silence read as health.
    FINDINGS=$((FINDINGS + 1))
    printf 'unpeekable\t%s\t%s\t%s\t%s\t%s\n' \
      "$id" "${NAMES[$i]}" "${ALIASES[$i]}" "${RIGS[$i]}" 'gc session peek failed — state NOT measured'
    i=$((i + 1))
    continue
  fi

  if grep -qiE "$BUSY_PATTERNS" "$WORKDIR/p1.$key"; then
    printf 'busy\t%s\t%s\t%s\t%s\t%s\n' \
      "$id" "${NAMES[$i]}" "${ALIASES[$i]}" "${RIGS[$i]}" 'mid-turn marker present'
    i=$((i + 1))
    continue
  fi

  banner=$(grep -iE "$PATTERNS" "$WORKDIR/p1.$key" | sed -n '1p') || banner=''
  if [ -z "$banner" ]; then
    printf 'clear\t%s\t%s\t%s\t%s\t%s\n' \
      "$id" "${NAMES[$i]}" "${ALIASES[$i]}" "${RIGS[$i]}" 'no limit banner in pane tail'
    i=$((i + 1))
    continue
  fi

  # Defer the verdict: a banner with no mid-turn marker is a candidate, not a
  # finding, until the stability re-peek confirms the pane is not advancing.
  printf '%s' "$(sanitize "$banner")" >"$WORKDIR/banner.$key"
  CAND_IDX+=("$i")
  i=$((i + 1))
done

# --- Pass 2: re-peek only the candidates, after one shared settle gap.
if [ "${#CAND_IDX[@]}" -gt 0 ]; then
  # The gap is paid ONCE for the whole fleet, not once per candidate: a
  # per-candidate sleep would multiply the patrol's cost by the number of
  # sessions that happen to be showing a banner.
  if [ "$SETTLE_SECS" -gt 0 ]; then
    sleep "$SETTLE_SECS"
  fi

  CAND_IDS=()
  for i in ${CAND_IDX[@]+"${CAND_IDX[@]}"}; do
    CAND_IDS+=("${IDS[$i]}")
  done
  capture_pass p2 ${CAND_IDS[@]+"${CAND_IDS[@]}"}

  for i in ${CAND_IDX[@]+"${CAND_IDX[@]}"}; do
    id="${IDS[$i]}"
    key=$(fs_key "$id")
    banner=$(cat "$WORKDIR/banner.$key" 2>/dev/null || printf '%s' 'limit banner')

    if [ ! -f "$WORKDIR/p2.$key" ]; then
      FINDINGS=$((FINDINGS + 1))
      printf 'unpeekable\t%s\t%s\t%s\t%s\t%s\n' \
        "$id" "${NAMES[$i]}" "${ALIASES[$i]}" "${RIGS[$i]}" 're-peek failed — stability NOT measured'
      continue
    fi

    # A mid-turn marker appearing on the re-peek means the session woke up and
    # is executing. Re-checking the veto here (not just in pass 1) is what keeps
    # a session that resumed during the settle gap from being reset.
    if grep -qiE "$BUSY_PATTERNS" "$WORKDIR/p2.$key"; then
      printf 'busy\t%s\t%s\t%s\t%s\t%s\n' \
        "$id" "${NAMES[$i]}" "${ALIASES[$i]}" "${RIGS[$i]}" 'mid-turn marker appeared during settle gap'
      continue
    fi

    if ! cmp -s "$WORKDIR/p1.$key" "$WORKDIR/p2.$key"; then
      # Still moving. Could be an auto-retry, a re-render, or a human at the
      # keyboard. Not actionable: resetting here would interrupt a recovery
      # already in progress.
      printf 'settling\t%s\t%s\t%s\t%s\t%s\n' \
        "$id" "${NAMES[$i]}" "${ALIASES[$i]}" "${RIGS[$i]}" \
        "pane changed across ${SETTLE_SECS}s — banner present but advancing"
      continue
    fi

    PARKED=$((PARKED + 1))
    FINDINGS=$((FINDINGS + 1))
    printf 'parked\t%s\t%s\t%s\t%s\t%s\n' \
      "$id" "${NAMES[$i]}" "${ALIASES[$i]}" "${RIGS[$i]}" "$banner"
  done
fi

echo "parked-session-check: checked $CHECKED active session(s)${RIG:+ in rig '$RIG'}, $PARKED parked (settle ${SETTLE_SECS}s, tail ${TAIL_LINES} lines, ${MAX_JOBS} concurrent peeks)" >&2

[ "$FINDINGS" -eq 0 ] || exit 1
