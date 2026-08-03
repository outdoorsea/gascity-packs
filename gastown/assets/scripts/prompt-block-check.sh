#!/usr/bin/env bash
# prompt-block-check.sh — is this session waiting on a HUMAN, or is it hung?
# Read-only: it peeks, classifies, prints, and exits. It never nudges, mails,
# files warrants, or sends keys — the deacon's health-scan step owns those
# decisions, exactly as it owns them for witness-heartbeat-check and
# queue-starvation-check.
#
# ## The gap it closes (gp-ha5)
#
# On 2026-08-03 tallyup/gastown.witness sat ~103 minutes parked on an interactive
# selection menu, awaiting a keystroke no unattended session will ever receive.
# Its witness duties — orphan bead recovery, polecat health monitoring — were not
# running that whole time, while tallyup had a live polecat unwatched.
#
# Detection was never the problem. witness-heartbeat-check flagged it correctly
# (stalled, 6173s, window 90m). The problem is that mol-deacon-patrol's health-scan
# offered exactly two remedies and BOTH are wrong for this cause:
#
#   * nudge — the step nudges first "so a witness that is merely wedged mid-turn
#     gets to recover on its own". But a live selection menu is not idle-prompt
#     residue. A nudge injects text into it, and the injected text lands on
#     whichever option the menu has under its cursor. On the observed menu,
#     option 1 ran `gc bd close ta-2e1p --force`. Nudging a prompt-blocked agent
#     can therefore execute a destructive action nobody authorised.
#   * warrant — the agent is alive and behaving correctly. A shutdown dance
#     discards the pending question and the reasoning that produced it, and the
#     respawned session must rediscover the same decision from scratch.
#
# The correct action is a third thing the ladder did not contain: route the
# decision to a human and leave the session alone. This check is what lets the
# deacon tell that case apart before it picks a rung.
#
# ## Why the existing signals cannot tell
#
# Session state reads `active`. LAST ACTIVE reads an hour old — that is the
# render, not progress. Only the heartbeat is stale, and a stale heartbeat is
# exactly what a genuine hang looks like too. Worse, the step's own corroboration
# rule ("prove liveness with two peeks") reads a byte-identical pair of peeks as
# evidence of a HANG — and a session parked on a menu produces byte-identical
# peeks forever, because a menu is a still image. Every generic liveness signal
# points the wrong way here. The town's human-gate machinery cannot see it either:
# notify-on-human-gate-creation and renudge-stale-human-gates watch BEADS, and
# this gate exists only as chrome inside a tmux pane.
#
# What IS mechanically distinguishable is the chrome itself. A hung pane does not
# render a menu; a menu-blocked pane does. That is the whole idea.
#
# ## Which way this check is allowed to be wrong
#
# Deliberately asymmetric, because the two errors do not cost the same thing:
#
#   * a false `prompt-blocked` on a genuinely hung session costs a DELAYED nudge.
#     The next patrol cycle looks again, and the operator the finding routes to
#     can see the pane.
#   * a false `clear` on a live menu costs an INJECTED KEYSTROKE into a menu whose
#     options run commands. That is the incident this check exists to prevent.
#
# So every uncertain path resolves away from nudging: an unreadable pane is a
# finding rather than a clearance, a missing `timeout` degrades to an unbounded
# peek rather than a skipped session, and a grep that ERRORS is separated from a
# grep that found nothing — `if grep ...` would collapse those two, and the
# collapse means an unusable pattern reports every pane `clear`. A `clear`
# verdict means "no prompt chrome was found in the tail", never "safe to nudge" —
# the deacon's own peek still outranks it, in the one direction that is safe:
# EITHER signal showing a menu is enough to stop a nudge.
#
# But asymmetric is not the same as free, and the patterns below are chosen
# rather than merely loosened. Every false `prompt-blocked` withdraws a rung the
# ladder needs: a genuinely hung witness stops getting its free nudge and waits
# for a human instead. A screen that over-fires does not fail safe, it just
# disables the ladder more politely. That is why the one prose-shaped signal was
# cut (see DEFAULT_PATTERNS) — over-firing has a real price, paid by the
# component this check is bolted onto.
#
# The known residual: an agent whose own last lines QUOTE the chrome — an agent
# working on this defect, this script, or the formula step that calls it — reads
# as prompt-blocked. That case survives on purpose. Tightening it further would
# mean guessing at which occurrences of menu chrome are "really" a menu, and a
# wrong guess in that direction is the incident. It is caught cheaply instead:
# the step that consumes this verdict must peek the pane before acting, so a
# quoted match costs one skipped nudge and nothing else.
#
# ## Why it takes explicit sessions and never sweeps
#
# `gc session peek` costs ~8 seconds per session, measured on the gascity-packs
# city (2026-08-03, 22 sessions). A no-argument sweep would therefore spend ~3
# minutes inside a patrol step — long enough to make the deacon's own heartbeat
# look stale, which is a remarkable way for a stall detector to behave. It is also
# unnecessary: the caller already holds the session list it cares about, because
# this check only ever runs on rows another check already flagged. Screening the
# whole roster to answer a question about one session is the expensive way to
# learn nothing new.
#
# ## Why one peek, not two
#
# The step's two-peek liveness rule is not reproduced here, and not by oversight.
# Two peeks discriminate progress from stillness, and BOTH answers here are still:
# a hang and a menu are equally byte-identical across peeks. The pane's chrome is
# the discriminator, and one peek carries it. A second peek would double an
# already-expensive call to re-learn nothing.
#
# Output: one TSV row per session on stdout, column header on stderr.
#
#   verdict <TAB> session <TAB> signal <TAB> evidence
#
#   prompt-blocked  the pane tail renders interactive-prompt chrome. FINDING.
#                   Do NOT nudge and do NOT warrant — route the decision to a
#                   human and leave the session running.
#   clear           no prompt chrome in the tail. The normal ladder applies.
#                   NOT an assertion that the session is healthy — this check
#                   answers one question only.
#   unreadable      the pane could not be captured or came back empty. FINDING,
#                   never a clearance: "I could not tell" must not license a
#                   nudge, because the pane it could not read may be a menu.
#
# Exit codes:  0 = every named session is `clear`
#              1 = findings on stdout (prompt-blocked and/or unreadable)
#              2 = the check could not run — no sessions named, or bad config.
#                  Nothing was measured, which is NOT a clearance either.
#
# Env:
#   GASTOWN_PROMPT_BLOCK_PATTERNS    ERE matched against the pane tail.
#                                    Default below. Extend it, never narrow it
#                                    to silence a false positive — see the
#                                    asymmetry note above.
#   GASTOWN_PROMPT_BLOCK_TAIL        pane lines from the bottom to scan (12)
#   GASTOWN_PROMPT_BLOCK_PEEK_LINES  lines to request from `gc session peek` (40)
#   GASTOWN_PROMPT_BLOCK_TIMEOUT     per-peek bound in seconds (20)
#
# Usage:
#   prompt-block-check.sh <session> [<session>...]
#   GASTOWN_PROMPT_BLOCK_TAIL=20 prompt-block-check.sh rig/gastown.witness

set -euo pipefail

# Only the TAIL of the pane is scanned, and that bound is load-bearing rather
# than a performance tweak. A pane's scrollback holds arbitrary agent output,
# including — for any agent that ever discusses this defect, this script, or the
# formula step that calls it — the literal words "Enter to select". Scanning the
# whole capture would flag the deacon for reading its own documentation. Live
# chrome is anchored to the bottom of the screen, so the bottom is where it is
# looked for.
TAIL_LINES="${GASTOWN_PROMPT_BLOCK_TAIL:-12}"
PEEK_LINES="${GASTOWN_PROMPT_BLOCK_PEEK_LINES:-40}"
PEEK_TIMEOUT="${GASTOWN_PROMPT_BLOCK_TIMEOUT:-20}"

# Three signals, all of them CHROME — pixels the TUI draws, not words an agent
# can write. Two are named in the incident report, one is structural.
#
#   Enter to select        the selection-menu footer hint
#   (↑|↓).*to navigate     the arrow-navigation footer hint
#   ❯ <digit>.             the cursor sitting ON a numbered option. This one is
#                          the version-robust member of the set: footer wording
#                          is chrome and chrome gets reworded, but a menu that
#                          does not mark its current option is not a menu. It
#                          cannot collide with the ordinary input box either —
#                          that renders `❯ ` followed by the user's text, never
#                          followed by a bare number and a dot.
#
# What is deliberately NOT here is the permission-prompt HEADLINE — `Do you want
# to proceed?` and friends. It reads like the obvious fourth signal and it is a
# trap, for a reason worth recording: it is prose-shaped, so an agent that simply
# ENDS ITS TURN asking "Do you want to proceed?" matches it. That agent then goes
# heartbeat-stale, because a finished turn is a still pane. Its false positives
# therefore correlate with the very condition being screened, which is the worst
# property a screen can have.
#
# Nothing is lost by dropping it. Claude Code's permission prompt IS a selection
# menu: it renders numbered options under a `❯` cursor, so the structural signal
# already covers it. The shape that makes a nudge dangerous — a live menu that
# binds a keystroke to a command — always carries chrome. An agent that merely
# asked a question in prose has no menu to inject into, and nudging it is both
# harmless and frequently the right move, so it must NOT be vetoed here.
DEFAULT_PATTERNS='Enter to select|(↑|↓).*to navigate|❯[[:space:]]+[0-9]+\.'
#
# `:-` rather than `-`, deliberately: an EMPTY override falls back to the
# defaults instead of matching nothing. Blanking this variable is therefore not a
# way to switch the screen off, and there is no other way either — a check that
# cannot fire reports clean forever, which is indistinguishable from a healthy
# fleet right up until a nudge lands on a live menu. Narrowing the set is still
# possible, but it takes supplying a narrower non-empty pattern, which is a
# deliberate act rather than an accidental blank.
PATTERNS="${GASTOWN_PROMPT_BLOCK_PATTERNS:-$DEFAULT_PATTERNS}"

# Validated one variable at a time rather than over a packed `NAME:value` list:
# a value containing a space would word-split that list into fragments, and the
# fragments individually validate clean. A window setting that passes its own
# check and then blows up inside `tail` is the sort of thing that gets read as a
# broken pane rather than a broken config.
require_positive_int() {
  case "$2" in
    ''|*[!0-9]*)
      echo "prompt-block-check: $1 must be a positive integer (got '$2')" >&2
      exit 2
      ;;
  esac
  if [ "$2" -le 0 ]; then
    echo "prompt-block-check: $1 must be a positive integer (got '$2')" >&2
    exit 2
  fi
}

require_positive_int GASTOWN_PROMPT_BLOCK_TAIL "$TAIL_LINES"
require_positive_int GASTOWN_PROMPT_BLOCK_PEEK_LINES "$PEEK_LINES"
require_positive_int GASTOWN_PROMPT_BLOCK_TIMEOUT "$PEEK_TIMEOUT"

if [ "$#" -eq 0 ]; then
  echo "prompt-block-check: name at least one session — this check is targeted, not a sweep" >&2
  echo "  usage: gc gastown prompt-block-check <session> [<session>...]" >&2
  echo "  Pass the sessions another check already flagged; peeking the whole roster costs ~8s per session." >&2
  exit 2
fi

# Bound each peek so one wedged pane cannot hang the patrol that called us. A
# missing `timeout` degrades to an unbounded peek rather than a skipped session:
# skipping would silently convert "not measured" into no row at all, and a
# session with no row is one the caller may nudge. Guarded the same way
# status-line.sh guards it, because macOS ships without coreutils.
#
# The bound is not theoretical. `gc session peek` HANGS — no output, no stderr,
# no exit — when it cannot resolve a city, observed 2026-08-03 by running it with
# cwd outside any city root. `gc` invokes pack commands from the city root so the
# normal path is fine, but an unbounded peek in that state would wedge the deacon
# inside a step whose entire purpose is noticing wedged agents. With the bound it
# surfaces as `unreadable`, which is a finding and correctly refuses to authorise
# a nudge.
TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_BIN="gtimeout"
fi

# `gc` is spelled literally so PATH stays authoritative. Reaching for
# ${GC_BIN:-gc} would escape a test's PATH stub onto the live city, because Gas
# Town sessions export GC_BIN as an absolute path.
peek_pane() {
  if [ -n "$TIMEOUT_BIN" ]; then
    "$TIMEOUT_BIN" "$PEEK_TIMEOUT" gc session peek "$1" --lines "$PEEK_LINES" --json 2>/dev/null
  else
    gc session peek "$1" --lines "$PEEK_LINES" --json 2>/dev/null
  fi
}

printf 'verdict\tsession\tsignal\tevidence\n' >&2

CHECKED=0
BLOCKED=0
UNREADABLE=0

for session in "$@"; do
  [ -n "$session" ] || continue
  CHECKED=$((CHECKED + 1))

  if ! PEEK=$(peek_pane "$session" </dev/null); then
    UNREADABLE=$((UNREADABLE + 1))
    printf 'unreadable\t%s\t%s\t%s\n' "$session" "peek-failed" \
      "gc session peek exited non-zero or timed out after ${PEEK_TIMEOUT}s"
    continue
  fi

  # `gc` reports a rejected flag or an unknown session by printing an
  # {"ok":false} envelope to STDOUT and exiting 0 in some paths, so the exit
  # status above is not sufficient on its own — this is the gp-b3x shape that
  # kept the deacon's starvation step from ever firing. Read the payload.
  if ! printf '%s' "$PEEK" | jq -e '(type == "object") and (.ok == true)' >/dev/null 2>&1; then
    PEEK_ERR=$(printf '%s' "$PEEK" | jq -r '.error.message // "unparseable peek payload"' 2>/dev/null) \
      || PEEK_ERR="unparseable peek payload"
    UNREADABLE=$((UNREADABLE + 1))
    printf 'unreadable\t%s\t%s\t%s\n' "$session" "peek-rejected" \
      "$(printf '%s' "${PEEK_ERR:-unparseable peek payload}" | tr '\t\n' '  ')"
    continue
  fi

  # Guarded rather than assigned bare, and not because the parse is expected to
  # fail — the `.ok == true` gate above already proved the payload is valid JSON.
  # It is guarded because this runs under `set -e`, where an unguarded failing
  # substitution would abort the WHOLE run and leave every remaining session with
  # no row at all. A session with no row is one the caller may nudge, so a
  # surprise here has to degrade into one `unreadable` row, not into silence.
  if ! OUTPUT=$(printf '%s' "$PEEK" | jq -r '.output // ""' 2>/dev/null); then
    UNREADABLE=$((UNREADABLE + 1))
    printf 'unreadable\t%s\t%s\t%s\n' "$session" "peek-unparsed" \
      "peek payload carried no readable .output"
    continue
  fi

  # Strip trailing blank lines BEFORE taking the tail. tmux pads a capture out
  # to the pane height, and counting that padding as part of the window would
  # push the footer — where the bottom-anchored signals live — out of view.
  #
  # awk rather than the usual `sed -e :a -e '/^$/{$d;N;ba' -e '}'` one-liner:
  # BSD sed rejects that block's labels-and-semicolons spelling, and the fleet
  # includes macOS.
  TRIMMED=$(printf '%s\n' "$OUTPUT" | awk '
    { buf[NR] = $0 }
    END {
      last = 0
      for (i = 1; i <= NR; i++) if (buf[i] ~ /[^ \t]/) last = i
      for (i = 1; i <= last; i++) print buf[i]
    }')

  # An all-blank capture is not a quiet pane, it is an unmeasured one.
  if [ -z "$TRIMMED" ]; then
    UNREADABLE=$((UNREADABLE + 1))
    printf 'unreadable\t%s\t%s\t%s\n' "$session" "empty-pane" \
      "peek returned no pane content"
    continue
  fi

  TAIL=$(printf '%s\n' "$TRIMMED" | tail -n "$TAIL_LINES")

  # -e so a pattern beginning with `-` is read as a pattern, not a flag, and a
  # here-string so grep never reaches for the caller's stdin.
  #
  # The exit code is captured and branched on THREE ways, not tested with `if`.
  # grep answers 0 = matched, 1 = no match, 2 = error, and the idiomatic
  # `if grep ...` collapses that last case onto "no match". Here that collapse is
  # the whole failure this check exists to prevent: an unusable pattern or a grep
  # that cannot execute would report `clear`, and `clear` is what authorises a
  # nudge into a live menu. Not evaluating the pane and finding nothing in it are
  # different answers, and only one of them is a clearance.
  GREP_RC=0
  MATCH=$(grep -n -m1 -E -e "$PATTERNS" <<<"$TAIL" 2>/dev/null) || GREP_RC=$?

  if [ "$GREP_RC" -gt 1 ]; then
    UNREADABLE=$((UNREADABLE + 1))
    printf 'unreadable\t%s\t%s\t%s\n' "$session" "match-failed" \
      "grep exited $GREP_RC — the pattern set is unusable or grep could not run; the pane was NOT evaluated"
    continue
  fi

  if [ "$GREP_RC" -eq 0 ]; then
    BLOCKED=$((BLOCKED + 1))
    # Offset from the bottom of the scanned window, so the deacon can see how
    # close to the live chrome the hit landed without re-peeking.
    HIT_LINE=${MATCH%%:*}
    HIT_TEXT=${MATCH#*:}
    WINDOW=$(printf '%s\n' "$TAIL" | wc -l | tr -d ' ')
    FROM_BOTTOM=$((WINDOW - HIT_LINE))
    printf 'prompt-blocked\t%s\t%s\t%s\n' "$session" \
      "tail-line-${FROM_BOTTOM}-from-bottom" \
      "$(printf '%s' "$HIT_TEXT" | tr '\t\n' '  ' | cut -c1-160)"
    continue
  fi

  printf 'clear\t%s\t%s\t%s\n' "$session" "no-prompt-chrome" \
    "scanned last ${TAIL_LINES} pane line(s)"
done

if [ "$CHECKED" -eq 0 ]; then
  echo "prompt-block-check: every named session was empty — nothing measured" >&2
  exit 2
fi

if [ -z "$TIMEOUT_BIN" ]; then
  echo "prompt-block-check: no timeout(1) on PATH — peeks ran unbounded" >&2
fi

echo "prompt-block-check: checked $CHECKED session(s), $BLOCKED prompt-blocked, $UNREADABLE unreadable (tail ${TAIL_LINES} line(s))" >&2

[ "$((BLOCKED + UNREADABLE))" -eq 0 ] || exit 1
exit 0
