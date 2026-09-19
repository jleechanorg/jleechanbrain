#!/usr/bin/env python3
"""
slack-history-sweep — starter template

Fetches Slack history from N channels in parallel batches of ≤ 6, classifies
each thread into 5 buckets, and writes /tmp/slack-<window>-sweep.json.

This is a TEMPLATE — copy it, modify the channel list + window + classification
keyword lists for your task. The actual MCP Slack calls must be issued from the
agent runtime (see SKILL.md); this script is the post-fetch processing layer.

Usage (after the MCP fetches are saved as CSV files at /tmp/hermes-results/):
    python3 sweep.py \
        --channels ${SLACK_CHANNEL_ID} C0AH3RY3DK6 C0AJ3SD5C79 C0AJQ5M0A0Y \
        --channel-names all-jleechan-ai worldai jleechanbrain ai-general \
        --window-start 2026-08-05T03:13 \
        --window-end 2026-08-19T03:13 \
        --output /tmp/slack-14d-sweep.json

If you have the full inline CSVs (from MCP Slack tool result wrapping),
pass --csv-file for each channel:
    python3 sweep.py --csv-file /tmp/c1.csv:all-jleechan-ai --csv-file /tmp/c2.csv:worldai ...

If you only have inline previews (1500-char truncation, no persisted file),
edit the parse_preview_only_messages() function inline; the rest of the
pipeline works the same.
"""

import argparse
import csv
import io
import json
import os
import re
import sys
from collections import Counter, defaultdict
from datetime import datetime, timezone


# ----- 5-bucket classification -----

JL_USER = "U09GH5BR3QU"  # jleechan; adjust for your operator
BOT_IDS = {"U0AEZC7RX1Q", "U0A4G7LDJ4R"}  # hermes, mcp_agent_mail

# Bot/nonce keywords — drop these before classification
NONCE_KW = [
    "test ping", "FRESH-START", "verify ", "inbound test",
    "outbound test", "incoming-webhook", "real-hermes-", "bypass-r",
    "mcp-final-", "xoxb-", "self-correction", "ack-test-", "fresh check",
]

# Cron/auto keywords — drop these before classification
CRON_KW = [
    "cronjob response", "cron backup", "ao progress report",
    "executive assistant sweep", "dropped-thread escalations",
    "cron armed", "session automatically reset",
    "no home channel is set", "ai terminal:", "heartbeat_ok",
    "spiral_calendar_pad:", "monitor merged",
]

# Meta-directive keywords — these are user-as-Hermes-director, not bug/feature
META_KW = [
    "run /roadmap", "pick top 10", "use /history /ms",
    "use /history /ms /wiki-search", "read this skill should we install",
    "make a plan", "look at all the campaigns",
    "evaluate my", "compare to upstream", "look at the bashrc",
]

BUG_KW = [
    "run /repro", "/repro ", "run /repro the", "/repro this",
    "/repro why", "/repro scene", "/repro investigate",
    "/rg fix", "/af on this", "/ready", "/green", "/er",
    "fix ci", "fix this", "fix the", "fix pr", "fix comments",
    "fix this report", "fix the css", "fix issue",
    "why missing", "why did auto level up fail", "why did the level",
    "why did the campaign", "why did the game", "why did it",
    "why did i", "why did we", "why are all", "why are these",
    "is this still needed", "is this fixed yet", "is this still",
    "doesn't make sense", "doesnt make sense",
    "output formatting messed", "latency seems worse",
    "feels like latency", "feels worse", "never completes",
    "never resolve", "never resolves", "calculating outcomes",
    "calculating outcomes...", "can't load", "cant load",
    "cant scroll", "scrolling lags", "css broke", "css messed up",
    "is broken", "is failing", "are failing", "failed",
    "error ", "error:", "exception", "stack trace", "traceback",
    "merge conflict", "conflict ",
    "investigate and see if", "investigate and root cause",
    "investigate and fix fullrun", "investigate this email",
    "investigate workers whats", "investigate why",
    "investigate readonly run", "investigate and dont code",
    "investigate without coding",
    "this is still wrong", "this isnt working", "this is broken",
    "this opened again",
    "i dont see ", "i cant see", "i don't see", "i can't see",
    "make sure this pr", "make sure these",
    "auto-deploy is failing", "auto deploy is still failing",
    "auto deploy seems broken", "prod deploy seems broken",
    "why is it stuck", "why is my god mode", "why does god mode",
    "is this truly needed", "is this truly fixed", "fix this email",
]

FEATURE_KW = [
    "let's make a ", "lets make a ", "make a skill", "make an mcp",
    "make a generic prompt",
    "move ", "add a ", "add an ", "add support",
    "add the ability", "add a button", "add a feature",
    "add a generic", "add a planning", "add a setting",
    "add a new", "add some ",
    "let's design", "lets design", "let's add", "lets add",
    "let's upgrade", "lets upgrade", "let's remove", "lets remove",
    "switch ", "change to ", "wanna make", "wanna add",
    "i wanna ", "i want a ", "i want to ",
    "make sure we add", "make sure we have",
    "feature request",
    "if we didnt yet", "prompt only change", "prompt only framework",
    "campaign goal", "campaign arcs", "quest", "quests",
    "subarcs", "goal criteria", "planning block option",
    "lets upgrade", "investigate model upgrades",
    "if cost is similar", "cost vs quality", "benchmark",
    "let's ensure", "lets ensure",
    "if not lets use", "use /super to code",
    "read through the 100", "look at all the campaigns",
    "lets try to make",
    "ensure companion", "ensure main",
    "make a feature", "add new", "new feature",
]

INCIDENT_KW = [
    "urgent infra", "infra finding", "sev1", "sev2",
    "outage", "host becoming unresponsive",
    "load average just spiked", "load spike is new and severe",
    "deploy failure", "deploy is failing", "deploy failed",
    "deploy broken", "deploy seems broken",
    "dev is down", "prod deploy",
    "gunicorn down", "server is down", "site is down",
]


def classify(parent, replies):
    """5-bucket classifier with pre-filters."""
    user = parent.get("UserID", "")
    txt = parent.get("Text", "").lower()
    text_full = parent.get("Text", "")

    # Pre-filter 1: bot users
    if user in BOT_IDS:
        return "E", "OTHER"

    # Pre-filter 2: nonce messages (even from jleechan)
    if any(k in txt for k in NONCE_KW):
        return "E", "OTHER"

    # Pre-filter 3: cron/auto messages
    if any(k in txt for k in CRON_KW):
        return "E", "OTHER"

    is_user = (user == JL_USER)

    # Pre-filter 4: meta-directives from user
    if is_user and any(k in txt for k in META_KW):
        return "E", "OTHER"

    if is_user:
        # INCIDENT has priority over BUG_FIX for the same phrase
        if any(k in txt for k in INCIDENT_KW):
            return "D", "INCIDENT"
        if any(k in txt for k in BUG_KW):
            return "A", "BUG_FIX"
        if any(k in txt for k in FEATURE_KW):
            return "B", "FEATURE_REQUEST"

        # Short status nudge from user — unresolved
        if len(text_full) < 100 and any(k in txt for k in [
            "status", "keep going", "continue",
            "what's the status", "whats the status",
            "still not fixed", "this progress report still",
            "status on", "investigate this",
        ]):
            return "C", "UNRESOLVED_SLACK_THREAD"

    # User thread with no replies — likely unresolved
    if is_user and len(replies) == 0:
        return "C", "UNRESOLVED_SLACK_THREAD"

    return "E", "OTHER"


def status_signal(cls, text_combined):
    """Determine finished/in_progress/pending/needs_decision."""
    text_low = text_combined.lower()
    if cls == "A":
        if any(s in text_low for s in [
            "merged", "shipped", "fixed", "/ready",
            "/green", "green gate", "ci green",
            "merged clean", "ready to merge", "/er passed",
        ]):
            return "finished"
        return "in_progress"
    if cls == "B":
        return "pending"
    if cls == "C":
        return "pending"
    if cls == "D":
        return "needs_decision"
    return "finished"


def parse_csv_file(path):
    """Parse a CSV file saved from MCP Slack (wrapped in JSON)."""
    with open(path) as f:
        raw = f.read()
    try:
        wrapped = json.loads(raw)
        inner = wrapped.get("result", "")
    except Exception:
        inner = raw
    return list(csv.DictReader(io.StringIO(inner)))


def parse_args():
    p = argparse.ArgumentParser(description="slack-history-sweep post-processor")
    p.add_argument("--csv-file", action="append", default=[],
                   help="PATH:CHANNEL_NAME pairs (repeatable)")
    p.add_argument("--channels", nargs="+", default=[],
                   help="Channel IDs in fetch order")
    p.add_argument("--channel-names", nargs="+", default=[],
                   help="Channel display names in same order")
    p.add_argument("--window-start", required=True,
                   help="ISO-8601 UTC (e.g. 2026-08-05T03:13)")
    p.add_argument("--window-end", required=True,
                   help="ISO-8601 UTC (e.g. 2026-08-19T03:13)")
    p.add_argument("--output", default="/tmp/slack-sweep.json",
                   help="Output JSON path")
    p.add_argument("--inline-previews", action="append", default=[],
                   help="Inline-preview-only channel entries as CHAN_ID:NAME:SNIPPET_TEXT")
    return p.parse_args()


def main():
    args = parse_args()

    # Build channel → CSV rows map
    channel_data = {}
    channel_names = {}
    for entry in args.csv_file:
        if ":" not in entry:
            print(f"Skipping malformed --csv-file entry: {entry}", file=sys.stderr)
            continue
        path, name = entry.split(":", 1)
        if not os.path.exists(path):
            print(f"WARN: CSV file {path} does not exist", file=sys.stderr)
            continue
        rows = parse_csv_file(path)
        # Channel ID is in every row; use the first
        chid = rows[0]["Channel"] if rows else "unknown"
        channel_data[chid] = rows
        channel_names[chid] = name

    # Handle inline-preview-only channels (manually-observed entries)
    for entry in args.inline_previews:
        parts = entry.split(":", 2)
        if len(parts) != 3:
            print(f"Skipping malformed --inline-previews entry: {entry}", file=sys.stderr)
            continue
        chid, name, snippet = parts
        # No full rows; treat as preview-only
        channel_data[chid] = []  # no rows
        channel_names[chid] = name

    # Build per-channel thread maps within window
    channel_threads = {}
    for chid, rows in channel_data.items():
        threads = defaultdict(list)
        for r in rows:
            if r["Time"] < args.window_start or r["Time"] > args.window_end:
                continue
            key = r["MsgID"] if r["ThreadTs"] == r["MsgID"] else r["ThreadTs"]
            threads[key].append(r)
        channel_threads[chid] = dict(threads)

    # Classify each thread
    classified = []
    for chid, threads in channel_threads.items():
        for tid, msgs in threads.items():
            parents = [m for m in msgs if m["MsgID"] == m["ThreadTs"]]
            if not parents:
                continue
            parent = parents[0]
            replies = [m for m in msgs if m["MsgID"] != m["ThreadTs"]]
            replies_sorted = sorted(replies, key=lambda x: x["Time"])

            cls, label = classify(parent, replies)

            # Build entity list
            text_combined = parent["Text"] + " " + " ".join(
                r["Text"] for r in replies_sorted[:5]
            )
            entities = []
            for tup in re.findall(r"(?:pull/(\d{3,5})|PR\s*(\d{3,5})|pr/(\d{3,5}))", text_combined):
                for p in tup:
                    if p and 100 <= int(p) <= 99999:
                        entities.append(f"PR#{p}")
            issues = re.findall(r"GH[-\s]?(\d{3,5})", text_combined)
            issues += re.findall(r"issue[s]?\s*#?(\d{3,5})", text_combined)
            for i in set(issues):
                if 100 <= int(i) <= 99999:
                    entities.append(f"issue#{i}")
            files = re.findall(r"([a-z_/.]+\.(?:py|ts|md|yml|yaml)):(\d{2,5})", text_combined)
            for f, ln in files[:3]:
                if "/" in f or ".py" in f or ".ts" in f or ".md" in f or ".yml" in f:
                    entities.append(f"{f}:{ln}")
            for e in ["MAX_TOKENS", "FinishReason", "AssertionError", "KeyError",
                       "HTTP 500", "HTTP 403", "HTTP 401", "OOM", "crash loop",
                       "timeout", "stale prompt", "scmFailureCount"]:
                if e.lower() in text_combined.lower():
                    entities.append(e)
            seen = set()
            entities_dedup = []
            for e in entities:
                if e not in seen:
                    seen.add(e)
                    entities_dedup.append(e)
            entities = entities_dedup[:10]

            snippet = parent["Text"][:280].replace("\n", " ").replace("\r", "")
            last_bot = ""
            last_user = ""
            for r in reversed(replies_sorted):
                if r["UserID"] == JL_USER and not last_user:
                    last_user = r["Text"][:200].replace("\n", " ")
                if r["UserID"] in BOT_IDS and not last_bot:
                    last_bot = r["Text"][:200].replace("\n", " ")

            last_reply = replies_sorted[-1] if replies_sorted else None

            classified.append({
                "channel_id": chid,
                "channel_name": channel_names.get(chid, chid),
                "thread_ts": tid,
                "title_snippet": snippet,
                "classification": label,
                "key_entities": entities,
                "last_bot_msg_summary": last_bot,
                "last_user_msg_summary": last_user,
                "status_signal": status_signal(cls, text_combined),
                "parent_time": parent["Time"],
                "reply_count": len(replies),
                "last_reply_time": last_reply["Time"] if last_reply else None,
            })

    classified.sort(key=lambda x: x["parent_time"], reverse=True)
    counts = Counter(c["classification"] for c in classified)

    output = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "window_start": args.window_start,
        "window_end": args.window_end,
        "channels_in_scope": [
            {"channel_id": chid,
             "channel_name": channel_names.get(chid, chid),
             "status": "fetched_inline_preview_only" if not channel_data.get(chid) else "fetched_full"}
            for chid in channel_data
        ],
        "summary_counts": dict(counts),
        "threads": classified,
    }

    with open(args.output, "w") as f:
        json.dump(output, f, indent=2, default=str)

    print(f"Wrote {len(classified)} threads to {args.output}")
    print(f"Counts: {dict(counts)}")


if __name__ == "__main__":
    main()
