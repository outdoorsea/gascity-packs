Measure how full the current session's context actually is.

The patrol formulas used to open their first step with

    RSS=$(ps -o rss= -p $$ | tr -d ' ')
    RSS_MB=$((RSS / 1024))

and restart "if RSS > 1500 MB". `$$` is the shell the agent harness forks per
tool call, not the agent runtime. Measured on this fleet: `$$` reads 2 MB while
the runtime holding the conversation was 511 MB. The gate could not fire at any
context depth, so the step reported CLEAN forever and the patrols' only
automatic restart trigger was inert — leaving "context feels heavy" eyeballing
as the sole remaining path, which is what the deterministic checks in these
formulas exist to replace (gp-ay9, same shape as gp-3qb and gp-584).

Pointing that threshold at the right process would not have been enough. Across
ten live runtimes the fleet occupied 267-547 MB, so 1500 MB is ~2.7x the healthy
ceiling and corresponds to a multi-million-token conversation. Both the process
and the number had to change.

Usage:
  gc gastown context-usage
  gc gastown context-usage --session-name gastown__witness --session-id gk-l1tp
  GASTOWN_CONTEXT_LIMIT_TOKENS=250000 gc gastown context-usage

Signals — two independent ones, either of which can trip:

  tokens  The prompt side of the newest `kind:"model"` row for this session in
          `<city>/.gc/usage.jsonl`: input + cache_read + cache_creation. Every
          call resends the whole conversation, so that sum IS context occupancy
          at that call. This is the real signal, but the sink flushes in batches
          — it lagged ~39 minutes when this was written, and none of the ten
          live agents had a row yet. It cannot be the only signal.

  rss     Max RSS over the process subtree rooted at the tmux pane pid for
          `$GC_SESSION_NAME`. Always current, but a correlate rather than a
          measurement. MAX, not sum: MCP servers and helpers are separate
          children whose memory is not context, and summing them would inflate
          the reading until the threshold stopped meaning anything.

Stale token readings are treated asymmetrically. Context only grows between
compactions, so a reading ABOVE the limit still trips even when old. A stale
reading BELOW the limit proves nothing about now, so it is discarded rather than
counted as health, and the verdict falls to RSS.

Output — one TSV row on stdout, header on stderr:

  verdict <TAB> signal <TAB> tokens <TAB> token_age_sec <TAB> rss_mb <TAB>
  runtime_pid <TAB> limit_tokens <TAB> limit_rss_mb

  ok          a signal was measured; nothing is over its limit.
  heavy       a measured signal is at or over its limit. Restart is warranted.
  unmeasured  neither signal obtainable. Context pressure was NOT evaluated.

  signal      which signal(s) were measured: `tokens`, `rss`, `tokens+rss`, `-`
  numerics    `-` for any signal that was unavailable

Exit codes:
  0   ok
  1   heavy — the caller should run `gc runtime request-restart`
  2   unmeasured — the check could not run. NOT a clean bill of health.

Why `unmeasured` must not restart: a city with metering off and no tmux would
be permanently unmeasurable, and restarting on exit 2 would put every patrol
into a restart loop. Exit 2 is loud instead — the point of this command is that
a check can no longer return the reassuring answer without earning it.

Environment:
  GC_SESSION_NAME                     tmux session name; resolves the runtime
  GC_SESSION_ID                       session id; joins the usage sink
  GASTOWN_CONTEXT_LIMIT_TOKENS        default 400000
  GASTOWN_CONTEXT_LIMIT_RSS_MB        default 1200
  GASTOWN_CONTEXT_TOKENS_MAX_AGE_SEC  default 900

Threshold calibration (measured 2026-08-06, this fleet). Both defaults are
provisional and meant to be tuned per city; what matters is that both are
REACHABLE, which the number they replaced was not.

  tokens  76 sessions in the sink peaked at 293,613. 400,000 sits above the
          busiest patrol ever recorded here and well inside a 1M window, so it
          fires before exhaustion rather than after it.
  rss     Ten live runtimes spanned 267-547 MB. 1200 MB is ~2.2x that ceiling —
          plainly abnormal, but reachable by a long session, which 1500 MB was
          not. Tokens are authoritative when present; RSS is the coarser
          backstop for sessions the sink has not flushed.

Why this is a `gc` command rather than a path: `GC_PACK_DIR` is set by `gc` when
`gc` invokes a pack command, and is absent from a plain agent session. A formula
step that reached for `"${GC_PACK_DIR:-}/assets/scripts/context-usage-check.sh"`
would expand to `/assets/scripts/...`, fail its own `[ -x ]` guard, and fall
through to a message that reads like a considered fallback — trading one silent
no-op for another. Routing through `gc` puts the only process that knows where
the pack materialized back in the invoker seat.
