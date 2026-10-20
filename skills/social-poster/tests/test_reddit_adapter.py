#!/usr/bin/env python3
"""
Unit & Adversarial Tests for SubredditConstraintValidator and RedditAdapter.
"""

import unittest
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).parent.parent / "scripts"))

from reddit_adapter import RedditAdapter, SubredditConstraintValidator


class TestRedditAdapter(unittest.TestCase):
    def setUp(self):
        self.available_flairs = [
            {"id": "flair-demo-123", "text": "Demo | Project | Workflow"},
            {"id": "flair-disc-456", "text": "Discussion"},
            {"id": "flair-show-789", "text": "Showcase"},
        ]

    def test_category_to_flair_mapping(self):
        matched = SubredditConstraintValidator.map_category_to_flair(
            "Demo | Project | Workflow", self.available_flairs
        )
        self.assertIsNotNone(matched)
        self.assertEqual(matched["id"], "flair-demo-123")

        # Fuzzy / partial match
        matched_partial = SubredditConstraintValidator.map_category_to_flair(
            "demo", self.available_flairs
        )
        self.assertIsNotNone(matched_partial)
        self.assertEqual(matched_partial["id"], "flair-demo-123")

    def test_link_vs_self_constraint_validation(self):
        caps_self_only = {
            "allow_images": True,
            "submission_type": "self",
            "flair_required": False,
        }
        # Link submission to self-only subreddit fails
        errors = SubredditConstraintValidator.validate(
            {"subreddit": "OpenAI", "title": "Test", "kind": "link", "url": "https://worldarchitect.ai"},
            caps_self_only,
            self.available_flairs,
        )
        self.assertTrue(any("only allows self" in e for e in errors))

        # Self submission succeeds
        errors_self = SubredditConstraintValidator.validate(
            {"subreddit": "OpenAI", "title": "Test", "kind": "self", "body": "Context"},
            caps_self_only,
            self.available_flairs,
        )
        self.assertEqual(errors_self, [])

    def test_title_over_300_chars_fails(self):
        caps = {"allow_images": True, "submission_type": "any", "flair_required": False}
        long_title = "A" * 301
        errors = SubredditConstraintValidator.validate(
            {"subreddit": "aigamedev", "title": long_title, "body": "Body"},
            caps,
            self.available_flairs,
        )
        self.assertTrue(any("exceeds 300 characters" in e for e in errors))


if __name__ == "__main__":
    unittest.main()
