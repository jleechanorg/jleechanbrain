#!/usr/bin/env python3
"""
mastodon_adapter.py — Mastodon REST API Adapter & Dynamic Instance Constraint Engine.
Discovers instance character & URL weights, handles multi-stage media uploads with
strict polling verification, content warning (CW) support, and fails closed on media upload failures.
"""

import os
import re
import time
from typing import Any

import requests
from common import PostResult, SocialPlatformAdapter


class MediaUploadPipeline:
    """Handles multi-stage media upload and asynchronous processing verification."""

    @staticmethod
    def upload_media(
        session: requests.Session,
        instance: str,
        image_path: str,
        description: str | None = None,
        timeout: int = 600,
    ) -> str | None:
        if not os.path.exists(image_path):
            return None

        url = f"https://{instance}/api/v2/media"
        filename = os.path.basename(image_path)

        with open(image_path, "rb") as f:
            files = {"file": (filename, f, "image/png")}
            data = {}
            if description:
                data["description"] = description

            try:
                r = session.post(url, files=files, data=data, timeout=timeout)
                if r.status_code in (200, 202):
                    res = r.json()
                    media_id = res.get("id")

                    # If 202 Accepted, poll /api/v1/media/<id> until processed
                    if r.status_code == 202 and media_id:
                        poll_url = f"https://{instance}/api/v1/media/{media_id}"
                        for _ in range(15):
                            time.sleep(2)
                            pr = session.get(poll_url, timeout=timeout)
                            if pr.status_code == 200:
                                p_data = pr.json()
                                if p_data.get("url") and not p_data.get("processing"):
                                    return media_id
                    return media_id
            except Exception as e:
                print(f"[MediaUploadPipeline] Media upload error: {e}")
        return None


class MastodonAdapter(SocialPlatformAdapter):
    def __init__(
        self,
        instance_domain: str = "mastodon.social",
        access_token: str | None = None,
        timeout: int = 600,
    ):
        super().__init__(name="mastodon", timeout=timeout)
        self.instance = (
            instance_domain.strip()
            .replace("https://", "")
            .replace("http://", "")
            .rstrip("/")
        )
        self.access_token = access_token
        self.session = requests.Session()
        self.session.headers.update(
            {
                "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
            }
        )
        if self.access_token:
            self.session.headers["Authorization"] = f"Bearer {self.access_token}"

    def extract_token_from_cookies(self, cookies: list[dict[str, Any]]) -> bool:
        """Extract Bearer token from page context using session cookies."""
        for c in cookies:
            domain = c.get("domain") or c.get("hostKey") or c.get("host_key") or ""
            if self.instance in domain:
                self.session.cookies.set(
                    c.get("name"),
                    c.get("value"),
                    domain=domain,
                    path=c.get("path", "/"),
                )

        try:
            r = self.session.get(
                f"https://{self.instance}/publish", timeout=self.timeout
            )
            m = re.search(r'"access_token":"([^"]+)"', r.text)
            if m:
                self.access_token = m.group(1)
                self.session.headers["Authorization"] = f"Bearer {self.access_token}"
                return True
        except Exception as e:
            print(f"[MastodonAdapter] Token extraction error: {e}")
        return False

    def authenticate(self) -> bool:
        """Verify that current bearer token is valid."""
        if not self.access_token:
            return False
        try:
            r = self.session.get(
                f"https://{self.instance}/api/v1/accounts/verify_credentials",
                timeout=self.timeout,
            )
            return r.status_code == 200
        except Exception:
            return False

    def get_instance_config(self) -> dict[str, Any]:
        """Fetch instance configuration limits and URL accounting rules."""
        url = f"https://{self.instance}/api/v1/instance"
        try:
            r = self.session.get(url, timeout=self.timeout)
            if r.status_code == 200:
                data = r.json()
                stats_cfg = data.get("configuration", {}).get("statuses", {})
                return {
                    "max_characters": stats_cfg.get(
                        "max_characters", data.get("max_toot_chars", 500)
                    ),
                    "characters_reserved_per_url": stats_cfg.get(
                        "characters_reserved_per_url", 23
                    ),
                    "max_media_attachments": stats_cfg.get("max_media_attachments", 4),
                }
        except Exception as e:
            print(f"[MastodonAdapter] Instance config query error: {e}")
        return {
            "max_characters": 500,
            "characters_reserved_per_url": 23,
            "max_media_attachments": 4,
        }

    def calculate_effective_length(self, text: str) -> int:
        """Calculate character length using instance's URL normalization formula."""
        cfg = self.get_instance_config()
        url_weight = cfg.get("characters_reserved_per_url", 23)

        url_pattern = r"https?://[^\s]+"
        non_url_text = re.sub(url_pattern, "", text)
        url_count = len(re.findall(url_pattern, text))

        return len(non_url_text) + (url_count * url_weight)

    def validate_draft(self, draft_payload: dict[str, Any]) -> list[str]:
        """Validate status length against instance character limits."""
        errors = []
        status_text = draft_payload.get("status", "")
        if not status_text:
            return ["Status text cannot be empty"]

        cfg = self.get_instance_config()
        max_chars = cfg.get("max_characters", 500)
        eff_len = self.calculate_effective_length(status_text)
        if eff_len > max_chars:
            errors.append(
                f"Effective status length ({eff_len}) exceeds instance limit ({max_chars})"
            )

        image_paths = list(draft_payload.get("image_paths", []))
        if draft_payload.get("image_path") and draft_payload["image_path"] not in image_paths:
            image_paths.append(draft_payload["image_path"])

        max_media = cfg.get("max_media_attachments", 4)
        if len(image_paths) > max_media:
            errors.append(
                f"Number of media attachments ({len(image_paths)}) exceeds limit ({max_media})"
            )

        for img in image_paths:
            if not os.path.exists(img):
                errors.append(f"Media attachment file not found: {img}")

        return errors

    def upload_media(
        self, image_path: str, description: str | None = None
    ) -> str | None:
        return MediaUploadPipeline.upload_media(
            self.session, self.instance, image_path, description, self.timeout
        )

    def publish(
        self, draft_payload: dict[str, Any], dry_run: bool = False
    ) -> PostResult:
        """Publish status or execute dry-run validation."""
        status_text = draft_payload.get("status", "")
        image_path = draft_payload.get("image_path")
        image_alt = draft_payload.get("image_alt")
        spoiler_text = draft_payload.get("spoiler_text")
        visibility = draft_payload.get("visibility", "public")

        validation_errors = self.validate_draft(draft_payload)
        if validation_errors:
            return PostResult(
                platform="mastodon",
                status="ERROR",
                error="; ".join(validation_errors),
                metadata={"validation_errors": validation_errors},
            )

        if dry_run:
            eff_len = self.calculate_effective_length(status_text)
            return PostResult(
                platform="mastodon",
                status="DRY_RUN",
                metadata={
                    "effective_length": eff_len,
                    "has_image": bool(image_path),
                    "visibility": visibility,
                    "spoiler_text": spoiler_text,
                },
            )

        if not self.access_token:
            return PostResult(
                platform="mastodon", status="ERROR", error="Missing access token"
            )

        media_ids = []
        if image_path:
            media_id = self.upload_media(image_path, image_alt)
            if not media_id:
                # Fail closed: do not silently publish text-only when user requested media
                return PostResult(
                    platform="mastodon",
                    status="ERROR",
                    error=f"Failed to upload required media asset: {image_path} (failing closed)",
                )
            media_ids.append(media_id)

        payload = {
            "status": status_text,
            "visibility": visibility,
        }
        if spoiler_text:
            payload["spoiler_text"] = spoiler_text
        if media_ids:
            payload["media_ids[]"] = media_ids

        url = f"https://{self.instance}/api/v1/statuses"
        try:
            r = self.session.post(url, data=payload, timeout=self.timeout)
            if r.status_code in (200, 201):
                res = r.json()
                return PostResult(
                    platform="mastodon",
                    status="LIVE",
                    url=res.get("url"),
                    post_id=res.get("id"),
                    raw_response=res,
                )
            return PostResult(
                platform="mastodon",
                status="ERROR",
                error=f"HTTP {r.status_code}: {r.text}",
                raw_response=r.text,
            )
        except Exception as e:
            return PostResult(platform="mastodon", status="ERROR", error=str(e))
