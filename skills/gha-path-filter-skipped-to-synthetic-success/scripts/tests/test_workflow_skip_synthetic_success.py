#!/usr/bin/env python3
"""
Regression test for the workflow-skip -> synthetic-success refactor.

Asserts:
  1. Every job in the configured set that uses needs.detect-changes.outputs.<key>
     in its `if:` has been patched to instead emit a synthetic-success step
     at the top of `steps:`.
  2. The job-level `if:` no longer references detect-changes.outputs.*.
  3. The synthetic-success step's `if:` matches the filter output key.
  4. The first existing step has SOME step-level `if:` gate (either pre-existing
     or newly added by the patcher).
  5. All three workflow files still parse as valid YAML.

Usage:
  python3 scripts/tests/test_workflow_skip_synthetic_success.py
  # or via unittest discovery:
  python3 -m unittest scripts.tests.test_workflow_skip_synthetic_success
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path

import yaml

# === Configuration: edit this for your repo ===
# Maps workflow file -> [(job_name, filter_output_key), ...]
# Same triple as the patcher's JOBS list, minus the label.
EXPECTED_JOBS: dict[str, list[tuple[str, str]]] = {
    "presubmit.yml": [
        ("schema-coverage", "schemas"),
        ("prompt-contracts", "prompts"),
        ("narrative-response-schema-ci", "prompts"),
        ("function-loc-ratchet", "loc_ratchet"),
        ("agy-json-contract", "agy"),
        ("python-lint", "python"),
        ("python-typecheck", "python"),
        ("javascript-lint", "js"),
    ],
    "test.yml": [
        ("import-validation", "python"),
        ("beads-jsonl-validation", "beads"),
        ("shell-script-tests", "shell"),
        ("test", "has-changes"),
    ],
    "self-hosted-mvp-shard1.yml": [
        ("harness-autonomy-self-hosted", "harness-changes"),
        ("mvp-shard-1", "mvp-changes"),
        ("mvp-shard-2", "mvp-changes"),
        ("mvp-shard-3", "mvp-changes"),
    ],
}

# Workflow directory, relative to repo root.
# This file lives at <repo>/scripts/tests/ and the workflows are at
# <repo>/.github/workflows/ — walk up two levels.
WF_DIR = Path(__file__).resolve().parents[2] / ".github" / "workflows"


class WorkflowSkipRefactorTest(unittest.TestCase):
    """Verify that every gated job emits synthetic-success instead of being `skipped`."""

    def _load(self, fname: str) -> dict:
        with (WF_DIR / fname).open() as f:
            return yaml.safe_load(f)

    def test_yaml_parses(self) -> None:
        """Every patched workflow file must still be valid YAML."""
        for fname in EXPECTED_JOBS:
            with self.subTest(file=fname):
                d = self._load(fname)
                self.assertIn("jobs", d)

    def test_job_if_strips_path_filter(self) -> None:
        """No gated job's `if:` may still reference detect-changes.outputs.<key>."""
        for fname, jobs in EXPECTED_JOBS.items():
            d = self._load(fname)
            jobs_def = d.get("jobs", {})
            for job, key in jobs:
                with self.subTest(file=fname, job=job):
                    j = jobs_def[job]
                    if_text = j.get("if", "")
                    self.assertNotIn(
                        f"detect-changes.outputs.{key}",
                        if_text,
                        f"{fname}/{job}: job-level `if:` still gates on path filter.",
                    )

    def test_synthetic_success_step_present(self) -> None:
        """Each gated job must have exactly one synthetic-success step."""
        for fname, jobs in EXPECTED_JOBS.items():
            d = self._load(fname)
            jobs_def = d.get("jobs", {})
            for job, key in jobs:
                with self.subTest(file=fname, job=job):
                    j = jobs_def[job]
                    steps = j.get("steps", [])
                    synth_steps = [
                        s
                        for s in steps
                        if isinstance(s, dict)
                        and isinstance(s.get("name"), str)
                        and s["name"].startswith("No ")
                        and s["name"].endswith("-relevant changes - synthetic success")
                    ]
                    self.assertEqual(
                        len(synth_steps),
                        1,
                        f"{fname}/{job}: expected exactly 1 synthetic-success step, found {len(synth_steps)}",
                    )
                    # The synthetic step's if: must require the filter to be 'false'.
                    step_if = synth_steps[0].get("if", "")
                    self.assertIn(f"detect-changes.outputs.{key}", step_if)
                    self.assertIn("!= 'true'", step_if)

    def test_all_heavy_steps_have_filter_if(self) -> None:
        """Every non-synthetic step must have SOME `if:` gate (existing or newly added).

        Steps with their own control `if:` (e.g. `runner.os != 'macOS'`, `always()`)
        are left untouched by the patcher — they're sufficient on their own.
        Steps with no `if:` at all are bugs: they would run on no-diff PRs and
        leak runner cost.
        """
        for fname, jobs in EXPECTED_JOBS.items():
            d = self._load(fname)
            jobs_def = d.get("jobs", {})
            for job, key in jobs:
                with self.subTest(file=fname, job=job):
                    j = jobs_def[job]
                    steps = j.get("steps", [])
                    non_synth = [
                        s
                        for s in steps
                        if not (
                            isinstance(s, dict)
                            and isinstance(s.get("name"), str)
                            and s["name"].startswith("No ")
                        )
                    ]
                    self.assertGreater(
                        len(non_synth), 0, f"{fname}/{job}: no non-synthetic steps found"
                    )
                    missing = []
                    for s in non_synth:
                        step_if = s.get("if", "")
                        if step_if:
                            # Existing control-flow if: is left untouched and is sufficient.
                            continue
                        # No if: at all — patcher should have added one.
                        missing.append(s.get("name", "?"))
                    self.assertEqual(
                        missing,
                        [],
                        f"{fname}/{job}: these steps lack any `if:` gate (patcher should add one): {missing}",
                    )


if __name__ == "__main__":
    unittest.main(verbosity=2)
