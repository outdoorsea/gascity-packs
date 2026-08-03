Report blocked beads that are still holding a worktree or pool routing.

Every step of `mol-witness-patrol` selected on open / in_progress / closed. None
enumerated `status=blocked`, so a blocked bead was invisible to the entire
patrol — including the steps whose stated purpose is finding work that fell out
of the flow (gp-6ph). A blocked bead can hold a worktree, hold stale routing, and
park indefinitely with no step responsible for noticing.

Two live examples on gascity-packs, both found only by querying `--status=blocked`
by hand, outside the formula:

  gp-yjx (P1)  blocked, unassigned, routed to human, still holding a 17M
               worktree. `recover-orphaned-beads` skips unassigned beads and
               never lists blocked. `worktree-reap` saw the tree and correctly
               refused it — `keep-open ... status=blocked; work is still in
               flight` — because it keys on the bead's terminal state and blocked
               is not terminal. Nothing was in flight. Both components behaved
               correctly and the tree was owned by nobody.
  gp-fcd (P2)  sat 5 days at `gc.routed_to=<rig>/gastown.polecat` while blocked.
               Blocked beads are not claimable, so the routing generated zero
               pool demand and was silently inert.

This command measures both shapes. It is read-only: it never mails, nudges,
reroutes, unblocks, or deletes a directory — the witness's `check-blocked-beads`
step owns those decisions.

Usage:
  gc gastown blocked-sweep
  GASTOWN_BLOCKED_PARK_ROUTES=human,operator gc gastown blocked-sweep

Output — one TSV row per blocked bead on stdout, header on stderr:

  verdict <TAB> id <TAB> priority <TAB> worktree <TAB> routed_to <TAB> title

  parked              blocked and holding nothing. Healthy, never flagged. A
                      parked bead is what a deliberate hold looks like, and
                      flagging it is how a sweep gets muted.
  holding-worktree    `metadata.work_dir` names a directory that EXISTS. Finding.
  inert-routing       `gc.routed_to` points at a pool, which cannot claim a
                      blocked bead. Finding.
  stale-worktree-ref  `metadata.work_dir` is set but the directory is gone.
                      Reported, not a finding — the tree is already collected and
                      a dangling pointer harms nothing.

  One row per bead. When a bead trips both finding axes the verdict names the
  worktree, because disk is the scarcer resource and the tree outlives the
  routing — but the `routed_to` column still carries the pool and the stderr
  summary counts both axes independently, so neither hides behind the other.

Park routes:
  GASTOWN_BLOCKED_PARK_ROUTES   comma-separated `gc.routed_to` values meaning
                                "a human is holding this on purpose"
                                (default: human)

  Matched case-insensitively. Everything else non-empty is a pool address and is
  reported as inert.

Report-only, deliberately:

  `blocked` + `gc.routed_to=human` is frequently a DELIBERATE park (the
  2026-08-03 mayor standing rule on gastownhall/gascity deliverables).
  Auto-rerouting it would resume work an operator explicitly stopped — strictly
  worse than the gap being closed, because it overrides a stated intent rather
  than a forgotten one.

  A blocked bead's worktree may also hold the only copy of unpushed work.
  Deciding whether a tree is safe to remove belongs to `worktree-reap`, whose
  safety argument — `git status --porcelain` empty AND `git cherry` reporting no
  `+` commits — is documented as one not to hand-roll. This command asks only
  whether the directory exists. Visibility is the deliverable: the tree was
  invisible, not un-reapable.

No staleness window, deliberately:

  Unlike `queue-starvation-check`, there is no age threshold. Both findings are
  wrong from the moment they are written — a blocked bead's pool routing
  generates zero demand on day 0, and a tree owned by no step is orphaned on
  day 0. gp-fcd's five days measure how long the gap hid it, not how long it had
  to sit before becoming a defect.

Exit codes:
  0  no findings (every blocked bead parked, or none at all)
  1  findings on stdout (holding-worktree / inert-routing)
  2  the check could not run — blocked beads were NOT measured, which is NOT
     health

  The 2 carries real weight here. This command queries the one status Gas Town
  had never queried, so its server-side filter has no operational history behind
  it. The check re-asserts that every row it got back really is blocked and
  exits 2 if not: a filter silently ignored would deliver the whole ledger and
  classify it, turning a targeted sweep into a flood of false findings. A
  detector inventing a query must verify the query did what it asked.
