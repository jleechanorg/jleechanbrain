from pathlib import Path
import subprocess
import pytest
import os
import shutil
import datetime

# Relative dates so fixtures never expire
_YESTERDAY = (datetime.date.today() - datetime.timedelta(days=1)).isoformat()
_TWO_DAYS_AGO = (datetime.date.today() - datetime.timedelta(days=2)).isoformat()

REPO_ROOT = Path(__file__).resolve().parents[1]
BUG_HUNT_SCRIPT = REPO_ROOT / "scripts" / "bug-hunt-daily.sh"
THREAD_NUDGE_SCRIPT = REPO_ROOT / "scripts" / "thread-reply-nudge.sh"


def read(path: Path) -> str:
    return path.read_text()


def test_changed_scripts_are_valid_bash() -> None:
    subprocess.run(["bash", "-n", str(BUG_HUNT_SCRIPT)], check=True)
    subprocess.run(["bash", "-n", str(THREAD_NUDGE_SCRIPT)], check=True)


def test_bug_hunt_uses_one_shot_hermes_not_fire_and_forget_ao() -> None:
    text = read(BUG_HUNT_SCRIPT)

    assert "ao spawn" not in text
    assert "ao send" not in text
    assert "hermes -z" in text
    assert "wait \"$FIX_PID\"" in text


def test_bug_hunt_watchdog_targets_resolved_process_group() -> None:
    text = read(BUG_HUNT_SCRIPT)

    assert "set -m" in text
    assert "shopt -s monitor" not in text
    assert "terminate_process_tree" in text
    assert "ps -o pgid= -p \"$pid\"" in text
    assert "kill -TERM \"-$pgid\"" in text


def test_bug_hunt_empty_agent_pid_array_is_safe_for_bash_32() -> None:
    text = read(BUG_HUNT_SCRIPT)

    assert 'if [ "${#AGENT_PIDS[@]}" -eq 0 ]; then' in text

    subprocess.run(
        [
            "/bin/bash",
            "-c",
            'set -euo pipefail; AGENT_PIDS=(); '
            'if [ "${#AGENT_PIDS[@]}" -eq 0 ]; then :; '
            'else for PID in "${AGENT_PIDS[@]}"; do :; done; fi',
        ],
        check=True,
    )


def test_bug_hunt_dedupe_jq_expression_compiles() -> None:
    expression = 'unique_by("\\(.repo)\\(.pr)\\(.file)\\(.line)\\(.description)")'
    sample = '[{"repo":"r","pr":1,"file":"f","line":2,"description":"d"}]'

    subprocess.run(["jq", expression], input=sample, text=True, check=True, capture_output=True)
    assert expression in read(BUG_HUNT_SCRIPT)


def test_thread_nudge_verifies_agent_subcommand_and_uses_message_flag() -> None:
    text = read(THREAD_NUDGE_SCRIPT)

    assert "hermes agent --help" in text
    assert "HERMES_HELP_TIMEOUT_SECONDS" in text
    assert 'agent_message_flag="--message"' in text
    assert "grep -q -- '--message'" in text
    assert "hermes agent --agent main \"$agent_message_flag\" \"$PROMPT\"" in text
    assert "hermes agent --agent main -m" not in text


@pytest.fixture
def temp_bin_dir(tmp_path):
    """Creates a temporary bin directory and adds it to PATH."""
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    
    # Mock curl to prevent outbound Slack/network requests in tests
    curl_mock = bin_dir / "curl"
    curl_mock.write_text(
        "#!/bin/sh\n"
        "if echo \"$@\" | grep -q \"slack.com/api\"; then\n"
        "  echo '{\"ok\": true}'\n"
        "  exit 0\n"
        "fi\n"
        "exec /usr/bin/curl \"$@\"\n"
    )
    curl_mock.chmod(0o755)

    original_path = os.environ.get("PATH", "")
    os.environ["PATH"] = f"{bin_dir}:{original_path}"
    
    yield bin_dir
    
    os.environ["PATH"] = original_path


def test_github_rate_limit_discovery_failure(temp_bin_dir, tmp_path) -> None:
    # Write mock gh failing with rate limit error
    gh_mock = temp_bin_dir / "gh"
    gh_mock.write_text(
        "#!/bin/sh\n"
        "echo 'GraphQL: API rate limit already exceeded for user ID 13840161' >&2\n"
        "exit 1\n"
    )
    gh_mock.chmod(0o755)

    # Write mock hermes
    hermes_mock = temp_bin_dir / "hermes"
    hermes_mock.write_text(
        "#!/bin/sh\n"
        "exit 0\n"
    )
    hermes_mock.chmod(0o755)
    
    # Mock gh-safe-publish
    publish_mock = temp_bin_dir / "gh-safe-publish"
    publish_mock.write_text("#!/bin/sh\nexit 0\n")
    publish_mock.chmod(0o755)

    # Run the daily bug hunt script
    reports_dir = tmp_path / "bug_reports"
    env = os.environ.copy()
    env["BUG_REPORTS_DIR"] = str(reports_dir)
    env["SLACK_USER_TOKEN"] = ""
    
    res = subprocess.run(
        ["bash", str(BUG_HUNT_SCRIPT)],
        env=env,
        capture_output=True,
        text=True
    )
    
    # Assert it failed closed and reported failure distinctly
    assert res.returncode == 1
    assert "Failed to discover PRs" in res.stdout or "Failed to discover PRs" in res.stderr
    assert "GraphQL: API rate limit already exceeded" in res.stdout or "GraphQL: API rate limit already exceeded" in res.stderr


def test_legitimate_zero_pr_input(temp_bin_dir, tmp_path) -> None:
    # Write mock gh returning empty PR list
    gh_mock = temp_bin_dir / "gh"
    gh_mock.write_text(
        "#!/bin/sh\n"
        "echo '[]'\n"
        "exit 0\n"
    )
    gh_mock.chmod(0o755)

    # Write mock hermes
    hermes_mock = temp_bin_dir / "hermes"
    hermes_mock.write_text(
        "#!/bin/sh\n"
        "exit 0\n"
    )
    hermes_mock.chmod(0o755)
    
    publish_mock = temp_bin_dir / "gh-safe-publish"
    publish_mock.write_text("#!/bin/sh\nexit 0\n")
    publish_mock.chmod(0o755)

    reports_dir = tmp_path / "bug_reports"
    env = os.environ.copy()
    env["BUG_REPORTS_DIR"] = str(reports_dir)
    env["SLACK_USER_TOKEN"] = ""
    
    res = subprocess.run(
        ["bash", str(BUG_HUNT_SCRIPT)],
        env=env,
        capture_output=True,
        text=True
    )
    
    # Assert it succeeded with no-input run
    assert res.returncode == 0
    assert "No PRs found to review." in res.stdout or "No PRs found to review." in res.stderr
    
    report_files = list(reports_dir.glob("bug-hunt-*.md"))
    assert len(report_files) == 1
    report_content = report_files[0].read_text()
    
    assert "- PRs reviewed: 0" in report_content
    assert "- Bugs found: 0" in report_content
    assert "- Agent failures: 0/0" in report_content


def test_prose_no_fence_output(temp_bin_dir, tmp_path) -> None:
    # Write mock gh returning PRs with a recent date (within 2-day lookback)
    gh_mock = temp_bin_dir / "gh"
    gh_mock.write_text(
        "#!/bin/sh\n"
        "echo '[{\"number\": 1, \"title\": \"test pr\", \"url\": \"http://example.com\", \"mergedAt\": \"" + _YESTERDAY + "\"}]'\n"
        "exit 0\n"
    )
    gh_mock.chmod(0o755)

    # Write mock hermes returning prose (no fence) for the main task
    hermes_mock = temp_bin_dir / "hermes"
    hermes_mock.write_text(
        "#!/bin/sh\n"
        "if [ \"$2\" = \"Hello\" ]; then\n"
        "  exit 0\n"
        "fi\n"
        "echo 'No merged PRs were provided to review (the list is empty)'\n"
        "exit 0\n"
    )
    hermes_mock.chmod(0o755)
    
    publish_mock = temp_bin_dir / "gh-safe-publish"
    publish_mock.write_text("#!/bin/sh\nexit 0\n")
    publish_mock.chmod(0o755)

    reports_dir = tmp_path / "bug_reports"
    env = os.environ.copy()
    env["BUG_REPORTS_DIR"] = str(reports_dir)
    env["SLACK_USER_TOKEN"] = ""
    
    res = subprocess.run(
        ["bash", str(BUG_HUNT_SCRIPT)],
        env=env,
        capture_output=True,
        text=True
    )
    
    # All chunks fail (prose, no fence) → script exits 2 (fail-closed)
    assert res.returncode in (0, 2), f"Unexpected RC {res.returncode}"
    assert "failed" in res.stdout
    
    report_files = list(reports_dir.glob("bug-hunt-*.md"))
    assert len(report_files) == 1
    report_content = report_files[0].read_text()
    
    assert "Chunk failures: 1/1" in report_content


def test_explicit_worker_routing(temp_bin_dir, tmp_path) -> None:
    import json as _j
    # 30 PRs → chunk_size=10 → 3 chunks → claude/gemini/minimax each get one chunk
    prs_30 = [
        {"number": i, "title": f"pr {i}", "url": f"http://example.com/{i}", "mergedAt": _YESTERDAY}
        for i in range(1, 31)
    ]
    gh_mock = temp_bin_dir / "gh"
    gh_mock.write_text(
        "#!/bin/sh\n"
        f"echo '{_j.dumps(prs_30)}'\n"
        "exit 0\n"
    )
    gh_mock.chmod(0o755)

    hermes_calls_log = tmp_path / "hermes_calls.log"
    hermes_mock = temp_bin_dir / "hermes"
    # Log AFTER the Hello-probe early return so preflight calls are not recorded.
    # This prevents the three-model assertion from passing via probe calls alone.
    # Log $4 (model: hermes -z <prompt> -m <model>) after probe guard — one line per worker call.
    hermes_mock.write_text(
        f"#!/bin/sh\n"
        "if [ \"$2\" = \"Hello\" ]; then exit 0; fi\n"
        f"echo \"$4\" >> {hermes_calls_log}\n"
        "echo '```json\n[]\n```'\n"
        "exit 0\n"
    )
    hermes_mock.chmod(0o755)

    publish_mock = temp_bin_dir / "gh-safe-publish"
    publish_mock.write_text("#!/bin/sh\nexit 0\n")
    publish_mock.chmod(0o755)

    reports_dir = tmp_path / "bug_reports"
    env = os.environ.copy()
    env["BUG_REPORTS_DIR"] = str(reports_dir)
    env["SLACK_USER_TOKEN"] = ""
    env["BUG_HUNT_DISABLE_RETRY"] = "1"
    env["BUG_HUNT_CHUNK_SIZE"] = "10"

    res = subprocess.run(
        ["bash", str(BUG_HUNT_SCRIPT)],
        env=env,
        capture_output=True,
        text=True
    )

    assert res.returncode == 0, f"script failed:\n{res.stdout[-500:]}"

    calls = hermes_calls_log.read_text().splitlines()
    # 4 repos × 30 PRs = 120 PRs; chunk_size=10 → 12 chunk workers, one model line each
    assert len(calls) == 12, f"Expected 12 chunk worker calls, got {len(calls)}: {calls[:5]}"
    # Round-robin across 3 agents: 4 calls each
    assert calls.count("anthropic/claude-3-5-haiku") == 4
    assert calls.count("agy-shim/gpt-oss-120b-medium") == 4
    assert calls.count("MiniMax-M3") == 4

def test_p1_p2_finding_triggers_fix_worker_with_selected_model(temp_bin_dir, tmp_path) -> None:
    """Regression: a P1/P2 finding must trigger `hermes -z ... -m <model>`.

    Previously, line 456 of `scripts/bug-hunt-daily.sh` used `local fix_model=...`
    at top level (outside any function). Bash rejects `local` outside a function,
    so with `set -e` the script aborted before launching the auto-fix agent
    whenever a P1/P2 bug was found. Green Gate #3 (CodeRabbit) flagged this.

    This test simulates a P1 finding and asserts:
    * the script exits 0 (no bash `local` error),
    * `hermes -z <FIX_TASK> -m <model>` is invoked with the first active
      agent's model.
    """
    text = read(BUG_HUNT_SCRIPT)
    # Hard guard: line 456 must NOT use `local` at top level.
    assert "local fix_model" not in text, (
        "scripts/bug-hunt-daily.sh still uses `local fix_model` at top level; "
        "with `set -e` this aborts the script when a P1/P2 bug is found."
    )

    log_path = str(tmp_path / "hermes_calls.log")

    # gh returns one merged PR.
    gh_mock = temp_bin_dir / "gh"
    gh_mock.write_text(
        "#!/bin/sh\n"
        "echo '[{\"number\": 1, \"title\": \"test pr\", \"url\": \"http://example.com\", \"mergedAt\": \"" + _YESTERDAY + "\"}]'\n"
        "exit 0\n"
    )
    gh_mock.chmod(0o755)

    # Define hermes executable. The stub configuration is written later in wrapper setup.
    hermes_mock = temp_bin_dir / "hermes"

    publish_mock = temp_bin_dir / "gh-safe-publish"
    publish_mock.write_text("#!/bin/sh\nexit 0\n")
    publish_mock.chmod(0o755)

    reports_dir = tmp_path / "bug_reports"
    env = os.environ.copy()
    env["BUG_REPORTS_DIR"] = str(reports_dir)
    env["SLACK_USER_TOKEN"] = ""
    env["BUG_HUNT_FIX_TIMEOUT_SECONDS"] = "5"

    # Inject the log path so the hermes stub can find it.
    env["HERMES_CALLS_LOG"] = log_path

    # Run with a wrapper that exports the log path so the stub script sees it.
    wrapper = tmp_path / "run.sh"
    wrapper.write_text(
        "#!/bin/sh\nexport HERMES_CALLS_LOG=\"$HERMES_CALLS_LOG\"\n"
        "exec bash \"" + str(BUG_HUNT_SCRIPT) + "\"\n"
    )
    wrapper.chmod(0o755)

    # Rewrite the hermes stub so it echoes "$@" to the log path (provided via env).
    hermes_mock.write_text(
        "#!/bin/sh\n"
        'echo "$@" >> "$HERMES_CALLS_LOG"\n'
        'if [ "$2" = "Hello" ]; then\n'
        "  exit 0\n"
        "fi\n"
        "echo '```json\n[{\"repo\":\"x\",\"pr\":1,\"file\":\"a.py\",\"line\":1,\"severity\":1,\"description\":\"p1\",\"suggested_fix\":\"fix\"}]\n```'\n"
        "exit 0\n"
    )
    hermes_mock.chmod(0o755)

    res = subprocess.run(
        ["bash", str(wrapper)],
        env=env,
        capture_output=True,
        text=True,
        timeout=60,
    )

    assert res.returncode == 0, (
        f"script exited {res.returncode}; stderr:\n{res.stderr[-2000:]}"
    )

    log_text = (tmp_path / "hermes_calls.log").read_text()
    # The mocked hermes stub echoes "$@" — the fix-task body is a single
    # multi-line arg that ends with `-m <model>`. Match the fix-task invocation
    # across the whole log, then verify the `-m` flag is present on that call.
    import re
    fix_calls = re.findall(r"-z Fix Bug from Bug Hunt:.*?(?=-z |\Z)", log_text, flags=re.DOTALL)
    assert fix_calls, (
        "fix worker was never invoked — script probably aborted before reaching "
        "the auto-fix section. Log:\n" + log_text
    )
    for call in fix_calls:
        assert re.search(r"\s-m\s+\S+", call), (
            f"fix worker invocation missing -m <model>: {call!r}"
        )
        # The selected model must be one of the configured AGENT_MODELS values.
        m = re.search(r"\s-m\s+(\S+)", call)
        # The active-agent list is built in order: claude, gemini, minimax.
        # With all three preflights passing, ACTIVE_AGENTS[0] is "claude",
        # so AGENT_MODELS["claude"] = "anthropic/claude-3-5-haiku" must be the
        # exact model routed to the fix worker. Asserting the literal value
        # (not a set) protects the requested first-active-agent routing behavior.
        assert m.group(1) == "anthropic/claude-3-5-haiku", (
            f"expected first-active model anthropic/claude-3-5-haiku, got {m.group(1)}"
        )


# ── NEW REGRESSION TESTS (2026-07-29 incident) ───────────────────────────────

def test_findings_use_slack_mrkdwn_link_format() -> None:
    """FINDINGS must use <url|text> not [text](url) to avoid url (url) duplication."""
    text = read(BUG_HUNT_SCRIPT)
    assert "<$pr_url|" in text or '<${pr_url}|' in text, (
        "FINDINGS must use Slack mrkdwn <url|label> format, not GitHub markdown [text](url)"
    )
    assert "[$REPO PR #$pr_num]($pr_url)" not in text, (
        "GitHub markdown [text](url) in FINDINGS causes url (url) duplication in Slack"
    )


def test_default_slack_channel_is_ai_general() -> None:
    """Bug-hunt reports must route to #ai-general (C0AJQ5M0A0Y), not #all-jleechan-ai."""
    text = read(BUG_HUNT_SCRIPT)
    assert "C0AJQ5M0A0Y" in text, (
        "Default Slack channel must be C0AJQ5M0A0Y (#ai-general), not ${SLACK_CHANNEL_ID}"
    )
    assert "${SLACK_CHANNEL_ID}" not in text, (
        "${SLACK_CHANNEL_ID} (#all-jleechan-ai) must not appear as a channel default"
    )


def test_agent_wait_uses_global_deadline_not_sequential() -> None:
    """All agent PIDs must be waited concurrently under one global deadline.

    July-29 incident: sequential per-PID watchdogs meant 3x10 min = 30 min worst-case.
    """
    text = read(BUG_HUNT_SCRIPT)
    assert "GLOBAL_DEADLINE" in text, (
        "Must use a GLOBAL deadline variable, not per-PID sequential watchdogs"
    )
    assert (
        'sleep "$TIMEOUT_SECONDS" && terminate_process_tree "$PID"' not in text
    ), (
        "Sequential per-PID watchdog still present — kills agents one at a time (max 30 min)"
    )


def test_pr_chunk_size_variable_exists() -> None:
    """Script must define BUG_HUNT_CHUNK_SIZE to bound monolithic prompts."""
    text = read(BUG_HUNT_SCRIPT)
    assert "BUG_HUNT_CHUNK_SIZE" in text, (
        "No BUG_HUNT_CHUNK_SIZE variable found; 32-PR monolithic prompts always time out"
    )


def test_large_pr_set_does_not_send_monolithic_prompt(temp_bin_dir, tmp_path) -> None:
    """Regression: with 32 PRs, no single hermes call gets more than BUG_HUNT_CHUNK_SIZE PRs."""
    import json as _json
    prs = [
        {"number": i, "title": f"pr {i}", "url": f"http://example.com/{i}", "mergedAt": _YESTERDAY}
        for i in range(1, 33)
    ]

    gh_mock = temp_bin_dir / "gh"
    gh_mock.write_text(
        "#!/bin/sh\n"
        f"echo '{_json.dumps(prs)}'\n"
        "exit 0\n"
    )
    gh_mock.chmod(0o755)

    max_chunk_file = tmp_path / "max_chunk.txt"
    hermes_mock = temp_bin_dir / "hermes"
    hermes_mock.write_text(
        "#!/bin/sh\n"
        'if [ "$2" = "Hello" ]; then exit 0; fi\n'
        f'count=$(echo "$@" | grep -o \'"number"\' | wc -l | tr -d " ")\n'
        f'prev=$(cat {max_chunk_file} 2>/dev/null || echo 0)\n'
        f'[ "$count" -gt "$prev" ] && echo "$count" > {max_chunk_file}\n'
        "echo '```json\n[]\n```'\n"
        "exit 0\n"
    )
    hermes_mock.chmod(0o755)

    publish_mock = temp_bin_dir / "gh-safe-publish"
    publish_mock.write_text("#!/bin/sh\nexit 0\n")
    publish_mock.chmod(0o755)

    reports_dir = tmp_path / "bug_reports"
    env = os.environ.copy()
    env["BUG_REPORTS_DIR"] = str(reports_dir)
    env["SLACK_USER_TOKEN"] = ""
    env["BUG_HUNT_DISABLE_RETRY"] = "1"
    env["BUG_HUNT_CHUNK_SIZE"] = "10"

    res = subprocess.run(
        ["bash", str(BUG_HUNT_SCRIPT)],
        env=env,
        capture_output=True,
        text=True,
        timeout=90,
    )
    assert res.returncode == 0, f"script failed:\n{res.stderr[-1000:]}"

    # max_chunk_file MUST exist: if hermes was never called with real PRs the chunking
    # is broken (e.g. early-exit before dispatch). Require existence unconditionally.
    assert max_chunk_file.exists(), (
        "hermes was never called with PR content — chunking loop did not fire. "
        f"stdout:\n{res.stdout[-500:]}"
    )
    max_count = int(max_chunk_file.read_text().strip())
    assert max_count <= 10, (
        f"Single hermes call received {max_count} PRs; must be ≤BUG_HUNT_CHUNK_SIZE(10). "
        "July-29 incident: 32-PR monolithic prompt always exceeded 10-min per-lane budget."
    )
    # Exact coverage: 4 repos × 32 PRs = 128, chunk_size=10 → 13 chunks must fire
    report_files = list(reports_dir.glob("bug-hunt-*.md"))
    assert report_files, "No report file generated"
    report_text = report_files[0].read_text()
    assert "Chunks dispatched: 13" in report_text, (
        f"Expected 13 chunks for 128 PRs at size 10; report:\n{report_text[-400:]}"
    )


def test_chunk_coverage_metadata_in_report(temp_bin_dir, tmp_path) -> None:
    """Report must record PRs-covered-per-chunk so incomplete runs are transparent."""
    import json as _json
    prs = [
        {"number": i, "title": f"pr {i}", "url": f"http://example.com/{i}", "mergedAt": _YESTERDAY}
        for i in range(1, 13)
    ]

    gh_mock = temp_bin_dir / "gh"
    gh_mock.write_text(
        "#!/bin/sh\n"
        f"echo '{_json.dumps(prs)}'\n"
        "exit 0\n"
    )
    gh_mock.chmod(0o755)

    hermes_mock = temp_bin_dir / "hermes"
    hermes_mock.write_text(
        "#!/bin/sh\n"
        'if [ "$2" = "Hello" ]; then exit 0; fi\n'
        "echo '```json\n[]\n```'\n"
        "exit 0\n"
    )
    hermes_mock.chmod(0o755)

    publish_mock = temp_bin_dir / "gh-safe-publish"
    publish_mock.write_text("#!/bin/sh\nexit 0\n")
    publish_mock.chmod(0o755)

    reports_dir = tmp_path / "bug_reports"
    env = os.environ.copy()
    env["BUG_REPORTS_DIR"] = str(reports_dir)
    env["SLACK_USER_TOKEN"] = ""
    env["BUG_HUNT_CHUNK_SIZE"] = "5"

    res = subprocess.run(
        ["bash", str(BUG_HUNT_SCRIPT)],
        env=env,
        capture_output=True,
        text=True,
        timeout=60,
    )
    assert res.returncode == 0, f"script failed:\n{res.stderr[-1000:]}"

    report_files = list(reports_dir.glob("bug-hunt-*.md"))
    assert report_files, "No report file generated"
    report_text = report_files[0].read_text()
    # Report must show total PRs reviewed so partial runs are observable
    assert "PRs discovered: 48" in report_text, (
        f"Report must state discovered count; got:\n{report_text[-500:]}"
    )


# ── BLOCKER REGRESSION TESTS ─────────────────────────────────────────────────

def _gh_mock(bin_dir, date, count=1, start=1):
    import json as _j
    prs = [{"number": start+i, "title": f"pr {start+i}", "url": f"http://ex/{start+i}", "mergedAt": date} for i in range(count)]
    p = bin_dir / "gh"
    p.write_text("#!/bin/sh\n" f"echo '{_j.dumps(prs)}'\n" "exit 0\n")
    p.chmod(0o755)


def _hermes_empty(bin_dir):
    p = bin_dir / "hermes"
    p.write_text("#!/bin/sh\n" 'if [ "$2" = "Hello" ]; then exit 0; fi\n' "echo '```json\n[]\n```'\n" "exit 0\n")
    p.chmod(0o755)


def _publish_mock(bin_dir):
    p = bin_dir / "gh-safe-publish"
    p.write_text("#!/bin/sh\nexit 0\n")
    p.chmod(0o755)


def test_results_loop_no_stale_agent_var() -> None:
    text = read(BUG_HUNT_SCRIPT)
    # After the chunk dispatch loop $AGENT is undefined; log messages in the
    # aggregation loop must reference $OUTPUT_FILE, not bare $AGENT.
    in_agg = False
    bad = []
    for line in text.splitlines():
        if "for OUTPUT_FILE in" in line and "CHUNK_OUTPUT_FILES" in line:
            in_agg = True
        if in_agg and ("log_warn" in line or "log_error" in line) and "$AGENT" in line and "ACTIVE_AGENTS" not in line:
            bad.append(line.strip())
    assert not bad, "Stale $AGENT in aggregation loop log messages:\n" + "\n".join(bad)


def test_disable_publish_skips_slack(temp_bin_dir, tmp_path) -> None:
    _gh_mock(temp_bin_dir, _YESTERDAY)
    _hermes_empty(temp_bin_dir)
    curl_log = tmp_path / "curl.log"
    curl_mock = temp_bin_dir / "curl"
    curl_mock.write_text("#!/bin/sh\n" f'echo "$@" >> {curl_log}\n' "echo '{\"ok\":true}'\n" "exit 0\n")
    curl_mock.chmod(0o755)
    p = temp_bin_dir / "gh-safe-publish"
    p.write_text("#!/bin/sh\nexit 0\n"); p.chmod(0o755)
    reports_dir = tmp_path / "r"
    env = os.environ.copy()
    env.update({"BUG_REPORTS_DIR": str(reports_dir), "SLACK_USER_TOKEN": "xoxp-real", "BUG_HUNT_DISABLE_PUBLISH": "1"})
    res = subprocess.run(["bash", str(BUG_HUNT_SCRIPT)], env=env, capture_output=True, text=True, timeout=60)
    assert res.returncode == 0
    if curl_log.exists():
        assert "slack.com" not in curl_log.read_text(), "curl hit Slack despite BUG_HUNT_DISABLE_PUBLISH=1"


def test_disable_fixes_skips_fix_agent(temp_bin_dir, tmp_path) -> None:
    _gh_mock(temp_bin_dir, _YESTERDAY)
    _publish_mock(temp_bin_dir)
    hlog = tmp_path / "h.log"
    h = temp_bin_dir / "hermes"
    h.write_text(
        "#!/bin/sh\n" f'echo "$@" >> {hlog}\n'
        'if [ "$2" = "Hello" ]; then exit 0; fi\n'
        "echo '```json\n[{\"repo\":\"x\",\"pr\":1,\"file\":\"a\",\"line\":1,\"severity\":1,\"description\":\"d\",\"suggested_fix\":\"s\"}]\n```'\n"
        "exit 0\n"
    )
    h.chmod(0o755)
    reports_dir = tmp_path / "r"
    env = os.environ.copy()
    env.update({"BUG_REPORTS_DIR": str(reports_dir), "SLACK_USER_TOKEN": "", "BUG_HUNT_DISABLE_FIXES": "1"})
    res = subprocess.run(["bash", str(BUG_HUNT_SCRIPT)], env=env, capture_output=True, text=True, timeout=60)
    assert res.returncode == 0
    fix_calls = [l for l in hlog.read_text().splitlines() if "Fix Bug from Bug Hunt" in l]
    assert not fix_calls, f"fix agent fired despite BUG_HUNT_DISABLE_FIXES=1: {fix_calls}"


def test_slack_auth_sends_real_token_in_header(temp_bin_dir, tmp_path) -> None:
    """With a real token, curl must receive that token (not *** or empty)."""
    _gh_mock(temp_bin_dir, _YESTERDAY)
    _hermes_empty(temp_bin_dir)
    curl_log = tmp_path / "curl.log"
    curl_mock = temp_bin_dir / "curl"
    curl_mock.write_text("#!/bin/sh\n" f'echo "$@" >> {curl_log}\n' "echo '{\"ok\":true}'\n" "exit 0\n")
    curl_mock.chmod(0o755)
    _publish_mock(temp_bin_dir)
    reports_dir = tmp_path / "r"
    env = os.environ.copy()
    env.update({"BUG_REPORTS_DIR": str(reports_dir), "SLACK_USER_TOKEN": "test-token"})
    res = subprocess.run(["bash", str(BUG_HUNT_SCRIPT)], env=env, capture_output=True, text=True, timeout=60)
    assert res.returncode == 0
    assert curl_log.exists(), "curl was never called — Slack post skipped with a real token"
    args = curl_log.read_text()
    assert "Authorization: Bearer test-token" in args, (
        f"Expected caller-provided token in curl args; got:\n{args[:500]}"
    )


def test_slack_auth_rejects_redacted_placeholder(temp_bin_dir, tmp_path) -> None:
    _gh_mock(temp_bin_dir, _YESTERDAY)
    _hermes_empty(temp_bin_dir)
    curl_log = tmp_path / "curl.log"
    curl_mock = temp_bin_dir / "curl"
    curl_mock.write_text("#!/bin/sh\n" f'echo "$@" >> {curl_log}\n' "echo '{\"ok\":true}'\n" "exit 0\n")
    curl_mock.chmod(0o755)
    _publish_mock(temp_bin_dir)
    reports_dir = tmp_path / "r"
    env = os.environ.copy()
    env.update({"BUG_REPORTS_DIR": str(reports_dir), "SLACK_USER_TOKEN": "***"})
    res = subprocess.run(["bash", str(BUG_HUNT_SCRIPT)], env=env, capture_output=True, text=True, timeout=60)
    assert res.returncode == 0
    if curl_log.exists():
        assert "Bearer ***" not in curl_log.read_text(), "Literal *** sent as Slack Bearer token"


def test_severity_zero_not_counted_as_bug(temp_bin_dir, tmp_path) -> None:
    _gh_mock(temp_bin_dir, _YESTERDAY)
    _publish_mock(temp_bin_dir)
    hlog = tmp_path / "h.log"
    h = temp_bin_dir / "hermes"
    h.write_text(
        "#!/bin/sh\n" f'echo "$@" >> {hlog}\n'
        'if [ "$2" = "Hello" ]; then exit 0; fi\n'
        "echo '```json\n[{\"repo\":\"x\",\"pr\":1,\"file\":\"\",\"line\":0,\"severity\":0,\"description\":\"no bugs\",\"suggested_fix\":\"\"}]\n```'\n"
        "exit 0\n"
    )
    h.chmod(0o755)
    reports_dir = tmp_path / "r"
    env = os.environ.copy()
    env.update({"BUG_REPORTS_DIR": str(reports_dir), "SLACK_USER_TOKEN": ""})
    res = subprocess.run(["bash", str(BUG_HUNT_SCRIPT)], env=env, capture_output=True, text=True, timeout=60)
    assert res.returncode == 0
    content = list(reports_dir.glob("bug-hunt-*.md"))[0].read_text()
    assert "Bugs found: 0" in content, f"severity=0 must not count as bug:\n{content[-300:]}"
    fix_calls = [l for l in hlog.read_text().splitlines() if "Fix Bug from Bug Hunt" in l]
    assert not fix_calls, "severity=0 must not trigger fix agent"


def test_discovered_vs_reviewed_in_report(temp_bin_dir, tmp_path) -> None:
    import json as _j, re
    # 20 PRs per repo → 80 discovered; first chunk fails → reviewed < discovered
    prs = [{"number": i, "title": f"pr {i}", "url": f"http://ex/{i}", "mergedAt": _YESTERDAY} for i in range(1, 21)]
    gh = temp_bin_dir / "gh"
    gh.write_text("#!/bin/sh\n" f"echo '{_j.dumps(prs)}'\n" "exit 0\n"); gh.chmod(0o755)
    _publish_mock(temp_bin_dir)
    cnt = tmp_path / "cnt.txt"
    h = temp_bin_dir / "hermes"
    h.write_text(
        "#!/bin/sh\n"
        'if [ "$2" = "Hello" ]; then exit 0; fi\n'
        f'n=$(cat {cnt} 2>/dev/null || echo 0); echo $((n+1)) > {cnt}\n'
        f'c=$(cat {cnt})\n'
        'if [ "$c" -eq 1 ]; then echo "error"; exit 1; fi\n'
        "echo '```json\n[]\n```'\n" "exit 0\n"
    )
    h.chmod(0o755)
    reports_dir = tmp_path / "r"
    env = os.environ.copy()
    env.update({
        "BUG_REPORTS_DIR": str(reports_dir),
        "SLACK_USER_TOKEN": "",
        "BUG_HUNT_CHUNK_SIZE": "10",
        "BUG_HUNT_DISABLE_RETRY": "1",
    })
    res = subprocess.run(["bash", str(BUG_HUNT_SCRIPT)], env=env, capture_output=True, text=True, timeout=90)
    assert res.returncode == 0
    content = list(reports_dir.glob("bug-hunt-*.md"))[0].read_text()
    assert "PRs discovered:" in content, f"Missing 'PRs discovered:' in:\n{content[-400:]}"
    assert "PRs reviewed:" in content, f"Missing 'PRs reviewed:' in:\n{content[-400:]}"
    disc = int(re.search(r"PRs discovered: (\d+)", content).group(1))
    rev = int(re.search(r"PRs reviewed: (\d+)", content).group(1))
    assert rev < disc, f"reviewed ({rev}) must be < discovered ({disc}) when a chunk fails"


def test_all_chunks_fail_returns_nonzero_exit(temp_bin_dir, tmp_path) -> None:
    """Script must exit nonzero (2) when every chunk produces 0-byte output."""
    import json as _j
    prs = [{"number": i, "title": f"pr {i}", "url": f"http://ex/{i}", "mergedAt": _YESTERDAY} for i in range(1, 6)]
    gh = temp_bin_dir / "gh"
    gh.write_text("#!/bin/sh\n" f"echo '{_j.dumps(prs)}'\n" "exit 0\n"); gh.chmod(0o755)
    _publish_mock(temp_bin_dir)
    # hermes passes preflight (Hello probe) but crashes on real tasks → 0-byte output
    h = temp_bin_dir / "hermes"
    h.write_text(
        "#!/bin/sh\n"
        'if [ "$2" = "Hello" ]; then exit 0; fi\n'
        "exit 1\n"
    )
    h.chmod(0o755)
    reports_dir = tmp_path / "r"
    env = os.environ.copy()
    env.update({
        "BUG_REPORTS_DIR": str(reports_dir),
        "SLACK_USER_TOKEN": "",
        "BUG_HUNT_DISABLE_PUBLISH": "1",
        "BUG_HUNT_DISABLE_FIXES": "1",
        "BUG_HUNT_CHUNK_SIZE": "5",
    })
    res = subprocess.run(["bash", str(BUG_HUNT_SCRIPT)], env=env, capture_output=True, text=True, timeout=60)
    assert res.returncode != 0, (
        f"Script must exit nonzero when all chunks fail; got RC={res.returncode}\n"
        f"stdout tail:\n{res.stdout[-500:]}"
    )


def test_chunk_exit_status_written_to_exit_file(temp_bin_dir, tmp_path) -> None:
    """When hermes exits nonzero, a .exit file must contain the nonzero code."""
    import json as _j
    prs = [{"number": 1, "title": "pr 1", "url": "http://ex/1", "mergedAt": _YESTERDAY}]
    gh = temp_bin_dir / "gh"
    gh.write_text("#!/bin/sh\n" f"echo '{_j.dumps(prs)}'\n" "exit 0\n"); gh.chmod(0o755)
    _publish_mock(temp_bin_dir)
    h = temp_bin_dir / "hermes"
    h.write_text(
        "#!/bin/sh\n"
        'if [ "$2" = "Hello" ]; then exit 0; fi\n'
        "exit 42\n"
    )
    h.chmod(0o755)
    reports_dir = tmp_path / "r"
    env = os.environ.copy()
    env.update({
        "BUG_REPORTS_DIR": str(reports_dir),
        "SLACK_USER_TOKEN": "",
        "BUG_HUNT_DISABLE_PUBLISH": "1",
        "BUG_HUNT_DISABLE_FIXES": "1",
        "BUG_HUNT_CHUNK_SIZE": "5",
    })
    subprocess.run(["bash", str(BUG_HUNT_SCRIPT)], env=env, capture_output=True, text=True, timeout=60)
    exit_files = list(reports_dir.glob("*.exit"))
    assert exit_files, "No .exit file written by chunk subshell"
    exit_code = exit_files[0].read_text().strip()
    assert exit_code == "42", f"Expected exit code 42 in .exit file, got: {exit_code!r}"


def test_summary_block_shows_discovered_and_reviewed_separately(temp_bin_dir, tmp_path) -> None:
    """Bottom summary must print PRs Discovered and PRs Reviewed on separate lines."""
    import json as _j
    prs = [{"number": i, "title": f"pr {i}", "url": f"http://ex/{i}", "mergedAt": _YESTERDAY} for i in range(1, 4)]
    gh = temp_bin_dir / "gh"
    gh.write_text("#!/bin/sh\n" f"echo '{_j.dumps(prs)}'\n" "exit 0\n"); gh.chmod(0o755)
    _publish_mock(temp_bin_dir)
    _hermes_empty(temp_bin_dir)
    reports_dir = tmp_path / "r"
    env = os.environ.copy()
    env.update({
        "BUG_REPORTS_DIR": str(reports_dir),
        "SLACK_USER_TOKEN": "",
        "BUG_HUNT_DISABLE_PUBLISH": "1",
        "BUG_HUNT_DISABLE_FIXES": "1",
    })
    res = subprocess.run(["bash", str(BUG_HUNT_SCRIPT)], env=env, capture_output=True, text=True, timeout=60)
    out = res.stdout
    assert "PRs Discovered:" in out, f"Missing 'PRs Discovered:' in stdout:\n{out[-600:]}"
    assert "PRs Reviewed:" in out, f"Missing 'PRs Reviewed:' in stdout:\n{out[-600:]}"
    # Must NOT conflate the two on one line
    for line in out.splitlines():
        assert not ("PRs Reviewed:" in line and "Discovered" in line), (
            f"Discovered/Reviewed conflated on one line: {line!r}"
        )


def test_retry_uses_proven_model_on_failed_chunks(temp_bin_dir, tmp_path) -> None:
    """Failed first-pass chunks are retried on the model that succeeded in the first pass.

    With chunk_size=2 and 3 PRs:
      chunk0 → claude  (anthropic/claude-3-5-haiku)  — fails (exit 1)
      chunk1 → gemini  (agy-shim/gpt-oss-120b-medium) — succeeds
    Retry must re-run chunk0 on the proven model (agy-shim/gpt-oss-120b-medium)
    and log exactly "Proven surviving model: agy-shim/gpt-oss-120b-medium".
    """
    import json as _j
    # Real configured model strings (must match AGENT_MODELS in the script)
    CLAUDE_MODEL = "anthropic/claude-3-5-haiku"
    GEMINI_MODEL = "agy-shim/gpt-oss-120b-medium"

    prs = [{"number": i, "title": f"pr {i}", "url": f"http://ex/{i}", "mergedAt": _YESTERDAY} for i in range(1, 4)]
    gh = temp_bin_dir / "gh"
    gh.write_text("#!/bin/sh\n" f"echo '{_j.dumps(prs)}'\n" "exit 0\n"); gh.chmod(0o755)
    _publish_mock(temp_bin_dir)

    calls_log = tmp_path / "calls.log"
    h = temp_bin_dir / "hermes"
    # $4 is the model arg (hermes -z <prompt> -m <model>).
    # Preflight Hello probes → exit 0 (all models available).
    # claude model → exit 1 to simulate timeout/failure.
    # gemini model (agy-shim/gpt-oss-120b-medium) → return empty JSON array (success).
    h.write_text(
        "#!/bin/sh\n"
        'if [ "$2" = "Hello" ]; then exit 0; fi\n'
        f'echo "$4" >> {calls_log}\n'
        f'if [ "$4" = "{GEMINI_MODEL}" ]; then\n'
        "  echo '```json\n[]\n```'\n"
        "  exit 0\n"
        "fi\n"
        "exit 1\n"
    )
    h.chmod(0o755)

    reports_dir = tmp_path / "r"
    env = os.environ.copy()
    env.update({
        "BUG_REPORTS_DIR": str(reports_dir),
        "SLACK_USER_TOKEN": "",
        "BUG_HUNT_DISABLE_PUBLISH": "1",
        "BUG_HUNT_DISABLE_FIXES": "1",
        "BUG_HUNT_CHUNK_SIZE": "2",
    })
    res = subprocess.run(["bash", str(BUG_HUNT_SCRIPT)], env=env, capture_output=True, text=True, timeout=90)
    out = res.stdout
    # Must log the exact proven-model line with the real model string
    assert f"Proven surviving model: {GEMINI_MODEL}" in out, (
        f"Expected 'Proven surviving model: {GEMINI_MODEL}' in stdout:\n{out[-600:]}"
    )
    # Retry must mention the proven model
    assert f"on proven model {GEMINI_MODEL}" in out, (
        f"Expected retry log referencing {GEMINI_MODEL}:\n{out[-600:]}"
    )
    # calls_log records every non-preflight hermes call; retry calls must include GEMINI_MODEL
    calls = calls_log.read_text().splitlines() if calls_log.exists() else []
    assert GEMINI_MODEL in calls, f"Proven model never called: {calls}"
    # Report must exist with reviewed count
    content = list(reports_dir.glob("bug-hunt-*.md"))[0].read_text()
    assert "PRs reviewed:" in content


def test_retry_integration_proven_model_used_for_all_retries(temp_bin_dir, tmp_path) -> None:
    """Integration: with 5 PRs and chunk_size=2 (3 chunks), chunks on claude and
    minimax fail; the gemini chunk succeeds; all 2 failed chunks retry on gemini.
    Asserts the exact proven-model log and that retry log lines reference gemini.
    """
    import json as _j
    CLAUDE_MODEL = "anthropic/claude-3-5-haiku"
    GEMINI_MODEL = "agy-shim/gpt-oss-120b-medium"
    MINIMAX_MODEL = "MiniMax-M3"

    prs = [{"number": i, "title": f"pr {i}", "url": f"http://ex/{i}", "mergedAt": _YESTERDAY} for i in range(1, 6)]
    gh = temp_bin_dir / "gh"
    gh.write_text("#!/bin/sh\n" f"echo '{_j.dumps(prs)}'\n" "exit 0\n"); gh.chmod(0o755)
    _publish_mock(temp_bin_dir)

    calls_log = tmp_path / "calls.log"
    h = temp_bin_dir / "hermes"
    h.write_text(
        "#!/bin/sh\n"
        'if [ "$2" = "Hello" ]; then exit 0; fi\n'
        f'echo "$4" >> {calls_log}\n'
        f'if [ "$4" = "{GEMINI_MODEL}" ]; then\n'
        "  echo '```json\n[]\n```'\n"
        "  exit 0\n"
        "fi\n"
        "exit 1\n"
    )
    h.chmod(0o755)

    reports_dir = tmp_path / "r"
    env = os.environ.copy()
    env.update({
        "BUG_REPORTS_DIR": str(reports_dir),
        "SLACK_USER_TOKEN": "",
        "BUG_HUNT_DISABLE_PUBLISH": "1",
        "BUG_HUNT_DISABLE_FIXES": "1",
        "BUG_HUNT_CHUNK_SIZE": "2",
    })
    res = subprocess.run(["bash", str(BUG_HUNT_SCRIPT)], env=env, capture_output=True, text=True, timeout=90)
    out = res.stdout

    # Exact proven-model log line
    assert f"Proven surviving model: {GEMINI_MODEL}" in out, (
        f"Expected proven-model log:\n{out[-700:]}"
    )
    # Both failed chunks must be retried on the gemini model
    retry_lines = [l for l in out.splitlines() if "on proven model" in l]
    assert len(retry_lines) >= 2, (
        f"Expected ≥2 retry log lines, got {len(retry_lines)}:\n{out[-700:]}"
    )
    for line in retry_lines:
        assert GEMINI_MODEL in line, f"Retry line references wrong model: {line!r}"

    # calls_log: first-pass calls use claude/gemini/minimax; retry calls must be gemini-only
    calls = calls_log.read_text().splitlines() if calls_log.exists() else []
    retry_calls = [c for c in calls if c == GEMINI_MODEL]
    # At least 3: 1 first-pass gemini success + 2 retries on gemini
    assert len(retry_calls) >= 3, (
        f"Expected ≥3 gemini calls (1 first-pass + 2 retries), got {len(retry_calls)}: {calls}"
    )


def test_retry_skipped_when_no_proven_model(temp_bin_dir, tmp_path) -> None:
    """When every chunk fails, retry is skipped with a warning (no proven model)."""
    import json as _j
    prs = [{"number": i, "title": f"pr {i}", "url": f"http://ex/{i}", "mergedAt": _YESTERDAY} for i in range(1, 4)]
    gh = temp_bin_dir / "gh"
    gh.write_text("#!/bin/sh\n" f"echo '{_j.dumps(prs)}'\n" "exit 0\n"); gh.chmod(0o755)
    _publish_mock(temp_bin_dir)
    h = temp_bin_dir / "hermes"
    h.write_text("#!/bin/sh\n" 'if [ "$2" = "Hello" ]; then exit 0; fi\n' "exit 1\n")
    h.chmod(0o755)
    reports_dir = tmp_path / "r"
    env = os.environ.copy()
    env.update({
        "BUG_REPORTS_DIR": str(reports_dir),
        "SLACK_USER_TOKEN": "",
        "BUG_HUNT_DISABLE_PUBLISH": "1",
        "BUG_HUNT_DISABLE_FIXES": "1",
        "BUG_HUNT_CHUNK_SIZE": "5",
    })
    res = subprocess.run(["bash", str(BUG_HUNT_SCRIPT)], env=env, capture_output=True, text=True, timeout=60)
    assert "No proven surviving model" in res.stdout, (
        f"Expected no-proven-model warning:\n{res.stdout[-400:]}"
    )
    assert res.returncode != 0, f"Expected nonzero exit when all chunks fail; got {res.returncode}"


def test_truncated_json_repaired_in_aggregation(temp_bin_dir, tmp_path) -> None:
    """When hermes produces truncated JSON (valid fence, cut-off array), the aggregation
    must repair it via Python and count the salvaged objects in PRs Reviewed."""
    import json as _j
    # 3 PRs → 1 chunk (chunk_size=5)
    prs = [{"number": i, "title": f"pr {i}", "url": f"http://ex/{i}", "mergedAt": _YESTERDAY} for i in range(1, 4)]
    gh = temp_bin_dir / "gh"
    gh.write_text("#!/bin/sh\n" f"echo '{_j.dumps(prs)}'\n" "exit 0\n"); gh.chmod(0o755)
    _publish_mock(temp_bin_dir)

    # hermes returns a truncated JSON array: two complete objects, then cut off mid-string
    truncated_json = '[{"repo":"r","pr":1,"file":"f","line":1,"severity":0,"description":"ok","suggested_fix":"","evidence":{"diff_excerpt":"","test_impact":"","reproduction_or_reasoning":""}},{"repo":"r","pr":2,"file":"f","line":2,"severity":0,"description":"truncated bu'
    h = temp_bin_dir / "hermes"
    h.write_text(
        "#!/bin/sh\n"
        'if [ "$2" = "Hello" ]; then exit 0; fi\n'
        f"echo '```json\n{truncated_json}\n```'\n"
        "exit 0\n"
    )
    h.chmod(0o755)

    reports_dir = tmp_path / "r"
    env = os.environ.copy()
    env.update({
        "BUG_REPORTS_DIR": str(reports_dir),
        "SLACK_USER_TOKEN": "",
        "BUG_HUNT_DISABLE_PUBLISH": "1",
        "BUG_HUNT_DISABLE_FIXES": "1",
        "BUG_HUNT_DISABLE_RETRY": "1",
        "BUG_HUNT_CHUNK_SIZE": "5",
    })
    res = subprocess.run(["bash", str(BUG_HUNT_SCRIPT)], env=env, capture_output=True, text=True, timeout=60)
    out = res.stdout
    # Repair warning must appear
    assert "repaired" in out.lower(), f"Expected repair log in stdout:\n{out[-600:]}"
    # At least 1 salvaged object → at least 1 PR reviewed
    content = list(reports_dir.glob("bug-hunt-*.md"))[0].read_text()
    rev = int(__import__("re").search(r"PRs reviewed: (\d+)", content).group(1))
    assert rev > 0, f"Expected reviewed > 0 after repair, got {rev}:\n{content[-300:]}"


def test_truncated_json_triggers_retry_on_proven_model(temp_bin_dir, tmp_path) -> None:
    """A non-empty but truncated JSON file must be queued for retry on the proven model,
    just like a 0-byte failure.  chunk0/claude → valid []; chunk1/gemini → truncated.
    Retry for chunk1 must run on claude (proven model) and produce full output."""
    import json as _j
    CLAUDE_MODEL = "anthropic/claude-3-5-haiku"
    GEMINI_MODEL = "agy-shim/gpt-oss-120b-medium"

    # 4 PRs, chunk_size=2 → chunk0 (claude, PRs 1-2), chunk1 (gemini, PRs 3-4)
    prs = [{"number": i, "title": f"pr {i}", "url": f"http://ex/{i}", "mergedAt": _YESTERDAY} for i in range(1, 5)]
    gh = temp_bin_dir / "gh"
    gh.write_text("#!/bin/sh\n" f"echo '{_j.dumps(prs)}'\n" "exit 0\n"); gh.chmod(0o755)
    _publish_mock(temp_bin_dir)

    calls_log = tmp_path / "calls.log"
    truncated = '[{"repo":"r","pr":3,"severity":0,"file":"f","line":1,"description":"ok","suggested_fix":"","evidence":{"diff_excerpt":"","test_impact":"","reproduction_or_reasoning":""}},{"repo":"r","pr":4,"severity":0,"description":"cut'
    h = temp_bin_dir / "hermes"
    h.write_text(
        "#!/bin/sh\n"
        'if [ "$2" = "Hello" ]; then exit 0; fi\n'
        f'echo "$4" >> {calls_log}\n'
        # gemini → truncated JSON on first call; claude → valid [] always
        f'if [ "$4" = "{GEMINI_MODEL}" ]; then\n'
        f"  echo '```json\n{truncated}\n```'\n"
        "  exit 0\n"
        "fi\n"
        "echo '```json\n[]\n```'\n"
        "exit 0\n"
    )
    h.chmod(0o755)

    reports_dir = tmp_path / "r"
    env = os.environ.copy()
    env.update({
        "BUG_REPORTS_DIR": str(reports_dir),
        "SLACK_USER_TOKEN": "",
        "BUG_HUNT_DISABLE_PUBLISH": "1",
        "BUG_HUNT_DISABLE_FIXES": "1",
        "BUG_HUNT_CHUNK_SIZE": "2",
    })
    res = subprocess.run(["bash", str(BUG_HUNT_SCRIPT)], env=env, capture_output=True, text=True, timeout=90)
    out = res.stdout
    # Proven model must be claude (first valid-JSON chunk)
    assert f"Proven surviving model: {CLAUDE_MODEL}" in out, (
        f"Expected claude as proven model:\n{out[-700:]}"
    )
    # Truncated chunk must be queued for retry
    assert "truncated" in out.lower(), f"Expected truncated-JSON warning:\n{out[-700:]}"
    # Retry must run on claude (proven model)
    assert f"on proven model {CLAUDE_MODEL}" in out, (
        f"Expected retry referencing {CLAUDE_MODEL}:\n{out[-700:]}"
    )
    # After retry with valid claude output, all PRs must be reviewed.
    # gh mock returns 4 PRs per repo × 4 repos = 16 total.
    content = list(reports_dir.glob("bug-hunt-*.md"))[0].read_text()
    rev = int(__import__("re").search(r"PRs reviewed: (\d+)", content).group(1))
    total_prs = len(prs) * 4  # 4 repos in script REPOS list
    assert rev == total_prs, f"Expected all {total_prs} PRs reviewed after retry, got {rev}:\n{content[-300:]}"
