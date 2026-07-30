#!/usr/bin/env bash
# deploy-check.sh — does a merged commit actually RUN anywhere, or was it only
# authored?
#
# Why this exists (gp-apx, follow-up to gp-9pa): closing a pack bead asserts
# AUTHORSHIP — the patch is an ancestor of the target branch. It says nothing
# about DEPLOYMENT. A city does not read the pack's default branch; it reads a
# commit pinned in packs.lock and materialized into the content-addressed pack
# cache. Advancing that pin is a separate act (`gc import install` + `gc reload`)
# that no close path performs or waits for.
#
# So "closed" and "live" are independent facts, and the ledger recorded only the
# first. Measured on this city, three P1 fixes were closed while still live as
# bugs:
#
#   gp-haf  witness salvage read metadata.worktree  closed 2026-07-27, undeployed
#   gp-dlq  patrol formulas leaked wisps            closed 2026-07-28, undeployed
#   gp-px5  parked-session detector                 closed 2026-07-29, undeployed
#
# gp-px5 is the clean reproduction: its fix is commit 51a667b, the city's pin was
# 10a553a, and 51a667b is not an ancestor of 10a553a. The bead read exactly like
# the two beside it that WERE deployed. That indistinguishability is the defect.
#
# This script answers the deployment question so a close can state it. It does
# NOT block a close: the merge really did land, and the refinery cannot advance a
# pin, so refusing to close would jam the merge queue on every fix and fix
# nothing. Instead the verdict is recorded, and an undeployed close says so.
#
# The two conjuncts, per gp-apx: a fix is live iff
#
#   1. PIN CONTAINMENT     — the pinned commit's history contains the fix, and
#   2. ARTIFACT RESOLUTION — the installed artifact actually resolves to that
#                            pin, so agents load it rather than an older copy.
#
# Both are needed. gp-9pa is the case where (1) held and (2) did not: the pack
# source carried gp-haf's fix while the rig's installed formula copy did not, so
# the pin looked fine and the running witness still had the bug.
#
# Note what (2) buys us here: GC_PACK_DIR is the INSTALLED pack directory, so
# this script runs from inside the very artifact it reports on. A `deployed`
# verdict therefore means "the code that just answered you is the code that
# contains the fix" — the assertion is self-witnessing rather than inferred.
#
# FAIL CLOSED. Anything short of a proven-live verdict is not `deployed`. A
# false "deployed" recreates the bug this replaces; a false "not deployed" costs
# one pin check. The one verdict that is NOT a failure is `not_applicable`: an
# ordinary application rig is not any city's pack source, and stamping every one
# of its beads "not deployed" would be noise that teaches people to ignore the
# field. That verdict is decided on evidence — no import in this city resolves
# to this repo — never on a missing tool.
#
# Usage:
#   deploy-check.sh <commit-sha> [--repo <dir>] [--stamp <bead-id>]
#
#   Default mode      prints `key=value` evidence lines on stdout.
#   --stamp <bead>    writes the verdict to the bead's metadata and prints ONLY
#                     a close-reason suffix on stdout (evidence moves to stderr),
#                     so a caller can splice it straight into `gc bd close`.
#
# Exit codes — the distinction is load-bearing for callers:
#   0  deployed              live in this city; both conjuncts proven
#   1  authored_not_deployed merged, but provably not live
#   2  undetermined          could not evaluate; treat as NOT deployed
#   3  not_applicable        this repo is not a pack source for this city
#
# Environment:
#   GC_PACK_DIR  absolute installed pack directory (set by gc for pack commands;
#                this is the artifact side of the assertion)
#   GC_CITY      city root, for reporting which city was asserted
#   GC_RIG_ROOT  the rig repo the commit landed in; used when --repo is absent
#
# Repo precedence is --repo, then GC_RIG_ROOT, then cwd. Preferring the resolved
# rig root over cwd is deliberate: a caller's working directory is ambient state,
# and the refinery in particular runs part of its merge from a detached worktree.
# cwd remains the last resort so the script stays usable by hand.
#
# Callers must reach this through `gc gastown deploy-check`. GC_PACK_DIR is set
# by gc for pack COMMANDS and is absent from an agent's shell, so a formula that
# spells the path itself resolves "/assets/scripts/..." and measures nothing —
# the failure mode that shipped four dead checks (gp-fid, gp-px5, gp-3qb x2).

set -uo pipefail

SHA=""
REPO=""
STAMP_BEAD=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --repo)
            REPO="${2:-}"
            shift 2 || break
            ;;
        --stamp)
            STAMP_BEAD="${2:-}"
            shift 2 || break
            ;;
        -h | --help)
            sed -n '2,/^set -uo/p' "$0" | sed 's/^# \{0,1\}//;$d'
            exit 0
            ;;
        -*)
            echo "deploy-check: unknown flag '$1'" >&2
            exit 2
            ;;
        *)
            [ -n "$SHA" ] && {
                echo "deploy-check: unexpected extra argument '$1'" >&2
                exit 2
            }
            SHA="$1"
            shift
            ;;
    esac
done

if [ -z "$SHA" ]; then
    echo "deploy-check: a commit sha is required" >&2
    exit 2
fi

REPO="${REPO:-${GC_RIG_ROOT:-$(pwd)}}"

# ---------------------------------------------------------------------------
# Verdict accumulator. Printed once, through emit(), so every exit path reports
# the same shape and no path can forget a field.
# ---------------------------------------------------------------------------
STATUS=""
REASON=""
PIN=""
INSTALLED=""
CHECKED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Remediation detail is operator-facing and multi-line; it never enters bead
# metadata or a close reason, both of which have to stay one short line.
DETAIL=""

emit() {
    local suffix=""
    case "$STATUS" in
        deployed) suffix=" -- deployed (pin ${PIN:0:8})" ;;
        authored_not_deployed) suffix=" -- AUTHORED, NOT DEPLOYED: $REASON" ;;
        undetermined) suffix=" -- deployment UNVERIFIED: $REASON" ;;
        # not_applicable contributes no suffix on purpose. A rig that is nobody's
        # pack source has no deployment story, and appending one to every close
        # reason would be pure noise.
        not_applicable) suffix="" ;;
    esac

    local evidence
    evidence=$(
        printf 'deploy_status=%s\n' "$STATUS"
        printf 'deploy_reason=%s\n' "$REASON"
        printf 'deploy_checked_at=%s\n' "$CHECKED_AT"
        [ -n "$PIN" ] && printf 'deploy_pin=%s\n' "$PIN"
        [ -n "$INSTALLED" ] && printf 'deploy_installed_sha=%s\n' "$INSTALLED"
        [ -n "${GC_PACK_DIR:-}" ] && printf 'deploy_pack_dir=%s\n' "$GC_PACK_DIR"
        [ -n "${GC_CITY:-}" ] && printf 'deploy_city=%s\n' "$GC_CITY"
        printf 'deploy_commit=%s\n' "$SHA"
    )

    if [ -n "$STAMP_BEAD" ]; then
        printf '%s\n' "$evidence" >&2
        [ -n "$DETAIL" ] && printf '%s\n' "$DETAIL" >&2

        # Stamp, but never let a stamp failure break the caller's close. A bead
        # closed without the deployment field is the status quo; a close that
        # aborted because a metadata write failed would strand merged work.
        local args=(
            --set-metadata "deploy_status=$STATUS"
            --set-metadata "deploy_reason=$REASON"
            --set-metadata "deploy_checked_at=$CHECKED_AT"
            --set-metadata "deploy_commit=$SHA"
        )
        [ -n "$PIN" ] && args+=(--set-metadata "deploy_pin=$PIN")
        [ -n "$INSTALLED" ] && args+=(--set-metadata "deploy_installed_sha=$INSTALLED")
        if ! gc bd update "$STAMP_BEAD" "${args[@]}" >/dev/null 2>&1; then
            echo "deploy-check: could not stamp $STAMP_BEAD (verdict $STATUS); reporting it in the close reason only." >&2
        fi

        printf '%s' "$suffix"
    else
        printf '%s\n' "$evidence"
        [ -n "$DETAIL" ] && printf '%s\n' "$DETAIL" >&2
    fi

    case "$STATUS" in
        deployed) exit 0 ;;
        authored_not_deployed) exit 1 ;;
        not_applicable) exit 3 ;;
        *) exit 2 ;;
    esac
}

# ---------------------------------------------------------------------------
# Reduce any pack-source or remote URL to a comparable `host/owner/repo`.
#
# The two sides of the comparison arrive in different shapes and neither is
# canonical: an import source carries the pinned ref and the pack subpath
# (".../gascity-packs/tree/<sha>/gastown"), while a git remote may be scp-style
# ("git@github.com:owner/repo.git"), https, or file://. Comparing raw strings
# would answer "not a pack source" for a repo that plainly is one, which lands
# in `not_applicable` — a silent pass. That is exactly the wrong direction to be
# wrong in, so normalize both sides.
# ---------------------------------------------------------------------------
# The subpath forms handled below are the ones validate_registry.py knows about:
# /tree/<ref>/<sub>, /blob/<ref>/<sub>, and the legacy '<repo>//<sub>'. The last
# two are rejected for registry entries, but a city's imports come from city.toml
# and packs.lock rather than the registry, so nothing upstream guarantees this
# only ever sees the canonical spelling.
normalize_repo() {
    local u="$1"

    # Scheme and userinfo come off FIRST, so any "//" left in the string is a
    # legacy subpath separator rather than part of "https://".
    case "$u" in
        *://*) u="${u#*://}" ;;
        *@*:*)
            u="${u#*@}"                          # scp-style: drop user@
            u="$(printf '%s' "$u" | tr ':' '/')" # host:path -> host/path
            ;;
    esac
    # Strip userinfo only from the authority component. Matching an '@' anywhere
    # would truncate a file:// path that legitimately contains one.
    case "${u%%/*}" in
        *@*) u="${u#*@}" ;;
    esac

    u="${u%%/tree/*}" # .../tree/<ref>/<subpath>
    u="${u%%/blob/*}" # .../blob/<ref>/<subpath>
    u="${u%%//*}"     # legacy '<repo>//<subpath>'
    u="${u%/}"
    u="${u%.git}"
    u="${u%/}"
    printf '%s' "$u" | tr '[:upper:]' '[:lower:]'
}

# ---------------------------------------------------------------------------
# 1. The repo the commit landed in.
# ---------------------------------------------------------------------------
if ! git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
    STATUS=undetermined
    REASON="$REPO is not a git repository"
    emit
fi

if ! git -C "$REPO" cat-file -e "${SHA}^{commit}" 2>/dev/null; then
    STATUS=undetermined
    REASON="commit $SHA is not present in $REPO"
    emit
fi

ORIGIN_URL=$(git -C "$REPO" remote get-url origin 2>/dev/null)
if [ -z "$ORIGIN_URL" ]; then
    # No origin means nothing can be matched against an import source. That is
    # unmeasurable, not inapplicable — a pack source with a detached remote must
    # not quietly read as "no deployment story".
    STATUS=undetermined
    REASON="$REPO has no origin remote to match against pack imports"
    emit
fi
ORIGIN_KEY=$(normalize_repo "$ORIGIN_URL")

# ---------------------------------------------------------------------------
# 2. This city's declared imports and their pins.
# ---------------------------------------------------------------------------
IMPORTS_JSON=$(gc import status --json 2>/dev/null)
if [ -z "$IMPORTS_JSON" ]; then
    STATUS=undetermined
    REASON="could not read this city's pack imports"
    emit
fi

# name<TAB>source<TAB>pinned-commit, one import per line.
IMPORT_ROWS=$(printf '%s' "$IMPORTS_JSON" |
    jq -r '.imports[]? | [.name, .source, (.pin.commit // "")] | @tsv' 2>/dev/null)
if [ -z "$IMPORT_ROWS" ]; then
    STATUS=undetermined
    REASON="this city declares no readable pack imports"
    emit
fi

# ---------------------------------------------------------------------------
# 3. Applicability: does any import resolve to this repo?
# ---------------------------------------------------------------------------
MATCHED_ROWS=""
while IFS=$'\t' read -r i_name i_source i_commit; do
    [ -n "$i_source" ] || continue
    if [ "$(normalize_repo "$i_source")" = "$ORIGIN_KEY" ]; then
        MATCHED_ROWS+="${i_name}	${i_commit}"$'\n'
    fi
done <<<"$IMPORT_ROWS"

if [ -z "$MATCHED_ROWS" ]; then
    STATUS=not_applicable
    REASON="no import in this city resolves to $ORIGIN_KEY"
    emit
fi

# ---------------------------------------------------------------------------
# 4. Artifact resolution: what commit does the INSTALLED pack resolve to?
#
# GC_PACK_DIR is the installed pack directory. Without it, or without a git
# clone behind it, conjunct (2) is unprovable — and an unprovable conjunct is
# never a pass. A registry release tarball legitimately has no HEAD; a fix
# inside one still cannot be asserted live by this method, so it reports
# undetermined and the operator sees an honest gap rather than a green light.
# ---------------------------------------------------------------------------
if [ -z "${GC_PACK_DIR:-}" ]; then
    STATUS=undetermined
    REASON="GC_PACK_DIR is unset, so the installed artifact cannot be resolved"
    DETAIL="Run this through 'gc gastown deploy-check' — gc sets GC_PACK_DIR for pack commands only."
    emit
fi

if ! git -C "$GC_PACK_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    STATUS=undetermined
    REASON="installed pack at $GC_PACK_DIR is not a git clone"
    DETAIL="A release tarball or plain directory has no commit to compare; deployment is not measurable this way."
    emit
fi

INSTALLED=$(git -C "$GC_PACK_DIR" rev-parse HEAD 2>/dev/null)
if [ -z "$INSTALLED" ]; then
    STATUS=undetermined
    REASON="installed pack at $GC_PACK_DIR has no resolvable HEAD"
    emit
fi

# ---------------------------------------------------------------------------
# 5. Evaluate every matching import. One satisfying BOTH conjuncts is enough —
#    gp-apx asks for "live in at least one city", and a city may import the same
#    pack several times (a city-wide pack: plus a rig: import per rig).
#
#    When none passes, the reason must name the nearest miss rather than the
#    last one looked at: "pin is behind" and "pin advanced but was never
#    installed" have different remediations, and the operator reads this field.
# ---------------------------------------------------------------------------
NEAREST_STATUS=""
NEAREST_REASON=""
NEAREST_PIN=""

# Rank the misses so the recorded reason is the most actionable one, not an
# arbitrary one: a pin that already contains the fix and merely needs installing
# is a closer miss than a pin that never received it, which in turn is closer
# than a pin this repo cannot even resolve.
rank_of() {
    case "$1" in
        skew) printf '3' ;;
        behind) printf '2' ;;
        *) printf '1' ;;
    esac
}

note_miss() {
    local kind="$1" reason="$2" pin="$3"
    if [ -z "$NEAREST_STATUS" ] || [ "$(rank_of "$kind")" -gt "$(rank_of "$NEAREST_STATUS")" ]; then
        NEAREST_STATUS="$kind"
        NEAREST_REASON="$reason"
        NEAREST_PIN="$pin"
    fi
}

while IFS=$'\t' read -r m_name m_commit; do
    [ -n "$m_name" ] || continue

    if [ -z "$m_commit" ]; then
        note_miss unresolvable "import $m_name has no recorded pin commit" ""
        continue
    fi

    # The pin must exist in THIS repo for containment to mean anything. A pin
    # from an unfetched fork or a pruned branch is unmeasurable, not contained.
    if ! git -C "$REPO" cat-file -e "${m_commit}^{commit}" 2>/dev/null; then
        note_miss unresolvable \
            "pin ${m_commit:0:8} ($m_name) is not present in this repo" "$m_commit"
        continue
    fi

    if ! git -C "$REPO" merge-base --is-ancestor "$SHA" "$m_commit" 2>/dev/null; then
        behind=$(git -C "$REPO" rev-list --count "${m_commit}..${SHA}" 2>/dev/null)
        note_miss behind \
            "pin ${m_commit:0:8} ($m_name) does not contain ${SHA:0:8}${behind:+ (${behind} commit(s) ahead of the pin)}" \
            "$m_commit"
        continue
    fi

    # Conjunct (1) holds. Conjunct (2): the installed artifact must BE this pin.
    # Lock-and-install skew is the gp-9pa shape — the pin carries the fix while
    # the artifact agents load does not — so it is a miss, with its own fix.
    if [ "$INSTALLED" != "$m_commit" ]; then
        note_miss skew \
            "pin ${m_commit:0:8} ($m_name) contains ${SHA:0:8} but the installed pack is at ${INSTALLED:0:8}" \
            "$m_commit"
        continue
    fi

    STATUS=deployed
    REASON="pin ${m_commit:0:8} ($m_name) contains ${SHA:0:8} and the installed pack resolves to it"
    PIN="$m_commit"
    emit
done <<<"$MATCHED_ROWS"

# ---------------------------------------------------------------------------
# 6. No import satisfied both conjuncts.
# ---------------------------------------------------------------------------
PIN="$NEAREST_PIN"
case "$NEAREST_STATUS" in
    behind | skew)
        STATUS=authored_not_deployed
        REASON="$NEAREST_REASON"
        DETAIL=$(
            printf '%s\n' "The fix is merged but agents do not load it yet."
            printf '%s\n' "Remediation: advance the import pin, then reinstall and reload --"
            printf '%s\n' "  update the import in city.toml (or the rig's [rigs.imports] entry)"
            printf '%s\n' "  gc import install"
            printf '%s\n' "  gc reload"
        )
        ;;
    *)
        # Could not evaluate containment at all. Not provably undeployed, and
        # certainly not deployed.
        STATUS=undetermined
        REASON="${NEAREST_REASON:-no evaluable pin for $ORIGIN_KEY}"
        ;;
esac
emit
