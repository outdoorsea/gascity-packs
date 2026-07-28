#!/usr/bin/env bash
# usage-stamp.sh — attribute a session's model spend to the bead it was spent on.
#
# The gap it closes: Gas City already meters token usage, but it meters it per
# SESSION. Every `kind:"model"` row in `<city>/.gc/usage.jsonl` carries exactly
# the fields a downstream tracker wants — model, input_tokens, output_tokens,
# cache_read_tokens, cache_creation_tokens — keyed by `session_id`/`worker` and
# by nothing else. Beads separately record which session claimed them
# (`metadata.gc.session_id`). Nobody joins the two, so per-bead and per-PRD
# spend reads empty even though the numbers were on disk the whole time.
#
# This script is that join, and it is deliberately mechanical. The alternative
# — asking the agent to report its own token counts on handoff — cannot work:
# a session's usage is written by the runtime as the session runs, and an agent
# narrating its own spend is guessing at a number the runtime already knows
# exactly. Measurement belongs to whatever can measure. See gp-fid.
#
# Output: one TSV row per model on stdout, then a TOTAL row. Column header on
# stderr, so row assertions stay clean.
#
#   model <TAB> provider <TAB> rows <TAB> input <TAB> output <TAB> cache_read <TAB> cache_creation
#
# Unless --dry-run is passed, the aggregate is also stamped onto the bead as
# metadata under the `usage.` prefix, using the field names a downstream
# tracker consumes:
#
#   usage.status            metered | unmetered
#   usage.session_id        the session the spend was joined from
#   usage.model             dominant model (most output tokens — see below)
#   usage.provider          provider for the dominant model
#   usage.input_tokens      summed across every matched row
#   usage.output_tokens
#   usage.cache_read_tokens
#   usage.cache_creation_tokens
#   usage.models            per-model breakdown, only when >1 model contributed
#   usage.unmetered_reason  why nothing was measured, only when unmetered
#
# `usage.model` is a single field but a session may span several models (a
# subagent on a cheaper tier, a mid-session model change). The dominant model
# is the one with the most OUTPUT tokens, because output is the cost driver
# that is unambiguously attributable to the model that produced it. When more
# than one model contributed, the full breakdown is preserved in
# `usage.models` so the flattening never silently loses a tier.
#
# UNMETERED IS NOT ZERO. If no rows match, this stamps `usage.status=unmetered`
# with a reason and writes NO token fields. A bead that reports 0 input and 0
# output tokens is indistinguishable from work that was genuinely free, and
# that is the exact failure this whole exercise exists to stop: silence that
# reads as data. The local sink really can be off — `GC_DISABLE_USAGE_METRICS=1`
# and a non-local usage provider (`exec:` / `discard`) both produce a session
# with real spend and no local rows.
#
# Exit codes:  0 = spend measured (and stamped unless --dry-run)
#              1 = unmetered — nothing to measure; the reason was recorded
#              2 = the join could not run (bad env, no jq, unreadable sink)
#
# Callers that must not fail on an unmetered session should invoke this as
# `usage-stamp.sh <bead> || true`. Metering is an observation, never a gate on
# work changing hands.
#
# Env:
#   GC_CITY / GC_CITY_PATH   city root (auto-discovered if unset, walks up)
#   GC_SESSION_ID            default session id to join on
#   GC_SESSION_NAME          default session name (matched against `worker`)
#
# Usage:
#   usage-stamp.sh <bead-id>
#   usage-stamp.sh <bead-id> --dry-run
#   usage-stamp.sh <bead-id> --session gk-3q5 --session-name gastown__polecat-gk-3q5

set -euo pipefail

BEAD=""
SID="${GC_SESSION_ID:-}"
SNAME="${GC_SESSION_NAME:-}"
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)      DRY_RUN=1; shift ;;
    --session)      SID="${2:-}"; shift 2 ;;
    --session-name) SNAME="${2:-}"; shift 2 ;;
    -h|--help)
      sed -n '2,70p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    -*)
      echo "usage-stamp: unknown flag '$1'" >&2
      exit 2 ;;
    *)
      if [ -n "$BEAD" ]; then
        echo "usage-stamp: unexpected argument '$1' (one bead id only)" >&2
        exit 2
      fi
      BEAD="$1"; shift ;;
  esac
done

if [ -z "$BEAD" ]; then
  echo "usage-stamp: a bead id is required" >&2
  exit 2
fi

command -v jq >/dev/null 2>&1 || {
  echo "usage-stamp: jq not found — spend NOT measured" >&2
  exit 2
}

# Resolve city root: env wins, else walk up from cwd looking for city.toml.
# Same resolution the other gastown patrol scripts use.
CITY="${GC_CITY:-${GC_CITY_PATH:-}}"
if [ -z "$CITY" ]; then
  dir=$(pwd)
  while [ "$dir" != "/" ]; do
    if [ -f "$dir/city.toml" ]; then
      CITY="$dir"
      break
    fi
    dir=$(dirname "$dir")
  done
fi

if [ -z "$CITY" ] || [ ! -f "$CITY/city.toml" ]; then
  echo "usage-stamp: GC_CITY not set and no city.toml found — spend NOT measured" >&2
  exit 2
fi

# Fall back to the bead's own record of who worked it. This is what makes the
# script usable from a later bridge (refinery at close, a backfill sweep) and
# not just from inside the spending session.
if [ -z "$SID" ] || [ -z "$SNAME" ]; then
  if BEAD_MD=$(gc bd show "$BEAD" --json 2>/dev/null); then
    [ -n "$SID" ] || SID=$(printf '%s' "$BEAD_MD" |
      jq -r '.[0].metadata["gc.session_id"] // ""' 2>/dev/null || printf '')
    [ -n "$SNAME" ] || SNAME=$(printf '%s' "$BEAD_MD" |
      jq -r '.[0].metadata["gc.session_name"] // ""' 2>/dev/null || printf '')
  fi
fi

if [ -z "$SID" ] && [ -z "$SNAME" ]; then
  echo "usage-stamp: no session identity for $BEAD (no GC_SESSION_ID/GC_SESSION_NAME, no gc.session_id on the bead) — spend NOT measured" >&2
  exit 2
fi

# stamp_unmetered <reason> — record that spend is unknown, and why. Writes no
# token fields: absent beats a zero that reads as free work.
stamp_unmetered() {
  local reason="$1"
  echo "usage-stamp: $BEAD unmetered — $reason" >&2
  if [ "$DRY_RUN" -eq 0 ]; then
    gc bd update "$BEAD" \
      --set-metadata usage.status=unmetered \
      --set-metadata usage.session_id="${SID:-$SNAME}" \
      --set-metadata usage.unmetered_reason="$reason" >/dev/null 2>&1 ||
      echo "usage-stamp: could not stamp unmetered status on $BEAD" >&2
  fi
  exit 1
}

USAGE="$CITY/.gc/usage.jsonl"

if [ ! -r "$USAGE" ]; then
  # No local sink at all. Either nothing has been recorded yet, or the city
  # forwards usage out of process ("exec:") or drops it ("discard"), in which
  # case the numbers exist but never land here.
  stamp_unmetered "no local usage sink at .gc/usage.jsonl (usage provider may be 'exec:' or 'discard')"
fi

# `inputs` streams the sink line by line rather than slurping it; the sink is
# append-only for the life of the city and gets large.
ROWS=$(jq -rn --arg sid "$SID" --arg sname "$SNAME" '
  def agg:
    reduce ( inputs
             | select((.kind // "") == "model")
             | select( ($sid   != "" and (.session_id // "") == $sid)
                    or ($sname != "" and (.worker     // "") == $sname) )
           ) as $u ({};
      ($u.model // "unknown") as $m
      | .[$m].provider       = ($u.provider // .[$m].provider // "")
      | .[$m].rows           = ((.[$m].rows           // 0) + 1)
      | .[$m].input          = ((.[$m].input          // 0) + ($u.input_tokens          // 0))
      | .[$m].output         = ((.[$m].output         // 0) + ($u.output_tokens         // 0))
      | .[$m].cache_read     = ((.[$m].cache_read     // 0) + ($u.cache_read_tokens     // 0))
      | .[$m].cache_creation = ((.[$m].cache_creation // 0) + ($u.cache_creation_tokens // 0))
    );
  agg
  | to_entries
  # Dominant model first: most output tokens, name as the tie-break so the
  # ordering is stable across runs over the same sink.
  | sort_by(-.value.output, .key)
  | .[]
  | [ .key, .value.provider, .value.rows,
      .value.input, .value.output, .value.cache_read, .value.cache_creation ]
  | @tsv
' "$USAGE" 2>/dev/null) || {
  echo "usage-stamp: could not parse $USAGE — spend NOT measured" >&2
  exit 2
}

if [ -z "$ROWS" ]; then
  if [ "${GC_DISABLE_USAGE_METRICS:-}" = "1" ]; then
    stamp_unmetered "GC_DISABLE_USAGE_METRICS=1 — the runtime recorded no model rows for session ${SID:-$SNAME}"
  fi
  stamp_unmetered "no model usage rows for session ${SID:-$SNAME} in .gc/usage.jsonl"
fi

printf 'model\tprovider\trows\tinput\toutput\tcache_read\tcache_creation\n' >&2
printf '%s\n' "$ROWS"

TOP_MODEL=""
TOP_PROVIDER=""
N_MODELS=0
T_IN=0
T_OUT=0
T_CREAD=0
T_CCREATE=0
BREAKDOWN=""

while IFS=$'\t' read -r model provider rows input output cache_read cache_creation; do
  [ -n "${model:-}" ] || continue
  N_MODELS=$((N_MODELS + 1))
  # First row is the dominant model — jq already sorted by output descending.
  if [ "$N_MODELS" -eq 1 ]; then
    TOP_MODEL="$model"
    TOP_PROVIDER="$provider"
  fi
  T_IN=$((T_IN + input))
  T_OUT=$((T_OUT + output))
  T_CREAD=$((T_CREAD + cache_read))
  T_CCREATE=$((T_CCREATE + cache_creation))
  if [ -z "$BREAKDOWN" ]; then
    BREAKDOWN="$model=$input/$output"
  else
    BREAKDOWN="$BREAKDOWN,$model=$input/$output"
  fi
done <<EOF
$ROWS
EOF

printf 'TOTAL\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$TOP_PROVIDER" "$N_MODELS" "$T_IN" "$T_OUT" "$T_CREAD" "$T_CCREATE"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "usage-stamp: $BEAD dry run — $N_MODELS model(s), ${T_IN} in / ${T_OUT} out (not stamped)" >&2
  exit 0
fi

set -- \
  --set-metadata usage.status=metered \
  --set-metadata usage.session_id="${SID:-$SNAME}" \
  --set-metadata usage.model="$TOP_MODEL" \
  --set-metadata usage.provider="$TOP_PROVIDER" \
  --set-metadata usage.input_tokens="$T_IN" \
  --set-metadata usage.output_tokens="$T_OUT" \
  --set-metadata usage.cache_read_tokens="$T_CREAD" \
  --set-metadata usage.cache_creation_tokens="$T_CCREATE"

# Only carry the breakdown when the single `usage.model` field would otherwise
# hide a contributing tier.
if [ "$N_MODELS" -gt 1 ]; then
  set -- "$@" --set-metadata usage.models="$BREAKDOWN"
fi

if ! gc bd update "$BEAD" "$@" >/dev/null 2>&1; then
  echo "usage-stamp: measured spend for $BEAD but could not stamp it (gc bd update failed)" >&2
  exit 2
fi

echo "usage-stamp: $BEAD stamped — $TOP_MODEL, ${T_IN} in / ${T_OUT} out / ${T_CREAD} cache-read / ${T_CCREATE} cache-write across $N_MODELS model(s)" >&2
