#!/usr/bin/env python3
"""Contract test for the dropped-thread-watcher-of-watchers harness fix.

Verifies the post-incident guarantees without external services:
1. Plist template StartInterval is <= 1800 (must be tighter than the 4h that masked the bug).
2. Inner plist has KeepAlive{SuccessfulExit=false} (the launchd silent-death fix).
3. Watcher plist exists, references the inner label, and has StartInterval=900.
4. Watcher script has a cooldown window (avoids alert spam) and mentions both
   launchd-state and log-mtime checks.
5. SOUL.md has the ## COMMIT: dropped-thread-watcher-of-watchers anchor.

Run: python3 -m pytest scripts/tests/test_dropped_thread_watcher_contract.py -q
"""
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
INNER_PLIST = REPO_ROOT / "launchd/ai.smartclaw.schedule.dropped-thread-followup.plist"
WATCHER_PLIST = REPO_ROOT / "launchd/ai.smartclaw.schedule.dropped-thread-watcher.plist"
WATCHER_SCRIPT = REPO_ROOT / "scripts/dropped-thread-watcher-of-watchers.sh"
SOUL = REPO_ROOT / "workspace/SOUL.md"

def _read(path: Path) -> str:
    assert path.exists(), f"missing: {path}"
    return path.read_text()

def test_inner_plist_interval_is_tight():
    text = _read(INNER_PLIST)
    m = re.search(r"<key>StartInterval</key>\s*<integer>(\d+)</integer>", text)
    assert m, "StartInterval missing in inner plist"
    interval = int(m.group(1))
    assert interval <= 1800, (
        f"StartInterval={interval}s (>1800/30min). "
        "The original 14400 (4h) interval is what masked the silent-death bug. "
        "Tighten to <=1800."
    )

def test_inner_plist_has_keepalive_successful_exit_false():
    text = _read(INNER_PLIST)
    assert "<key>KeepAlive</key>" in text, "KeepAlive missing — launchd will treat silent 0-exit as success"
    ka_block = re.search(r"<key>KeepAlive</key>\s*<dict>(.*?)</dict>", text, re.S)
    assert ka_block, "KeepAlive dict malformed"
    assert "<key>SuccessfulExit</key>" in ka_block.group(1)
    assert re.search(r"<key>SuccessfulExit</key>\s*<false/>", ka_block.group(1)), (
        "KeepAlive/SuccessfulExit must be false — the launchd silent-death guard"
    )

def test_watcher_plist_references_inner_label_as_string():
    text = _read(WATCHER_PLIST)
    # The reference must be inside a <string>...</string> element so the script
    # (or an env-substituted re-derive) can find it; comments alone are not load-bearing.
    assert re.search(r"<string>ai\.smartclaw\.schedule\.dropped-thread-followup</string>", text), (
        "watcher plist must reference the inner label as a <string> element "
        "for the launchctl print check"
    )

def test_watcher_plist_interval_is_15min():
    text = _read(WATCHER_PLIST)
    m = re.search(r"<key>StartInterval</key>\s*<integer>(\d+)</integer>", text)
    assert m and int(m.group(1)) == 900, "watcher plist StartInterval must be 900s (15 min)"

def test_watcher_script_has_cooldown():
    text = _read(WATCHER_SCRIPT)
    # Either an env-var default or a hardcoded constant — both are valid; just verify
    # that "cooldown" appears in a guard comparison (not just in a comment).
    assert re.search(r"COOLDOWN_SECONDS\s*=\s*\S+", text), (
        "watcher script must set a COOLDOWN_SECONDS value (env default or literal)"
    )
    # And the cooldown must actually gate the alert (not be decorative).
    assert re.search(r"since_last\s*<\s*COOLDOWN_SECONDS", text) or re.search(
        r"since_last.*COOLDOWN_SECONDS", text
    ), "the cooldown value must gate the alert path, not appear in a comment only"

def test_watcher_script_checks_both_launchd_and_log_mtime():
    text = _read(WATCHER_SCRIPT)
    assert "launchctl print" in text, "must check launchctl print for inner job state"
    assert re.search(r"stat.*-f.*\"%m\"|log_mtime", text), (
        "must check log file mtime to detect silent-death even when launchd reports loaded"
    )

def test_soul_has_dropped_thread_watcher_commit():
    text = _read(SOUL)
    assert "## COMMIT: dropped-thread-watcher-of-watchers" in text, (
        "SOUL.md must record the harness COMMIT block"
    )
    # The block must cite the originating incident URL
    assert "p1783124135813349" in text, "SOUL.md COMMIT must reference the originating Slack ts"

if __name__ == "__main__":
    import pytest
    sys.exit(pytest.main([__file__, "-v"]))
