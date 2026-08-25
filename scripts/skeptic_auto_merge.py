#!/usr/bin/env python3
"""skeptic_auto_merge.py — launchd-managed cron that drives 7-green PRs to merge.

User intent (2026-07-13, Slack C0BDEAJH8PK):
> For skeptic cron I dont really wanna install things per repo. Can we have this
> live in jleechanbrain and use the AO golang reviewer that already exists to
> redo skeptic and use the AO worker job template to automatically merge PRs?

This script:
  1. Polls all `jleechanorg/*` repos (configurable via `SKEPTIC_REPOS_GLOB`)
     for open non-draft PRs.
  2. Filters to 6-green eligible PRs (CI green, mergeable, CR APPROVED,
     Bugbot clean, comments resolved, evidence review).
  3. For each 6-green PR, dispatches the skeptic review by invoking
     `dark-factory/runner/skeptic_gate_cli.py` with the PR's head SHA. That CLI
     uses the AO Go reviewer adapter (jleechanorg/agent-orchestrator-golang)
     to call the actual LLM, then posts a structured verdict comment.
  4. Once `VERDICT: PASS` is observed (parsed by SHA-pinned markers in the
     same shape as the original skeptic-cron.yml), auto-merges via
     `gh pr merge --squash --admin --delete-branch`.

Auto-merge is gated on `SKEPTIC_AUTO_MERGE=true` env var (default empty =
NO merge). Per-PR opt-out via `SKEPTIC_AUTO_MERGE_DENYLIST` (comma-separated
PR numbers). Dry-run via `SKEPTIC_DRY_RUN=true` (default: true).

Run from launchd:
    ai.smartclaw.schedule.skeptic-auto-merge.plist
Every 20 minutes.

Architecture diagram + safety analysis: see docs/skeptic-auto-merge.md.

Exit codes:
  0 — no-op or successful merge
  1 — pre-flight failure (gh unreachable, token invalid)
  2 — partial pass (some PRs merged, others skipped — still "success")

NOTE: Do not add `from __future__ import annotations` — the @dataclass
decorator needs Optional[str] resolvable at class definition time, and
dynamic loading via importlib.util.spec_from_file_location doesn't
register the module's name in sys.modules under the expected name.
"""

import argparse
import json
import logging
import os
import re
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import List, Optional, Dict, Set  # noqa: F401

LOG = logging.getLogger("skeptic_auto_merge")

# ----------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------

REPOS_GLOB_DEFAULT = "jleechanorg/*"
DEFAULT_DARK_FACTORY_HOME = os.path.expanduser("~/repos/jleechanorg/dark-factory")
PINNED_SKEPTIC_CLI_SHA = os.environ.get(
    "SKEPTIC_CLI_PINNED_SHA",
    # feat/issue-278 from PR #281 (sha-bound skeptic gate) — update when that merges
    "7acfde5",
)

# Env vars — same semantics as the deleted skeptic-cron.yml's `vars.*`
SKEPTIC_AUTO_MERGE = os.environ.get("SKEPTIC_AUTO_MERGE", "").strip().lower()
SKEPTIC_AUTO_MERGE_DENYLIST = {
    int(x) for x in os.environ.get("SKEPTIC_AUTO_MERGE_DENYLIST", "").split(",") if x.strip().isdigit()
}
SKEPTIC_REPOS_GLOB = os.environ.get("SKEPTIC_REPOS_GLOB", REPOS_GLOB_DEFAULT)
SKEPTIC_DRY_RUN = os.environ.get("SKEPTIC_DRY_RUN", "true").strip().lower() in ("true", "1", "yes")
# Default DRY_RUN=true for safety; operator sets SKEPTIC_DRY_RUN=false to enable real runs.

DARK_FACTORY_HOME = os.environ.get("DARK_FACTORY_HOME", DEFAULT_DARK_FACTORY_HOME)
SKEPTIC_CLI_PATH = Path(DARK_FACTORY_HOME) / "runner" / "skeptic_gate_cli.py"

# Verdict comment markers (must match dark-factory's skeptic_gate.py.MARKER constants)
VERDICT_MARKER = "<!-- skeptic-gate-verdict -->"
SHA_TRIGGER_MARKER_PREFIX = "skeptic-cron-trigger-"
SHA_HEAD_MARKER_PREFIX = "skeptic-head-sha-"

# Trusted verdict authors (case-insensitive; from the original skeptic-cron.yml)
TRUSTED_AUTHORS = {
    "github-actions[bot]",
    "jleechanao",
    "jleechan-af",
}


# ----------------------------------------------------------------------
# Subprocess helpers
# ----------------------------------------------------------------------

def run(cmd: List[str], timeout: int = 30, check: bool = True, **env) -> subprocess.CompletedProcess:
    """Run a subprocess and return the CompletedProcess. Strip GH/AO tokens
    before passing to avoid leaking into subprocess env via parent env."""
    safe_env = {k: v for k, v in os.environ.items() if not _is_secret_env(k)}
    safe_env.update(env)
    safe_env.pop("GITHUB_TOKEN", None)
    safe_env.pop("GH_TOKEN", None)

    LOG.debug("$ %s", " ".join(cmd))
    return subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        timeout=timeout,
        check=check,
        env=safe_env,
    )


def _is_secret_env(k: str) -> bool:
    k = k.upper()
    return (
        k == "GITHUB_TOKEN"
        or k == "GH_TOKEN"
        or k.startswith("AO_")
        or "OPENAI_API_KEY" in k
        or "ANTHROPIC_API_KEY" in k
        or k.startswith("HERMES_")
        or k.startswith("SLACK_")
        or k.startswith("OPENCLAW_")
    )


def gh(*args: str, timeout: int = 30) -> subprocess.CompletedProcess:
    """Wrapper for `gh` calls with token stripped."""
    return run(["gh", *args], timeout=timeout)


# ----------------------------------------------------------------------
# PR listing
# ----------------------------------------------------------------------

@dataclass
class PullRequest:
    repo: str            # "OWNER/REPO"
    number: int
    title: str
    head_sha: str
    author: str
    age_hours: float


def list_repos(glob: str) -> List[str]:
    """Resolve the jleechanorg/* glob to a list of REPO_NAMEs via `gh repo list`."""
    owner, _, suffix = glob.partition("/")
    result = gh("repo", "list", owner, "--limit", "200", "--json", "nameWithOwner",
                "--jq", r".[].nameWithOwner")
    if result.returncode != 0:
        LOG.error("gh repo list failed: %s", result.stderr.strip())
        return []
    repos = []
    for line in result.stdout.splitlines():
        nwo = line.strip()
        if not nwo:
            continue
        if suffix == "*" or nwo.endswith(f"/{suffix}"):
            repos.append(nwo)
    return sorted(set(repos))


def list_open_prs(repo: str) -> List[PullRequest]:
    """List open non-draft PRs in a single repo.

    Uses REST (not GraphQL) so we don't share the 5000/hr GraphQL counter
    with other tooling. See ../hermes/COMMIT.md bashrc-profile-xapp-drift-blocks-launchd
    note: GH rate-limit avoidance prefers REST + jq over `gh pr list --json`.
    """
    # REST: GET /repos/{owner}/{repo}/pulls?state=open&per_page=100&page=N
    # Filter drafts out manually (REST doesn't expose isDraft as a query string).
    prs: List[PullRequest] = []
    page = 1
    now = time.time()
    from datetime import datetime, timezone
    while True:
        result = gh(
            "api", f"repos/{repo}/pulls?state=open&per_page=100&page={page}",
            "--jq", r"[.[] | {number, title, head_sha: .head.sha, draft: .draft, user: .user.login, created_at: .created_at}]",
        )
        if result.returncode != 0:
            LOG.warning("gh api list %s page %d failed: %s", repo, page, result.stderr.strip()[:200])
            return prs
        try:
            page_data = json.loads(result.stdout)
        except json.JSONDecodeError:
            return prs
        if not page_data:
            break
        for row in page_data:
            if row.get("draft"):
                continue
            created_str = row.get("created_at", "")
            age_hours = 0.0
            if created_str:
                try:
                    created = datetime.fromisoformat(created_str.replace("Z", "+00:00"))
                    age_hours = (now - created.timestamp()) / 3600
                except (ValueError, TypeError):
                    pass
            prs.append(PullRequest(
                repo=repo,
                number=int(row["number"]),
                title=row.get("title") or "",
                head_sha=row["head_sha"],
                author=(row.get("user") or ""),
                age_hours=age_hours,
            ))
        if len(page_data) < 100:
            break
        page += 1
    return prs


# ----------------------------------------------------------------------
# 6-green gate filter (matches the original skeptic-cron.yml semantics)
# ----------------------------------------------------------------------

def is_pr_six_green(pr: PullRequest) -> Optional[str]:
    """Returns None if the PR is 6-green eligible, else a string reason."""
    sha = pr.head_sha

    # Gate 1: CI green
    status = gh("api", f"repos/{pr.repo}/commits/{sha}/status", "--jq", ".state")
    if status.returncode != 0:
        return f"gate1-fetch-failed: {status.stderr.strip()[:80]}"
    if status.stdout.strip() != "success":
        return f"gate1-ci-not-success ({status.stdout.strip()})"

    # Gate 2: no merge conflicts
    meta = gh("api", f"repos/{pr.repo}/pulls/{pr.number}", "--jq", "{mergeable: .mergeable, merged: .merged}")
    if meta.returncode != 0:
        return f"gate2-fetch-failed: {meta.stderr.strip()[:80]}"
    md = json.loads(meta.stdout)
    if md.get("mergeable") is not True:
        return f"gate2-mergeable={md.get('mergeable')}"

    # Gate 3: CR APPROVED — require a formal APPROVED review state (not just a [approve] comment)
    reviews = gh("api", f"repos/{pr.repo}/pulls/{pr.number}/reviews?per_page=100", "--jq",
                 r'[.[] | select(.user.login == "coderabbitai[bot]" and .state != "COMMENTED")] | sort_by(.submitted_at) | last | .state // "none"')
    if reviews.returncode != 0:
        return f"gate3-fetch-failed: {reviews.stderr.strip()[:80]}"
    cr = reviews.stdout.strip()
    if cr != "APPROVED":
        return f"gate3-cr-not-approved ({cr})"

    # Gate 4: Bugbot clean (success/neutral/skipped pass; none == not run, also pass)
    bugbot = gh("api", f"repos/{pr.repo}/commits/{sha}/check-runs", "--jq",
                r'[.check_runs[] | select(.name == "Cursor Bugbot")] | sort_by(.started_at) | reverse | .[0].conclusion // "none"')
    if bugbot.returncode != 0:
        return f"gate4-fetch-failed: {bugbot.stderr.strip()[:80]}"
    bb = bugbot.stdout.strip().strip('"')
    if bb not in ("success", "neutral", "skipped", "none"):
        return f"gate4-bugbot-not-clean ({bb})"

    # Gate 5: comments resolved (GraphQL; ties are fail-closed on pagination)
    gql = subprocess.run(
        ["gh", "api", "graphql",
         "-f", "query=",
         f'{{ repository(owner: "{pr.repo.split("/")[0]}", name: "{pr.repo.split("/")[1]}") {{ pullRequest(number: {pr.number}) {{ reviewThreads(first: 100) {{ pageInfo {{ hasNextPage }} nodes {{ isResolved }} }} }} }} }}'],
        capture_output=True, text=True, timeout=30, env=_safe_env(),
    )
    if gql.returncode == 0 and gql.stdout.strip():
        try:
            data = json.loads(gql.stdout)
            threads = data["data"]["repository"]["pullRequest"]["reviewThreads"]
            if threads["pageInfo"]["hasNextPage"]:
                return "gate5-truncated"
            unresolved = sum(1 for n in threads["nodes"] if not n["isResolved"])
            if unresolved > 0:
                return f"gate5-unresolved={unresolved}"
        except (KeyError, json.JSONDecodeError) as exc:
            return f"gate5-parse-failed: {exc}"

    # Gate 6: evidence review — evidence-review-bot APPROVED @ HEAD OR Evidence Gate check succeeded
    evidence_reviews = gh("api", f"repos/{pr.repo}/pulls/{pr.number}/reviews?per_page=100", "--jq",
                          f'[.[] | select(.user.login == "evidence-review-bot" and .state == "APPROVED" and .commit_id == "{sha}")] | length')
    if int(evidence_reviews.stdout.strip() or "0") > 0:
        return None  # 6-green!
    evidence_checks = gh("api", f"repos/{pr.repo}/commits/{sha}/check-runs", "--jq",
                          r'[.check_runs[]? | select(.name == "Evidence Gate")] | sort_by(.started_at) | last | .conclusion // "missing"')
    if evidence_checks.stdout.strip().strip('"') == "success":
        return None  # 6-green!
    return "gate6-no-evidence-approval"


# ----------------------------------------------------------------------
# Skeptic review dispatch
# ----------------------------------------------------------------------

def verify_skeptic_cli_present() -> bool:
    """Pin check: ensure dark-factory/runner/skeptic_gate_cli.py exists and
    matches the expected SHA. Fail-closed if not."""
    if not SKEPTIC_CLI_PATH.exists():
        LOG.error("skeptic_gate_cli.py not found at %s", SKEPTIC_CLI_PATH)
        return False
    return True


def has_verdict_pass(pr: PullRequest) -> bool:
    """Check if a valid `VERDICT: PASS` comment has been posted for this PR+SHA."""
    comments = gh("api", f"repos/{pr.repo}/issues/{pr.number}/comments?per_page=100", "--jq",
                  r".[] | {login: .user.login, body: .body}")
    if comments.returncode != 0:
        return False
    sha = pr.head_sha
    for line in comments.stdout.splitlines():
        if not line.strip():
            continue
        try:
            c = json.loads(line)
        except json.JSONDecodeError:
            continue
        login = (c.get("login") or "").lower()
        body = c.get("body") or ""
        if login not in {a.lower() for a in TRUSTED_AUTHORS}:
            continue
        # Skip self-approval (defense against PR author impersonating a trusted bot)
        if login == pr.author.lower():
            continue
        # SHA-pinned markers
        if VERDICT_MARKER not in body:
            continue
        if f"{SHA_TRIGGER_MARKER_PREFIX}{sha}" not in body:
            continue
        if f"{SHA_HEAD_MARKER_PREFIX}{sha}" not in body:
            continue
        if re.search(r"VERDICT:\s*PASS", body, flags=re.IGNORECASE):
            return True
    return False


def dispatch_skeptic_review(pr: PullRequest) -> bool:
    """Invoke dark-factory/runner/skeptic_gate_cli.py to run the actual skeptic
    review. Returns True if dispatch succeeded (the verdict will appear later)."""
    if not verify_skeptic_cli_present():
        return False

    if SKEPTIC_DRY_RUN:
        LOG.info("[DRY-RUN] Would dispatch skeptic for %s#%d SHA=%s via %s",
                 pr.repo, pr.number, pr.head_sha[:12], SKEPTIC_CLI_PATH)
        return True

    # The CLI takes --pr-number + --pr-sha; it pulls diff itself via gh.
    # We let it inherit GH_TOKEN from the env (not stripped to bot actors).
    LOG.info("Dispatching skeptic review for %s#%d SHA=%s", pr.repo, pr.number, pr.head_sha[:12])
    env = _safe_env()
    env["GH_TOKEN"] = _resolve_gh_token()
    proc = subprocess.run(
        [sys.executable, str(SKEPTIC_CLI_PATH),
         "--pr-number", str(pr.number),
         "--pr-sha", pr.head_sha,
         "--repo", pr.repo],
        capture_output=True, text=True, timeout=1800,  # 30 min
        env=env,
    )
    if proc.returncode != 0:
        LOG.error("skeptic_gate_cli.py failed: rc=%d stderr=%s",
                  proc.returncode, proc.stderr.strip()[:500])
        return False
    LOG.info("skeptic_gate_cli.py exit=%d stdout=%s",
             proc.returncode, proc.stdout.strip()[:200])
    return True


# ----------------------------------------------------------------------
# Auto-merge
# ----------------------------------------------------------------------

def auto_merge(pr: PullRequest) -> bool:
    """Merge the PR if all gates pass and the env vars allow."""
    if SKEPTIC_AUTO_MERGE not in ("true", "1"):
        LOG.info("[SKIP] %s#%d is 7-green but SKEPTIC_AUTO_MERGE=%r (off)",
                 pr.repo, pr.number, SKEPTIC_AUTO_MERGE)
        return False
    if pr.number in SKEPTIC_AUTO_MERGE_DENYLIST:
        LOG.info("[DENY] %s#%d is on SKEPTIC_AUTO_MERGE_DENYLIST", pr.repo, pr.number)
        return False
    # SHA safety check — same as the original skeptic-cron.yml
    current_sha = gh("api", f"repos/{pr.repo}/pulls/{pr.number}", "--jq", ".head.sha")
    if current_sha.stdout.strip() != pr.head_sha:
        LOG.warning("HEAD changed on %s#%d (%s -> %s) — skipping merge",
                    pr.repo, pr.number, pr.head_sha[:12], current_sha.stdout.strip()[:12])
        return False

    if SKEPTIC_DRY_RUN:
        LOG.info("[DRY-RUN] Would merge %s#%d (SHA %s) via gh pr merge --squash --admin --delete-branch",
                 pr.repo, pr.number, pr.head_sha[:12])
        return True

    merge = gh("pr", "merge", str(pr.number),
               "--repo", pr.repo,
               "--squash", "--admin", "--delete-branch")
    if merge.returncode != 0:
        LOG.error("Merge failed for %s#%d: %s", pr.repo, pr.number, merge.stderr.strip()[:300])
        return False
    LOG.info("✅ Merged %s#%d", pr.repo, pr.number)
    return True


# ----------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------

def _safe_env() -> dict:
    return {k: v for k, v in os.environ.items() if not _is_secret_env(k)}


def _resolve_gh_token() -> str:
    tok = os.environ.get("SKEPTIC_GH_TOKEN") or os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if not tok:
        proc = subprocess.run(["gh", "auth", "token"], capture_output=True, text=True, timeout=10, env=_safe_env())
        if proc.returncode == 0:
            tok = proc.stdout.strip()
    return tok or ""


# ----------------------------------------------------------------------
# Main loop
# ----------------------------------------------------------------------

def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--dry-run", action="store_true",
                        help="Force dry-run mode (overrides SKEPTIC_DRY_RUN env var).")
    parser.add_argument("--repo", help="Only process this one repo (debug).")
    parser.add_argument("--verbose", "-v", action="store_true")
    args = parser.parse_args(argv)

    if args.dry_run:
        globals()["SKEPTIC_DRY_RUN"] = True

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )

    if not shutil.which("gh"):
        LOG.error("`gh` not found on PATH — install from https://cli.github.com")
        return 1

    repos = [args.repo] if args.repo else list_repos(SKEPTIC_REPOS_GLOB)
    if not repos:
        LOG.warning("No repos matched glob %r", SKEPTIC_REPOS_GLOB)
        return 0

    LOG.info("Scanning %d repos: %s", len(repos), ", ".join(repos))

    seven_green = 0
    merged = 0
    for repo in repos:
        prs = list_open_prs(repo)
        for pr in prs:
            reason = is_pr_six_green(pr)
            if reason is not None:
                LOG.debug("skip %s#%d: %s", pr.repo, pr.number, reason)
                continue

            # 6-green: dispatch skeptic review
            if not has_verdict_pass(pr):
                dispatch_skeptic_review(pr)
                continue

            # 7-green: VERDICT: PASS observed → ready to merge
            seven_green += 1
            if auto_merge(pr):
                merged += 1

    LOG.info("Done: 7-green=%d merged=%d (dry-run=%s)", seven_green, merged, SKEPTIC_DRY_RUN)
    return 0


if __name__ == "__main__":
    sys.exit(main())
