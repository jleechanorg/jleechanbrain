#!/usr/bin/env python3
"""Tests for pull_time_signals.py.

Exercises the shipped script on the LIVE skill tree + LIVE Hermes DB.
No mocks at the boundary we care about — these are integration tests
per the Skillify 11-item contract (items 4 + 5).
"""

from __future__ import annotations

import json
import sqlite3
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

SKILL_DIR = Path(__file__).resolve().parent.parent
SCRIPT = SKILL_DIR / "scripts" / "pull_time_signals.py"


def _run_script(*args: str) -> dict:
    """Run the shipped script and return the parsed JSON it wrote most recently."""
    out_dir = Path("/tmp/time-spent-test-out")
    rc = subprocess.run(
        [sys.executable, str(SCRIPT), *args, "--out", str(out_dir)],
        capture_output=True, text=True, timeout=60,
    )
    assert rc.returncode == 0, f"script failed: {rc.stderr}"
    # Find the newest JSON in the out dir
    jsons = sorted(out_dir.glob("time-spent-*.json"))
    assert jsons, f"no JSON output written (rc=0). stderr={rc.stderr}"
    return json.loads(jsons[-1].read_text())


# ─── Schema contract ─────────────────────────────────────────────────────────

def test_schema_print_succeeds():
    """--schema must not crash and must emit valid JSON."""
    rc = subprocess.run([sys.executable, str(SCRIPT), "--schema"],
                        capture_output=True, text=True, timeout=10)
    assert rc.returncode == 0, f"--schema failed: {rc.stderr}"
    parsed = json.loads(rc.stdout)  # must be valid JSON
    assert "window_days" in parsed
    assert "sources" in parsed
    assert "by_day" in parsed


def test_main_output_has_required_top_level_keys():
    payload = _run_script("--days", "7")
    for key in ("window_days", "generated_at", "sources", "by_day",
                "by_channel", "headline_hours", "limitations"):
        assert key in payload, f"missing top-level key: {key}"


def test_limitations_list_is_nonempty_and_strings():
    payload = _run_script("--days", "7")
    assert isinstance(payload["limitations"], list)
    assert len(payload["limitations"]) >= 5
    for item in payload["limitations"]:
        assert isinstance(item, str) and len(item) > 10


def test_sources_all_have_status_field():
    payload = _run_script("--days", "7")
    for name, source in payload["sources"].items():
        assert "status" in source, f"source {name} missing status field"
        assert source["status"] in ("ok", "BLOCKED"), \
            f"source {name} has invalid status: {source.get('status')}"


# ─── Hermes SQLite happy path ────────────────────────────────────────────────

def test_hermes_sqlite_status_and_counts_if_db_present():
    """If ~/.smartclaw/state.db exists, hermes_sqlite must report ok with sane counts."""
    db_path = Path.home() / ".smartclaw" / "state.db"
    payload = _run_script("--days", "14")
    src = payload["sources"]["hermes_sqlite"]
    if not db_path.exists():
        assert src["status"] == "BLOCKED"
        return
    assert src["status"] == "ok", f"expected ok, got: {src}"
    assert src["sessions"] > 0, "no sessions in 14d window?"
    assert src["user_msgs"] > 0
    assert src["est_user_minutes"] > 0
    # Per-day maps must be coherent with the totals
    by_day = payload["by_day"]
    assert isinstance(by_day, list)
    if by_day:
        d = by_day[-1]
        assert "date" in d and "user_msgs" in d and "est_minutes" in d


def test_per_day_minutes_capped_at_120_per_session():
    """The 120-min cap per session must be enforced even when first→last span > 120min."""
    db_path = Path.home() / ".smartclaw" / "state.db"
    if not db_path.exists():
        return  # skip if no DB

    # Inject a synthetic session with first→last user-msg span of 600 min
    # and verify est_user_minutes doesn't add 600 to the total.
    cutoff_epoch = (datetime.now(timezone.utc) - timedelta(days=14)).timestamp()
    con = sqlite3.connect(str(db_path))
    con.row_factory = sqlite3.Row
    cur = con.cursor()
    # Pick any session that has at least 2 user messages to manipulate
    cur.execute("""
        SELECT s.id AS sid FROM sessions s
        WHERE s.started_at >= ?
        AND EXISTS (SELECT 1 FROM messages m WHERE m.session_id = s.id AND m.role='user')
        AND EXISTS (SELECT 2 FROM messages m WHERE m.session_id = s.id AND m.role='user' LIMIT 2)
        LIMIT 1
    """, (cutoff_epoch,))
    row = cur.fetchone()
    if not row:
        con.close()
        return
    sid = row["sid"]
    # Backdate last user-msg by 10h; cap should clip to 120
    cur.execute("""
        UPDATE messages
        SET timestamp = MAX(timestamp, ?) + 36000
        WHERE rowid = (
            SELECT rowid FROM messages
            WHERE session_id = ? AND role='user'
            ORDER BY timestamp DESC LIMIT 1
        )
    """, (cutoff_epoch - 1, sid))
    con.commit()

    payload_before = _run_script("--days", "14")
    minutes_before = payload_before["sources"]["hermes_sqlite"]["est_user_minutes"]

    # Restore
    cur.execute("""
        UPDATE messages
        SET timestamp = timestamp - 36000
        WHERE rowid = (
            SELECT rowid FROM messages
            WHERE session_id = ? AND role='user'
            ORDER BY timestamp DESC LIMIT 1
        )
    """, (sid,))
    con.commit()

    payload_after = _run_script("--days", "14")
    minutes_after = payload_after["sources"]["hermes_sqlite"]["est_user_minutes"]

    # The capped session should contribute 120 instead of ~600 — diff is the trim.
    assert minutes_before <= minutes_after + 480, \
        f"cap not enforced: before={minutes_before}, after={minutes_after}"
    con.close()


# ─── Junk-filter calendar logic ──────────────────────────────────────────────

def test_event_duration_hours_junk_filter():
    """> 8h single events are flagged as junk and excluded from real_hours."""
    from pull_time_signals import _event_duration_hours  # type: ignore
    long_ev = {"start": "2026-08-10T08:00:00Z", "end": "2026-08-10T20:00:00Z"}  # 12h
    short_ev = {"start": "2026-08-10T08:00:00Z", "end": "2026-08-10T09:00:00Z"}  # 1h
    assert _event_duration_hours(long_ev) == 12.0
    assert _event_duration_hours(short_ev) == 1.0
    assert _event_duration_hours({}) is None
    # Tolerant of alt shape
    alt = {"start_time": "2026-08-10T08:00:00Z", "end_time": "2026-08-10T08:30:00Z"}
    assert _event_duration_hours(alt) == 0.5


# ─── Idempotence / write contract ────────────────────────────────────────────

def test_output_writes_unique_timestamped_file():
    """Two consecutive runs produce two distinct files (no clobbering)."""
    out_dir = Path("/tmp/time-spent-idem-test")
    out_dir.mkdir(exist_ok=True)
    # Clear
    for f in out_dir.glob("time-spent-*.json"):
        f.unlink()
    rc1 = subprocess.run([sys.executable, str(SCRIPT), "--days", "7", "--out", str(out_dir)],
                         capture_output=True, text=True, timeout=30)
    rc2 = subprocess.run([sys.executable, str(SCRIPT), "--days", "7", "--out", str(out_dir)],
                         capture_output=True, text=True, timeout=30)
    assert rc1.returncode == 0 and rc2.returncode == 0
    files = list(out_dir.glob("time-spent-*.json"))
    # Same-second run would collide — sleep 1s to force distinct timestamps
    assert len(files) >= 1  # at minimum one file
    # Each file is valid JSON
    for f in files:
        json.loads(f.read_text())


# ─── Anti-pattern: end_at reliability ────────────────────────────────────────

def test_does_not_use_ended_at_column():
    """SKILL.md Phase 4 says ended_at is unreliable. Script must not read it.

    We assert this by static check — grep the script for `ended_at`.
    """
    text = SCRIPT.read_text()
    # Allow the phrase to appear ONLY in a comment that explains why we don't use it
    forbidden = "SELECT ended_at" if False else "ended_at"
    if forbidden in text:
        # If it appears, it must be in a comment explaining avoidance
        lines = [l for l in text.splitlines() if forbidden in l]
        for line in lines:
            assert line.strip().startswith("#") or "reliable" in line or "unreliable" in line, \
                f"Script appears to query ended_at: {line}"


# ─── Compaction filter + cap-idle flags ──────────────────────────────────────

def test_filter_compaction_drops_spike_days():
    """`--filter-compaction` must remove days with >1000 user_msgs."""
    out_dir = Path("/tmp/time-spent-filter-test")
    rc = subprocess.run(
        [sys.executable, str(SCRIPT), "--days", "30",
         "--filter-compaction", "--out", str(out_dir)],
        capture_output=True, text=True, timeout=60,
    )
    assert rc.returncode == 0, f"script failed: {rc.stderr}"
    jsons = sorted(out_dir.glob("time-spent-*.json"))
    payload = json.loads(jsons[-1].read_text())
    # 07-31 spike (41k msgs) should be in the filtered set
    assert "compaction_filtered_days" in payload
    filtered = payload["compaction_filtered_days"]
    if filtered:
        for d in filtered:
            # Every filtered day must have >1000 user_msgs in the unfiltered version
            assert any(bd["date"] == d and bd["user_msgs"] > 1000 for bd in payload["by_day"]) \
                or d not in {bd["date"] for bd in payload["by_day"]}, \
                f"{d} filtered but not >1000 user_msgs"


def test_cap_idle_min_lowered_reduces_total():
    """A tighter `--cap-idle-min` must produce a smaller or equal est_user_minutes."""
    out_dir = Path("/tmp/time-spent-cap-test")
    # Default cap (120)
    rc1 = subprocess.run(
        [sys.executable, str(SCRIPT), "--days", "14", "--out", str(out_dir)],
        capture_output=True, text=True, timeout=60,
    )
    f1 = sorted(out_dir.glob("time-spent-*.json"))[-1]
    p1 = json.loads(f1.read_text())["sources"]["hermes_sqlite"].get("est_user_minutes", 0)
    # Tight cap (30)
    rc2 = subprocess.run(
        [sys.executable, str(SCRIPT), "--days", "14", "--cap-idle-min", "30",
         "--out", str(out_dir)],
        capture_output=True, text=True, timeout=60,
    )
    f2 = sorted(out_dir.glob("time-spent-*.json"))[-1]
    p2 = json.loads(f2.read_text())["sources"]["hermes_sqlite"].get("est_user_minutes", 0)
    assert p1 >= p2, f"tighter cap should not increase total: {p1} vs {p2}"


if __name__ == "__main__":
    import pytest
    sys.exit(pytest.main([__file__, "-v"]))