Measure whether in-flight polecat work beads are still moving.

The witness patrol step used to ask an LLM to eyeball "is this polecat still
making progress?" with no command to run, so the model improvised `date`
arithmetic every cycle. One improvisation stat'd a file, got a LOCAL-time mtime,
formatted it with a `Z` suffix, and compared it against a UTC `now`. On a PDT
host that is a 7-hour error: a file touched 4 minutes earlier read as ~7h stale,
and a warrant was filed against a polecat that was working correctly (gp-9ly).

This command measures instead. Its arithmetic is epoch-to-epoch and never
touches a local-time string — `stat` yields raw epoch seconds, which carry no
timezone at all, and the only formatting happens on the way out, explicitly
under `date -u`. There is deliberately no code path that can format a local
mtime. It is read-only: it never nudges, mails, or files warrants — the
witness's `check-polecat-health` step owns those decisions.

Usage:
  gc gastown progress-check
  GASTOWN_POLECAT_STALE_MIN=90 gc gastown progress-check

Scope:
  Every `in_progress` work bead whose assignee matches the polecat role as a
  delimited token, from your own rig's ledger — so it never reaches into another
  rig's polecats.

  The heartbeat is the NEWER of the bead's `updated_at` and the newest file mtime
  under `metadata.work_dir`. Either signal alone misleads: a polecat editing
  files for an hour without touching bd looks stale by bead time, and a polecat
  mid `go test` touches no files but is plainly alive.

Output — one TSV row per checked bead on stdout, header on stderr:

  verdict <TAB> bead <TAB> assignee <TAB> age_seconds <TAB> heartbeat <TAB>
  source <TAB> commits <TAB> dirty

  fresh         heartbeat inside the window.
  stale         heartbeat older than the window. NECESSARY BUT NOT SUFFICIENT to
                file a warrant — see below.
  no-heartbeat  no usable timestamp at all; nothing was measured for that bead.

  source        which signal won: `worktree`, `bead`, or `-`
  commits       commits ahead of upstream/origin-main, or `-` if unresolvable
  dirty         count of uncommitted+untracked paths, or `-`

Exit codes:
  0   Every checked polecat is fresh (or there was nothing to check).
  1   Findings on stdout (stale and/or no-heartbeat).
  2   The check could not run — bad env, an unreadable bead list, or no usable
      `stat`. Freshness was NOT measured, which is not the same as health.

Why `stale` is not a warrant: it means only "no file or bead activity in the
window", which a polecat blocked in one long tool call legitimately produces.
Confirm with a live proof-of-life peek before escalating — a rising token counter
across two peeks OVERRIDES this verdict. A large `dirty` count with `commits` at
0 is also normal mid-flight state for a polecat that has not reached its commit
step yet, and must never be read as a stall.

Why this is a `gc` command rather than a path: `GC_PACK_DIR` is set by `gc` when
`gc` invokes a pack command, and is absent from a plain agent session. A formula
step that reached for `"${GC_PACK_DIR:-}/assets/scripts/polecat-progress-check.sh"`
expanded to `/assets/scripts/...`, failed its own `[ -x ]` guard, and fell
through to a message that read like a considered fallback — so the check silently
measured nothing and the patrol was back to eyeballing. Routing through `gc` puts
the only process that knows where the pack materialized back in the invoker seat.
