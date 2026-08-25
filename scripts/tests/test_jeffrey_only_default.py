"""Contract test for the jeffrey-only default change in dropped-thread-followup.sh.

The 2026-07-04 bug: the script's JEFFREY_ONLY_CHANNELS default was ${SLACK_CHANNEL_ID}
(#all-jleechan-ai). For the new operator-Hermes direct-line model, this caused
every Jeffrey-only thread in that channel to return action_needed=False and be
silently skipped. Jeffrey was left needing to @-mention Hermes explicitly.

Fix contract:
  - DROP_JEFFREY_ONLY_CHANNELS UNSET (the default) → JEFFREY_ONLY_CHANNELS=""
  - DROP_JEFFREY_ONLY_CHANNELS="C09..." (explicit) → JEFFREY_ONLY_CHANNELS=<value>
  - DROP_JEFFREY_ONLY_CHANNELS="" (explicit empty) → JEFFREY_ONLY_CHANNELS=""

In all three cases the gating is OFF by default for #all-jleechan-ai, but
operators can opt back in for any specific channel.

This is a pure bash-config regression test: it sources the early lines of
dropped-thread-followup.sh in a subshell with controlled env and asserts
the resulting JEFFREY_ONLY_CHANNELS value.
"""
import os
import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts/dropped-thread-followup.sh"


def _read_setup_block():
    """Read the early JEFFREY_ONLY_CHANNELS config block from the script."""
    text = SCRIPT.read_text()
    # Find the entire "if [[ ${DROP_JEFFREY_ONLY_CHANNELS+x}" block including its
    # matching `fi` and the trailing export line.
    m = re.search(
        r"# Space-separated channel IDs.*?(?=^# ──)", text, re.DOTALL | re.MULTILINE,
    )
    assert m, "could not find the JEFFREY_ONLY_CHANNELS config block in script"
    return m.group(0)


def _eval_block(env_overrides):
    """Source the JEFFREY_ONLY_CHANNELS block in a subshell and return the value."""
    setup_block = _read_setup_block()
    # Build a one-line bash that sources the block then echoes the value.
    # We construct the bash command string outside the Python f-string so
    # curly braces in the regex don't conflict.
    sentinel = (
        'printf "VAL=[%s]\\n" "$JEFFREY_ONLY_CHANNELS"\n'
    )
    full = setup_block + "\n" + sentinel
    env = {**os.environ, **env_overrides}
    # Make sure target env var doesn't bleed in unless we want it
    env.pop("DROP_JEFFREY_ONLY_CHANNELS", None)
    env.update(env_overrides)
    result = subprocess.run(
        ["bash", "-c", full],
        capture_output=True, text=True, env=env, timeout=10,
    )
    return result


def test_unset_default_is_empty():
    """No env override → JEFFREY_ONLY_CHANNELS should be empty (the new default)."""
    r = _eval_block({})  # no overrides (DROP_JEFFREY_ONLY_CHANNELS unset)
    assert "VAL=[]" in r.stdout, (
        f"FAIL: JEFFREY_ONLY_CHANNELS should be empty by default. "
        f"stdout={r.stdout!r} stderr={r.stderr!r}"
    )


def test_explicit_empty_override_kept_empty():
    """DROP_JEFFREY_ONLY_CHANNELS='' (explicit empty) → empty."""
    r = _eval_block({"DROP_JEFFREY_ONLY_CHANNELS": ""})
    assert "VAL=[]" in r.stdout, (
        f"FAIL: explicit empty override should produce empty value. "
        f"stdout={r.stdout!r} stderr={r.stderr!r}"
    )


def test_explicit_channel_override_passes_through():
    """DROP_JEFFREY_ONLY_CHANNELS='C0ANOTHERCHAN' → JEFFREY_ONLY_CHANNELS=C0ANOTHERCHAN."""
    r = _eval_block({"DROP_JEFFREY_ONLY_CHANNELS": "C0ANOTHERCHAN"})
    assert "VAL=[C0ANOTHERCHAN]" in r.stdout, (
        f"FAIL: explicit channel override should pass through. "
        f"stdout={r.stdout!r} stderr={r.stderr!r}"
    )


def test_default_does_not_contain_c09grlxf9gr():
    """The new default assignment must NOT contain ${SLACK_CHANNEL_ID}."""
    text = SCRIPT.read_text()
    # Find every line that assigns to JEFFREY_ONLY_CHANNELS
    assigns = [
        ln for ln in text.splitlines()
        if re.match(r"\s*JEFFREY_ONLY_CHANNELS=", ln)
        and "=(" not in ln
    ]
    assert assigns, "no JEFFREY_ONLY_CHANNELS assignment found in script"
    for ln in assigns:
        assert "${SLACK_CHANNEL_ID}" not in ln, (
            f"FAIL: JEFFREY_ONLY_CHANNELS default still references ${SLACK_CHANNEL_ID}: {ln!r}"
        )


def test_export_present():
    """The fix must `export JEFFREY_ONLY_CHANNELS` so subprocess readers see it."""
    text = SCRIPT.read_text()
    assert "export JEFFREY_ONLY_CHANNELS" in text, (
        "FAIL: missing `export JEFFREY_ONLY_CHANNELS` after the if/fi block"
    )


if __name__ == "__main__":
    import pytest
    sys.exit(pytest.main([__file__, "-v"]))
