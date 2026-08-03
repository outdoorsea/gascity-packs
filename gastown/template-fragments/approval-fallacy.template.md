{{ define "approval-fallacy-crew" }}
## No Approval Step

When work is done, finish the cycle. Do not summarize and wait for permission.

- Commit and push your work.
- Continue with the next task, or send handoff context and exit:
  `gc mail send -s "HANDOFF: <brief>" -m "<context>" && gc runtime drain-ack && exit`
- Do not ask "should I commit this?"
- Do not sit idle after finishing.
{{ end }}

{{ define "approval-fallacy-polecat" }}
## No Idle Polecats

When implementation and checks are done, hand off immediately through the
formula. There is no approval wait. An idle polecat blocks the refinery and
wastes the pool slot.

### The Done Sequence Lives in the Formula

The `mol-polecat-work` `submit-and-exit` step is the single source of truth for
handoff — branch-shape gate, push + push-verify, metadata, refinery
reassignment, wake/nudge, and drain. **Run that step.**

**Do NOT run submit-and-exit twice** — running the done sequence twice is a bug.
Do not trust memory for this; check mechanically. Derive the work bead exactly
as the formula's workspace-setup step does — never pass a bare or guessed id to
`bd`, which fuzzy-matches and can reassign the wrong bead. When a molecule was
poured, `$GC_BEAD_ID` is the convoy; **on a pool claim it can be empty** (gp-wqu),
in which case the branch name carries the id instead. If a clean read shows the
work bead is no longer `in_progress` for this session, submit-and-exit already
reassigned it — drain and exit. Otherwise run it:

```bash
EXPECTED_ASSIGNEE="${BEADS_ACTOR:-${GC_SESSION_NAME:-${GC_SESSION_ID:-${GC_AGENT:-}}}}"
# Resolve the bead ONCE, then retry only the read. An empty $GC_BEAD_ID is not a
# convoy blip — retrying it just re-asks a question that has no answer.
# Classify on issue_type: `gc convoy status` exits 1 both for "not a convoy"
# (an answer) and for an unreachable Dolt (a fault).
WORK_BEAD_ID=""
if [ -n "${GC_BEAD_ID:-}" ]; then
  POURED_JSON=$(gc bd show "$GC_BEAD_ID" --json 2>/dev/null)
  POURED_KIND=$(printf '%s' "$POURED_JSON" | jq -r '.[0].issue_type // empty')
  if [ "$POURED_KIND" = "convoy" ]; then
    CONVOY_STATUS=$(gc convoy status "$GC_BEAD_ID" --json 2>/dev/null)
    WORK_BEAD_ID=$(printf '%s' "$CONVOY_STATUS" | jq -r 'if (.children | length) == 1 then .children[0].id else empty end' 2>/dev/null)
  elif [ -n "$POURED_KIND" ]; then
    WORK_BEAD_ID="$GC_BEAD_ID"
  fi
fi
if [ -z "$WORK_BEAD_ID" ]; then
  # No convoy. submit-and-exit's gate guarantees `polecat/<bead-id>`, so the
  # branch names the bead. CONFIRM it — `gc bd show` fuzzy-matches ("wqu"
  # resolves to "gp-wqu"), so only an exact id echo is proof. Do NOT reach for
  # `gc hook --claim` here: if submit-and-exit already ran, the hook would hand
  # you a DIFFERENT bead and this check would evaluate the wrong one.
  BRANCH_NOW=$(git branch --show-current 2>/dev/null)
  case "$BRANCH_NOW" in
    polecat/*)
      CANDIDATE="${BRANCH_NOW#polecat/}"
      CANDIDATE_JSON=$(gc bd show "$CANDIDATE" --json 2>/dev/null)
      CANDIDATE_ID=$(printf '%s' "$CANDIDATE_JSON" | jq -r '.[0].id // empty')
      if [ "$CANDIDATE_ID" = "$CANDIDATE" ]; then
        WORK_BEAD_ID="$CANDIDATE"
      fi
      ;;
  esac
fi
# Read the work bead with retry — same unreadable-is-not-terminal discipline as
# the claim block. An unreadable state (empty JSON, a Dolt blip) is NOT proof
# that submit-and-exit already ran. Only a SUCCESSFUL read showing the bead
# genuinely moved off this session (closed, or reassigned to refinery) means it
# is done. An UNRESOLVABLE bead is likewise not proof — it falls through below.
WORK_STATUS=""
WORK_ASSIGNEE=""
READ_OK=0
READ_TRY=0
while [ -n "$WORK_BEAD_ID" ] && [ "$READ_TRY" -lt 3 ]; do
  READ_TRY=$((READ_TRY + 1))
  WORK_JSON=$(gc bd show "$WORK_BEAD_ID" --json 2>/dev/null)
  SHOW_CODE=$?
  WORK_STATUS=$(printf '%s' "$WORK_JSON" | jq -r '.[0].status // empty' 2>/dev/null)
  WORK_ASSIGNEE=$(printf '%s' "$WORK_JSON" | jq -r '.[0].assignee // empty' 2>/dev/null)
  if [ "$SHOW_CODE" -eq 0 ] && [ -n "$WORK_STATUS" ]; then
    READ_OK=1
    break
  fi
  sleep 1
done
if [ "$READ_OK" -eq 1 ] && { [ "$WORK_STATUS" != "in_progress" ] || [ "$WORK_ASSIGNEE" != "$EXPECTED_ASSIGNEE" ]; }; then
  echo "ALREADY_SUBMITTED $WORK_BEAD_ID status=$WORK_STATUS assignee=$WORK_ASSIGNEE — draining."
  gc runtime drain-ack
  exit
fi
# Unreadable after retries, or still in_progress for this session: DO NOT assume
# already-submitted — fall through and run submit-and-exit. A stranded
# in_progress bead with an unpushed branch is the worse outcome.
```

The `auto_push=false` opt-out (mol-pr-from-issue's halt-at-branch-ready) is
handled inside submit-and-exit itself: when set, it halts at branch-ready (no
push, no refinery handoff); otherwise it pushes and reassigns to the refinery.

Polecats do not push to main, close beads, create MR beads, or wait around. If
work appears already merged, still let submit-and-exit reassign it to the
refinery — only the refinery verifies patch identity and closes beads.
{{ end }}
