Re-resolve one assignee against a fresh session roster, before recovering its bead.

The witness's `recover-orphaned-beads` step builds its assignee->state liveness
map ONCE per cycle, before the per-bead loop, and only then lists beads. Any
session created between those two reads is missing from the map, the
classification table resolves an unknown assignee to `absent`, and `absent` is
treated as definitive — "the owning session is gone and will never come back".
Step 3b then resets that bead back into the pool.

So the map's freshness is load-bearing for a destructive action, and it was a
snapshot with no staleness check. This command is the staleness check: it
re-reads the roster and answers for the ONE assignee about to be acted on.

Measured (gp-8m6, meety-local witness patrol 2026-07-31T23:29-23:34Z): the
cycle map held 18 sessions / 54 keys and did not contain
`gastown__polecat-gk-a9xk`. Four minutes later `parked-check` found that
session active and `progress-check` found it holding `ml-0txz.4` in_progress
with a 1s heartbeat and uncommitted changes on disk. The bead escaped only
because it was not yet in_progress when the bead list was taken.

The existing fail-safe does not cover this. It fires only on an EMPTY map with
live sessions; a map that is non-empty but merely missing recently-spawned
sessions passes it cleanly, and every unknown assignee still resolves to
`absent`. This is the partial-staleness case.

Usage:
  gc gastown liveness-recheck <assignee>

  Call it for a bead already classified orphaned, before salvaging its worktree
  and before `gc gastown reopen-source`. It never turns a live classification
  into a reset — it can only withhold one — so it cannot orphan anything the
  current recipe would not.

Sources, probed in cost order:
  `gc session list --state=all --json` first, matching id / name / session_name
  / alias / agent_name by exact lookup. Only on a miss does it consult the
  session BEADS for `metadata.configured_named_identity`, the cycle map's other
  key source — the extra query is spent solely on the path whose answer would
  authorise a destructive reset.

  Set GASTOWN_RECHECK_SKIP_SESSION_BEADS=1 to probe the roster only. Narrower,
  never less safe.

Output — one TSV row on stdout, header on stderr:

  verdict <TAB> assignee <TAB> state <TAB> source

  present      found in a fresh read, in a state the classification table does
               NOT treat as orphaned. The cycle map was stale — this is the
               race, caught. Skip the bead; it is being worked right now.
  terminal     found, but `archived`/`closed`. The orphan classification holds,
               for a reason that was actually measured.
  absent       not found in either fresh source. The orphan classification
               holds.
  unavailable  the roster could not be read — call failed, error envelope, or
               schema drift. NOTHING was measured.

Exit codes:
  0   `absent` or `terminal` — re-confirmed gone. Recovery may proceed.
  1   `present` — a live session still owns this bead. Do not salvage its
      worktree and do not reset the bead.
  2   The check could not run. Nothing was measured, which is not a
      confirmation of absence. Do not reset the bead.

Note the polarity against `gc gastown delivery-check`, where exit 2 means
"proceed as normal". It is inverted here on purpose. There the unsafe direction
is halting a polecat over an unmeasured guess; here the unsafe direction is
proceeding, because a reset destroys a running agent's uncommitted work. Only
exit 0 is green, which makes the plain shell idiom the safe one:

  if gc gastown liveness-recheck "$ASSIGNEE"; then
      ... salvage and reset ...
  else
      ... skip this bead this cycle ...
  fi
