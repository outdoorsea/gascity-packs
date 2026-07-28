#!/usr/bin/env bash
# Pack doctor check: report how far this installed pack has drifted behind the
# branch it was cut from.
#
# Why this check exists (gp-0xl): a pack import is resolved once, pinned in
# packs.lock, and materialized into the content-addressed pack cache. Nothing
# afterwards compares that pin against its upstream. A city can therefore run a
# months-old pack — stale formulas, missing commands — while every other doctor
# check is green:
#
#   rig:<rig>:root-branch  watches the rig WORKING TREE, not the pin. Returning
#                          the working tree to main leaves it green and changes
#                          nothing about what agents actually load.
#   packv2-import-state    validates lock <-> install consistency. A pin that is
#                          internally consistent but 144 commits behind its own
#                          upstream is, by that definition, perfectly healthy.
#
# So staleness was invisible until someone diffed a formula by hand. This check
# makes it loud.
#
# Semantics: the count is a LOWER BOUND. It is measured against the remote refs
# already in the pack clone, which were last updated by `gc import install`. No
# network access happens here — doctor runs under a per-check time budget and a
# fetch would make it slow and flaky. A clone whose refs are themselves stale
# therefore under-reports drift; it never over-reports it. Wrong in the safe
# direction: no false alarms, and the reported number is never worse than the
# truth. The details block prints how old that view of upstream is so the number
# can be read with the right confidence.
#
# Exit codes: 0=OK, 1=Warning, 2=Error
# stdout: first line=message, rest=details
#
# Environment:
#   GC_PACK_DIR         — absolute pack directory (set by gc; e.g. <clone>/gastown)
#   GC_PACK_DRIFT_REF   — override the reference branch (e.g. "origin/release").
#                         Also the seam the tests drive.
#
# Note there is deliberately no GC_PACK_NAME here. gc injects that for pack
# COMMAND dispatch and for orders, but the doctor runner does not: it passes
# only GC_PACK_DIR plus the city/pack-state vars. Depending on it would make
# every message in production read "pack is N commits behind" while tests that
# set it by hand stayed green, so the name is derived from the pack directory
# instead — which is what gc actually hands us.

set -uo pipefail

dir="${GC_PACK_DIR:-.}"
pack=$(basename "$dir")

# A pack that is not a git clone cannot drift in any meaningful sense: registry
# release tarballs and plain local directories have no upstream to fall behind.
# Report OK rather than inventing a failure the operator cannot act on.
if ! git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
    echo "$pack is not a git clone — drift not applicable"
    exit 0
fi

head_sha=$(git -C "$dir" rev-parse HEAD 2>/dev/null)
if [ -z "$head_sha" ]; then
    echo "$pack clone has no HEAD commit — cannot measure drift"
    exit 2
fi

# Resolve the branch this pin should be compared against.
#
# `origin/HEAD` is authoritative for a real remote, but NOT for a file:// clone
# of a local working repo: there it mirrors whatever branch the source repo had
# checked out at clone time. This city hit exactly that — a file:// pack clone
# whose origin/HEAD pointed at an abandoned feature branch, so measuring against
# it would have compared a stale pin to a stale branch and called it healthy.
# Hence the explicit order, with the override first so an operator (and the
# tests) can always name the right branch.
resolve_ref() {
    if [ -n "${GC_PACK_DRIFT_REF:-}" ]; then
        if git -C "$dir" rev-parse --verify --quiet "${GC_PACK_DRIFT_REF}^{commit}" >/dev/null 2>&1; then
            printf '%s' "$GC_PACK_DRIFT_REF"
        fi
        return
    fi

    local sym
    sym=$(git -C "$dir" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null)
    sym=${sym#refs/remotes/}

    local candidate
    for candidate in "$sym" origin/main origin/master; do
        [ -n "$candidate" ] || continue
        if git -C "$dir" rev-parse --verify --quiet "${candidate}^{commit}" >/dev/null 2>&1; then
            printf '%s' "$candidate"
            return
        fi
    done
}

ref=$(resolve_ref)

# A clone with no resolvable reference branch is not benign — it is a pin whose
# freshness can never be evaluated, which is the very blind spot this check was
# written to close. Warn instead of passing silently.
if [ -z "$ref" ]; then
    echo "$pack: cannot resolve a reference branch — drift is unmeasurable"
    echo "pinned at ${head_sha:0:12}"
    if [ -n "${GC_PACK_DRIFT_REF:-}" ]; then
        echo "GC_PACK_DRIFT_REF=$GC_PACK_DRIFT_REF does not resolve in this clone"
    else
        echo "no origin/HEAD, origin/main or origin/master in this clone"
        echo "set GC_PACK_DRIFT_REF to name the branch this pack is cut from"
    fi
    exit 1
fi

behind=$(git -C "$dir" rev-list --count "HEAD..$ref" 2>/dev/null)
[ -n "$behind" ] || behind=0

# When origin/HEAD was auto-selected and names something other than the usual
# default, say so. A file:// pack clone inherits the source repo's checked-out
# branch as origin/HEAD, so a reference like "origin/fix/some-feature" usually
# means the pack was cut while that branch was checked out — and measuring
# against it can report a stale pin as healthy. Naming the conventional branch
# and its drift turns a confusing reference into a usable signal.
suspect_note() {
    [ -z "${GC_PACK_DRIFT_REF:-}" ] || return
    case "$ref" in origin/main | origin/master) return ;; esac

    local alt alt_behind
    for alt in origin/main origin/master; do
        git -C "$dir" rev-parse --verify --quiet "${alt}^{commit}" >/dev/null 2>&1 || continue
        alt_behind=$(git -C "$dir" rev-list --count "HEAD..$alt" 2>/dev/null)
        echo
        echo "NOTE: the reference branch was taken from this clone's origin/HEAD, which"
        echo "      names '$ref' rather than '$alt'. A file:// pack clone inherits"
        echo "      whatever branch its source repo had checked out, so this may be"
        echo "      measuring against an abandoned branch."
        echo "      Against $alt this pin is ${alt_behind:-?} commit(s) behind."
        echo "      Set GC_PACK_DRIFT_REF to pin the comparison to the right branch."
        return
    done
}

# How old is this clone's view of upstream? The drift count is only as fresh as
# the last fetch, so print it alongside every verdict — including the OK path,
# where "0 behind" against a months-old view is the one way this check can be
# quietly wrong.
fetch_age() {
    # No single marker is reliable: a clone that has never been re-fetched has
    # no FETCH_HEAD, and remote refs may live in packed-refs rather than as
    # loose files. Take the newest mtime across every marker a fetch could have
    # touched, so the answer degrades to "older than you think" rather than
    # "unknown".
    # Resolve against the ABSOLUTE git dir. `rev-parse --git-path` returns a
    # path relative to $dir, and GC_PACK_DIR is a subdirectory of the clone
    # (<clone>/gastown), so those relative paths do not resolve from wherever
    # this script happens to be running.
    local gitdir marker path mtime newest=0
    gitdir=$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null)
    [ -n "$gitdir" ] || return

    for marker in FETCH_HEAD packed-refs refs/remotes/origin refs/remotes/origin/HEAD ""; do
        path="$gitdir${marker:+/$marker}"
        [ -e "$path" ] || continue
        mtime=$(stat -f %m "$path" 2>/dev/null || stat -c %Y "$path" 2>/dev/null || echo 0)
        [ "$mtime" -gt "$newest" ] 2>/dev/null && newest=$mtime
    done
    [ "$newest" -gt 0 ] || return
    printf '%s' $(( ( $(date +%s) - newest ) / 86400 ))
}

age=$(fetch_age)
age_note="upstream view: last fetched ${age:-unknown} day(s) ago"
[ -n "$age" ] || age_note="upstream view: last fetch time unknown"

if [ "$behind" -eq 0 ]; then
    echo "$pack pin is current with $ref"
    echo "pinned at ${head_sha:0:12}"
    echo "$age_note"
    suspect_note
    exit 0
fi

ref_sha=$(git -C "$dir" rev-parse "$ref" 2>/dev/null)

echo "$pack is $behind commit(s) behind $ref — agents load the pinned version, not $ref"
echo "pinned at  ${head_sha:0:12}"
echo "$ref is at ${ref_sha:0:12}"
echo "$age_note (count is a lower bound)"
echo "pack dir: $dir"
suspect_note
echo
echo "Agents resolve formulas and commands from the PIN, not from the rig working"
echo "tree. Returning a checkout to its default branch does not move this pin."
echo "Remediation: advance the import pin, then reinstall and reload —"
echo "  update the import in city.toml (or the rig's [rigs.imports] entry)"
echo "  gc import install"
echo "  gc reload"
exit 1
