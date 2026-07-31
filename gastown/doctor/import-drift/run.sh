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
# Semantics: the local count is a LOWER BOUND, and at zero it is not a verdict
# at all (gp-jlt). The pack clone is content-addressed by (source, sha) and
# cloned ONCE when the pin is created, then never fetched again — so its
# `origin/main` is a fossil recording where main stood at pin time. For the
# ordinary pin, cut from the tip of main, that fossil equals HEAD forever, and
# `rev-list --count HEAD..origin/main` returns 0 however far main has since
# advanced. Measured on this city's own pack cache: six of eleven clones had
# HEAD == origin/main exactly, including the one pinned at 06c8a63f, which
# reported 0 while main had moved 9 commits past it.
#
# So the check written to make staleness loud could only ever catch a pin that
# was BORN behind. A pin that BECAME stale — the entire case it exists for —
# read as "pin is current with origin/main". That is not wrong in the safe
# direction. A missing check leaves you looking; a false green stops you
# looking, and this one stopped three shipped fixes from being noticed while
# each still had an active symptom in the town.
#
# Currency is therefore established by asking the remote, not by trusting the
# fossil: one bounded `git ls-remote` for the branch tip. That is a single
# refs-only round trip with no object transfer — not the fetch the original
# design rightly refused on doctor's per-check time budget. When the probe
# answers, the verdict is authoritative. When it cannot answer (offline, no way
# to bound the call, or an operator-named local ref), the check falls back to
# the local view and says which one it used — and a zero measured against refs
# that have never been re-fetched is reported as UNVERIFIED, never as current.
#
# Exit codes: 0=OK, 1=Warning, 2=Error
# stdout: first line=message, rest=details
#
# Environment:
#   GC_PACK_DIR         — absolute pack directory (set by gc; e.g. <clone>/gastown)
#   GC_PACK_DRIFT_REF   — override the reference branch (e.g. "origin/release").
#                         Also the seam the tests drive.
#   GC_PACK_DRIFT_NO_NETWORK — set to any non-empty value to skip the remote
#                         probe entirely (air-gapped cities; also the seam the
#                         tests drive to exercise the fallback deterministically).
#                         Note this is not a mute switch: a pin whose currency
#                         cannot be established still reports UNVERIFIED rather
#                         than green, because that is the true state. Silencing
#                         it would rebuild the false green this check exists to
#                         prevent.
#   GC_PACK_DRIFT_PROBE_TIMEOUT — seconds to bound the probe (default 5).
#   GC_PACK_DRIFT_FORCE_SHELL_BOUND — bound the probe with the built-in
#                         watchdog even where timeout(1) exists. Test seam, so
#                         the fallback stock macOS always takes is covered.
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

# Has anything ever refreshed this clone's remote-tracking refs?
#
# `git clone` does not write FETCH_HEAD; `git fetch` (and pull, and remote
# update) does. Its absence is therefore positive evidence that no fetch has
# ever run here, which means every remote-tracking ref still holds exactly what
# it held at clone time. That is the ordinary state of a content-addressed pack
# clone — and it is precisely what makes a local drift count of 0 worthless as
# a claim about the present.
refs_never_refetched() {
    local gitdir
    gitdir=$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null)
    [ -n "$gitdir" ] || return 1
    [ -e "$gitdir/FETCH_HEAD" ] && return 1
    return 0
}

# Ask the remote for a branch tip. One refs-only round trip, bounded,
# best-effort: sets PROBE_SHA and returns 0 only when the answer was actually
# measured. Every failure mode — no bounding tool, transport error, auth,
# timeout, or a branch that no longer exists upstream — collapses to "unknown"
# rather than to a verdict. That is the same discipline
# assets/scripts/polecat-worktree-reap.sh applies to its own ls-remote probes:
# unreachable is not absent, and a probe that did not run is not a finding.
PROBE_SHA=""

probe_remote_tip() {
    local branch="$1"
    PROBE_SHA=""
    [ -n "$branch" ] || return 1
    [ -z "${GC_PACK_DRIFT_NO_NETWORK:-}" ] || return 1

    local timeout_s="${GC_PACK_DRIFT_PROBE_TIMEOUT:-5}"
    local tmp rc=0
    tmp=$(mktemp 2>/dev/null) || return 1

    # GC_PACK_DRIFT_FORCE_SHELL_BOUND is the seam the tests drive. Without it the
    # hand-rolled branch below would only ever execute on hosts that happen to
    # lack coreutils — i.e. never in CI, and always on a stock Mac. An untested
    # bound on the one call that can hang is not a risk this check gets to take.
    local forced="${GC_PACK_DRIFT_FORCE_SHELL_BOUND:-}"
    if [ -z "$forced" ] && command -v timeout >/dev/null 2>&1; then
        timeout "$timeout_s" git -C "$dir" ls-remote --heads origin "refs/heads/$branch" >"$tmp" 2>/dev/null
        rc=$?
    elif [ -z "$forced" ] && command -v gtimeout >/dev/null 2>&1; then
        gtimeout "$timeout_s" git -C "$dir" ls-remote --heads origin "refs/heads/$branch" >"$tmp" 2>/dev/null
        rc=$?
    else
        # No timeout(1) — stock macOS, minimal containers. Bound it by hand
        # rather than skip: skipping would send every such host down the
        # unverified path forever, which reintroduces the fossil blind spot by
        # another route.
        local probe_pid watchdog_pid
        git -C "$dir" ls-remote --heads origin "refs/heads/$branch" >"$tmp" 2>/dev/null &
        probe_pid=$!
        ( sleep "$timeout_s"; kill -TERM "$probe_pid" 2>/dev/null ) >/dev/null 2>&1 &
        watchdog_pid=$!
        wait "$probe_pid" 2>/dev/null
        rc=$?
        kill -TERM "$watchdog_pid" 2>/dev/null
        wait "$watchdog_pid" 2>/dev/null
    fi

    if [ "$rc" -eq 0 ]; then
        # `--heads <pattern>` matches by tail glob, so compare the refname
        # exactly rather than trusting the first line.
        PROBE_SHA=$(awk -v r="refs/heads/$branch" '$2 == r { print $1; exit }' "$tmp" 2>/dev/null)
    fi
    rm -f "$tmp"
    [ -n "$PROBE_SHA" ]
}

# Only a remote-tracking ref can be checked against a remote. An operator who
# names a local ref through GC_PACK_DRIFT_REF is naming exactly the thing they
# want compared, and no fossil problem arises there — that ref mirrors nothing.
remote_branch=""
case "$ref" in
    origin/*) remote_branch="${ref#origin/}" ;;
esac

# Test the opt-out here rather than only inside the probe: a probe that was
# never attempted must not be reported as one that failed to reach origin.
# Same rule the verdicts follow — do not describe an unrun check as a finding.
probe_state="skipped"
if [ -n "$remote_branch" ] && [ -z "${GC_PACK_DRIFT_NO_NETWORK:-}" ]; then
    if probe_remote_tip "$remote_branch"; then
        probe_state="verified"
    else
        probe_state="unknown"
    fi
fi

case "$probe_state" in
    verified) probe_note="remote check: asked origin for $remote_branch just now" ;;
    unknown) probe_note="remote check: could not reach origin — falling back to this clone's refs" ;;
    *)
        if [ -n "${GC_PACK_DRIFT_NO_NETWORK:-}" ]; then
            probe_note="remote check: disabled by GC_PACK_DRIFT_NO_NETWORK"
        else
            probe_note="remote check: not applicable — $ref is not a remote-tracking ref"
        fi
        ;;
esac

age=$(fetch_age)
if refs_never_refetched; then
    # Saying "last fetched" here would be a fabrication: nothing was ever
    # fetched, and the mtime being read is the clone's own birthday. Reported
    # as a fetch age it looks reassuringly fresh on exactly the clones whose
    # view of upstream is frozen solid.
    age_note="upstream view: never re-fetched — refs are as of clone time, ${age:-unknown} day(s) ago"
else
    age_note="upstream view: last fetched ${age:-unknown} day(s) ago"
    [ -n "$age" ] || age_note="upstream view: last fetch time unknown"
fi

ref_sha=$(git -C "$dir" rev-parse "$ref" 2>/dev/null)

# Every warning ends the same way, so the remediation lives in one place.
remediation() {
    echo
    echo "Agents resolve formulas and commands from the PIN, not from the rig working"
    echo "tree. Returning a checkout to its default branch does not move this pin."
    echo "Remediation: advance the import pin, then reinstall and reload —"
    echo "  update the import in city.toml (or the rig's [rigs.imports] entry)"
    echo "  gc import install"
    echo "  gc reload"
}

# --- the remote answered, so its tip decides ----------------------------------
if [ "$probe_state" = verified ]; then
    if [ "$PROBE_SHA" = "$head_sha" ]; then
        echo "$pack pin is current with $ref — verified against origin"
        echo "pinned at ${head_sha:0:12}"
        echo "origin/$remote_branch tip is the same commit"
        echo "$probe_note"
        suspect_note
        exit 0
    fi

    if [ "$behind" -gt 0 ]; then
        echo "$pack is $behind commit(s) behind $ref — agents load the pinned version, not $ref"
        echo "pinned at  ${head_sha:0:12}"
        echo "$ref is at ${ref_sha:0:12}"
        echo "origin/$remote_branch tip is ${PROBE_SHA:0:12}"
        echo "$age_note (local count is a lower bound)"
    else
        # The gp-jlt shape exactly: the clone's own refs report zero because
        # they are a snapshot of pin time, while the live branch has moved.
        #
        # State only what was measured. The pin differing from the live tip is
        # a fact; "N commits behind" is not available here, because counting
        # would need the intervening objects and this clone never fetched them.
        # Nor is the direction certain — a pin cut from a commit that never
        # landed on the branch also lands in this arm — and asserting one would
        # be the same overclaiming that made the old green false.
        echo "$pack pin is NOT current with $ref — pin and live $ref tip differ"
        echo "pinned at  ${head_sha:0:12}"
        echo "$ref tip is ${PROBE_SHA:0:12} (live, just asked)"
        echo "this clone's $ref still reads ${ref_sha:0:12}, which is why a local count reports 0"
        echo "distance is not countable here: the commits between were never fetched"
        echo "$age_note"
    fi
    echo "$probe_note"
    echo "pack dir: $dir"
    suspect_note
    remediation
    exit 1
fi

# --- no remote answer: fall back to the local view, and say which one it is ---
if [ "$behind" -gt 0 ]; then
    echo "$pack is $behind commit(s) behind $ref — agents load the pinned version, not $ref"
    echo "pinned at  ${head_sha:0:12}"
    echo "$ref is at ${ref_sha:0:12}"
    echo "$age_note (count is a lower bound)"
    echo "$probe_note"
    echo "pack dir: $dir"
    suspect_note
    remediation
    exit 1
fi

# A local count of zero. Whether that is a currency claim or a fossil artefact
# depends entirely on whether the refs it was measured against were ever
# updated — so this is the branch where the false green used to live.
if [ -n "$remote_branch" ] && refs_never_refetched; then
    echo "$pack pin cannot be confirmed current with $ref — drift is UNVERIFIED"
    echo "pinned at ${head_sha:0:12}"
    echo "this clone's $ref also reads ${ref_sha:0:12}, so the local count is 0 —"
    echo "but no fetch has ever run here, so that ref is a snapshot of pin time."
    echo "A zero measured against it means the pin was current when it was CUT,"
    echo "not that it is current now."
    echo "$probe_note"
    echo "pack dir: $dir"
    suspect_note
    remediation
    exit 1
fi

# Either the operator named a local ref (nothing is mirroring anything, so the
# comparison is exactly what they asked for), or the remote refs really have
# been fetched at some point. Pass — but never silently about which it was.
if [ -z "$remote_branch" ]; then
    echo "$pack pin is current with $ref"
else
    echo "$pack pin is current with $ref as of the last fetch — not re-verified just now"
fi
echo "pinned at ${head_sha:0:12}"
echo "$age_note"
echo "$probe_note"
suspect_note
exit 0
