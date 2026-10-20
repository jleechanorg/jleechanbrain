#!/usr/bin/env python3
"""
Unit & Adversarial Tests for MediaUploadPipeline and MastodonAdapter.
"""

import unittest
from unittest.mock import MagicMock
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).parent.parent / "scripts"))

from mastodon_adapter import MastodonAdapter, MediaUploadPipeline


class TestMastodonAdapter(unittest.TestCase):
    def test_async_media_polling_simulation(self):
        session = MagicMock()
        
        upload_resp = MagicMock()
        upload_resp.status_code = 202
        upload_resp.json.return_value = {"id": "media_999"}
        session.post.return_value = upload_resp

        poll_resp = MagicMock()
        poll_resp.status_code = 200
        poll_resp.json.return_value = {"id": "media_999", "url": "https://mastodon.social/media/999.png", "processing": False}
        session.get.return_value = poll_resp

        import tempfile
        with tempfile.NamedTemporaryFile(suffix=".png") as tmp:
            media_id = MediaUploadPipeline.upload_media(
                session=session,
                instance="mastodon.social",
                image_path=tmp.name,
                description="Sample Alt Text",
            )
            self.assertEqual(media_id, "media_999")

    def test_content_warning_support_in_payload(self):
        adapter = MastodonAdapter(access_token="valid_token")
        adapter.get_instance_config = lambda: {"max_characters": 500, "characters_reserved_per_url": 23}
        
        payload = {
            "status": "Check out this reveal",
            "spoiler_text": "Story Spoilers",
        }
        res = adapter.publish(payload, dry_run=True)
        self.assertEqual(res.status, "DRY_RUN")
        self.assertEqual(res.metadata.get("spoiler_text"), "Story Spoilers")


if __name__ == "__main__":
    unittest.main()
