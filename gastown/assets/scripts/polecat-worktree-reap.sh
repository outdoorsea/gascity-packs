#!/usr/bin/env bash
# polecat-worktree-reap.sh — reap per-bead polecat worktrees whose work has
# already landed. Reports by default; removes only under --reap.
#
# The leak it closes (gp-a7z): no component owned a polecat worktree's death.
# The refinery deletes the BRANCH after merge, not the tree. The witness removes
# a tree only inside orphan recovery, which keys on a live-but-unreachable
# ASSIGNEE — a landed bead is closed and unassigned, so it never enters that
# path. The controller manages processes, not directories. Result: one worktree
# per completed bead, accumulating forever (measured: 5 trees at filing, 8 two
# days later, ~3/day at that throughput).
#
# ## What makes a tree disposable
#
# Gas Town's canonical work chain is `worktree -> (push) -> branch -> (merge) ->
# target`. Each transition moves the canonical copy forward and makes the
# previous location disposable. The question a reap turns on is therefore "is
# this directory still the only copy?" — not "did the work reach the target".
# The two coincide for work that merges, which is why the target was the
# original test; they come apart for work that never will, which is the leak
# C6c closes.
#
# Two checks carry the safety argument. They are the ones that answer "can
# reaping this directory lose work?":
#
#   C5 clean      `git status --porcelain` is empty — nothing uncommitted or
#                 untracked is sitting in the tree.
#   C6 upstream   `git cherry <target> HEAD` reports no `+` commits — every
#                 local commit's PATCH is already on the target.
#
# C6b and C6c are the two fallbacks consulted only after C6 has refused, and
# each clears on its own terms: C6b that the work landed on the target with its
# patch adjusted on the way in, C6c that the work is on origin whether or not it
# ever landed. C6c is the weaker guarantee and says so in its evidence.
#
# C5b is a third check but NOT a third clearance: it grades a tree C5 has already
# refused, so an operator can tell an eternal refusal holding unrecoverable
# content from one holding scratch. It can only ever change which refusal is
# printed. See its section below.
#
# The remaining checks answer a different question — "is anyone still using
# it?" — and exist to protect in-flight work that happens to look finished:
#
#   C1 identity   the path has the per-bead shape and its basename resolves to
#                 an EXACTLY matching bead id.
#   C2 terminal   that bead is closed.
#   C3 unclaimed  no non-closed bead points `metadata.work_dir` at this path.
#   C4 cool       the bead closed at least $GASTOWN_REAP_MIN_AGE_MIN ago.
#
# ## C6 uses patch-id, never ancestry
#
# `git merge-base --is-ancestor HEAD <target>` is the wrong test and would keep
# the leak open. The refinery rebases before merging, so a landed branch's
# commits are on the target with DIFFERENT SHAs. Measured on this rig
# (2026-07-29), three landed, closed, clean trees:
#
#   gp-982  is_ancestor=YES  unmerged_patches=0
#   gp-px5  is_ancestor=NO   unmerged_patches=0
#   gp-nrm  is_ancestor=NO   unmerged_patches=0
#
# An ancestry-keyed reaper reaps the first and leaks the other two forever.
# `git cherry` compares patch-ids, so it sees all three as landed. (The same
# trap in the other direction is why gp-zs8 stopped inferring a queue bypass
# from ancestry.)
#
# ## C6b: patch-id is not stable when the patch is ADJUSTED on the way in
#
# Patch-id survives a CLEAN rebase — same diff, new SHA — which is exactly what
# makes C6 stronger than ancestry. It does NOT survive a rebase that CHANGES
# the diff: a conflict resolved by hand, a reviewer's touch-up applied before
# the merge, a comment reflowed. What lands is a different patch, so its
# patch-id differs, so `git cherry` reports `+` forever and the tree is refused
# on every cycle the reaper will ever run. Measured on this rig (2026-07-31),
# three closed, clean, branch-deleted trees whose work was demonstrably on main:
#
#   gp-f4m  6801256 landed as 43d1eda
#   gp-apx  13629aa landed as 8107684
#   gp-q6i  43004be landed as c42e259
#
# gp-q6i's two versions have IDENTICAL diffstats and differ by six bytes of
# reworded comment — enough to move the patch-id from 0664cd18 to 95d6a2dd. So
# this is not an exotic conflict case: any edit at all on the way in does it,
# and review touch-ups are routine.
#
# That makes patch-id the THIRD identity notion to break against a rebasing
# merge queue, after SHA ancestry (gp-a7z) and commit shape (gp-zs8). So C6b
# does not replace C6 or loosen it. It is an ALTERNATIVE positive signal,
# consulted only after C6 has already refused, and it must clear on its own
# terms — all three of:
#
#   * every commit C6 flagged has a same-subject twin in the window
#     merge-base(HEAD, target)..target;
#   * each of those subjects carries a WORK REFERENCE (see below);
#   * the refinery independently attests that it merged this bead — either the
#     branch it merges is absent from origin, or the bead records a
#     `merged_sha` that is verifiably present on the target.
#
# Each clause carries weight. Subjects survive a rebase exactly when patch-ids
# do not — rebase rewrites the diff, never the message — which is what makes
# the two signals independent rather than two spellings of one. The window
# starts at the merge base because a landing can only be on the target AFTER
# the tree branched, which also bounds the walk. Matches are counted per
# distinct subject rather than merely existence-checked, so a tree holding two
# same-subject commits cannot be cleared by a single landing.
#
# ### The anchor is a work reference, not a bead id (gp-psa)
#
# The anchor exists to stop a generic subject ("fix: typo") from being cleared
# by an unrelated commit that happens to share it. Its first spelling got that
# intent right and the mechanism wrong: it required the tree's own BEAD ID
# inside the subject, on the grounds that "the polecat formula mandates that
# spelling". The formula mandates it for THIS rig. This script is a pack asset
# that runs in every rig, and meety-local stamps a criterion hash instead —
# `feat(portal): ... (crit:c84a4764d9a1)`, never a bead id. There the anchor
# vetoed 100% of C6b, so the fallback was dead code in the rig, and ml-uoa.3's
# tree was refused every cycle with its work byte-identically on main.
#
# What actually carries the weight is an explicit work reference: a trailing
# parenthesised token, spaceless and internally structured (a `-` or a `:`),
# which is how every convention in use spells "this commit belongs to that unit
# of work" — `(gp-psa)`, `(crit:c84a4764d9a1)`, `(ml-uoa.3)`. The trailer must
# END the subject, so a conventional-commit SCOPE (`feat(router-portal): ...`)
# is not mistaken for one. Prose in parentheses ("(see below)") and bare words
# ("(wip)") are deliberately not references: they recur, which is the hazard.
# The tree's own bead id still qualifies wherever it appears, so a subject that
# names the bead outside a trailer clears exactly as it did before.
#
# ### Merge attestation: branch-absence is a proxy, merged_sha is the record
#
# The deleted origin branch is the refinery's own after-merge signal — an
# independent witness that a merge happened, not a restatement of the subject
# match. It is REQUIRED for C6b, which is why it is not enough to match a
# subject. But it is a PROXY: it infers a merge from the absence of a ref, and
# it silently stops being available wherever post-merge branch deletion is not
# running. That deletion lives in mol-refinery-patrol's Cleanup step behind
# `delete_merged_branches`, which defaults to "true" — and measured 2026-07-31
# it is nonetheless not happening: meety-local carries 60 undeleted
# `origin/polecat/*` refs and tallyup 53, including beads reaped days earlier.
# In those rigs C6b could never clear anything even with a matching subject —
# the reaper was coupled to a cleanup step in another component, so a lapse
# there parked trees here, silently and forever.
#
# `metadata.merged_sha` is the same fact recorded first-hand by the agent that
# did the merge, and unlike the proxy it can be CHECKED: the sha must resolve
# and must be present on the target. A stale, bogus, or force-pushed-away sha
# fails that check and keeps the tree. Ancestry is the right test HERE, though
# it is the wrong test for C6 — merged_sha names the commit the refinery
# created ON the target, so there is no rebase between it and the target for
# ancestry to be confused by. Either attestation satisfies the clause; neither
# is inferred, and the per-commit subject check above still runs regardless, so
# broadening this conjunct never clears a commit whose content is unaccounted
# for. Verified against both live trees: ml-uoa.3 (merged, reapable) records
# merged_sha=2c6abe5, an ancestor of main, while ml-94dh (recalled by its owner,
# must be kept) records none at all and so stays kept on this clause alone.
#
# Both conjuncts had to move. On ml-uoa.3 the anchor vetoed the subject clause
# AND origin/polecat/ml-uoa.3 was still present, so relaxing either one alone
# would only have shifted the tree from the first refusal arm to the second —
# same leaked directory, a differently-worded row.
#
# The refusal direction is preserved throughout: any clause that cannot be
# MEASURED — no merge base, an unreadable subject, an `ls-remote` that failed
# for transport reasons rather than a missing ref — keeps the tree. And every
# refusal NAMES the clause that declined, because a `keep-unmerged` row that
# asserts "no same-subject landing there either" when one demonstrably exists
# reads as the reaper working correctly, which is how this leak survived three
# patrol cycles unnoticed.
#
# ## C5b: a REFUSED tree still has to be triageable (gp-dgu)
#
# C5 has no terminal exit. On a closed, unassigned bead whose polecat is gone,
# `git status --porcelain` stays non-empty forever, so the tree is refused on
# every cycle the reaper will ever run and every refusal prints the same
# `keep-dirty` row. The refusal is CORRECT — keeping the tree is the whole point.
# Reporting it as routine is not: an eternal row is indistinguishable from a tree
# that is dirty for a boring reason, and the obvious "clean up the old worktrees"
# reflex then destroys whatever it was holding.
#
# Measured instance, meety-local/ml-cmai (read-only, 2026-08-03): closed, no
# assignee, its agent gone, 59 staged paths. HEAD was an ancestor of origin/main,
# so ZERO commits were at risk — but 31 staged blobs matched neither HEAD's tree
# nor origin/main's. main.py, admin.py, api.ts and three test files existed
# nowhere else in the world, behind a row that read like garbage.
#
# So C5b asks the one question separating a tree whose loss costs nothing from a
# tree whose loss is unrecoverable: is every STAGED blob already carried by
# HEAD's tree or the target's? Staged content is the invisible half of a dirty
# tree — `ls` does not show it, only the index references it, and `rm -rf` takes
# it without a word.
#
#   keep-dirty     dirty, but every staged blob is already on HEAD or the target
#                  (or nothing is staged). Losing the index loses no content.
#   keep-orphaned  a staged blob is on NEITHER, or the index could not be
#                  measured. Content may exist only here.
#
# THIS IS A REPORT, NOT AN AUTHORISATION. Both verdicts keep the tree, C5 still
# `continue`s before any reap logic is reachable, and nothing downstream consults
# the result — the reachability answer is exactly the line between a tree that is
# safe to drop and one that is not, which is why it must not become a new licence
# to drop one. `keep-orphaned` exists to make a human look, which is why it
# counts as a finding for the exit code: an escalation that exits 0 is an
# escalation nobody reads.
#
# The probe covers the INDEX only, and the row says so. Untracked and unstaged
# content also keeps the tree via C5, but pricing it means hashing every
# untracked file — an unbounded walk on any tree carrying a node_modules,
# charged to every patrol. `git diff-index --cached --raw` hands back index blob
# shas directly, so the measurement costs one command bounded by index size and
# hashes nothing. The row prints the total dirty count next to the staged
# measurement so what was NOT priced stays visible rather than reading as a clean
# bill of health.
#
# ## C6c: the tree is disposable once the work is PUBLISHED, not only once it
# ##      is MERGED (gp-qmd, widened by gp-98n)
#
# C6 and C6b both answer "did this work reach the target?". That is a proxy for
# the question reaping actually turns on — "is this directory still the only
# copy?" — and for a whole class of bead the proxy can never be satisfied,
# because the work is never going to the target at all. Its `git cherry` reports
# `+` on every cycle forever, no predicate in the script can ever collect the
# tree, and nothing else in the city owns that directory's death. It leaks
# permanently — the gp-a7z shape reached by a different route.
#
# So C6c does not ask about the target. It asks the question directly:
#
#   the tree is CLEAN, and every local commit is reachable from the bead's
#   branch on origin => the directory is redundant, whatever became of the work.
#
# PUBLICATION is that measurement, and it is exact:
#
#   * `ls-remote` the bead's own `metadata.branch` — a LIVE query, never a
#     remote-tracking ref. A stale `origin/*` ref left behind by a deleted
#     branch would claim publication for work that is no longer on origin, which
#     is the one direction this script never fails in;
#   * HEAD must be contained in the tip that query returns. Every commit C6
#     flagged is reachable from HEAD, so containment covers all of them at once,
#     and a tree holding local commits past the pushed tip fails it;
#   * the tip must come from the EXACT ref (see origin_branch_probe) — a pattern
#     match on a decoy is not a publication.
#
# Both facts come from the same `ls-remote` C6b already runs for its merge
# attestation, so this costs no extra network call.
#
# ### Why disposition is NOT a second conjunct (gp-98n)
#
# C6c shipped requiring publication AND a RECALL — `do_not_merge` or
# `recalled_by_owner` on the closed bead — on the argument that publication
# alone would reap against `origin/polecat/*`, a transient handoff artifact that
# mol-refinery-patrol's Cleanup deletes after a merge.
#
# That conjunct was dropped, on evidence and on principle.
#
# On EVIDENCE: those two flags are not the only way a bead becomes terminal, and
# the leak survived the conjunct by exactly one metadata key. Measured live
# 2026-08-04, meety-local, both clean, both closed, both refused every cycle:
#
#   ml-94dh  50M  gc.work_outcome=no-op      a6ec0cb == origin/polecat/ml-94dh
#   ml-apes  55M  gc.work_outcome=abandoned  5a88f5e == origin/polecat/ml-apes
#
# ml-apes carries NEITHER recall flag, so the recall conjunct vetoed it and 55M
# of provably-redundant disk stayed parked. Enumerating the dispositions that
# mean "this will never merge" is a losing game — each new spelling reopens the
# leak silently, and reading them correctly is a dependency on another
# component's vocabulary. Redundancy is measurable without asking why.
#
# On PRINCIPLE: the branch-deletion objection does not survive being made
# precise. The deleter named is the refinery's POST-MERGE cleanup, which removes
# a branch only once its content is on the target — a protected ref. So the
# sequence "C6c reaps a published tree, refinery later deletes the branch"
# leaves the content on the target, never nowhere. The hazard would be a sweep
# that deletes UNMERGED branches, and that is a sequencing constraint on such a
# sweep rather than a property this script can assert: gp-98n is recorded as
# BLOCKING gp-9yg (bulk deletion of stale `origin/polecat/*`) for exactly that
# reason. Deleting origin/polecat/ml-apes first would strand 5a88f5e in a
# detached-HEAD tree the reaper still refuses — converting a redundant tree into
# a unique-content one.
#
# What was load-bearing in the old conjunct is kept, and it was never the flags:
# it is that publication must be MEASURED. Every refusal direction below is
# unchanged — an absent branch, a tip that does not contain HEAD, a decoy ref, a
# transport failure — because each of those means the tree may hold the only
# copy. Only the "and the bead said it would never merge" clause is gone.
#
# C6c still reaps on a WEAKER guarantee than C6/C6b, and its evidence string
# says so rather than letting `reap` imply a merge. What it guarantees is
# redundancy: the directory can be reconstructed with `git fetch` +
# `git worktree add`.
#
# RECALL survives as description, not authorisation. A recalled tree that is NOT
# published stays kept — correctly, it is the only copy — and its row says the
# bead can never merge and no predicate can ever collect it, so an operator can
# dispose of it instead of reading the row as a merge still pending. See
# recall_note.
#
# ### "Unpublished" is a claim that must be measured before it is printed
#
# `keep-unmerged` used to end with "work looks genuinely unpublished" whenever
# the subject check declined. On ml-94dh that sentence was FALSE: the branch sat
# on origin at the identical sha. It is also the sentence an operator reads when
# deciding whether removing a tree is safe, so it was wrong in the reassuring
# direction — and the identical wording would understate the risk on a tree that
# really was the only copy. The reaper was measuring reachability from the
# TARGET and reporting it as publication. Every refusal now carries the
# publication fact it actually measured, including "NOT measured" when the
# probe could not run.
#
# ## Why agent liveness is never an input
#
# The obvious predicate — "this agent has no session, so its workspace is
# garbage" — is wrong twice over, both observed live (gp-a7z notes):
#
#   1. A rejected bead returns to the pool and is resumed by a DIFFERENT
#      polecat, while `metadata.work_dir` still points into the original
#      polecat's workspace. gp-px5 was in exactly that state — in_progress,
#      one unmerged commit, inside a workspace whose agent had no session at
#      all. A liveness-keyed reaper would have destroyed it. Here C2 and C6
#      both refuse it.
#   2. Polecat names are recycled from the namepool. gascity-packs/gastown
#      .furiosa went from "no session" to state=draining within ~15 minutes.
#      An absent name is not evidence its workspace is garbage.
#
# The converse — refusing to reap anything under a LIVE agent, which the
# original bug report suggested — is also rejected, for a quieter reason:
# `gc session list` reports a polecat's `work_dir` as its AGENT WORKSPACE
# (`polecats/<agent>`), the PARENT of every per-bead tree. Keying on it would
# refuse every tree belonging to any running polecat, which is most of them,
# and the leak would survive the fix. C4's grace window covers the only real
# race here — a session that has drain-acked but not yet been killed — using
# the bead's own `closed_at` rather than an inference about the agent.
#
# ## Scope: per-bead trees only
#
# Only paths shaped `<city>/.gc/worktrees/<rig>/polecats/<agent>/worktrees/
# <bead-id>` are candidates. The parent agent workspace (`polecats/<agent>`),
# the rig repo, the refinery workspace, and crew checkouts are never touched —
# they are long-lived, they hold no per-bead work, and an agent whose workspace
# vanished mid-session is a much worse outcome than a leaked directory.
#
# Candidates come from `git worktree list`, not a filesystem walk: the git
# registry is the authoritative record, `git worktree remove` can only act on
# what it lists, and a wide `find` under $HOME trips macOS TCC prompts.
#
# Output: one TSV row per candidate on stdout, verdict in column 1, header and
# summary on stderr.
#
#   reap          <TAB> <bead> <TAB> <path> <TAB> <evidence>
#   reaped        <TAB> <bead> <TAB> <path> <TAB> <what was removed>   (--reap)
#   reap-failed   <TAB> <bead> <TAB> <path> <TAB> <error>              (--reap)
#   keep-open     <TAB> <bead> <TAB> <path> <TAB> status=<status>
#   keep-claimed  <TAB> <bead> <TAB> <path> <TAB> claimed by <bead>
#   keep-cooling  <TAB> <bead> <TAB> <path> <TAB> closed <n>m ago
#   keep-dirty    <TAB> <bead> <TAB> <path> <TAB> <n> uncommitted paths, none of
#                 whose staged content is missing from HEAD or the target
#   keep-orphaned <TAB> <bead> <TAB> <path> <TAB> closed <age>, <owner>, <n>
#                 staged, <n> blobs unreachable from HEAD or the target — or
#                 why the index could NOT be measured. Kept, like every other
#                 keep-*; escalated, unlike every other keep-*.
#   keep-unmerged <TAB> <bead> <TAB> <path> <TAB> <n> patches not on <target>,
#                 plus why C6b did not clear it either, plus the MEASURED
#                 publication state that C6c also declined on — so a tree that
#                 really is the only copy is distinguishable from a near-miss,
#                 and from one whose publication simply could not be measured
#   keep-locked   <TAB> <bead> <TAB> <path> <TAB> worktree is locked
#   keep-self     <TAB> <bead> <TAB> <path> <TAB> we are running inside it
#   unverifiable  <TAB> <bead> <TAB> <path> <TAB> <why it was NOT measured>
#
# `unverifiable` is never reaped. A tree whose bead cannot be read, whose id
# does not match, or whose target ref does not resolve has not been cleared —
# it has been ABSTAINED on. Reaping on an unreadable state is how a reaper
# eats real work; the leak is the cheaper failure.
#
# Exit codes:  0 = nothing to report (no candidates, or every one kept for a
#                  reason that needs no human)
#              1 = findings on stdout (reapable, reaped, unverifiable, or
#                  orphaned)
#              2 = the check could not run — nothing was measured, which is
#                  NOT the same as nothing to reap
#
# Env:
#   GC_CITY                      city root (auto-discovered by walking up)
#   GC_RIG                       rig to scan (required unless --rig is given)
#   GASTOWN_REAP_MIN_AGE_MIN     minutes since closed_at before a tree is
#                                eligible (default: 15). Covers the window
#                                between a polecat's drain-ack and the
#                                controller actually killing its session.
#   GASTOWN_REAP_TARGET          override the target ref for every candidate
#
# Usage:
#   polecat-worktree-reap.sh                     # report only (dry run)
#   polecat-worktree-reap.sh --reap              # remove what passed
#   polecat-worktree-reap.sh --rig gascity-packs --target origin/main

set -euo pipefail

ME=polecat-worktree-reap

DO_REAP=0
RIG="${GC_RIG:-}"
TARGET_OVERRIDE="${GASTOWN_REAP_TARGET:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --reap) DO_REAP=1; shift ;;
    --rig)
      [ $# -ge 2 ] || { echo "$ME: --rig needs a rig name" >&2; exit 2; }
      RIG="$2"; shift 2 ;;
    --rig=*) RIG="${1#--rig=}"; shift ;;
    --target)
      [ $# -ge 2 ] || { echo "$ME: --target needs a ref" >&2; exit 2; }
      TARGET_OVERRIDE="$2"; shift 2 ;;
    --target=*) TARGET_OVERRIDE="${1#--target=}"; shift ;;
    -h|--help)
      # Print the header block by SHAPE, not by line number: every comment line
      # after the shebang, stopping at the first line that is not one. A magic
      # `2,126p` range silently truncates or overruns the moment the header
      # grows, and this header is where the whole safety argument lives.
      awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
      exit 0 ;;
    *) echo "$ME: unexpected argument '$1'" >&2; exit 2 ;;
  esac
done

MIN_AGE_MIN="${GASTOWN_REAP_MIN_AGE_MIN:-15}"
case "$MIN_AGE_MIN" in
  ''|*[!0-9]*)
    echo "$ME: GASTOWN_REAP_MIN_AGE_MIN must be a non-negative integer (got '$MIN_AGE_MIN')" >&2
    exit 2 ;;
esac
MIN_AGE_SECS=$((MIN_AGE_MIN * 60))

# Resolve city root: env wins, else walk up from cwd looking for city.toml.
if [ -z "${GC_CITY:-}" ]; then
  dir=$(pwd)
  while [ "$dir" != "/" ]; do
    if [ -f "$dir/city.toml" ]; then GC_CITY="$dir"; break; fi
    dir=$(dirname "$dir")
  done
fi
if [ -z "${GC_CITY:-}" ] || [ ! -f "$GC_CITY/city.toml" ]; then
  echo "$ME: GC_CITY not set and no city.toml found — nothing was measured" >&2
  exit 2
fi

# Resolve the city to its PHYSICAL path. `git worktree list` always reports
# resolved paths, so a city reached through a symlink (a symlinked $HOME, a
# city under /tmp on macOS where /tmp -> /private/tmp) makes the shape filter
# below match nothing at all. That failure is silent and reads exactly like a
# clean city: "no candidates", exit 0. Every path compared in this script is
# physical on both sides.
GC_CITY=$(cd "$GC_CITY" && pwd -P)

if [ -z "$RIG" ]; then
  echo "$ME: no rig to scan. Set GC_RIG or pass --rig <name>." >&2
  exit 2
fi

# The rig's main repo is where `git worktree list` and `git worktree remove`
# must run — remove refuses to operate from inside the tree it is deleting.
REPO=$(gc rig list --json 2>/dev/null \
  | jq -r --arg r "$RIG" '(.rigs // [])[] | select(.name == $r) | .path // empty' 2>/dev/null || true)
if [ -z "$REPO" ] || { [ ! -d "$REPO/.git" ] && [ ! -f "$REPO/.git" ]; }; then
  echo "$ME: could not resolve a git repo for rig '$RIG' (got '${REPO:-}') — nothing was measured" >&2
  exit 2
fi

RIG_WORKTREES="$GC_CITY/.gc/worktrees/$RIG"

# `date -u +%s` is epoch seconds — identical on every host regardless of $TZ.
# Every comparison below is between two such integers; no formatted local-time
# string is ever compared, which is the gp-9ly defect.
NOW=$(date -u +%s)

# ts_epoch — RFC3339 timestamp to epoch seconds, printing 0 for "no usable
# signal": empty, null, or the Go zero-time sentinel bd emits for an unset
# field. 0 means unknown, never "ancient". Shared idiom with
# polecat-progress-check.sh: GNU `-d` first, BSD `-j -f` second.
#
# The BSD arm strips the colon out of a `±HH:MM` offset as well as rewriting `Z`,
# because BSD `%z` accepts only the compact RFC822 spelling. `bd` stamps closed_at
# in Z form today, so this arm is not currently reached with an offset and the
# rewrite is a no-op here — it is carried anyway because gp-ra8 was exactly this
# line failing in witness-heartbeat-check.sh, where the input DOES arrive as
# `-07:00` from `gc session list`. The two producers already disagree on spelling,
# so leaving the identical helper unhardened here just parks the same silent
# 0-means-unknown misread behind a future field change.
ts_epoch() {
  local ts="$1" norm epoch
  case "$ts" in
    ''|null|0001-*) printf '0'; return 0 ;;
  esac
  norm=$(printf '%s' "$ts" | sed -E 's/\.[0-9]+(Z|[+-][0-9:]+)?$/\1/')
  epoch=$(date -u -d "$norm" +%s 2>/dev/null) \
    || epoch=$(date -u -j -f '%Y-%m-%dT%H:%M:%S%z' \
                 "$(printf '%s' "$norm" | sed -e 's/Z$/+0000/' \
                    -e 's/\([+-][0-9][0-9]\):\([0-9][0-9]\)$/\1\2/')" +%s 2>/dev/null) \
    || epoch=''
  case "$epoch" in
    ''|*[!0-9]*) printf '0'; return 0 ;;
  esac
  printf '%s' "$epoch"
}

row() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4"; }

# normalize_target — submit-and-exit records `metadata.target` as a bare branch
# name ("main"), but a patch-id comparison must run against the REMOTE tip; the
# local branch in a stale worktree lags by definition. Anything already
# qualified is passed through untouched so `integration/<convoy>` bases and
# explicit refs still work.
normalize_target() {
  case "$1" in
    '') printf '' ;;
    origin/*|refs/*) printf '%s' "$1" ;;
    *) printf 'origin/%s' "$1" ;;
  esac
}

# resolve_target — the ref a tree's work is measured against: the CLI override,
# else the bead's own `metadata.target`, else the tree's origin HEAD, else
# origin/main. Pure resolution — it never verifies the ref, because C5b and C6
# want the same ref but do NOT agree on what an unresolvable one means (C5b
# grades a refusal, C6 abstains from a clearance). Shared so the two checks can
# never silently drift onto different targets and report contradictory rows for
# one tree.
resolve_target() {
  local wt="$1" meta_target="$2" t
  t=$(normalize_target "${TARGET_OVERRIDE:-$meta_target}")
  if [ -z "$t" ]; then
    t=$(git -C "$wt" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
    [ -n "$t" ] || t=origin/main
  fi
  printf '%s' "$t"
}

# age_brief — seconds to a coarse human duration for a triage row. Minutes below
# an hour, hours below two days, days beyond. The reader's question is "has this
# been sitting here long enough to be someone's forgotten problem", which no
# amount of precision answers better than "3d" does.
age_brief() {
  local s="$1"
  if [ "$s" -lt 3600 ]; then printf '%dm' "$((s / 60))"
  elif [ "$s" -lt 172800 ]; then printf '%dh' "$((s / 3600))"
  else printf '%dd' "$((s / 86400))"
  fi
}

# staged_reachability — C5b. Of the blobs this tree has STAGED, how many exist
# nowhere but here? See the C5b section in the header for why a refused tree
# still needs grading and why the probe stops at the index.
#
# Sets STAGED_TOTAL, STAGED_DELETIONS and STAGED_UNREACHABLE on success. Returns
# non-zero when the answer was NOT measured, with REACH_WHY naming what
# declined — the caller must not read the counters in that case, and must not
# report the tree as routine either.
#
# "Reachable" is: the exact blob appears somewhere in HEAD's tree or somewhere in
# the target's tree. Tree-wide rather than same-path, because the operator's
# question is "does this content still exist if I delete the directory", and
# identical bytes at another path answer it yes. Comparing per-path would report
# a moved file as unrecoverable and inflate exactly the alarm this check exists
# to make meaningful.
staged_reachability() {
  local wt="$1" target="$2"

  STAGED_TOTAL=0
  STAGED_DELETIONS=0
  STAGED_UNREACHABLE=0
  REACH_WHY=''

  # An unborn HEAD means there is no baseline to diff the index against. Rather
  # than treat every staged path as unreachable on a technicality, abstain and
  # say so — the tree is kept either way, and a named abstention is auditable
  # where an inferred alarm is not.
  if ! git -C "$wt" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
    REACH_WHY="this tree has no HEAD commit, so the index has no baseline to be measured against"
    return 1
  fi

  if ! git -C "$wt" diff-index --cached --raw HEAD >"$STAGED_RAW_FILE" 2>/dev/null; then
    REACH_WHY="'git diff-index --cached HEAD' failed here; the index was NOT read"
    return 1
  fi

  # An empty index diff is a complete answer on its own: no staged blob can be
  # unreachable when there is no staged blob. Returning here keeps the common
  # case — a tree dirty only with untracked scratch — off two `ls-tree` walks,
  # and stops a target that happens not to resolve from escalating a tree whose
  # index was never in question.
  if [ ! -s "$STAGED_RAW_FILE" ]; then
    return 0
  fi

  # A target that does not resolve halves the reachable universe, which would
  # report blobs that ARE on the target as existing nowhere. Refuse to measure
  # rather than measure against HEAD alone and present the shortfall as
  # unrecoverable content.
  if ! git -C "$wt" rev-parse --verify --quiet "$target^{commit}" >/dev/null 2>&1; then
    REACH_WHY="target ref '$target' does not resolve here, so reachability could only have been half-measured"
    return 1
  fi

  # Every blob the two surviving refs already carry. `ls-tree -r` is filtered on
  # the literal type column rather than trusted positionally, so a submodule
  # (`commit`) or a subtree entry can never be mistaken for file content.
  : >"$REACH_BLOBS_FILE"
  local ref
  for ref in HEAD "$target"; do
    if ! git -C "$wt" ls-tree -r "$ref" >"$LS_TREE_FILE" 2>/dev/null; then
      REACH_WHY="could not read $ref's tree; reachability was NOT measured"
      return 1
    fi
    # Guarded rather than bare: this function is called from an `if !`, which
    # disables `set -e` for its whole body, so an unguarded failure here would
    # not abort — it would silently leave the reachable set SHORT and report the
    # difference as content existing nowhere. A false orphan alarm is the one
    # way this check could cost a human real time.
    if ! awk '$2 == "blob" { print $3 }' "$LS_TREE_FILE" >>"$REACH_BLOBS_FILE"; then
      REACH_WHY="could not collect $ref's blob ids; reachability was NOT measured"
      return 1
    fi
  done

  # `diff-index --raw` emits `:<srcmode> <dstmode> <srcsha> <dstsha> <status>`
  # before the tab, so fields 1-5 are parseable even when a path contains spaces
  # or arrives quoted. A staged DELETION carries no content — its dstsha is the
  # all-zero sentinel — and is counted apart rather than as unreachable: the
  # bytes it removes are by definition still on the ref it was deleted from.
  if ! awk -v blobs="$REACH_BLOBS_FILE" '
    BEGIN {
      while ((getline b < blobs) > 0) reachable[b] = 1
    }
    {
      total++
      if ($5 ~ /^D/)            { deletions++; next }
      if ($4 ~ /^0+$/)          { unmeasured++; next }
      if (!($4 in reachable))   { unreachable++ }
    }
    END {
      if (unmeasured > 0) exit 3
      printf "%d %d %d\n", total + 0, deletions + 0, unreachable + 0
    }
  ' "$STAGED_RAW_FILE" >"$STAGED_COUNT_FILE" 2>/dev/null; then
    REACH_WHY="a staged entry carried no blob id, so the index was only partly measured"
    return 1
  fi

  read -r STAGED_TOTAL STAGED_DELETIONS STAGED_UNREACHABLE <"$STAGED_COUNT_FILE" || {
    REACH_WHY="the staged tally could not be read back; NOT measured"
    return 1
  }
  return 0
}

# origin_branch_probe — ONE live query, two facts about the branch the refinery
# would have deleted after merging: whether it is still on origin, and what it
# points at. Sets ORIGIN_STATE (present|absent|unknown) and ORIGIN_TIP (the sha
# of the EXACT ref when origin carries it, empty otherwise — including when the
# state is `present` on a pattern match alone; see the tip note below).
#
# C6b needs the state and C6c needs the tip, and they are the same `ls-remote`.
# Returning both from one call is not just thrift: two separate probes could
# straddle a push or a delete and have the two clauses reason about different
# states of origin.
#
# `ls-remote --exit-code` reserves exit 2 for "no matching refs"; every other
# non-zero is a transport, auth, or repo failure. Collapsing the two would make
# an offline run report that every branch had been deleted — a fail-OPEN on a
# signal C6b treats as corroborating evidence, which is the one direction this
# script never takes. `unknown` therefore keeps the tree, and also keeps the
# reap evidence honest for the C6 path, which used to print "origin branch
# deleted" whenever the probe merely failed to run.
#
# The tip is bound to the EXACT ref, not to the first line of output. `ls-remote`
# matches a pattern against the tail of a ref path on slash boundaries, so
# `polecat/ml-94dh` also matches `refs/heads/decoy/polecat/ml-94dh`, and output
# is sorted by refname — `d` sorts before `p`, so a decoy would win a positional
# read. The state may stay `present` on such a match, because `present` only ever
# WITHHOLDS C6b's branch-absence attestation. The tip may not: it is C6c's
# clearance, and a tip read off the wrong ref that happened to contain HEAD would
# be a false publication. No exact ref means no tip, which published_state
# reports as NOT measured and keeps the tree.
origin_branch_probe() {
  local br="$1" out='' rc=0
  ORIGIN_STATE=unknown
  ORIGIN_TIP=''
  [ -n "$br" ] || return 0
  out=$(git -C "$REPO" ls-remote --exit-code --heads origin "$br" 2>/dev/null) || rc=$?
  case "$rc" in
    0)
      ORIGIN_STATE=present
      ORIGIN_TIP=$(printf '%s\n' "$out" | awk -v r="refs/heads/$br" '$2 == r { print $1; exit }')
      ;;
    2) ORIGIN_STATE=absent ;;
    *) ORIGIN_STATE=unknown ;;
  esac
}

# published_state — C6c. Is this tree's work already on origin under the branch
# the bead records, independent of whether it ever reached the target? See the
# C6c section in the header for why the FIRST transition of the work chain is
# the one that makes the directory redundant.
#
# Returns 0 only when publication is measured and true. Sets PUB_NOTE either
# way, because that note is what replaces the old unmeasured "work looks
# genuinely unpublished" sentence on every refusal row.
#
# Containment is tested against HEAD rather than each flagged commit: `git
# cherry` only ever flags commits reachable from HEAD, so one ancestry test
# covers all of them, and a tree carrying commits past the pushed tip correctly
# fails it. Ancestry is the right test here for the same reason it is right for
# merged_sha and wrong for C6 — no rebase sits between a tree's own HEAD and the
# tip of its own pushed branch.
published_state() {
  local wt="$1" branch="$2" state="$3" tip="$4" short

  PUB_NOTE=''

  case "$state" in
    absent)
      PUB_NOTE="origin/$branch is gone, so this tree may hold the only copy"
      return 1 ;;
    present) ;;
    *)
      PUB_NOTE="publication NOT measured (ls-remote on $branch failed)"
      return 1 ;;
  esac

  if [ -z "$tip" ]; then
    PUB_NOTE="origin/$branch resolved to no sha, so publication was NOT measured"
    return 1
  fi
  # The tip must be an object we HAVE. A push from this tree normally leaves it
  # local, so an absent object means origin moved on independently — which is
  # unmeasurable here, not evidence either way.
  if ! git -C "$wt" rev-parse --verify --quiet "$tip^{commit}" >/dev/null 2>&1; then
    PUB_NOTE="origin/$branch is at $(printf '%s' "$tip" | cut -c1-7), which is not an object here, so publication was NOT measured"
    return 1
  fi
  if ! git -C "$wt" merge-base --is-ancestor HEAD "$tip" 2>/dev/null; then
    short=$(printf '%s' "$tip" | cut -c1-7)
    PUB_NOTE="origin/$branch is at $short but does NOT contain this tree's HEAD, so the tree holds commits found nowhere else"
    return 1
  fi

  PUB_NOTE="published: origin/$branch contains this tree's HEAD"
  return 0
}

# recall_note — the bead's own statement that this work is never going to the
# target. `do_not_merge` and `recalled_by_owner` are written as JSON booleans by
# the recall path and could reasonably arrive as strings, so both spellings are
# normalised through `tostring` rather than matched literally.
#
# DESCRIPTIVE, like C5b's grading next door and unlike C6/C6b/C6c: nothing is
# removed on the strength of what this returns. It was C6c's authorisation
# conjunct once; gp-98n dropped that, because the flags enumerate only two of
# the ways a bead becomes terminal and ml-apes — `gc.work_outcome=abandoned`,
# neither flag set — leaked 55M behind the veto. See the C6c section.
#
# What it is for now is the REFUSAL rows: on a tree C6c could not clear it says
# no predicate will ever collect this one, so an operator disposes of it rather
# than reading the row as a merge still pending. On a tree C6c did clear it is
# appended to the evidence as context. Both spellings of the flags are still
# normalised, because a row that silently stops appearing is a row nobody
# notices has stopped.
recall_note() {
  printf '%s' "$1" | jq -r '
    (.[0].metadata // {}) as $m
    | [ (if (($m.do_not_merge // false) | tostring) == "true"
         then "do_not_merge" else empty end),
        (if (($m.recalled_by_owner // false) | tostring) == "true"
         then "recalled_by_owner" else empty end) ]
    | if length == 0 then "" else join(" + ") end
  ' 2>/dev/null || true
}

# has_work_reference — C6b's anchor. Does this subject explicitly name a unit of
# work, so that an identical subject on the target is the SAME work rather than
# a recurrence of a common phrase? See the anchor section in the header for why
# this is no longer "does the subject contain the bead id".
#
# Two spellings qualify. The tree's own bead id ANYWHERE in the subject is the
# original anchor, kept verbatim so nothing that cleared before stops clearing.
# Otherwise: a parenthesised trailer that ENDS the subject, contains no
# whitespace, and is internally structured (a `-` or a `:`) — `(gp-psa)`,
# `(crit:c84a4764d9a1)`, `(polecat/ml-uoa.3)`.
#
# Every clause of that shape is doing work. Requiring the trailer to END the
# subject is what keeps a conventional-commit SCOPE out: `feat(router-portal):
# add a thing` has a spaceless, hyphenated parenthesised group, but it is not
# the last thing on the line. Rejecting whitespace drops prose asides ("(see
# below)"). Requiring a `-` or `:` drops bare words ("(wip)", "(hotfix)"), which
# recur across unrelated commits and are therefore exactly the hazard the anchor
# exists to catch. A PR-number trailer `(#1234)` deliberately does not qualify:
# GitHub appends it during a squash merge, so the landed subject differs from
# the tree's and the subject comparison could not have matched anyway.
has_work_reference() {
  local subj="$1" bead="$2" trailer

  case "$subj" in *"$bead"*) return 0 ;; esac

  # A trailer needs an opening paren somewhere and a closing one at the very
  # end; without the `(` test, a subject merely ending in `)` would fall through
  # to the strip below and be measured against its own whole text.
  case "$subj" in *'('*')') ;; *) return 1 ;; esac
  trailer="${subj##*\(}"
  trailer="${trailer%\)}"

  [ -n "$trailer" ] || return 1
  case "$trailer" in *[[:space:]]*) return 1 ;; esac
  case "$trailer" in *[-:]*) return 0 ;; esac
  return 1
}

# landed_by_subject — C6b. Does every commit `git cherry` flagged as missing
# have a same-subject twin already on the target? See the C6b section in the
# header for why subject survives what patch-id does not, and why each guard
# below is load-bearing. Returns 0 only when the answer is measured and yes;
# any unmeasurable input returns non-zero, which keeps the tree.
#
# Sets SUBJ_WHY to the SPECIFIC reason it declined. Collapsing every refusal
# into one message is the gp-psa defect itself: ml-uoa.3's row read "no
# same-subject landing there either" while origin/main demonstrably carried one
# — the anchor had vetoed before the target was ever consulted. A refusal that
# misreports its own reason reads as the reaper working correctly, which is how
# a leak survives patrol after patrol.
landed_by_subject() {
  local wt="$1" target="$2" bead="$3" cherry="$4"
  local mb mark sha subj short

  SUBJ_WHY=''

  # A landing can only be on the target AFTER this tree branched, so the merge
  # base is both the correct lower bound and the thing that keeps this off a
  # full-history walk. No merge base (unrelated histories) means no window to
  # search, which is an abstention, not a clearance.
  mb=$(git -C "$wt" merge-base HEAD "$target" 2>/dev/null) || mb=''
  if [ -z "$mb" ]; then
    SUBJ_WHY="no merge base with $target, so there is no window to search for a landing"
    return 1
  fi

  : >"$SUBJ_LOCAL_FILE"
  while read -r mark sha; do
    [ "$mark" = "+" ] || continue
    if [ -z "$sha" ]; then
      SUBJ_WHY="'git cherry' emitted a '+' with no sha; the commit list was NOT measured"
      return 1
    fi
    short=$(printf '%s' "$sha" | cut -c1-7)
    subj=$(git -C "$wt" log -1 --format=%s "$sha" 2>/dev/null) || subj=''
    if [ -z "$subj" ]; then
      SUBJ_WHY="the subject of $short is unreadable; the subject signal was NOT measured"
      return 1
    fi
    if ! has_work_reference "$subj" "$bead"; then
      SUBJ_WHY="$short's subject carries no work reference to anchor a match ('$subj'), so a same-subject landing would not prove it is the same work"
      return 1
    fi
    printf '%s\n' "$subj" >>"$SUBJ_LOCAL_FILE"
  done <<EOF
$cherry
EOF

  # Empty means we measured nothing — and would also invert awk's NR==FNR
  # file-discrimination below, silently reading the target's subjects as the
  # tree's and clearing on a comparison with itself.
  if [ ! -s "$SUBJ_LOCAL_FILE" ]; then
    SUBJ_WHY="no subject was collected from the flagged commits; NOT measured"
    return 1
  fi

  if ! git -C "$wt" log "$mb..$target" --no-merges --format=%s \
       >"$SUBJ_TARGET_FILE" 2>/dev/null; then
    SUBJ_WHY="could not read $target's subjects over $(printf '%s' "$mb" | cut -c1-7)..; NOT measured"
    return 1
  fi

  # Count per distinct subject rather than existence-check: a tree holding two
  # commits with the same subject must not be cleared by one landing of it.
  if ! awk '
    NR == FNR { want[$0]++; next }
    { have[$0]++ }
    END {
      for (s in want) if (have[s] < want[s]) exit 1
      exit 0
    }
  ' "$SUBJ_LOCAL_FILE" "$SUBJ_TARGET_FILE"; then
    # Says only what it measured. This used to end "work looks genuinely
    # unpublished", which is a claim about ORIGIN inferred from a walk of the
    # TARGET — false on any tree whose branch is still pushed, and false in the
    # reassuring direction. The publication fact is measured separately by C6c
    # and appended to the row by the caller.
    SUBJ_WHY="no same-subject landing on $target for every flagged commit"
    return 1
  fi
}

# is_hex_sha — shape of a commit sha, checked BEFORE anything tries to resolve
# it. `git rev-parse` would happily turn a ref-like value ("main", "HEAD", a
# tag) into an attestation the refinery never made, and this is also the arm
# that catches the literal `unknown` mol-refinery-patrol writes when a PR merge
# reports no commit — a placeholder that never named a sha, not a sha that
# failed to resolve. Length is left to `rev-parse`, which knows what is
# ambiguous in this repo better than a constant here would.
is_hex_sha() {
  case "$1" in
    ''|*[!0-9a-fA-F]*) return 1 ;;
    *) return 0 ;;
  esac
}

# merge_attested — C6b's second conjunct: did the refinery independently say it
# merged THIS bead? Two attestations, either sufficient, neither inferred.
#
#   * the branch it merges is absent from origin — its own after-merge cleanup;
#   * `metadata.merged_sha` resolves AND is an ancestor of the target — the
#     merge commit it recorded first-hand.
#
# Ancestry is the right test for the second and the wrong test for C6, which is
# not a contradiction: merged_sha names the commit the refinery created ON the
# target, so no rebase sits between it and the target for ancestry to be
# confused by. The checks are what make the field trustworthy rather than merely
# present, and they are staged so each refusal names its own cause: a value that
# is not a sha at all (the refinery writes the literal `unknown` when a PR merge
# reports none), a sha that does not resolve here, and a sha that resolves but
# is not on the target (a force-push can strand a once-valid one). Each keeps
# the tree.
#
# Sets ATTEST_NOTE either way: on success naming the attestation that cleared
# it, on failure naming what BOTH declined, so the row never implies the reaper
# consulted only the proxy.
merge_attested() {
  local wt="$1" target="$2" branch="$3" branch_state="$4" merged_sha="$5"
  local full sha_note

  if [ "$branch_state" = "absent" ]; then
    ATTEST_NOTE="origin branch $branch deleted after merge"
    return 0
  fi

  if [ -z "$merged_sha" ]; then
    sha_note="the bead records no merged_sha"
  elif ! is_hex_sha "$merged_sha"; then
    sha_note="merged_sha '$merged_sha' is not a commit sha"
  elif ! full=$(git -C "$wt" rev-parse --verify --quiet "$merged_sha^{commit}" 2>/dev/null) \
       || [ -z "$full" ]; then
    sha_note="merged_sha '$merged_sha' does not resolve to a commit here"
  elif ! git -C "$wt" merge-base --is-ancestor "$full" "$target" 2>/dev/null; then
    sha_note="merged_sha '$merged_sha' is not on $target"
  else
    ATTEST_NOTE="refinery recorded merged_sha $(printf '%s' "$full" | cut -c1-7) on $target"
    return 0
  fi

  case "$branch_state" in
    present) ATTEST_NOTE="origin/$branch still present and $sha_note" ;;
    *)       ATTEST_NOTE="origin/$branch state unknown (ls-remote failed) and $sha_note" ;;
  esac
  return 1
}

# Candidate shape, as one place both the filter and the rm -rf fallback consult.
# The trailing component is a bead id; the `worktrees` segment is what separates
# a per-bead tree from the agent workspace that contains it.
is_per_bead_worktree() {
  case "$1" in
    "$RIG_WORKTREES"/polecats/*/worktrees/*/*) return 1 ;;
    "$RIG_WORKTREES"/polecats/*/worktrees/?*) return 0 ;;
    *) return 1 ;;
  esac
}

# --- Hoisted once: every work_dir claimed by a bead that is NOT closed. -------
# A path in this set belongs to live work even if the bead named by its basename
# is closed — the rejection-resume path re-points a returned bead at an existing
# tree (gp-px5). Streamed through files, never --argjson on argv: bead payloads
# on a busy rig overflow ARG_MAX.
CLAIMED_FILE=$(mktemp)
RAW_CLAIMED_FILE=$(mktemp)
LIST_FILE=$(mktemp)
CANDIDATES_FILE=$(mktemp)
LOCKED_FILE=$(mktemp)
# C6b's two subject sets. Hoisted with the rest so the EXIT trap owns them —
# allocating inside the per-candidate loop would leak one pair per tree.
SUBJ_LOCAL_FILE=$(mktemp)
SUBJ_TARGET_FILE=$(mktemp)
# C5b's scratch: the raw staged diff, the reachable blob universe, one ls-tree
# read at a time, and the tally awk hands back. Hoisted for the same reason as
# C6b's pair — a mktemp inside the per-candidate loop leaks one set per tree.
STAGED_RAW_FILE=$(mktemp)
REACH_BLOBS_FILE=$(mktemp)
LS_TREE_FILE=$(mktemp)
STAGED_COUNT_FILE=$(mktemp)
# Every refusal reason and measured fact the rows below read back: written by
# landed_by_subject, merge_attested, staged_reachability and published_state,
# plus the two facts origin_branch_probe returns and C5b's three counters.
# Seeded here so `set -u` cannot turn a future early-return that forgets to set
# one into an abort mid-scan.
SUBJ_WHY=''
ATTEST_NOTE=''
REACH_WHY=''
PUB_NOTE=''
ORIGIN_STATE=unknown
ORIGIN_TIP=''
STAGED_TOTAL=0
STAGED_DELETIONS=0
STAGED_UNREACHABLE=0
trap 'rm -f "$CLAIMED_FILE" "$RAW_CLAIMED_FILE" "$LIST_FILE" "$CANDIDATES_FILE" "$LOCKED_FILE" "$SUBJ_LOCAL_FILE" "$SUBJ_TARGET_FILE" "$STAGED_RAW_FILE" "$REACH_BLOBS_FILE" "$LS_TREE_FILE" "$STAGED_COUNT_FILE"' EXIT

# Every stored status that is not `closed`, taken from bd's own enum
# (open, in_progress, blocked, deferred, closed) rather than guessed. A
# non-closed status missing from this list is a bead whose claim on a tree this
# guard cannot see — the quiet fail-OPEN the whole script is built to avoid.
# `escalated` was named here once and is NOT a stored status: bd rejects it, the
# error went to /dev/null, and the iteration bought nothing while `deferred`
# was genuinely missing.
NONCLOSED_STATUSES=open,in_progress,blocked,deferred

: >"$RAW_CLAIMED_FILE"
if ! gc bd --rig "$RIG" list --status="$NONCLOSED_STATUSES" --json --limit=0 \
     >"$LIST_FILE" 2>/dev/null; then
  echo "$ME: could not list non-closed beads for rig '$RIG' — the claimed-tree" >&2
  echo "  guard cannot be evaluated, so nothing was measured" >&2
  exit 2
fi
# `// ""` rather than `// empty`: inside an array constructor, `empty` collapses
# the element away and shifts .id into column 1, which would silently compare a
# bead id against a path.
if ! jq -r 'if type == "array" then .[] else empty end
            | select((.status // "") != "closed")
            | select((.metadata.work_dir // "") != "")
            | [(.metadata.work_dir // ""), .id] | @tsv' \
       "$LIST_FILE" >>"$RAW_CLAIMED_FILE" 2>/dev/null; then
  echo "$ME: could not parse the non-closed bead listing — the claimed-tree" >&2
  echo "  guard cannot be evaluated, so nothing was measured" >&2
  exit 2
fi

# Store BOTH spellings of every claimed path. `metadata.work_dir` is recorded by
# the polecat's workspace-setup step from `$(pwd)`, which is the LOGICAL cwd, so
# it can name a symlinked path differently than the physical one `git worktree
# list` reports. A spelling mismatch here would make this guard fail OPEN — the
# quietest possible way to lose the gp-px5 protection — so the comparison is
# never allowed to depend on which spelling was recorded.
: >"$CLAIMED_FILE"
while IFS="$(printf '\t')" read -r claimed_dir claimed_id; do
  [ -n "${claimed_dir:-}" ] || continue
  printf '%s\t%s\n' "$claimed_dir" "$claimed_id" >>"$CLAIMED_FILE"
  if [ -d "$claimed_dir" ]; then
    claimed_phys=$( (cd "$claimed_dir" && pwd -P) 2>/dev/null || true)
    if [ -n "$claimed_phys" ] && [ "$claimed_phys" != "$claimed_dir" ]; then
      printf '%s\t%s\n' "$claimed_phys" "$claimed_id" >>"$CLAIMED_FILE"
    fi
  fi
done <"$RAW_CLAIMED_FILE"

claimed_by() {
  awk -F'\t' -v p="$1" '$1 == p { print $2; exit }' "$CLAIMED_FILE"
}

# --- Enumerate candidates from the git registry. ------------------------------
: >"$CANDIDATES_FILE"
: >"$LOCKED_FILE"

if ! WT_LIST=$(git -C "$REPO" worktree list --porcelain 2>/dev/null); then
  echo "$ME: 'git worktree list' failed in $REPO — nothing was measured" >&2
  exit 2
fi

current_wt=''
while IFS= read -r line; do
  case "$line" in
    'worktree '*)
      current_wt="${line#worktree }"
      if is_per_bead_worktree "$current_wt"; then
        printf '%s\n' "$current_wt" >>"$CANDIDATES_FILE"
      else
        current_wt=''
      fi
      ;;
    'locked'|'locked '*)
      [ -n "$current_wt" ] && printf '%s\n' "$current_wt" >>"$LOCKED_FILE"
      ;;
  esac
done <<EOF
$WT_LIST
EOF

TOTAL=$(wc -l <"$CANDIDATES_FILE" | tr -d ' ')
if [ "${TOTAL:-0}" -eq 0 ]; then
  echo "$ME: no per-bead polecat worktrees registered under $RIG_WORKTREES" >&2
  exit 0
fi

printf 'verdict\tbead\tpath\tdetail\n' >&2

n_reap=0 n_reaped=0 n_failed=0 n_kept=0 n_unverifiable=0 n_orphaned=0

while IFS= read -r WT; do
  [ -n "$WT" ] || continue
  BEAD=$(basename "$WT")

  # C0: never pull the rug out from under the shell we are running in. Compared
  # physically for the same reason the city root is: a symlinked cwd would slip
  # past this guard and the reaper would delete the directory it is standing in.
  case "$(pwd -P)/" in
    "$WT"/*) row keep-self "$BEAD" "$WT" "we are running inside it"; n_kept=$((n_kept + 1)); continue ;;
  esac

  if grep -Fxq "$WT" "$LOCKED_FILE" 2>/dev/null; then
    row keep-locked "$BEAD" "$WT" "worktree is locked; an operator or a running job claimed it"
    n_kept=$((n_kept + 1)); continue
  fi

  # C1 identity. `gc bd show` FUZZY-MATCHES: `show a7z` returns gp-a7z
  # (verified live). A directory whose basename is a prefix of, or otherwise
  # near, some other bead id would be "verified" against a bead it has nothing
  # to do with — and then reaped on that bead's closed status. Requiring the
  # returned id to equal the basename exactly is what makes the rest of the
  # checks mean anything.
  BEAD_JSON=$(gc bd --rig "$RIG" show "$BEAD" --json 2>/dev/null || true)
  GOT_ID=$(printf '%s' "$BEAD_JSON" \
    | jq -r 'if type == "array" then (.[0].id // empty) else empty end' 2>/dev/null || true)
  if [ -z "$GOT_ID" ]; then
    row unverifiable "$BEAD" "$WT" "no bead read back for this path; NOT cleared"
    n_unverifiable=$((n_unverifiable + 1)); continue
  fi
  if [ "$GOT_ID" != "$BEAD" ]; then
    row unverifiable "$BEAD" "$WT" "basename resolved to a different bead ($GOT_ID) — fuzzy match, NOT cleared"
    n_unverifiable=$((n_unverifiable + 1)); continue
  fi

  STATUS=$(printf '%s' "$BEAD_JSON" | jq -r '.[0].status // empty' 2>/dev/null || true)
  CLOSED_AT=$(printf '%s' "$BEAD_JSON" | jq -r '.[0].closed_at // empty' 2>/dev/null || true)
  # Reported by C5b only, and never a predicate anywhere: see the liveness
  # section above for why "nobody owns it" must not authorise anything. It is in
  # the row because an operator triaging a kept tree needs to know whether there
  # is anyone left to ask about its contents.
  ASSIGNEE=$(printf '%s' "$BEAD_JSON" | jq -r '.[0].assignee // empty' 2>/dev/null || true)
  META_TARGET=$(printf '%s' "$BEAD_JSON" | jq -r '.[0].metadata.target // empty' 2>/dev/null || true)
  # The branch the refinery was handed and, on success, deleted. Recorded by
  # the polecat's branch-setup step; the convention is the fallback for a bead
  # that predates the metadata contract.
  META_BRANCH=$(printf '%s' "$BEAD_JSON" | jq -r '.[0].metadata.branch // empty' 2>/dev/null || true)
  MERGE_BRANCH="${META_BRANCH:-polecat/$BEAD}"
  # The merge commit the refinery recorded on the target. Unlike the deleted
  # branch it is a first-hand statement rather than an inference, and it is
  # checked before it is believed — see merge_attested. No fallback: absent
  # means the refinery never attested this merge, which is a refusal, not a
  # spelling to guess at.
  META_MERGED_SHA=$(printf '%s' "$BEAD_JSON" | jq -r '.[0].metadata.merged_sha // empty' 2>/dev/null || true)
  # The bead's own statement that this work will never reach the target. C6c's
  # authorisation conjunct: never sufficient by itself, but nothing is removed on
  # the C6c path without it. It is also the note carried by the refusals it does
  # NOT clear, so an eternal keep reads as one. See recall_note.
  RECALLED=$(recall_note "$BEAD_JSON")

  # C2 terminal. Anything not closed is in flight — including a rejected bead
  # back in the pool, whose branch a later polecat will resume from this tree.
  if [ "$STATUS" != "closed" ]; then
    row keep-open "$BEAD" "$WT" "status=${STATUS:-unknown}; work is still in flight"
    n_kept=$((n_kept + 1)); continue
  fi

  # C3 unclaimed by any other live bead.
  OWNER=$(claimed_by "$WT" || true)
  if [ -n "$OWNER" ] && [ "$OWNER" != "$BEAD" ]; then
    row keep-claimed "$BEAD" "$WT" "non-closed bead $OWNER points metadata.work_dir here"
    n_kept=$((n_kept + 1)); continue
  fi

  # C4 cool. Guards the one real race: a polecat that has drain-acked but whose
  # session the controller has not yet killed. An unparseable closed_at reads as
  # 0 = unknown, which must not read as "ancient" — abstain instead.
  CLOSED_EPOCH=$(ts_epoch "$CLOSED_AT")
  if [ "$CLOSED_EPOCH" -eq 0 ]; then
    row unverifiable "$BEAD" "$WT" "closed but closed_at is unreadable ('${CLOSED_AT:-}'); age NOT measured"
    n_unverifiable=$((n_unverifiable + 1)); continue
  fi
  AGE_SECS=$((NOW - CLOSED_EPOCH))
  if [ "$AGE_SECS" -lt "$MIN_AGE_SECS" ]; then
    row keep-cooling "$BEAD" "$WT" "closed $((AGE_SECS / 60))m ago; grace window is ${MIN_AGE_MIN}m"
    n_kept=$((n_kept + 1)); continue
  fi

  # A registered worktree whose directory is already gone has nothing to lose
  # and nothing to check — the registry entry is the only leak left.
  if [ ! -d "$WT" ]; then
    if [ "$DO_REAP" -eq 1 ]; then
      git -C "$REPO" worktree prune >/dev/null 2>&1 || true
      row reaped "$BEAD" "$WT" "directory already gone; pruned the stale registry entry"
      n_reaped=$((n_reaped + 1))
    else
      row reap "$BEAD" "$WT" "directory already gone; only a stale registry entry remains"
      n_reap=$((n_reap + 1))
    fi
    continue
  fi

  # The ref both remaining checks measure against. Resolved once, before either
  # runs, so C5b's report and C6's clearance can never name different targets for
  # the same tree. Resolution only — C6 still verifies the ref itself, because
  # only C6 turns an unresolvable target into an abstention from REMOVING.
  TARGET=$(resolve_target "$WT" "$META_TARGET")

  # C5 clean — load-bearing. Nothing uncommitted or untracked may be discarded.
  if ! DIRTY=$(git -C "$WT" status --porcelain 2>/dev/null); then
    row unverifiable "$BEAD" "$WT" "'git status' failed here; cleanliness NOT measured"
    n_unverifiable=$((n_unverifiable + 1)); continue
  fi
  if [ -n "$DIRTY" ]; then
    # C5b. The tree is already kept — the only question left is whether this
    # refusal is routine or an escalation, and NOTHING below reads the answer.
    DIRTY_N=$(printf '%s\n' "$DIRTY" | wc -l | tr -d ' ')
    AGE_NOTE="closed $(age_brief "$AGE_SECS")"
    if [ -n "$ASSIGNEE" ]; then OWNER_NOTE="assignee $ASSIGNEE"; else OWNER_NOTE="no owner"; fi
    if ! staged_reachability "$WT" "$TARGET"; then
      # Not measured is not a clean bill. It reports as the escalating verdict
      # naming its own cause, never as the routine one.
      row keep-orphaned "$BEAD" "$WT" \
        "$AGE_NOTE, $OWNER_NOTE, $DIRTY_N uncommitted or untracked paths; staged content NOT measured: $REACH_WHY"
      n_orphaned=$((n_orphaned + 1)); continue
    fi
    if [ "$STAGED_UNREACHABLE" -gt 0 ]; then
      row keep-orphaned "$BEAD" "$WT" \
        "$AGE_NOTE, $OWNER_NOTE, $DIRTY_N uncommitted or untracked paths, $STAGED_TOTAL staged ($STAGED_DELETIONS deletion(s)); $STAGED_UNREACHABLE staged blob(s) on NEITHER HEAD nor $TARGET — that content exists nowhere else. Do not remove without a human read"
      n_orphaned=$((n_orphaned + 1)); continue
    fi
    if [ "$STAGED_TOTAL" -eq 0 ]; then
      REACH_NOTE="nothing staged, so no index-only content is at risk"
    else
      REACH_NOTE="all $STAGED_TOTAL staged path(s) already on HEAD or $TARGET"
    fi
    # Untracked and unstaged content was NOT priced — say so, so the row cannot
    # be read as "safe to delete" when only the index was cleared.
    row keep-dirty "$BEAD" "$WT" \
      "$DIRTY_N uncommitted or untracked paths; $REACH_NOTE (worktree-side content not priced)"
    n_kept=$((n_kept + 1)); continue
  fi

  # C6 upstream — load-bearing, and patch-id rather than ancestry. $TARGET was
  # resolved above; verifying it is C6's own business.
  if ! git -C "$WT" rev-parse --verify --quiet "$TARGET^{commit}" >/dev/null 2>&1; then
    row unverifiable "$BEAD" "$WT" "target ref '$TARGET' does not resolve; landing NOT measured"
    n_unverifiable=$((n_unverifiable + 1)); continue
  fi
  if ! CHERRY=$(git -C "$WT" cherry "$TARGET" HEAD 2>/dev/null); then
    row unverifiable "$BEAD" "$WT" "'git cherry $TARGET HEAD' failed; landing NOT measured"
    n_unverifiable=$((n_unverifiable + 1)); continue
  fi
  AHEAD=$(printf '%s' "$CHERRY" | grep -c '^+' || true)

  # The refinery deletes the branch after a successful merge, so its absence is
  # a second landed-signal — corroborating for C6, which is strictly stronger
  # evidence, and REQUIRED for C6b, which is not.
  origin_branch_probe "$MERGE_BRANCH"
  BRANCH_STATE="$ORIGIN_STATE"
  case "$BRANCH_STATE" in
    present) ORIGIN_NOTE="origin/$MERGE_BRANCH still present" ;;
    absent)  ORIGIN_NOTE="origin branch $MERGE_BRANCH deleted" ;;
    *)       ORIGIN_NOTE="origin branch $MERGE_BRANCH state unknown (ls-remote failed)" ;;
  esac

  if [ "${AHEAD:-0}" -gt 0 ]; then
    # C6b runs FIRST — not because it is cheaper (it is not; it walks the
    # target's subjects while C6c is one ancestry test) but because it is the
    # STRONGER claim. Both clearances are equally safe, so the order decides
    # only which evidence an operator reads, and "the work landed on the target"
    # is worth more on a row than "the work is also on origin". A merged tree
    # usually has no branch left on origin anyway, so C6c would abstain on it
    # and the walk happens either way.
    #
    # Every arm reports WHICH signal declined, because a bare `keep-unmerged`
    # reads as the reaper working correctly and is how the gp-psa leak stayed
    # invisible for three cycles.
    KEEP_WHY=''
    if ! landed_by_subject "$WT" "$TARGET" "$BEAD" "$CHERRY"; then
      KEEP_WHY="subject check declined: $SUBJ_WHY"
    elif ! merge_attested "$WT" "$TARGET" "$MERGE_BRANCH" "$BRANCH_STATE" "$META_MERGED_SHA"; then
      KEEP_WHY="every subject DID land on $TARGET, but no merge is attested: $ATTEST_NOTE"
    fi

    if [ -z "$KEEP_WHY" ]; then
      EVIDENCE="closed $CLOSED_AT; clean; $AHEAD patch(es) adjusted on the way in, every subject landed on $TARGET; $ATTEST_NOTE"
    elif published_state "$WT" "$MERGE_BRANCH" "$BRANCH_STATE" "$ORIGIN_TIP"; then
      # C6c. The work did not reach the target and may never — but the target was
      # only ever a proxy for "is this the only copy", and origin answers that
      # directly. Publication is the whole test: the disposition conjunct this
      # used to carry vetoed ml-apes for want of a flag while its work sat on
      # origin at the identical sha (gp-98n). See the C6c section.
      #
      # Deliberately weaker evidence than the merge paths, and worded so `reap`
      # cannot be misread as "this landed". It says only what was measured: the
      # tree is redundant with origin, so removing it loses nothing. The recall,
      # when there is one, is context on that row rather than the reason for it.
      EVIDENCE="closed $CLOSED_AT; clean; $AHEAD patch(es) NOT on $TARGET; $PUB_NOTE, so the tree is redundant and recoverable with 'git fetch' + 'git worktree add'"
      if [ -n "$RECALLED" ]; then
        EVIDENCE="$EVIDENCE; bead is terminal-and-will-never-merge ($RECALLED), so it was never going to reach $TARGET"
      fi
    else
      # Neither route cleared it. The row carries both refusals: why the merge
      # signals declined, and the MEASURED publication state C6c declined on —
      # never an inference from the target walk.
      DETAIL="$AHEAD commit(s) whose patches are not on $TARGET; $KEEP_WHY; $PUB_NOTE"
      # A recalled bead can never satisfy any predicate here — the refinery will
      # not merge it and C6c just found no copy on origin. Saying so is the
      # difference between a row an operator can act on and one that reads as a
      # merge still pending, forever.
      if [ -n "$RECALLED" ]; then
        DETAIL="$DETAIL; bead is terminal-and-will-never-merge ($RECALLED), so no predicate can ever collect this tree — operator disposition needed"
      fi
      row keep-unmerged "$BEAD" "$WT" "$DETAIL"
      n_kept=$((n_kept + 1)); continue
    fi
  else
    EVIDENCE="closed $CLOSED_AT; clean; 0 patches ahead of $TARGET; $ORIGIN_NOTE"
  fi

  if [ "$DO_REAP" -eq 0 ]; then
    row reap "$BEAD" "$WT" "$EVIDENCE"
    n_reap=$((n_reap + 1))
    continue
  fi

  # Removal runs from $REPO, never from inside $WT — `git worktree remove`
  # refuses to delete the tree it is standing in.
  if git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1; then
    REMOVED="git worktree remove"
  elif is_per_bead_worktree "$WT" && [ -n "$WT" ] && rm -rf "$WT" 2>/dev/null; then
    # Fallback for a registry/directory mismatch git will not reconcile itself.
    # Re-asserting the shape here is deliberate: this is the only rm -rf in the
    # script and it must not be reachable with an unvalidated path.
    REMOVED="rm -rf (worktree remove refused)"
  else
    row reap-failed "$BEAD" "$WT" "could not remove; left in place"
    n_failed=$((n_failed + 1))
    continue
  fi

  git -C "$REPO" worktree prune >/dev/null 2>&1 || true
  # The branch is disposable by the same argument as the tree: its patches are
  # on the target. It is only still here because the tree held it checked out.
  # Non-fatal — a branch checked out elsewhere must stay. This is the LOCAL
  # branch only, and since gp-psa a tree can reach here with its origin branch
  # still published, which makes the deletion strictly safer than before rather
  # than less: origin keeps a copy either way.
  if git -C "$REPO" branch -D "$MERGE_BRANCH" >/dev/null 2>&1; then
    REMOVED="$REMOVED; deleted local branch $MERGE_BRANCH"
  fi
  row reaped "$BEAD" "$WT" "$REMOVED"
  n_reaped=$((n_reaped + 1))
done <"$CANDIDATES_FILE"

printf '%s: %s candidate(s) under %s — reapable=%s reaped=%s failed=%s kept=%s unverifiable=%s orphaned=%s\n' \
  "$ME" "$TOTAL" "$RIG_WORKTREES" "$n_reap" "$n_reaped" "$n_failed" "$n_kept" "$n_unverifiable" "$n_orphaned" >&2

# `orphaned` is a finding for the same reason `unverifiable` is: both name a tree
# that will still be here next cycle and that no further reaper run can resolve.
# A rig whose only anomaly is an orphaned tree must not exit 0 — that is the
# "nothing to report" code, and it is what let an eternal refusal read as routine.
if [ "$n_reap" -gt 0 ] || [ "$n_reaped" -gt 0 ] || [ "$n_failed" -gt 0 ] \
   || [ "$n_unverifiable" -gt 0 ] || [ "$n_orphaned" -gt 0 ]; then
  exit 1
fi
exit 0
