"""Smoke tests for skill existence.

This module is a placeholder for skill-level integration tests. The actual
regression coverage for the daily-dice-audit fix recipe lives in the
`jleechanorg/worldarchitect.ai` repository at:

  mvp_site/tests/test_action_resolution_utils.py
  mvp_site/tests/test_audit_dice_rolls.py
  mvp_site/tests/test_fix_dice_notation_concat.py

For skill-existence checks (this file):
"""

import os


def test_skill_file_exists():
    """Verify the SKILL.md file is present at the canonical path."""
    path = os.path.join(
        os.path.dirname(__file__),
        "..",
        "SKILL.md",
    )
    assert os.path.exists(path), f"SKILL.md missing at {path}"


def test_resolver_file_exists():
    """Verify the RESOLVER.md file is present."""
    path = os.path.join(
        os.path.dirname(__file__),
        "..",
        "RESOLVER.md",
    )
    assert os.path.exists(path), f"RESOLVER.md missing at {path}"
