#!/usr/bin/env python3
"""
bq_coverage_watcher.py — Daily BQ LLM coverage check for worldarchitect.ai.

Verifies that the BQ `llm_forensics.llm_payloads` table is still receiving
raw LLM request/response payloads for Gemini, both streaming and non-streaming.

Alerts (Slack) when ANY of these drop below threshold:
  - request_json populated (any length > 10 bytes): STREAM_REQ_JSON_MIN_PCT
  - response_text populated:                       STREAM_RESP_TEXT_MIN_PCT
  - finish_reason populated:                       STREAM_FINISH_MIN_PCT
  - is_test populated (not NULL):                  IS_TEST_POPULATED_MIN_PCT
  - is_test/user_id gap trend (>= 3 consecutive days with any null rows)
  - zero Gemini rows in the last 2 days (freshness stop)

Schedule: daily (default 09:30 UTC). Slack channel: $SLACK_CHANNEL.

Auth: `google.auth.default()` ADC. Project: `worldarchitecture-ai`.
Table: `llm_forensics.llm_payloads`.

Pattern borrowed from worldarchitect.ai/scripts/daily_gemini_cost_report.py
and the bq-rest-query-pattern skill reference. Run standalone or via launchd:

  cp scripts/bq_coverage_watcher.py ~/.smartclaw/scripts/
  cp launchd/ai.smartclaw.schedule.bq-coverage-watcher.plist \
     ~/Library/LaunchAgents/
  launchctl bootstrap gui/$UID ~/Library/LaunchAgents/ai.smartclaw.schedule.bq-coverage-watcher.plist
"""
from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from typing import Any

# Drop any SA-key env var so google.auth.default() picks ADC user creds.
os.environ.pop("GOOGLE_APPLICATION_CREDENTIALS", None)

import google.auth
from google.auth.transport.requests import Request  # noqa: E402

PROJECT = "worldarchitecture-ai"
DATASET = "llm_forensics"
TABLE = "llm_payloads"
BQ_API = f"https://bigquery.googleapis.com/bigquery/v2/projects/{PROJECT}/queries"

# Thresholds (override via env). Lower is more conservative; alerts fire on <.
STREAM_REQ_JSON_MIN_PCT = float(os.environ.get("BQ_WATCH_STREAM_REQ_JSON_MIN_PCT", "99.5"))
STREAM_RESP_TEXT_MIN_PCT = float(os.environ.get("BQ_WATCH_STREAM_RESP_TEXT_MIN_PCT", "99.0"))
STREAM_FINISH_MIN_PCT = float(os.environ.get("BQ_WATCH_STREAM_FINISH_MIN_PCT", "99.5"))
NONSTREAM_REQ_JSON_MIN_PCT = float(os.environ.get("BQ_WATCH_NONSTREAM_REQ_JSON_MIN_PCT", "99.5"))
IS_TEST_POPULATED_MIN_PCT = float(os.environ.get("BQ_WATCH_IS_TEST_MIN_PCT", "95.0"))
# Alert on is_test=NULL gemini rows exceeding this absolute count.
IS_TEST_NULL_ABS_THRESHOLD = int(os.environ.get("BQ_WATCH_IS_TEST_NULL_ABS", "100"))
# Reference for "empty" request_json (request body missing entirely).
REQ_JSON_EMPTY_MAX_PCT = float(os.environ.get("BQ_WATCH_REQ_JSON_EMPTY_MAX_PCT", "0.5"))

SLACK_CHANNEL_DEFAULT = os.environ.get("SLACK_CHANNEL", "C0BCVG4F560")
INVESTIGATOR = os.environ.get("BQ_WATCH_INVESTIGATOR", "<@U09GH5BR3QU>")

WINDOW_DAYS = int(os.environ.get("BQ_WATCH_WINDOW_DAYS", "7"))

# Recent-rate alerting (added 2026-07-13, post-#8351 fix).
# Background: PR #8351 fixed the bq_logging lazy schema-migration bug in
# production. Pre-fix the watcher fired on cumulative 7d data, but post-fix
# the 7d window still contains ~8800 historical NULL rows that take 7 days to
# roll off naturally — making the alert a permanent false-positive.
#
# This module adds an "active rate" alert: it checks the last
# `RECENT_WINDOW_HOURS` (default 24) for fresh NULL rows. Backlog is reported
# as informational only, never triggers an alert.
#
# `USE_RECENT_RATE=false` restores the original cumulative-7d behavior
# (backwards-compat opt-out).
RECENT_WINDOW_HOURS = int(os.environ.get("BQ_WATCH_RECENT_WINDOW_HOURS", "24"))
USE_RECENT_RATE = os.environ.get("BQ_WATCH_USE_RECENT_RATE", "true").lower() == "true"
# Streak threshold: number of consecutive recent-window runs with >=1 NULL row
# before alerting on streak (catches slow-leak replicas).
RECENT_STREAK_THRESHOLD = int(os.environ.get("BQ_WATCH_RECENT_STREAK_THRESHOLD", "3"))
# State file for streak tracking across cron runs.
STREAK_STATE_PATH = os.environ.get(
    "BQ_WATCH_STREAK_STATE_PATH",
    os.path.expanduser("~/.smartclaw/var/bq_coverage_streak.json"),
)
# Active-rate threshold: absolute count of NULL rows in the recent window
# that triggers an alert (overrides any higher cumulative count).
ACTIVE_NULL_ABS_THRESHOLD = int(os.environ.get("BQ_WATCH_ACTIVE_NULL_ABS", "10"))

# Streaming classifier for the llm_payloads schema. Matches the convention used
# by the daily gemini cost report and the bq-rest-query-pattern skill.
STREAM_CLAUSE = """(event_type LIKE '%stream%' OR event_type IN
    ('streaming','gameplay_streaming','story_stream',
     'stream_story_with_game_state','continue_story_streaming',
     'initial_story_streaming'))"""


def _run_query(query: str, token: str, max_rows: int = 200) -> dict[str, Any]:
    body = {"query": query, "useLegacySql": False, "maxResults": max_rows}
    req = urllib.request.Request(
        BQ_API,
        data=json.dumps(body).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.loads(resp.read().decode("utf-8"))

def _rows_as_lists(data: dict[str, Any]) -> list[list[str]]:
    return [[cell.get("v", "") for cell in row.get("f", [])] for row in data.get("rows", [])]


def _bq_token() -> str:
    creds, _ = google.auth.default()
    if not creds.valid:
        creds.refresh(Request())
    return creds.token


# Streaming classifier for the llm_payloads schema. Matches the production
# event_type values observed in the 7d sample (gameplay_streaming,
# stream_story_with_game_state) — verify before changing.
STREAM_EVENT_TYPES = (
    "gameplay_streaming",
    "stream_story_with_game_state",
    "stream_narrative_simple",
    "continue_story_streaming",
    "initial_story_streaming",
)
STREAM_EVENT_TYPE_IN = ", ".join(f"'{e}'" for e in STREAM_EVENT_TYPES)


def _coverage_query(streaming_clause: str, *, is_stream: bool) -> str:
    if is_stream:
        where_clause = streaming_clause
    else:
        where_clause = f"NOT ({streaming_clause}) AND event_type NOT IN ('agy_request')"
    resp_filter = "finish_reason NOT LIKE 'error%' AND finish_reason NOT IN ('SAFETY', 'FinishReason.TOO_MANY_TOOL_CALLS', 'cancelled')"
    return f"""
SELECT
  COUNT(*) AS n_total,
  COUNTIF(LENGTH(request_json) > 10) AS n_req_json_ok,
  COUNTIF({resp_filter}) AS n_completed,
  COUNTIF(({resp_filter}) AND LENGTH(response_text) > 0) AS n_resp_text_ok,
  COUNTIF(finish_reason IS NOT NULL AND finish_reason != '') AS n_finish_ok,
  COUNTIF(LENGTH(request_json) = 0) AS n_req_json_empty
FROM `{PROJECT}.{DATASET}.{TABLE}`
WHERE ingested_at > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL {WINDOW_DAYS} DAY)
  AND model LIKE '%gemini%'
  AND {where_clause}
"""


# Concrete clause used by both streaming and non-streaming queries.
STREAM_CLAUSE = f"event_type IN ({STREAM_EVENT_TYPE_IN})"


def _is_test_null_query() -> str:
    return f"""
SELECT
  COUNT(*) AS n_is_test_null,
  COUNTIF(LENGTH(request_json) > 1000) AS n_is_test_null_with_req_body
FROM `{PROJECT}.{DATASET}.{TABLE}`
WHERE ingested_at > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL {WINDOW_DAYS} DAY)
  AND model LIKE '%gemini%'
  AND is_test IS NULL
"""


def _recent_is_test_null_query() -> str:
    """Count is_test=NULL rows in the RECENT_WINDOW_HOURS window.

    This is the "active drift" metric that catches ongoing lazy schema-migration
    failures on freshly cold-started Cloud Run replicas. Independent of the
    cumulative 7d backlog.
    """
    return f"""
SELECT COUNT(*) AS n_active_null,
       COUNTIF(LENGTH(request_json) > 1000) AS n_active_null_with_req_body
FROM `{PROJECT}.{DATASET}.{TABLE}`
WHERE ingested_at > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL {RECENT_WINDOW_HOURS} HOUR)
  AND model LIKE '%gemini%'
  AND is_test IS NULL
"""


def _load_streak_state() -> dict[str, int]:
    """Load streak counter state from disk; returns {consecutive_nonzero: 0} if absent."""
    try:
        with open(STREAK_STATE_PATH, encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, dict) and "consecutive_nonzero" in data:
            return {"consecutive_nonzero": int(data["consecutive_nonzero"])}
    except (FileNotFoundError, json.JSONDecodeError, ValueError):
        pass
    return {"consecutive_nonzero": 0}


def _save_streak_state(consecutive_nonzero: int) -> None:
    """Persist streak counter state for the next cron run."""
    try:
        os.makedirs(os.path.dirname(STREAK_STATE_PATH), exist_ok=True)
        with open(STREAK_STATE_PATH, "w", encoding="utf-8") as f:
            json.dump({"consecutive_nonzero": consecutive_nonzero}, f)
    except OSError as exc:
        print(f"[bq-watch] could not persist streak state: {exc}", file=sys.stderr)


def _latest_ts_query() -> str:
    return f"""
SELECT FORMAT_TIMESTAMP('%Y-%m-%d %H:%M:%S UTC', MAX(ingested_at)) AS latest_ts,
       COUNT(*) AS n_recent
FROM `{PROJECT}.{DATASET}.{TABLE}`
WHERE ingested_at > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 2 DAY)
  AND model LIKE '%gemini%'
"""


def _per_day_is_test_null_query() -> str:
    # Dense: emit one row per UTC day in the last 30d with the null count
    # (zero when no rows matched), so the consecutive-day streak counter
    # doesn't treat non-contiguous days as contiguous (codex P2 finding:
    # intermittent blips on M/W/F falsely reported as "3 consecutive days").
    return f"""
WITH date_range AS (
  SELECT d FROM UNNEST(
    GENERATE_DATE_ARRAY(
      DATE_SUB(CURRENT_DATE(), INTERVAL 29 DAY),
      CURRENT_DATE()
    )
  ) AS d
)
SELECT CAST(dr.d AS STRING) AS d,
       COALESCE(t.n, 0) AS n
FROM date_range dr
LEFT JOIN (
  SELECT DATE(ingested_at) AS d, COUNT(*) AS n
  FROM `{PROJECT}.{DATASET}.{TABLE}`
  WHERE ingested_at > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY)
    AND model LIKE '%gemini%'
    AND is_test IS NULL
  GROUP BY d
) t USING (d)
ORDER BY dr.d
"""


def _total_gemini_in_window_query() -> str:
    # Denominator for is_test coverage percentage (codex P2: low-volume windows
    # with n_null < IS_TEST_NULL_ABS_THRESHOLD still need a pct check).
    return f"""
SELECT COUNT(*) AS n_total,
       COUNTIF(is_test IS NOT NULL) AS n_is_test_populated
FROM `{PROJECT}.{DATASET}.{TABLE}`
WHERE ingested_at > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL {WINDOW_DAYS} DAY)
  AND model LIKE '%gemini%'
"""


def _pct(num: float, denom: float) -> float:
    if denom == 0:
        return 0.0
    return 100.0 * num / denom


def _slack_post(channel: str, text: str) -> None:
    token = os.environ.get("SLACK_BOT_TOKEN", "").strip()
    if not token:
        print(f"[bq-watch] SLACK_BOT_TOKEN not set; would post to {channel}:")
        print(text)
        return
    body = {"channel": channel, "text": text}
    req = urllib.request.Request(
        "https://slack.com/api/chat.postMessage",
        data=json.dumps(body).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json; charset=utf-8",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            if not data.get("ok"):
                print(f"[bq-watch] Slack post failed: {data}", file=sys.stderr)
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError) as exc:
        print(f"[bq-watch] Slack post error: {exc}", file=sys.stderr)


def main() -> int:
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    try:
        token = _bq_token()
    except Exception as exc:
        _slack_post(
            SLACK_CHANNEL_DEFAULT,
            f":rotating_light: bq-coverage-watcher failed to auth: `{exc}` "
            f"{INVESTIGATOR} (run at {now})",
        )
        return 2

    alerts: list[str] = []
    mode_tag = "recent-rate" if USE_RECENT_RATE else "cumulative-7d"
    summary_lines: list[str] = [
        f"*BQ coverage watcher* — {now} (mode: {mode_tag}; cumulative window: {WINDOW_DAYS}d)"
    ]

    try:
        # Streaming coverage
        rows = _rows_as_lists(_run_query(_coverage_query(STREAM_CLAUSE, is_stream=True), token))
        if not rows:
            alerts.append("streaming coverage query returned no rows")
        else:
            cells = rows[0]
            if len(cells) >= 6:
                n_total = int(cells[0])
                n_req_ok = int(cells[1])
                n_completed = int(cells[2])
                n_resp_ok = int(cells[3])
                n_finish_ok = int(cells[4])
                n_req_empty = int(cells[5])
                pct_resp = _pct(n_resp_ok, n_completed) if n_completed > 0 else 100.0
            else:
                n_total = int(cells[0])
                n_req_ok = int(cells[1])
                n_resp_ok = int(cells[2])
                n_finish_ok = int(cells[3])
                n_req_empty = int(cells[4])
                pct_resp = _pct(n_resp_ok, n_total)
            pct_req = _pct(n_req_ok, n_total)
            pct_finish = _pct(n_finish_ok, n_total)
            pct_empty = _pct(n_req_empty, n_total)
            summary_lines.append(
                f"• Streaming (Gemini, {n_total} rows): "
                f"req_json {pct_req:.2f}% · resp_text {pct_resp:.2f}% · "
                f"finish_reason {pct_finish:.2f}% · empty req_json {pct_empty:.2f}%"
            )
            if pct_req < STREAM_REQ_JSON_MIN_PCT:
                alerts.append(
                    f"streaming `request_json` populated = {pct_req:.2f}% "
                    f"(< {STREAM_REQ_JSON_MIN_PCT}%) — {n_total - n_req_ok} rows missing request body"
                )
            if pct_resp < STREAM_RESP_TEXT_MIN_PCT:
                alerts.append(
                    f"streaming `response_text` populated = {pct_resp:.2f}% "
                    f"(< {STREAM_RESP_TEXT_MIN_PCT}%)"
                )
            if pct_finish < STREAM_FINISH_MIN_PCT:
                alerts.append(
                    f"streaming `finish_reason` populated = {pct_finish:.2f}% "
                    f"(< {STREAM_FINISH_MIN_PCT}%)"
                )
            if pct_empty > REQ_JSON_EMPTY_MAX_PCT:
                alerts.append(
                    f"streaming `request_json` is empty (0 bytes) on "
                    f"{pct_empty:.2f}% of rows (> {REQ_JSON_EMPTY_MAX_PCT}%) — "
                    f"{n_req_empty} rows dropped"
                )

        # Non-streaming coverage
        rows = _rows_as_lists(_run_query(_coverage_query(STREAM_CLAUSE, is_stream=False), token))
        if not rows:
            alerts.append("non-streaming coverage query returned no rows")
        else:
            cells = rows[0]
            if len(cells) >= 6:
                n_total = int(cells[0])
                n_req_ok = int(cells[1])
                n_completed = int(cells[2])
                n_resp_ok = int(cells[3])
                n_finish_ok = int(cells[4])
                n_req_empty = int(cells[5])
                pct_resp = _pct(n_resp_ok, n_completed) if n_completed > 0 else 100.0
            else:
                n_total = int(cells[0])
                n_req_ok = int(cells[1])
                n_resp_ok = int(cells[2])
                n_finish_ok = int(cells[3])
                n_req_empty = int(cells[4])
                pct_resp = _pct(n_resp_ok, n_total)
            pct_req = _pct(n_req_ok, n_total)
            pct_finish = _pct(n_finish_ok, n_total)
            pct_empty = _pct(n_req_empty, n_total)
            summary_lines.append(
                f"• Non-streaming (Gemini, {n_total} rows): "
                f"req_json {pct_req:.2f}% · resp_text {pct_resp:.2f}% · "
                f"finish_reason {pct_finish:.2f}% · empty req_json {pct_empty:.2f}%"
            )
            if pct_req < NONSTREAM_REQ_JSON_MIN_PCT:
                alerts.append(
                    f"non-streaming `request_json` populated = {pct_req:.2f}% "
                    f"(< {NONSTREAM_REQ_JSON_MIN_PCT}%)"
                )

        # is_test=NULL gap (the lazy schema-migration bug)
        if USE_RECENT_RATE:
            # Recent-rate mode: alert on ACTIVE drift only.
            # Cumulative backlog is informational; never trips an alert by itself.
            rows = _rows_as_lists(_run_query(_recent_is_test_null_query(), token))
            if rows:
                n_active_null = int(rows[0][0])
                n_active_with_req = int(rows[0][1])
                summary_lines.append(
                    f"\u2022 Active `is_test IS NULL` (Gemini, last {RECENT_WINDOW_HOURS}h): "
                    f"{n_active_null} rows ({n_active_with_req} have request_json)"
                )
                # Update streak counter across cron runs.
                state = _load_streak_state()
                streak = state["consecutive_nonzero"]
                if n_active_null > 0:
                    streak += 1
                else:
                    streak = 0
                _save_streak_state(streak)
                # Label the streak counter as a trip condition so the operator
                # can see at-a-glance whether the threshold has been hit.
                streak_label = (
                    " (TRIPS alert \u2265 "
                    f"{RECENT_STREAK_THRESHOLD})"
                    if streak >= RECENT_STREAK_THRESHOLD
                    else f" (alert threshold: {RECENT_STREAK_THRESHOLD})"
                )
                summary_lines.append(
                    f"\u2022 Streak: {streak} consecutive run(s) with >=1 active NULL row"
                    f"{streak_label}"
                )
                if n_active_null >= ACTIVE_NULL_ABS_THRESHOLD:
                    alerts.append(
                        f"`is_test IS NULL` on {n_active_null} Gemini rows in last "
                        f"{RECENT_WINDOW_HOURS}h (\u2265 {ACTIVE_NULL_ABS_THRESHOLD}). "
                        f"Likely lazy schema-migration failure on a Cloud Run replica \u2014 "
                        f"see `bq_logging._payloads_schema_migrated` flag in "
                        f"`mvp_site/bq_logging.py` (per-replica lazy migration). "
                        f"Remediation: redeploy to force cold-start + migration on "
                        f"all replicas; or run `scripts/backfill_bq_is_test_null.py` "
                        f"to backfill the historical NULL rows."
                    )
                if streak >= RECENT_STREAK_THRESHOLD:
                    alerts.append(
                        f"`is_test IS NULL` rows have been flowing for "
                        f"{streak} consecutive run(s) across recent windows \u2014 "
                        f"migration may be stuck on a replica (not a transient blip). "
                        f"Check `_payloads_schema_migrated` and consider redeploy."
                    )
            # Cumulative backlog (informational only)
            rows = _rows_as_lists(_run_query(_is_test_null_query(), token))
            if rows:
                n_null = int(rows[0][0])
                n_null_with_req = int(rows[0][1])
                summary_lines.append(
                    f"\u2022 Backlog `is_test IS NULL` (Gemini, {WINDOW_DAYS}d): "
                    f"{n_null} rows ({n_null_with_req} have request_json) \u2014 "
                    f"informational; alert fires on active rate only. Backfill via "
                    f"`scripts/backfill_bq_is_test_null.py`."
                )
        else:
            # Legacy cumulative-7d mode (USE_RECENT_RATE=false).
            # NOTE: This mode is retained for opt-in legacy alerting; new
            # deployments should leave USE_RECENT_RATE=true (default).
            rows = _rows_as_lists(_run_query(_is_test_null_query(), token))
            if rows:
                n_null = int(rows[0][0])
                n_null_with_req = int(rows[0][1])
                summary_lines.append(
                    f"\u2022 `is_test IS NULL` (Gemini, {WINDOW_DAYS}d): "
                    f"{n_null} rows ({n_null_with_req} have request_json)"
                )
                if n_null >= IS_TEST_NULL_ABS_THRESHOLD:
                    alerts.append(
                        f"`is_test IS NULL` on {n_null} Gemini rows over {WINDOW_DAYS}d "
                        f"(\u2265 {IS_TEST_NULL_ABS_THRESHOLD}). "
                        "Likely lazy schema-migration failure on a Cloud Run replica \u2014 "
                        "see `bq_logging._payloads_schema_migrated` flag in "
                        "`mvp_site/bq_logging.py` (per-replica lazy migration). "
                        "Remediation: redeploy to force cold-start + migration on "
                        "all replicas; or run `scripts/backfill_bq_is_test_null.py` "
                        "to backfill the historical NULL rows. (Or set "
                        "BQ_WATCH_USE_RECENT_RATE=true to switch to active-rate "
                        "alerting and suppress this cumulative false-positive.)"
                    )

        # is_test coverage percentage (informational only in recent-rate mode).
        rows = _rows_as_lists(_run_query(_total_gemini_in_window_query(), token))
        if rows:
            n_total = int(rows[0][0])
            n_is_test_populated = int(rows[0][1])
            pct_populated = _pct(n_is_test_populated, n_total)
            summary_lines.append(
                f"\u2022 `is_test` populated (Gemini, {WINDOW_DAYS}d): "
                f"{pct_populated:.2f}% ({n_is_test_populated}/{n_total})"
            )
            if not USE_RECENT_RATE:
                if n_total > 0 and pct_populated < IS_TEST_POPULATED_MIN_PCT:
                    alerts.append(
                        f"`is_test` populated = {pct_populated:.2f}% "
                        f"(< {IS_TEST_POPULATED_MIN_PCT}%) on {n_total} Gemini rows "
                        f"over {WINDOW_DAYS}d"
                    )

        if not USE_RECENT_RATE:
            # Legacy per-day consecutive-day streak check (superseded by recent-window streak).
            rows = _rows_as_lists(_run_query(_per_day_is_test_null_query(), token))
            consecutive_nonzero = 0
            consecutive_max = 0
            for d, n in rows:
                if int(n) > 0:
                    consecutive_nonzero += 1
                    consecutive_max = max(consecutive_max, consecutive_nonzero)
                else:
                    consecutive_nonzero = 0
            if consecutive_max >= 3:
                alerts.append(
                    f"`is_test IS NULL` rows have been flowing for "
                    f"{consecutive_max} consecutive day(s) \u2014 migration may be "
                    "stuck on a replica (not a transient blip)."
                )

        # Latest timestamp freshness (codex P2: alert when no recent rows at all)
        rows = _rows_as_lists(_run_query(_latest_ts_query(), token))
        if rows:
            latest_ts = rows[0][0]
            n_recent = int(rows[0][1]) if len(rows[0]) > 1 else 0
            summary_lines.append(f"• Latest Gemini row: {latest_ts} ({n_recent} in 2d)")
            if n_recent == 0:
                alerts.append(
                    "No Gemini `llm_payloads` rows in the last 2 days — "
                    "ingestion may have stopped; coverage %s above may be stale"
                )
    except Exception as exc:
        _slack_post(
            SLACK_CHANNEL_DEFAULT,
            f":rotating_light: bq-coverage-watcher query failed: `{exc}` "
            f"{INVESTIGATOR} (run at {now})",
        )
        return 3

    if alerts:
        msg = ":warning: " + " · ".join(alerts) + "\n\n" + "\n".join(summary_lines)
        msg = f"{INVESTIGATOR} {msg}"
        _slack_post(SLACK_CHANNEL_DEFAULT, msg)
        print(msg, file=sys.stderr)
        return 1

    msg = ":white_check_mark: " + " · ".join(summary_lines)
    print(msg)
    return 0


if __name__ == "__main__":
    sys.exit(main())