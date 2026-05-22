"""Tests for cmux-terminal-review.sh — script-based cron job.

TDD: these tests define the contract BEFORE the fix is applied.
Current bugs:
  1. Schedule is 0,8,12,16,20 (5x/day) — should be every 4h
  2. Script path in jobs.json is 'scripts/cmux-terminal-review.sh'
     but hermes prepends scripts/ → resolves to scripts/scripts/... (404)
  3. Socket discovery only checks /private/tmp/cmux-debug-appclick.sock
     but current socket is /private/tmp/cmux-debug-may-18.sock
"""

import json
import os
import stat
import subprocess
import tempfile

import pytest


def _find_socket():
    """Find an active cmux socket in standard paths."""
    for d in ["/private/tmp", "/tmp"]:
        if os.path.isdir(d):
            for name in os.listdir(d):
                if name.startswith("cmux") and name.endswith(".sock"):
                    path = os.path.join(d, name)
                    if stat.S_ISSOCK(os.stat(path).st_mode):
                        return path
    return None

SCRIPT_STAGING = os.path.expanduser("~/.smartclaw/scripts/cmux-terminal-review.sh")
SCRIPT_PROD = os.path.expanduser("~/.smartclaw_prod/scripts/cmux-terminal-review.sh")
JOBS_JSON = os.path.expanduser("~/.smartclaw_prod/cron/jobs.json")


# ── Test 1: Script exists at both staging and prod paths ────────────

class TestScriptExists:
    def test_staging_script_exists(self):
        assert os.path.isfile(SCRIPT_STAGING), f"Staging script missing: {SCRIPT_STAGING}"

    def test_prod_script_exists(self):
        assert os.path.isfile(SCRIPT_PROD), f"Prod script missing: {SCRIPT_PROD}"

    def test_script_is_executable(self):
        assert os.access(SCRIPT_STAGING, os.X_OK), "Staging script not executable"


# ── Test 2: Script path in cron job resolves correctly ──────────────

class TestCronJobScriptPath:
    def test_no_double_scripts_prefix(self):
        """The 'script' field in jobs.json should NOT start with 'scripts/'
        because hermes already prepends scripts/ when resolving."""
        with open(JOBS_JSON) as f:
            data = json.load(f)
        jobs = data.get("jobs", data) if isinstance(data, dict) else data
        cmux_job = None
        for j in jobs:
            if isinstance(j, dict) and "cmux" in j.get("name", "").lower():
                cmux_job = j
                break
        assert cmux_job is not None, "cmux-status-system-tree job not found in jobs.json"

        script_field = cmux_job.get("script", "")
        # BUG: if script_field starts with "scripts/", hermes resolves it as
        # ~/.smartclaw_prod/scripts/scripts/... (double prefix)
        assert not script_field.startswith("scripts/"), (
            f"Script field '{script_field}' has double-prefix bug: "
            f"hermes prepends scripts/ → resolves to scripts/{script_field}. "
            f"Use 'cmux-terminal-review.sh' instead."
        )

    def test_script_field_resolves_to_real_file(self):
        """The resolved path (hermes_scripts_dir / script_field) must exist."""
        with open(JOBS_JSON) as f:
            data = json.load(f)
        jobs = data.get("jobs", data) if isinstance(data, dict) else data
        cmux_job = None
        for j in jobs:
            if isinstance(j, dict) and "cmux" in j.get("name", "").lower():
                cmux_job = j
                break

        script_field = cmux_job.get("script", "")
        scripts_dir = os.path.expanduser("~/.smartclaw_prod/scripts")
        resolved = os.path.join(scripts_dir, script_field)
        assert os.path.isfile(resolved), (
            f"Resolved script path does not exist: {resolved} "
            f"(script_field='{script_field}', scripts_dir='{scripts_dir}')"
        )


# ── Test 3: Schedule is every 4 hours ─────────────────────────────

class TestCronSchedule:
    def test_schedule_is_every_4h(self):
        """Schedule should be '0 */4 * * *' (every 4 hours)."""
        with open(JOBS_JSON) as f:
            data = json.load(f)
        jobs = data.get("jobs", data) if isinstance(data, dict) else data
        cmux_job = None
        for j in jobs:
            if isinstance(j, dict) and "cmux" in j.get("name", "").lower():
                cmux_job = j
                break
        assert cmux_job is not None

        schedule = cmux_job.get("schedule", {})
        expr = schedule.get("expr", "") if isinstance(schedule, dict) else str(schedule)
        assert expr == "0 */4 * * *", (
            f"Schedule is '{expr}', expected '0 */4 * * *' (every 4h). "
            f"Current schedule runs {self._count_daily_runs(expr)}x/day, want 6x/day."
        )

    @staticmethod
    def _count_daily_runs(expr: str) -> int:
        """Rough count of daily runs from cron expr."""
        # hour field is the 2nd component
        parts = expr.split()
        if len(parts) < 2:
            return -1
        hour_field = parts[1]
        if hour_field == "*":
            return 24
        if hour_field.startswith("*/"):
            step = int(hour_field[2:])
            return 24 // step
        # comma-separated
        return len(hour_field.split(","))


# ── Test 4: Socket discovery finds current socket ──────────────────

class TestSocketDiscovery:
    def test_discovers_may18_socket(self):
        """Script should discover /private/tmp/cmux-debug-may-18.sock."""
        # The script uses CMUX_SOCKET_DIRS for search paths
        # It should find any cmux*.sock in the search dirs
        result = subprocess.run(
            ["bash", SCRIPT_STAGING],
            capture_output=True, text=True, timeout=15,
            env={**os.environ, "CMUX_SOCKET_PATH": "", "CMUX_SOCKET_DIRS": "/private/tmp:/tmp"}
        )
        # Script should NOT exit with "no cmux socket found"
        assert "ERROR: no cmux socket found" not in result.stdout, (
            f"Socket discovery failed. stdout: {result.stdout[:200]}"
        )
        assert result.returncode == 0, f"Script exited {result.returncode}: {result.stderr[:200]}"

    def test_cmux_socket_path_env_override(self):
        """CMUX_SOCKET_PATH env var should skip discovery if valid."""
        # Find actual socket
        sockets = []
        for d in ["/private/tmp", "/tmp"]:
            for name in os.listdir(d) if os.path.isdir(d) else []:
                if name.startswith("cmux") and name.endswith(".sock"):
                    sockets.append(os.path.join(d, name))
        if not sockets:
            pytest.skip("No cmux socket found for live test")

        result = subprocess.run(
            ["bash", SCRIPT_STAGING],
            capture_output=True, text=True, timeout=15,
            env={**os.environ, "CMUX_SOCKET_PATH": sockets[0]}
        )
        assert result.returncode == 0, f"Script failed with explicit socket: {result.stderr[:200]}"
        assert "ERROR" not in result.stdout, f"Error in output: {result.stdout[:200]}"


# ── Test 5: Script output format ───────────────────────────────────

class TestScriptOutput:
    def test_output_has_required_sections(self):
        """Output must contain: Healthy, Risky, Blocked, Next actions."""
        socket = _find_socket()
        if not socket:
            pytest.skip("No cmux socket for live test")

        result = subprocess.run(
            ["bash", SCRIPT_STAGING],
            capture_output=True, text=True, timeout=30,
            env={**os.environ, "CMUX_SOCKET_PATH": socket}
        )
        assert result.returncode == 0, f"Script error: {result.stderr[:200]}"

        for section in ["Healthy", "Risky", "Blocked", "Next actions"]:
            assert section in result.stdout, f"Missing section: {section}"

    def test_output_contains_timestamp(self):
        """Output should include a timestamp."""
        socket = _find_socket()
        if not socket:
            pytest.skip("No cmux socket for live test")

        result = subprocess.run(
            ["bash", SCRIPT_STAGING],
            capture_output=True, text=True, timeout=30,
            env={**os.environ, "CMUX_SOCKET_PATH": socket}
        )
        assert "20" in result.stdout  # Year in timestamp (20xx)


# ── Test 6: Staging script is newer than prod (deploy hygiene) ──────

class TestDeployHygiene:
    def test_staging_newer_or_equal_to_prod(self):
        """Staging script should be >= prod (deploy pipeline flows staging→prod)."""
        if not os.path.isfile(SCRIPT_PROD):
            pytest.skip("Prod script not yet deployed")
        s_mtime = os.path.getmtime(SCRIPT_STAGING)
        p_mtime = os.path.getmtime(SCRIPT_PROD)
        # Allow 60s tolerance for deploy race
        assert s_mtime >= p_mtime - 60, (
            f"Staging is OLDER than prod: staging={s_mtime}, prod={p_mtime}. "
            f"Did you edit prod directly?"
        )
