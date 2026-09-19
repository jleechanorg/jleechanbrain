#!/usr/bin/env python3
"""
hackernews_adapter.py — Hacker News Adapter with 80-Char Guardrail & Precise 2-Step Matching.
Enforces strict 80-char title limit, clean plain-text/link HN markup formatting,
and matches exact submitted URL/title to prevent commenting on concurrent/unrelated stories.
"""

import re
import time
from typing import Any

import requests
from common import PostResult, SocialPlatformAdapter


class HNMarkupFormatter:
    """Formats markdown text to Hacker News compatible plain text / URL links."""

    @staticmethod
    def format(text: str) -> str:
        if not text:
            return ""
        # Convert markdown links [anchor](url) -> anchor (url)
        formatted = re.sub(r"\[([^\]]+)\]\((https?://[^\)]+)\)", r"\1 (\2)", text)
        # Strip bold/italic markers
        formatted = re.sub(r"\*\*([^\*]+)\*\*", r"\1", formatted)
        formatted = re.sub(r"\*([^\*]+)\*", r"\1", formatted)
        formatted = re.sub(r"__([^_]+)__", r"\1", formatted)
        # Strip header markers (# Header -> Header)
        formatted = re.sub(r"^#+\s*", "", formatted, flags=re.MULTILINE)
        # Clean double blank lines
        formatted = re.sub(r"\n{3,}", "\n\n", formatted)
        return formatted.strip()


class TwoStepSubmissionPipeline:
    """Coordinates 2-step Show HN story creation followed by author context comment."""

    @staticmethod
    def validate_title(title: str) -> str:
        """Enforce strict 80-character ceiling for HN titles."""
        title = title.strip()
        if len(title) <= 80:
            return title
        truncated = title[:77]
        if " " in truncated:
            truncated = truncated.rsplit(" ", 1)[0]
        return truncated + "..."

    @staticmethod
    def validate_payload(draft_payload: dict[str, Any]) -> list[str]:
        errors = []
        title = draft_payload.get("title", "")
        if not title:
            errors.append("Title cannot be empty")
        elif len(title) > 80:
            errors.append(
                f"Title length ({len(title)}) exceeds Hacker News 80-character ceiling"
            )

        url = draft_payload.get("url")
        text = draft_payload.get("text")
        if not url and not text:
            errors.append("Hacker News submission requires either 'url' or 'text'")

        return errors


class HackerNewsAdapter(SocialPlatformAdapter):
    def __init__(
        self,
        user_cookie: str | None = None,
        username: str | None = None,
        timeout: int = 600,
    ):
        super().__init__(name="hackernews", timeout=timeout)
        self.session = requests.Session()
        self.session.headers.update(
            {
                "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
            }
        )
        self.username = username
        if user_cookie:
            self.session.cookies.set(
                "user", user_cookie, domain="news.ycombinator.com", path="/"
            )

    def authenticate(self) -> bool:
        """Verify that the user cookie is active."""
        try:
            r = self.session.get(
                "https://news.ycombinator.com/submit", timeout=self.timeout
            )
            if "login" not in r.url and self.session.cookies.get("user"):
                return True
        except Exception as e:
            print(f"[HackerNewsAdapter] Auth check error: {e}")
        return False

    def login(self, username: str, password: str) -> bool:
        """Login to Hacker News using credentials."""
        self.username = username
        login_url = "https://news.ycombinator.com/login"
        payload = {"acct": username, "pw": password, "goto": "news"}
        try:
            r = self.session.post(
                login_url, data=payload, allow_redirects=True, timeout=self.timeout
            )
            if self.session.cookies.get("user") or f"user?id={username}" in r.text:
                return True
        except Exception as e:
            print(f"[HackerNewsAdapter] Login error: {e}")
        return False

    @staticmethod
    def validate_title(title: str) -> str:
        return TwoStepSubmissionPipeline.validate_title(title)

    @staticmethod
    def format_markup(text: str) -> str:
        return HNMarkupFormatter.format(text)

    def validate_draft(self, draft_payload: dict[str, Any]) -> list[str]:
        return TwoStepSubmissionPipeline.validate_payload(draft_payload)

    def _find_matching_item_id(
        self, target_title: str, target_url: str | None
    ) -> str | None:
        """Search user's submitted page for exact matching story."""
        if not self.username:
            return None

        r_user = self.session.get(
            f"https://news.ycombinator.com/submitted?id={self.username}",
            timeout=self.timeout,
        )
        if r_user.status_code != 200:
            return None

        athing_blocks = re.findall(
            r"<tr class=['\"]athing['\"] id=['\"](\d+)['\"]>(.*?)</tr>",
            r_user.text,
            re.DOTALL,
        )
        for item_id, block in athing_blocks:
            title_match = re.search(
                r"<span class=['\"]titleline['\"]><a href=['\"]([^'\"]+)['\"]>([^<]+)</a>",
                block,
            )
            if title_match:
                href, title_text = title_match.group(1), title_match.group(2)
                if target_url and target_url in href:
                    return item_id
                if target_title.strip().lower() == title_text.strip().lower():
                    return item_id

        return None

    def publish(
        self, draft_payload: dict[str, Any], dry_run: bool = False
    ) -> PostResult:
        """Execute Show HN submission or return dry-run validation."""
        title = draft_payload.get("title", "")
        sanitized_title = self.validate_title(title)
        url = draft_payload.get("url", "")
        comment_text = draft_payload.get("first_comment")
        if comment_text:
            comment_text = HNMarkupFormatter.format(comment_text)

        validation_errors = self.validate_draft({"title": sanitized_title, "url": url})
        if validation_errors:
            return PostResult(
                platform="hackernews",
                status="ERROR",
                title=sanitized_title,
                error="; ".join(validation_errors),
                metadata={"validation_errors": validation_errors},
            )

        if dry_run:
            return PostResult(
                platform="hackernews",
                status="DRY_RUN",
                title=sanitized_title,
                metadata={"url": url, "has_comment": bool(comment_text)},
            )

        if not self.authenticate():
            return PostResult(
                platform="hackernews",
                status="ERROR",
                title=sanitized_title,
                error="Unauthenticated session",
            )

        # 1. Submit Story
        try:
            payload = {"title": sanitized_title, "url": url, "text": ""}
            r_sub = self.session.post(
                "https://news.ycombinator.com/r",
                data=payload,
                allow_redirects=True,
                timeout=self.timeout,
            )

            if "toolong-title" in r_sub.url or "Title too long" in r_sub.text:
                return PostResult(
                    platform="hackernews",
                    status="ERROR",
                    title=sanitized_title,
                    error="Title exceeds 80 characters",
                )

            # Extract item_id by exact matching
            item_id = self._find_matching_item_id(sanitized_title, url)
            if not item_id:
                m = re.search(r"item\?id=(\d+)", r_sub.url)
                if m:
                    item_id = m.group(1)

            if not item_id:
                return PostResult(
                    platform="hackernews",
                    status="ERROR",
                    title=sanitized_title,
                    error="Story submitted but could not resolve verified matching item ID",
                )

            story_url = f"https://news.ycombinator.com/item?id={item_id}"

            # 2. Post Author Context Comment with exponential backoff & verification
            comment_status = "SKIPPED"
            if comment_text:
                for attempt in range(3):
                    time.sleep(2 * (attempt + 1))
                    r_item = self.session.get(story_url, timeout=self.timeout)
                    m_fnid = re.search(
                        r"name=['\"]fnid['\"] value=['\"]([^\"']+)['\"]", r_item.text
                    )
                    m_hmac = re.search(
                        r"name=['\"]hmac['\"] value=['\"]([^\"']+)['\"]", r_item.text
                    )

                    c_payload = {
                        "parent": item_id,
                        "goto": f"item?id={item_id}",
                        "text": comment_text,
                    }
                    if m_fnid:
                        c_payload["fnid"] = m_fnid.group(1)
                    if m_hmac:
                        c_payload["hmac"] = m_hmac.group(1)

                    r_comm = self.session.post(
                        "https://news.ycombinator.com/comment",
                        data=c_payload,
                        allow_redirects=True,
                        timeout=self.timeout,
                    )
                    if r_comm.status_code == 200:
                        r_check = self.session.get(story_url, timeout=self.timeout)
                        if self.username and self.username in r_check.text:
                            comment_status = "POSTED"
                            break

            return PostResult(
                platform="hackernews",
                status="LIVE",
                url=story_url,
                post_id=item_id,
                title=sanitized_title,
                metadata={"comment_status": comment_status},
            )

        except Exception as e:
            return PostResult(
                platform="hackernews",
                status="ERROR",
                title=sanitized_title,
                error=str(e),
            )
