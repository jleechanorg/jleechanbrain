#!/usr/bin/env python3
"""End-to-end smoke test for the time-spent-estimation skill.

7 stages:
  1. Discover the skill in RESOLVER.md
  2. SKILL.md has required sections (Contract, Phases, Output Format, Anti-Patterns)
  3. check_resolvable.py passes
  4. Puller script runs end-to-end
  5. Output JSON has all required sections
  6. All sources report a status (no silent drops)
  7. Limitations are surfaced (≥ 5 entries)
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "pull_time_signals.py"
RESOLVER = Path.home() / ".smartclaw" / "skills" / "RESOLVER.md"


def stage(name: str):
    print(f"[E2E] {name}")


def main() -> int:
    stage("1. Resolver discoverability")
    resolver_text = RESOLVER.read_text()
    assert "time-spent-estimation" in resolver_text, \
        "skill not in RESOLVER.md"
    assert "Triggers:" in resolver_text.split("## time-spent-estimation")[1][:300], \
        "Triggers line missing in resolver entry"

    stage("2. SKILL.md exists with required sections")
    skill_md = (ROOT / "SKILL.md").read_text()
    for section in ("## Contract", "## Phases", "## Output Format", "## Anti-Patterns"):
        assert section in skill_md, f"SKILL.md missing {section}"

    stage("3. check_resolvable.py passes (skillify_check + trigger_eval also wired)")
    # Reference all 3 contract-validators so this test exercises the full audit chain
    check_script = ROOT / "scripts" / "check_resolvable.py"
    rc = subprocess.run([sys.executable, str(check_script), "--repo", str(Path.home() / ".smartclaw")],
                        capture_output=True, text=True, timeout=10)
    assert rc.returncode == 0, f"check_resolvable failed: {rc.stdout}\n{rc.stderr}"

    # Inline-run skillify_check on ourselves to verify 9-item pass rate
    skillify_check_script = Path.home() / ".smartclaw" / "skills" / "skillify" / "scripts" / "skillify_check.py"
    if skillify_check_script.exists():
        rc = subprocess.run(
            [sys.executable, str(skillify_check_script), str(ROOT), "--repo-root", str(Path.home() / ".smartclaw")],
            capture_output=True, text=True, timeout=20,
        )
        assert rc.returncode == 0, f"skillify_check failed: {rc.stdout}\n{rc.stderr}"
        assert "score=7/9" in rc.stdout or "score=8/9" in rc.stdout or "score=9/9" in rc.stdout, \
            f"skillify_check did not reach the contract floor: {rc.stdout}"

    # Inline-run trigger_eval against the fixture to confirm every intent routes here
    trigger_eval_script = Path.home() / ".smartclaw" / "skills" / "skillify" / "scripts" / "trigger_eval.py"
    if trigger_eval_script.exists():
        rc = subprocess.run(
            [sys.executable, str(trigger_eval_script), "--fixture", str(ROOT / "routing-eval.jsonl")],
            capture_output=True, text=True, timeout=10,
        )
        assert rc.returncode == 0, f"trigger_eval failed: {rc.stdout}\n{rc.stderr}"

    stage("4. Puller script runs end-to-end")
    out_dir = Path("/tmp/time-spent-e2e")
    rc = subprocess.run(
        [sys.executable, str(SCRIPT), "--days", "14", "--out", str(out_dir)],
        capture_output=True, text=True, timeout=60,
    )
    assert rc.returncode == 0, f"puller failed: {rc.stderr}"
    jsons = sorted(out_dir.glob("time-spent-*.json"))
    assert jsons, "no JSON output"
    payload = json.loads(jsons[-1].read_text())

    stage("5. Output has all required sections")
    for key in ("window_days", "sources", "by_day", "by_channel",
                "headline_hours", "limitations"):
        assert key in payload, f"missing key: {key}"

    stage("6. All sources report a status (no silent drops)")
    for name, source in payload["sources"].items():
        assert "status" in source, f"{name} missing status"
        assert source["status"] in ("ok", "BLOCKED"), f"{name} invalid status"

    stage("7. Limitations are surfaced (≥ 5 entries)")
    assert len(payload["limitations"]) >= 5

    print("[E2E] all 7 stages passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())