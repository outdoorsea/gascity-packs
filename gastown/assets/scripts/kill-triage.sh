#!/usr/bin/env bash
# kill-triage.sh — decide whether a PID may be killed by an automated patrol
# step. Read-only: it measures, prints, and exits. It never signals anything.
# The deacon's orphan-process-cleanup and dolt-health steps own the kill; this
# owns the refusal.
#
# The gap it closes: two patrol steps converted a heuristic signal directly into
# an irreversible action with nothing in between. Both fired on a HEALTHY town
# on 2026-07-31 (gp-aik):
#
#   orphan-process-cleanup detected orphans with `ps aux | grep -E 'claude|node'
#   | grep '?'`. On the reporting host that matched 95 processes: five separate
#   cities' tmux servers, Discord and Claude.app helpers, a gemini node process,
#   and every live agent in this town. Zero were orphans. Worst of all it
#   matched THIS town's own tmux server — `ps aux` prints the server's full
#   argv, which contains the `exec claude ...` it launched, so the town's
#   session host matches a 'claude' grep, sits at ppid=1, and shows TTY '?'.
#   It satisfies both stated orphan heuristics. Killing it takes down every
#   agent in the town, including the deacon running the step.
#
#   dolt-health reported zombie_count=1 and the step said to kill the pid. That
#   pid was stat=Ss — not a Unix zombie — six minutes old, 669MB resident, with
#   a live agent for a parent. It was a working server that agent was using.
#   `zombie_count` does not mean Z; a prior cycle had 2 of 14 flagged servers
#   live and in use.
#
# The shared defect is not either query. It is that a single unverified query
# was sufficient authority to kill. gp-9ur required pane corroboration before a
# WARRANT for exactly this reason; this is the same rule on the KILL paths,
# which gp-9ur does not cover.
#
# Three questions must all be answered before a kill is permitted, and any one
# of them failing is a refusal:
#
#   1. Is it OURS?        A process this town cannot claim is never this town's
#                         to kill, however orphaned it looks.
#   2. Is it ABANDONED?   ppid=1 is a hypothesis, not proof — the town's own
#                         session host sits at ppid=1 permanently. For dolt,
#                         "zombie" must mean stat=Z, not a reporter's field name.
#   3. Is anything USING it?  A process with live children is hosting them, and
#                         a server with a live ancestor is somebody's working
#                         server.
#
# Output: one TSV row per PID on stdout, column header on stderr.
#
#   verdict <TAB> pid <TAB> stat <TAB> ppid <TAB> owner <TAB> reason
#
#   kill-candidate       every refusal test passed — the caller may propose a kill
#   refuse-not-ours      ancestry/env place it in another city, or nowhere we can claim
#   refuse-live-agent    ancestry reaches THIS town's session host — it is a live agent
#   refuse-session-host  it IS a session host, or has live children depending on it
#   refuse-not-zombie    --require-zombie was set and stat is not Z
#   refuse-unverifiable  process state could not be read — never a licence to kill
#
# Exit codes:  0 = no kill candidates (everything refused, or no PIDs given)
#              1 = at least one kill-candidate on stdout
#              2 = the check could not run — nothing was triaged, which is NOT
#                  a clearance to kill anything
#
# The 0/1 polarity is deliberate and is the opposite of a "did it pass" check.
# The safe default — the value you get from an empty run, a refusal, or an
# unhandled edge — is 0/no-candidates. A caller that ignores this script's
# output entirely still kills nothing.
#
# Env:
#   GC_CITY   city root (auto-discovered if unset, walks up looking for city.toml)
#
# Usage:
#   kill-triage.sh --pid 61677
#   kill-triage.sh --require-zombie --pid 61677 --pid 61680
#
# Callers pass pids explicitly. There is deliberately no "read the reporter's
# list for me" mode: the whole point is that a reporter's list is a set of
# suspects, and making it one argument away from a kill is the shape of the bug
# this exists to prevent.

set -euo pipefail

REQUIRE_ZOMBIE=0
PIDS=()

usage() {
    cat >&2 <<'USAGE'
usage: kill-triage.sh [--require-zombie] --pid <pid> [--pid <pid> ...]

  --pid <pid>        a PID to triage (repeatable)
  --require-zombie   additionally require stat=Z (use for "zombie" reports whose
                     field name does not actually mean a Unix zombie)
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --pid)
            [ $# -ge 2 ] || { echo "kill-triage: --pid needs a value" >&2; exit 2; }
            PIDS+=("$2"); shift 2 ;;
        --require-zombie)
            REQUIRE_ZOMBIE=1; shift ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            echo "kill-triage: unknown argument '$1'" >&2; usage; exit 2 ;;
    esac
done

# Resolve city root: env wins, else walk up from cwd looking for city.toml.
if [ -z "${GC_CITY:-}" ]; then
    dir=$(pwd)
    while [ "$dir" != "/" ]; do
        if [ -f "$dir/city.toml" ]; then
            GC_CITY="$dir"
            break
        fi
        dir=$(dirname "$dir")
    done
fi

if [ -z "${GC_CITY:-}" ] || [ ! -f "$GC_CITY/city.toml" ]; then
    echo "kill-triage: GC_CITY not set and no city.toml found — cannot establish" >&2
    echo "  which town owns these processes, so nothing can be cleared for a kill." >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# Process primitives. Kept tiny and separately testable; every one of them
# returns empty rather than guessing when the process is gone.
# ---------------------------------------------------------------------------

# Every caller passes a trailing '=' in the format, which suppresses the ps
# header — so the value is line 1, not line 2. Getting that wrong returns empty
# for every field, and empty ppid/stat would sail through the numeric guards
# below as "unknown" rather than failing loudly.
proc_field() {  # proc_field <pid> <ps-format>
    ps -o "$2" -p "$1" 2>/dev/null | sed -n '1p' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

proc_ppid() { proc_field "$1" ppid=; }
proc_stat() { proc_field "$1" stat=; }
proc_comm() { proc_field "$1" comm=; }

proc_exists() { kill -0 "$1" 2>/dev/null || ps -p "$1" >/dev/null 2>&1; }

# Full argv. Used only to recognise a tmux server and its -L socket; never to
# decide ownership, which is the mistake that started all this.
proc_args() { ps -o command= -p "$1" 2>/dev/null | tr '\n' ' '; }

proc_children() { pgrep -P "$1" 2>/dev/null || true; }

# Resolve a path through symlinks so two spellings of one directory compare
# equal. macOS reports cwd under /private/var while $TMPDIR says /var, and an
# unnormalised string compare would call a process foreign purely over that.
canon() { (cd "$1" 2>/dev/null && pwd -P) || printf '%s' "$1"; }

# Attribute a process to a city. Returns:
#   ours            positively this town's
#   foreign:<hint>  positively some other town's
#   unknown         not attributable — which is a refusal, never a licence
#
# NOTE for anyone tempted to reach for `ps eww` here: on macOS it does NOT
# expose another process's environment, only its argv. It *looks* like it works
# against a Gas Town tmux server, because that server's own command line carries
# `-e GC_CITY=...` flags — so a grep for GC_CITY= hits the ARGUMENTS and reads
# like a successful environment probe. Every non-tmux process then comes back
# empty. That false positive is precisely the "matching on command text" the
# bead asked to stop doing, so ownership resolves through the process tree and
# the working directory instead.
proc_attribution() {  # proc_attribution <pid>
    local pid="$1" env_city="" cwd=""

    # Linux exposes the environment directly, and it is the strongest signal.
    if [ -r "/proc/$pid/environ" ]; then
        env_city=$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null \
                   | sed -n 's/^GC_CITY=//p' | head -1)
    fi
    if [ -n "$env_city" ]; then
        if [ "$(canon "$env_city")" = "$CITY_CANON" ]; then
            printf 'ours'
        else
            printf 'foreign:%s' "$env_city"
        fi
        return 0
    fi

    # Working directory. Both platforms expose it, and on macOS it is the only
    # attribution route available.
    if [ -r "/proc/$pid/cwd" ]; then
        cwd=$(readlink -f "/proc/$pid/cwd" 2>/dev/null)
    elif command -v lsof >/dev/null 2>&1; then
        cwd=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)
    fi

    if [ -n "$cwd" ]; then
        cwd=$(canon "$cwd")
        case "$cwd/" in
            "$CITY_CANON"/*) printf 'ours'; return 0 ;;
        esac
        # A cwd outside our root does not PROVE another owner — a process of
        # ours may chdir anywhere — so this is reported as unattributable
        # rather than foreign. Both refuse; only the reason differs, and
        # claiming more certainty than we have is how this class of bug starts.
        printf 'unknown:cwd=%s' "$cwd"
        return 0
    fi

    printf 'unknown'
}

# Is this pid a tmux server? A server is `tmux ... -L <socket> ...` reparented
# to init. Session hosts are the single most destructive thing on this list:
# killing one takes every agent in its city with it.
proc_tmux_socket() {  # -> socket name, or empty if not a tmux server
    local pid="$1" args comm
    comm=$(proc_comm "$pid")
    case "$comm" in *tmux*) ;; *) return 0 ;; esac
    args=$(proc_args "$pid")
    printf '%s' "$args" | sed -n 's/.*-L \([^ ]*\).*/\1/p' | head -1
}

# ---------------------------------------------------------------------------
# Establish OUR session host — the anchor every ownership question resolves
# against. Two independent routes, and if neither answers we exit 2 rather
# than proceed. An unresolvable anchor must never read as "nothing is ours,
# so everything is killable"; it means we cannot triage at all.
# ---------------------------------------------------------------------------

CITY_SOCKET=$(basename "$GC_CITY")
CITY_CANON=$(canon "$GC_CITY")
OWN_HOST=""

# Route 1: walk our own ancestry. Convention-independent — if we are running
# inside the town, the server hosting us IS the town's session host.
walk_to_host() {  # walk_to_host <pid> -> host pid, or empty
    local pid="$1" hops=0 sock
    while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null && [ "$hops" -lt 64 ]; do
        sock=$(proc_tmux_socket "$pid")
        if [ -n "$sock" ] && [ "$(proc_ppid "$pid")" = "1" ]; then
            printf '%s' "$pid"
            return 0
        fi
        pid=$(proc_ppid "$pid")
        hops=$((hops + 1))
    done
    return 0
}

OWN_HOST=$(walk_to_host "$$")

# Route 2: match a tmux server whose -L socket is this city. Covers invocation
# from outside any agent session (an operator shell, a test harness).
if [ -z "$OWN_HOST" ]; then
    while read -r cand; do
        [ -n "$cand" ] || continue
        [ "$(proc_ppid "$cand")" = "1" ] || continue
        if [ "$(proc_tmux_socket "$cand")" = "$CITY_SOCKET" ]; then
            OWN_HOST="$cand"
            break
        fi
    done <<<"$(pgrep -x tmux 2>/dev/null || true)"
fi

# GC_TRIAGE_ANCHOR lets the test suite pin the anchor to a fixture process tree
# instead of the live host. It is not a supported operator knob: overriding the
# anchor changes which processes read as "ours", so it stays test-only.
if [ -n "${GC_TRIAGE_ANCHOR:-}" ]; then
    OWN_HOST="$GC_TRIAGE_ANCHOR"
fi

if [ -z "$OWN_HOST" ]; then
    echo "kill-triage: cannot identify this town's session host (city=$CITY_SOCKET)." >&2
    echo "  Without an anchor, no process can be positively attributed to this" >&2
    echo "  town — and 'unattributable' is a refusal, never a licence to kill." >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# Triage
# ---------------------------------------------------------------------------

# Does <pid>'s ancestry reach <host>? This is the ownership test that replaces
# matching on command text. It answers "who is actually running this?", which
# is the question the command string only appeared to answer.
ancestry_reaches() {  # ancestry_reaches <pid> <host>
    local pid="$1" host="$2" hops=0
    while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null && [ "$hops" -lt 64 ]; do
        [ "$pid" = "$host" ] && return 0
        pid=$(proc_ppid "$pid")
        hops=$((hops + 1))
    done
    return 1
}

emit() {  # emit <verdict> <pid> <stat> <ppid> <owner> <reason>
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6"
}

printf 'verdict\tpid\tstat\tppid\towner\treason\n' >&2

CANDIDATES=0

for pid in "${PIDS[@]:-}"; do
    [ -n "$pid" ] || continue

    case "$pid" in
        ''|*[!0-9]*)
            emit refuse-unverifiable "$pid" - - - "not a numeric pid"
            continue ;;
    esac

    if ! proc_exists "$pid"; then
        emit refuse-unverifiable "$pid" - - - "process does not exist (already gone)"
        continue
    fi

    stat=$(proc_stat "$pid"); stat=${stat:--}
    ppid=$(proc_ppid "$pid"); ppid=${ppid:--}

    # --- Never kill a session host, and never kill something being depended on.
    sock=$(proc_tmux_socket "$pid")
    if [ -n "$sock" ]; then
        emit refuse-session-host "$pid" "$stat" "$ppid" "city:$sock" \
            "tmux session host for city '$sock' — killing it kills every agent it hosts"
        continue
    fi

    # --- Question 1: is it ours? Ancestry first, then environment.
    #
    # Ownership is settled BEFORE "is anything using it", so a foreign process
    # is reported as foreign rather than as a busy one. Both are refusals, so
    # the order cannot make an unsafe call safe or vice versa — but the reason
    # string is what an operator acts on, and "another city owns this" is the
    # fact worth surfacing. The tmux-server check above stays ahead of both:
    # our own session host would otherwise match its own ancestry and be
    # described as a live agent, which is true but badly misleading for the
    # one process whose death takes the town with it.
    owner=""
    if ancestry_reaches "$pid" "$OWN_HOST"; then
        # It descends from OUR session host, so something live is above it.
        # This is the check that would have spared all 11 kittyhawk processes,
        # and separately the dolt server whose parent was a working agent.
        if [ "$REQUIRE_ZOMBIE" -eq 1 ]; then
            reason="a live ancestor in this town is using it (chain reaches session host $OWN_HOST)"
        else
            reason="descends from this town's session host ($OWN_HOST) — a live agent, not an orphan"
        fi
        emit refuse-live-agent "$pid" "$stat" "$ppid" "city:$CITY_SOCKET" "$reason"
        continue
    fi

    # Not under our host. Before treating it as foreign, check whether it is a
    # reparented process that still names this town in its environment — that
    # is the only shape a genuine orphan of ours can have.
    attribution=$(proc_attribution "$pid")
    case "$attribution" in
        ours)
            owner="city:$CITY_SOCKET" ;;
        foreign:*)
            emit refuse-not-ours "$pid" "$stat" "$ppid" \
                "city:$(basename "${attribution#foreign:}")" \
                "belongs to ${attribution#foreign:} — a different town, not ours to kill"
            continue ;;
        *)
            # Not attributable. This is the arm that keeps another city's
            # agents, the desktop apps, and every unrelated daemon alive.
            emit refuse-not-ours "$pid" "$stat" "$ppid" "unknown" \
                "cannot attribute to this town (${attribution}) — unattributable is a refusal"
            continue ;;
    esac

    # --- Question 3: is anything live still using it? Asked before question 2
    # because it is the more absolute bar: a process with dependents must not be
    # killed even when the signal that named it turns out to be perfectly right.
    children=$(proc_children "$pid" | grep -c . || true)
    if [ "${children:-0}" -gt 0 ]; then
        emit refuse-session-host "$pid" "$stat" "$ppid" "$owner" \
            "has $children live child process(es) depending on it"
        continue
    fi

    # --- Question 2: is it actually in the state the signal claimed?
    if [ "$REQUIRE_ZOMBIE" -eq 1 ]; then
        case "$stat" in
            Z*) ;;
            *)
                emit refuse-not-zombie "$pid" "$stat" "$ppid" "$owner" \
                    "stat=$stat is not Z — a 'zombie' report named it, the kernel does not"
                continue ;;
        esac
    fi

    # ppid=1 is the hypothesis that got us here, not the proof. By this point it
    # has been corroborated: the process is positively ours by environment, it
    # hosts nothing, and nothing live is above it.
    if [ "$ppid" != "1" ] && [ "$REQUIRE_ZOMBIE" -eq 0 ]; then
        emit refuse-live-agent "$pid" "$stat" "$ppid" "$owner" \
            "reparented check failed: ppid=$ppid is a live parent, so it is not abandoned"
        continue
    fi

    emit kill-candidate "$pid" "$stat" "$ppid" "$owner" \
        "ours by environment, hosts nothing, no live parent, state corroborated"
    CANDIDATES=$((CANDIDATES + 1))
done

[ "$CANDIDATES" -gt 0 ] && exit 1
exit 0
