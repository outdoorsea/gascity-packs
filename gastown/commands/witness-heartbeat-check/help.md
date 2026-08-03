Measure whether each witness's patrol loop is still beating.

A witness whose self-scheduled patrol loop has died still reports a healthy
session state. It sits in `asleep` or `active` forever, so the controller's
liveness reconcile sees a live session and the deacon's LLM health-scan reads
the quiet as legitimate idle. Wisp staleness on an otherwise idle rig is
indistinguishable from a healthy lull. Patrol stalls of 14h to 63h were
observed in production exactly this way, with no alert.

Heartbeat age is the one signal that separates "idle and fine" from "the loop
is gone", which makes it exactly the kind of measurement an LLM should not be
eyeballing. This command measures it. It is read-only: it never mails, nudges,
or files warrants — the deacon's `health-scan` step owns those decisions.

Usage:
  gc gastown witness-heartbeat-check
  GASTOWN_WITNESS_STALE_MIN=45 gc gastown witness-heartbeat-check

Scope:
  Every witness session in a state that implies it should be patrolling
  (active / awake / asleep / running). Sessions the controller or an operator
  owns — creating / drained / draining / suspended / quarantined / closed — are
  the controller's business and are skipped.

  The heartbeat is the NEWER of the session's `last_active` and
  `last_nudge_delivered_at`.

Output — one TSV row per checked witness on stdout, header on stderr:

  verdict <TAB> rig <TAB> session <TAB> state <TAB> age_seconds <TAB> heartbeat

  fresh         heartbeat inside the window. Nothing to do.
  stalled       heartbeat older than the window — the patrol loop is gone.
                Deterministic evidence; nudge first, then warrant if the stall
                survives the nudge.
  no-heartbeat  no usable timestamp recorded yet. Do NOT warrant: a
                freshly-spawned witness has no heartbeat yet, and `gc` emits the
                Go zero-time sentinel (0001-01-01T00:00:00Z) for a field it has
                never set. Only a no-heartbeat that persists across cycles is a
                real signal.
  schema-drift  the session exposes no `last_active` at all — nothing was
                measured for it.

Exit codes:
  0   Every checked witness is fresh (or there was nothing to check).
  1   Findings on stdout (stalled and/or no-heartbeat).
  2   The check could not run — bad config, an unreadable session roster, or a
      `gc session list` schema drift that hid `last_active`. That means
      freshness was NOT measured, which is not the same as health. Escalate the
      breakage rather than recording a clean patrol.

Environment:
  GASTOWN_WITNESS_STALE_MIN  staleness window in minutes (default: 90)
  GASTOWN_WITNESS_ROLE       role suffix to match (default: witness)
  GC_CITY                    city root; defaults to the city `gc` resolved

Why the window defaults to 90m: the gastown witness does not self-schedule a
~60s wakeup. It ends each cycle in `mol-witness-patrol`'s `next-iteration`,
which reads the resolved session_sleep policy off its own session bead and picks
one of two endings — under a configured policy it emits `IDLE:` and that policy
restarts it; with no policy configured (`off`/`legacy_off`, the default) it calls
`gc runtime request-restart` itself. Either way a healthy witness returns well
inside the witness agent's `idle_timeout` of 1h, so 1h is the longest legitimate
silence and the window sits at 1.5x that — well clear of legitimate idle, and
still an order of magnitude under the 14h floor of the stalls this check exists
to catch. Lower it only if your city's witness `idle_timeout` is lower.

This window is a backstop, not the patrol cadence. It formerly rested on
"session_sleep will restart it", which is false on any city that never
configured the policy: nothing restarted the witness and this 90m nag became the
cadence, letting witness context grow across cycles into compaction (gp-5bg).
The formula now owns the restart, which is what keeps 1h the real bound.

Why this is a `gc` command rather than a path: `GC_PACK_DIR` is set by `gc` when
`gc` invokes a pack command, and is absent from a plain agent session. A formula
step that reached for `"${GC_PACK_DIR:-}/assets/scripts/witness-heartbeat-check.sh"`
expanded to `/assets/scripts/...`, failed its own `[ -x ]` guard, and fell
through to a message that read like a considered fallback — so the check never
ran once and the patrol logged nothing wrong (gp-3qb). Routing through `gc` puts
the only process that knows where the pack materialized back in the invoker
seat.
