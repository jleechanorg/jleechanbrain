#!/usr/bin/env python3
"""Tests for babysit-stale-watchdog.py."""
import json
import os
import sys
import unittest
from pathlib import Path
from unittest.mock import patch, MagicMock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import babysit_stale_watchdog  # noqa: E402
extract_pr_refs = babysit_stale_watchdog.extract_pr_refs
is_babysit = babysit_stale_watchdog.is_babysit
gh_pr_state = babysit_stale_watchdog.gh_pr_state


class TestExtractPRRefs(unittest.TestCase):
    def test_url(self):
        refs = extract_pr_refs(
            "PR https://github.com/jleechanorg/worldarchitect.ai/pull/7711"
        )
        self.assertEqual(refs, [("jleechanorg", "worldarchitect.ai", 7711)])

    def test_bare_ref_uses_default_repo(self):
        refs = extract_pr_refs("PR #7711")
        self.assertEqual(refs, [("jleechanorg", "worldarchitect.ai", 7711)])

    def test_no_dedup_between_url_and_bare(self):
        # URL takes precedence; bare ref is dropped if same number
        refs = extract_pr_refs(
            "PR https://github.com/jleechanorg/worldarchitect.ai/pull/7711 and PR #7711"
        )
        self.assertEqual(len(refs), 1)


class TestIsBabysit(unittest.TestCase):
    def test_name_match(self):
        self.assertTrue(is_babysit({"name": "babysit-wa-2403-PR7711", "prompt": ""}))

    def test_prompt_head_match(self):
        self.assertTrue(is_babysit({
            "name": "AO cron", "prompt": "You are babysitting AO worker wa-2258..."
        }))

    def test_negative(self):
        self.assertFalse(is_babysit({
            "name": "life:daily-task-prep", "prompt": "Run executive assistant sweep"
        }))


class TestGhPrState(unittest.TestCase):
    @patch("babysit_stale_watchdog.subprocess.run")
    def test_merged(self, mock_run):
        mock_run.return_value = MagicMock(
            returncode=0, stdout=json.dumps({"state": "MERGED"})
        )
        self.assertEqual(gh_pr_state("o", "r", 1), "MERGED")

    @patch("babysit_stale_watchdog.subprocess.run")
    def test_failure_returns_none(self, mock_run):
        mock_run.return_value = MagicMock(returncode=1, stdout="")
        self.assertIsNone(gh_pr_state("o", "r", 1))


class TestMainEndToEnd(unittest.TestCase):
    """Verify main() disables a job whose PR is merged."""

    sample_jobs = {
        "jobs": [
            {
                "id": "stale-1",
                "name": "babysit-wa-2403-PR7711",
                "enabled": True,
                "state": "scheduled",
                "prompt": "PR https://github.com/jleechanorg/worldarchitect.ai/pull/7711",
                "repeat": {"completed": 251},
            },
            {
                "id": "live-1",
                "name": "babysit-wa-9999",
                "enabled": True,
                "state": "scheduled",
                "prompt": "PR https://github.com/jleechanorg/worldarchitect.ai/pull/9999",
                "repeat": {"completed": 1},
            },
            {
                "id": "non-babysit-1",
                "name": "life:daily-task-prep",
                "enabled": True,
                "state": "scheduled",
                "prompt": "Run daily prep",
                "repeat": {"completed": 0},
            },
        ]
    }

    @patch("babysit_stale_watchdog.gh_pr_state")
    def test_disables_only_merged(self, mock_state):
        # Verify the predicate: is the babysit job staled-on-merged-pr logic correct?
        # Use a temp CRON_JOBS so we don't touch real state.
        import tempfile
        from datetime import datetime, timezone
        tmp_dir = tempfile.TemporaryDirectory()
        tmp_path = Path(tmp_dir.name) / "jobs.json"
        with open(tmp_path, "w") as f:
            json.dump(self.sample_jobs, f)

        with patch.object(babysit_stale_watchdog, "CRON_JOBS", tmp_path), \
             patch("pathlib.Path.home", return_value=Path(tmp_dir.name)):
            def gh_state(owner, repo, num):
                if num == 7711: return "MERGED"
                if num == 9999: return "OPEN"
                return None
            mock_state.side_effect = gh_state

            main = babysit_stale_watchdog.main
            result = main()
            self.assertEqual(result, 0)

            # Re-read what got written — only stale-1 should be disabled
            with open(tmp_path) as f:
                written = json.load(f)
            by_id = {j["id"]: j for j in written["jobs"]}
            self.assertFalse(by_id["stale-1"]["enabled"])
            self.assertIn("babysit-stale-watchdog", by_id["stale-1"]["paused_reason"])
            self.assertTrue(by_id["live-1"]["enabled"], "OPEN PR must NOT be disabled")
            self.assertTrue(by_id["non-babysit-1"]["enabled"], "non-babysit must be untouched")

            # Check that last_alert.json was created
            alert_file = Path(tmp_dir.name) / ".smartclaw" / "cron" / "output" / "babysit-stale-watchdog.last_alert.json"
            self.assertTrue(alert_file.exists())

        tmp_dir.cleanup()

    @patch("babysit_stale_watchdog.gh_pr_state")
    def test_handles_non_dict_repeat(self, mock_state):
        import tempfile
        tmp_dir = tempfile.TemporaryDirectory()
        tmp_path = Path(tmp_dir.name) / "jobs.json"
        
        bad_repeat_jobs = {
            "jobs": [
                {
                    "id": "stale-none",
                    "name": "babysit-wa-2403-PR7711",
                    "enabled": True,
                    "state": "scheduled",
                    "prompt": "PR https://github.com/jleechanorg/worldarchitect.ai/pull/7711",
                    "repeat": None,
                },
                {
                    "id": "stale-string",
                    "name": "babysit-wa-2403-PR7712",
                    "enabled": True,
                    "state": "scheduled",
                    "prompt": "PR https://github.com/jleechanorg/worldarchitect.ai/pull/7712",
                    "repeat": "not-a-dict",
                }
            ]
        }
        with open(tmp_path, "w") as f:
            json.dump(bad_repeat_jobs, f)

        with patch.object(babysit_stale_watchdog, "CRON_JOBS", tmp_path), \
             patch("pathlib.Path.home", return_value=Path(tmp_dir.name)):
            mock_state.return_value = "MERGED"

            main = babysit_stale_watchdog.main
            result = main()
            self.assertEqual(result, 0)

            with open(tmp_path) as f:
                written = json.load(f)
            by_id = {j["id"]: j for j in written["jobs"]}
            self.assertFalse(by_id["stale-none"]["enabled"])
            self.assertIn("Original polls: ?", by_id["stale-none"]["paused_reason"])
            self.assertFalse(by_id["stale-string"]["enabled"])
            self.assertIn("Original polls: ?", by_id["stale-string"]["paused_reason"])

        tmp_dir.cleanup()

    @patch("babysit_stale_watchdog.gh_pr_state")
    def test_alert_throttling(self, mock_state):
        import tempfile
        from datetime import datetime, timezone
        tmp_dir = tempfile.TemporaryDirectory()
        tmp_path = Path(tmp_dir.name) / "jobs.json"
        
        jobs = {
            "jobs": [
                {
                    "id": "stale-1",
                    "name": "babysit-wa-2403-PR7711",
                    "enabled": True,
                    "state": "scheduled",
                    "prompt": "PR https://github.com/jleechanorg/worldarchitect.ai/pull/7711",
                    "repeat": {"completed": 10},
                }
            ]
        }
        with open(tmp_path, "w") as f:
            json.dump(jobs, f)

        # Pre-create last_alert.json with today's date
        alert_dir = Path(tmp_dir.name) / ".smartclaw" / "cron" / "output"
        alert_dir.mkdir(parents=True, exist_ok=True)
        alert_file = alert_dir / "babysit-stale-watchdog.last_alert.json"
        
        now = datetime.now(timezone.utc).isoformat(timespec="seconds")
        today_str = now[:10]
        
        pre_existing_data = {
            "disabled_at": f"{today_str}T00:00:00Z",
            "jobs": [{"job_id": "other-stale", "name": "something-else"}]
        }
        with open(alert_file, "w") as f:
            json.dump(pre_existing_data, f)

        with patch.object(babysit_stale_watchdog, "CRON_JOBS", tmp_path), \
             patch("pathlib.Path.home", return_value=Path(tmp_dir.name)):
            mock_state.return_value = "MERGED"

            main = babysit_stale_watchdog.main
            result = main()
            self.assertEqual(result, 0)

            # Re-read jobs.json -> stale-1 should be disabled
            with open(tmp_path) as f:
                written = json.load(f)
            self.assertFalse(written["jobs"][0]["enabled"])

            # Re-read last_alert.json -> it should NOT be overwritten (remains pre_existing_data)
            with open(alert_file) as f:
                alert_data = json.load(f)
            self.assertEqual(alert_data["jobs"][0]["job_id"], "other-stale")

        tmp_dir.cleanup()


if __name__ == "__main__":
    unittest.main(verbosity=2)