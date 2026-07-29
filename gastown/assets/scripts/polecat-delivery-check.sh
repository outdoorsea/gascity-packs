#!/usr/bin/env bash
# polecat-delivery-check.sh — is this work bead's deliverable ALREADY on the
# target branch? Read-only: it gathers evidence, prints it, and exits. It never
# updates a bead, nudges, or mails — the `workspace-setup` gate in
# mol-polecat-work owns those decisions.
#
# The gap it closes: the bead pool can go stale relative to the target branch.
# A second machine (or an earlier polecat, or a human) lands work directly on
# origin/main while the bead describing that work is still open in the pool. A
# polecat is then dispatched at it and:
#
#   1. takes a pool slot and a session,
#   2. builds a deliverable that is already present,
#   3. produces a branch with 0 commits / an empty diff vs the target,
#   4. is refused by the refinery's branch_has_real_change() guard,
#   5. becomes a blocked bead routed to a human.
#
# That guard works, but it catches the waste at the END of the cycle — after the
# slot is spent and a human decision has been manufactured. This check moves the
# question to the FRONT, before anything is built, and answers it with positive
# evidence (here is the commit that already did it) instead of the refinery's
# negative inference (this branch changes nothing).
#
# Three independent signals, cheapest and strongest first:
#
#   S1  commit  the bead id appears in a commit message reachable from the
#               target ref. In a rig whose commit convention is
#               `<type>: <subject> (<bead-id>)` this is near-conclusive, and it
#               needs no verify clause, so it works on EVERY bead.
#   S2  path    a file path named by the bead's verify clause already exists on
#               the target ref.
#   S3  symbol  a code-shaped identifier named by the verify clause already
#               appears in the target ref's content.
#
# Output: one TSV row per finding on stdout, verdict row FIRST, header and
# summary on stderr.
#
#   verdict  <TAB> <bead>  <TAB> <verdict> <TAB> <target-ref>
#   evidence <TAB> commit  <TAB> <sha>     <TAB> <subject>
#   evidence <TAB> path    <TAB> <token>   <TAB> <path-on-target>
#   evidence <TAB> symbol  <TAB> <token>   <TAB> <file-on-target>
#   missing  <TAB> symbol  <TAB> <token>   <TAB> -
#
# Verdicts:
#   already-delivered   S1 fired: a commit on the target names this bead. HALTS.
#   possibly-delivered  S1 silent, but every extracted token is already present.
#                       ADVISORY ONLY — reported, but does not stop the build.
#   not-delivered       evidence gathered, and it does not add up. BUILD.
#   no-signal           nothing checkable — no commit hit and no extractable
#                       token. The check ABSTAINED; it did not clear the bead.
#
# Exit codes:  0 = go build it (not-delivered, no-signal, or possibly-delivered)
#              1 = already-delivered — a commit on the target names this bead
#              2 = the check could not run (bad ref, unreadable bead, no git) —
#                  delivery was NOT evaluated. Never read a 2 as "go build".
#
# ONLY S1 CAN STOP WORK. That is a deliberate, measured asymmetry (gp-nrm, mayor
# decision): across 28 real beads the commit signal caught 8/8 already-delivered
# with zero false positives on 14 open beads, while the token heuristic behind
# `possibly-delivered` fired zero times. A signal that has never fired must not
# be allowed to halt a polecat, because the two error directions are not
# symmetric — a MISS costs one pool slot and the refinery's
# branch_has_real_change() guard still catches it, but a FALSE POSITIVE silently
# drops real work. Never trade a silent drop of real work for a heuristic that
# has never fired. Promote S2/S3 to halting only on evidence that they detect
# something S1 misses.
#
# Even a halt is NECESSARY BUT NOT SUFFICIENT: the caller must open the cited
# commit and confirm the deliverable is genuinely there before abandoning the
# work. See `workspace-setup` in mol-polecat-work.
#
# The token filters are deliberately conservative — code-shaped tokens only, and
# S2/S3 must hit EVERY extracted token to speak. A verify clause written as pure
# prose ("the document names the backend, the setting, and the permission
# requirement") yields no tokens at all, and the check says `no-signal` rather
# than guessing. Abstaining is the correct answer when there is nothing to
# measure; a cheap first pass need not be perfect, but it must not be confident
# when it is blind.
#
# Env:
#   GASTOWN_DELIVERY_MIN_TOKENS  tokens required before S2/S3 may speak (default: 2)
#   GASTOWN_DELIVERY_MAX_TOKENS  cap on tokens checked, for cost (default: 12)
#
# Usage:
#   polecat-delivery-check.sh <bead-id> [--target <ref>]
#   polecat-delivery-check.sh gp-nrm --target origin/main

set -euo pipefail

ME=polecat-delivery-check

BEAD=''
TARGET=''

while [ $# -gt 0 ]; do
  case "$1" in
    --target)
      [ $# -ge 2 ] || { echo "$ME: --target needs a ref" >&2; exit 2; }
      TARGET="$2"
      shift 2
      ;;
    --target=*)
      TARGET="${1#--target=}"
      shift
      ;;
    -h|--help)
      sed -n '2,80p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*)
      echo "$ME: unknown flag '$1'" >&2
      exit 2
      ;;
    *)
      [ -z "$BEAD" ] || { echo "$ME: unexpected extra argument '$1'" >&2; exit 2; }
      BEAD="$1"
      shift
      ;;
  esac
done

if [ -z "$BEAD" ]; then
  echo "$ME: usage: $ME <bead-id> [--target <ref>]" >&2
  exit 2
fi

MIN_TOKENS="${GASTOWN_DELIVERY_MIN_TOKENS:-2}"
MAX_TOKENS="${GASTOWN_DELIVERY_MAX_TOKENS:-12}"
for v in MIN_TOKENS MAX_TOKENS; do
  eval "val=\$$v"
  case "$val" in
    ''|*[!0-9]*)
      echo "$ME: GASTOWN_DELIVERY_${v} must be a non-negative integer (got '$val')" >&2
      exit 2
      ;;
  esac
done
if [ "$MAX_TOKENS" -le 0 ]; then
  echo "$ME: GASTOWN_DELIVERY_MAX_TOKENS must be positive (got '$MAX_TOKENS')" >&2
  exit 2
fi

git rev-parse --git-dir >/dev/null 2>&1 || {
  echo "$ME: not inside a git repository — delivery NOT evaluated" >&2
  exit 2
}

if ! BEAD_JSON=$(gc bd show "$BEAD" --json 2>/dev/null); then
  echo "$ME: 'gc bd show $BEAD --json' failed — delivery NOT evaluated" >&2
  exit 2
fi

# Tolerate both the bare array bd returns today and an object wrapper, the way
# the sibling polecat/witness checks do — this schema has drifted before.
JQ_ISSUES='def issues_of: (.issues? // .) | if type == "array" then . else [] end;'

if ! DESCRIPTION=$(printf '%s' "$BEAD_JSON" \
  | jq -r "$JQ_ISSUES issues_of | .[0] | ((.title // \"\") + \"\n\" + (.description // \"\"))" 2>/dev/null); then
  echo "$ME: could not parse bead $BEAD — delivery NOT evaluated" >&2
  exit 2
fi
if [ -z "${DESCRIPTION//[[:space:]]/}" ]; then
  echo "$ME: bead $BEAD has no title or description — delivery NOT evaluated" >&2
  exit 2
fi

# Target ref resolution: explicit flag, then the bead's own metadata.target,
# then the remote's default branch, then origin/main.
if [ -z "$TARGET" ]; then
  TARGET=$(printf '%s' "$BEAD_JSON" \
    | jq -r "$JQ_ISSUES issues_of | .[0].metadata.target // empty" 2>/dev/null) || TARGET=''
fi
if [ -z "$TARGET" ]; then
  TARGET=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null) || TARGET=''
fi
[ -n "$TARGET" ] || TARGET=origin/main

# A bare branch name means "the branch as the remote sees it" — that is what
# "already landed on main" asks about. Prefer origin/<name> when it resolves,
# because a local <name> can trail the remote by many commits and would hide
# exactly the commits this check exists to find.
case "$TARGET" in
  */*) : ;;
  *)
    if git rev-parse --verify --quiet "refs/remotes/origin/$TARGET" >/dev/null 2>&1; then
      TARGET="origin/$TARGET"
    fi
    ;;
esac

git rev-parse --verify --quiet "$TARGET" >/dev/null 2>&1 || {
  echo "$ME: target ref '$TARGET' does not resolve — delivery NOT evaluated" >&2
  echo "$ME: fetch first ('git fetch --prune origin'), or pass --target <ref>" >&2
  exit 2
}

# --- verify-clause extraction ----------------------------------------------
# Three conventions are in the wild and all three are honoured:
#   [verify: ...]        bracket clause, may wrap across lines
#   Verify: ...          labelled line (also Verification:), to end of paragraph
#   ## Verify            markdown section, to the next heading
# Nothing found is a normal outcome, not an error: S1 needs no verify clause.
#
# Case-insensitivity comes from tolower() and match()/RSTART/RLENGTH, never from
# gawk's IGNORECASE — this fleet includes macOS, whose awk silently ignores that
# variable. An IGNORECASE version of this function matched `verify:` and missed
# every real-world `Verify:`, which reads as "bead has no verify clause" and
# quietly disables two of the three signals.
extract_verify() {
  printf '%s\n' "$DESCRIPTION" | awk '
    BEGIN { inbracket = 0; insection = 0; inlabel = 0 }
    {
      low = tolower($0)
    }
    # [verify: ...] — emit from after the marker, stop at the closing bracket.
    !inbracket && match(low, /\[[ \t]*verif[a-z]*[ \t]*:/) {
      line = substr($0, RSTART + RLENGTH)
      if (line ~ /\]/) { sub(/\].*$/, "", line); print line; next }
      inbracket = 1; print line; next
    }
    inbracket {
      line = $0
      if (line ~ /\]/) { sub(/\].*$/, "", line); print line; inbracket = 0; next }
      print line; next
    }
    # ## Verify — a markdown section, to the next heading of any depth.
    low ~ /^[ \t]*#+[ \t]*verif/ { insection = 1; inlabel = 0; next }
    insection && low ~ /^[ \t]*#+[ \t]/ { insection = 0 }
    insection { print; next }
    # Verify: — a labelled line, continuing to the next blank line.
    match(low, /^[ \t]*verif[a-z]*[ \t]*:/) {
      inlabel = 1
      print substr($0, RSTART + RLENGTH)
      next
    }
    inlabel && low ~ /^[ \t]*$/ { inlabel = 0; next }
    inlabel { print; next }
  '
}

VERIFY_TEXT=$(extract_verify) || VERIFY_TEXT=''

# --- tokenisation -----------------------------------------------------------
# Keep only CODE-SHAPED tokens. An English word grepped against a source tree
# hits everywhere and would manufacture false confidence, so a token must both
# be long enough and carry a structural marker (`/`, `_`, `.`, `-`, a digit) or
# be mixedCase/ALLCAPS. Placeholder prefixes like `<work_dir>/` are stripped so
# the greppable remainder survives.
tokenize() {
  printf '%s\n' "$VERIFY_TEXT" \
    | tr -c 'A-Za-z0-9_./<>-' '\n' \
    | sed -e 's/^<[A-Za-z0-9_]*>//' \
          -e 's/[<>]//g' \
          -e 's/^[.-]*//' \
          -e 's/[.,;:)(-]*$//' \
    | awk '
      {
        t = $0
        if (length(t) < 4) next
        if (t ~ /^[0-9.]+$/) next
        # Prose that sneaks past the shape filter.
        lower = tolower(t)
        if (lower == "e.g." || lower == "i.e." || lower == "etc." || lower == "vs.") next
        if (lower == "verify" || lower == "verified" || lower == "verification") next
        # Structural marker: a path separator, an underscore, a dotted pair
        # (a file extension or a dotted symbol), or a letter-digit run.
        structural = (t ~ /[_\/]/) \
          || (t ~ /[A-Za-z0-9]\.[A-Za-z0-9]/) \
          || (t ~ /[A-Za-z][0-9]/)
        # CamelCase is admitted only from TWO humps up. One hump is how brand
        # prose reads — macOS, GitHub, JavaScript — and those grep-hit somewhere
        # in any large tree, which manufactures a confident wrong answer. Two
        # humps is how a real multi-word identifier reads: WheelUpPane. Bare
        # ALLCAPS is excluded for the same reason: in this ledger it is prose
        # emphasis (RECORDED, NEVER), while real constants carry an underscore
        # and are already admitted as structural.
        humps = 0
        s = t
        while (match(s, /[a-z][A-Z]/)) { humps++; s = substr(s, RSTART + 2) }
        if (!structural && humps < 2) next
        if (seen[t]++) next
        print t
      }
    ' \
    | sed -n "1,${MAX_TOKENS}p"
}

TOKENS=$(tokenize) || TOKENS=''
TOKEN_COUNT=$(printf '%s' "$TOKENS" | grep -c . || true)
[ -n "$TOKEN_COUNT" ] || TOKEN_COUNT=0

# --- S1: does a commit reachable from the target name this bead? ------------
# Anchored on purpose. A bare substring search for `ml-xob.1` also matches a
# commit for `ml-xob.11`, and sub-bead ids of exactly that shape are common —
# so the id must not be followed by another digit or a dot. `.` in the id is
# escaped for the regex; every other character in a bead id is literal.
BEAD_RE=$(printf '%s' "$BEAD" | sed 's/[.[\*^$+?(){}|\\]/\\&/g')
COMMITS=$(git log --no-merges -E --grep="${BEAD_RE}([^0-9.]|\$)" \
  --format='%h%x09%s' -n 20 "$TARGET" -- 2>/dev/null) || COMMITS=''
COMMIT_COUNT=$(printf '%s' "$COMMITS" | grep -c . || true)
[ -n "$COMMIT_COUNT" ] || COMMIT_COUNT=0

# --- S2/S3 evidence gathering ----------------------------------------------
# One `git ls-tree` for the whole path question: per-token `git cat-file` calls
# would be N round trips to answer what one file list already answers, and a
# verify clause usually names a path fragment rather than a repo-root path.
TREE_FILES=''
if [ "$TOKEN_COUNT" -gt 0 ]; then
  TREE_FILES=$(git ls-tree -r --name-only "$TARGET" 2>/dev/null) || TREE_FILES=''
fi

EVIDENCE=''
MISSING=''
HIT_COUNT=0

# path_on_target <token> — the first tracked path whose tail matches the token,
# or empty. Matching on a `/`-anchored suffix keeps `main.py` from claiming an
# unrelated `other/main.py`, while still resolving the `pkg/main.py` fragment a
# verify clause typically writes.
path_on_target() {
  local tok="$1" hit
  case "$tok" in
    */*) : ;;
    *) return 1 ;;
  esac
  hit=$(printf '%s\n' "$TREE_FILES" | grep -F -- "$tok" 2>/dev/null | sed -n '1p') || hit=''
  [ -n "$hit" ] || return 1
  printf '%s' "$hit"
}

# symbol_on_target <token> — the first tracked file whose CONTENT contains the
# token. `-F` because verify clauses carry regex metacharacters (`/health`,
# `*.md`) that must be matched literally, and `-e` because a token beginning
# with `-` or `/` would otherwise be read as a flag or a pathspec. git grep
# exits 1 for "no match", which is a normal answer, not a failure — hence the
# guard under `set -e`.
symbol_on_target() {
  local tok="$1" hit rc
  set +e
  hit=$(git grep -F -l -e "$tok" "$TARGET" -- 2>/dev/null | sed -n '1p')
  rc=$?
  set -e
  [ "$rc" -le 1 ] || return 2
  [ -n "$hit" ] || return 1
  printf '%s' "${hit#*:}"
}

while IFS= read -r tok; do
  [ -n "${tok:-}" ] || continue
  if hit=$(path_on_target "$tok"); then
    EVIDENCE="${EVIDENCE}evidence	path	${tok}	${hit}
"
    HIT_COUNT=$((HIT_COUNT + 1))
    continue
  fi
  set +e
  hit=$(symbol_on_target "$tok")
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    EVIDENCE="${EVIDENCE}evidence	symbol	${tok}	${hit}
"
    HIT_COUNT=$((HIT_COUNT + 1))
  else
    MISSING="${MISSING}missing	symbol	${tok}	-
"
  fi
done <<EOF
$TOKENS
EOF

# --- verdict ----------------------------------------------------------------
# S1 is decisive on its own. S2/S3 only speak when there were enough tokens to
# be worth believing AND every one of them is already present: a partial hit is
# the normal shape of a bead whose neighbourhood exists but whose deliverable
# does not, which is most beads.
if [ "$COMMIT_COUNT" -gt 0 ]; then
  VERDICT=already-delivered
elif [ "$TOKEN_COUNT" -ge "$MIN_TOKENS" ] && [ "$TOKEN_COUNT" -gt 0 ] \
  && [ "$HIT_COUNT" -eq "$TOKEN_COUNT" ]; then
  VERDICT=possibly-delivered
elif [ "$TOKEN_COUNT" -eq 0 ]; then
  VERDICT=no-signal
else
  VERDICT=not-delivered
fi

printf 'kind\tsignal\tsubject\tlocation\n' >&2
printf 'verdict\t%s\t%s\t%s\n' "$BEAD" "$VERDICT" "$TARGET"

if [ "$COMMIT_COUNT" -gt 0 ]; then
  while IFS=$'\t' read -r sha subject; do
    [ -n "${sha:-}" ] || continue
    printf 'evidence\tcommit\t%s\t%s\n' "$sha" "$subject"
  done <<EOF
$COMMITS
EOF
fi

[ -z "$EVIDENCE" ] || printf '%s' "$EVIDENCE"
[ -z "$MISSING" ] || printf '%s' "$MISSING"

if [ -z "${VERIFY_TEXT//[[:space:]]/}" ]; then
  echo "$ME: $BEAD has no verify clause — only the commit signal was available" >&2
else
  echo "$ME: $BEAD verify clause yielded $TOKEN_COUNT token(s), $HIT_COUNT already present on $TARGET" >&2
fi
echo "$ME: $BEAD vs $TARGET — $VERDICT ($COMMIT_COUNT naming commit(s))" >&2

case "$VERDICT" in
  already-delivered)
    echo "$ME: CONFIRM BEFORE HALTING — open the cited commit/file and check the deliverable is genuinely there. A false positive skips real work." >&2
    exit 1
    ;;
  possibly-delivered)
    # ADVISORY, not a halt. Measured on 28 real beads (gp-nrm): the commit
    # signal caught 8/8 already-delivered with no false positive on 14 open
    # beads, while the token heuristic fired zero times. A signal that has never
    # fired must not be allowed to stop work, because the error directions are
    # not symmetric — a miss costs one pool slot and the refinery's
    # branch_has_real_change() guard still catches it, but a false positive
    # silently drops real work. So this prints its evidence and gets out of the
    # way. Promote it only on evidence that it detects something S1 misses.
    echo "$ME: ADVISORY — every token is already present, but that is a prose heuristic, not proof. BUILD; check the cited files first in case the work is genuinely done." >&2
    exit 0
    ;;
esac
exit 0
