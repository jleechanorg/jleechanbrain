#!/usr/bin/env python3
"""
Comprehensive Unit & Adversarial Tests for Social Poster Engine Building Blocks.
"""

import json
import sys
import tempfile
import unittest
from pathlib import Path

# Add scripts directory to path
sys.path.insert(0, str(Path(__file__).parent.parent / "scripts"))

from direct_api_poster import SocialPosterEngine
from hackernews_adapter import HackerNewsAdapter
from mastodon_adapter import MastodonAdapter
from reddit_adapter import RedditAdapter
from common import PostResult


class TestSocialPosterBuildingBlocks(unittest.TestCase):
    def test_adversarial_approval_tokens(self):
        """Verify strict gatekeeper rejection of adversarial substrings."""
        adversarial_inputs = [
            "DO NOT POST APPROVED",
            "POST APPROVEDISH",
            "xPOST APPROVEDx",
            "please post approved",
            "POST APPROVED!",
            "POST APPROVED && rm -rf /",
            "",
            "   ",
        ]
        for token in adversarial_inputs:
            engine = SocialPosterEngine(drafts_dir="/tmp", approval_token=token)
            self.assertFalse(
                engine.verify_approval(),
                f"Failed to reject adversarial token: '{token}'",
            )

        # Valid tokens
        valid_inputs = [
            "POST APPROVED",
            "POST APPROVED   ",
            "POST APPROVED reddit",
            "POST APPROVED reddit,mastodon",
            "POST APPROVED hackernews, reddit, mastodon",
        ]
        for token in valid_inputs:
            engine = SocialPosterEngine(drafts_dir="/tmp", approval_token=token)
            self.assertTrue(
                engine.verify_approval(), f"Failed to accept valid token: '{token}'"
            )

        # Platform allowlist filtering
        engine = SocialPosterEngine(
            drafts_dir="/tmp", approval_token="POST APPROVED reddit,mastodon"
        )
        self.assertTrue(engine.verify_approval("reddit"))
        self.assertTrue(engine.verify_approval("mastodon"))
        self.assertFalse(engine.verify_approval("hackernews"))

    def test_hn_title_clamping_and_validation(self):
        adapter = HackerNewsAdapter()
        # Short title remains intact
        short_title = "Show HN: WorldArchitect – AI TTRPG GM with deterministic rules"
        self.assertEqual(adapter.validate_title(short_title), short_title)

        # Long title clamped <= 80
        long_title = "Show HN: WorldArchitect.AI – An Autonomous Open-Source Multi-Agent Living World Engine with Infinite Memory and Server-Enforced Anti-Cheat Mechanics"
        clamped = adapter.validate_title(long_title)
        self.assertLessEqual(len(clamped), 80)
        self.assertTrue(clamped.endswith("..."))

        # Validation errors on over-length title without clamp
        errors = adapter.validate_draft(
            {"title": long_title, "url": "https://example.com"}
        )
        self.assertTrue(any("exceeds Hacker News 80-character" in e for e in errors))

    def test_mastodon_exact_23char_url_accounting(self):
        adapter = MastodonAdapter()
        text = (
            "Explore WorldArchitect.AI:\n"
            "http://worldarchitect.ai/shared/t3hKKtzBKCKlvg5vCnlW_2hxwH3UmzjFq56yi6hQN2Q\n"
            "https://www.linkedin.com/posts/jeffrey-lee-chan_built-a-campaign-sharing-feature-and-of-course-share-7495750291464835074-9p8m\n"
            "#AI #DND"
        )
        adapter.get_instance_config = lambda: {
            "characters_reserved_per_url": 23,
            "max_characters": 500,
        }
        eff_len = adapter.calculate_effective_length(text)
        self.assertEqual(eff_len, len("Explore WorldArchitect.AI:\n\n\n#AI #DND") + 46)

    def test_reddit_zero_semantic_routing_and_fail_closed(self):
        adapter = RedditAdapter(cookies=[])
        adapter.get_subreddit_capabilities = lambda sub: {
            "allow_images": True,
            "flair_required": True if sub == "OpenAI" else False,
        }
        adapter.get_flair_templates = lambda sub: [
            {"id": "flair-123", "text": "Project"},
            {"id": "flair-456", "text": "Discussion"},
        ]

        # Missing flair on flair_required subreddit fails closed
        errors = adapter.validate_draft(
            {"subreddit": "OpenAI", "title": "My Project", "body": "Hello"}
        )
        self.assertTrue(any("mandates link flair" in e for e in errors))

        # Supplying exact valid flair_id passes validation
        valid_errors = adapter.validate_draft(
            {
                "subreddit": "OpenAI",
                "title": "My Project",
                "body": "Hello",
                "flair_id": "flair-123",
            }
        )
        self.assertEqual(valid_errors, [])

    def test_reddit_no_images_fail_closed(self):
        adapter = RedditAdapter(cookies=[])
        adapter.get_subreddit_capabilities = lambda sub: {
            "allow_images": False if sub == "Rag" else True,
            "flair_required": False,
        }

        # Submitting inline images to NO_IMAGES subreddit returns explicit validation error
        body_with_img = "Architecture overview:\n![Architecture](https://example.com/arch.png)\nDetails."
        errors = adapter.validate_draft(
            {"subreddit": "Rag", "title": "RAG in Game Worlds", "body": body_with_img}
        )
        self.assertTrue(any("enforces NO_IMAGES" in e for e in errors))

        # Clean body passes
        clean_body = "Architecture overview:\n[Architecture](https://example.com/arch.png)\nDetails."
        clean_errors = adapter.validate_draft(
            {"subreddit": "Rag", "title": "RAG in Game Worlds", "body": clean_body}
        )
        self.assertEqual(clean_errors, [])

    def test_dry_run_dispatch(self):
        adapter = RedditAdapter(cookies=[])
        adapter.get_subreddit_capabilities = lambda sub: {
            "allow_images": True,
            "flair_required": False,
        }
        res = adapter.publish(
            {"subreddit": "ai_rpg_community", "title": "Test", "body": "Body"},
            dry_run=True,
        )
        self.assertEqual(res.status, "DRY_RUN")

    def test_idempotency_ledger_and_force_override(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp_path = Path(tmpdir)
            posted_json = tmp_path / "posted.json"
            initial_data = [
                {"platform": "hackernews", "status": "LIVE", "url": "https://news.ycombinator.com/item?id=49372160"}
            ]
            with open(posted_json, "w", encoding="utf-8") as f:
                json.dump(initial_data, f)

            from social_ledger import SocialLedger
            mock_ledger = SocialLedger(ledger_file=tmp_path / "mock_global.json")
            engine = SocialPosterEngine(drafts_dir=tmp_path, approval_token="POST APPROVED", global_ledger=mock_ledger)
            self.assertTrue(engine.is_already_posted("hackernews"))
            self.assertFalse(engine.is_already_posted("mastodon"))

            force_engine = SocialPosterEngine(drafts_dir=tmp_path, approval_token="POST APPROVED", force=True)
            self.assertFalse(force_engine.is_already_posted("hackernews"))

            engine.posted_ledger.append(PostResult(platform="mastodon", status="LIVE", url="https://mastodon.social/@user/123"))
            engine.save_posted_log()

            with open(posted_json, encoding="utf-8") as f:
                updated = json.load(f)
            self.assertEqual(len(updated), 2)
            self.assertEqual(updated[0]["platform"], "hackernews")
            self.assertEqual(updated[1]["platform"], "mastodon")


if __name__ == "__main__":
    unittest.main()
