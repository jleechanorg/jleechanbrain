#!/usr/bin/env python3
"""
Unit & Adversarial Tests for HNMarkupFormatter, TwoStepSubmissionPipeline, and HackerNewsAdapter.
"""

import unittest
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).parent.parent / "scripts"))

from hackernews_adapter import HackerNewsAdapter, HNMarkupFormatter, TwoStepSubmissionPipeline


class TestHackerNewsAdapter(unittest.TestCase):
    def test_hn_markup_formatting(self):
        raw_markdown = (
            "# Heading 1\n\n"
            "This is **bold** and *italic* text.\n\n"
            "Check out [WorldArchitect](https://worldarchitect.ai) for interactive worlds."
        )
        formatted = HNMarkupFormatter.format(raw_markdown)
        self.assertNotIn("#", formatted)
        self.assertNotIn("**", formatted)
        self.assertIn("WorldArchitect (https://worldarchitect.ai)", formatted)

    def test_two_step_pipeline_validation(self):
        errors = TwoStepSubmissionPipeline.validate_payload({"title": "", "url": "https://example.com"})
        self.assertTrue(any("cannot be empty" in e for e in errors))

        errors_no_target = TwoStepSubmissionPipeline.validate_payload({"title": "Valid Title"})
        self.assertTrue(any("requires either" in e for e in errors_no_target))

        valid_errors = TwoStepSubmissionPipeline.validate_payload(
            {"title": "Show HN: WorldArchitect – AI GM", "url": "https://worldarchitect.ai"}
        )
        self.assertEqual(valid_errors, [])


if __name__ == "__main__":
    unittest.main()
