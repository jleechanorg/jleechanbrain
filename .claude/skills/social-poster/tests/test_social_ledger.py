import json
import pytest
from datetime import datetime, timezone, timedelta
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
from social_ledger import SocialLedger, PostRecord


class TestSocialLedger:
    @pytest.fixture
    def temp_ledger(self, tmp_path):
        ledger_file = tmp_path / "test_ledger.json"
        return SocialLedger(ledger_file=ledger_file)

    def test_record_and_persist(self, temp_ledger):
        rec = temp_ledger.record_post(
            platform="reddit",
            target="r/GeminiAI",
            url="https://reddit.com/r/GeminiAI/comments/123",
            title="Gemini AI Stack",
            status="LIVE",
            post_id="test_123",
        )
        assert rec.target == "r/GeminiAI"
        assert len(temp_ledger.records) == 1

        # Reload from disk
        reloaded = SocialLedger(ledger_file=temp_ledger.ledger_file)
        assert len(reloaded.records) == 1
        assert reloaded.records[0].post_id == "test_123"

    def test_daily_reddit_limit_enforcement(self, temp_ledger):
        # Add 3 reddit posts in the last 2 hours
        now = datetime.now(timezone.utc)
        for i in range(3):
            temp_ledger.record_post(
                platform="reddit",
                target=f"r/Sub_{i}",
                status="LIVE",
                post_id=f"p_{i}",
            )
        assert temp_ledger.get_reddit_posts_count(24) == 3

        # 4th reddit post should be blocked
        can_post, reason = temp_ledger.can_post_reddit("r/NewSub", daily_limit=3)
        assert can_post is False
        assert "Daily Reddit cap reached" in reason

        # Force override allows posting
        can_post_forced, _ = temp_ledger.can_post_reddit("r/NewSub", daily_limit=3, force=True)
        assert can_post_forced is True

    def test_72h_recency_filter(self, temp_ledger):
        # Record a post to r/solorpgplay 10 hours ago
        past_time = (datetime.now(timezone.utc) - timedelta(hours=10)).isoformat()
        rec = PostRecord(
            platform="reddit",
            target="r/solorpgplay",
            title="Solo RPG",
            status="LIVE",
            timestamp=past_time,
            post_id="solo_1",
        )
        temp_ledger.records.append(rec)
        temp_ledger.save()

        # Should be blocked due to recency
        can_post, reason = temp_ledger.can_post_reddit("solorpgplay", daily_limit=5, recency_hours=72)
        assert can_post is False
        assert "posted to within the last 72 hours" in reason

        # An unposted sub should pass
        can_post_fresh, _ = temp_ledger.can_post_reddit("indiegames", daily_limit=5, recency_hours=72)
        assert can_post_fresh is True
