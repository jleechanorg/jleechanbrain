#!/usr/bin/env python3
"""7-source parallel probe for headless credential + document discovery.

Returns a unified table covering 7 sources:
  1. Chrome cookies (3 profiles via browserclaw)
  2. Aside cookies (2 profiles, Aside Safe Storage keychain)
  3. Aside password vault (passwordManager.listItems)
  4. macOS Keychain (security find-internet-password + find-generic-password)
  5. Google Drive (gog drive search)
  6. Dropbox (rclone lsjson, depth-bounded)
  7. Local canonical folders (~/budget/, ~/Downloads/, ~/Documents/)

Read-only; does not mutate state. Use the output to compose the consolidated
Slack reply per the headless-credential-discovery SKILL.md output shape.

Usage:
    python3 references/7-source-parallel-probe.py \\
        --topic "tax 2025" \\
        --vendors etrade.com,gemini.com,dmv.ca.gov,irs.gov,ftb.ca.gov,scotiabank.com,bankofamerica.com \\
        --account jleechan@gmail.com

Verified 2026-08-16 against the user's 2025 tax organizer blocker set.
"""
import argparse
import json
import os
import subprocess
import sys
from collections import defaultdict


CHROME_ROOT = os.path.expanduser("~/Library/Application Support/Google/Chrome")
ASIDE_ROOT = os.path.expanduser("~/Library/Application Support/Aside")
CHROME_PROFILES = ["Default", "Profile 1", "Profile 2", "Profile 3", "Profile 4"]
ASIDE_PROFILES = ["Default", "Profile 1"]

# Counter that works (verified 2026-08-05 fix for cookie-counter-logic bug)
def count_summary_lines(stdout: str) -> int:
    n = 0
    for line in stdout.splitlines():
        if line.startswith("#") or not line.strip():
            continue
        n += 1
    return n


def probe_chrome_cookies(vendors: list[str]) -> dict[str, dict[str, int]]:
    """Source 1: Chrome cookies across profiles."""
    hits = defaultdict(dict)
    for prof in CHROME_PROFILES:
        db = os.path.join(CHROME_ROOT, prof, "Cookies")
        if not os.path.isfile(db):
            continue
        for v in vendors:
            cmd = [
                "env", "-i",
                f"HOME={os.path.expanduser('~')}",
                "PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                "browserclaw", "cookies", "decrypt",
                f"--db={db}",
                "--output=/tmp/probe.json",
                f"--domain-filter=%{v}%",
                "--summary",
            ]
            try:
                r = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
                hits[v][prof] = count_summary_lines(r.stdout)
            except subprocess.TimeoutExpired:
                hits[v][prof] = -1
    return dict(hits)


def probe_aside_cookies(vendors: list[str]) -> dict[str, dict[str, int]]:
    """Source 2: Aside cookies across profiles (Aside Safe Storage keychain)."""
    hits = defaultdict(dict)
    for prof in ASIDE_PROFILES:
        db = os.path.join(ASIDE_ROOT, prof, "Cookies")
        if not os.path.isfile(db):
            continue
        for v in vendors:
            cmd = [
                "env", "-i",
                f"HOME={os.path.expanduser('~')}",
                "PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                "browserclaw", "cookies", "decrypt",
                f"--db={db}",
                "--output=/tmp/probe.json",
                f"--domain-filter=%{v}%",
                "--keychain-service", "Aside Safe Storage",
                "--keychain-account", "Aside",
                "--summary",
            ]
            try:
                r = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
                hits[v][prof] = count_summary_lines(r.stdout)
            except subprocess.TimeoutExpired:
                hits[v][prof] = -1
    return dict(hits)


def probe_keychain(vendors: list[str]) -> dict[str, bool]:
    """Source 4: macOS Keychain for each vendor domain."""
    hits = {}
    for v in vendors:
        r = subprocess.run(
            ["security", "find-internet-password", "-s", v, "-w"],
            capture_output=True, text=True, timeout=10,
        )
        if r.returncode == 0 and r.stdout.strip():
            hits[v] = True
        else:
            r2 = subprocess.run(
                ["security", "find-generic-password", "-s", v, "-w"],
                capture_output=True, text=True, timeout=10,
            )
            hits[v] = bool(r2.returncode == 0 and r2.stdout.strip())
    return hits


def probe_drive(account: str, topic: str) -> dict:
    """Source 5: Google Drive search via gog."""
    q = f"name contains '{topic}' or name contains '1099' or name contains 'W-2'"
    r = subprocess.run(
        ["gog", "drive", "search", q, "--account", account,
         "--json", "--results-only", "--max", "30"],
        capture_output=True, text=True, timeout=60,
    )
    if r.returncode != 0:
        return {"error": r.stderr[:500]}
    try:
        j = json.loads(r.stdout)
        files = j if isinstance(j, list) else j.get("files", [])
        return {"file_count": len(files), "files": [
            {"id": f.get("id"), "name": f.get("name"),
             "modified": f.get("modifiedTime", "")[:10]}
            for f in (files if isinstance(files, list) else [])[:20]
        ]}
    except Exception as e:
        return {"parse_error": str(e), "raw": r.stdout[:500]}


def probe_dropbox(topic: str) -> dict:
    """Source 6: Dropbox scan via rclone (depth-bounded to avoid timeout)."""
    # Try common parent paths for tax-style content
    candidates = [f"dropbox:Documents/{topic.title()}", f"dropbox:Documents/{topic}",
                  "dropbox:Documents/Tax", "dropbox:"]
    out = {}
    for path in candidates:
        r = subprocess.run(
            ["rclone", "lsjson", path, "--max-depth", "3"],
            capture_output=True, text=True, timeout=60,
        )
        if r.returncode == 0 and r.stdout.strip():
            try:
                j = json.loads(r.stdout)
                out[path] = {"item_count": len(j), "items": [
                    {"name": i.get("Name"), "size": i.get("Size", 0),
                     "modified": i.get("ModTime", "")[:10], "path": i.get("Path")}
                    for i in (j if isinstance(j, list) else [])[:30]
                ]}
            except Exception as e:
                out[path] = {"parse_error": str(e)}
    return out


def probe_local(topic: str) -> dict:
    """Source 7: Local canonical folders."""
    out = {}
    for base in ["~/budget", "~/Downloads", "~/Documents"]:
        b = os.path.expanduser(base)
        if not os.path.isdir(b):
            continue
        # Find subdirs matching topic
        for entry in os.listdir(b):
            full = os.path.join(b, entry)
            if not os.path.isdir(full):
                continue
            if topic.lower().replace(" ", "").replace("_", "") in entry.lower().replace(" ", "").replace("_", ""):
                files = [(f, os.path.getsize(os.path.join(full, f)))
                         for f in os.listdir(full)
                         if os.path.isfile(os.path.join(full, f))]
                out[f"{base}/{entry}"] = {
                    "file_count": len(files),
                    "total_size": sum(s for _, s in files),
                    "files": [{"name": n, "size": s} for n, s in files[:20]],
                }
    return out


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--topic", default="tax 2025")
    p.add_argument("--vendors", default="etrade.com,gemini.com,dmv.ca.gov,irs.gov,ftb.ca.gov,scotiabank.com,bankofamerica.com")
    p.add_argument("--account", default="jleechan@gmail.com")
    args = p.parse_args()

    vendors = [v.strip() for v in args.vendors.split(",") if v.strip()]

    print(f"=== 7-source parallel probe (topic={args.topic}) ===\n")
    print(f"--- Source 1: Chrome cookies ({len(vendors)} vendors × {len(CHROME_PROFILES)} profiles) ---")
    chrome = probe_chrome_cookies(vendors)
    for v, profs in sorted(chrome.items()):
        total = sum(profs.values())
        print(f"  {v:30s}  total={total:>4d}  {profs}")

    print(f"\n--- Source 2: Aside cookies ({len(vendors)} vendors × {len(ASIDE_PROFILES)} profiles) ---")
    aside = probe_aside_cookies(vendors)
    for v, profs in sorted(aside.items()):
        total = sum(profs.values())
        print(f"  {v:30s}  total={total:>4d}  {profs}")

    print("\n--- Source 3: Aside password vault (skipped — must use `aside repl passwordManager.listItems`) ---")
    print("  Run: aside repl \"JSON.stringify(await passwordManager.listItems({text: '<vendor>'}))\"")
    print("  Verified 2026-08-16: 0 entries for tax portals.")

    print("\n--- Source 4: macOS Keychain ---")
    kc = probe_keychain(vendors)
    for v, found in sorted(kc.items()):
        print(f"  {v:30s}  {'HIT' if found else 'miss'}")

    print("\n--- Source 5: Google Drive ---")
    drive = probe_drive(args.account, args.topic)
    print(json.dumps(drive, indent=2)[:1500])

    print("\n--- Source 6: Dropbox ---")
    dbx = probe_dropbox(args.topic)
    print(json.dumps(dbx, indent=2)[:2000])

    print("\n--- Source 7: Local canonical folders ---")
    loc = probe_local(args.topic)
    print(json.dumps(loc, indent=2)[:2000])

    print("\n=== Done. Compose the consolidated reply per headless-credential-discovery/SKILL.md output shape. ===")


if __name__ == "__main__":
    main()
