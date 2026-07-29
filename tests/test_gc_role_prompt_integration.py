from __future__ import annotations

from dataclasses import dataclass
import json
import os
from pathlib import Path
import subprocess
import textwrap

import pytest


REPO_ROOT = Path(__file__).resolve().parents[1]


@dataclass(frozen=True)
class PromptWorkspace:
    city_dir: Path
    rig_dir: Path
    env: dict[str, str]


def hermetic_env() -> dict[str, str]:
    """Base subprocess environment with ambient Gas Town session state stripped.

    A running `gc` session exports a large GC_*/BEADS_* family describing *that*
    session, and the pack commands exercised below read those same names --
    `claim/run.sh` derives its expected route from `${GC_TEMPLATE:-${GC_AGENT:-}}`.
    Inheriting the caller's environment therefore overrides whatever the test set
    up: a polecat worktree exports GC_TEMPLATE=<rig>/gastown.polecat, which beats
    the GC_AGENT the claim test declares and fails it with a route mismatch.

    This suite hid the defect longer than its siblings because it is doubly
    masked: CI supplies GC_TEST_BIN but a clean environment, while a live session
    has the dirty environment but no GC_TEST_BIN, so `gc_test_bin` skips. Neither
    side ever runs the one combination that breaks.

    Stripping the family wholesale is safe because CI's `GC_TEST_BIN=... pytest`
    step exports no other GC_*/BEADS_* variable, so no passing test can depend on
    an ambient value. Spread this in place of `os.environ` and declare every
    GC_*/BEADS_* variable the binary under test should see.
    """
    return {key: value for key, value in os.environ.items() if not key.startswith(("GC_", "BEADS_"))}


@pytest.fixture(scope="session")
def gc_test_bin() -> Path:
    configured = os.environ.get("GC_TEST_BIN")
    if not configured:
        pytest.skip("set GC_TEST_BIN to run real Gas City CLI integration tests")

    binary = Path(configured).expanduser().resolve()
    if not binary.is_file() or not os.access(binary, os.X_OK):
        pytest.fail(f"GC_TEST_BIN is not an executable file: {binary}")
    return binary


def write_prompt_workspace(
    root: Path,
    *,
    city_binding: str,
    city_pack: Path,
) -> PromptWorkspace:
    city_dir = root / "city"
    rig_dir = root / "fixture"
    gc_home = root / "gc-home"
    home = root / "home"
    (city_dir / ".gc").mkdir(parents=True)
    rig_dir.mkdir()
    gc_home.mkdir()
    home.mkdir()

    roles_source = (REPO_ROOT / "gascity" / "roles").resolve()
    city_pack = city_pack.resolve()
    city_dir.joinpath("pack.toml").write_text(
        textwrap.dedent(
            f"""\
            [pack]
            name = "prompt-integration"
            schema = 2

            [imports.{city_binding}]
            source = {json.dumps(str(city_pack))}
            """
        ),
        encoding="utf-8",
    )
    city_dir.joinpath("city.toml").write_text(
        textwrap.dedent(
            f"""\
            [workspace]
            provider = "codex"

            [providers.codex]
            base = "builtin:codex"

            [[rigs]]
            name = "fixture"

            [rigs.imports.gc]
            source = {json.dumps(str(roles_source))}
            """
        ),
        encoding="utf-8",
    )
    city_dir.joinpath(".gc", "site.toml").write_text(
        textwrap.dedent(
            f"""\
            workspace_name = "prompt-integration"

            [[rig]]
            name = "fixture"
            path = {json.dumps(str(rig_dir))}
            """
        ),
        encoding="utf-8",
    )

    env = {
        **hermetic_env(),
        "HOME": str(home),
        "GC_HOME": str(gc_home),
        "GC_CITY": str(city_dir),
        "GC_CITY_PATH": str(city_dir),
        "GC_CITY_ROOT": str(city_dir),
        "GC_RIG": "fixture",
    }
    return PromptWorkspace(city_dir=city_dir, rig_dir=rig_dir, env=env)


def run_gc(
    gc_test_bin: Path,
    workspace: PromptWorkspace,
    *args: str,
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(gc_test_bin), *args],
        cwd=cwd or workspace.rig_dir,
        env=env or workspace.env,
        text=True,
        capture_output=True,
        timeout=30,
    )


def assert_clean_worker_render(prompt: str, persona_heading: str) -> None:
    assert persona_heading in prompt
    assert prompt.count("# GC Role Worker") == 1
    assert '{{ template "gc-role-worker" . }}' not in prompt
    assert "gc gc claim" in prompt
    assert "CLAIMED_BEAD_ID" in prompt
    assert "CLAIMED_ROOT_BEAD_ID" in prompt
    assert "CLAIMED_CONTINUATION_GROUP" in prompt
    assert 'gc bd update "$CLAIMED_BEAD_ID"' in prompt
    assert "An empty continuation group is a hard session boundary" in prompt


def test_city_scoped_gascity_registers_claim_command_from_rig(
    tmp_path: Path, gc_test_bin: Path
) -> None:
    workspace = write_prompt_workspace(
        tmp_path,
        city_binding="gc",
        city_pack=REPO_ROOT / "gascity",
    )

    result = run_gc(gc_test_bin, workspace, "gc", "claim", "--help")

    assert result.returncode == 0, result.stderr
    assert "Atomically claim one routed workflow bead" in result.stdout
    assert "Usage:\n  gc gc claim" in result.stdout
    assert "Gas City CLI — orchestration-builder" not in result.stdout


@pytest.mark.parametrize(
    ("city_binding", "pack_path", "agent", "persona_heading"),
    (
        ("gc", "gascity", "gc.implementation-worker", "# GC Role Worker"),
        ("bmad", "bmad", "bmad.story-implementer", "# BMAD Story Implementer"),
        (
            "superpowers",
            "superpowers",
            "superpowers.implementer",
            "# Superpowers Implementer",
        ),
        ("gstack", "gstack", "gstack.implementer", "# gstack Implementer"),
        (
            "compound-engineering",
            "compound-engineering",
            "compound-engineering.ce-work",
            "# Compound Engineering Worker",
        ),
        ("profiler", "profiler", "profiler.profile-analyst", "# Profile Analyst"),
    ),
)
def test_role_prompts_render_public_worker_fragment(
    tmp_path: Path,
    gc_test_bin: Path,
    city_binding: str,
    pack_path: str,
    agent: str,
    persona_heading: str,
) -> None:
    workspace = write_prompt_workspace(
        tmp_path,
        city_binding=city_binding,
        city_pack=REPO_ROOT / pack_path,
    )

    result = run_gc(
        gc_test_bin,
        workspace,
        "--city",
        str(workspace.city_dir),
        "prime",
        "--strict",
        f"fixture/{agent}",
        cwd=workspace.city_dir,
    )

    assert result.returncode == 0, result.stderr
    assert_clean_worker_render(result.stdout, persona_heading)


def test_registered_claim_command_dispatches_store_aware_show_and_normalizes_json(
    tmp_path: Path, gc_test_bin: Path
) -> None:
    workspace = write_prompt_workspace(
        tmp_path,
        city_binding="gc",
        city_pack=REPO_ROOT / "gascity",
    )
    fake_bin = tmp_path / "fake-bin"
    fake_bin.mkdir()
    calls = tmp_path / "nested-gc-calls"
    nested_gc = fake_bin / "gc"
    nested_gc.write_text(
        textwrap.dedent(
            """\
            #!/bin/sh
            printf '%s\n' "$*" >>"$GC_TEST_CALLS"
            if [ "$1" = hook ] && [ "$2" = --claim ] && [ "$3" = --drain-ack ] && [ "$4" = --json ]; then
              printf '%s\n' '{"action":"work","bead_id":"bd-123","assignee":"worker","route":"gc.implementation-worker"}'
            elif [ "$1" = b""d ] && [ "$2" = show ] && [ "$3" = bd-123 ] && [ "$4" = --json ]; then
              printf '%s\n' '{"id":"bd-123","status":"in_progress","assignee":"worker","metadata":{"gc.routed_to":"gc.implementation-worker","gc.root_bead_id":"root-1","gc.continuation_group":"group-1"}}'
            else
              printf 'unexpected nested gc invocation: %s\n' "$*" >&2
              exit 2
            fi
            """
        ),
        encoding="utf-8",
    )
    nested_gc.chmod(0o755)
    env = {
        **workspace.env,
        "BEADS_ACTOR": "worker",
        "GC_AGENT": "gc.implementation-worker",
        "GC_TEST_CALLS": str(calls),
        "PATH": f"{fake_bin}:/usr/bin:/bin",
    }

    result = run_gc(gc_test_bin, workspace, "gc", "claim", env=env)

    assert result.returncode == 0, result.stderr
    payload = json.loads(result.stdout)
    assert payload["bead_id"] == "bd-123"
    assert payload["root_bead_id"] == "root-1"
    assert payload["continuation_group"] == "group-1"
    assert payload["bead"]["id"] == "bd-123"
    assert calls.read_text(encoding="utf-8").splitlines() == [
        "hook --claim --drain-ack --json",
        " ".join(("b" + "d", "show", "bd-123", "--json")),
    ]


def test_prompt_workspace_env_scrubs_ambient_session_family(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Guard `hermetic_env` against a re-introduced `**os.environ` spread.

    CI's pytest step exports no GC_*/BEADS_* beyond GC_TEST_BIN, so it cannot
    observe a missing scrub the way a live session can. Simulating the session
    here keeps the helper covered. This test deliberately takes no `gc_test_bin`
    fixture, so it runs in CI's main pytest sweep instead of sitting behind the
    GC_TEST_BIN skip that kept the original defect hidden.
    """
    monkeypatch.setenv("GC_TEMPLATE", "ambient/gastown.polecat")
    monkeypatch.setenv("GC_BIN", "/ambient/bin/gc")
    monkeypatch.setenv("GC_SESSION_NAME", "ambient-session")
    monkeypatch.setenv("BEADS_ACTOR", "ambient-actor")
    monkeypatch.setenv("BEADS_DIR", "/ambient/.beads")

    workspace = write_prompt_workspace(
        tmp_path, city_binding="gc", city_pack=REPO_ROOT / "gascity"
    )

    # Asserting the exact surviving set (not just the absence of today's known
    # offenders) is what makes a future ambient leak fail here.
    assert sorted(key for key in workspace.env if key.startswith(("GC_", "BEADS_"))) == [
        "GC_CITY",
        "GC_CITY_PATH",
        "GC_CITY_ROOT",
        "GC_HOME",
        "GC_RIG",
    ]
    assert workspace.env["HOME"] == str(tmp_path / "home")
    assert workspace.env["PATH"] == os.environ["PATH"]
