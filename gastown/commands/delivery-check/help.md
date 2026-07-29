Ask whether a work bead's deliverable is ALREADY on the target branch, before
a polecat builds it.

The bead pool can go stale relative to the target branch. A second machine, an
earlier polecat, or a human lands work directly on origin/main while the bead
describing that work is still open in the pool. A polecat dispatched at that
bead takes a slot and a session, builds a deliverable that is already present,
produces a branch with an empty diff, is refused by the refinery's
`branch_has_real_change()` guard, and lands as a blocked bead on a human's desk.

That guard works. But it catches the waste at the END of the cycle, after the
slot is spent and a human decision has been manufactured. This command moves the
question to the FRONT, and answers it with positive evidence — here is the commit
that already did it — instead of the refinery's negative inference that this
branch changes nothing.

Usage:
  gc gastown delivery-check <bead-id>
  gc gastown delivery-check <bead-id> --target origin/main

Target ref resolution, in order: the `--target` flag, the bead's own
`metadata.target`, the remote's default branch, then `origin/main`. A bare
branch name resolves to `origin/<name>` when that exists, because "already
landed on main" is a question about the branch as the remote sees it — a local
`main` can trail the remote by exactly the commits this check exists to find.

Three independent signals, cheapest and strongest first:

  S1  commit  the bead id appears in a commit message reachable from the target.
              In a rig whose convention is `<type>: <subject> (<bead-id>)` this
              is near-conclusive, and it needs no verify clause, so it works on
              EVERY bead.
  S2  path    a file path named by the bead's verify clause already exists.
  S3  symbol  a code-shaped identifier from that clause is already in the
              content.

Verdicts:

  already-delivered   S1 fired: a commit on the target names this bead. HALTS.
  possibly-delivered  S1 silent, but every extracted token is already present.
                      ADVISORY ONLY — reported, but does not stop the build.
  not-delivered       evidence gathered, and it does not add up. BUILD.
  no-signal           nothing checkable. The check ABSTAINED — it did not
                      clear the bead. BUILD.

Exit codes:
  0  go build it (not-delivered, no-signal, or possibly-delivered)
  1  already-delivered — a commit on the target names this bead
  2  the check could not run — bad ref, unreadable bead, no git, no pack
     context. Delivery was NOT evaluated. Never read a 2 as a verdict.

ONLY S1 CAN STOP WORK. That asymmetry is measured (gp-nrm): across 28 real
beads the commit signal caught 8/8 already-delivered with zero false positives
on 14 open beads, while the token heuristic behind `possibly-delivered` fired
zero times. A signal that has never fired must not halt a polecat, because the
error directions are not symmetric — a MISS costs one pool slot and the
refinery's branch_has_real_change() guard still catches it, but a FALSE POSITIVE
silently drops real work. Promote S2/S3 to halting only on evidence that they
detect something S1 misses.

EVEN A HALT IS NEVER SUFFICIENT ON ITS OWN. The caller must open the cited
commit and confirm the deliverable is genuinely there before abandoning the
work. A test file named by a verify clause routinely predates the fix the bead
wants; a doc that mentions a subject is not a doc that documents it. If
confirmation is anything short of convincing, BUILD.

This command is read-only. It never updates a bead, nudges, or mails — the
`workspace-setup` step in mol-polecat-work owns those decisions.

Tuning:
  GASTOWN_DELIVERY_MIN_TOKENS  tokens required before S2/S3 may speak (default 2)
  GASTOWN_DELIVERY_MAX_TOKENS  cap on tokens checked, for cost (default 12)

Environment variables set by gc:
  GC_CITY_PATH   Absolute path to the city root
  GC_PACK_DIR    Absolute path to this pack's directory
  GC_PACK_NAME   Pack name ("gastown")
  GC_CITY_NAME   City workspace name
