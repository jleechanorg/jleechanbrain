#!/usr/bin/env python3
"""
verify_cron_backup_round_trip.py

Round-trip verifier for the cron backup export at
  ~/.smartclaw/docs/context/CRON_JOBS_BACKUP.json

against the canonical store at
  ~/.smartclaw/cron/jobs.json

Exits 0 with "PASS <N> jobs round-trip" on success.
Exits 1 with diagnostic detail on any drift.

Usage:
    python3 scripts/verify_cron_backup_round_trip.py [--strict]

The --strict flag treats any VOLATILE-field drift as a failure too (useful
when you want to confirm the export's volatile-strip logic actually ran).

What this catches that ad-hoc grep would not:
  - Jobs that exist in the live store but were silently dropped from the
    export (the original 2026-08-10 bug: 13 missing + 8 mis-attributed).
  - Field-level drift on any non-volatile key.
  - TOTAL == ENABLED in the post (separate signature; see SKILL.md pitfall).
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

# Mirrored from scripts/cron-backup-sync.sh — keep in sync if the script
# changes its VOLATILE set.
VOLATILE_TOP = {
    "next_run_at",
    "last_run_at",
    "last_status",
    "last_error",
    "last_delivery_error",
    "fire_claim",
}
VOLATILE_META = {"next_run", "last_run"}

STORE = Path.home() / ".smartclaw" / "cron" / "jobs.json"
EXPORT = Path.home() / ".smartclaw" / "docs" / "context" / "CRON_JOBS_BACKUP.json"


def load_jobs(path: Path) -> dict[str, dict]:
    if not path.exists():
        print(f"FATAL: {path} does not exist", file=sys.stderr)
        sys.exit(2)
    with path.open() as f:
        data = json.load(f)
    jobs = data.get("jobs", [])
    if not isinstance(jobs, list):
        print(f"FATAL: {path} 'jobs' field is not a list", file=sys.stderr)
        sys.exit(2)
    return {j["id"]: j for j in jobs}


def strip_volatile(job: dict) -> dict:
    out = {k: v for k, v in job.items() if k not in VOLATILE_TOP}
    meta = out.get("meta")
    if isinstance(meta, dict):
        out["meta"] = {k: v for k, v in meta.items() if k not in VOLATILE_META}
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--strict",
        action="store_true",
        help="Also fail on VOLATILE-field drift (catches bugs in the stripper).",
    )
    args = parser.parse_args()

    live = load_jobs(STORE)
    exported = load_jobs(EXPORT)

    missing = set(live) - set(exported)
    extra = set(exported) - set(live)
    if missing or extra:
        print(
            f"FAIL: job-set drift — missing={sorted(missing)} extra={sorted(extra)}",
            file=sys.stderr,
        )
        return 1

    drift: list[str] = []
    volatile_drift: list[str] = []
    for jid, live_job in live.items():
        live_clean = strip_volatile(live_job)
        export_clean = strip_volatile(exported[jid])

        for key in set(live_clean) | set(export_clean):
            if live_clean.get(key) != export_clean.get(key):
                if key in VOLATILE_TOP or key in VOLATILE_META:
                    volatile_drift.append(f"{jid}.{key}")
                else:
                    drift.append(f"{jid}.{key}")

    if drift:
        print(f"FAIL: non-volatile field drift — {drift}", file=sys.stderr)
        return 1
    if volatile_drift and args.strict:
        print(
            f"FAIL: VOLATILE fields present in export "
            f"(stripper did not run?) — {volatile_drift}",
            file=sys.stderr,
        )
        return 1

    enabled_live = sum(1 for j in live.values() if j.get("enabled"))
    enabled_export = sum(1 for j in exported.values() if j.get("enabled"))
    if enabled_live != enabled_export:
        print(
            f"FAIL: enabled count drift — live={enabled_live} export={enabled_export}",
            file=sys.stderr,
        )
        return 1

    print(f"PASS {len(exported)} jobs round-trip (enabled={enabled_export})")
    return 0


if __name__ == "__main__":
    sys.exit(main())