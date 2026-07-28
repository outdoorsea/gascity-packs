#!/usr/bin/env bash
# wisp-reconcile.sh — the one implementation of "this agent owns exactly one
# patrol wisp". Every patrol formula and agent prompt calls it instead of
# carrying its own copy of the query.
#
# The gap it closes: the reconcile guard ("reuse the queued wisp instead of
# pouring a duplicate") was copy-pasted shell in six files. Copies drift, and
# these drifted in two independent ways at once:
#
#   1. Flags. The query needs all three of `gc bd` (not bare `bd`),
#      `--type=molecule`, and `--include-infra`. Drop any one and it returns
#      empty. Some copies filtered `--type=wisp` — not a valid gc bd type, so
#      those matched nothing; the rest omitted `--include-infra`, and wisps are
#      ephemeral/infra beads that `gc bd list` hides by default.
#   2. Existence. `mol-refinery-patrol` and `mol-deacon-patrol` poured their
#      next wisp unconditionally — they carried no reconcile query at all.
#
# Either way the guard is a silent no-op: the query yields nothing, the agent
# concludes "no wisp exists", and pours another. The prior wisp leaks, forever,
# once per restart. A guard that fails OPEN is invisible; that is why this one
# fails CLOSED (see below) and why it lives in one tested file.
#
# THE SELF-SELECTION TRAP — worse than the leak, and the reason `--except`
# exists. A wisp is NOT reliably moved to in_progress while its agent runs it.
# Measured live on one ledger, same moment: gp-wisp-8vo was `open` while the
# witness was running it; gp-wisp-jo0 was `in_progress` while the refinery ran
# its own. Status therefore CANNOT distinguish "the wisp I am running" from
# "the wisp queued for next time". A next-iteration step that picks its next
# wisp from open wisps assigned to self picks ITSELF, burns no surplus, and
# then burns that same id — leaving ZERO wisps and a patrol loop that dies
# silently. A leak accumulates recoverable surplus; this one stops the engine.
# `queued` and `ensure` therefore exclude the current wisp by default
# ($GC_BEAD_ID), and `startup` — which is resuming that wisp, not replacing
# it — does not.
#
# FAIL-CLOSED CONTRACT — the single most important property here. When a query
# cannot be answered (gc down, Dolt wedged, unparseable output) this script
# prints nothing and exits 2. It NEVER reports "no wisps" from a broken query,
# because the caller's next move on an empty result is to pour. Callers must
# treat a non-zero exit as "do not pour", never as "nothing found". A blocked
# patrol cycle is recoverable and visible; a leaked wisp is neither.
#
# Verbs:
#   current            Print the wisp this session is running. $GC_BEAD_ID
#                      wins; otherwise the newest in_progress wisp. Empty
#                      output + exit 0 means "none" (a legitimate answer).
#   queued [--except <id>]
#                      Reconcile QUEUED wisps to exactly one: keep the first,
#                      burn the surplus, print the kept id. Empty output +
#                      exit 0 means "nothing queued". Excludes the current
#                      wisp ($GC_BEAD_ID unless --except overrides) — see the
#                      self-selection trap above.
#   startup            Reconcile in_progress AND open wisps to exactly one,
#                      preferring in_progress. For an agent's startup protocol,
#                      where either state is resumable. Excludes nothing: the
#                      current wisp is exactly what startup wants to resume.
#   ensure <formula> [--except <id>] [pour args...]
#                      `queued`, and if nothing is queued, pour <formula> and
#                      assign it. Prints the id of the wisp the agent should
#                      run NEXT — never the one it is running now. Extra args
#                      pass through to `gc bd mol wisp` (this is where
#                      per-formula `--var` flags go).
#
# `--except ''` disables the exclusion explicitly. Pass the id you got from
# `current` when $GC_BEAD_ID may be unset; the default covers the common case.
#
# Exit codes:  0 = reconciled (id on stdout, empty for current/queued/startup
#                  when the agent genuinely owns none)
#              1 = `ensure` could not pour or assign a wisp — caller must NOT
#                  burn its current wisp
#              2 = could not run: no $GC_AGENT, or a query that failed. Nothing
#                  was reconciled and nothing may be poured.
#
# Diagnostics go to stderr so `WISP=$(wisp-reconcile.sh ...)` stays clean.
#
# Env:
#   GC_AGENT     agent identity the wisps are assigned to (required)
#   GC_BEAD_ID   current wisp, when the runtime injected one (`current` only)
#
# Usage — always through the pack command, never by path. $GC_PACK_DIR is set
# for pack commands like this one, not in an agent's shell, so a formula that
# spells the path directly resolves "/assets/scripts/..." and finds nothing:
#   WISP=$(gc gastown wisp-reconcile startup) || exit 1
#   NEXT=$(gc gastown wisp-reconcile ensure mol-witness-patrol \
#            --except "$CURRENT" --var binding_prefix=gastown.) || exit 1

set -euo pipefail

# Print the header block: line 2 through the last comment line before code.
# The range is derived rather than hardcoded because a hardcoded one drifts as
# the header grows — the previous `2,70p` cut off mid-sentence and never
# printed exit code 2 at all, hiding the "query failed, do not pour"
# distinction that every caller's safety depends on.
usage() {
    sed -n '2,${/^#/!q; s/^# \{0,1\}//; p;}' "$0"
}

if [ "$#" -eq 0 ]; then
    echo "wisp-reconcile: a verb is required (current|queued|startup|ensure)" >&2
    exit 2
fi

case "$1" in
    -h|--help|help) usage; exit 0 ;;
esac

if [ -z "${GC_AGENT:-}" ]; then
    echo "wisp-reconcile: GC_AGENT is not set — cannot identify whose wisps to reconcile" >&2
    exit 2
fi

# wisp_ids <status> — every wisp root assigned to this agent in <status>, one
# id per line. Returns 2 (printing nothing) if the query could not be answered.
#
# The three things that make this query correct, stated once:
#
#   gc bd            not bare `bd`. Bare `bd` resolves the RIG ledger from cwd;
#                    patrol wisps live on the TOWN ledger and are invisible to
#                    it. Same silent-empty failure as a wrong filter.
#   --type=molecule  wisp roots are molecules. `--type=wisp` is not a valid
#                    gc bd type — it matches nothing.
#   --include-infra  wisps are ephemeral/infra beads, hidden by default.
#
# Measured on a live ledger while this defect was open:
#   (no flags) -> 0 | --include-gates -> 0 | --all -> 0 | --include-infra -> 2
wisp_ids() {
    status="$1"
    if ! _json=$(gc bd list --assignee="$GC_AGENT" --status="$status" \
                     --type=molecule --include-infra --limit=0 --json 2>/dev/null); then
        echo "wisp-reconcile: 'gc bd list --status=$status' failed — NOT reconciling." \
             "A failed query must never read as 'no wisps'." >&2
        return 2
    fi
    # A blank body is not an empty list, and the difference is load-bearing:
    # `jq -r '.[].id'` exits 0 on empty input, so without this guard a gc that
    # exits 0 while printing nothing (truncated response, wedged Dolt) would
    # read as "no wisps" and the caller would pour. An empty ledger answers
    # "[]"; a blank answer means the query never ran.
    if [ -z "$(printf '%s' "$_json" | tr -d '[:space:]')" ]; then
        echo "wisp-reconcile: 'gc bd list --status=$status' exited 0 but printed nothing —" \
             "NOT reconciling. An empty ledger answers '[]', never ''." >&2
        return 2
    fi
    if ! printf '%s' "$_json" | jq -r '.[].id' 2>/dev/null; then
        echo "wisp-reconcile: could not parse the --status=$status listing — NOT reconciling." >&2
        return 2
    fi
}

# keep_one <id...> — print the first id, burn every other. A burn that fails is
# a warning, not an error: the invariant this script promises is "the caller
# gets exactly one id", and a surplus wisp that survives is swept by the next
# cycle or by the deacon. Aborting here would strand the caller with no wisp at
# all, which is strictly worse.
keep_one() {
    _keep=''
    for _id in "$@"; do
        if [ -z "$_keep" ]; then
            _keep="$_id"
            continue
        fi
        echo "wisp-reconcile: burning surplus wisp $_id" >&2
        gc bd mol burn "$_id" --force >&2 \
            || echo "wisp-reconcile: could not burn surplus wisp $_id (leaving it for the next sweep)" >&2
    done
    [ -z "$_keep" ] || printf '%s\n' "$_keep"
}

cmd_current() {
    if [ -n "${GC_BEAD_ID:-}" ]; then
        printf '%s\n' "$GC_BEAD_ID"
        return 0
    fi
    _ids=$(wisp_ids in_progress) || return 2
    # Unquoted on purpose: split the newline-separated ids into positional args.
    set -- $_ids
    [ "$#" -eq 0 ] || printf '%s\n' "$1"
}

# $EXCEPT is the wisp that must never be offered as "next". It defaults to the
# wisp this session is running, because selecting that one as next and then
# burning it is how a patrol loop reaches zero wisps and stops. `--except <id>`
# overrides it (pass the id from `current` when $GC_BEAD_ID is unset);
# `--except ''` disables the exclusion.
EXCEPT="${GC_BEAD_ID:-}"

# parse_except <args...> — consume `--except <id>` / `--except=<id>` wherever it
# appears, set $EXCEPT, and leave everything else in the $REST array for the
# caller. Splitting it out keeps the flag working identically for `queued` and
# for `ensure`, whose remaining args are pour flags that must pass through
# untouched.
#
# `--except ''` is meaningful (it disables the exclusion), so an empty value is
# accepted; only a missing one is an error.
parse_except() {
    REST=()
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --except)
                if [ "$#" -lt 2 ]; then
                    echo "wisp-reconcile: --except requires a value" \
                         "(use --except '' to disable the exclusion)" >&2
                    return 2
                fi
                EXCEPT="$2"
                shift 2
                ;;
            --except=*)
                EXCEPT="${1#--except=}"
                shift
                ;;
            *)
                REST[${#REST[@]}]="$1"
                shift
                ;;
        esac
    done
}

# drop_except <id...> — echo every id that is not $EXCEPT.
drop_except() {
    for _c in "$@"; do
        [ -n "$_c" ] || continue
        if [ -n "$EXCEPT" ] && [ "$_c" = "$EXCEPT" ]; then
            echo "wisp-reconcile: skipping current wisp $_c (never a candidate for 'next')" >&2
            continue
        fi
        printf '%s\n' "$_c"
    done
}

cmd_queued() {
    parse_except ${1+"$@"} || return 2
    if [ "${#REST[@]}" -ne 0 ]; then
        echo "wisp-reconcile: queued takes no positional arguments (got: ${REST[*]})" >&2
        return 2
    fi
    _ids=$(wisp_ids open) || return 2
    set -- $_ids
    _ids=$(drop_except ${1+"$@"})
    set -- $_ids
    # ${1+"$@"} rather than "$@": bash 3.2 under `set -u` treats an empty "$@"
    # as unbound. The fleet includes macOS.
    keep_one ${1+"$@"}
}

cmd_startup() {
    _in_progress=$(wisp_ids in_progress) || return 2
    _open=$(wisp_ids open) || return 2
    # in_progress first so it wins the "keep the first" rule — a wisp the agent
    # was already running is the more faithful resume point than a queued one.
    set -- $_in_progress $_open
    keep_one ${1+"$@"}
}

cmd_ensure() {
    parse_except ${1+"$@"} || return 2
    set -- ${REST[@]+"${REST[@]}"}
    if [ "$#" -eq 0 ]; then
        echo "wisp-reconcile: ensure requires a formula name" >&2
        return 2
    fi
    _formula="$1"
    shift

    _existing=$(cmd_queued) || return 2
    if [ -n "$_existing" ]; then
        echo "wisp-reconcile: reusing queued wisp $_existing (not pouring a duplicate)" >&2
        printf '%s\n' "$_existing"
        return 0
    fi

    # stdout and stderr are captured SEPARATELY, never folded with 2>&1. A
    # single stderr warning merged into the payload makes it unparseable, and
    # an unparseable payload from a SUCCESSFUL pour is the worst outcome
    # available here: the wisp exists, its id is unreadable, and it stays
    # unassigned — invisible to the assignee-filtered query, leaking exactly
    # like the duplicates this script exists to prevent.
    _err=$(mktemp) || {
        echo "wisp-reconcile: could not create a temp file — not pouring." >&2
        return 1
    }
    if ! _poured=$(gc bd mol wisp "$_formula" --root-only ${1+"$@"} --json 2>"$_err"); then
        echo "wisp-reconcile: could not pour $_formula: $(cat "$_err")" >&2
        rm -f "$_err"
        return 1
    fi
    rm -f "$_err"
    _new=$(printf '%s' "$_poured" | jq -r '.new_epic_id // empty' 2>/dev/null) || _new=''
    if [ -z "$_new" ]; then
        # Fail closed for the caller, but say plainly that a wisp may exist:
        # this is the one path where a leak can survive the script.
        echo "wisp-reconcile: pour of $_formula reported success but no wisp id could be read." \
             "A wisp may exist unassigned — check:" \
             "gc bd list --type=molecule --include-infra --limit=0" >&2
        return 1
    fi
    if ! gc bd update "$_new" --assignee="$GC_AGENT" >&2; then
        # An unassigned wisp is worse than none: it is invisible to the
        # assignee-filtered reconcile query, so it would leak exactly like the
        # duplicates this script exists to prevent. Burn it rather than leave
        # it — best effort, since whatever broke the assign may break the burn.
        echo "wisp-reconcile: poured $_new but could not assign it to $GC_AGENT — burning it." >&2
        gc bd mol burn "$_new" --force >&2 \
            || echo "wisp-reconcile: could not burn orphan wisp $_new — burn it by hand." >&2
        return 1
    fi
    printf '%s\n' "$_new"
}

VERB="$1"
shift

case "$VERB" in
    current) cmd_current ;;
    queued)  cmd_queued ${1+"$@"} ;;
    startup) cmd_startup ;;
    ensure)  cmd_ensure ${1+"$@"} ;;
    *)
        echo "wisp-reconcile: unknown verb '$VERB' (expected current|queued|startup|ensure)" >&2
        exit 2
        ;;
esac
