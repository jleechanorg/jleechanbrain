"""Verify deploy.sh matches the single-directory Hermes runtime model.

Run: python -m pytest tests/test_deploy_sync_completeness.py -v
"""

from __future__ import annotations

import os
import re
from pathlib import Path

import pytest

HERMES_REPO = Path(os.environ.get("HERMES_REPO", str(Path.home() / ".smartclaw")))
DEPLOY_SCRIPT = HERMES_REPO / "scripts" / "deploy.sh"

MUST_HAVE_POLICY_FILES: list[str] = [
    "CLAUDE.md",
    "SOUL.md",
    "TOOLS.md",
    "HEARTBEAT.md",
]


@pytest.fixture(scope="module")
def deploy_script() -> str:
    return DEPLOY_SCRIPT.read_text(encoding="utf-8")


def _parse_policy_files(script_content: str) -> list[str]:
    match = re.search(r"^POLICY_FILES=\(([^)]*)\)", script_content, re.MULTILINE)
    if not match:
        pytest.fail("POLICY_FILES array not found in deploy.sh")
    return [item for item in match.group(1).split() if item]


def test_policy_files_array_contains_runtime_policy_files(deploy_script: str):
    policy_files = _parse_policy_files(deploy_script)
    missing = [f for f in MUST_HAVE_POLICY_FILES if f not in policy_files]
    assert not missing, f"POLICY_FILES missing runtime policy files: {missing}"


def test_deploy_uses_single_canonical_runtime_root(deploy_script: str):
    assert 'PROD_DIR="$HOME/.smartclaw"' in deploy_script
    assert "SINGLE_DIR_MODE=0" in deploy_script
    assert 'cd "$PROD_DIR" && pwd -P' in deploy_script
    assert 'Prod   : $HOME/.smartclaw  (port $PROD_PORT)' in deploy_script


def test_single_dir_mode_skips_policy_and_skill_copy(deploy_script: str):
    assert 'Stage 4.5: Policy Sync (single-dir)' in deploy_script
    assert "no policy copy needed" in deploy_script
    assert 'Stage 4.6: Skills Sync (single-dir)' in deploy_script
    assert "no skills rsync needed" in deploy_script


def test_deploy_script_does_not_reference_retired_prod_path(deploy_script: str):
    retired_dir = ".smartclaw" + "_prod"
    retired_name = "hermes" + "_prod"
    assert retired_dir not in deploy_script
    assert retired_name not in deploy_script
