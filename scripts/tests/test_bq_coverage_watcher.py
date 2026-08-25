"""Unit tests for the BQ coverage watcher.

Validates the recent-rate alerting logic added on 2026-07-13 (post-#8351 fix).
The watcher must:
  - Alert on ACTIVE recent-rate drift, not on cumulative 7d backlog.
  - Report backlog as informational only.
  - Persist streak counter across runs.
  - Preserve legacy behavior when BQ_WATCH_USE_RECENT_RATE=false.

Run: cd ~/.smartclaw && python3 -m pytest tests/test_bq_coverage_watcher.py -v
"""
from __future__ import annotations

import importlib.util
import json
from pathlib import Path

import pytest


WATCHER_PATH = Path.home() / ".smartclaw" / "scripts" / "bq_coverage_watcher.py"


def _load_watcher(monkeypatch, **env_overrides):
    for k, v in env_overrides.items():
        monkeypatch.setenv(k, str(v))
    spec = importlib.util.spec_from_file_location("bq_coverage_watcher", WATCHER_PATH)
    watcher = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(watcher)
    return watcher


@pytest.fixture
def tmp_streak_state(tmp_path, monkeypatch):
    state_path = tmp_path / "streak.json"
    monkeypatch.setenv("BQ_WATCH_STREAK_STATE_PATH", str(state_path))
    return state_path


def _row(*cells):
    """Single-row, N-cell response."""
    return {"rows": [{"f": [{"v": c} for c in cells]}]}


def _streaming_rows():
    # 100% req_json, 100% resp_text, 100% finish_reason, 0% empty — healthy
    return _row("10000", "10000", "10000", "10000", "0")


def _nonstream_rows():
    return _row("500", "500", "500", "500", "0")


def _latest_rows():
    return _row("2026-07-13 22:14:00 UTC", "104")


def test_cumulative_backlog_alone_does_not_trip_recent_rate_alert(monkeypatch, tmp_streak_state):
    """A large 7d backlog (post-#8351) must NOT trip an alert in recent-rate mode."""
    watcher = _load_watcher(monkeypatch)

    bq_responses = iter([
        _streaming_rows(),
        _nonstream_rows(),
        _row("0", "0"),  # recent active null = 0
        _row("8800", "4859"),  # cumulative backlog
        _row("10000", "1200"),
        _latest_rows(),
    ])

    posted = []
    monkeypatch.setattr(watcher, "_run_query", lambda q, t, max_rows=200: next(bq_responses))
    monkeypatch.setattr(watcher, "_bq_token", lambda: "fake-token")
    monkeypatch.setattr(watcher, "_slack_post", lambda *a, **kw: posted.append(a[1]))

    rc = watcher.main()
    assert rc == 0, f"Backlog alone triggered alert (rc={rc}). Expected clean."
    assert len(posted) == 0

    saved = json.loads(tmp_streak_state.read_text())
    assert saved["consecutive_nonzero"] == 0


def test_active_window_threshold_trips_alert(monkeypatch, tmp_streak_state):
    """Recent-window count >= ACTIVE_NULL_ABS_THRESHOLD (10) triggers alert."""
    watcher = _load_watcher(monkeypatch)

    bq_responses = iter([
        _streaming_rows(),
        _nonstream_rows(),
        _row("42", "42"),  # active null = 42 >= 10
        _row("8800", "4859"),
        _row("10000", "1200"),
        _latest_rows(),
    ])

    posted = []
    monkeypatch.setattr(watcher, "_run_query", lambda q, t, max_rows=200: next(bq_responses))
    monkeypatch.setattr(watcher, "_bq_token", lambda: "fake-token")
    monkeypatch.setattr(watcher, "_slack_post", lambda *a, **kw: posted.append(a[1]))

    rc = watcher.main()
    assert rc == 1, f"Expected alert (rc=1), got rc={rc}"
    assert len(posted) == 1
    msg = posted[0]
    assert "42 Gemini rows in last 24h" in msg
    assert "≥ 10" in msg


def test_streak_detection_across_recent_windows(monkeypatch, tmp_streak_state):
    """3 consecutive runs each with >= 1 active NULL → streak alert fires."""
    tmp_streak_state.write_text(json.dumps({"consecutive_nonzero": 2}))
    watcher = _load_watcher(monkeypatch)

    bq_responses = iter([
        _streaming_rows(),
        _nonstream_rows(),
        _row("1", "1"),  # 1 active NULL → streak becomes 3
        _row("8800", "4859"),
        _row("10000", "1200"),
        _latest_rows(),
    ])

    posted = []
    monkeypatch.setattr(watcher, "_run_query", lambda q, t, max_rows=200: next(bq_responses))
    monkeypatch.setattr(watcher, "_bq_token", lambda: "fake-token")
    monkeypatch.setattr(watcher, "_slack_post", lambda *a, **kw: posted.append(a[1]))

    rc = watcher.main()
    assert rc == 1, f"Streak should trigger alert (rc=1), got rc={rc}"
    msg = posted[0]
    assert "3 consecutive run" in msg

    saved = json.loads(tmp_streak_state.read_text())
    assert saved["consecutive_nonzero"] == 3


def test_streak_resets_on_clean_run(monkeypatch, tmp_streak_state):
    """A clean run (0 active NULL) must reset streak counter to 0."""
    tmp_streak_state.write_text(json.dumps({"consecutive_nonzero": 5}))
    watcher = _load_watcher(monkeypatch)

    bq_responses = iter([
        _streaming_rows(),
        _nonstream_rows(),
        _row("0", "0"),
        _row("8800", "4859"),
        _row("10000", "1200"),
        _latest_rows(),
    ])

    posted = []
    monkeypatch.setattr(watcher, "_run_query", lambda q, t, max_rows=200: next(bq_responses))
    monkeypatch.setattr(watcher, "_bq_token", lambda: "fake-token")
    monkeypatch.setattr(watcher, "_slack_post", lambda *a, **kw: posted.append(a[1]))

    rc = watcher.main()
    assert rc == 0
    saved = json.loads(tmp_streak_state.read_text())
    assert saved["consecutive_nonzero"] == 0


def test_use_recent_rate_false_preserves_old_behavior(monkeypatch, tmp_streak_state):
    """BQ_WATCH_USE_RECENT_RATE=false restores legacy cumulative-7d alerting."""
    watcher = _load_watcher(monkeypatch, BQ_WATCH_USE_RECENT_RATE="false")

    bq_responses = iter([
        _streaming_rows(),
        _nonstream_rows(),
        _row("8800", "4859"),  # cumulative NULL
        _row("10000", "1200"),  # 12% populated
        # per_day: 3 separate ROWS of (date, count) — 2 cells per row
        {"rows": [
            {"f": [{"v": "2026-07-12"}, {"v": "1000"}]},
            {"f": [{"v": "2026-07-11"}, {"v": "500"}]},
            {"f": [{"v": "2026-07-10"}, {"v": "200"}]},
        ]},
        _latest_rows(),
    ])

    posted = []
    monkeypatch.setattr(watcher, "_run_query", lambda q, t, max_rows=200: next(bq_responses))
    monkeypatch.setattr(watcher, "_bq_token", lambda: "fake-token")
    monkeypatch.setattr(watcher, "_slack_post", lambda *a, **kw: posted.append(a[1]))

    rc = watcher.main()
    assert rc == 1, f"Legacy mode must alert, got rc={rc}. Posted messages: {posted}"
    msg = posted[0]
    assert "8800 Gemini rows over 7d" in msg, f"msg was: {msg[:500]}"
    assert "Active" not in msg, f"Active should not appear: {msg[:500]}"


def test_streak_state_handles_missing(monkeypatch, tmp_streak_state):
    """Missing streak state file is treated as 0 (cold start)."""
    assert not tmp_streak_state.exists()
    watcher = _load_watcher(monkeypatch)
    state = watcher._load_streak_state()
    assert state == {"consecutive_nonzero": 0}


def test_streak_state_handles_corrupt(monkeypatch, tmp_streak_state):
    """Corrupt streak state file is treated as 0 (do not crash)."""
    tmp_streak_state.write_text("not valid json {")
    watcher = _load_watcher(monkeypatch)
    state = watcher._load_streak_state()
    assert state == {"consecutive_nonzero": 0}


def test_active_alert_includes_remediation_hint(monkeypatch, tmp_streak_state):
    """24h active-window alert must include the remediation hint + bq_logging.py path."""
    watcher = _load_watcher(monkeypatch)

    bq_responses = iter([
        _streaming_rows(),
        _nonstream_rows(),
        _row("42", "42"),  # active null = 42 >= 10
        _row("8800", "4859"),
        _row("10000", "1200"),
        _latest_rows(),
    ])

    posted = []
    monkeypatch.setattr(watcher, "_run_query", lambda q, t, max_rows=200: next(bq_responses))
    monkeypatch.setattr(watcher, "_bq_token", lambda: "fake-token")
    monkeypatch.setattr(watcher, "_slack_post", lambda *a, **kw: posted.append(a[1]))

    rc = watcher.main()
    assert rc == 1
    msg = posted[0]
    # Operator must see the file path, not just the flag name
    assert "mvp_site/bq_logging.py" in msg, f"missing file path: {msg[:400]}"
    # Operator must see at least one remediation step
    assert "Remediation:" in msg, f"missing remediation hint: {msg[:400]}"
    assert "redeploy" in msg.lower(), f"missing redeploy step: {msg[:400]}"
    assert "backfill_bq_is_test_null.py" in msg, f"missing backfill pointer: {msg[:400]}"


def test_streak_summary_labeled_with_threshold(monkeypatch, tmp_streak_state):
    """Streak summary line must show TRIPS alert >= N when threshold is hit."""
    # Pre-seed streak = 2 so this run with 1 NULL pushes it to 3 (== threshold).
    tmp_streak_state.write_text(json.dumps({"consecutive_nonzero": 2}))
    watcher = _load_watcher(monkeypatch)

    bq_responses = iter([
        _streaming_rows(),
        _nonstream_rows(),
        _row("1", "1"),  # 1 active NULL → streak becomes 3
        _row("8800", "4859"),
        _row("10000", "1200"),
        _latest_rows(),
    ])

    posted = []
    monkeypatch.setattr(watcher, "_run_query", lambda q, t, max_rows=200: next(bq_responses))
    monkeypatch.setattr(watcher, "_bq_token", lambda: "fake-token")
    monkeypatch.setattr(watcher, "_slack_post", lambda *a, **kw: posted.append(a[1]))

    rc = watcher.main()
    assert rc == 1
    msg = posted[0]
    # The summary line must show "TRIPS alert >= N" when threshold hit
    assert "TRIPS alert" in msg, f"missing TRIPS label: {msg[:400]}"


def test_streak_summary_under_threshold(monkeypatch, tmp_streak_state):
    """Streak below threshold shows plain (alert threshold: N) label."""
    watcher = _load_watcher(monkeypatch)

    def _run_query_factory():
        bq_responses = iter([
            _streaming_rows(),
            _nonstream_rows(),
            _row("1", "1"),  # streak = 1, below threshold of 3
            _row("8800", "4859"),
            _row("10000", "1200"),
            _latest_rows(),
        ])
        return lambda q, t, max_rows=200: next(bq_responses)

    posted = []
    monkeypatch.setattr(watcher, "_run_query", _run_query_factory())
    monkeypatch.setattr(watcher, "_bq_token", lambda: "fake-token")
    monkeypatch.setattr(watcher, "_slack_post", lambda *a, **kw: posted.append(a[1]))

    import io
    import contextlib
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = watcher.main()
    stdout_msg = buf.getvalue()

    assert rc == 0  # No alert
    assert len(posted) == 0  # Summary goes to stdout
    assert "alert threshold: 3" in stdout_msg, f"missing threshold label: {stdout_msg[:400]}"


def test_legacy_cumulative_alert_includes_remediation_hint(monkeypatch, tmp_streak_state):
    """Legacy cumulative-7d alert must include remediation + path."""
    watcher = _load_watcher(monkeypatch, BQ_WATCH_USE_RECENT_RATE="false")

    bq_responses = iter([
        _streaming_rows(),
        _nonstream_rows(),
        _row("8800", "4859"),  # cumulative NULL
        _row("10000", "1200"),  # 12% populated
        {"rows": [
            {"f": [{"v": "2026-07-12"}, {"v": "1000"}]},
            {"f": [{"v": "2026-07-11"}, {"v": "500"}]},
            {"f": [{"v": "2026-07-10"}, {"v": "200"}]},
        ]},
        _latest_rows(),
    ])

    posted = []
    monkeypatch.setattr(watcher, "_run_query", lambda q, t, max_rows=200: next(bq_responses))
    monkeypatch.setattr(watcher, "_bq_token", lambda: "fake-token")
    monkeypatch.setattr(watcher, "_slack_post", lambda *a, **kw: posted.append(a[1]))

    rc = watcher.main()
    assert rc == 1
    msg = posted[0]
    assert "mvp_site/bq_logging.py" in msg, f"missing file path: {msg[:400]}"
    assert "Remediation:" in msg, f"missing remediation hint: {msg[:400]}"
    # Legacy mode should also suggest switching to recent-rate
    assert "BQ_WATCH_USE_RECENT_RATE=true" in msg, f"missing recent-rate opt-in hint: {msg[:400]}"
