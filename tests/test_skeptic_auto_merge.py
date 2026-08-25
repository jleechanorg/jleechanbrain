"""Contract tests for scripts/skeptic_auto_merge.py — the launchd-managed
skeptic + auto-merge cron.

Pins the user's stated invariants (2026-07-13, Slack C0BDEAJH8PK):
  - "I dont really wanna install things per repo"
  - "use the AO golang reviewer that already exists"
  - "use the AO worker job template to automatically merge PRs"

A future refactor that breaks any of these fails the suite fast.

Test coverage:
  [1] No per-repo install — script reads `gh repo list` over SKEPTIC_REPOS_GLOB
  [2] Reuses dark-factory's skeptic_gate_cli.py (pinned path), not reimplemented
  [3] Auto-merge is gated on SKEPTIC_AUTO_MERGE=true env var (default empty = NO merge)
  [4] Per-PR denylist via SKEPTIC_AUTO_MERGE_DENYLIST
  [5] Fail-closed on spoofed verdicts — only trusted authors accepted
  [6] SHA-pinned verdict markers required
  [7] Self-approval blocked (PR author ≠ verdict author)
  [8] 6-green gate filter is fail-closed on every gate
  [9] DRY_RUN default is true (safe default per hermes-deploy-pipeline)
  [10] Strips GITHUB_TOKEN / AO_*/SECRET_* env vars before subprocess calls
"""

from __future__ import annotations

import importlib.util
import json
import os
import re
import subprocess
import sys
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
SCRIPT_PATH = ROOT / "scripts" / "skeptic_auto_merge.py"


def _load_module():
    spec = importlib.util.spec_from_file_location("skeptic_auto_merge", SCRIPT_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# ---------------------------------------------------------------------------
# Source-level invariants (no execution, no subprocess)
# ---------------------------------------------------------------------------

class SkepticAutoMergeInvariants(unittest.TestCase):
    """Pin the source shape of the script — these don't import or execute."""

    def test_01_script_exists(self):
        self.assertTrue(SCRIPT_PATH.exists(), f"missing {SCRIPT_PATH}")

    def test_02_no_hardcoded_repo_list(self):
        """No per-repo install — script must enumerate via `gh repo list`."""
        src = SCRIPT_PATH.read_text()
        # No literal hardcoded list of `jleechanorg/<repo>` names beyond the glob default
        # Allow glob default "jleechanorg/*" but reject explicit enumerations.
        self.assertIn('"jleechanorg/*"', src, "glob default must be 'jleechanorg/*'")
        # Search for hardcoded `gh pr list --repo jleechanorg/<some-name>` patterns
        bad = re.search(r'gh\s+pr\s+list\s+--repo\s+jleechanorg/(?!\{)', src)
        self.assertIsNone(bad, "script must NOT hardcode `gh pr list --repo jleechanorg/<name>` — must use glob")

    def test_03_uses_dark_factory_skeptic_cli(self):
        """Reuses the AO Go reviewer's CLI — calls skeptic_gate_cli.py."""
        src = SCRIPT_PATH.read_text()
        self.assertIn("skeptic_gate_cli.py", src)
        # The dispatch path is dark-factory-relative, not self-implemented
        self.assertIn("dark-factory", src.lower())
        # Pins the SHA in case PR #281 closes (dropped or merged)
        self.assertIn("PINNED_SKEPTIC_CLI_SHA", src)
        # Calls the CLI as a subprocess — does not reimplement verdict parsing
        self.assertRegex(src, r"subprocess\.run\(\s*\[sys\.executable,\s*str\(SKEPTIC_CLI_PATH\)")

    def test_04_auto_merge_env_gated(self):
        """Auto-merge is gated on SKEPTIC_AUTO_MERGE env var."""
        src = SCRIPT_PATH.read_text()
        self.assertIn("SKEPTIC_AUTO_MERGE", src)
        # The auto-merge function checks the env var, not a hardcoded true
        self.assertRegex(
            src,
            r"if\s+SKEPTIC_AUTO_MERGE\s+not\s+in\s+\(\"true\"|\"1\"\)",
            "auto-merge must check SKEPTIC_AUTO_MERGE in ('true', '1')",
        )

    def test_05_denylist_supported(self):
        """Per-PR opt-out via SKEPTIC_AUTO_MERGE_DENYLIST."""
        src = SCRIPT_PATH.read_text()
        self.assertIn("SKEPTIC_AUTO_MERGE_DENYLIST", src)
        self.assertIn("denylist", src.lower())

    def test_06_strips_secrets_from_subprocess_env(self):
        """Subprocess env must NOT inherit GITHUB_TOKEN, AO_*, HERMES_*, etc."""
        src = SCRIPT_PATH.read_text()
        self.assertRegex(
            src,
            r"_is_secret_env|_safe_env|GITHUB_TOKEN|GH_TOKEN|safe_env",
            "script must filter secret env vars before subprocess.run()",
        )
        # Verdict: the populate_env logic exists
        self.assertIn("def _safe_env", src)
        self.assertIn("def _is_secret_env", src)
        # Specifically strips the AO bot token (per bashrc-profile-xapp-drift-blocks-launchd bug-ref)
        self.assertRegex(
            src,
            r'k\s*==\s*"GITHUB_TOKEN"|k\s*startswith\("AO_\"',
            "_is_secret_env must refuse GITHUB_TOKEN and AO_*",
        )

    def test_07_fail_closed_on_unknown_gate(self):
        """6-green gate filter refuses PRs on any unknown/partial state."""
        src = SCRIPT_PATH.read_text()
        # is_pr_six_green returns a string reason on any failure
        self.assertRegex(src, r"def is_pr_six_green\(.*\) -> Optional\[str\]:")
        # Every gate returns a reason if the gate is not met
        self.assertIn("gate1-", src)
        self.assertIn("gate2-", src)
        self.assertIn("gate3-", src)
        self.assertIn("gate4-", src)
        self.assertIn("gate5-", src)
        self.assertIn("gate6-", src)

    def test_08_sha_pinned_markers(self):
        """Verdict parsers require SHA-pinned markers."""
        src = SCRIPT_PATH.read_text()
        self.assertIn("skeptic-cron-trigger-", src)
        self.assertIn("skeptic-head-sha-", src)
        self.assertIn("skeptic-gate-verdict", src)

    def test_09_trusted_authors_allowlist(self):
        """Trusted verdict authors allowlist includes the three trusted bots."""
        src = SCRIPT_PATH.read_text()
        self.assertIn("github-actions[bot]", src)
        self.assertIn("jleechanao", src)
        self.assertIn("jleechan-af", src)

    def test_10_self_approval_blocked(self):
        """Verdict author must NOT equal PR author (defense against self-approval)."""
        src = SCRIPT_PATH.read_text()
        self.assertRegex(
            src,
            r"if\s+login\s*==\s*pr\.author\.lower\(\).*:",
            "self-approval guard: login == pr.author must skip the comment",
        )

    def test_11_dry_run_default_true(self):
        """DRY_RUN defaults to TRUE for safety — operator must opt-in to real runs."""
        src = SCRIPT_PATH.read_text()
        # SKEPTIC_DRY_RUN env default is "true"
        self.assertIn('SKEPTIC_DRY_RUN = os.environ.get("SKEPTIC_DRY_RUN", "true")', src)
        # --dry-run CLI flag exists for force-dry-run
        self.assertIn("--dry-run", src)

    def test_12_head_sha_safety_check(self):
        """Auto-merge must verify HEAD SHA hasn't changed between 7-green eval and merge."""
        src = SCRIPT_PATH.read_text()
        self.assertIn("current_sha", src.lower())
        self.assertRegex(
            src,
            r"current_sha.*!=.*pr\.head_sha|HEAD changed",
            "script must abort the merge if HEAD changed between eval and merge",
        )


# ---------------------------------------------------------------------------
# Behavioural tests (load the module, exercise functions)
# ---------------------------------------------------------------------------

class SkepticAutoMergeBehavior(unittest.TestCase):
    """Exercise the module's runtime behavior."""

    @classmethod
    def setUpClass(cls):
        cls.mod = _load_module()

    def setUp(self):
        # Ensure no env vars leak across tests
        for k in (
            "SKEPTIC_AUTO_MERGE",
            "SKEPTIC_AUTO_MERGE_DENYLIST",
            "SKEPTIC_DRY_RUN",
            "SKEPTIC_REPOS_GLOB",
            "SKEPTIC_GH_TOKEN",
        ):
            os.environ.pop(k, None)

    def test_secret_filter_strips_gh_token(self):
        """_is_secret_env must refuse GITHUB_TOKEN, GH_TOKEN, AO_*, HERMES_*, etc."""
        mod = self.mod
        for k in ("GITHUB_TOKEN", "GH_TOKEN", "AO_BOT_TOKEN", "AO_FOO", "HERMES_KEY", "SLACK_TOKEN", "OPENAI_API_KEY"):
            self.assertTrue(mod._is_secret_env(k), f"should refuse {k}")
        # Public, non-secret env vars must be allowed
        for k in ("HOME", "PATH", "TZ", "USER", "LANG"):
            self.assertFalse(mod._is_secret_env(k), f"should allow {k}")

    def test_safe_env_strips_secrets(self):
        with mock.patch.dict(os.environ, {
            "GITHUB_TOKEN": "***",
            "AO_BOT_TOKEN": "***",
            "HERMES_SECRET": "***",
            "HOME": "/home/test",
        }):
            env = self.mod._safe_env()
            self.assertNotIn("GITHUB_TOKEN", env)
            self.assertNotIn("AO_BOT_TOKEN", env)
            self.assertNotIn("HERMES_SECRET", env)
            self.assertEqual(env["HOME"], "/home/test")

    def test_denylist_parses(self):
        """SKEPTIC_AUTO_MERGE_DENYLIST parses correctly."""
        os.environ["SKEPTIC_AUTO_MERGE_DENYLIST"] = "123,456,789"
        # Reload module to pick up env
        import importlib
        mod = _load_module()
        self.assertEqual(mod.SKEPTIC_AUTO_MERGE_DENYLIST, {123, 456, 789})

    def test_has_verdict_pass_requires_all_three_markers(self):
        """A valid VERDICT: PASS must include all three SHA-pinned markers."""
        mod = self.mod
        pr = mod.PullRequest(
            repo="OWNER/REPO", number=1, title="t", head_sha="abc123", author="joe", age_hours=1,
        )
        good_comment = json.dumps({
            "login": "github-actions[bot]",
            "body": (
                "<!-- skeptic-gate-verdict -->\n"
                "<!-- skeptic-cron-trigger-abc123 -->\n"
                "<!-- skeptic-head-sha-abc123 -->\n"
                "VERDICT: PASS\n"
            ),
        })
        with mock.patch.object(mod, "gh", return_value=_mock_proc(0, good_comment + "\n")):
            self.assertTrue(mod.has_verdict_pass(pr))

        # Same comment but missing trigger marker
        bad1 = json.dumps({
            "login": "github-actions[bot]",
            "body": (
                "<!-- skeptic-gate-verdict -->\n"
                "<!-- skeptic-head-sha-abc123 -->\n"
                "VERDICT: PASS\n"
            ),
        })
        with mock.patch.object(mod, "gh", return_value=_mock_proc(0, bad1 + "\n")):
            self.assertFalse(mod.has_verdict_pass(pr))

        # Missing head-sha marker
        bad2 = json.dumps({
            "login": "github-actions[bot]",
            "body": (
                "<!-- skeptic-gate-verdict -->\n"
                "<!-- skeptic-cron-trigger-abc123 -->\n"
                "VERDICT: PASS\n"
            ),
        })
        with mock.patch.object(mod, "gh", return_value=_mock_proc(0, bad2 + "\n")):
            self.assertFalse(mod.has_verdict_pass(pr))

        # Trusted-marker marker missing
        bad3 = json.dumps({
            "login": "github-actions[bot]",
            "body": "VERDICT: PASS\n",
        })
        with mock.patch.object(mod, "gh", return_value=_mock_proc(0, bad3 + "\n")):
            self.assertFalse(mod.has_verdict_pass(pr))

    def test_has_verdict_pass_rejects_unknown_author(self):
        mod = self.mod
        pr = mod.PullRequest(
            repo="OWNER/REPO", number=1, title="t", head_sha="abc123", author="joe", age_hours=1,
        )
        spoofed = json.dumps({
            "login": "random-bot",  # NOT in TRUSTED_AUTHORS
            "body": (
                "<!-- skeptic-gate-verdict -->\n"
                "<!-- skeptic-cron-trigger-abc123 -->\n"
                "<!-- skeptic-head-sha-abc123 -->\n"
                "VERDICT: PASS\n"
            ),
        })
        with mock.patch.object(mod, "gh", return_value=_mock_proc(0, spoofed + "\n")):
            self.assertFalse(mod.has_verdict_pass(pr))

    def test_has_verdict_pass_rejects_self_approval(self):
        mod = self.mod
        # PR author is `jleechan-af` (a trusted actor). The verdict comment
        # author is also `jleechan-af`. Self-approval must be rejected even
        # when the author is trusted.
        pr = mod.PullRequest(
            repo="OWNER/REPO", number=1, title="t", head_sha="abc123", author="jleechan-af", age_hours=1,
        )
        self_approval = json.dumps({
            "login": "jleechan-af",
            "body": (
                "<!-- skeptic-gate-verdict -->\n"
                "<!-- skeptic-cron-trigger-abc123 -->\n"
                "<!-- skeptic-head-sha-abc123 -->\n"
                "VERDICT: PASS\n"
            ),
        })
        with mock.patch.object(mod, "gh", return_value=_mock_proc(0, self_approval + "\n")):
            self.assertFalse(mod.has_verdict_pass(pr))

    def test_auto_merge_blocked_when_env_unset(self):
        mod = self.mod
        pr = mod.PullRequest(
            repo="OWNER/REPO", number=1, title="t", head_sha="abc123", author="joe", age_hours=1,
        )
        # SKEPTIC_AUTO_MERGE not set → must NOT merge
        self.assertEqual(mod.SKEPTIC_AUTO_MERGE, "")
        self.assertFalse(mod.auto_merge(pr))

    def test_auto_merge_enabled_with_env_true(self):
        mod = self.mod
        os.environ["SKEPTIC_AUTO_MERGE"] = "true"
        # Reload to pick up the new env
        import importlib
        mod2 = _load_module()
        pr = mod2.PullRequest(
            repo="OWNER/REPO", number=1, title="t", head_sha="abc123", author="joe", age_hours=1,
        )
        # DRY_RUN default is true → auto-merge reports "[DRY-RUN] would merge" but returns True
        self.assertTrue(mod2.SKEPTIC_DRY_RUN)
        # Mock `gh("api", "repos/.../pulls/N", "--jq", ".head.sha")` to return the same SHA
        sha_proc = subprocess.CompletedProcess(args=[], returncode=0, stdout="abc123", stderr="")
        with mock.patch.object(mod2, "gh", return_value=sha_proc) as mock_gh:
            ok = mod2.auto_merge(pr)
            self.assertTrue(ok)
            # gh pr merge must NOT be called in dry-run
            for call in mock_gh.call_args_list:
                self.assertNotIn("merge", call.args)

    def test_auto_merge_blocked_for_denylisted_pr(self):
        mod = self.mod
        os.environ["SKEPTIC_AUTO_MERGE"] = "true"
        os.environ["SKEPTIC_AUTO_MERGE_DENYLIST"] = "42"
        import importlib
        mod2 = _load_module()
        pr = mod2.PullRequest(
            repo="OWNER/REPO", number=42, title="t", head_sha="abc123", author="joe", age_hours=1,
        )
        self.assertFalse(mod2.auto_merge(pr))


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _mock_proc(rc: int, stdout: str = "", stderr: str = "") -> subprocess.CompletedProcess:
    return subprocess.CompletedProcess(args=[], returncode=rc, stdout=stdout, stderr=stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
