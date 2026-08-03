Measure whether any session is holding work it is not moving.

A session can look healthy-idle in a patrol wisp view while its queue silently
starves. The refinery (upstream #1833) self-polled for 13h42m with seven beads
assigned to it, because its poll filter resolved to an identity that did not
match its own. Session state said `active`, the wisp looked fresh, and nothing
moved for half a day.

The pairing of "queue depth" with "time since the queue last changed" is the
signal that separates a healthy idle agent from one wedged against its own
filter, and it is exactly the kind of measurement an LLM should not be
eyeballing. This command measures it. It is read-only: it never mails, nudges,
or files warrants — the deacon's `queue-starvation-check` step owns those
decisions.

Usage:
  gc gastown queue-starvation-check
  GASTOWN_STARVATION_STALE_MIN=15 gc gastown queue-starvation-check

Scope:
  Every session in a state that implies it should be working (active / awake /
  asleep / running). Sessions the controller or an operator owns — creating /
  drained / draining / suspended / quarantined / closed — are skipped.

  Both assignee namespaces are queried and unioned per session. `--assignee` is
  an exact match, and Gas Town writes two spellings: a polecat self-claim lands
  the session NAME (`gastown__polecat-gk-s4j0`), a refinery handoff lands the
  agent ADDRESS (`meety-local/gastown.refinery`). Probing either alone misses
  the other class of work entirely.

  Queued means `open,in_progress`. A claimed bead flips to in_progress, so an
  `open`-only query cannot see the work a session is actually sitting on.

  Every rig's ledger is read, one query per rig. Gas Town shards beads per rig,
  so there is no such thing as a city-wide bead query: an unscoped `gc bd list`
  resolves to exactly one database, picked from `$GC_RIG` or the cwd. Gathering
  the queue that way meant polecat and refinery work — which lives in the
  per-rig ledgers — was invisible, and every session in the city scored 0 and
  reported idle (gp-1ug). Each query is now scoped by path, so the result does
  not depend on where the caller was standing.

  A rig that declares a ledger and then cannot produce it is an unread queue,
  not an empty one: the check exits 2 rather than reporting the sessions holding
  that rig's work as idle. A rig that never initialized beads is skipped, and
  said so on stderr.

Output — one TSV row per checked session on stdout, header on stderr:

  verdict <TAB> rig <TAB> session <TAB> role <TAB> queued <TAB> age_seconds <TAB> identity

  idle          no assigned work. Healthy — never flagged. An idle-but-ready
                refinery or witness is exactly what a quiet town looks like.
  working       holds work and the queue changed inside the window. Nothing
                to do.
  starved       holds work and the queue has not changed for longer than the
                window. Deterministic evidence; nudge first, then warrant if
                the stall survives the nudge.
  schema-drift  the session exposes no queryable identity, or its beads expose
                no `updated_at`. Nothing was measured for it — do not read this
                as health.
  query-failed  the bead query itself failed. Nothing was measured for it.

Windows:
  GASTOWN_STARVATION_STALE_MIN    coordination/merge sessions (default 30)
  GASTOWN_STARVATION_POLECAT_MIN  polecats (default 120)
  GASTOWN_STARVATION_STATUSES     statuses that count as queued
                                  (default open,in_progress)

  30m is ~6x the 300s max patrol backoff: a coordination agent cycles in
  seconds when work is present, so half an hour of silence on a non-empty queue
  is an eternity rather than a lull. Polecats legitimately spend longer inside a
  single implement step, so they get a more forgiving window rather than an
  exemption — exempting them is how a stuck polecat becomes invisible.

Exit codes:
  0  every checked session is idle or working (or none to check)
  1  findings on stdout (starved)
  2  the check could not run — starvation was NOT measured, which is NOT health

  The 2 matters more than usual here. This check replaced a step that could not
  fire (gp-b3x): it called a command that does not exist, queried a status that
  excluded claimed work, and probed one of two identity namespaces. Each fault
  produced zero rows, and zero rows read as a clean queue — so the detector had
  the same defect class as the incident it existed to catch. Every path here
  that fails to measure exits 2 and says so.

  That rewrite fixed three of the four silent-zero paths and the symptom did not
  change, because the fourth — gathering the queue from a single unscoped
  database — was still there (gp-1ug). Worth remembering in both directions: a
  check that is still reporting zero has not necessarily been fixed, and the
  surviving fault was the one introduced as an optimization.
