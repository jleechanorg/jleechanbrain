#!/usr/bin/env python3
"""
agento-notifier: Minimal HTTP server that receives AO webhook events
and posts them to Slack #ai-slack-test as the hermes bot.

Run: python3 scripts/agento-notifier.py
Port: 18800
"""
from __future__ import annotations

import json
import os
import subprocess
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

os.environ.setdefault("PYTHONUNBUFFERED", "1")

SLACK_CHANNEL = os.environ.get("HERMES_SLACK_CHANNEL", "${SLACK_CHANNEL_ID}")  # #ai-slack-test
PORT = 18800
WEBHOOK_SECRET = os.environ.get("HERMES_AO_NOTIFY_TOKEN", "")
AO_BIN = os.environ.get("AO_BIN") or os.path.expanduser("~/bin/ao")
COOLDOWN_SECONDS = 60
COOLDOWN_DIR = "/tmp"


def get_cooldown_path(project_id: str) -> str:
    safe_id = project_id.replace("/", "_").replace("..", "_").replace("\\", "_")
    return f"{COOLDOWN_DIR}/ao-respawn-cooldown-{safe_id}"


def is_in_cooldown(project_id: str) -> bool:
    path = get_cooldown_path(project_id)
    if not os.path.exists(path):
        return False
    try:
        mtime = os.path.getmtime(path)
        return (time.time() - mtime) < COOLDOWN_SECONDS
    except OSError:
        return False


def set_cooldown(project_id: str) -> None:
    path = get_cooldown_path(project_id)
    try:
        with open(path, "w") as f:
            f.write(str(int(time.time())))
    except OSError as e:
        print(f"[agento-notifier] Warning: could not write cooldown file: {e}")


def ao_stop(project_id: str) -> None:
    """Stop AO session for project (non-blocking)."""
    try:
        subprocess.Popen([AO_BIN, "stop", project_id],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        print(f"[agento-notifier] Triggered ao stop for {project_id}")
    except Exception as e:
        print(f"[agento-notifier] ao stop failed for {project_id}: {e}")


def ao_spawn(project_id: str, claim_pr: str | None = None) -> None:
    """Spawn AO session for project (non-blocking)."""
    if is_in_cooldown(project_id):
        print(f"[agento-notifier] Skipping spawn for {project_id} (in cooldown)")
        return
    try:
        args = [AO_BIN, "spawn", project_id]
        if claim_pr:
            args.extend(["--claim-pr", claim_pr])
        env = os.environ.copy()
        env["AO_CONFIG_PATH"] = os.path.expanduser("~/agent-orchestrator.yaml")
        subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         cwd=os.path.expanduser("~"), env=env)
        set_cooldown(project_id)
        print(f"[agento-notifier] Triggered ao spawn for {project_id}" +
              (f" with --claim-pr {claim_pr}" if claim_pr else ""))
    except Exception as e:
        print(f"[agento-notifier] ao spawn failed for {project_id}: {e}")


def get_tracker_info(session_id: str) -> tuple[str | None, str | None]:
    if not session_id:
        return None, None
    tracker_path = os.path.expanduser(f"~/.smartclaw/ao-session-tracker/active/{session_id}.json")
    try:
        if os.path.exists(tracker_path):
            with open(tracker_path, "r") as f:
                data = json.load(f)
            return data.get("slack_channel"), data.get("slack_thread_ts")
    except Exception as e:
        print(f"[agento-notifier] Warning: could not read tracker file for {session_id}: {e}")
    return None, None


def post_to_slack(text: str, channel: str | None = None, thread_ts: str | None = None) -> None:
    # Gather potential tokens in priority order
    tokens = []
    for var_name in ["SLACK_BOT_TOKEN", "SLACK_BOT_TOKEN", "SLACK_USER_TOKEN"]:
        t = os.environ.get(var_name)
        if t and t not in tokens:
            tokens.append(t)

    target_channel = channel if channel else SLACK_CHANNEL
    if not tokens:
        print(f"[agento-notifier] No Slack token in env, would have posted to {target_channel} (thread: {thread_ts}): {text}")
        return

    msg_payload = {"channel": target_channel, "text": text}
    if thread_ts:
        msg_payload["thread_ts"] = thread_ts
    payload = json.dumps(msg_payload).encode()

    last_err = None
    for token in tokens:
        req = urllib.request.Request(
            "https://slack.com/api/chat.postMessage",
            data=payload,
            headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                body = json.loads(resp.read())
            if body.get("ok"):
                print(f"[agento-notifier] Posted to Slack ({target_channel}, thread: {thread_ts}): {text[:80]}")
                return
            else:
                last_err = f"Slack error: {body.get('error')}"
                print(f"[agento-notifier] Token starting with {token[:10]} failed: {body}")
        except Exception as exc:
            last_err = str(exc)
            print(f"[agento-notifier] Request error with token starting with {token[:10]}: {exc}")

    print(f"[agento-notifier] All tokens failed to post to Slack. Last error: {last_err}")


class Handler(BaseHTTPRequestHandler):
    def do_POST(self) -> None:
        if self.path != "/ao-notify":
            self.send_response(404)
            self.end_headers()
            return

        # Optional webhook authentication
        if WEBHOOK_SECRET:
            auth_header = self.headers.get("Authorization", "")
            if auth_header != f"Bearer {WEBHOOK_SECRET}":
                self.send_response(401)
                self.end_headers()
                return

        try:
            length = int(self.headers.get("Content-Length", 0))
            if length < 0:
                length = 0
        except ValueError:
            length = 0
        body = self.rfile.read(length)
        try:
            data = json.loads(body)
        except json.JSONDecodeError:
            self.send_response(400)
            self.end_headers()
            return

        if not isinstance(data, dict):
            self.send_response(400)
            self.end_headers()
            return

        self.send_response(200)
        self.end_headers()

        event = data.get("event")
        if not isinstance(event, dict):
            event = {}
        msg_type = data.get("type", "notification")

        # Extract channel and thread_ts from the payload
        thread_ts = None
        channel = None

        # 1. Check if sessionKey contains :thread:<threadTs>
        session_key = data.get("sessionKey") or ""
        if ":thread:" in session_key:
            parts = session_key.split(":thread:")
            if len(parts) > 1:
                thread_ts = parts[1]

        # 2. Extract channel from 'to' or 'channel'
        to_field = data.get("to")
        chan_field = data.get("channel")
        if to_field:
            channel = to_field
        elif chan_field and chan_field != "slack":
            channel = chan_field

        # 3. If msg_type == "message", extract from 'context'
        context = data.get("context")
        if isinstance(context, dict):
            if not thread_ts:
                thread_ts = context.get("slackThreadTs")
            if not channel:
                channel = context.get("slackChannelId")

        # 4. If event is present, extract from event.data
        if isinstance(event, dict):
            event_data = event.get("data")
            if isinstance(event_data, dict):
                if not thread_ts:
                    thread_ts = event_data.get("slackThreadTs")
                if not channel:
                    channel = event_data.get("slackChannelId")

        # 5. Extract session_id to fallback on tracker file lookup
        session_id = None
        if msg_type == "message":
            if isinstance(context, dict):
                session_id = context.get("sessionId")
        else:
            session_id = event.get("sessionId")

        if session_id:
            tracker_channel, tracker_thread_ts = get_tracker_info(session_id)
            if tracker_channel and not channel:
                channel = tracker_channel
            if tracker_thread_ts and not thread_ts:
                thread_ts = tracker_thread_ts

        if msg_type == "message":
            text = f":robot_face: *agento* | {data.get('message', '') or ''}"
        else:
            priority = event.get("priority") or "info"
            event_type = event.get("type") or "unknown"
            message = event.get("message") or ""
            session = event.get("sessionId") or ""
            project = event.get("projectId") or ""
            event_data = event.get("data")
            if isinstance(event_data, dict):
                pr_url = event_data.get("prUrl", "")
            else:
                pr_url = ""
            pr_part = f" | <{pr_url}|PR>" if pr_url else ""
            emoji = {"urgent": ":rotating_light:", "action": ":point_right:",
                     "warning": ":warning:", "info": ":information_source:"}.get(priority, ":bell:")
            text = f"{emoji} *agento* `{event_type}` [{project}/{session}]{pr_part}\n{message}"

        post_to_slack(text, channel=channel, thread_ts=thread_ts)

        # Recovery handlers - act on AO lifecycle events (non-blocking)
        event_type = event.get("type") or ""
        project_id = event.get("projectId") or ""
        event_data = event.get("data")
        if isinstance(event_data, dict):
            pr_number = event_data.get("prNumber") or event_data.get("pr")
        else:
            pr_number = None

        if event_type == "merge.completed" and project_id:
            ao_stop(project_id)
        elif event_type == "reaction.escalated" and project_id:
            # Only respawn after escalation (reaction exhausted retries), not on every stuck poll
            reaction_key = event_data.get("reactionKey") if isinstance(event_data, dict) else None
            if reaction_key == "agent-stuck":
                claim_pr = str(pr_number) if pr_number else None
                ao_spawn(project_id, claim_pr)

    def log_message(self, fmt: str, *args: object) -> None:
        print(f"[agento-notifier] {fmt % args}")


if __name__ == "__main__":
    print(f"[agento-notifier] Listening on port {PORT}")
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
