#!/usr/bin/env python3
"""
AO Session Poll & Post — Cron job that checks AO workers and posts results to Slack.

Designed to be called from a Hermes cron job. Uses the ao-session-notifier to
detect completed/failed sessions, then posts results via Hermes's Slack MCP.
"""

import json
import subprocess
import sys

NOTIFIER = "${HOME}/.smartclaw_prod/scripts/ao-session-notifier.py"

def main():
    # Run the notifier poll
    try:
        r = subprocess.run(
            ["python3", NOTIFIER, "poll"],
            capture_output=True, text=True, timeout=30
        )
        if r.returncode != 0:
            print(f"Notifier failed: {r.stderr[:200]}")
            return
        
        results = json.loads(r.stdout) if r.stdout.strip() else []
    except Exception as e:
        print(f"Error running notifier: {e}")
        return
    
    if not results:
        # No completed sessions — silent (cron no-agent mode)
        return
    
    # Build output for the Hermes cron agent to post
    for r in results:
        channel = r["channel"]
        thread_ts = r["thread_ts"]
        message = r["message"]
        session_id = r["session_id"]
        status = r["status"]
        
        # Output in a format the Hermes agent can parse and post
        print(f"POST_SLACK channel={channel} thread_ts={thread_ts}")
        print(f"message={message}")
        print(f"status={status}")
        print("---")

if __name__ == "__main__":
    main()
