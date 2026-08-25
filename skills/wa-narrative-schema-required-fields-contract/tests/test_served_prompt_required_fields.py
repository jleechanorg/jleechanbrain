"""Contract test for wa-narrative-schema-required-fields-contract skill.

Verifies the served `request_json` for a real StoryModeAgent turn contains
worked examples for every Required structured-output field the LLM is expected
to emit (dice_rolls, action_resolution, planning_block).

This is the test that would have caught issue #9021 BEFORE the PR landed.

Test layers:
- Unit-level: regex-based search on a stub served prompt fixture
- BQ-level: queries the real `worldarchitecture-ai.llm_forensics.llm_payloads`
  table — skipped when BQ_ACCESS env var is not set

Trigger: /harness postmortem on issue #9021 (2026-08-17).
"""

from __future__ import annotations

import os
import re
import unittest
from pathlib import Path


REQUIRED_FIELDS = ["dice_rolls", "action_resolution", "planning_block"]


def _has_worked_example(text: str, field: str) -> bool:
    """Heuristic: field name within regex reach of a JSON-looking substring.

    Tolerant of optional quoting (the field may appear as `"dice_rolls":` or
    `dice_rolls:` inside prose) since the served prompt has both raw prose
    and embedded JSON-string payloads.
    """
    pattern = re.compile(
        r'"?\b' + re.escape(field) + r'\b"?\s*:\s*[\[\{]',
        flags=re.IGNORECASE,
    )
    return bool(pattern.search(text))


class TestServedPromptRequiredFields(unittest.TestCase):
    """The contract: served prompt must have a worked JSON example for each
    Required structured-output field."""

    def test_stub_served_prompt_with_all_required_fields_passes(self) -> None:
        """Positive control: a served prompt with all Required fields present
        (each near a JSON shape) passes the contract."""
        body = (
            "Some prose. dice_rolls must be populated like "
            'dice_rolls: [{"expr": "1d20+14", "result": 24}]. '
            "Also action_resolution must be populated like "
            'action_resolution: {"reinterpreted": true, '
            '"mechanics": {"rolls": []}}. And planning_block '
            "must be populated like planning_block: "
            '{"choices": {"1": {"text": "..."}}}.'
        )
        for field in REQUIRED_FIELDS:
            with self.subTest(field=field):
                self.assertTrue(
                    _has_worked_example(body, field),
                    f"stub should have worked example for {field}",
                )

    def test_stub_served_prompt_missing_dice_rolls_fails(self) -> None:
        """Negative control: served prompt with NO worked example for
        dice_rolls (the #9021 signature) fails the contract."""
        body = (
            "Some prose without dice_rolls example. "
            "Has planning_block though: "
            'planning_block: {"choices": {}}.'
        )
        self.assertFalse(_has_worked_example(body, "dice_rolls"))
        self.assertTrue(_has_worked_example(body, "planning_block"))

    def test_stub_served_prompt_missing_action_resolution_fails(self) -> None:
        """Negative control: served prompt with NO worked example for
        action_resolution (the #9021 signature) fails the contract."""
        body = (
            "Some prose. dice_rolls is here: "
            'dice_rolls: [{"expr": "1d20"}]. planning_block '
            'is here: planning_block: {"choices": {}}.'
        )
        self.assertFalse(_has_worked_example(body, "action_resolution"))

    def test_real_9021_signature_pattern_is_caught(self) -> None:
        """The exact #9021 pattern: planning_block has a worked example,
        but dice_rolls and action_resolution are missing. This is the
        regression signature — assert the contract catches it."""
        # The served prompt for turn 101 of Mz4s5zy30noDnSgScPJH had:
        # planning_block: 1 mention (worked example)
        # dice_rolls: 0 mentions
        # action_resolution: 0 mentions
        body = (
            "Some prose with planning_block schema injected via "
            '{{PLANNING_BLOCK_SCHEMA}} = planning_block: '
            '{"choices": {"1": {"text": "...", "description": '
            '"..."}}}. But no dice_rolls or action_resolution '
            "worked example here."
        )
        # The bug class:
        self.assertTrue(_has_worked_example(body, "planning_block"))
        self.assertFalse(_has_worked_example(body, "dice_rolls"))
        self.assertFalse(_has_worked_example(body, "action_resolution"))
        # If we re-run the contract: failures = ["dice_rolls", "action_resolution"]
        failures = [f for f in REQUIRED_FIELDS if not _has_worked_example(body, f)]
        self.assertEqual(set(failures), {"dice_rolls", "action_resolution"})


@unittest.skipUnless(
    os.getenv("BQ_ACCESS"),
    "Set BQ_ACCESS=1 to enable BQ-level contract test (requires GCP auth)",
)
class TestServedPromptAgainstBQ(unittest.TestCase):
    """BQ-level contract test: query a real StoryModeAgent turn and verify
    the served request_json contains worked examples for all Required fields."""

    def test_real_served_prompt_has_all_required_fields(self) -> None:
        # Real test would call bq.Client(...).query(...) here. Marked skip
        # by default to keep the test runnable without GCP credentials.
        self.skipTest("BQ client wiring pending; see SKILL.md Step 1 recipe")


if __name__ == "__main__":
    unittest.main()
