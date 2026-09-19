#!/usr/bin/env python3
"""
babysit-stale-watchdog.py

Detect enabled babysit crons in ~/.smartclaw/cron/jobs.json whose referenced PR
is MERGED or CLOSED, and disable them.

Bug-ref: 2026-07-03 — babysit-wa-2403-PR7711 ran 251 polls over 11 days after
PR #7711 merged, spamming Slack with "TERMINAL: merged" pings.

Companion to the in-script `is_pr_terminal()` check (added to babysit.py
2026-07-03). This watchdog is belt-and-suspenders: even if babysit.py is
broken, missing, or running against an old task_summary, this cron will catch
the stale job and disable it within 30 minutes.

Run via launchd plist `ai.smartclaw.schedule.babysit-stale-watchdog.plist`
(every 30 min). Posts ONE alert per day to #ai-general when stale jobs are
disabled, otherwise silent.
"""
import fcntl
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

CRON_JOBS = Path.home() / ".smartclaw" / "cron" / "jobs.json"
PR_URL_RE = re.compile(r"https://github\.com/([\w.-]+)/([\w.-]+)/pull/(\d+)")
PR_REF_RE = re.compile(r"\bPR\s*#?\s*(\d{3,5})\b", re.I)
DEFAULT_REPO = ("jleechanorg", "worldarchitect.ai")


def extract_pr_refs(text: str) -> list[tuple[str, str, int]]:
    """Extract (owner, repo, number) tuples from prompt text."""
    refs: list[tuple[str, str, int]] = []
    seen: set[tuple[str, str, int]] = set()
    for m in PR_URL_RE.finditer(text):
        key = (m.group(1), m.group(2), int(m.group(3)))
        if key not in seen:
            seen.add(key)
            refs.append(key)
    # Bare PR refs default to the most common babysit target
    for m in PR_REF_RE.finditer(text):
        num = int(m.group(1))
        key = (DEFAULT_REPO[0], DEFAULT_REPO[1], num)
        if num not in {r[2] for r in refs} and key not in seen:
            seen.add(key)
            refs.append(key)
    return refs


def gh_pr_state(owner: str, repo: str, number: int) -> str | None:
    """Return MERGED, CLOSED, OPEN, or None on gh failure."""
    try:
        r = subprocess.run(
            ["gh", "pr", "view", str(number), "--repo", f"{owner}/{repo}",
             "--json", "state"],
            capture_output=True, text=True, timeout=15,
        )
        if r.returncode != 0:
            return None
        return json.loads(r.stdout).get("state")
    except (subprocess.TimeoutExpired, json.JSONDecodeError, FileNotFoundError):
        return None


def is_babysit(job: dict) -> bool:
    """Heuristic: looks like an AO babysit cron."""
    name = (job.get("name") or "").lower()
    if "babysit" in name:
        return True
    prompt_head = (job.get("prompt") or "")[:200].lower()
    return "babysit" in prompt_head or "babysitting" in prompt_head


def main() -> int:
    if not CRON_JOBS.exists():
        print(f"jobs.json not found at {CRON_JOBS}", file=sys.stderr)
        return 1

    # Ensure lock file exists
    lock_path = CRON_JOBS.parent / "jobs.json.lock"
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    lock_path.touch(exist_ok=True)

    with open(lock_path, "w") as lock_fd:
        fcntl.flock(lock_fd.fileno(), fcntl.LOCK_EX)
        try:
            with CRON_JOBS.open() as f:
                data = json.load(f)

            now = datetime.now(timezone.utc).isoformat(timespec="seconds")
            disabled: list[dict] = []

            for job in data.get("jobs", []):
                if not job.get("enabled"):
                    continue
                if not is_babysit(job):
                    continue

                name = job.get("name", "")
                prompt = job.get("prompt") or ""
                refs = extract_pr_refs(f"{name}\n{prompt}")

                terminal_pr = None
                for owner, repo, num in refs:
                    state = gh_pr_state(owner, repo, num)
                    if state in ("MERGED", "CLOSED"):
                        terminal_pr = (owner, repo, num, state)
                        break

                if terminal_pr:
                    owner, repo, num, state = terminal_pr
                    job["enabled"] = False
                    job["state"] = "paused"
                    repeat = job.get("repeat")
                    completed_polls_str = repeat.get("completed", "?") if isinstance(repeat, dict) else "?"
                    job["paused_reason"] = (
                        f"Disabled by babysit-stale-watchdog {now}: "
                        f"PR #{num} {state} on {owner}/{repo}. "
                        f"Original polls: {completed_polls_str}"
                    )
                    job["last_run_at"] = now
                    disabled.append({
                        "job_id": job["id"],
                        "name": name,
                        "pr": f"{owner}/{repo}#{num}",
                        "state": state,
                        "completed_polls": repeat.get("completed", 0) if isinstance(repeat, dict) else 0,
                    })

            if disabled:
                # Write to temp file first and rename atomically
                temp_file = CRON_JOBS.with_suffix(".json.tmp")
                with temp_file.open("w") as f:
                    json.dump(data, f, indent=2, default=str)
                temp_file.replace(CRON_JOBS)

                print(f"Disabled {len(disabled)} stale babysit jobs:")
                for d in disabled:
                    print(f"  • {d['job_id']} ({d['pr']} {d['state']}, polls={d['completed_polls']}): {d['name']}")

                # Write alert payload for the launchd wrapper to pick up, checking for daily throttle
                alert_path = Path.home() / ".smartclaw" / "cron" / "output" / "babysit-stale-watchdog.last_alert.json"
                
                already_alerted = False
                if alert_path.exists():
                    try:
                        with alert_path.open() as af:
                            alert_data = json.load(af)
                        last_alert_date = alert_data.get("disabled_at", "")[:10]
                        current_date = now[:10]
                        if last_alert_date == current_date:
                            already_alerted = True
                    except Exception:
                        pass

                if not already_alerted:
                    alert_path.parent.mkdir(parents=True, exist_ok=True)
                    with alert_path.open("w") as f:
                        json.dump({"disabled_at": now, "jobs": disabled}, f, indent=2)
                return 0
            else:
                print("No stale babysit jobs found.")
                return 0
        finally:
            fcntl.flock(lock_fd.fileno(), fcntl.LOCK_UN)


if __name__ == "__main__":
    sys.exit(main())