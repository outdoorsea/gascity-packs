Reap per-bead polecat worktrees whose work has already landed.

Nothing in Gas Town owned a polecat worktree's death. The refinery deletes the
BRANCH after merge, not the tree. The witness removes a tree only inside orphan
recovery, which keys on a live-but-unreachable ASSIGNEE — a landed bead is
closed and unassigned, so it never enters that path. The controller manages
processes, not directories. So one worktree accumulated per completed bead,
indefinitely (measured, gascity-packs: 5 stale trees at filing, 8 two days
later, ~3/day at that throughput).

Usage:
  gc gastown worktree-reap                      # report only (dry run)
  gc gastown worktree-reap --reap               # remove what passed every check
  gc gastown worktree-reap --rig <name>         # scan a rig other than $GC_RIG
  gc gastown worktree-reap --target <ref>       # override the landed-against ref

Reporting is the default. `--reap` is the only mode that deletes anything, so
an operator can always see the verdicts before acting on them.

Scope:
  Only paths shaped `<city>/.gc/worktrees/<rig>/polecats/<agent>/worktrees/
  <bead-id>` are candidates. The parent agent workspace, the rig repo, the
  refinery workspace, and crew checkouts are never touched. Candidates come
  from `git worktree list` — the authoritative registry, and the only thing
  `git worktree remove` can act on — never from a filesystem walk.

  GC_RIG scopes the scan and is inherited from the calling shell. Unlike
  parked-check there is no town-wide mode: the reaper needs one rig's git repo
  to enumerate and remove worktrees, so a caller with no GC_RIG must pass --rig.

Output — one TSV row per candidate on stdout, verdict in column 1, header and
summary on stderr:

  verdict <TAB> bead <TAB> path <TAB> detail

  reap           every check passed; the tree is disposable. Not removed unless
                 --reap was given.
  reaped         removed (--reap).
  reap-failed    removal was attempted and did not succeed; left in place.
  keep-open      the bead is not closed. Work is in flight — including a
                 rejected bead back in the pool whose branch a later polecat
                 will resume from this very tree.
  keep-claimed   a non-closed bead points `metadata.work_dir` at this path.
  keep-cooling   closed too recently; inside the grace window.
  keep-dirty     uncommitted or untracked files are present, and every STAGED
                 blob is already carried by HEAD or the target — losing the
                 index would lose no content. The detail column names what was
                 not priced: the untracked and unstaged side is not measured.
  keep-orphaned  the same permanent refusal as keep-dirty, but this tree's index
                 holds content that is on NEITHER HEAD nor the target, or its
                 index could not be measured at all. The content may exist
                 nowhere else in the world. Reported for a human, never reaped —
                 see "Why a kept tree still gets graded" below.
  keep-unmerged  commits whose PATCHES are not on the target ref, AND which the
                 subject reconciliation below did not clear either. The detail
                 column names which signal declined, so a genuinely unpublished
                 tree reads differently from one whose patch was merely adjusted
                 on the way in.
  keep-locked    the worktree is locked.
  keep-self      the reaper is running inside this tree.
  unverifiable   the tree was NOT measured — unreadable bead, a basename that
                 fuzzy-matched a different bead, an unresolvable target ref, or
                 a failing `git status`. Never reaped.

Exit codes:
  0   Nothing to report — no candidates, or every one kept for a reason that
      needs no human.
  1   Findings on stdout (reapable, reaped, unverifiable, or orphaned).
  2   The reaper could not run — no city, no rig, unresolvable repo, or an
      unreadable worktree list. Nothing was measured. That is NOT the same as
      nothing to reap; escalate the breakage rather than recording a clean
      sweep.

Environment:
  GASTOWN_REAP_MIN_AGE_MIN   minutes since `closed_at` before a tree is
                             eligible (default: 15)
  GASTOWN_REAP_TARGET        override the target ref for every candidate

Why patch-id and not ancestry: the refinery rebases before merging, so a landed
branch's commits reach the target with DIFFERENT SHAs and
`git merge-base --is-ancestor HEAD <target>` reports NO for work that is fully
upstream. Measured on gascity-packs (2026-07-29), three landed, closed, clean
trees: gp-982 is_ancestor=YES, gp-px5 NO, gp-nrm NO — all three with zero
unmerged patches. An ancestry-keyed reaper reaps the first and leaks the other
two forever. `git cherry` compares patch-ids and sees all three as landed.

Why patch-id alone is not enough: patch-id survives a CLEAN rebase, which is
what makes it stronger than ancestry, but it does NOT survive a rebase that
CHANGES the diff — a conflict resolved by hand, a reviewer's touch-up, a
comment reflowed. What lands is a different patch, so `git cherry` reports `+`
forever and the tree is refused on every cycle the reaper will ever run.
Measured on gascity-packs (2026-07-31), three closed, clean, branch-deleted
trees whose work was demonstrably on main: gp-f4m, gp-apx, gp-q6i. gp-q6i's two
versions have IDENTICAL diffstats and differ by six bytes of reworded comment.

So a second, INDEPENDENT positive signal is consulted only after the patch
check has already refused. It does not loosen that check; it must clear on its
own terms, all three of: every flagged commit has a same-subject twin in
`merge-base(HEAD, target)..target`; each of those subjects names THIS tree's
bead; and the branch the refinery merges is absent from origin. Subjects
survive exactly what patch-ids do not — rebase rewrites the diff, never the
message — which is what makes the two signals independent rather than two
spellings of one. Requiring the bead id stops a generic subject ("fix: typo")
from matching an unrelated commit, matches are counted per distinct subject so
a tree holding two same-subject commits cannot be cleared by one landing, and
the deleted branch is the refinery's own after-merge signal. Any clause that
cannot be MEASURED — no merge base, an unreadable subject, an `ls-remote` that
failed for transport reasons rather than a missing ref — keeps the tree.

Why agent liveness is never an input: "this agent has no session, so its
workspace is garbage" is wrong in both directions, both observed live. A
rejected bead resumed by a DIFFERENT polecat keeps `metadata.work_dir` pointing
into the original polecat's workspace — gp-px5 sat in exactly that state,
in_progress with one unmerged commit, inside a workspace whose agent had no
session at all. And polecat names are recycled from the namepool, so an absent
name may be about to be reused (furiosa went from no-session to draining in
~15 minutes). The reaper keys on the BEAD's terminal state instead.

The converse — refusing to reap anything under a LIVE agent — is also rejected:
`gc session list` reports a polecat's `work_dir` as its AGENT WORKSPACE, the
parent of every per-bead tree, so keying on it would refuse every tree of every
running polecat and the leak would survive the fix. The grace window covers the
only real race, a session that has drain-acked but has not yet been killed,
using the bead's own `closed_at` rather than an inference about the agent.

Two checks carry the safety argument — `git status --porcelain` is empty, and
the work is demonstrably on the target, either by patch-id or by the subject
reconciliation above. Together they mean reaping cannot lose work. The rest
answer a different question, "is anyone still using it", and exist to protect
in-flight work that merely looks finished.

Why a kept tree still gets graded: the dirty check has no terminal exit. On a
closed, unassigned bead whose polecat is gone, `git status --porcelain` stays
non-empty forever, so the tree is refused on every cycle the reaper will ever
run and every refusal prints the same row. Keeping it is right; reporting it as
routine is not — an eternal row is indistinguishable from a tree dirty for a
boring reason, and the obvious "clean up the old worktrees" reflex then destroys
whatever it was holding. Measured on meety-local (2026-08-03), ml-cmai was
closed and unassigned with 59 staged paths; HEAD was an ancestor of origin/main
so ZERO commits were at risk, but 31 staged blobs — main.py, api.ts, three test
files — matched neither HEAD's tree nor origin/main's and existed nowhere else.

So a dirty refusal is graded by one question: is every staged blob already
carried by HEAD or the target? Staged content is the invisible half of a dirty
tree — `ls` does not show it, only the index references it, and `rm -rf` takes
it without a word. Reachability is asked tree-wide rather than per-path, because
identical bytes at another path mean the content is not lost.

This is a REPORT, not an authorisation. Both verdicts keep the tree and nothing
downstream reads the answer: the reachability test is exactly the line between a
tree that is safe to drop and one that is not, which is why it must not become a
new licence to drop one. `keep-orphaned` counts as a finding for the exit code
because an escalation that exits 0 is an escalation nobody reads.

Deciding to reap is the witness's, taken in the `reap-landed-worktrees` step of
mol-witness-patrol, which runs this command with `--reap` after orphan salvage
has already had its chance at every tree.
