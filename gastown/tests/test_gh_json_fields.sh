#!/usr/bin/env bash
# Validates every `gh ... --json <fields>` field list in the gastown pack
# against the REAL gh binary's own schema.
#
# Why this is not a fixture test. `gh` validates --json field names
# CLIENT-SIDE and rejects the ENTIRE query when one name is wrong, so a single
# typo does not degrade a query, it deletes it. That is how
# mol-refinery-patrol came to ask for `mergeCommitOid` (there is no such field;
# the object is `mergeCommit`) in its authoritative merge check: the query
# failed on every patrol, on every rig, and `2>/dev/null` swallowed the reason.
#
# A stubbed gh cannot catch this. A stub echoes whatever the fixture says
# regardless of which fields were requested, so a fixture that encodes the
# wrong name passes happily -- and a fixture that encodes the RIGHT name still
# proves nothing about a future gh field RENAME, which is the only way this
# class of bug ever appears. The only authority on which fields exist is the
# binary, so this test asks it.
#
# It runs offline: field validation happens before any network call, so pointing
# GH_HOST at an unroutable address keeps the suite hermetic and auth-free.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
PACK="$ROOT/gastown"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

if ! command -v gh >/dev/null 2>&1; then
    # Skip rather than fake it: there is no honest way to ask an absent binary
    # what its schema is, and a fixture here would defeat the entire point.
    # CI runners ship gh, so this skip does not weaken the guard where it counts.
    echo "SKIP: $(basename "${BASH_SOURCE[0]}") — gh not installed; cannot verify field names against the real schema"
    exit 0
fi

# Harvest gh's authoritative field list for one subcommand by asking for a field
# that cannot exist: gh answers with "Available fields:" and the full set.
#
# GH_HOST is unroutable and GH_TOKEN is junk on purpose -- if this ever needs
# the network to answer, the assumption this test rests on has changed and the
# harvest fails loudly instead of quietly passing.
harvest_fields() {
    GH_TOKEN=x GH_HOST=localhost:1 gh "$@" --json __not_a_real_field__ 2>&1 |
        sed -n '/^Available fields:/,$p' | tail -n +2 |
        sed 's/^[[:space:]]*//' | grep . || true
}

# One namespace per distinct gh field set the pack touches. `gh pr checks` has
# its own (much smaller) set than `gh pr view`, so they cannot share a list.
PR_FIELDS=$(harvest_fields pr view 1 --repo o/r)
ISSUE_FIELDS=$(harvest_fields issue view 1 --repo o/r)
REPO_FIELDS=$(harvest_fields repo view o/r)
CHECKS_FIELDS=$(harvest_fields pr checks 1 --repo o/r)

# Non-vacuity on the harvest itself. An empty or truncated list would make every
# assertion below vacuous, so require a plausible size and a known member.
for spec in "pr:$PR_FIELDS:mergedAt" "issue:$ISSUE_FIELDS:state" \
            "repo:$REPO_FIELDS:defaultBranchRef" "checks:$CHECKS_FIELDS:state"; do
    space=${spec%%:*}
    rest=${spec#*:}
    list=${rest%:*}
    sentinel=${rest##*:}
    count=$(printf '%s\n' "$list" | grep -c . || true)
    [ "$count" -ge 5 ] ||
        fail "harvested only $count fields for '$space'; gh's --json error format has changed and this test is no longer checking anything"
    printf '%s\n' "$list" | grep -qx "$sentinel" ||
        fail "harvested '$space' field list lacks the known field '$sentinel'; the harvest is wrong"
done

# The regression that motivated this file: prove gh really does reject the name
# the formula used to ask for. If gh ever accepts it, this test is obsolete and
# should say so rather than keep guarding a non-problem.
printf '%s\n' "$PR_FIELDS" | grep -qx mergeCommit ||
    fail "gh no longer exposes 'mergeCommit' on pr view; mol-refinery-patrol's merge check needs revisiting"
! printf '%s\n' "$PR_FIELDS" | grep -qx mergeCommitOid ||
    fail "gh now accepts 'mergeCommitOid'; this test's premise has changed"

# Extract every `gh <pr|issue|repo> <verb> ... --json a,b,c` in the pack and
# check each field against the matching harvested list.
#
# The field-list pattern deliberately excludes dots and ellipses so that prose
# and stub comments spelling `--json state,mergedAt,...` are not mistaken for
# real call sites. Real --json values are bare comma-separated identifiers.
AUDIT=$(python3 - "$PACK" <<'PY'
import pathlib, re, sys

pack = pathlib.Path(sys.argv[1])
ident = r"[A-Za-z][A-Za-z0-9_]*"
pat = re.compile(
    r"gh\s+(pr|issue|repo)\s+([a-z-]+)((?:[^\n]|\\\n)*?)"
    r"--json\s+(" + ident + r"(?:," + ident + r")*)"
)
for path in sorted(pack.rglob("*")):
    if not path.is_file() or path.suffix not in {".md", ".toml", ".sh", ".yml", ".yaml", ".py"}:
        continue
    text = path.read_text(errors="replace")
    for m in pat.finditer(text):
        sub, verb, mid, fields = m.groups()
        if sub == "pr":
            space = "checks" if verb == "checks" else "pr"
        else:
            space = sub
        line = text[: m.start()].count("\n") + 1
        print(f"{path.relative_to(pack.parent)}\t{line}\t{space}\t{fields}")
PY
)

# A silently-empty audit would make this file a no-op that reads as coverage.
# The pack demonstrably contains gh --json calls; if extraction finds none, the
# extractor broke.
SITES=$(printf '%s\n' "$AUDIT" | grep -c . || true)
[ "$SITES" -ge 1 ] ||
    fail "found no 'gh ... --json' call sites in $PACK; the extractor is broken, not the pack clean"

# Non-vacuity on the extractor's aim: the call site this whole file exists for
# must be among what it found.
printf '%s\n' "$AUDIT" | grep -q 'mol-refinery-patrol.toml' ||
    fail "the audit did not find mol-refinery-patrol's gh pr view call; the extractor is not looking where it must"

BAD=""
while IFS=$'\t' read -r file line space fields; do
    [ -n "$file" ] || continue
    case "$space" in
        pr) valid=$PR_FIELDS ;;
        issue) valid=$ISSUE_FIELDS ;;
        repo) valid=$REPO_FIELDS ;;
        checks) valid=$CHECKS_FIELDS ;;
        *) fail "unknown field namespace '$space' at $file:$line" ;;
    esac
    old_ifs=$IFS
    IFS=','
    for field in $fields; do
        printf '%s\n' "$valid" | grep -qx "$field" ||
            BAD="$BAD  $file:$line  gh $space --json $fields  ->  invalid field '$field'"$'\n'
    done
    IFS=$old_ifs
done <<EOF
$AUDIT
EOF

if [ -n "$BAD" ]; then
    echo "Invalid gh --json field names (gh rejects the WHOLE query on any one of these):" >&2
    printf '%s' "$BAD" >&2
    fail "$(printf '%s' "$BAD" | grep -c .) invalid gh --json field reference(s) in $PACK"
fi

echo "PASS: $(basename "${BASH_SOURCE[0]}") ($SITES gh --json call site(s) checked against real gh)"
