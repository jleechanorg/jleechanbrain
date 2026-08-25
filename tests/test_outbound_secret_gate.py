from __future__ import annotations

import importlib.util
import os
from pathlib import Path
import re
import subprocess
import sys

import pytest


REPO_ROOT = Path(__file__).resolve().parents[1]
GATE_MODULE = REPO_ROOT / "lib" / "outbound_secret_gate.py"
GH_PUBLISH = REPO_ROOT / "scripts" / "gh-safe-publish"
SLACK_LIB = REPO_ROOT / "lib" / "slack_thread_lib.sh"
SECONDARY_SLACK_LIB = REPO_ROOT / "scripts" / "lib-slack-post.sh"
ROADMAP_REPORT = REPO_ROOT / "scripts" / "slack-thread-roadmap-report.sh"
SOUL = REPO_ROOT / "SOUL.md"
AUTOMATION_PUBLISHERS = (
    REPO_ROOT / "scripts" / "harness-analyzer.sh",
    REPO_ROOT / "scripts" / "commit-pending-changes.sh",
    REPO_ROOT / "scripts" / "simplify-daily.sh",
    REPO_ROOT / "scripts" / "bug-hunt-daily.sh",
    REPO_ROOT / "scripts" / "sync-to-smartclaw.sh",
)
GITHUB_PUBLISH_GUIDANCE = (
    REPO_ROOT / "skills" / "github" / "github-issues" / "SKILL.md",
    REPO_ROOT / "skills" / "github" / "github-pr-workflow" / "SKILL.md",
    REPO_ROOT / "skills" / "dispatch-task" / "SKILL.md",
    REPO_ROOT / "skills" / "write-goal" / "SKILL.md",
    REPO_ROOT / ".claude" / "commands" / "coderabbit.md",
    REPO_ROOT / ".claude" / "commands" / "evidence_review.md",
)


def synthetic_github_token(prefix: str = "ghp_") -> str:
    return prefix + ("A" * 36)


def synthetic_slack_token(prefix: str = "xoxb-") -> str:
    return prefix + ("1" * 12) + "-" + ("B" * 24)


@pytest.fixture(scope="module")
def gate_module():
    spec = importlib.util.spec_from_file_location("outbound_secret_gate", GATE_MODULE)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.mark.parametrize("prefix", ["ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_"])
def test_detects_supported_github_token_families(gate_module, prefix: str) -> None:
    findings = gate_module.find_secrets(f"credential={synthetic_github_token(prefix)}")
    assert len(findings) == 1
    assert findings[0].kind == "github-token"


@pytest.mark.parametrize("prefix", ["xoxb-", "xoxa-", "xoxp-", "xoxr-", "xoxs-"])
def test_detects_supported_slack_token_families(gate_module, prefix: str) -> None:
    findings = gate_module.find_secrets(f"credential={synthetic_slack_token(prefix)}")
    assert len(findings) == 1
    assert findings[0].kind == "slack-token"


def test_redacts_issue_body_and_remote_config_without_preserving_full_secret(gate_module) -> None:
    tokens = [
        synthetic_github_token("ghp_"),
        synthetic_github_token("github_pat_"),
        synthetic_slack_token(),
    ]
    body = "\n".join(
        [
            "Disk report:",
            f"origin https://x-access-token:{tokens[0]}@github.com/acme/one.git (fetch)",
            f"mirror https://operator:{tokens[1]}@github.com/acme/two.git (push)",
            f"slack={tokens[2]}",
            "config path: /tmp/example/.git/config",
        ]
    )

    redacted = gate_module.redact_text(body)

    for token in tokens:
        assert token not in redacted
    assert "https://x-access-token:[REDACTED]@github.com/acme/one.git" in redacted
    assert "https://operator:[REDACTED]@github.com/acme/two.git" in redacted
    assert "/tmp/example/.git/config" in redacted
    assert gate_module.find_secrets(redacted) == []


def test_https_template_placeholders_are_not_reported_as_credentials(gate_module) -> None:
    text = "https://x-access-token:{token}@github.com/acme/repo.git"
    assert gate_module.find_secrets(text) == []


def _fake_gh(tmp_path: Path) -> tuple[Path, Path]:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    invocation_log = tmp_path / "gh-invocations"
    gh = bin_dir / "gh"
    gh.write_text(
        "#!/usr/bin/env bash\n"
        "printf '%s\\n' \"$*\" >>\"$GH_INVOCATION_LOG\"\n"
        "printf 'https://github.com/acme/repo/issues/1\\n'\n"
    )
    gh.chmod(0o755)
    return bin_dir, invocation_log


def test_gh_issue_create_blocks_exact_leak_body_before_invoking_gh(tmp_path: Path) -> None:
    bin_dir, invocation_log = _fake_gh(tmp_path)
    token = synthetic_github_token()
    body = f"git remote -v\norigin https://x-access-token:{token}@github.com/acme/private.git"
    env = {
        **os.environ,
        "PATH": f"{bin_dir}:{os.environ['PATH']}",
        "GH_INVOCATION_LOG": str(invocation_log),
    }

    result = subprocess.run(
        [str(GH_PUBLISH), "issue", "create", "--title", "disk report", "--body", body],
        text=True,
        capture_output=True,
        env=env,
    )

    assert result.returncode != 0
    assert "blocked" in result.stderr.lower()
    assert token not in result.stderr
    assert not invocation_log.exists()


@pytest.mark.parametrize("flag", ["--body=", "-b"])
def test_gh_combined_body_flags_cannot_bypass_gate(tmp_path: Path, flag: str) -> None:
    bin_dir, invocation_log = _fake_gh(tmp_path)
    token = synthetic_github_token()
    env = {
        **os.environ,
        "PATH": f"{bin_dir}:{os.environ['PATH']}",
        "GH_INVOCATION_LOG": str(invocation_log),
    }

    result = subprocess.run(
        [str(GH_PUBLISH), "issue", "create", "--title", "report", f"{flag}leak={token}"],
        text=True,
        capture_output=True,
        env=env,
    )

    assert result.returncode != 0
    assert token not in result.stderr
    assert not invocation_log.exists()


@pytest.mark.parametrize("flag", ["--body-file=", "-F"])
def test_gh_combined_body_file_flags_cannot_bypass_gate(tmp_path: Path, flag: str) -> None:
    bin_dir, invocation_log = _fake_gh(tmp_path)
    body_file = tmp_path / "body.md"
    body_file.write_text(f"leak={synthetic_slack_token()}")
    env = {
        **os.environ,
        "PATH": f"{bin_dir}:{os.environ['PATH']}",
        "GH_INVOCATION_LOG": str(invocation_log),
    }

    result = subprocess.run(
        [str(GH_PUBLISH), "pr", "create", "--title", "report", f"{flag}{body_file}"],
        text=True,
        capture_output=True,
        env=env,
    )

    assert result.returncode != 0
    assert not invocation_log.exists()


def test_gh_body_file_is_scanned_and_clean_body_is_forwarded(tmp_path: Path) -> None:
    bin_dir, invocation_log = _fake_gh(tmp_path)
    body_file = tmp_path / "body.md"
    body_file.write_text("Paths only: /tmp/example/.git/config\nToken fingerprint: github-token:ghp_…AAAA")
    env = {
        **os.environ,
        "PATH": f"{bin_dir}:{os.environ['PATH']}",
        "GH_INVOCATION_LOG": str(invocation_log),
    }

    result = subprocess.run(
        [str(GH_PUBLISH), "pr", "comment", "7", "--body-file", str(body_file)],
        text=True,
        capture_output=True,
        env=env,
    )

    assert result.returncode == 0, result.stderr
    assert invocation_log.read_text().startswith("pr comment 7 --body-file")


def test_shared_slack_post_blocks_secret_before_transport(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    transport_log = tmp_path / "transport-log"
    curl = bin_dir / "curl"
    curl.write_text(
        "#!/usr/bin/env bash\n"
        "printf 'called' >\"$TRANSPORT_LOG\"\n"
        "printf '{\"ok\":true,\"ts\":\"1.2\"}'\n"
    )
    curl.chmod(0o755)
    token = synthetic_slack_token()
    script = f"source {SLACK_LIB!s}; slack_post leak-test \"report {token}\" --channel C123"
    env = {
        **os.environ,
        "SLACK_BOT_TOKEN": "fixture-transport-token",
        "SLACK_POST_CURL": str(curl),
        "SLACK_THREAD_STATE_DIR": str(tmp_path / "state"),
        "TRANSPORT_LOG": str(transport_log),
    }

    result = subprocess.run(["bash", "-c", script], text=True, capture_output=True, env=env)

    assert result.returncode != 0
    assert "blocked" in result.stderr.lower()
    assert token not in result.stderr
    assert not transport_log.exists()


def test_secondary_slack_post_blocks_secret_before_transport(tmp_path: Path) -> None:
    transport_log = tmp_path / "transport-log"
    curl = tmp_path / "curl"
    curl.write_text("#!/usr/bin/env bash\nprintf called >\"$TRANSPORT_LOG\"\n")
    curl.chmod(0o755)
    token = synthetic_github_token()
    script = (
        f"source {SECONDARY_SLACK_LIB!s}; "
        f"PATH={tmp_path}:$PATH; slack_post_message C123 \"report {token}\""
    )
    env = {**os.environ, "SLACK_BOT_TOKEN": "fixture", "TRANSPORT_LOG": str(transport_log)}

    result = subprocess.run(["bash", "-c", script], text=True, capture_output=True, env=env)

    assert result.returncode != 0
    assert "blocked" in result.stderr.lower()
    assert token not in result.stderr
    assert not transport_log.exists()


def test_roadmap_report_uses_shared_redactor() -> None:
    text = ROADMAP_REPORT.read_text()
    assert "outbound_secret_gate.py" in text
    assert " redact" in text
    assert "xox[abp]" not in text


def test_soul_has_triggered_outbound_secret_commitment() -> None:
    soul = SOUL.read_text()
    section = soul.split("## COMMIT: outbound-secret-publication-gate", 1)[1]
    assert "gh-safe-publish" in section
    assert "git remote -v" in section
    assert ".git/config" in section
    assert "gh auth status -t" in section
    assert "fingerprint" in section.lower()


@pytest.mark.parametrize("publisher", AUTOMATION_PUBLISHERS, ids=lambda path: path.name)
def test_automation_publishers_use_shared_github_gate(publisher: Path) -> None:
    text = publisher.read_text()
    assert "GH_SAFE_PUBLISH" in text
    assert re.search(r'"\$GH_SAFE_PUBLISH" (?:issue|pr) create', text)
    assert not re.search(r"(?m)^\s*gh (?:issue|pr) (?:create|comment)\b", text)


@pytest.mark.parametrize("guidance", GITHUB_PUBLISH_GUIDANCE, ids=lambda path: path.name)
def test_canonical_publish_guidance_uses_shared_gate(guidance: Path) -> None:
    text = guidance.read_text()
    assert "gh-safe-publish" in text
    assert not re.search(r"(?m)^\s*gh (?:issue|pr) (?:create|comment)\b", text)


def test_no_executable_guidance_bypasses_shared_publish_gate() -> None:
    roots = (REPO_ROOT / "skills", REPO_ROOT / ".claude" / "commands")
    raw_publish = re.compile(r"(?m)^\s*gh (?:issue (?:create|comment)|pr (?:create|comment)|gist create)\b")
    offenders = []
    for root in roots:
        for path in root.rglob("*"):
            if path.is_file() and path.suffix in {".md", ".sh", ".py"} and "references" not in path.parts:
                if raw_publish.search(path.read_text(errors="replace")):
                    offenders.append(str(path.relative_to(REPO_ROOT)))
    assert offenders == []
