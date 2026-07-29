Detect sessions parked at a provider usage-limit prompt.

A parked session is the THIRD session state. Gas Town models two and has a
detector for each — alive-and-working, and dead-or-orphaned — and a session
parked at an interactive usage-limit prompt reads as healthy to both:
`gc session list` reports it `active`, so the controller will not restart it,
and liveness resolves its assignee to `active`, so orphan recovery correctly
refuses it. It is not stuck either: there is no loop and no long tool call. It
is not executing at all.

Measured (gp-px5, 2026-07-29): a polecat held a P1 bead for 17h doing nothing,
its pane showing a weekly-limit banner with no "esc to interrupt". It was not
out of quota — the banner was stale session state, and `gc session reset`
restored it in under 60 seconds. It also re-claimed the bead within ~3 minutes
of an operator releasing it, so a parked pool member acts as a bead sink.

Usage:
  gc gastown parked-check                      # every active session in GC_RIG
  gc gastown parked-check <id-or-alias>...     # only these sessions

Scope:
  GC_RIG scopes the scan and is inherited from the calling shell — every rig
  agent has it, so a witness scans only its own rig. Town-level sessions
  (mayor, deacon, dogs) are the deacon's concern. Explicitly named sessions
  bypass the rig filter, so an operator can triage a session in any rig.

Output — one TSV row per inspected session on stdout, header on stderr:

  verdict <TAB> session <TAB> session_name <TAB> alias <TAB> rig <TAB> detail

  parked      limit banner in the pane tail, no mid-turn marker, and the pane
              did not change across the settle gap. Remedy: `gc session reset`.
  settling    banner present but the pane is still advancing — possibly
              auto-retrying. Not actionable; a reset would interrupt a recovery
              already under way.
  busy        a mid-turn marker is present. The session is executing.
  clear       no limit banner in the pane tail.
  unpeekable  the peek failed — this session's state was NOT measured.

Exit codes:
  0   No parked and no unmeasured session (or nothing to check).
  1   Findings on stdout (parked and/or unpeekable).
  2   The check could not run — bad config, or an unreadable session list.
      Nothing was measured. That is not health: file nothing, escalate the
      breakage.

Environment:
  GC_RIG                        limit the scan to this rig (unset: every rig)
  GASTOWN_PARKED_PEEK_LINES     lines requested per peek (default: 40)
  GASTOWN_PARKED_TAIL_LINES     trailing lines searched for the banner (default: 12)
  GASTOWN_PARKED_SETTLE_SECS    gap between the two peeks (default: 45)
  GASTOWN_PARKED_MAX_JOBS       concurrent peeks per batch (default: 8)
  GASTOWN_PARKED_PATTERNS       case-insensitive ERE for limit banners
  GASTOWN_PARKED_BUSY_PATTERNS  case-insensitive ERE for mid-turn markers

  The banner patterns are provider UI copy — strings owned by the coding-agent
  CLI, not by Gas Town, so they can change without notice. Override
  GASTOWN_PARKED_PATTERNS to correct the list without waiting on a pack release.

Why the banner must be in the pane TAIL: the patterns are ordinary English that
an agent may legitimately have on screen — an agent working on this very bug
quotes the banner verbatim. A real parked banner is the last thing rendered,
immediately above the prompt; quoted text scrolls away as work continues.
Widening GASTOWN_PARKED_TAIL_LINES trades away that defense.

Why two peeks: `last_active` is not an activity signal. It tracks pane redraws,
so a parked session reports a last_active of ~now forever — which is why every
existing detector read this state as healthy. The signal used instead is pane
stability across a settle gap, an observation rather than an inference.

This command only measures. Resetting is the witness's decision, taken in the
`check-parked-sessions` step of mol-witness-patrol under a clean-worktree
precondition.
