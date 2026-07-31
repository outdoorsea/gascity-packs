#!/usr/bin/env bash
# queue-starvation-check.sh — is any session holding work it is not moving?
# Read-only: it measures, prints, and exits. It never mails, nudges, or files
# warrants — the deacon's queue-starvation-check patrol step owns those
# decisions, exactly as it owns them for witness-heartbeat-check.sh.
#
# The gap it closes: a session can look healthy-idle in a patrol wisp view while
# its queue silently starves. The refinery (upstream #1833) self-polled for
# 13h42m with seven beads assigned to it, because its poll filter resolved to an
# identity that did not match its own. Session state said `active`, the wisp
# looked fresh, and nothing was moving.
#
# For every session in a state that implies it should be working, it computes:
#   A = open+in_progress beads assigned to that session (either identity form)
#   B = the newest updated_at across those beads — the work signal
# and reports A>0 with a stale B as `starved`.
#
# ## Why this script exists rather than inline shell in the formula (gp-b3x)
#
# The step used to carry this as a shell snippet in mol-deacon-patrol.toml, and
# it could not fire. Every one of its failure paths degraded to zero rows, and
# zero rows read as a clean queue:
#
#   1. It called `gc agents list --json --active`, which does not exist (`gc
#      agent` is config; the roster is `gc session list`). That prints an
#      {"ok":false} envelope to STDOUT and exits 1 — but it sat at the head of a
#      pipeline, so the shell reported the `while` loop's status instead, jq got
#      an object where it expected an array, and the loop body never ran once.
#   2. It queried `--status=open` only, which cannot see a CLAIMED bead. A
#      session actively holding in_progress work — the commonest starvation
#      shape — scored A=0.
#   3. It probed ONE identity form. `--assignee` is an exact match and Gas Town
#      writes two spellings: a polecat self-claim lands the session NAME
#      (`gastown__polecat-gk-s4j0`), a refinery handoff lands the agent ADDRESS
#      (`meety-local/gastown.refinery`). Probing either alone misses the other
#      class of work entirely.
#
# The through-line is that a detector whose failure mode is silence has the same
# defect class as the incident it exists to catch. So every path here that could
# not measure exits 2 and says so, and the only exit 0 is a measurement that
# actually happened.
#
# Output: one TSV row per checked session on stdout, column header on stderr.
#
#   verdict <TAB> rig <TAB> session <TAB> role <TAB> queued <TAB> age_seconds <TAB> identity
#
#   idle         no assigned work — healthy, never flagged
#   working      holds work and the signal is inside the window
#   starved      holds work and the signal is stale — FINDING
#   schema-drift session exposes no queryable identity, or its beads expose no
#                updated_at — nothing was measured for it
#   query-failed the bead query itself failed — nothing was measured for it
#
# Exit codes:  0 = every checked session is idle or working (or none to check)
#              1 = findings on stdout (starved)
#              2 = the check could not run (bad env, unreadable roster, schema
#                  drift, or a failed bead query) — NOT health
#
# Env:
#   GC_CITY                             city root (auto-discovered if unset)
#   GASTOWN_STARVATION_STALE_MIN        window for coordination/merge sessions
#                                       (default: 30)
#   GASTOWN_STARVATION_POLECAT_MIN      window for polecats, which take longer
#                                       per step (default: 120)
#   GASTOWN_STARVATION_STATUSES         bead statuses that count as queued
#                                       (default: open,in_progress)

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
  echo "queue-starvation-check: GC_CITY not set and no city.toml found" >&2
  exit 2
fi

# 30m is ~6x the 300s max patrol backoff: coordination agents cycle in seconds
# when work is present, so half an hour of silence on a non-empty queue is an
# eternity rather than a lull. Polecats legitimately spend longer inside a single
# implement step, so they get their own, more forgiving window instead of being
# excluded — excluding them is how a stuck polecat becomes invisible.
STALE_MIN="${GASTOWN_STARVATION_STALE_MIN:-30}"
POLECAT_MIN="${GASTOWN_STARVATION_POLECAT_MIN:-120}"

# open+in_progress, not open alone. A claimed bead flips to in_progress, so the
# `open`-only query this replaced could not see the work a session was actually
# sitting on. Comma-separated because repeating `-s` silently overwrites.
STATUSES="${GASTOWN_STARVATION_STATUSES:-open,in_progress}"

for pair in "GASTOWN_STARVATION_STALE_MIN:$STALE_MIN" "GASTOWN_STARVATION_POLECAT_MIN:$POLECAT_MIN"; do
  var=${pair%%:*}
  val=${pair#*:}
  case "$val" in
    ''|*[!0-9]*)
      echo "queue-starvation-check: $var must be a positive integer (got '$val')" >&2
      exit 2
      ;;
  esac
  if [ "$val" -le 0 ]; then
    echo "queue-starvation-check: $var must be a positive integer (got '$val')" >&2
    exit 2
  fi
done

NOW=$(date -u +%s)

# ts_epoch — RFC3339 timestamp to epoch seconds, printing 0 for "no usable
# signal": empty, null, or the Go zero-time sentinel `gc` emits for a field it
# has never set. 0 means unknown, never "ancient".
#
# GNU `date -d` first, BSD `date -j -f` second: the fleet includes macOS. The BSD
# arm normalizes the offset twice over because BSD `%z` accepts only the compact
# RFC822 spelling — `Z` becomes `+0000`, and a `±HH:MM` offset loses its colon.
# Dropping that colon strip is gp-ra8, which silently turned the witness check
# into a nudge-age meter on macOS while CI stayed green; the same input reaches
# this check, so it carries the same normalization.
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
  [ "$epoch" -gt 0 ] && printf '%s' "$epoch" || printf '0'
}

# `--state=all` because the default listing hides asleep sessions, and a session
# that fell asleep holding a queue is precisely the shape this check is for.
if ! ROSTER=$(gc session list --state=all --json 2>/dev/null); then
  echo "queue-starvation-check: 'gc session list --state=all --json' failed — starvation NOT measured" >&2
  exit 2
fi

# The {"ok":false} envelope check is the whole lesson of gp-b3x and must not be
# reduced to the `if !` above. `gc` reports an unknown command by printing that
# envelope to stdout and exiting non-zero, but the original snippet ran the
# roster call at the head of a pipeline, where its exit status is discarded. Any
# future refactor that reintroduces a pipe would slip straight past a
# status-only guard; this one reads the payload itself.
if printf '%s' "$ROSTER" | jq -e '(type == "object") and (.ok == false)' >/dev/null 2>&1; then
  ROSTER_ERR=$(printf '%s' "$ROSTER" | jq -r '.error.message // "unknown error"' 2>/dev/null)
  echo "queue-starvation-check: the roster command failed (${ROSTER_ERR}) — starvation NOT measured" >&2
  exit 2
fi

# `gc session list --json` returns an OBJECT with a `sessions` array. Tolerate a
# bare top-level array too: that shape shipped previously and the schema has
# drifted before (gc-3tn8g).
JQ_SESSIONS='def sessions_of: (.sessions? // .) | if type == "array" then . else [] end;'

# An object carrying neither `sessions` nor an array body is drift, not an empty
# city. Without this, a renamed key would present as "no sessions to check" and
# exit 0 — the silent green this check exists to refuse.
if ! printf '%s' "$ROSTER" | jq -e '(type == "array") or (type == "object" and has("sessions"))' >/dev/null 2>&1; then
  echo "queue-starvation-check: roster exposes no 'sessions' array — gc session list schema drifted; starvation NOT measured" >&2
  exit 2
fi

if ! TOTAL=$(printf '%s' "$ROSTER" | jq -r "$JQ_SESSIONS sessions_of | length" 2>/dev/null); then
  echo "queue-starvation-check: could not parse the session roster — starvation NOT measured" >&2
  exit 2
fi

# Both identity namespaces, per session, deliberately unioned. `--assignee` is an
# exact match, so the session NAME (polecat self-claim) and the agent ADDRESS
# (refinery handoff) are disjoint query keys and each hides a different class of
# work from the other. `alias`/`name` come along because they are the address
# under other spellings and cost nothing once deduplicated.
ROWS=$(printf '%s' "$ROSTER" | jq -r "
  $JQ_SESSIONS
  sessions_of
  | .[]
  | select((.closed // false) | not)
  | [ (if (.name // \"\") != \"\" then .name
        elif (.alias // \"\") != \"\" then .alias
        else (.id // \"?\") end),
      (if (.rig // \"\") != \"\" then .rig else \"-\" end),
      (.state // \"\"),
      (.template // \"-\"),
      ([ (.session_name // \"\"), (.agent_name // \"\"), (.alias // \"\"), (.name // \"\") ]
       | map(select(. != null and . != \"\")) | unique | join(\",\"))
    ]
  | @tsv
" 2>/dev/null) || ROWS=''

# --- the queue, gathered once ------------------------------------------------
#
# Two queries total, regardless of how many sessions the city runs. The obvious
# shape — one `gc bd list --assignee=X` per session per identity — is O(sessions)
# round trips against Dolt, which measured ~2s each and pushed a single patrol
# pass past two minutes on an 18-session city.
#
if ! QUEUED=$(gc bd list --status="$STATUSES" --json --limit=0 2>/dev/null </dev/null); then
  echo "queue-starvation-check: 'gc bd list --status=$STATUSES' failed — starvation NOT measured" >&2
  exit 2
fi

if ! printf '%s' "$QUEUED" | jq -e 'type == "array"' >/dev/null 2>&1; then
  echo "queue-starvation-check: the queue query returned no array — starvation NOT measured" >&2
  exit 2
fi

# Read `assignee` off the list payload, and never `owner` — owner is the human
# who filed the bead, not the agent holding it, so grouping by it would attribute
# the whole city to one address and match no session at all.
#
# `assignee` is emitted only on beads that HAVE one; `jq keys` on an unassigned
# bead therefore shows no such field. Reading that as a listing that cannot
# report assignees is what motivated a second `gc bd show` pass here, and it was
# wrong: one query carries id, assignee and updated_at together.
#
# assignee -> {count, latest}, grouped once and looked up per identity below.
# `assignee` is a single exact string per bead, so two DIFFERENT identity
# spellings can never both match one bead and the per-identity counts below are
# safely additive.
HOLDINGS=$(printf '%s' "$QUEUED" | jq '
  map(select(((.assignee // "") | tostring) != "")
      | {assignee: .assignee, updated_at: (.updated_at // "")})
  | group_by(.assignee)
  | map({key: .[0].assignee,
         value: {count: length, latest: ([.[].updated_at] | max // "")}})
  | from_entries
' 2>/dev/null) || {
  echo "queue-starvation-check: could not group the queue by assignee — starvation NOT measured" >&2
  exit 2
}

printf 'verdict\trig\tsession\trole\tqueued\tage_seconds\tidentity\n' >&2

CHECKED=0
FINDINGS=0
STARVED=0
BROKEN=0

while IFS=$'\t' read -r ident rig state template identities; do
  [ -n "${ident:-}" ] || continue

  case "$(printf '%s' "$state" | tr '[:upper:]' '[:lower:]')" in
    active|awake|asleep|running) ;;
    # creating / drained / draining / suspended / quarantined / archived /
    # closed are controller- or operator-owned. Not this check's business.
    *) continue ;;
  esac

  CHECKED=$((CHECKED + 1))

  # No identity at all means every query below would return zero and the session
  # would read as idle. That is the exact silent-green shape under repair, so it
  # is a finding about the check, not a verdict about the session.
  if [ -z "${identities:-}" ]; then
    BROKEN=$((BROKEN + 1))
    printf 'schema-drift\t%s\t%s\t%s\t-\t-\t-\n' "$rig" "$ident" "$template"
    continue
  fi

  # Polecats get the longer window; everything else is a coordination or merge
  # agent that should be cycling in seconds.
  case "$template" in
    *.polecat|*/polecat|polecat) window_min=$POLECAT_MIN ;;
    *) window_min=$STALE_MIN ;;
  esac
  window_secs=$((window_min * 60))

  # Union both identity namespaces from the map gathered above. No network call
  # belongs inside this loop: the loop is fed by a here-doc on stdin, and a child
  # process that reads stdin eats the roster lines the loop has not consumed yet.
  # That cost one silently-skipped session per iteration when the queries lived
  # here — measured at 18 sessions in, 17 rows out, the deacon gone. A silently
  # skipped agent is the exact silent-green failure this check exists to refuse,
  # so the fix is structural: keep the queries outside the loop entirely.
  queued=0
  latest=''
  query_failed=0
  # Sum the counts and take the newest stamp across BOTH spellings in one pass.
  # `unique` first because a session whose two identity fields carry the same
  # string would otherwise be counted twice.
  if hit=$(printf '%s' "$HOLDINGS" | jq -r --arg ids "$identities" '
      . as $held
      | ($ids | split(",") | map(select(. != "")) | unique) as $names
      | [ $names[] | ($held[.] // {count: 0, latest: ""}) ] as $rows
      | "\([$rows[].count] | add // 0)\t\([$rows[].latest] | map(select(. != "")) | max // "")"
    ' 2>/dev/null); then
    queued=${hit%%	*}
    latest=${hit#*	}
    case "$queued" in
      ''|*[!0-9]*) query_failed=1 ;;
    esac
  else
    query_failed=1
  fi

  if [ "$query_failed" -eq 1 ]; then
    BROKEN=$((BROKEN + 1))
    printf 'query-failed\t%s\t%s\t%s\t-\t-\t%s\n' "$rig" "$ident" "$template" "$identities"
    continue
  fi

  # Step 4 of the patrol: a genuinely-idle session is NOT flagged. Idle-but-ready
  # refineries and witnesses are healthy.
  if [ "${queued:-0}" -eq 0 ]; then
    printf 'idle\t%s\t%s\t%s\t0\t-\t-\n' "$rig" "$ident" "$template"
    continue
  fi

  best=$(ts_epoch "$latest")

  # Beads exist but carry no readable updated_at: the work signal this check is
  # built on is gone, so nothing was measured. Never fall through to "working".
  if [ "$best" -eq 0 ]; then
    BROKEN=$((BROKEN + 1))
    printf 'schema-drift\t%s\t%s\t%s\t%s\t-\t%s\n' "$rig" "$ident" "$template" "$queued" "$identities"
    continue
  fi

  age=$((NOW - best))
  # A stamp in the future is clock skew, not progress you can bank on.
  [ "$age" -lt 0 ] && age=0

  if [ "$age" -ge "$window_secs" ]; then
    STARVED=$((STARVED + 1))
    FINDINGS=$((FINDINGS + 1))
    printf 'starved\t%s\t%s\t%s\t%s\t%s\t%s\n' "$rig" "$ident" "$template" "$queued" "$age" "$identities"
  else
    printf 'working\t%s\t%s\t%s\t%s\t%s\t%s\n' "$rig" "$ident" "$template" "$queued" "$age" "$identities"
  fi
done <<EOF
$ROWS
EOF

if [ "$BROKEN" -gt 0 ]; then
  echo "queue-starvation-check: $BROKEN session(s) could not be measured — starvation NOT measured for them" >&2
  exit 2
fi

if [ "$CHECKED" -eq 0 ]; then
  echo "queue-starvation-check: no working session among $TOTAL session(s) — nothing to check" >&2
  exit 0
fi

echo "queue-starvation-check: checked $CHECKED session(s), $STARVED starved (windows ${STALE_MIN}m / ${POLECAT_MIN}m polecat)" >&2

[ "$FINDINGS" -eq 0 ] || exit 1
