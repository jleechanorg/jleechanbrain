#!/usr/bin/env python3
"""
reddit_adapter.py — Reddit REST API Adapter & Deterministic Constraint Engine.
Validates constraints against /about.json and /link_flair_v2.json.
Enforces zero-semantic-routing: fails closed on missing required flair.
"""

import re
from typing import Any

import requests
from common import PostResult, SocialPlatformAdapter


class SubredditConstraintValidator:
    """Pre-flight validator for subreddit-specific rules and constraints."""

    @staticmethod
    def map_category_to_flair(
        category: str, available_flairs: list[dict[str, Any]]
    ) -> dict[str, Any] | None:
        """Find matching flair template by exact or normalized category name."""
        cat_lower = category.strip().lower()
        for f in available_flairs:
            f_text = f.get("text", "").strip().lower()
            if cat_lower == f_text or cat_lower in f_text or f_text in cat_lower:
                return f
        return None

    @staticmethod
    def validate(
        draft_payload: dict[str, Any],
        capabilities: dict[str, Any] | None,
        available_flairs: list[dict[str, Any]],
    ) -> list[str]:
        errors = []
        subreddit = draft_payload.get("subreddit")
        if not subreddit:
            return ["Missing 'subreddit' in draft payload"]

        title = draft_payload.get("title", "")
        if not title:
            errors.append("Title cannot be empty")
        elif len(title) > 300:
            errors.append(f"Title length ({len(title)}) exceeds 300 characters")

        if capabilities is None:
            errors.append(
                f"Failed to query r/{subreddit} capabilities from /about.json (failing closed)"
            )
            return errors

        # Submission type check (link vs self)
        kind = draft_payload.get("kind", "self")
        allowed_type = capabilities.get("submission_type", "any")
        if allowed_type == "self" and kind == "link":
            errors.append(f"Subreddit r/{subreddit} only allows self (text) posts, but kind is 'link'")
        elif allowed_type == "link" and kind == "self":
            errors.append(f"Subreddit r/{subreddit} only allows link posts, but kind is 'self'")

        # Flair requirement check
        flair_required = capabilities.get("flair_required", False)
        flair_id = draft_payload.get("flair_id")
        flair_text = draft_payload.get("flair_text")
        
        if flair_required and not flair_id:
            matched = (
                next((f for f in available_flairs if f.get("text") == flair_text), None)
                if flair_text
                else None
            )
            if not matched:
                avail_names = [f.get("text") for f in available_flairs]
                errors.append(
                    f"Subreddit r/{subreddit} mandates link flair, but no valid 'flair_id' provided. Available: {avail_names}"
                )

        # Image embed check (NO_IMAGES rule)
        body = draft_payload.get("body", "")
        if not capabilities.get("allow_images", True):
            if re.search(r"!\[.*?\]\(.*?\)", body):
                errors.append(
                    f"Subreddit r/{subreddit} enforces NO_IMAGES, but markdown body contains inline images (![alt](url)). Convert to text links."
                )

        return errors


class RedditAdapter(SocialPlatformAdapter):
    def __init__(
        self,
        cookies: list[dict[str, Any]],
        user_agent: str | None = None,
        timeout: int = 600,
    ):
        super().__init__(name="reddit", timeout=timeout)
        self.session = requests.Session()
        self.session.headers.update(
            {
                "User-Agent": user_agent
                or "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
            }
        )
        for c in cookies:
            domain = c.get("domain") or c.get("hostKey") or c.get("host_key") or ""
            if "reddit.com" in domain:
                self.session.cookies.set(
                    c.get("name"),
                    c.get("value"),
                    domain=domain,
                    path=c.get("path", "/"),
                )
        self.modhash: str | None = None
        self.username: str | None = None

    def authenticate(self) -> bool:
        """Fetch modhash and verify user session."""
        try:
            r = self.session.get(
                "https://www.reddit.com/api/me.json", timeout=self.timeout
            )
            if r.status_code == 200:
                data = r.json().get("data", {})
                self.modhash = data.get("modhash")
                self.username = data.get("name")
                return bool(self.modhash)
        except Exception as e:
            print(f"[RedditAdapter] Auth error: {e}")
        return False

    def get_flair_templates(self, subreddit: str) -> list[dict[str, Any]]:
        """Fetch valid link flair templates for a subreddit."""
        url = f"https://www.reddit.com/r/{subreddit}/api/link_flair_v2.json"
        try:
            r = self.session.get(url, timeout=self.timeout)
            if r.status_code == 200:
                return r.json()
        except Exception as e:
            print(f"[RedditAdapter] Flair query error for r/{subreddit}: {e}")
        return []

    def get_subreddit_capabilities(self, subreddit: str) -> dict[str, Any] | None:
        """Fetch subreddit capabilities from about.json. Returns None if failed."""
        url = f"https://www.reddit.com/r/{subreddit}/about.json"
        try:
            r = self.session.get(url, timeout=self.timeout)
            if r.status_code == 200:
                data = r.json().get("data", {})
                return {
                    "allow_images": data.get("allow_images", False),
                    "allow_videogifs": data.get("allow_videogifs", False),
                    "submission_type": data.get("submission_type", "any"),
                    "flair_required": data.get("link_flair_required", False),
                }
        except Exception as e:
            print(f"[RedditAdapter] About query error for r/{subreddit}: {e}")
        return None

    def validate_draft(self, draft_payload: dict[str, Any]) -> list[str]:
        """Validate subreddit rules, title length, flair requirement, and image permissions."""
        subreddit = draft_payload.get("subreddit")
        if not subreddit:
            return ["Missing 'subreddit' in draft payload"]

        caps = self.get_subreddit_capabilities(subreddit)
        available_flairs = self.get_flair_templates(subreddit) if caps else []

        # Auto-map flair if category/flair_text is provided but no flair_id
        if draft_payload.get("flair_text") and not draft_payload.get("flair_id") and available_flairs:
            matched = SubredditConstraintValidator.map_category_to_flair(
                draft_payload["flair_text"], available_flairs
            )
            if matched:
                draft_payload["flair_id"] = matched.get("id")

        return SubredditConstraintValidator.validate(draft_payload, caps, available_flairs)

    def publish(
        self, draft_payload: dict[str, Any], dry_run: bool = False
    ) -> PostResult:
        """Publish post or execute dry-run validation."""
        subreddit = draft_payload.get("subreddit", "")
        title = draft_payload.get("title", "")
        body = draft_payload.get("body", "")
        kind = draft_payload.get("kind", "self")
        url_link = draft_payload.get("url")
        flair_id = draft_payload.get("flair_id")
        flair_text = draft_payload.get("flair_text")

        validation_errors = self.validate_draft(draft_payload)
        if validation_errors:
            return PostResult(
                platform=f"reddit/r/{subreddit}",
                status="ERROR",
                title=title,
                error="; ".join(validation_errors),
                metadata={"validation_errors": validation_errors},
            )

        if dry_run:
            return PostResult(
                platform=f"reddit/r/{subreddit}",
                status="DRY_RUN",
                title=title,
                metadata={
                    "subreddit": subreddit,
                    "kind": kind,
                    "flair_id": draft_payload.get("flair_id"),
                    "flair_text": flair_text,
                },
            )

        if not self.modhash and not self.authenticate():
            return PostResult(
                platform=f"reddit/r/{subreddit}",
                status="ERROR",
                title=title,
                error="Authentication failed (invalid modhash/session cookies)",
            )

        payload = {
            "api_type": "json",
            "kind": kind,
            "sr": subreddit,
            "title": title[:300],
            "uh": self.modhash,
            "extension": "json",
            "resubmit": "true",
            "sendreplies": "true",
        }
        if kind == "self":
            payload["text"] = body
        elif kind == "link" and url_link:
            payload["url"] = url_link

        if draft_payload.get("flair_id"):
            payload["flair_id"] = draft_payload["flair_id"]
        if flair_text:
            payload["flair_text"] = flair_text

        try:
            r = self.session.post(
                "https://www.reddit.com/api/submit", data=payload, timeout=self.timeout
            )
            res = r.json()
            errors = res.get("json", {}).get("errors", [])
            post_data = res.get("json", {}).get("data", {})
            if post_data.get("url"):
                url = post_data["url"]
                if url.startswith("/"):
                    url = f"https://www.reddit.com{url}"
                return PostResult(
                    platform=f"reddit/r/{subreddit}",
                    status="LIVE",
                    url=url,
                    post_id=post_data.get("id"),
                    title=title,
                    metadata={"flair_id": draft_payload.get("flair_id"), "flair_text": flair_text},
                    raw_response=res,
                )
            return PostResult(
                platform=f"reddit/r/{subreddit}",
                status="ERROR",
                title=title,
                error=str(errors),
                raw_response=res,
            )
        except Exception as e:
            return PostResult(
                platform=f"reddit/r/{subreddit}",
                status="ERROR",
                title=title,
                error=str(e),
            )
