#!/usr/bin/env python3
"""
Test: config-disable-requires-gateway-restart-reminder COMMIT

Verifies the COMMIT block exists in SOUL.md with both:
1. The trigger ("agent commits disabled_toolsets change + gateway still running")
2. The action ("verify gateway PID etime > config mtime; post restart reminder")

Run: python3 -m pytest tests/test_config_restart_reminder_contract.py -v
"""
import os

SOUL_PATH = os.path.expanduser("~/.smartclaw/workspace/SOUL.md")


def test_commit_block_present():
    with open(SOUL_PATH) as f:
        content = f.read()
    assert "## COMMIT: config-disable-requires-gateway-restart-reminder" in content, (
        "SOUL.md missing the COMMIT block"
    )


def test_commit_has_etime_check_action():
    """The action must include the etime/mtime comparison."""
    with open(SOUL_PATH) as f:
        content = f.read()
    # Locate the COMMIT block
    start = content.index("## COMMIT: config-disable-requires-gateway-restart-reminder")
    end = content.index("## COMMIT:", start + 10)
    block = content[start:end]
    assert "etime" in block, "COMMIT action missing etime check"
    assert "config.yaml" in block, "COMMIT action missing config.yaml reference"
    assert "hermes gateway restart" in block, "COMMIT action missing the restart command"
    assert "config.yaml doesn't hot-reload" in block or "config does not hot-reload" in block, (
        "COMMIT action missing the 'config does not hot-reload' reminder"
    )


def test_commit_has_bug_ref():
    with open(SOUL_PATH) as f:
        content = f.read()
    start = content.index("## COMMIT: config-disable-requires-gateway-restart-reminder")
    end = content.index("## COMMIT:", start + 10)
    block = content[start:end]
    assert "C0AH3RY3DK6/p1787185077" in block, "Missing bug-ref to clarify-button-menus thread"


def test_commit_classifies_mast_etclovg():
    with open(SOUL_PATH) as f:
        content = f.read()
    start = content.index("## COMMIT: config-disable-requires-gateway-restart-reminder")
    end = content.index("## COMMIT:", start + 10)
    block = content[start:end]
    assert "MAST" in block and "ETCLOVG" in block, "Missing MAST/ETCLOVG classification"
    assert "Lifecycle" in block or "Verification" in block, "Missing ETCLOVG layer"


if __name__ == "__main__":
    test_commit_block_present()
    test_commit_has_etime_check_action()
    test_commit_has_bug_ref()
    test_commit_classifies_mast_etclovg()
    print("✓ all 4 config-restart-reminder contract tests passed")
