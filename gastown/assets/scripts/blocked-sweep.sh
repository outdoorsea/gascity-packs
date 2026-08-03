#!/usr/bin/env bash
# blocked-sweep.sh — which blocked beads are still holding something?
# Read-only: it measures, prints, and exits. It never mails, nudges, reroutes,
# unblocks, or deletes a worktree — the witness's blocked-sweep patrol step owns
# those decisions, exactly as it owns them for worktree-reap and
# queue-starvation-check.
#
# ## The gap it closes (gp-6ph)
#
# All eight steps of mol-witness-patrol selected on open / in_progress / closed.
# NONE enumerated status=blocked, so a blocked bead was invisible to the whole
# patrol — including the steps whose stated purpose is finding work that fell out
# of the flow. Two live examples on gascity-packs, 2026-08-03, both found only by
# querying --status=blocked by hand, outside the formula:
#
#   * gp-yjx (P1) — blocked, unassigned, routed to human, and STILL HOLDING a 17M
#     worktree. `recover-orphaned-beads` skips unassigned beads and never lists
#     blocked, so it never saw it. `worktree-reap` DID see the tree and correctly
#     refused it: `keep-open ... status=blocked; work is still in flight`. Nothing
#     was in flight — there was no assignee and no session — but the reaper keys
#     on the bead's terminal state and blocked is not terminal, so it abstains.
#     Both components behaved correctly and the tree was still owned by nobody.
#   * gp-fcd (P2) — sat 5 days at gc.routed_to=<rig>/gastown.polecat while
#     status=blocked. Blocked beads are not claimable, so the routing generated
#     zero pool demand: no polecat spawned for it and none could claim it. The
#     routing was inert and silently wrong. The mayor caught it, not a patrol.
#
# This is the failure SHAPE of gp-982 on a different axis: a bead that looks
# healthy to every automated check and is therefore never surfaced. gp-982 was
# open+unassigned with no routing; this one is blocked with routing or a tree.
#
# ## Why report-only, and why that is not timidity
#
# Both shapes have a legitimate cause that a mutation would destroy:
#
#   * blocked + gc.routed_to=human is frequently a DELIBERATE park (the
#     2026-08-03 mayor standing rule on gastownhall/gascity deliverables).
#     Auto-rerouting it resumes work an operator explicitly stopped — strictly
#     worse than the gap being fixed, because it overrides a stated intent rather
#     than a forgotten one. That is the lesson check-unroutable-beads records
#     about its own auto_push_false exclusion.
#   * a blocked bead's worktree may hold the only copy of unpushed work. Deciding
#     whether a tree is safe to remove is worktree-reap's job, and its safety
#     argument (`git status --porcelain` empty AND `git cherry` reporting no `+`
#     commits) is explicitly documented as one not to hand-roll. This check does
#     not re-derive it and does not touch the directory. Visibility is the whole
#     deliverable: the tree was invisible, not un-reapable.
#
# ## Why no staleness window
#
# Deliberately no age threshold, unlike queue-starvation-check. Both findings are
# wrong from the moment they are written, not after N days: a blocked bead's pool
# routing generates zero demand on day 0, and a tree owned by no step is orphaned
# on day 0. gp-fcd's five days measure how long the GAP hid it, not how long it
# had to sit before becoming a defect. Adding a window would only delay the
# report, and it would drag in the RFC3339/BSD-date normalization that silently
# broke the witness heartbeat check on macOS (gp-ra8) for a column nothing
# branches on.
#
# Output: one TSV row per blocked bead on stdout, column header on stderr.
#
#   verdict <TAB> id <TAB> priority <TAB> worktree <TAB> routed_to <TAB> title
#
#   parked              blocked and holding nothing. Healthy — the deliberate
#                       park. Never a finding.
#   holding-worktree    metadata.work_dir names a directory that EXISTS. FINDING.
#   inert-routing       gc.routed_to points at a pool, which cannot claim a
#                       blocked bead. FINDING.
#   stale-worktree-ref  metadata.work_dir is set but the directory is gone.
#                       Reported, not a finding — the tree is already collected
#                       and a dangling pointer harms nothing.
#
# One row per bead. When a bead trips both finding axes the verdict names the
# worktree — disk is the scarcer resource and the tree outlives the routing — but
# the routed_to column still carries the pool and the stderr summary counts BOTH
# axes independently, so neither is lost behind the other.
#
# Exit codes:  0 = no findings (every blocked bead parked, or none at all)
#              1 = findings on stdout (holding-worktree / inert-routing)
#              2 = the check could not run — nothing was measured, which is NOT
#                  health
#
# Env:
#   GC_CITY                     city root (auto-discovered if unset)
#   GASTOWN_BLOCKED_PARK_ROUTES comma-separated gc.routed_to values that mean
#                               "deliberately parked, not a pool" (default: human)

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
  echo "blocked-sweep: GC_CITY not set and no city.toml found" >&2
  exit 2
fi

# Routes that mean "a human is holding this on purpose". Everything else
# non-empty is a pool address — `<rig>/gastown.polecat`, `gastown.dog`, a
# refinery — and a pool cannot claim a blocked bead, so the routing is inert.
# Configurable because a city may grow another park sentinel; the default is the
# only one Gas Town writes today.
PARK_ROUTES="${GASTOWN_BLOCKED_PARK_ROUTES:-human}"

if ! BLOCKED=$(gc bd list --status=blocked --json --limit=0 2>/dev/null </dev/null); then
  echo "blocked-sweep: 'gc bd list --status=blocked' failed — blocked beads NOT measured" >&2
  exit 2
fi

# The {"ok":false} envelope check is not redundant with the `if !` above. `gc`
# reports an unknown command or a rejected flag by printing that envelope to
# STDOUT, and a status-only guard misses it the moment anyone reintroduces a
# pipe — the exact shape that kept the deacon's starvation step from ever firing
# (gp-b3x). Read the payload, not just the exit code.
if printf '%s' "$BLOCKED" | jq -e '(type == "object") and (.ok == false)' >/dev/null 2>&1; then
  BLOCKED_ERR=$(printf '%s' "$BLOCKED" | jq -r '.error.message // "unknown error"' 2>/dev/null)
  echo "blocked-sweep: the blocked-bead query failed (${BLOCKED_ERR}) — blocked beads NOT measured" >&2
  exit 2
fi

if ! printf '%s' "$BLOCKED" | jq -e 'type == "array"' >/dev/null 2>&1; then
  echo "blocked-sweep: the blocked-bead query returned no array — blocked beads NOT measured" >&2
  exit 2
fi

# Re-assert the filter the whole check is premised on. Nothing in Gas Town had
# ever queried --status=blocked before gp-6ph, so this is the one status whose
# server-side filter has no operational history behind it. If it were ignored,
# every open bead in the ledger would arrive here and get classified — turning a
# targeted sweep into a flood of false findings that reads like a catastrophe.
# A detector inventing a query must verify the query did what it asked.
if ! OFFSPEC=$(printf '%s' "$BLOCKED" | jq -r '[ .[] | select(((.status // "") | tostring) != "blocked") ] | length' 2>/dev/null); then
  echo "blocked-sweep: could not verify the status filter — blocked beads NOT measured" >&2
  exit 2
fi
if [ "$OFFSPEC" != "0" ]; then
  echo "blocked-sweep: 'gc bd list --status=blocked' returned $OFFSPEC non-blocked bead(s) — the status filter is not being applied; blocked beads NOT measured" >&2
  exit 2
fi

# id, priority, work_dir, routed_to, title. Title goes LAST so a tab inside it
# lands in the final read field instead of shifting every column after it.
#
# Absent values become "-", never "". A TSV field must not be empty here: TAB is
# IFS *whitespace*, so `IFS=$'\t' read` collapses a run of tabs into ONE
# delimiter and an empty column silently shifts every column after it left. Left
# unguarded, gp-fcd — blocked with no work_dir — parsed as routed_to="human"
# landing in the worktree column and its TITLE landing in routed_to, which reads
# as a perfectly well-formed row asserting something false. That is the same
# looks-healthy-so-nobody-looks failure this whole check exists to end, so the
# placeholders are load-bearing and the shell strips them back to empty below.
#
# Every field takes a `//` default rather than `has()`. `gc bd list --json` OMITS
# empty fields — gp-yjx exposes no `assignee` key at all rather than a null one —
# so a missing key proves nothing about whether the field exists.
if ! ROWS=$(printf '%s' "$BLOCKED" | jq -r '
  def dash: if ((. // "") | tostring) == "" then "-" else (. | tostring) end;
  .[]
  | [ (.id // "?"),
      (.priority | dash),
      (.metadata["work_dir"] | dash),
      (.metadata["gc.routed_to"] | dash),
      ((.title // "") | tostring | gsub("[\t\n]"; " ") | dash)
    ]
  | @tsv
' 2>/dev/null); then
  echo "blocked-sweep: could not parse the blocked-bead payload — blocked beads NOT measured" >&2
  exit 2
fi

printf 'verdict\tid\tpriority\tworktree\trouted_to\ttitle\n' >&2

TOTAL=0
HOLDING=0
INERT=0
STALE_REF=0
PARKED=0

# Fed by a here-doc, so nothing inside this loop may read stdin: a child that
# consumes it eats the rows the loop has not reached yet, which cost
# queue-starvation-check one silently-skipped session per iteration. Every test
# below is a local filesystem or string check — no subprocess reads stdin here.
while IFS=$'\t' read -r id priority work_dir routed_to title; do
  [ -n "${id:-}" ] || continue
  TOTAL=$((TOTAL + 1))

  # Undo the "-" placeholders the jq above emitted to keep the columns aligned.
  # A real work_dir is an absolute path and a real route is an address, so
  # neither can legitimately be a bare dash.
  [ "$work_dir" = "-" ] && work_dir=""
  [ "$routed_to" = "-" ] && routed_to=""

  # A pool route is any non-empty route that is not a park sentinel. Compared
  # case-insensitively so `Human` cannot slip through as a pool address and get
  # reported as a defect against an operator who parked it correctly.
  route_is_pool=0
  if [ -n "$routed_to" ]; then
    route_is_pool=1
    lc_route=$(printf '%s' "$routed_to" | tr '[:upper:]' '[:lower:]')
    old_ifs=$IFS
    IFS=','
    for park in $PARK_ROUTES; do
      lc_park=$(printf '%s' "$park" | tr '[:upper:]' '[:lower:]')
      if [ -n "$lc_park" ] && [ "$lc_route" = "$lc_park" ]; then
        route_is_pool=0
        break
      fi
    done
    IFS=$old_ifs
  fi

  # Existence separates a leaked tree from a dangling pointer. It is the only
  # thing this check asks about the directory: whether the tree is SAFE to remove
  # is worktree-reap's predicate, and re-deriving it here is what that step's
  # "do not hand-roll this predicate" warning is about.
  tree_state=none
  if [ -n "$work_dir" ]; then
    if [ -d "$work_dir" ]; then
      tree_state=present
    else
      tree_state=absent
    fi
  fi

  [ "$route_is_pool" -eq 1 ] && INERT=$((INERT + 1))
  [ "$tree_state" = present ] && HOLDING=$((HOLDING + 1))

  # Verdict precedence: a live tree outranks inert routing. Both counts above are
  # already incremented independently, so naming one verdict never hides the
  # other axis from the summary.
  if [ "$tree_state" = present ]; then
    verdict=holding-worktree
  elif [ "$route_is_pool" -eq 1 ]; then
    verdict=inert-routing
  elif [ "$tree_state" = absent ]; then
    verdict=stale-worktree-ref
    STALE_REF=$((STALE_REF + 1))
  else
    verdict=parked
    PARKED=$((PARKED + 1))
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$verdict" "$id" "$priority" "${work_dir:--}" "${routed_to:--}" "$title"
done <<EOF
$ROWS
EOF

if [ "$TOTAL" -eq 0 ]; then
  echo "blocked-sweep: no blocked beads — nothing to sweep" >&2
  exit 0
fi

echo "blocked-sweep: $TOTAL blocked bead(s) — $HOLDING holding a worktree, $INERT with inert pool routing, $STALE_REF stale worktree ref(s), $PARKED parked" >&2

[ "$((HOLDING + INERT))" -eq 0 ] || exit 1
exit 0
