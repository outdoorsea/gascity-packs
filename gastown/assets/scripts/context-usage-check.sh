#!/usr/bin/env bash
# context-usage-check.sh — how full is THIS session's context, really?
#
# The gap it closes: three patrol formulas opened their first step with
#
#     RSS=$(ps -o rss= -p $$ | tr -d ' ')
#     RSS_MB=$((RSS / 1024))
#
# and instructed the agent to request a restart "if RSS > 1500 MB". `$$` is the
# shell the agent harness forks per tool call, not the agent runtime, so that
# reads 2 MB no matter how deep the conversation is. Measured on this fleet
# (gp-ay9): `$$` = 2 MB against a 1500 MB gate. The guard could not fire at any
# context depth, so the step reported CLEAN forever and the patrol's only
# automatic restart trigger was inert — leaving "context feels heavy" eyeballing
# as the sole remaining path, which is exactly the improvisation the
# deterministic checks in these formulas exist to replace (cf. gp-3qb, gp-584).
#
# Fixing the PID alone was NOT enough, and that is the substance of this script.
# Measured across the live fleet on 2026-08-06, ten agent runtimes occupied
# 267-547 MB. A 1500 MB gate is ~2.7x the healthy ceiling; against the one
# token/RSS pair available (250,409 tokens <-> 547 MB) it corresponds to a
# multi-million-token conversation, past any context window in use. Pointing the
# old threshold at the right process would have shipped a SECOND guard that
# never fires. Both the process and the number had to change.
#
# Two independent signals, either of which can trip:
#
#   tokens  The prompt side of the newest `kind:"model"` row for this session in
#           <city>/.gc/usage.jsonl: input + cache_read + cache_creation. Every
#           call resends the whole conversation, so that sum IS the context
#           occupancy at that call. This is the real signal — but the sink is
#           flushed in batches and lagged ~39 minutes when this was written, and
#           NONE of the ten live agents had a row yet. It cannot be the only one.
#
#   rss     Max RSS over the process subtree rooted at the tmux pane pid for
#           $GC_SESSION_NAME. Always available and always current, but a
#           correlate rather than a measurement. MAX, not sum: MCP servers and
#           helpers are separate children whose memory is not context, and
#           summing them would inflate the reading until the threshold stopped
#           meaning anything. The runtime holding the conversation is the single
#           heaviest process in the subtree.
#
# Stale token readings are treated ASYMMETRICALLY, which is the same
# "abstention is not a clearance" rule the delivery-check gate follows, applied
# to time instead of evidence. Context only grows between compactions, so a
# stale reading ABOVE the limit is still valid evidence of heaviness and trips.
# A stale reading BELOW the limit proves nothing about now, so it is discarded
# rather than counted as health, and the verdict falls to RSS.
#
# UNMEASURED IS NOT HEALTHY. If neither signal can be obtained this exits 2 and
# says so. Reporting "0 tokens, looks fine" when metering is off would recreate
# the precise defect this script exists to remove: a check that always returns
# the reassuring answer, so nobody re-checks it.
#
# Output — one TSV row on stdout, column header on stderr so row assertions stay
# clean:
#
#   verdict <TAB> signal <TAB> tokens <TAB> token_age_sec <TAB> rss_mb <TAB>
#   runtime_pid <TAB> limit_tokens <TAB> limit_rss_mb
#
#   ok          at least one signal measured, nothing over its limit
#   heavy       a measured signal is at or over its limit — restart is warranted
#   unmeasured  neither signal obtainable; context pressure was NOT evaluated
#
#   signal      which signal(s) were measured: tokens, rss, tokens+rss, or -
#   any numeric column is `-` when that signal was unavailable
#
# Exit codes:
#   0  ok
#   1  heavy — the caller should run `gc runtime request-restart`
#   2  unmeasured — NOT a clean bill of health, and NOT a reason to restart
#      (a permanently unmeasurable city would restart-loop on every patrol)
#
# Env:
#   GC_CITY / GC_CITY_PATH              city root (auto-discovered if unset)
#   GC_SESSION_NAME                     tmux session name; resolves the runtime
#   GC_SESSION_ID                       session id; joins the usage sink
#   GASTOWN_CONTEXT_LIMIT_TOKENS        default 400000 — see calibration below
#   GASTOWN_CONTEXT_LIMIT_RSS_MB        default 1200 — see calibration below
#   GASTOWN_CONTEXT_TOKENS_MAX_AGE_SEC  default 900; older readings are stale
#
# Threshold calibration (measured 2026-08-06, this fleet, gp-ay9). Both defaults
# are provisional and meant to be overridden per city; what matters is that both
# are REACHABLE, which the number they replaced was not.
#
#   tokens  76 sessions in the sink peaked at 293,613. 400,000 sits above the
#           busiest patrol ever recorded here and well inside a 1M window, so it
#           fires before exhaustion instead of after it.
#   rss     Ten live runtimes spanned 267-547 MB. 1200 MB is ~2.2x that ceiling
#           — plainly abnormal, but reachable by a long session, which 1500 MB
#           was not. The token signal is the authoritative one when present;
#           this is the coarser backstop for sessions the sink has not flushed.
#
# Usage:
#   context-usage-check.sh
#   context-usage-check.sh --session-name gastown__witness --session-id gk-l1tp
#   GASTOWN_CONTEXT_LIMIT_TOKENS=250000 context-usage-check.sh

set -euo pipefail

SNAME="${GC_SESSION_NAME:-}"
SID="${GC_SESSION_ID:-}"
LIMIT_TOKENS="${GASTOWN_CONTEXT_LIMIT_TOKENS:-400000}"
LIMIT_RSS_MB="${GASTOWN_CONTEXT_LIMIT_RSS_MB:-1200}"
TOKENS_MAX_AGE="${GASTOWN_CONTEXT_TOKENS_MAX_AGE_SEC:-900}"

while [ $# -gt 0 ]; do
  case "$1" in
    --session-name) SNAME="${2:-}"; shift 2 ;;
    --session-id)   SID="${2:-}"; shift 2 ;;
    -h|--help)      sed -n '2,60p' "$0"; exit 0 ;;
    *)
      echo "context-usage-check: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

# --- signal 1: token occupancy from the usage sink ---------------------------
#
# Absent for a session the sink has not flushed, which on this fleet is the
# common case for a LIVE session. Absence is reported, never defaulted to 0.

TOKENS="-"
TOKEN_AGE="-"
TOKENS_USABLE=0

CITY="${GC_CITY:-${GC_CITY_PATH:-}}"
if [ -z "$CITY" ]; then
  dir="$PWD"
  while [ "$dir" != "/" ]; do
    if [ -f "$dir/city.toml" ]; then
      CITY="$dir"
      break
    fi
    dir="$(dirname "$dir")"
  done
fi

USAGE="${CITY:+$CITY/.gc/usage.jsonl}"
if [ -n "$USAGE" ] && [ -r "$USAGE" ] && command -v jq >/dev/null 2>&1 \
   && { [ -n "$SID" ] || [ -n "$SNAME" ]; }; then
  # Last matching line in FILE order, not by `at`: the sink is append-only, and
  # a batch flush stamps many rows with an identical `at`, so `at` cannot order
  # within a batch. Match on session_id or worker, the same join usage-stamp
  # uses, and guard each against an empty selector so an unset var cannot match
  # rows that merely lack the field.
  #
  # The trailing `|| true` inside each substitution below is load-bearing under
  # `set -euo pipefail`: an assignment takes the exit status of its command
  # substitution, and pipefail surfaces a failing producer even when the
  # consumer succeeds. Without it, an unreadable sink or an unresolvable tmux
  # pane kills the script with exit 1 — which this command defines as HEAVY, so
  # a failure to measure would be reported as a reason to restart. Failing into
  # the restart code is the one direction this check must never fail in.
  ROW="$(jq -c --arg s "$SID" --arg w "$SNAME" '
      select(.kind == "model"
             and ((($s | length) > 0 and .session_id == $s)
                  or (($w | length) > 0 and .worker == $w)))
      | { ctx: ((.input_tokens // 0) + (.cache_read_tokens // 0) + (.cache_creation_tokens // 0)),
          at: (.at // 0) }
    ' "$USAGE" 2>/dev/null | tail -1 || true)"
  if [ -n "$ROW" ]; then
    TOKENS="$(printf '%s' "$ROW" | jq -r '.ctx')"
    ROW_AT_MS="$(printf '%s' "$ROW" | jq -r '.at')"
    if [ "$ROW_AT_MS" -gt 0 ] 2>/dev/null; then
      TOKEN_AGE=$(( $(date +%s) - ROW_AT_MS / 1000 ))
      if [ "$TOKEN_AGE" -lt 0 ]; then
        TOKEN_AGE=0
      fi
    fi
    TOKENS_USABLE=1
  fi
fi

# --- signal 2: RSS of the actual runtime process -----------------------------
#
# The pane pid, never `$$`. `-t "=name"` forces an exact session match so a
# prefix collision cannot silently measure another agent's runtime.

RSS_MB="-"
RUNTIME_PID="-"

if [ -n "$SNAME" ] && command -v tmux >/dev/null 2>&1; then
  PANE_PID="$(tmux list-panes -t "=$SNAME" -F '#{pane_pid}' 2>/dev/null | head -1 || true)"
  if [ -n "$PANE_PID" ]; then
    # Walk the whole subtree to a fixpoint rather than assuming the runtime is
    # the pane's root process. It is on this fleet, but a pane that starts a
    # shell which then execs the runtime puts it one level down, and a check
    # that quietly measured the wrong process is what produced this bead.
    SUBTREE="$(ps -eo pid=,ppid=,rss= 2>/dev/null | awk -v root="$PANE_PID" '
        { pid[NR] = $1; ppid[NR] = $2; rss[NR] = $3; n = NR }
        END {
          want[root] = 1
          changed = 1
          while (changed) {
            changed = 0
            for (i = 1; i <= n; i++)
              if (!want[pid[i]] && want[ppid[i]]) { want[pid[i]] = 1; changed = 1 }
          }
          best = -1; bestpid = "-"
          for (i = 1; i <= n; i++)
            if (want[pid[i]] && rss[i] + 0 > best) { best = rss[i] + 0; bestpid = pid[i] }
          if (best >= 0) print bestpid, best
        }' || true)"
    if [ -n "$SUBTREE" ]; then
      RUNTIME_PID="${SUBTREE%% *}"
      RSS_MB=$(( ${SUBTREE##* } / 1024 ))
    fi
  fi
fi

# --- verdict -----------------------------------------------------------------

SIGNALS=""
HEAVY=0

if [ "$TOKENS_USABLE" -eq 1 ]; then
  # An age we could not compute counts as STALE, not as fresh. A row whose `at`
  # is missing or unparseable says nothing about when it was written, and
  # resolving that unknown to "recent" — thereby granting health — is the
  # reassuring-answer reflex this command exists to remove. Default to stale and
  # let only a positively-measured age clear it.
  STALE=1
  if [ "$TOKEN_AGE" != "-" ] && [ "$TOKEN_AGE" -le "$TOKENS_MAX_AGE" ]; then
    STALE=0
  fi
  if [ "$TOKENS" -ge "$LIMIT_TOKENS" ]; then
    # Over the limit counts whether fresh or stale: between compactions context
    # only grows, so an old high reading cannot have become safe on its own.
    SIGNALS="tokens"
    HEAVY=1
  elif [ "$STALE" -eq 0 ]; then
    SIGNALS="tokens"
  fi
  # Stale and under the limit: discarded. It describes a conversation up to
  # TOKENS_MAX_AGE ago and says nothing about the one running now, so counting
  # it as a measured-healthy signal would be the reassuring answer again.
fi

if [ "$RSS_MB" != "-" ]; then
  SIGNALS="${SIGNALS:+$SIGNALS+}rss"
  if [ "$RSS_MB" -ge "$LIMIT_RSS_MB" ]; then
    HEAVY=1
  fi
fi

printf 'verdict\tsignal\ttokens\ttoken_age_sec\trss_mb\truntime_pid\tlimit_tokens\tlimit_rss_mb\n' >&2

if [ -z "$SIGNALS" ]; then
  printf 'unmeasured\t-\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$TOKENS" "$TOKEN_AGE" "$RSS_MB" "$RUNTIME_PID" "$LIMIT_TOKENS" "$LIMIT_RSS_MB"
  echo "context-usage-check: context pressure was NOT evaluated — no usable token row and no resolvable runtime process. This is not a clean bill of health." >&2
  exit 2
fi

VERDICT="ok"
if [ "$HEAVY" -eq 1 ]; then
  VERDICT="heavy"
fi

printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$VERDICT" "$SIGNALS" "$TOKENS" "$TOKEN_AGE" "$RSS_MB" "$RUNTIME_PID" \
  "$LIMIT_TOKENS" "$LIMIT_RSS_MB"

if [ "$HEAVY" -eq 1 ]; then
  exit 1
fi
exit 0
