"""Test for pre-execution-option-bailout-guard SOUL.md COMMIT block.

Failure class (MAST FC3, ETCLOVG Verification): agent reaches "I could
execute this" then hands the user a menu instead of executing. The
trigger surface is any 2+ option menu in a Slack reply when the user
already authorized execution in the current message.

Bug-ref: Slack ${SLACK_CHANNEL_ID}/p1786580624 (Jeffrey 2026-08-13
"Why would you stop when 2) is a valid option? Run /harness").
"""
import re
import subprocess
from pathlib import Path


SOUL_MD = Path.home() / ".smartclaw" / "workspace" / "SOUL.md"


def _read_soul() -> str:
    """Read the live SOUL.md from the active (~/.smartclaw) tree."""
    if not SOUL_MD.exists():
        # Fall back to .smartclaw being a symlink to staging
        return SOUL_MD.read_text() if SOUL_MD.exists() else ""
    return SOUL_MD.read_text()


def test_commit_block_exists():
    """The new COMMIT block must be present in the live SOUL.md."""
    text = _read_soul()
    assert "## COMMIT: pre-execution-option-bailout-guard" in text, (
        "pre-execution-option-bailout-guard COMMIT block missing from SOUL.md"
    )


def test_commit_block_has_trigger_and_action():
    """The block must define both Trigger and Action lines, not just a heading."""
    text = _read_soul()
    # Find the block (starts with the heading, ends at next blank line + ## COMMIT:)
    match = re.search(
        r"## COMMIT: pre-execution-option-bailout-guard\n(Trigger:[^\n]+\n)(Action:[^\n]+(?:\n(?!## COMMIT:)[^\n]*)*)",
        text,
    )
    assert match, "COMMIT block malformed: missing Trigger/Action lines"
    trigger = match.group(1)
    action = match.group(2)
    assert "2+ option menu" in trigger or "multi-option" in trigger, (
        f"Trigger line should mention option-menu pattern; got: {trigger!r}"
    )
    assert "Do NOT post the menu" in action or "execute" in action.lower(), (
        f"Action line should direct execution; got: {action!r}"
    )


def test_no_lost_commit_blocks():
    """Adding this block must not have removed any pre-existing COMMIT blocks."""
    text = _read_soul()
    blocks = re.findall(r"^## COMMIT: ", text, re.MULTILINE)
    # 55 pre-existing + 1 new = 56 on origin/main + this change
    assert len(blocks) == 56, f"Expected 56 COMMIT blocks, found {len(blocks)}"


def test_curl_first_pattern_documented():
    """The block must encode the curl-first pattern for public social URLs."""
    text = _read_soul()
    block_match = re.search(
        r"## COMMIT: pre-execution-option-bailout-guard.*?(?=\n## COMMIT: |\Z)",
        text,
        re.DOTALL,
    )
    assert block_match, "Block not found"
    block = block_match.group(0)
    assert "og:description" in block, "Block should mention og:description extraction"
    assert "curl" in block.lower(), "Block should mention curl"
    assert "LinkedIn" in block or "/posts/" in block, "Block should call out LinkedIn /posts/ URLs"


def test_block_references_meta_autonomy_companion():
    """The block must explicitly link to meta-autonomy-violation-handler as its AFTER-the-fact cousin."""
    text = _read_soul()
    assert "meta-autonomy-violation-handler" in text, (
        "Block must reference the parent meta-autonomy-violation-handler COMMIT"
    )


def test_block_references_bug_ref():
    """The block must cite the originating Slack thread."""
    text = _read_soul()
    assert "${SLACK_CHANNEL_ID}/p1786580624" in text, "Block must cite the bug-ref thread"


if __name__ == "__main__":
    # Allow running as a script for quick local sanity check
    import sys
    failures = []
    for name in dir():
        if name.startswith("test_") and callable(eval(name)):
            try:
                eval(name)()
                print(f"  PASS: {name}")
            except AssertionError as e:
                failures.append((name, str(e)))
                print(f"  FAIL: {name}: {e}")
    if failures:
        sys.exit(1)
    print("ALL PASS")
