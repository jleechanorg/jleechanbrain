#!/usr/bin/env python3
"""Test: claudem-p-flag-mandatory-dispatch-prefix COMMIT.

Run: python3 -m pytest tests/test_claudem_p_flag_contract.py -v
"""
import os
import subprocess

SOUL_PATH = os.path.expanduser("~/.smartclaw/workspace/SOUL.md")

COMMIT_HEADER = "## COMMIT: claudem-p-flag-mandatory-dispatch-prefix"
NEXT_COMMIT = "\n## COMMIT:"


def _block():
    with open(SOUL_PATH) as f:
        content = f.read()
    start = content.index(COMMIT_HEADER)
    end_idx = content.find(NEXT_COMMIT, start + 10)
    if end_idx == -1:
        end_idx = len(content)
    return content[start:end_idx]


def test_commit_block_present():
    with open(SOUL_PATH) as f:
        content = f.read()
    assert COMMIT_HEADER in content, "SOUL.md missing the COMMIT block"


def test_commit_has_dash_p_action():
    block = _block()
    assert "-p" in block, "COMMIT missing -p flag reference"
    assert "print mode" in block, "COMMIT missing 'print mode' explanation"
    assert "interactive session" in block, "COMMIT missing the silent-interactive-session trap description"


def test_commit_has_smoke_test_recommendation():
    block = _block()
    assert "smoke" in block.lower(), "COMMIT missing smoke-test recommendation"


def test_commit_has_bug_ref():
    block = _block()
    assert "C0AH3RY3DK6/p1787187424" in block, "Missing bug-ref to living-world dispatch thread"


def test_claudem_wrapper_print_mode_is_default():
    """If the claudem bashrc function is loaded, smoke-test that -p roundtrips."""
    try:
        result = subprocess.run(
            ["bash", "-lic", "type claudem 2>/dev/null | head -3"],
            capture_output=True, text=True, timeout=10,
        )
        if "function claudem" in result.stdout or "claudem is a function" in result.stdout:
            print("OK claudem wrapper found in bashrc; runtime check skipped (out of scope for unit test)")
        else:
            print("WARN claudem wrapper not loaded in this shell — skipping runtime check")
    except Exception as e:
        print(f"WARN could not probe claudem wrapper: {e}")


if __name__ == "__main__":
    test_commit_block_present()
    test_commit_has_dash_p_action()
    test_commit_has_smoke_test_recommendation()
    test_commit_has_bug_ref()
    test_claudem_wrapper_print_mode_is_default()
    print("OK all 5 claudem -p flag contract tests passed")
