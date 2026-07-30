#!/usr/bin/env bash
# Pack doctor check: assert every `gc <pack> <sub>` a materialized prompt or
# formula invokes actually exists in the pin that supplies the command namespace.
#
# Why this check exists (gp-xb9)
# ------------------------------
# "declared pin == materialized pin" is necessary but not sufficient. On
# 2026-07-29 all three rig pins were declared AND materialized at 10a553ac,
# `gc import check` reported "Import state OK: 5 remote import(s) checked", the
# sibling pin-materialization axes were all clean — and the city was still one
# patrol restart away from failing every witness, refinery and deacon closed.
#
# The missed invariant is CROSS-PIN. A pack is imported twice, at two
# independently-versioned scopes:
#
#   city pin   <city>/pack.toml   [imports.<pack>]        supplies `gc <pack> <sub>`
#   rig pins   <city>/city.toml   [rigs.imports.<pack>]   supply rig prompts + formulas
#
# Rig prompts at 10a553ac call `gc gastown wisp-reconcile`; the city pin at
# f69ec02 shipped only `status`. Each pin was internally consistent. The PAIR was
# not, and nothing in the city compared them — every existing check evaluates one
# pin against itself or against its own upstream.
#
# The failure mode is fail-closed, not degraded. The prompts invoke these
# commands with `|| exit 1`, so a missing subcommand does not produce a warning
# and carry on: the patrol dies. That is why this reports as an error.
#
# Do NOT probe with `gc <pack> <sub> --help`
# ------------------------------------------
# Cobra falls back to printing the PARENT command's help and exits 0 for an
# unknown subcommand, so `gc gastown no-such-command --help; echo $?` prints 0
# and a probe built on it reports every command as present. This check reads the
# command namespace off the filesystem instead — the pin's commands/ directory,
# where a dispatchable subcommand is a directory containing run.sh. There is a
# test asserting this script never shells out to a --help probe, because the
# tempting wrong implementation looks correct until a command is actually
# missing, which is the one moment the check matters.
#
# Exit codes: 0=OK, 1=Warning, 2=Error
# stdout: first line=message, rest=details
#
# Environment (the doctor runner's contract, verified empirically against
# `gc doctor` with every inherited GC_* var scrubbed and a neutral cwd):
#   GC_PACK_DIR   — absolute pack directory (e.g. <cache>/<hash>/gastown)
#   GC_CITY_PATH  — absolute city root
#   GC_CITY       — absolute city root (same value; both are injected)
#   cwd           — the city root
#
# GC_PACK_NAME is NOT set for doctor checks, so the pack name is derived from the
# pack directory gc actually hands us. See the sibling import-drift check for the
# bug that shortcut caused.

set -uo pipefail

dir="${GC_PACK_DIR:-.}"
pack=$(basename "$dir")

# ---------------------------------------------------------------------------
# City root
# ---------------------------------------------------------------------------
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
    echo "$pack: cannot locate the city root — command coverage is uncheckable"
    echo "GC_CITY_PATH=${GC_CITY_PATH:-<unset>}"
    echo "GC_CITY=${GC_CITY:-<unset>}"
    echo "cwd=$(pwd -P 2>/dev/null)"
    exit 1
fi

# ---------------------------------------------------------------------------
# The pin that supplies the command namespace
# ---------------------------------------------------------------------------
# Commands are dispatched from the CITY pin — <city>/pack.toml [imports.<pack>] —
# not from whichever rig pin a given agent's prompt came from. That asymmetry is
# the whole bug, so this check has to resolve the city pin specifically rather
# than trusting GC_PACK_DIR to be it.
city_declared_commit() {
    local file="$city/pack.toml"
    [ -f "$file" ] || return 0
    awk -v want="$pack" '
        function qval(s) {
            if (match(s, /"[^"]*"/)) return substr(s, RSTART + 1, RLENGTH - 2)
            return ""
        }
        { line = $0; gsub(/^[ \t]+|[ \t]+$/, "", line) }
        line ~ /^\[/ {
            sect = (line == "[imports." want "]") ? "WANT" : "OTHER"
            next
        }
        sect == "WANT" && line ~ /^version[ \t]*=/ {
            v = qval(line)
            if (v ~ /^sha:/) { print substr(v, 5); exit }
        }
        sect == "WANT" && line ~ /^source[ \t]*=/ {
            s = qval(line)
            if (match(s, /\/tree\/[0-9a-fA-F]{40}\//)) {
                print substr(s, RSTART + 6, 40); exit
            }
        }
    ' "$file" | tr 'A-F' 'a-f'
}

want_commit=$(city_declared_commit)

# Locate the cache dir materializing that commit. The pack cache is
# content-addressed, so the directory name cannot be computed from the pin —
# but the caches are siblings of the one we were handed, and each is a git clone
# whose HEAD identifies it. Look there rather than guessing a hash.
resolve_city_pack_dir() {
    # The common case: gc handed us the city pin already.
    if [ -z "$want_commit" ]; then
        printf '%s' "$dir"
        return
    fi
    local head
    head=$(git -C "$dir" rev-parse HEAD 2>/dev/null)
    if [ "$head" = "$want_commit" ]; then
        printf '%s' "$dir"
        return
    fi

    local repos candidate chead
    repos=$(dirname "$(dirname "$dir")")
    [ -d "$repos" ] || { printf '%s' "$dir"; return; }
    for candidate in "$repos"/*/"$pack"; do
        [ -d "$candidate" ] || continue
        chead=$(git -C "$candidate" rev-parse HEAD 2>/dev/null)
        [ "$chead" = "$want_commit" ] && { printf '%s' "$candidate"; return; }
    done

    # Declared but not materialized anywhere we can see. Fall back to the dir gc
    # gave us and let the message record that the namespace may be the wrong one;
    # the sibling pin-materialization check owns that failure.
    printf '%s' "$dir"
}

command_pack_dir=$(resolve_city_pack_dir)
command_pin=$(git -C "$command_pack_dir" rev-parse HEAD 2>/dev/null)

# A dispatchable subcommand is a directory under commands/ containing run.sh. A
# directory with only help.md is documentation, not a command, and treating it as
# available would hide exactly the gap this check looks for.
available=()
if [ -d "$command_pack_dir/commands" ]; then
    for c in "$command_pack_dir"/commands/*/; do
        [ -f "${c}run.sh" ] || continue
        available+=("$(basename "$c")")
    done
fi

# ---------------------------------------------------------------------------
# What the materialized prompts and formulas demand
# ---------------------------------------------------------------------------
# Scanned surfaces are the ones agents actually execute:
#   formulas/           step bodies agents run verbatim
#   agents/             role prompt templates
#   template-fragments/ prompt fragments composed into those templates
#   orders/             agent-facing order definitions
#   assets/scripts/     scripts the above invoke, which fail closed the same way
#
# Deliberately NOT scanned:
#   commands/  its help.md text references sibling commands; self-referential
#   tests/     not materialized into any agent's runtime
#   doctor/    these checks, including the examples in this comment block
scan_dirs=(formulas agents template-fragments orders assets/scripts)

# Demand is collected from every pin the city has wired up, not just the city
# pin: a rig prompt at a newer pin is the side that names a command the city pin
# may not have. Rig pins are found the way the incident was found — by resolving
# the artifact symlinks the rigs are really using.
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

wired_pack_dir() {
    local link="$1" target parent
    target=$(cd "$(dirname "$link")" 2>/dev/null && realpath "$(basename "$link")" 2>/dev/null)
    [ -n "$target" ] || return
    parent=$(dirname "$(dirname "$target")")
    [ "$(basename "$parent")" = "$pack" ] || return
    printf '%s' "$parent"
}

demand_dirs=("$command_pack_dir")
demand_labels=("city pin")
while IFS= read -r rigpath; do
    [ -n "$rigpath" ] || continue
    [ -d "$rigpath/.beads/formulas" ] || continue
    for link in "$rigpath"/.beads/formulas/*.toml; do
        [ -L "$link" ] || continue
        w=$(wired_pack_dir "$link")
        [ -n "$w" ] || continue
        seen=0
        for existing in "${demand_dirs[@]}"; do
            [ "$existing" = "$w" ] && { seen=1; break; }
        done
        if [ "$seen" -eq 0 ]; then
            demand_dirs+=("$w")
            demand_labels+=("rig $(basename "$rigpath")")
        fi
    done
done < <(rig_paths)

# City-authored prompts live in the city tree rather than in any pin, and invoke
# the same command namespace.
if [ -d "$city/agents" ]; then
    demand_dirs+=("$city/agents")
    demand_labels+=("city-authored prompts")
fi

# The subcommand is the FIRST token after the pack name: in
# `gc gastown wisp-reconcile ensure mol-x`, `ensure` is an argument to
# wisp-reconcile, not a second subcommand. The token pattern also excludes
# documentation placeholders like `gc gastown <sub>` and flags like `--help`.
demanded=()
demanded_where=()
i=0
while [ "$i" -lt ${#demand_dirs[@]} ]; do
    d="${demand_dirs[$i]}"
    label="${demand_labels[$i]}"
    i=$((i + 1))
    [ -d "$d" ] || continue

    targets=()
    if [ "$(basename "$d")" = "agents" ]; then
        targets=("$d")
    else
        for sub in "${scan_dirs[@]}"; do
            [ -d "$d/$sub" ] && targets+=("$d/$sub")
        done
    fi
    [ ${#targets[@]} -gt 0 ] || continue

    while IFS= read -r sub; do
        [ -n "$sub" ] || continue
        seen=0
        j=0
        while [ "$j" -lt ${#demanded[@]} ]; do
            if [ "${demanded[$j]}" = "$sub" ]; then
                case "${demanded_where[$j]}" in
                    *"$label"*) ;;
                    *) demanded_where[$j]="${demanded_where[$j]}, $label" ;;
                esac
                seen=1
                break
            fi
            j=$((j + 1))
        done
        if [ "$seen" -eq 0 ]; then
            demanded+=("$sub")
            demanded_where+=("$label")
        fi
    done < <(
        grep -rhoE "gc[[:space:]]+$pack[[:space:]]+[a-z][a-z0-9-]*" "${targets[@]}" 2>/dev/null |
            awk '{print $NF}' | sort -u
    )
done

# ---------------------------------------------------------------------------
# Verdict
# ---------------------------------------------------------------------------
if [ ${#demanded[@]} -eq 0 ]; then
    echo "$pack: no prompt or formula invokes a $pack subcommand"
    echo "command pin: ${command_pin:0:12} at $command_pack_dir"
    echo "nothing to verify — no cross-pin command dependency exists"
    exit 0
fi

if [ ${#available[@]} -eq 0 ]; then
    # Demand exists and the namespace is empty. Either the pin ships no commands
    # or we resolved the wrong pin; both mean the invocations fail closed.
    echo "$pack: ${#demanded[@]} subcommand(s) are invoked but the command pin ships none"
    for k in "${!demanded[@]}"; do
        echo "  gc $pack ${demanded[$k]}   (invoked by ${demanded_where[$k]})"
    done
    echo "command pin: ${command_pin:0:12} at $command_pack_dir"
    echo "no commands/*/run.sh found under that pin"
    exit 2
fi

missing=()
missing_where=()
for k in "${!demanded[@]}"; do
    found=0
    for a in "${available[@]}"; do
        [ "$a" = "${demanded[$k]}" ] && { found=1; break; }
    done
    if [ "$found" -eq 0 ]; then
        missing+=("${demanded[$k]}")
        missing_where+=("${demanded_where[$k]}")
    fi
done

avail_list=$(printf '%s, ' "${available[@]}"); avail_list=${avail_list%, }

if [ ${#missing[@]} -eq 0 ]; then
    echo "$pack: all ${#demanded[@]} invoked subcommand(s) exist in the command pin"
    echo "command pin: ${command_pin:0:12} at $command_pack_dir"
    echo "available:   $avail_list"
    echo "invoked:     $(printf '%s, ' "${demanded[@]}" | sed 's/, $//')"
    exit 0
fi

echo "$pack: ${#missing[@]} invoked subcommand(s) do not exist in the command pin"
for k in "${!missing[@]}"; do
    echo "  gc $pack ${missing[$k]}   MISSING — invoked by ${missing_where[$k]}"
done
echo
echo "command pin: ${command_pin:0:12} at $command_pack_dir"
echo "available:   $avail_list"
echo "  (from $command_pack_dir/commands/)"
echo
echo "Commands come from the city pin — $city/pack.toml [imports.$pack] — while"
echo "prompts and formulas come from the per-rig pins in $city/city.toml."
echo "Those pins are versioned independently, so each can be internally"
echo "consistent while the pair is not. This is that state."
echo
echo "The prompts invoke these commands with '|| exit 1', so this does not"
echo "degrade an agent — it fails the patrol closed. Remediation: move one pin"
echo "so the pair agrees (usually advance the city pin to match the rig pins),"
echo "then:"
echo "  gc import install"
echo "  gc reload"
exit 2
