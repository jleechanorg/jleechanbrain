#!/usr/bin/env python3
"""
personal-finance-status-check 5-source parallel reader.

Run this when the user asks for status on a prior life-admin work block
(tax, EDD audit, immigration, insurance). Reads:
  1. nextsteps-*.md in ~/roadmap/ (canonical artifact)
  2. ~/budget/ + ~/Downloads/ + ~/Documents/ (source files)
  3. ~/roadmap/.beads/issues.jsonl (open P1 beads via br ready --priority=1)
  4. Drive folder (when one is known) via gog drive ls --parent=<id>
  5. Slack #life channel (C0AMM2B4319) via mcp__slack__conversations_history

Usage:
  python3 ~/.smartclaw/skills/personal-finance-status-check/references/5-source-parallel-read.py <topic>

Prints a 5-section report to stdout. Pipe into the dispatch.

This is reading-only — it does NOT mutate any state. Beads may return
"Schema version mismatch" warnings; pass that through to the user.
"""
import os
import subprocess
import sys
import json
from pathlib import Path


def find_nextsteps_doc(topic: str) -> list[Path]:
    out = subprocess.run(
        ["find", os.path.expanduser("~/roadmap"), "-maxdepth", "2",
         "-name", "nextsteps-*-*.md", "-mtime", "-120"],
        capture_output=True, text=True, timeout=10,
    ).stdout.strip().splitlines()
    matches = [Path(p) for p in out if topic.lower() in Path(p).name.lower()]
    return matches


def list_source_files(topics: list[str]) -> dict[str, list[tuple[Path, int]]]:
    buckets = {}
    for base in ["~/budget", "~/Downloads", "~/Documents"]:
        bd = Path(os.path.expanduser(base))
        if not bd.is_dir():
            continue
        for sub in bd.iterdir():
            if not sub.is_dir():
                continue
            name = sub.name.lower()
            if any(t.lower() in name for t in topics):
                files = [(p, p.stat().st_size) for p in sorted(sub.iterdir()) if p.is_file()]
                buckets[str(sub)] = files
    return buckets


def open_p1_beads() -> str:
    try:
        return subprocess.run(
            ["br", "ready", "--priority", "1"],
            capture_output=True, text=True,
            cwd=os.path.expanduser("~/roadmap"), timeout=10,
        ).stdout
    except FileNotFoundError:
        return "br not installed"


def drive_ls(parent_id: str, account: str = "jleechan@gmail.com") -> str:
    try:
        return subprocess.run(
            ["gog", "drive", "ls", f"--parent={parent_id}",
             "-a", account, "-p"],
            capture_output=True, text=True, timeout=30,
        ).stdout
    except FileNotFoundError:
        return "gog not installed"


def main() -> None:
    if len(sys.argv) < 2:
        print("Usage: 5-source-parallel-read.py <topic> [drive-folder-id]", file=sys.stderr)
        sys.exit(2)
    topic = sys.argv[1]
    drive_id = sys.argv[2] if len(sys.argv) > 2 else None

    print(f"=== 1. Nextsteps doc (topic={topic!r}) ===")
    docs = find_nextsteps_doc(topic)
    for d in docs:
        print(f"  {d}  ({d.stat().st_size} bytes)")
    if not docs:
        print("  (none found in ~/roadmap)")

    print(f"\n=== 2. Source files (matching {topic}) ===")
    files = list_source_files([topic])
    if not files:
        print("  (no matching subdirs)")
    for bucket, fs in files.items():
        print(f"  {bucket}/: {len(fs)} files")
        for p, sz in fs:
            print(f"    {sz:>10d}  {p.name}")

    print(f"\n=== 3. Open P1 beads (br ready --priority=1) ===")
    print(open_p1_beads())

    if drive_id:
        print(f"\n=== 4. Drive folder {drive_id} ===")
        print(drive_ls(drive_id))
    else:
        print("\n=== 4. Drive folder === (no id provided — pass as 2nd arg)")

    print("\n=== 5. Slack #life channel (C0AMM2B4319) ===")
    print("  (use mcp__slack__conversations_history(channel_id=C0AMM2B4319, limit=90d)")
    print("   in a separate Slack MCP call — this script does not have token access)")


if __name__ == "__main__":
    main()
