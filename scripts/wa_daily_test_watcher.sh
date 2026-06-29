#!/usr/bin/env bash
# wa_daily_test_watcher.sh
# Reads the latest WorldArchitect daily GCP cron report emails and posts structured
# pass/fail notices in #worldai. Cron-driven; safe to re-run (idempotent per job/date).
#
# Behavior:
#   1. Search Gmail for the most recent daily level-up and daily dice audit emails
#   2. Extract: date, scenario pass/fail list, GCP log links, GCS evidence path
#   3. Post PASS and FAIL summaries for both jobs
#   4. Idempotent: keyed off job + email run_date so we don't double-post the same run
#
# Args (env): SLACK_CHANNEL (default C0AH3RY3DK6 = #worldai)

set -euo pipefail

CHANNEL="${SLACK_CHANNEL:-C0AH3RY3DK6}"

# Load environment using shared loader
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
if [ -f "$REPO_ROOT/lib/gog-env.sh" ]; then
  source "$REPO_ROOT/lib/gog-env.sh"
  if declare -F load_gog_env_from_hermes >/dev/null; then
    load_gog_env_from_hermes
  fi
fi

# Source slack_thread_lib.sh so the Python post_slack helper shells out to the
# shared lib instead of calling chat.postMessage directly at channel root.
# bead jleechan-ry3y follow-up to PR #615. The lib threads each cronjob post
# under a per-job daily anchor and dedupes identical text within 60s.
LIB_DIR="$REPO_ROOT/lib"
# shellcheck source=lib/slack_thread_lib.sh
source "$LIB_DIR/slack_thread_lib.sh"

# Fallback defaults for environment secrets/identifiers
export GOG_KEYRING_PASSWORD="${GOG_KEYRING_PASSWORD:-hermes-gog-2026}"
export GOOGLE_CLOUD_PROJECT="${GOOGLE_CLOUD_PROJECT:-infinite-zephyr-487405-d0}"

# Idempotency hardening (closes jleechanbrain#599 — duplicate "could not parse
# failed scenario list" cron alerts flooding #worldai):
#   1. flock -n ensures concurrent runs of this script are no-ops, not dueling posts
#   2. The Python heredocs are quoted (<<'PYEOF') below so bash does not evaluate
#      backticks or other command substitutions. Variables are passed via env.
LOCK_FILE="/tmp/wa_daily_test_watcher.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "another instance of $0 is running; exiting"
  exit 0
fi
TODAY="$(date -u +%Y-%m-%d)"
GOG="$(command -v gog || echo /opt/homebrew/bin/gog)"

# Idempotency: marker is keyed on the email's run_date (parsed from subject),
# NOT today. This means a 12h polling schedule can run multiple times per day
# but only post once per GCP test run.
MARKER_DIR="${HOME}/.cache/wa_daily_test_watcher"
DRY_RUN="${WA_DAILY_TEST_WATCHER_DRY_RUN:-0}"

# 2. Parse out subject + body
export CHANNEL
export TODAY
export MARKER_DIR
export GOG_KEYRING_PASSWORD
export GOG_BIN="$GOG"
export WA_DAILY_TEST_WATCHER_DRY_RUN="$DRY_RUN"

python3 - <<'PYEOF'
import json, os, re, subprocess, sys, urllib.request, shutil, pathlib

channel = os.environ.get("CHANNEL", "")
today = os.environ.get("TODAY", "")
marker_dir = os.environ.get("MARKER_DIR", os.path.expanduser("~/.cache/wa_daily_test_watcher"))
gog_bin = os.environ.get("GOG_BIN") or shutil.which("gog") or "/opt/homebrew/bin/gog"
dry_run = os.environ.get("WA_DAILY_TEST_WATCHER_DRY_RUN", "0") == "1"

JOBS = [
    {
        "key": "level-up",
        "display": "Daily Level Up Test",
        "subject": "[GCP Cron] Daily Level Up Test",
        "work_prefix": "daily-scheduled",
        "execution_prefix": "wa-daily-level-up-test",
        "evidence_fallback": "gs://wa-test-evidence/daily/<unknown>",
    },
    {
        "key": "dice",
        "display": "Daily Dice Audit",
        "subject": "[GCP Cron] Daily Dice Audit",
        "work_prefix": "daily-dice-audit",
        "execution_prefix": "wa-daily-dice-audit",
        "evidence_fallback": "gs://wa-test-evidence/daily-dice-audit/<unknown>",
    },
]

def post_slack(channel, text):
    if dry_run:
        print(f"dry_run_slack_post:{channel}:{text[:160]}")
        return True

    # Shell out to the bash slack_thread_lib.sh so the post threads under a
    # per-job daily anchor (var/slack/wa-daily-test-watcher/) instead of going
    # to channel root. The lib dedupes identical text within 60s and resolves
    # the channel via HERMES_OPS_SLACK_CHANNEL env first, --channel arg second.
    # bead jleechan-ry3y follow-up to PR #615.
    try:
        # Find the lib path relative to this script so the helper is locatable
        # from both staging and production checkouts.
        lib_path = os.path.expanduser("~/.smartclaw/lib/slack_thread_lib.sh")
        if not os.path.exists(lib_path):
            # Fallback: walk up from CWD looking for the lib (worktree safety).
            for candidate in [
                os.path.expanduser("~/.smartclaw/lib/slack_thread_lib.sh"),
                "${HOME}/.smartclaw/lib/slack_thread_lib.sh",
            ]:
                if os.path.exists(candidate):
                    lib_path = candidate
                    break
        # Use SLACK_BOT_TOKEN if present; otherwise leave env alone and
        # let the lib fall through to its own ~/.bashrc/.profile resolution.
        # The bash source and the slack_post call happen in the same bash -c
        # invocation so the sourced functions are in scope for the slack_post call.
        result = subprocess.run(
            ["bash", "-c",
             f'source "{lib_path}" >/dev/null 2>&1 && '
             f'slack_post "wa-daily-test-watcher" "$0" --channel "$1" --force',
             text, channel],
            capture_output=True, text=True, timeout=15,
            env={**os.environ},
        )
        # The lib writes "slack_post[job]: ok channel=... ts=..." to stderr on
        # success. Anything other than empty stderr plus a zero exit code means
        # a real failure; treat non-zero exit as failure.
        if result.returncode != 0:
            print(f"slack_post: non-zero exit {result.returncode}: {result.stderr.strip()}", file=sys.stderr)
            return False
        # The lib may also legitimately skip (e.g. dedupe hit, missing token).
        # In those cases the lib still returns 0; we treat any 0 exit as success.
        if "Slack API error" in result.stderr or "curl returned empty" in result.stderr:
            print(f"slack_post: {result.stderr.strip()}", file=sys.stderr)
            return False
        return True
    except subprocess.TimeoutExpired:
        print("slack_post: timeout (>15s)", file=sys.stderr)
        return False
    except Exception as e:
        print(f"Error posting to Slack via slack_thread_lib: {e}", file=sys.stderr)
        return False

def marker_path(job_key, marker_date):
    return pathlib.Path(marker_dir) / job_key / f"{marker_date}.posted"

def write_marker(marker, status):
    if dry_run:
        print(f"dry_run_marker:{marker}:{status}")
        return
    marker.parent.mkdir(parents=True, exist_ok=True)
    marker.write_text(status)
    print(f"marker_written:{marker}:{status}")

def fetch_raw(job):
    fixture_dir = os.environ.get("WA_DAILY_TEST_WATCHER_FIXTURE_DIR")
    if fixture_dir:
        fixture = pathlib.Path(fixture_dir) / f"{job['key']}.json"
        if fixture.exists():
            return fixture.read_text()

    query = f'subject:"{job["subject"]}" newer_than:36h'
    proc = subprocess.run(
        [gog_bin, "gmail", "search", query, "--max", "1", "--no-input", "--json"],
        env={**os.environ, "GOG_KEYRING_PASSWORD": os.environ.get("GOG_KEYRING_PASSWORD", "hermes-gog-2026")},
        capture_output=True,
        text=True,
        timeout=20,
    )
    if proc.returncode != 0:
        print(f"gog search failed for {job['display']}: {proc.stderr.strip()}", file=sys.stderr)
        return ""
    return proc.stdout

def parse_threads(raw):
    threads = []
    if raw and raw.strip() not in ("null", "[]"):
        data = json.loads(raw)
        if isinstance(data, dict):
            threads = data.get("threads", data.get("messages", []))
        elif isinstance(data, list):
            threads = data
    return threads

def fetch_body(msg_id, message):
    body = message.get("body", message.get("snippet", ""))
    if body or not msg_id:
        return body
    try:
        body_proc = subprocess.run(
            [gog_bin, "gmail", "get", msg_id, "--no-input"],
            env={**os.environ, "GOG_KEYRING_PASSWORD": os.environ.get("GOG_KEYRING_PASSWORD", "hermes-gog-2026")},
            capture_output=True, text=True, timeout=15
        )
        return body_proc.stdout[:20000]  # cap — email bodies can be 15K+
    except Exception as e:
        return f"(body fetch failed: {e})"

def process_job(job):
    raw = fetch_raw(job)
    threads = []
    try:
        threads = parse_threads(raw)
    except Exception as e:
        # Idempotency check for JSON parse errors (key: today, status: ERROR)
        marker = marker_path(job["key"], today)
        if marker.exists() and marker.read_text().strip() in ("ERROR", "PASS", "FAIL"):
            print(f"already_posted:{job['key']}:{today}:{marker.read_text().strip()}")
            return 0
        
        err_msg = f":warning: *{job['display']} Watcher Error* — Failed to parse JSON response from gog: {e}\nRaw stdout: `{raw[:500]}`"
        print(err_msg, file=sys.stderr)
        if post_slack(channel, err_msg):
            write_marker(marker, "ERROR")
        return 1

    if not threads:
        marker = marker_path(job["key"], today)
        if marker.exists() and marker.read_text().strip() in ("EMPTY", "PASS", "FAIL"):
            print(f"already_posted:{job['key']}:{today}:{marker.read_text().strip()}")
            return 0
    
        msg = f":mag: No '{job['subject']}' email threads found for {today}. Test may not have run yet, or subject line changed."
        print(msg)
        if post_slack(channel, msg):
            write_marker(marker, "EMPTY")
        return 0

    m = threads[0]
    subject = m.get("subject", "")
    msg_id = m.get("id", "")
    # Subject format examples:
    #   [GCP Cron] Daily Level Up Test - FAIL (daily-scheduled-YYYY-MM-DD)
    #   [GCP Cron] Daily Dice Audit - PASS (daily-dice-audit-YYYY-MM-DD)
    status_match = re.search(
        rf"- (PASS|FAIL) \({re.escape(job['work_prefix'])}-(\d{{4}}-\d{{2}}-\d{{2}})\)",
        subject,
    )
    status = status_match.group(1) if status_match else "UNKNOWN"
    run_date = status_match.group(2) if status_match else today

    if status == "UNKNOWN":
        # Idempotency check for unparseable subjects (key: run_date, status: ERROR)
        marker = marker_path(job["key"], run_date)
        if marker.exists() and marker.read_text().strip() in ("ERROR", "PASS", "FAIL"):
            print(f"already_posted:{job['key']}:{run_date}:{marker.read_text().strip()}")
            return 0
    
        err_msg = f":warning: *{job['display']} Watcher Parsing Failed* — Could not parse status/date from subject: `{subject}`"
        print(err_msg, file=sys.stderr)
        if post_slack(channel, err_msg):
            write_marker(marker, "ERROR")
        return 1

    # Skip if we already processed this run
    marker = marker_path(job["key"], run_date)
    if marker.exists() and marker.read_text().strip() == status:
        print(f"already_posted:{job['key']}:{run_date}:{status}")
        return 0

    # Best-effort body fetch (gog's search response has no body, so we re-fetch the message)
    body = fetch_body(msg_id, m)

    # We need scenario results + log links — body is usually truncated, so use snippet
    # which is enough for the summary line
    exec_match = re.search(rf"Execution:\s+({re.escape(job['execution_prefix'])}-\S+)", body)
    gcs_match = re.search(r"GCS Path:\s+(gs://\S+)", body)
    # Email uses "=== Scenarios: 6/8 passed" (legacy) OR "=== Results: 6/8 passed"
    # (current template, changed ~2026-06-15) then bracketed [PASS]/[FAIL] lines.
    # Capture everything between that header and the next === divider / Log Tail.
    scenarios_match = re.search(
        r"===\s*(?:Scenarios|Results):\s*([\d/]+\s+passed)\b([\s\S]*?)(?:={3,}|Log Tail|last \d+ lines:)",
        body
    )

    if not exec_match:
        print(f"WARNING: {job['key']} exec_match failed. Body snippet: {body[:200]}", file=sys.stderr)
    if not gcs_match:
        print(f"WARNING: {job['key']} gcs_match failed. Body snippet: {body[:200]}", file=sys.stderr)
    if not scenarios_match:
        print(f"WARNING: {job['key']} scenarios_match failed. Body snippet: {body[:200]}", file=sys.stderr)

    execution = exec_match.group(1) if exec_match else "unknown-execution"
    gcs_path = gcs_match.group(1) if gcs_match else job["evidence_fallback"]
    passed_str = scenarios_match.group(1) if scenarios_match else "?"
    scenario_block = (scenarios_match.group(2) or "").strip() if scenarios_match else ""

    # Build Slack message
    if status == "FAIL":
        # Extract just the FAILED scenario lines
        failed_lines = []
        for line in scenario_block.splitlines():
            if "FAIL" in line:
                failed_lines.append(line.strip())

        # Belt-and-suspenders backstop: if the structured header is missing or the
        # scenario block was truncated, scan the FULL body for [FAIL] markers so a
        # future template drift never silently drops the failed-scenario list again.
        if not failed_lines:
            for line in body.splitlines():
                stripped = line.strip()
                if re.match(r"^\s*\[FAIL\]", stripped):
                    failed_lines.append(stripped)

        if not failed_lines:
            failed_lines = ["(could not parse failed scenario list from email body)"]
        failed_summary = "\n".join(f"• `{ln[:240]}`" for ln in failed_lines[:6])

        text = (
            f":rotating_light: *{job['display']} FAILED* — {run_date}\n"
            f"_{passed_str}_\n\n"
            f"*Failed scenarios:*\n{failed_summary}\n\n"
            f"*Evidence:* `{gcs_path}`\n"
            f"*Execution:* `{execution}`\n\n"
            f"<@U09GH5BR3QU> please investigate. <@Hermes>: read this thread, "
            f"fetch the GCS evidence, and propose (or spawn an AO worker for) a fix."
        )
    elif status == "PASS":
        text = (
            f":white_check_mark: *{job['display']} PASSED* — {run_date} "
            f"({passed_str}). Evidence: `{gcs_path}`"
        )
    else:
        return 1

    if post_slack(channel, text):
        # Mark as posted for idempotency only if posting succeeded
        write_marker(marker, status)
        return 0
    return 1

exit_code = 0
for job in JOBS:
    rc = process_job(job)
    if rc != 0:
        exit_code = rc
sys.exit(exit_code)
PYEOF
