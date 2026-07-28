Reconcile this agent's patrol wisps to exactly one.

Every patrol agent (witness, refinery, deacon) must own exactly one open patrol
wisp. Each restart that cannot see the wisp it already owns pours another, and
the surplus leaks forever. This command is the single implementation of that
rule — formulas and prompts call it instead of carrying their own copy of the
query, which is how the three patrol formulas drifted apart in the first place.

Usage:
  gc gastown wisp-reconcile <verb> [args...]

Verbs:
  current
      Print the wisp this session is running ($GC_BEAD_ID, else the newest
      in_progress wisp). Empty output with exit 0 means "none" — a legitimate
      answer, not an error.

  startup
      Reconcile in_progress AND open wisps to exactly one, preferring
      in_progress; burn the surplus; print the survivor. For an agent's startup
      protocol, where either state is resumable.

  queued [--except <id>]
      Reconcile QUEUED (open) wisps to exactly one and print it. Excludes the
      wisp this session is running, so it is never offered as "next".

  ensure <formula> [--except <id>] [pour args...]
      `queued`, and if nothing is queued, pour <formula> and assign it. Prints
      the wisp to run NEXT. Extra args pass through to `gc bd mol wisp` — this
      is where per-formula `--var` flags go.

Exit codes — the distinction is load-bearing:
  0   Reconciled. The id is on stdout (empty = the agent genuinely owns none).
  1   `ensure` could not pour or assign. The caller must NOT burn its current
      wisp; leaving it open is recoverable, burning it stops the patrol loop.
  2   Could not run at all — no $GC_AGENT, or a query that failed. Nothing was
      reconciled and nothing may be poured.

A non-zero exit means "do not pour", NEVER "nothing found". The defect this
replaced was a query that failed open: it returned empty, the agent read that
as "no wisp exists", and poured a duplicate every single restart.

Examples:
  # Startup: resume the one wisp you own, burning any surplus.
  WISP=$(gc gastown wisp-reconcile startup) || exit 1

  # End of cycle: get the successor, then burn the current wisp. Resolve the
  # current wisp and pass --except: a running wisp is not reliably in_progress,
  # so without it `ensure` can hand back the very wisp you are about to burn,
  # leaving zero wisps and a patrol loop that dies silently.
  CURRENT=$(gc gastown wisp-reconcile current) || exit 1
  NEXT=$(gc gastown wisp-reconcile ensure mol-witness-patrol \
           --except "$CURRENT" --var binding_prefix=gastown.) || exit 1
  [ -n "$CURRENT" ] && gc bd mol burn "$CURRENT" --force

Environment:
  GC_AGENT     Agent identity whose wisps are reconciled (required).
  GC_BEAD_ID   The current wisp, when the runtime injected one.
  GC_PACK_DIR  Absolute pack directory (set by gc for pack commands).
