Tell a session waiting on a HUMAN apart from a session that is hung.

On 2026-08-03 `tallyup/gastown.witness` sat ~103 minutes parked on an interactive
selection menu, awaiting a keystroke no unattended session will ever receive
(gp-ha5). Its witness duties — orphan bead recovery, polecat health monitoring —
were not running that whole time, while the rig had a live polecat unwatched.

Detection was never the problem. `witness-heartbeat-check` flagged it correctly
(stalled, 6173s, window 90m). The problem was that `mol-deacon-patrol`'s
`health-scan` offered exactly two remedies and both are wrong for this cause:

  nudge     A live selection menu is not idle-prompt residue. A nudge injects
            text into it, and that text lands on whichever option sits under the
            cursor. On the observed menu, option 1 ran
            `gc bd close ta-2e1p --force`. Nudging a prompt-blocked agent can
            execute a destructive action nobody authorised.
  warrant   The agent is alive and behaving correctly. A shutdown dance discards
            the pending question and the reasoning that produced it, and the
            respawned session must rediscover the same decision from scratch.

The correct action is a third thing the ladder did not contain: route the
decision to a human and leave the session alone. This command is what lets the
deacon tell that case apart before it picks a rung.

Usage:
  gc gastown prompt-block-check <session> [<session>...]
  GASTOWN_PROMPT_BLOCK_TAIL=20 gc gastown prompt-block-check rig/gastown.witness

Output — one TSV row per session on stdout, header on stderr:

  verdict <TAB> session <TAB> signal <TAB> evidence

  prompt-blocked  the pane tail renders interactive-prompt chrome. Finding. Do
                  NOT nudge and do NOT warrant — route the decision to a human
                  and leave the session running.
  clear           no prompt chrome in the tail. The normal ladder applies. NOT
                  an assertion that the session is healthy; this command answers
                  one question only.
  unreadable      the pane could not be captured, or came back empty. Finding,
                  never a clearance — "I could not tell" must not license a
                  nudge, because the pane it could not read may be a menu.

  The `evidence` column carries the matched line and `signal` carries its offset
  from the bottom of the scanned window, so the finding can be judged without a
  second peek.

Why the existing signals cannot tell:

  Session state reads `active`. LAST ACTIVE reads an hour old — that is the
  render, not progress. Only the heartbeat is stale, and a stale heartbeat is
  what a genuine hang looks like too. Worse, `health-scan`'s own corroboration
  rule ("prove liveness with two peeks") reads a byte-identical pair of peeks as
  evidence of a HANG — and a session parked on a menu produces byte-identical
  peeks forever, because a menu is a still image. Every generic liveness signal
  points the wrong way here.

  The town's human-gate machinery cannot see it either: notify-on-human-gate-
  creation and renudge-stale-human-gates watch BEADS, and this gate exists only
  as chrome inside a tmux pane.

  What IS mechanically distinguishable is the chrome itself. A hung pane does not
  render a menu; a menu-blocked pane does.

Signals:
  GASTOWN_PROMPT_BLOCK_PATTERNS   ERE matched against the pane tail. Default:

                                    Enter to select
                                    (↑|↓).*to navigate
                                    ❯ <digit>.

  All three are chrome — pixels the TUI draws, not words an agent can write. The
  third is the version-robust member: footer wording gets reworded, but a menu
  that does not mark its current option is not a menu, and `❯` followed by a bare
  number and a dot cannot collide with the ordinary input box.

  Deliberately absent is the permission-prompt HEADLINE (`Do you want to
  proceed?`). It looks like the obvious fourth signal and it is a trap: it is
  prose-shaped, so an agent that simply ENDS ITS TURN with that question matches
  it — and then goes heartbeat-stale, because a finished turn is a still pane.
  Its false positives correlate with the condition being screened. Nothing is
  lost by omitting it: Claude Code's permission prompt IS a selection menu, so
  the structural signal already covers it.

  Extend this set, do not narrow it to silence a false positive.

Windows:
  GASTOWN_PROMPT_BLOCK_TAIL        pane lines from the bottom to scan (12)
  GASTOWN_PROMPT_BLOCK_PEEK_LINES  lines to request from `gc session peek` (40)
  GASTOWN_PROMPT_BLOCK_TIMEOUT     per-peek bound in seconds (20)

  Scanning only the tail is load-bearing, not a performance tweak. Scrollback
  holds arbitrary agent output, including — for any agent that ever discusses
  this defect — the literal words "Enter to select". Live chrome is anchored to
  the bottom of the screen, so the bottom is where it is looked for.

Targeted, never a sweep:

  `gc session peek` costs ~8 seconds per session, measured on gascity-packs
  (2026-08-03, 22 sessions). A no-argument sweep would spend ~3 minutes inside a
  patrol step — long enough to make the deacon's own heartbeat look stale, which
  is a remarkable way for a stall detector to behave. It is also unnecessary: the
  caller already holds the session list it cares about, because this check only
  runs on rows another check already flagged. Naming no sessions is exit 2, not
  an implicit roster scan.

One peek, not two:

  `health-scan`'s two-peek liveness rule is not reproduced here, and not by
  oversight. Two peeks discriminate progress from stillness, and both answers
  here are still — a hang and a menu are equally byte-identical across peeks. The
  chrome is the discriminator and one peek carries it.

Exit codes:
  0  every named session is `clear`
  1  findings on stdout (prompt-blocked and/or unreadable)
  2  the check could not run — no sessions named, or bad config. Nothing was
     measured, which is NOT a clearance either

Which way this is allowed to be wrong:

  Deliberately asymmetric. A false `prompt-blocked` on a genuinely hung session
  costs a DELAYED nudge; a false `clear` on a live menu costs an INJECTED
  KEYSTROKE into a menu whose options run commands. Every uncertain path
  therefore resolves away from nudging.

  Asymmetric is not free, though. Every false `prompt-blocked` withdraws a rung
  the ladder needs, so a screen that over-fires does not fail safe — it disables
  the ladder more politely. The patterns are chosen with that price in mind
  rather than merely loosened.

  Known residual: an agent whose own last lines QUOTE the chrome — one working on
  this defect, this command, or the step that calls it — reads as
  prompt-blocked. That survives on purpose. Tightening further would mean
  guessing which occurrences of menu chrome are "really" a menu, and a wrong
  guess in that direction is the incident. It is caught cheaply instead: the step
  consuming this verdict peeks the pane before acting, so a quoted match costs
  one skipped nudge and nothing else.
