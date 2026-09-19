"""Tests for SOUL.md ## COMMIT: vendor-webcheck-first contract.

Verifies:
1. The COMMIT block exists in SOUL.md with the required trigger phrase.
2. The skill SKILL.md exists and references the trigger phrases.
3. The recipe document lists vendor-source URLs (catches regressions where
   a future edit removes the source-map).
4. No anti-pattern phrases ("I'll search my session memory first",
   "Let me think about whether that's a typo") appear in the skill.

Run from staging tree:
    cd ~/.smartclaw && PYTHONPATH=scripts python3 -m pytest \
        skills/vendor-webcheck-first/tests/test_vendor_webcheck_first_contract.py -v
"""
from __future__ import annotations

import os
import re
from pathlib import Path

import pytest


STAGING_ROOT = Path(os.environ.get("HERMES_ROOT", Path.home() / ".smartclaw"))
SOUL_PATH = STAGING_ROOT / "workspace" / "SOUL.md"
SKILL_PATH = STAGING_ROOT / "skills" / "vendor-webcheck-first" / "SKILL.md"


def _read(p: Path) -> str:
    if not p.exists():
        pytest.skip(f"File not present at {p} — run after deploy")
    return p.read_text(encoding="utf-8")


def test_soul_md_has_commit_block() -> None:
    """SOUL.md must contain the COMMIT block."""
    soul = _read(SOUL_PATH)
    assert "## COMMIT: vendor-webcheck-first" in soul, (
        "SOUL.md missing '## COMMIT: vendor-webcheck-first' block. "
        "Add it via patch mode=replace against a unique anchor."
    )


def test_commit_block_has_required_trigger_phrase() -> None:
    """The COMMIT block must include the canonical trigger phrase regex."""
    soul = _read(SOUL_PATH)
    m = re.search(
        r"## COMMIT: vendor-webcheck-first\s*\n(.*?)(?=\n## COMMIT:|\Z)",
        soul,
        re.DOTALL,
    )
    assert m, "COMMIT block present but not parseable"
    block = m.group(1)
    # Required trigger phrase coverage — must include at least one of these:
    assert any(
        phrase in block
        for phrase in [
            "user names a specific external artifact",
            "user-named",
            "user names",
            "vendor artifact",
        ]
    ), "COMMIT block missing trigger phrase"


def test_commit_block_has_curl_first_action() -> None:
    """The action must include curl/webcheck as the first step, not memory search."""
    soul = _read(SOUL_PATH)
    m = re.search(
        r"## COMMIT: vendor-webcheck-first\s*\n(.*?)(?=\n## COMMIT:|\Z)",
        soul,
        re.DOTALL,
    )
    block = m.group(1).lower()
    assert "curl" in block or "webcheck" in block or "web_extract" in block, (
        "COMMIT block must specify curl/web_extract/webcheck as the action"
    )


def test_skill_md_exists() -> None:
    """Skill SKILL.md must exist."""
    assert SKILL_PATH.exists(), f"Skill not found at {SKILL_PATH}"


def test_skill_md_has_yaml_frontmatter() -> None:
    """Skill SKILL.md must start with YAML frontmatter."""
    skill = _read(SKILL_PATH)
    assert skill.startswith("---\n"), "SKILL.md must start with --- frontmatter"
    assert "\n---\n" in skill, "SKILL.md missing closing ---"


def test_skill_md_has_vendor_source_map() -> None:
    """Vendor source map must include Google/OpenAI/Anthropic rows (anti-regression)."""
    skill = _read(SKILL_PATH)
    for vendor in ["Google", "OpenAI", "Anthropic"]:
        assert vendor in skill, f"Vendor source map missing entry for {vendor}"


def test_skill_md_excludes_anti_patterns() -> None:
    """Skill must NOT contain the anti-pattern phrases (these caused the incident)."""
    skill = _read(SKILL_PATH)
    # These phrases appear in the "Anti-patterns" section, which is fine.
    # Strip that section before checking.
    stripped = re.sub(
        r"## Anti-patterns\s*\n.*?(?=\n## |\Z)",
        "",
        skill,
        flags=re.DOTALL,
    )
    for anti in [
        "I'll search my session memory first",
        "Let me think about whether that's a typo",
    ]:
        assert anti not in stripped, (
            f"Anti-pattern phrase '{anti}' appears outside the Anti-patterns "
            f"section — remove or move into that section."
        )


def test_skill_md_references_origin_incident() -> None:
    """Skill must cite the origin Slack thread so future agents can verify."""
    skill = _read(SKILL_PATH)
    assert "1786698333.972209" in skill or "1786698423.832949" in skill, (
        "Skill must reference the origin incident thread/message ts"
    )


def test_skill_md_no_one_question_max_escape_hatch() -> None:
    """The 'one question max' rule must be present (anti-clarification-freeze)."""
    skill = _read(SKILL_PATH)
    assert "one question" in skill.lower() or "One question" in skill, (
        "Skill must include 'one question max' rule"
    )


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
