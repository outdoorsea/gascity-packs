Reopen a source bead for a NEW round, leaving nothing from the previous round
readable as current state.

`gc workflow reopen-source` reopens a bead and clears its `assignee`. It clears
nothing else. A bead reopened for round 2 therefore still carries round 1's
refinery verdict in the CURRENT-round keys:

    merge_result            = no_patch_needs_human
    no_patch_verified       = "...confirmed zero-diff vs origin/main..."
    no_code_change          = true
    no_code_change_evidence = "...verdict=fail, recorded 2026-07-31T19:18:04Z"
    work_dir                = .../polecats/<some other agent>/worktrees/<bead>

Every one of those was true of round 1 and false of round 2, which had no
verdict at all. Anything reading them concludes "already dispositioned, empty
branch is correct, nothing to do" — exactly true of round 1, exactly false of
round 2. Zero-diff is ALSO the expected shape of a legitimately passing
validation bead, so the wrong reading is the plausible-looking one. That is the
shape that closes a P0 criterion without validating it. Observed live on ml-cmai
(PRD #261 crit:8d5572e9cf37).

The staleness is not only the verdict. CLAIM IDENTITY survives too, and it is
the more dangerous half. ml-cmai was reassigned to one agent while still
carrying `gc.session_id`/`gc.session_name` of a confirmed-dead session and a
`gc.work_dir` pointing into the worktree of the very agent its own
`validation_barred_agent` BARS from validating it. Anything resolving a working
directory from `gc.work_dir` pre-claim lands inside the barred agent's worktree
— a separation-of-duties bypass, not cosmetic drift.

Usage:
  gc gastown reopen-source <bead-id>
  gc gastown reopen-source <bead-id> --route <addr>
  gc gastown reopen-source <bead-id> --dry-run

  <bead-id>   the source bead to reopen for a new round
  --route     pool address to route to. Normally omitted — the route is
              self-derived from $GC_AGENT via agent-address.sh, which is
              environment rather than template substitution and so cannot render
              empty the way `${GC_RIG:+$GC_RIG/}{{binding_prefix}}polecat` can
              (gp-0fz). Ignored when the bead carries a validator roster.
  --dry-run   print the planned sweep and exit without touching the bead.

What it does, in order:

  1. Reads the bead's metadata (with retry — an unreadable bead is transient far
     more often than terminal, and treating a blip as "no fields to sweep" would
     produce exactly the half-swept bead this command prevents).
  2. Derives the next round number as one past the highest `round<N>.*` already
     parked, so a second reopen produces `round2.*` without overwriting
     `round1.*`.
  3. Resolves the route (see ROUTING below).
  4. `gc workflow delete-source --apply`, then `gc workflow reopen-source`.
     delete-source first, and reopen only if it succeeded: reopening a bead
     whose stale workflow subtree is still open re-races the steps being retired.
  5. ONE `gc bd update` that parks every stale field under `round<N>.*`, sets
     `gc.routed_to`, and restates `--status=open --assignee=""`. One update, not
     several — splitting the namespacing from the routing leaves a crash window
     in which the bead is open and either unroutable or still advertising the
     previous round's verdict.

The post-condition is therefore guaranteed by this command, not inherited:
**open, unassigned, routed, swept.** The status/assignee restatement is
deliberate redundancy — every caller this replaces wrote that pair explicitly,
and none documented whether it was belt-and-braces or a real backstop, so a
caller that drops it on migration must not silently get a weaker outcome.

CALLERS MUST NOT RE-ROUTE AFTERWARDS. Adding `--set-metadata gc.routed_to=...`
in a follow-up update overrides the roster check below and re-opens the
separation-of-duties hole this command closes.

Values are read back and re-injected verbatim rather than retyped:
`--set-metadata key=value` splits on the FIRST `=` only, so evidence strings
containing `verdict=fail` round-trip safely. Nothing is deleted — the previous
round stays auditable under its `round<N>.*` prefix.

SWEPT — these describe the round that just ended:

  verdict    merge_result, merged_sha, merged_target, no_patch_verified,
             no_code_change, no_code_change_evidence, no_code_change_source,
             no_code_change_cleared, false_completion_suspected, blocked_reason,
             already_delivered_suspected, awaiting_merge, awaiting_merge_since,
             awaiting_merge_since_epoch, awaiting_merge_stale, branch_ready,
             halt_reason
  identity   work_dir, gc.session_id, gc.session_name, gc.work_dir,
             polecat_session

NOT SWEPT — each survives a round boundary honestly:

  branch, fork_sha, target        the artifact the next round RESUMES. The
                                  refinery deliberately keeps the branch on
                                  reject so a new polecat can resolve the
                                  conflict.
  rejection_reason                written AFTER reopen as the next round's
                                  instruction — round-N input, not round-N-1
                                  output.
  pr_url, pr_number, existing_pr  a PR is a durable external artifact that
                                  outlives the round. Sweeping these makes
                                  round 2 open a SECOND PR for the same bead.
  recovered, parked_reset_count,  cross-round counters. The witness reads
  parked_reset_at                 `recovered` precisely to detect a crash LOOP,
                                  so namespacing it per round destroys the
                                  signal.
  eligible_validators,            the standing contract on the bead, not a
  validation_barred_agent         verdict. See ROUTING.
  gc.work_branch                  the rig's base branch (a gc-core session
                                  stamp), not claim identity.

ROUTING

Routing is folded in here rather than left to callers. `reopen-source` does not
route, so `gc.routed_to` was made a caller duty and then policed by
gastown/tests/test_pool_return_routing.sh — a test that exists because callers
forget. On ml-cmai the ENFORCED lesson took (routing was set) and the unenforced
one did not (the whole round-1 disposition survived). Same bead, same reopen,
same operator. Adding a second thing callers must remember would fail the same
way, so this command upholds both itself.

A bead carrying `eligible_validators` or `validation_barred_agent` routes to
`human`, never to the pool, and records `reopen_route_withheld` saying why. Such
a bead enforces separation of duties through its ASSIGNEE and nothing else — a
pool claim never consults `eligible_validators`. reopen-source clears that
assignee, so pool-routing it would hand the barred agent a clean path to claim
the very bead it is barred from validating. Failing closed to a human is
deliberate: picking which validator should get it is a policy call, not a sweep.

Exit codes:
  0  reopened and swept.
  1  REFUSED — nothing was reopened. Preconditions failed (unreadable bead,
     unresolvable route, or delete-source/reopen-source failed).
  2  could not run — bad arguments, missing pack context, no jq.
  3  REOPENED BUT NOT SWEPT — the reopen succeeded and the follow-up sweep did
     not. This is the one state this command exists to prevent, so it is
     reported as its own code with the exact recovery command on stderr. Never
     treat a 3 as success; the bead is now carrying a stale disposition.

Environment variables set by gc:
  GC_CITY_PATH   Absolute path to the city root
  GC_PACK_DIR    Absolute path to this pack's directory
  GC_PACK_NAME   Pack name ("gastown")
  GC_CITY_NAME   City workspace name
