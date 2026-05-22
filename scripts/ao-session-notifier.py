#!/usr/bin/env python3
"""
AO Session Notifier — Track AO workers and post results to originating Slack threads.

When an AO worker is dispatched, this script:
1. Records the session→Slack thread mapping
2. Polls active sessions for liveness
3. When a session ends: checks git log for commits/PRs, posts result to Slack thread
4. If session died: posts failure notice to Slack thread

This replaces the broken mctrl supervisor + notifier-openclaw pipeline.
"""

import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

TRACKER_DIR = Path.home() / ".smartclaw" / "ao-session-tracker"
TRACKER_DIR.mkdir(parents=True, exist_ok=True)

ACTIVE_DIR = TRACKER_DIR / "active"
ACTIVE_DIR.mkdir(exist_ok=True)
DONE_DIR = TRACKER_DIR / "done"
DONE_DIR.mkdir(exist_ok=True)

def iso_now():
    return datetime.now(timezone.utc).isoformat()

def register(session_id: str, slack_channel: str, slack_thread_ts: str,
             bead_id: str = "", task_summary: str = "", worktree: str = ""):
    """Register a new AO session with its Slack thread context."""
    record = {
        "session_id": session_id,
        "slack_channel": slack_channel,
        "slack_thread_ts": slack_thread_ts,
        "bead_id": bead_id,
        "task_summary": task_summary,
        "worktree": worktree,
        "registered_at": iso_now(),
        "start_sha": _get_sha(worktree) if worktree else "",
        "status": "active"
    }
    path = ACTIVE_DIR / f"{session_id}.json"
    path.write_text(json.dumps(record, indent=2))
    print(f"Registered {session_id} → thread {slack_thread_ts}")
    return record

def _get_sha(worktree: str) -> str:
    try:
        r = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True,
                          cwd=worktree, timeout=10)
        return r.stdout.strip()[:12] if r.returncode == 0 else ""
    except Exception:
        return ""

def _find_tmux_session(session_id: str) -> Optional[str]:
    """Find the tmux session name for an AO session ID."""
    try:
        r = subprocess.run(["tmux", "list-sessions"], capture_output=True, text=True, timeout=5)
        for line in r.stdout.splitlines():
            if session_id in line:
                return line.split(":")[0]
    except Exception:
        pass
    return None

def _session_alive(session_id: str) -> bool:
    return _find_tmux_session(session_id) is not None

def _get_worktree_path(session_id: str) -> Optional[str]:
    """Find the worktree for a session."""
    try:
        r = subprocess.run(
            ["find", os.path.expanduser("~/.worktrees"), "-maxdepth", "2", "-name", session_id, "-type", "d"],
            capture_output=True, text=True, timeout=10
        )
        paths = r.stdout.strip().splitlines()
        return paths[0] if paths else None
    except Exception:
        return None

def _check_pr(session_id: str, worktree: str) -> Optional[str]:
    """Check if a PR was created from this session's branch."""
    try:
        r = subprocess.run(
            ["git", "log", "--oneline", "-5"], capture_output=True, text=True,
            cwd=worktree, timeout=10
        )
        # Check for gh pr create in the log or branch push
        r2 = subprocess.run(
            ["git", "branch", "--show-current"], capture_output=True, text=True,
            cwd=worktree, timeout=10
        )
        branch = r2.stdout.strip()
        if not branch or branch == "main":
            return None
        
        # Check if branch exists on remote and has a PR
        r3 = subprocess.run(
            ["gh", "pr", "list", "--head", branch, "--json", "url,number,state", "--limit", "1"],
            capture_output=True, text=True, cwd=worktree, timeout=15
        )
        prs = json.loads(r3.stdout) if r3.stdout.strip() else []
        if prs:
            pr = prs[0]
            return f"PR #{pr['number']}: {pr['url']} ({pr['state']})"
    except Exception:
        pass
    return None

def _get_new_commits(worktree: str, start_sha: str) -> str:
    """Get commits since start_sha."""
    if not start_sha or not worktree:
        return ""
    try:
        r = subprocess.run(
            ["git", "log", "--oneline", f"{start_sha}..HEAD"],
            capture_output=True, text=True, cwd=worktree, timeout=10
        )
        return r.stdout.strip() if r.returncode == 0 else ""
    except Exception:
        return ""

def poll_all():
    """Check all active sessions and post results for completed ones."""
    active_files = list(ACTIVE_DIR.glob("*.json"))
    if not active_files:
        return
    
    results = []
    for f in active_files:
        record = json.loads(f.read_text())
        session_id = record["session_id"]
        alive = _session_alive(session_id)
        
        if not alive:
            # Session ended — determine outcome
            worktree = record.get("worktree", "") or _get_worktree_path(session_id)
            start_sha = record.get("start_sha", "")
            new_commits = ""
            pr_info = None
            
            if worktree and os.path.isdir(worktree):
                new_commits = _get_new_commits(worktree, start_sha)
                pr_info = _check_pr(session_id, worktree)
            
            # Build result message
            if pr_info:
                status = "completed"
                msg = f"✅ AO worker `{session_id}` completed — {pr_info}"
                if new_commits:
                    msg += f"\nCommits: {new_commits.count(chr(10))+1} new"
            elif new_commits:
                status = "partial"
                msg = f"⚠️ AO worker `{session_id}` ended with commits but no PR found.\nCommits:\n{new_commits[:500]}"
            else:
                status = "failed"
                msg = f"❌ AO worker `{session_id}` died without producing commits or PR.\nTask: {record.get('task_summary', 'unknown')}"
                # Check if worktree was GC'd
                if not worktree or not os.path.isdir(worktree):
                    msg += "\n(Worktree was garbage-collected — likely killed by a lifecycle worker)"
            
            # Record the timestamp for the Slack post
            record["status"] = status
            record["completed_at"] = iso_now()
            record["result_message"] = msg
            
            # Move to done
            done_path = DONE_DIR / f"{session_id}.json"
            done_path.write_text(json.dumps(record, indent=2))
            f.unlink()
            
            results.append({
                "session_id": session_id,
                "channel": record["slack_channel"],
                "thread_ts": record["slack_thread_ts"],
                "message": msg,
                "status": status
            })
        else:
            # Still alive — nothing to report this cycle
            pass
    
    return results

def status():
    """Print current status of all tracked sessions."""
    active = list(ACTIVE_DIR.glob("*.json"))
    done = list(DONE_DIR.glob("*.json"))
    print(f"Active: {len(active)}, Done: {len(done)}")
    for f in active:
        r = json.loads(f.read_text())
        alive = _session_alive(r["session_id"])
        print(f"  {r['session_id']}: {'alive' if alive else 'DEAD'} — thread {r['slack_thread_ts']}")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: ao-notify.py register|poll|status ...")
        sys.exit(1)
    
    cmd = sys.argv[1]
    
    if cmd == "register":
        # register SESSION CHANNEL THREAD_TS [BEAD_ID] [TASK_SUMMARY] [WORKTREE]
        register(
            session_id=sys.argv[2],
            slack_channel=sys.argv[3],
            slack_thread_ts=sys.argv[4],
            bead_id=sys.argv[5] if len(sys.argv) > 5 else "",
            task_summary=sys.argv[6] if len(sys.argv) > 6 else "",
            worktree=sys.argv[7] if len(sys.argv) > 7 else ""
        )
    elif cmd == "poll":
        results = poll_all()
        if results:
            # Output results as JSON for the caller (Hermes cron) to post to Slack
            print(json.dumps(results))
        else:
            print("[]")
    elif cmd == "status":
        status()
    else:
        print(f"Unknown command: {cmd}")
        sys.exit(1)
