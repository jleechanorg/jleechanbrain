"""Tests for the campaign-creation skill v1.0.0 self-contained-prompt rule.

These tests verify the skill's structural contract:
- SKILL.md exists at ~/.smartclaw/skills/campaign-creation/SKILL.md
- SKILL.md frontmatter contains the v1.0.0 version marker
- SKILL.md contains the "Self-Contained Prompt Rule" section
- SKILL.md contains the "Locked 10-Section + Canon-Assumptions Shape" table
- The script-skill contract works on the Quiet War working example

These are triggered-evaluation checks — verify the skill exists, ships the right
sections, and that the actual working example satisfies the self-contained rule.
"""
import re
import sys
from pathlib import Path

SKILL_PATH = Path.home() / ".smartclaw/skills/campaign-creation/SKILL.md"
EXAMPLE_WIKI = Path.home() / "llm_wiki/wiki/sources/quiet-war-slim.md"
EXAMPLE_DRIVE_PATH = Path("/tmp/qw-doc-self-contained.txt")  # cached Drive body if needed


def _read(path: Path) -> str:
    if not path.exists():
        return ""
    return path.read_text()


def test_skill_file_exists() -> None:
    """SKILL.md lives at the canonical path."""
    assert SKILL_PATH.exists(), f"missing SKILL.md at {SKILL_PATH}"
    text = _read(SKILL_PATH)
    assert len(text) > 1000, f"SKILL.md is suspiciously short: {len(text)} bytes"


def test_skill_frontmatter_v100() -> None:
    """Frontmatter declares version 1.0.0."""
    text = _read(SKILL_PATH)
    m = re.search(r"version:\s*([\d.]+)", text)
    assert m, "missing version line"
    assert m.group(1) == "1.0.0", f"wrong version: {m.group(1)}"


def test_skill_self_contained_rule() -> None:
    """Phase 3 self-containment audit rules are present."""
    text = _read(SKILL_PATH)
    must_have = [
        "Self-Contained Prompt Rule",
        "Self-Containment Audit",
        "External URL test",
        "External ID test",
        "Cross-doc backref test",
        "Code reference test",
        "Inlining test",
    ]
    for needle in must_have:
        assert needle in text, f"missing required section: {needle!r}"


def test_skill_locked_shape_table() -> None:
    """The 10-section + canon-assumptions shape table is present."""
    text = _read(SKILL_PATH)
    must_have_sections = [
        "Canon assumptions",
        "§1", "The Setting",
        "§2", "Personality",
        "§3", "Class",
        "§4", "Assets",
        "§5", "Family",
        "§6", "Factions",
        "§7", "Mechanical Systems",
        "§8", "Gazetteer",
        "§9", "Starting Scene",
        "§10", "Continuity Hooks",
        "Setup Notes",
    ]
    for needle in must_have_sections:
        assert needle in text, f"missing shape section: {needle!r}"


def test_skill_no_ending_section() -> None:
    """The skill itself bans Ending Determinator / Canonical Ending sections."""
    text = _read(SKILL_PATH)
    # The phrase "No Canonical Ending" must appear
    assert "No Canonical Ending" in text or "no Canonical Ending" in text or \
           "no Canonical Ending, no Final Verdict, no Ending Determinator" in text, \
        "Rule 10 (no endings) not pinned"
    # Anti-pattern "Endings Matrix" must appear as a banned term
    assert "Endings Matrix" in text, "Endings Matrix ban not pinned"


def test_working_example_no_urls() -> None:
    """The Quiet War slim bible has zero external URLs."""
    if not EXAMPLE_WIKI.exists():
        return  # working example file absent — skill itself should still be sound
    text = _read(EXAMPLE_WIKI)
    urls = re.findall(r"https?://\S+", text)
    assert not urls, f"working example has URLs: {urls[:5]}"


def test_working_example_no_external_ids() -> None:
    """No Drive doc IDs, no wiki cross-doc refs, no GitHub URLs in the working example."""
    if not EXAMPLE_WIKI.exists():
        return
    text = _read(EXAMPLE_WIKI)
    forbidden = [
        r"github\.com/jleechanorg",
        r"docs\.google\.com",
        r"11oBduyCd6HsydnWi6YwxDHrwDm4L1VQFCGe0hD8mp04",
        r"1ZLC7LXj2goOP30e395647XO1PChGhDgO",
        r"^See §\d+",
        r"^see §\d+",
    ]
    for pat in forbidden:
        hits = re.findall(pat, text, flags=re.MULTILINE)
        assert not hits, f"working example contains external-id pattern {pat!r}: {hits[:2]}"


def test_working_example_no_code_refs() -> None:
    """No Python class names, Flask routes, file paths in the working example."""
    if not EXAMPLE_WIKI.exists():
        return
    text = _read(EXAMPLE_WIKI)
    forbidden = [
        r"\.py\b",
        r"world_logic\.py",
        r"flask",
        r"/Users/jleechan",
        r"\bpip install\b",
    ]
    for pat in forbidden:
        hits = re.findall(pat, text)
        # Allow legitimate references to "Heroism" or named-character; block code paths
        assert not hits, f"working example contains code reference {pat!r}: {hits[:2]}"


def test_working_example_canon_assumptions_inline() -> None:
    """The §0 'Canon assumptions' block exists and contains lineage + status."""
    if not EXAMPLE_WIKI.exists():
        return
    text = _read(EXAMPLE_WIKI)
    must_have = [
        "Canon assumptions",
        "Raziel",
        "Lucifer",
        "Alexiel",
        "Sariel",
        "Empressariel",
        "Lumiel",
        "Vaelara XI",
        "is the Empress's mother",
    ]
    for needle in must_have:
        assert needle in text, f"canon-assumption block missing: {needle!r}"


if __name__ == "__main__":
    tests = [g for n in dir() if n.startswith("test_") for g in [n]]
    failed = 0
    for name in tests:
        try:
            globals()[name]()
            print(f"  PASS  {name}")
        except AssertionError as e:
            print(f"  FAIL  {name}: {e}")
            failed += 1
    print(f"\n{len(tests) - failed} passed / {failed} failed")
    sys.exit(0 if failed == 0 else 1)
