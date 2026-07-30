#!/usr/bin/env bash
# Pack doctor check: assert the pin this city DECLARES for the pack is the pin
# that is actually materialized and wired up.
#
# Why this check exists (gp-xb9, follow-up to gp-9pa / gp-0xl)
# ------------------------------------------------------------
# The sibling import-drift check makes a STALE pin loud: pinned at X, upstream
# has moved to Y. The failure found 2026-07-29 was a different shape and
# import-drift could not see it at all:
#
#   city.toml declared     051c35e
#   live .beads/formulas/  symlinked into cache de1a3627, whose HEAD was f69ec02
#                          — three days older than the declared pin
#   and a correctly-materialized cache for the declared pin (c82816ce) existed
#   on disk. It just was not the one wired up.
#
# Every pin-freshness check in the city was green, because each one compared a
# pin against itself:
#
#   packv2-import-state  validates lock <-> install consistency. A pin that is
#                        internally consistent is healthy by that definition.
#   import-drift         measures pinned-HEAD against upstream. It reads HEAD of
#                        whichever cache dir it is handed, so a wrongly-wired
#                        cache is measured as if it were the right one and the
#                        answer comes back "current".
#
# Nothing compared what the city DECLARES against what is on disk. This check
# closes that gap, on three axes drawn from the incident:
#
#   1. declared commit == HEAD of the cache the installed artifacts resolve into
#   2. the cache clone was made from the declared REMOTE (the wrongly-wired
#      cache de1a3627 had origin = file:///Users/jeremy/GitHub/gascity-packs
#      while city.toml declared an https:// URL — a local clone of a working
#      repo standing in for the published one)
#   3. the declared commit is an ANCESTOR of the branch it claims to come from
#      (051c35e was on side branch origin/fix/tmux-wheel-mouse-any-flag, whose
#      merge-base with main was Jun 17 — pinned to a commit that was never on
#      the mainline at all)
#
# Independence is the point
# -------------------------
# The DECLARED side is read straight out of the city's own TOML — pack.toml
# [imports.<pack>] for the city pin, city.toml [rigs.imports.<pack>] per rig.
# It is deliberately NOT read from `gc import status`, even though that would be
# less code: gc's import resolution is the layer under audit here. Ask gc for
# both sides of the comparison and the check agrees with the bug.
#
# The MATERIALIZED side is measured the way the incident was actually found: by
# resolving the artifact symlinks the rigs are really using and taking HEAD of
# the cache dir they land in. GC_PACK_DIR — the cache dir gc resolves the pack
# to right now — is checked too, and a disagreement between the two is itself
# reported, because "the artifacts point somewhere other than where gc thinks
# the pack lives" is precisely what happened.
#
# No network access. Doctor runs under a per-check time budget and a fetch would
# make this slow and flaky, so ancestry is evaluated against the remote refs
# already in the clone. When the declared commit is not present locally the
# check says so rather than guessing.
#
# Exit codes: 0=OK, 1=Warning, 2=Error
# stdout: first line=message, rest=details
#
# Environment (the doctor runner's contract, verified empirically against
# `gc doctor` with every inherited GC_* var scrubbed and a neutral cwd):
#   GC_PACK_DIR        — absolute pack directory (e.g. <cache>/<hash>/gastown)
#   GC_CITY_PATH       — absolute city root
#   GC_CITY            — absolute city root (same value; both are injected)
#   GC_PACK_STATE_DIR  — <city>/.gc/runtime/packs/<name>
#   GC_BIN             — path to the gc binary
#   cwd                — the city root
#   GC_PACK_PIN_REF    — override the mainline ref for the ancestry test
#                        (e.g. "origin/release"). Also the seam the tests drive.
#
# GC_PACK_NAME is NOT set for doctor checks — gc injects it for pack COMMAND
# dispatch and for orders, but not here. The pack name is therefore derived from
# the pack directory, which is what gc actually hands us. Reading it from
# GC_PACK_NAME with a fallback is the bug that made every import-drift message
# in production say "pack is N commits behind" while its suite, which set the
# variable itself, stayed green.

set -uo pipefail

dir="${GC_PACK_DIR:-.}"
pack=$(basename "$dir")

findings_hard=()
findings_soft=()
details=()

hard() { findings_hard+=("$1"); }
soft() { findings_soft+=("$1"); }
detail() { details+=("$1"); }

# ---------------------------------------------------------------------------
# City root
# ---------------------------------------------------------------------------
# Both GC_CITY_PATH and GC_CITY are injected, but prefer them in order and fall
# back to walking up from cwd (which the runner sets to the city root) so the
# check still works if that contract ever narrows to one variable.
find_city() {
    local candidate
    for candidate in "${GC_CITY_PATH:-}" "${GC_CITY:-}"; do
        [ -n "$candidate" ] || continue
        [ -f "$candidate/city.toml" ] && { printf '%s' "$candidate"; return; }
    done

    local d
    d=$(pwd -P 2>/dev/null) || return
    while [ -n "$d" ] && [ "$d" != "/" ]; do
        [ -f "$d/city.toml" ] && { printf '%s' "$d"; return; }
        d=$(dirname "$d")
    done
}

city=$(find_city)
if [ -z "$city" ]; then
    # A city we cannot locate is a pin whose declaration can never be read,
    # which is the blind spot this check exists to close. Warn; do not pass.
    echo "$pack: cannot locate the city root — declared pin is unreadable"
    echo "GC_CITY_PATH=${GC_CITY_PATH:-<unset>}"
    echo "GC_CITY=${GC_CITY:-<unset>}"
    echo "cwd=$(pwd -P 2>/dev/null)"
    echo "no city.toml found in either, or by walking up from cwd"
    exit 1
fi

# ---------------------------------------------------------------------------
# Declared pins
# ---------------------------------------------------------------------------
# Emits one TAB-separated record per declaration: scope, source, version.
#
# Hand-rolled rather than shelled out to a TOML parser because a doctor check
# may not assume anything beyond coreutils, and because reading gc's own view of
# the imports would defeat the independence this check depends on. Values are
# pulled as the first double-quoted string on the line, which is immune to
# trailing comments without needing to track quote state.
declared_pins() {
    local file="$1" want="$2"
    [ -f "$file" ] || return 0
    awk -v want="$want" '
        function qval(s) {
            if (match(s, /"[^"]*"/)) return substr(s, RSTART + 1, RLENGTH - 2)
            return ""
        }
        function flush() {
            if (scope != "" && (src != "" || ver != ""))
                printf "%s\t%s\t%s\n", scope, src, ver
            scope = ""; src = ""; ver = ""
        }
        {
            line = $0
            gsub(/^[ \t]+|[ \t]+$/, "", line)

            # A [[rigs]] array entry starts a new rig; its name arrives as a
            # key inside that table, before any [rigs.imports.*] subtable.
            if (line == "[[rigs]]") { flush(); rig = ""; sect = "RIG"; next }
            if (line == "[[pack]]") { flush(); packname = ""; sect = "PACK"; next }

            if (line ~ /^\[/) {
                flush()
                if (line == "[rigs.imports." want "]")      sect = "IMPORT_RIG"
                else if (line == "[imports." want "]")       sect = "IMPORT_CITY"
                else if (line ~ /^\[rigs\.imports\./)        sect = "OTHER"
                else if (line == "[rigs.imports]")           sect = "OTHER"
                else                                         sect = "OTHER"
                if (sect == "IMPORT_RIG")
                    scope = "rig:" (rig == "" ? "?" : rig)
                else if (sect == "IMPORT_CITY")
                    scope = "city"
                next
            }

            # Track the identifying key of the enclosing table.
            if (sect == "RIG"  && line ~ /^name[ \t]*=/) { rig = qval(line); next }
            if (sect == "PACK" && line ~ /^name[ \t]*=/) { packname = qval(line); next }

            # A [[pack]] entry naming this pack declares a source inline.
            if (sect == "PACK" && packname == want) {
                if (line ~ /^source[ \t]*=/)  { scope = "pack"; src = qval(line) }
                if (line ~ /^version[ \t]*=/) { scope = "pack"; ver = qval(line) }
                next
            }

            if (sect == "IMPORT_RIG" || sect == "IMPORT_CITY") {
                if (line ~ /^source[ \t]*=/)  src = qval(line)
                if (line ~ /^version[ \t]*=/) ver = qval(line)
            }
        }
        END { flush() }
    ' "$file"
}

# A full 40-hex commit, taken from `version = "sha:<hex>"` when present and
# otherwise from the /tree/<hex>/ segment of the source URL. Anything else — a
# branch name, a semver constraint — is not a pin we can compare, and is
# reported as unpinned rather than silently skipped.
commit_of() {
    local source="$1" version="$2" candidate=""
    case "$version" in
        sha:*) candidate=${version#sha:} ;;
    esac
    if [ -z "$candidate" ]; then
        candidate=$(printf '%s' "$source" |
            sed -n 's|.*/tree/\([0-9a-fA-F]\{40\}\)\(/.*\)\{0,1\}$|\1|p')
    fi
    case "$candidate" in
        [0-9a-fA-F][0-9a-fA-F]*)
            [ ${#candidate} -eq 40 ] && printf '%s' "$(printf '%s' "$candidate" | tr 'A-F' 'a-f')"
            ;;
    esac
}

# The ref named in a source URL s /tree/<ref>/ segment, when it is not a commit.
# `.../tree/main/switchyard-mcp` declares a branch; that branch, not the repo
# default, is the mainline this pin claims to come from.
branch_of() {
    printf '%s' "$1" | sed -n 's|.*/tree/\([^/]\{1,\}\)/.*|\1|p' |
        grep -Ev '^[0-9a-fA-F]{40}$' || true
}

records=()
while IFS= read -r rec; do
    [ -n "$rec" ] && records+=("$rec")
done < <(
    declared_pins "$city/pack.toml" "$pack"
    declared_pins "$city/city.toml" "$pack"
)

if [ ${#records[@]} -eq 0 ]; then
    # The pack is installed enough for its doctor checks to be running, so the
    # city declares it somewhere. Finding no declaration means the parse missed
    # it — report that rather than reporting a clean bill of health from a
    # comparison that never happened.
    echo "$pack: installed, but no declaration found in this city's TOML"
    echo "looked in $city/pack.toml  [imports.$pack]"
    echo "looked in $city/city.toml  [rigs.imports.$pack], [imports.$pack], [[pack]]"
    echo "pack dir: $dir"
    echo
    echo "Either the pack is installed without being declared, or this check"
    echo "failed to parse a declaration shape it should understand. Both are"
    echo "worth an eye: the declared pin is what every other assertion here"
    echo "compares against."
    exit 1
fi

# ---------------------------------------------------------------------------
# Materialized side
# ---------------------------------------------------------------------------
# A pack that is not a git clone has no commit identity to compare: registry
# release tarballs and plain local directories are materialized by copy. Report
# OK rather than inventing a failure the operator cannot act on. (The builtin
# core pack is exactly this — it is unpacked from the gc binary's embedded
# bootstrap and has no .git at all.)
if ! git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
    echo "$pack is not a git clone — pin materialization not applicable"
    echo "pack dir: $dir"
    exit 0
fi

head_sha=$(git -C "$dir" rev-parse HEAD 2>/dev/null)
if [ -z "$head_sha" ]; then
    echo "$pack clone has no HEAD commit — cannot identify the materialized pin"
    echo "pack dir: $dir"
    exit 2
fi
remote_url=$(git -C "$dir" remote get-url origin 2>/dev/null)

# Where the installed artifacts actually resolve to. This is the bead's own
# definition of the materialized pin, and the measurement that found the
# incident: the rigs' .beads/formulas/ entries are symlinks into the pack cache,
# so following one and taking HEAD of the pack dir it lands in reports what the
# agents are really loading — independently of where gc currently thinks the
# pack lives.
#
# Rig paths come from .gc/site.toml ([[rig]] name/path), because a rig s
# repository lives outside the city tree.
rig_paths() {
    local file="$city/.gc/site.toml"
    [ -f "$file" ] || return 0
    awk '
        function qval(s) {
            if (match(s, /"[^"]*"/)) return substr(s, RSTART + 1, RLENGTH - 2)
            return ""
        }
        { line = $0; gsub(/^[ \t]+|[ \t]+$/, "", line) }
        line == "[[rig]]" { sect = "RIG"; next }
        line ~ /^\[/      { sect = "OTHER"; next }
        sect == "RIG" && line ~ /^path[ \t]*=/ { print qval(line) }
    ' "$file"
}

# Resolve one artifact symlink to the pack directory that contains it:
#   <cache>/<hash>/<pack>/formulas/mol-x.toml  ->  <cache>/<hash>/<pack>
# Derived by walking up from the file rather than by string-matching the pack
# name, so a pack name that also appears earlier in the path cannot truncate it.
wired_pack_dir() {
    local link="$1" target parent
    target=$(cd "$(dirname "$link")" 2>/dev/null && realpath "$(basename "$link")" 2>/dev/null)
    [ -n "$target" ] || return
    parent=$(dirname "$(dirname "$target")")
    [ "$(basename "$parent")" = "$pack" ] || return
    printf '%s' "$parent"
}

wired_dirs=()
wired_rigs=()
while IFS= read -r rigpath; do
    [ -n "$rigpath" ] || continue
    [ -d "$rigpath/.beads/formulas" ] || continue
    for link in "$rigpath"/.beads/formulas/*.toml; do
        [ -L "$link" ] || continue
        w=$(wired_pack_dir "$link")
        [ -n "$w" ] || continue
        seen=0
        for existing in ${wired_dirs+"${wired_dirs[@]}"}; do
            [ "$existing" = "$w" ] && { seen=1; break; }
        done
        if [ "$seen" -eq 0 ]; then
            wired_dirs+=("$w")
            wired_rigs+=("$(basename "$rigpath")")
        fi
    done
done < <(rig_paths)

# The pin the agents actually load. When the artifacts resolve somewhere, that
# is authoritative; otherwise fall back to the dir gc handed us.
materialized_dir="$dir"
materialized_sha="$head_sha"
materialized_via="GC_PACK_DIR"

if [ ${#wired_dirs[@]} -gt 0 ]; then
    materialized_dir="${wired_dirs[0]}"
    materialized_via="installed artifacts in rig ${wired_rigs[0]}"
    materialized_sha=$(git -C "$materialized_dir" rev-parse HEAD 2>/dev/null)
    [ -n "$materialized_sha" ] || materialized_sha="$head_sha"

    # More than one distinct cache dir wired up across the rigs means the rigs
    # are running different builds of the same pack. Individually each may match
    # its own declaration; as a set it is a split brain.
    if [ ${#wired_dirs[@]} -gt 1 ]; then
        hard "rigs are wired to ${#wired_dirs[@]} different $pack caches"
        i=0
        while [ "$i" -lt ${#wired_dirs[@]} ]; do
            s=$(git -C "${wired_dirs[$i]}" rev-parse HEAD 2>/dev/null)
            detail "  rig ${wired_rigs[$i]} -> ${s:0:12} at ${wired_dirs[$i]}"
            i=$((i + 1))
        done
    fi

    # The artifacts point somewhere other than where gc resolves the pack. This
    # is the incident's exact shape, and the reason the materialized side is
    # measured from the symlinks rather than from GC_PACK_DIR alone.
    if [ "$(realpath "$materialized_dir" 2>/dev/null)" != "$(realpath "$dir" 2>/dev/null)" ]; then
        hard "installed artifacts resolve to a different cache than gc resolves $pack to"
        detail "  artifacts -> ${materialized_sha:0:12} at $materialized_dir"
        detail "  GC_PACK_DIR -> ${head_sha:0:12} at $dir"
    fi
fi

# ---------------------------------------------------------------------------
# Axis 1 — declared commit == materialized commit
# ---------------------------------------------------------------------------
declared_commits=()
for rec in "${records[@]}"; do
    IFS=$'\t' read -r scope src ver <<<"$rec"
    c=$(commit_of "$src" "$ver")
    if [ -z "$c" ]; then
        soft "$scope declares $pack without a commit pin"
        detail "  $scope: version=${ver:-<none>} source=${src:-<none>}"
        detail "         a floating ref cannot be compared to what is materialized"
        continue
    fi
    declared_commits+=("$scope|$c")
    if [ "$c" != "$materialized_sha" ]; then
        hard "$scope declares ${c:0:12} but ${materialized_sha:0:12} is materialized"
        detail "  $scope declared:  ${c:0:12}"
        detail "  materialized:     ${materialized_sha:0:12}  (via $materialized_via)"
    fi
done

# Declarations that disagree with each other. Every pin can match the artifacts
# it happens to be measured against and the set can still be incoherent, which
# is how a city ends up with a rig pin and a city pin that are each internally
# fine but wrong as a pair.
if [ ${#declared_commits[@]} -gt 1 ]; then
    distinct=$(printf '%s\n' "${declared_commits[@]}" | cut -d'|' -f2 | sort -u | wc -l | tr -d ' ')
    if [ "$distinct" -gt 1 ]; then
        hard "this city declares $distinct different $pack pins"
        for dc in "${declared_commits[@]}"; do
            detail "  ${dc%%|*} -> ${dc#*|}"
        done
        detail "  a pack has one command namespace and one set of formulas per pin;"
        detail "  scopes pinned apart run mismatched halves of the same pack"
    fi
fi

# ---------------------------------------------------------------------------
# Axis 2 — the clone came from the declared remote
# ---------------------------------------------------------------------------
# The wrongly-wired cache in the incident was a file:// clone of a local working
# repo standing in for the published https:// source. Its contents track
# whatever that working tree happened to have checked out, so a pin resolved
# through it means nothing — and it is invisible to every check that only
# compares commits.
scheme_of() {
    case "$1" in
        https://*)                printf 'https' ;;
        http://*)                 printf 'http' ;;
        ssh://* | git@* | git://*) printf 'ssh' ;;
        file://*)                 printf 'file' ;;
        /*)                       printf 'path' ;;
        *)                        printf 'other' ;;
    esac
}

if [ -n "$remote_url" ]; then
    materialized_remote=$(git -C "$materialized_dir" remote get-url origin 2>/dev/null)
    [ -n "$materialized_remote" ] || materialized_remote="$remote_url"
    got=$(scheme_of "$materialized_remote")

    for rec in "${records[@]}"; do
        IFS=$'\t' read -r scope src ver <<<"$rec"
        [ -n "$src" ] || continue
        wanted=$(scheme_of "$src")
        case "$wanted" in https | http | ssh) ;; *) continue ;; esac
        case "$got" in file | path) ;; *) continue ;; esac

        hard "$pack is materialized from a local clone while $scope declares a remote URL"
        detail "  $scope declares: $src"
        detail "  cache origin is: $materialized_remote"
        detail "                   ($got, not $wanted)"
        detail "  A local clone tracks whatever its source working tree has checked"
        detail "  out, so a commit resolved through it does not correspond to the"
        detail "  published history the declaration names."
        break
    done
fi

# ---------------------------------------------------------------------------
# Axis 3 — the declared commit is on the mainline it claims to come from
# ---------------------------------------------------------------------------
# A pin that is merely BEHIND its branch is ordinary staleness; import-drift
# already reports that. A pin that is not an ANCESTOR of its branch was never on
# that branch at all — in the incident, a commit on the abandoned side branch
# origin/fix/tmux-wheel-mouse-any-flag, whose merge-base with main was six weeks
# earlier. Advancing such a pin does not fix it; it has to be re-pointed.
#
# Reference resolution order is deliberately the INVERSE of import-drift's.
# There, origin/HEAD is tried first as the authoritative default branch. Here it
# is the last resort: origin/HEAD is the field a file:// clone corrupts, and
# testing "is this commit on the mainline" against a corrupted notion of the
# mainline is how the incident stayed green. An explicit override wins, then the
# conventional names, then origin/HEAD.
resolve_mainline() {
    local repo="$1" src="$2" candidate named
    if [ -n "${GC_PACK_PIN_REF:-}" ]; then
        git -C "$repo" rev-parse --verify --quiet "${GC_PACK_PIN_REF}^{commit}" >/dev/null 2>&1 &&
            printf '%s' "$GC_PACK_PIN_REF"
        return
    fi

    # A source URL naming a branch declares its own mainline.
    named=$(branch_of "$src")
    if [ -n "$named" ]; then
        for candidate in "origin/$named" "$named"; do
            git -C "$repo" rev-parse --verify --quiet "${candidate}^{commit}" >/dev/null 2>&1 &&
                { printf '%s' "$candidate"; return; }
        done
    fi

    local sym
    sym=$(git -C "$repo" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null)
    sym=${sym#refs/remotes/}
    for candidate in origin/main origin/master "$sym"; do
        [ -n "$candidate" ] || continue
        git -C "$repo" rev-parse --verify --quiet "${candidate}^{commit}" >/dev/null 2>&1 &&
            { printf '%s' "$candidate"; return; }
    done
}

for rec in "${records[@]}"; do
    IFS=$'\t' read -r scope src ver <<<"$rec"
    c=$(commit_of "$src" "$ver")
    [ -n "$c" ] || continue

    mainline=$(resolve_mainline "$materialized_dir" "$src")
    if [ -z "$mainline" ]; then
        soft "cannot resolve a mainline ref for $scope — ancestry unverifiable"
        detail "  $scope: no origin/main, origin/master or origin/HEAD in the cache clone"
        detail "         set GC_PACK_PIN_REF to name the branch this pin is cut from"
        continue
    fi

    # An absent commit cannot be placed on any branch. This is expected for a
    # shallow or partial clone, and is reported as unverifiable rather than as a
    # failure: no network access happens here, so "not present" is not evidence
    # of "not an ancestor".
    if ! git -C "$materialized_dir" rev-parse --verify --quiet "${c}^{commit}" >/dev/null 2>&1; then
        soft "$scope declares ${c:0:12}, which is not present in the cache clone"
        detail "  $scope: cannot verify ${c:0:12} is on $mainline — commit is absent locally"
        detail "         (no fetch happens here; doctor runs offline under a time budget)"
        continue
    fi

    if ! git -C "$materialized_dir" merge-base --is-ancestor "$c" "$mainline" >/dev/null 2>&1; then
        base=$(git -C "$materialized_dir" merge-base "$c" "$mainline" 2>/dev/null)
        when=""
        [ -n "$base" ] && when=$(git -C "$materialized_dir" log -1 --format=%cs "$base" 2>/dev/null)
        hard "$scope declares ${c:0:12}, which is not an ancestor of $mainline"
        detail "  $scope declared: ${c:0:12}"
        detail "  mainline:        $mainline at $(git -C "$materialized_dir" rev-parse --short=12 "$mainline" 2>/dev/null)"
        if [ -n "$base" ]; then
            detail "  merge-base:      ${base:0:12}${when:+ ($when)}"
        fi
        detail "  This commit was never on $mainline, so it is not stale — it is a"
        detail "  side branch. Advancing the pin will not help; re-point it."
    fi
done

# ---------------------------------------------------------------------------
# Verdict
# ---------------------------------------------------------------------------
context=(
    "pack dir:     $dir"
    "materialized: ${materialized_sha:0:12} at $materialized_dir"
    "              (via $materialized_via)"
)
for rec in "${records[@]}"; do
    IFS=$'\t' read -r scope src ver <<<"$rec"
    context+=("declared:     $scope -> ${ver:-<no version>}")
done

remediation=(
    ""
    "Agents resolve formulas and commands from the MATERIALIZED pin, not from the"
    "declaration and not from any rig working tree. Remediation:"
    "  correct the import in city.toml (or the city's pack.toml [imports.$pack])"
    "  gc import install"
    "  gc reload"
)

if [ ${#findings_hard[@]} -gt 0 ]; then
    echo "$pack: ${findings_hard[0]}"
    [ ${#findings_hard[@]} -gt 1 ] &&
        for f in "${findings_hard[@]:1}"; do echo "also: $f"; done
    for f in ${findings_soft+"${findings_soft[@]}"}; do echo "also: $f"; done
    printf '%s\n' ${details+"${details[@]}"}
    printf '%s\n' "${context[@]}"
    printf '%s\n' "${remediation[@]}"
    exit 2
fi

if [ ${#findings_soft[@]} -gt 0 ]; then
    echo "$pack: ${findings_soft[0]}"
    [ ${#findings_soft[@]} -gt 1 ] &&
        for f in "${findings_soft[@]:1}"; do echo "also: $f"; done
    printf '%s\n' ${details+"${details[@]}"}
    printf '%s\n' "${context[@]}"
    exit 1
fi

echo "$pack declared pin matches the materialized pin"
printf '%s\n' "${context[@]}"
exit 0
