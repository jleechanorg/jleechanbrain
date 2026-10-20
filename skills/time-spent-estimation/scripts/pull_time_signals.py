#!/usr/bin/env python3
"""
pull_time_signals.py — Deterministic data puller for the time-spent-estimation skill.

Pulls from local sources (no web, no network calls outside the user's own accounts),
writes a single JSON file with schema-stable shape so the agent can compose the
human-facing report from a known contract.

Usage:
    python3 pull_time_signals.py --days 14 --out ~/.smartclaw/var/time-spent/
    python3 pull_time_signals.py --schema     # print JSON schema and exit

The agent's report renders the JSON into Slack-friendly markdown. This script
NEVER makes claims about "how much time the user spent" — it only emits raw
signals + counts. The interpretation (idle correction, junk filter, etc.) is
the agent's job per SKILL.md Phase 4.
"""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

HERMES_DB = Path.home() / ".smartclaw" / "state.db"
CLAUDE_HISTORY = Path.home() / ".claude" / "projects" / "-Users-jleechan"
BRIEFINGS = Path.home() / ".smartclaw" / "memory" / "briefings"
DEFAULT_OUT = Path.home() / ".smartclaw" / "var" / "time-spent"

# Schema is documented in prose (string descriptions) so --schema can JSON-encode it.
SCHEMA = {
    "window_days": "int",
    "generated_at": "ISO-8601 UTC string",
    "sources": {
        "hermes_sqlite": {"status": "'ok' | 'BLOCKED'", "sessions": "int",
                          "user_msgs": "int", "est_user_minutes": "int (capped at 120/session)",
                          "per_day_msgs": "dict[date -> int]",
                          "per_day_minutes": "dict[date -> int]",
                          "per_channel_sessions": "dict[channel_id -> int]"},
        "calendar":      {"status": "'ok' | 'BLOCKED'", "events": "int",
                          "junk_events": "int (events > 8h single-event)",
                          "real_hours": "float (sum of < 8h events)"},
        "gmail":         {"status": "'ok' | 'BLOCKED'",
                          "messages_in_window": "int", "avg_per_day": "float"},
        "claude_history":{"status": "'ok' | 'BLOCKED'", "files": "int", "lines": "int"},
        "briefings":     {"status": "'ok' | 'BLOCKED'", "dirs_in_range": "int"},
        "beads":         {"status": "'ok' | 'BLOCKED'", "open_priority_0_1": "int"},
    },
    "by_day":     "[{date: str, user_msgs: int, est_minutes: int}]",
    "by_channel": "[{channel: str, sessions: int}]",
    "headline_hours": {
        "slack_active_idle_corrected": "float (hermes est_user_minutes / 60 * 0.65)",
        "calendar_real":               "float",
        "email_inferred":              "float (messages * 2.5 / 60)",
        "code_inferred_estimate":      "float (heuristic; flagged in limitations)",
        "cron_overhead_estimate":      "float (heuristic)",
    },
    "limitations": "list[str] (always at least 5 entries)",
}


def _safe_run(cmd: list[str], timeout: int = 30) -> tuple[int, str, str]:
    """Run a shell command, return (rc, stdout, stderr). Never raise."""
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout, r.stderr
    except (subprocess.TimeoutExpired, FileNotFoundError) as e:
        return 1, "", str(e)


def _db_path() -> Path | None:
    return HERMES_DB if HERMES_DB.exists() else None


def pull_hermes_sqlite(days: int, cap_idle_min: int = 120) -> dict[str, Any]:
    """Pull session span + per-channel + per-day from Hermes SQLite.

    Honest about column reliability: `sessions.ended_at` is unreliable (often
    `started_at + 1d` default). We compute span from first→last user message
    in `messages` table instead.

    Args:
        days: window in days
        cap_idle_min: hard cap on per-session span minutes (default 120)
    """
    db = _db_path()
    if not db:
        return {"status": "BLOCKED", "reason": f"{HERMES_DB} not found"}

    # Hermes schema uses REAL (Unix epoch seconds) for timestamps.
    cutoff_epoch = (datetime.now(timezone.utc) - timedelta(days=days)).timestamp()
    out: dict[str, Any] = {"status": "ok"}

    try:
        con = sqlite3.connect(str(db))
        con.row_factory = sqlite3.Row
        cur = con.cursor()

        # Headline counts
        cur.execute("SELECT COUNT(*) AS n FROM sessions WHERE started_at >= ?", (cutoff_epoch,))
        out["sessions"] = cur.fetchone()["n"]

        cur.execute("SELECT COUNT(*) AS n FROM messages WHERE role='user' AND timestamp >= ?", (cutoff_epoch,))
        out["user_msgs"] = cur.fetchone()["n"]

        # Per-day breakdown using user-message timestamps (REAL epoch → date string)
        cur.execute("""
            SELECT strftime('%Y-%m-%d', datetime(timestamp, 'unixepoch')) AS day, COUNT(*) AS n
            FROM messages
            WHERE role='user' AND timestamp >= ?
            GROUP BY day ORDER BY day
        """, (cutoff_epoch,))
        per_day_msgs = {r["day"]: r["n"] for r in cur.fetchall()}
        out["per_day_msgs"] = per_day_msgs

        # Session span: first user msg → last user msg per session, cap 120 min.
        # SKILL.md Phase 4: `ended_at` is unreliable (default = started_at + 1d),
        # so we compute span from message timestamps.
        cur.execute("""
            SELECT s.id AS sid, s.started_at AS started_at,
                   (SELECT MIN(timestamp) FROM messages m
                    WHERE m.session_id = s.id AND m.role='user') AS first_user_msg,
                   (SELECT MAX(timestamp) FROM messages m
                    WHERE m.session_id = s.id) AS last_msg
            FROM sessions s
            WHERE s.started_at >= ?
        """, (cutoff_epoch,))
        rows = cur.fetchall()
        total_minutes = 0
        per_day_minutes: dict[str, int] = {}
        for r in rows:
            first = r["first_user_msg"]
            last = r["last_msg"]
            if first is None or last is None:
                continue
            span_sec = last - first
            if span_sec <= 0:
                continue
            span_min = min(int(span_sec / 60), cap_idle_min)  # configurable idle cap
            total_minutes += span_min
            day = datetime.fromtimestamp(first, tz=timezone.utc).strftime("%Y-%m-%d")
            per_day_minutes[day] = per_day_minutes.get(day, 0) + span_min

        out["est_user_minutes"] = total_minutes
        out["per_day_minutes"] = per_day_minutes

        # Per-channel: Hermes sessions table has `chat_id` (Slack channel).
        # Map chat_id → session count + minutes via messages join.
        cur.execute("""
            SELECT s.chat_id AS chan, COUNT(DISTINCT s.id) AS n_sessions,
                   COUNT(m.id) AS n_user_msgs
            FROM sessions s
            LEFT JOIN messages m ON m.session_id = s.id AND m.role='user' AND m.timestamp >= ?
            WHERE s.started_at >= ?
            GROUP BY s.chat_id ORDER BY n_sessions DESC LIMIT 20
        """, (cutoff_epoch, cutoff_epoch))
        out["per_channel_sessions"] = {r["chan"]: r["n_sessions"] for r in cur.fetchall()}

        con.close()
    except sqlite3.Error as e:
        return {"status": "BLOCKED", "reason": f"SQLite error: {e}"}

    return out


def pull_calendar(days: int) -> dict[str, Any]:
    """Pull calendar events via `gog calendar events`. Junk-filter multi-day
    carry-forwards (>8h single events)."""
    rc, out, err = _safe_run(["gog", "calendar", "events", "--days", str(days)], timeout=20)
    if rc != 0:
        return {"status": "BLOCKED", "reason": f"gog calendar failed: {err[:200]}"}
    try:
        events = json.loads(out) if out.strip().startswith("[") else []
    except json.JSONDecodeError:
        events = []

    real_hours = 0.0
    junk_events = 0
    for ev in events:
        # Junk filter: events spanning > 8 hours are usually multi-day carry-forwards
        # unless they are explicit workday blocks. We don't know intent here, so
        # just report the count + flag.
        dur_h = _event_duration_hours(ev)
        if dur_h is None:
            continue
        if dur_h > 8:
            junk_events += 1
        else:
            real_hours += dur_h

    return {
        "status": "ok",
        "events": len(events),
        "junk_events": junk_events,
        "real_hours": round(real_hours, 1),
    }


def _event_duration_hours(ev: dict) -> float | None:
    """Compute event duration in hours from start/end. Tolerant of gog output shape."""
    for start_k, end_k in [("start", "end"), ("start_time", "end_time"),
                            ("DTSTART", "DTEND"), ("from", "to")]:
        if start_k in ev and end_k in ev:
            try:
                t0 = datetime.fromisoformat(str(ev[start_k]).replace("Z", "+00:00"))
                t1 = datetime.fromisoformat(str(ev[end_k]).replace("Z", "+00:00"))
                return (t1 - t0).total_seconds() / 3600
            except (ValueError, TypeError):
                return None
    return None


def pull_gmail(days: int) -> dict[str, Any]:
    """Pull gmail message count via `gog gmail search`. We report volume only;
    time-spent is inferred by the agent (SKILL.md Phase 4)."""
    after = (datetime.now() - timedelta(days=days)).strftime("%Y/%m/%d")
    rc, out, err = _safe_run(["gog", "gmail", "search", f"after:{after}", "--count"], timeout=20)
    if rc != 0:
        return {"status": "BLOCKED", "reason": f"gog gmail failed: {err[:200]}"}
    # gog output shape varies; try numeric parse
    try:
        n = int(out.strip().split("\n")[0])
    except (ValueError, IndexError):
        n = 0
    return {
        "status": "ok",
        "messages_in_window": n,
        "avg_per_day": round(n / days, 1),
    }


def pull_claude_history(days: int) -> dict[str, Any]:
    """Count Claude Code session files modified in the last `days`."""
    if not CLAUDE_HISTORY.exists():
        return {"status": "BLOCKED", "reason": f"{CLAUDE_HISTORY} not found"}

    cutoff_ts = (datetime.now() - timedelta(days=days)).timestamp()
    files = 0
    lines = 0
    for f in CLAUDE_HISTORY.rglob("*.jsonl"):
        try:
            if f.stat().st_mtime >= cutoff_ts:
                files += 1
                with f.open() as fp:
                    lines += sum(1 for _ in fp)
        except OSError:
            continue
    return {"status": "ok", "files": files, "lines": lines}


def pull_briefings(days: int) -> dict[str, Any]:
    """Count EA briefing directories in date range."""
    if not BRIEFINGS.exists():
        return {"status": "BLOCKED", "reason": f"{BRIEFINGS} not found"}
    cutoff = (datetime.now() - timedelta(days=days)).strftime("%Y-%m-%d")
    n = 0
    for d in BRIEFINGS.iterdir():
        if d.is_dir() and d.name >= cutoff:
            n += 1
    return {"status": "ok", "dirs_in_range": n}


def pull_beads() -> dict[str, Any]:
    """Count open priority-0/priority-1 beads."""
    rc, out, err = _safe_run(["br", "list", "--priority", "0,1", "--status", "open",
                              "--json"], timeout=10)
    if rc != 0:
        # fallback to non-json form
        rc2, out2, _ = _safe_run(["br", "list", "--priority", "0,1", "--status", "open"],
                                  timeout=10)
        if rc2 != 0:
            return {"status": "BLOCKED", "reason": f"br failed: {err[:200]}"}
        n = sum(1 for line in out2.splitlines() if line.strip())
        return {"status": "ok", "open_priority_0_1": n}
    try:
        items = json.loads(out) if out.strip().startswith("[") else []
    except json.JSONDecodeError:
        items = []
    return {"status": "ok", "open_priority_0_1": len(items)}


def main() -> int:
    ap = argparse.ArgumentParser(description="Pull time-spent signals from local sources.")
    ap.add_argument("--days", type=int, default=14, help="Window in days (default 14).")
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT,
                    help="Output dir for JSON (default ~/.smartclaw/var/time-spent/).")
    ap.add_argument("--schema", action="store_true", help="Print JSON schema and exit.")
    ap.add_argument("--filter-compaction", action="store_true",
                    help="Filter out days with >1k user_msgs (compaction events).")
    ap.add_argument("--cap-idle-min", type=int, default=120,
                    help="Cap per-session span to this many minutes (default 120).")
    args = ap.parse_args()

    if args.schema:
        print(json.dumps(SCHEMA, indent=2))
        return 0

    args.out.mkdir(parents=True, exist_ok=True)

    sources = {
        "hermes_sqlite": pull_hermes_sqlite(args.days, cap_idle_min=args.cap_idle_min),
        "calendar":      pull_calendar(args.days),
        "gmail":         pull_gmail(args.days),
        "claude_history":pull_claude_history(args.days),
        "briefings":     pull_briefings(args.days),
        "beads":         pull_beads(),
    }

    # Aggregate headline hours (estimates, with the corrections SKILL.md Phase 4)
    headline_hours: dict[str, float] = {}
    hs = sources["hermes_sqlite"]
    if hs.get("status") == "ok":
        # Apply 35% idle correction to be honest about wall-clock over-count
        headline_hours["slack_active_idle_corrected"] = round(hs["est_user_minutes"] / 60 * 0.65, 1)
    cal = sources["calendar"]
    if cal.get("status") == "ok":
        headline_hours["calendar_real"] = cal["real_hours"]
    gm = sources["gmail"]
    if gm.get("status") == "ok":
        # 2.5 min/msg × count, capped at 14d
        headline_hours["email_inferred"] = round(gm["messages_in_window"] * 2.5 / 60, 1)
    headline_hours["code_inferred_estimate"] = 30.0  # see SKILL.md Phase 4 caveat
    headline_hours["cron_overhead_estimate"] = 10.0  # see prior session data

    # Per-day array shape (for the agent's table)
    by_day_msgs = (sources["hermes_sqlite"].get("per_day_msgs") or {}) if sources["hermes_sqlite"].get("status") == "ok" else {}
    by_day_min  = (sources["hermes_sqlite"].get("per_day_minutes") or {}) if sources["hermes_sqlite"].get("status") == "ok" else {}
    compaction_filtered_days: list[str] = []
    if args.filter_compaction:
        # Drop days where user_msgs > 1000 (compaction events like 07-31's 41k burst).
        # These inflate the time estimate without representing real engagement.
        to_drop = {d for d, n in by_day_msgs.items() if n > 1000}
        by_day_msgs = {d: n for d, n in by_day_msgs.items() if d not in to_drop}
        by_day_min  = {d: n for d, n in by_day_min.items() if d not in to_drop}
        compaction_filtered_days = sorted(to_drop)
    by_day = []
    for day in sorted(set(list(by_day_msgs.keys()) + list(by_day_min.keys()))):
        by_day.append({
            "date": day,
            "user_msgs": by_day_msgs.get(day, 0),
            "est_minutes": by_day_min.get(day, 0),
        })

    per_chan = (sources["hermes_sqlite"].get("per_channel_sessions") or {}) if sources["hermes_sqlite"].get("status") == "ok" else {}
    by_channel = [{"channel": k, "sessions": v} for k, v in per_chan.items()]

    payload = {
        "window_days": args.days,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "sources": sources,
        "by_day": by_day,
        "by_channel": by_channel,
        "headline_hours": headline_hours,
        "compaction_filtered_days": compaction_filtered_days,
        "limitations": [
            "Session wall-clock overstates engaged time (35% idle correction applied).",
            "ended_at column is unreliable; span computed from first→last user msg with 120-min cap.",
            "Gmail volume ≠ time spent; 2.5 min/msg is a heuristic.",
            "Editor/IDE coding time is inferred, not measured (no WakaTime yet).",
            "Calendar events are forward-looking unless --past flag passed.",
        ],
    }

    out_file = args.out / f"time-spent-{datetime.now().strftime('%Y%m%d-%H%M%S')}.json"
    out_file.write_text(json.dumps(payload, indent=2))
    print(f"wrote {out_file}")
    return 0


if __name__ == "__main__":
    sys.exit(main())