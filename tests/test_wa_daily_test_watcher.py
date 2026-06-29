from pathlib import Path
import subprocess

REPO_ROOT = Path(__file__).resolve().parents[1]
WATCHER_SCRIPT = REPO_ROOT / "scripts" / "wa_daily_test_watcher.sh"

def read_script() -> str:
    return WATCHER_SCRIPT.read_text()

def test_watcher_is_valid_bash() -> None:
    subprocess.run(["bash", "-n", str(WATCHER_SCRIPT)], check=True)

def test_watcher_uses_quoted_heredoc() -> None:
    text = read_script()
    # Ensure heredoc delimiter is quoted to prevent Bash from evaluating backticks
    assert "<<'PYEOF'" in text
    assert "<<PYEOF" not in text

def test_watcher_uses_shutil_which_for_gog() -> None:
    text = read_script()
    # Python code should use shutil.which instead of running shell builtin "command"
    assert "shutil.which" in text
    assert "subprocess.run([\"command\", \"-v\", \"gog\"]" not in text

def test_watcher_handles_unknown_status_explicitly() -> None:
    text = read_script()
    # It should not treat UNKNOWN status as PASS
    assert 'status == "UNKNOWN"' in text or 'status_match is None' in text or 'sys.exit(1)' in text
    assert 'elif status == "PASS":' in text or 'elif status == \'PASS\':' in text

def test_watcher_handles_invalid_json() -> None:
    text = read_script()
    # It should try/except json.loads
    assert 'try:' in text and 'json.loads(raw)' in text

def test_watcher_handles_empty_threads_with_slack_notice() -> None:
    text = read_script()
    # It should not exit silently on empty threads
    assert 'print("no_threads_in_response")' not in text
    assert 'post_slack(channel, msg)' in text or 'post_slack(channel, err_msg)' in text

def test_error_handling_does_not_overwrite_success_marker() -> None:
    text = read_script()
    # It should check marker.exists() and exit rather than checking == "ERROR"
    assert 'if marker.exists() and marker.read_text().strip() == "ERROR":' not in text

def test_empty_threads_writes_marker() -> None:
    text = read_script()
    # It should write a marker when empty threads are posted
    assert 'write_marker(marker, "EMPTY")' in text

def test_watcher_marker_specific_comparisons() -> None:
    text = read_script()
    # Ensure JSON parse, empty thread, and UNKNOWN status check specific marker values
    assert 'in ("ERROR", "PASS", "FAIL")' in text
    assert 'in ("EMPTY", "PASS", "FAIL")' in text

def test_no_unmarked_empty_alert_path() -> None:
    text = read_script()
    # The old, duplicate-prone bash-level alert path should be removed in favor of the unified idempotent python path
    assert "No '[GCP Cron] Daily Level Up Test' email found for" not in text

def test_watcher_checks_level_up_and_dice_subjects() -> None:
    text = read_script()
    assert '"display": "Daily Level Up Test"' in text
    assert '"subject": "[GCP Cron] Daily Level Up Test"' in text
    assert '"work_prefix": "daily-scheduled"' in text
    assert '"display": "Daily Dice Audit"' in text
    assert '"subject": "[GCP Cron] Daily Dice Audit"' in text
    assert '"work_prefix": "daily-dice-audit"' in text

def test_markers_are_namespaced_per_daily_job() -> None:
    text = read_script()
    assert 'def marker_path(job_key, marker_date):' in text
    assert 'pathlib.Path(marker_dir) / job_key / f"{marker_date}.posted"' in text
    assert 'marker_path(job["key"], run_date)' in text

def test_watcher_supports_no_slack_dry_run() -> None:
    text = read_script()
    assert "WA_DAILY_TEST_WATCHER_DRY_RUN" in text
    assert "dry_run_slack_post" in text
    assert "dry_run_marker" in text


def test_watcher_drops_legacy_flat_marker_path() -> None:
    text = read_script()
    # PR #655 removal: pre-multijob flat markers are no longer honored.
    # Multijob deploy (#645) has been live long enough that any flat marker
    # is stale. The script must rely solely on namespaced markers
    # (~/.cache/wa_daily_test_watcher/<job_key>/<date>.posted).
    assert "def legacy_marker_path(" not in text
    assert "def legacy_already_posted(" not in text
    assert "def clear_legacy_marker(" not in text
    assert "legacy_already_posted(" not in text
    assert "clear_legacy_marker(" not in text
    assert "already_posted_legacy" not in text
    assert "legacy_marker_hit" not in text
    assert "legacy_marker_cleared" not in text
    assert "dry_run_clear_legacy" not in text
    # Idempotency must come from the namespaced marker path only.
    assert 'pathlib.Path(marker_dir) / job_key / f"{marker_date}.posted"' in text
