"""Gate `gc lint gastown` in CI without going red on upstream linter bugs.

Every other supported pack is linted by the plain loop in ci.yml. gastown was
absent from that loop, so nothing in CI ever ran `gc lint gastown` -- the pack
that drives the whole town was the one pack whose lint was ungated, and it had
accumulated 26 findings unnoticed (gp-f4m). It reached 27 while this fix was
in flight, which is the argument for the gate in miniature: an ungated pack
does not hold still long enough to be fixed by hand.

gastown cannot join the plain loop yet: `gc lint gastown` still exits 1 on
findings that are defects in the linter's own flag model, not in the templates.
Each is verified against the real CLI below. So this test runs the same lint and
fails on anything *outside* that verified waiver set, which gates the pack
against regression while the upstream bugs are outstanding.

The waiver set is a ratchet, not a suppression list: an entry that stops firing
also fails the test, so the waivers get deleted as upstream lands fixes rather
than quietly outliving them.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import subprocess

import pytest


REPO_ROOT = Path(__file__).resolve().parents[1]

PACK = "gastown"

BD_UNKNOWN_FLAG = re.compile(
    r'^bd-unknown-flag: bd (?P<sub>.+) uses unrecognized flag "(?P<flag>[^"]+)"$'
)

# (path relative to repo root, bd subcommand as the linter resolved it, flag)
#
# Tracked upstream as gk-3zxw. Every entry here is text that is CORRECT as
# shipped -- the linter's internal/bdflags scanner misreads it. Verified against
# bd 1.1.2 / gc 1.3 and read from gascity v1.4.0 (the version
# `go install ...@latest` resolves to in the lint step, so this is the scanner
# CI actually runs):
#
#   --rig   `gc bd create --rig <name>` is a gc *global* flag, accepted by every
#           gc subcommand (`gc bd create --rig gascity-packs --dry-run` exits 0).
#           bdflags models bd's globals (-C, --db, --actor...) but no gc global,
#           so it validates --rig against `gc bd create`'s flag set and misses.
#           This repo's own tests/test_no_bare_bd_commands.py already treats
#           --rig/--city as gc globals.
#
#   -r      These lines are `gc bd show ... --json | jq -r '...'`. The -r is
#           jq's. bdflags tokenizes on whitespace only and never terminates a
#           command at `|`, so it keeps consuming past the pipe and attributes
#           jq's flag to `gc bd show`.
#
#   --age   These lines are `gc bd mol wisp gc --age 24h`. --age is real, on the
#           three-token `mol wisp gc` subcommand. bdflags.matchSubcommand
#           matches at most two tokens, resolves `mol wisp`, treats `gc` as a
#           positional, and checks --age against the wrong manifest.
#
# Waivers are keyed by (path, subcommand, flag), not by line, because line
# numbers move whenever the surrounding prose is edited. One entry therefore
# covers every occurrence of the same misread in the same file.
WAIVED_BD_FLAGS = frozenset(
    {
        ("gastown/agents/mayor/prompt.template.md", "create", "--rig"),
        ("gastown/assets/prompts/crew.template.md", "create", "--rig"),
        ("gastown/agents/polecat/prompt.template.md", "show", "-r"),
        ("gastown/agents/refinery/prompt.template.md", "show", "-r"),
        # Added when this branch was rebased past gp-6k8, which introduced the
        # `gc bd show "$BEAD" --json | jq -r '...'` work-dir probe. Same
        # jq-past-a-pipe misread as the two entries above, confirmed by linting
        # a detached worktree at the new origin/main: the finding is present
        # there with this branch absent, so it is inherited, not introduced.
        ("gastown/agents/witness/prompt.template.md", "show", "-r"),
        ("gastown/agents/deacon/prompt.template.md", "mol wisp", "--age"),
    }
)


def hermetic_env() -> dict[str, str]:
    """Environment with ambient Gas Town session state stripped.

    A live `gc` session exports a GC_*/BEADS_* family describing that session,
    which can redirect the linted pack or the discovered city. CI's lint step
    exports only GC_TEST_BIN, so stripping the family makes a developer run
    match CI instead of linting through the surrounding town.
    """
    return {k: v for k, v in os.environ.items() if not k.startswith(("GC_", "BEADS_"))}


@pytest.fixture(scope="session")
def gc_test_bin() -> Path:
    configured = os.environ.get("GC_TEST_BIN")
    if not configured:
        pytest.skip("set GC_TEST_BIN to run real Gas City CLI integration tests")

    binary = Path(configured).expanduser().resolve()
    if not binary.is_file() or not os.access(binary, os.X_OK):
        pytest.fail(f"GC_TEST_BIN is not an executable file: {binary}")
    return binary


def lint_diagnostics(binary: Path) -> list[tuple[str, int | None, str]]:
    """Return (relative path, line, message) for every gastown lint diagnostic."""
    # No check=True: `gc lint` exits non-zero precisely when it reports
    # findings, which is the case this test exists to inspect.
    result = subprocess.run(
        [str(binary), "lint", PACK, "--json"],
        cwd=REPO_ROOT,
        env=hermetic_env(),
        capture_output=True,
        text=True,
    )
    try:
        report = json.loads(result.stdout)
    except json.JSONDecodeError:
        pytest.fail(
            f"gc lint {PACK} --json emitted unparseable output "
            f"(exit {result.returncode}):\n{result.stdout}\n{result.stderr}"
        )

    diagnostics = []
    for pack in report.get("packs") or []:
        for diagnostic in pack.get("diagnostics") or []:
            path = Path(diagnostic["path"])
            try:
                relative = path.relative_to(REPO_ROOT).as_posix()
            except ValueError:
                relative = path.as_posix()
            diagnostics.append((relative, diagnostic.get("line"), diagnostic["message"]))
    return diagnostics


def classify(
    diagnostics: list[tuple[str, int | None, str]],
) -> tuple[list[str], set[tuple[str, str, str]]]:
    """Split diagnostics into unwaived failures and the waivers they matched."""
    failures = []
    matched = set()
    for relative, line, message in diagnostics:
        flag_match = BD_UNKNOWN_FLAG.match(message)
        key = None
        if flag_match:
            key = (relative, flag_match["sub"], flag_match["flag"])
        if key in WAIVED_BD_FLAGS:
            matched.add(key)
        else:
            failures.append(f"{relative}:{line if line is not None else '-'}: {message}")
    return failures, matched


@pytest.fixture(scope="session")
def diagnostics(gc_test_bin: Path) -> list[tuple[str, int | None, str]]:
    return lint_diagnostics(gc_test_bin)


def test_gastown_lint_reports_only_waived_upstream_linter_bugs(
    diagnostics: list[tuple[str, int | None, str]],
) -> None:
    failures, _ = classify(diagnostics)

    assert not failures, (
        f"gc lint {PACK} reported findings that are not waived upstream linter bugs.\n"
        "Fix the pack, or -- only if the finding is provably a linter defect, "
        "verified against the real CLI -- add it to WAIVED_BD_FLAGS with the "
        "evidence.\n" + "\n".join(failures)
    )


def test_no_stale_waivers(diagnostics: list[tuple[str, int | None, str]]) -> None:
    """A waiver that stops firing must be deleted, so the list cannot rot.

    This is what makes the waiver set temporary. When an upstream fix lands (or
    the waived line is edited away), the entry becomes dead weight that would
    otherwise keep hiding a real future finding on the same path and flag.
    """
    _, matched = classify(diagnostics)
    stale = WAIVED_BD_FLAGS - matched

    assert not stale, (
        "WAIVED_BD_FLAGS entries no longer reported by gc lint -- delete them:\n"
        + "\n".join(f"{path}: bd {sub} {flag}" for path, sub, flag in sorted(stale))
    )
