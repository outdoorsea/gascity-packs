Report whether a merged commit is actually live in this city.

Closing a pack bead asserts AUTHORSHIP — the patch is an ancestor of the target
branch. It says nothing about DEPLOYMENT. A city does not read the pack's default
branch; it reads a commit pinned in `packs.lock` and materialized into the
content-addressed pack cache. Advancing that pin is a separate act
(`gc import install` + `gc reload`) that no close path performs or waits for.

So "closed" and "live" are independent facts, and the ledger recorded only the
first. Three P1 fixes were closed while still live as bugs — gp-haf, gp-dlq and
gp-px5 — and read exactly like the beads beside them that were genuinely fixed.
That indistinguishability is what this command exists to remove (gp-apx).

Usage:
  gc gastown deploy-check <commit-sha> [--repo <dir>] [--stamp <bead-id>]

A fix is live only if BOTH hold:

  1. PIN CONTAINMENT      the pinned commit's history contains the fix, and
  2. ARTIFACT RESOLUTION  the installed artifact resolves to that pin, so agents
                          load it rather than an older copy.

Both are needed. gp-9pa is the case where (1) held and (2) did not: the pack
source carried gp-haf's fix while the rig's installed copy did not, so the pin
looked fine and the running witness still had the bug.

Because the check runs from inside the installed artifact (`GC_PACK_DIR`), a
`deployed` verdict means the code that just answered you is the code that
contains the fix — the assertion is self-witnessing rather than inferred.

`<commit-sha>` may be abbreviated — the examples below are. Every commit id this
command RECORDS is first resolved to its full 40-char form, because a 7-char
short SHA matching `^[0-9]+e[0-9]+$` is valid scientific notation and metadata
writers store it as a float: `6001e55` becomes `6.001e+58` and the id is gone.
1 in 53 short SHAs has that shape. An id that cannot be resolved to a commit is
reported in `deploy_reason` — which is prose, and so cannot coerce — and its
SHA field is omitted rather than written unverified (gp-prt).

Modes:
  <sha>
      Print `key=value` evidence on stdout: deploy_status, deploy_reason,
      deploy_pin, deploy_installed_sha, deploy_pack_dir, deploy_city,
      deploy_commit, deploy_checked_at.

      deploy_commit and deploy_pin appear only when that id resolved to a
      commit in the repo under test; deploy_status, deploy_reason and
      deploy_checked_at are always present.

  <sha> --stamp <bead-id>
      Write the verdict to that bead's metadata and print ONLY a close-reason
      suffix on stdout, with the evidence on stderr. Splice the suffix straight
      into a close:

        NOTE=$(gc gastown deploy-check "$MERGED_SHA" --stamp "$WORK" 2>/dev/null || true)
        gc bd close "$WORK" --reason "Merged to $TARGET at $SHORT$NOTE"

      The `|| true` is required, not defensive: a non-zero exit is a VERDICT, not
      a failure, and under `set -e` it would abort a close whose merge already
      landed.

  --repo <dir>
      The repo the commit landed in. Defaults to $GC_RIG_ROOT, then cwd.

Exit codes — the distinction is load-bearing:
  0   deployed              live in this city; both conjuncts proven.
  1   authored_not_deployed merged, but provably not live. The close still
                            happens; the bead is marked so it stays visible.
  2   undetermined          could not evaluate. Treat as NOT deployed — never as
                            deployed. A missing tool must not read as green.
  3   not_applicable        no import in this city resolves to this repo, so it
                            has no deployment story. An ordinary application rig
                            lands here, and it is a clean no-op: no suffix is
                            added to the close reason.

This command NEVER blocks a close. The merge really did land, and the refinery
cannot advance a pin, so refusing to close would jam the merge queue on every fix
and fix nothing. It records the fact instead.

Remediation when the verdict is `authored_not_deployed`:
  update the import in city.toml (or the rig's [rigs.imports] entry)
  gc import install
  gc reload

Environment:
  GC_PACK_DIR  Absolute installed pack directory (set by gc for pack commands).
               This is the artifact side of the assertion.
  GC_CITY      City root; the wrapper supplies it from the city gc resolved.
  GC_RIG_ROOT  The rig repo, used when --repo is absent.

Examples:
  # Is the commit that closed gp-px5 actually running here?
  gc gastown deploy-check 51a667b

  # Verdict only.
  gc gastown deploy-check 51a667b >/dev/null 2>&1; echo $?
