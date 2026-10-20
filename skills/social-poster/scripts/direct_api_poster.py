#!/usr/bin/env python3
"""
direct_api_poster.py — Unified Direct REST API & Gated Social Publisher.
Requires strict exact "POST APPROVED" approval token before executing live network mutations.
Supports --dry-run for complete pre-flight validation without mutating external platforms.
Integrates with persistent ~/.social-poster/ledger.json to enforce:
- Maximum 3 Reddit posts per rolling 24-hour day.
- 72-hour community recency filter.
"""

import argparse
import json
import re
import sys
import time
from datetime import datetime, timezone, timedelta
from pathlib import Path
from typing import Any

from auth_bridge import AuthBridge
from common import PostResult
from hackernews_adapter import HackerNewsAdapter
from mastodon_adapter import MastodonAdapter
from reddit_adapter import RedditAdapter
from social_ledger import get_social_ledger, PostRecord


class SocialPosterEngine:
    def __init__(
        self,
        drafts_dir: str | Path,
        approval_token: str | None = None,
        dry_run: bool = False,
        force: bool = False,
        max_recency_hours: int = 72,
        daily_reddit_limit: int = 3,
        global_ledger: Any = None,
    ):
        self.drafts_dir = Path(drafts_dir)
        self.approval_token = approval_token.strip() if approval_token else ""
        self.dry_run = dry_run
        self.force = force
        self.max_recency_hours = max_recency_hours
        self.daily_reddit_limit = daily_reddit_limit
        self.auth_bridge = AuthBridge()
        self.global_ledger = global_ledger if global_ledger is not None else get_social_ledger()
        self.posted_ledger: list[PostResult] = []
        self.existing_ledger = self._load_existing_ledger()

    def _load_existing_ledger(self) -> list[dict[str, Any]]:
        out_file = self.drafts_dir / "posted.json"
        if out_file.exists():
            try:
                with open(out_file, encoding="utf-8") as f:
                    return json.load(f)
            except Exception:
                return []
        return []

    def get_recently_posted_targets(self, hours: int | None = None) -> set[str]:
        if self.force:
            return set()
        window_hours = hours if hours is not None else self.max_recency_hours
        recent = self.global_ledger.get_recently_posted_targets(hours=window_hours)

        # Also check local posted.json ledger
        cutoff = datetime.now(timezone.utc) - timedelta(hours=window_hours)
        for entry in self.existing_ledger:
            if entry.get("status") == "LIVE" and entry.get("timestamp"):
                try:
                    ts = datetime.fromisoformat(entry["timestamp"])
                    if ts.tzinfo is None:
                        ts = ts.replace(tzinfo=timezone.utc)
                    if ts >= cutoff:
                        recent.add(entry.get("platform", "").lower())
                except Exception:
                    pass
        return recent

    def is_already_posted(self, platform_id: str) -> bool:
        if self.force:
            return False
        recent_targets = self.get_recently_posted_targets()
        plat_lower = platform_id.lower()
        if plat_lower in recent_targets or plat_lower.replace("reddit/r/", "") in recent_targets:
            return True
        for entry in self.existing_ledger:
            if entry.get("platform") == platform_id and entry.get("status") == "LIVE":
                return True
        return False

    def verify_approval(self, target_platform: str | None = None) -> bool:
        if self.dry_run:
            return True

        if not self.approval_token:
            print("[Gatekeeper] DENIED: No approval token provided.")
            return False

        match = re.fullmatch(
            r"^POST APPROVED(?:\s+([a-zA-Z0-9_, -]+))?$", self.approval_token.strip()
        )
        if not match:
            print(
                f"[Gatekeeper] DENIED: Approval token does not match exact format. Got: '{self.approval_token}'"
            )
            return False

        allowlist_str = match.group(1)
        if allowlist_str and target_platform:
            allowed = [p.strip().lower() for p in allowlist_str.split(",") if p.strip()]
            if target_platform.lower() not in allowed:
                print(
                    f"[Gatekeeper] SKIPPED: Platform '{target_platform}' not in allowlist {allowed}"
                )
                return False

        return True

    def delete_post(self, thing_id: str, delete_token: str | None = None) -> bool:
        """Strictly gates post deletion behind literal 'POST DELETE APPROVED' token."""
        if not delete_token or delete_token.strip() != "POST DELETE APPROVED":
            raise PermissionError(
                "POST DELETIONS ARE STRICTLY FORBIDDEN: Agents must NEVER delete, retract, "
                "or call deletion endpoints on published social posts unless the current live "
                "user message explicitly contains the exact phrase 'POST DELETE APPROVED'."
            )
        print(f"[Gatekeeper] Deletion approved with token 'POST DELETE APPROVED' for {thing_id}")
        return True

    def publish_reddit(
        self, manifest: dict[str, Any], subreddits: list[str]
    ) -> list[PostResult]:
        """Publish or validate Reddit drafts, enforcing daily cap (max 3) and 72h recency."""
        if not self.verify_approval("reddit"):
            return []

        cookies = self.auth_bridge.decrypt_cookies_via_browserclaw(
            domain_filter="%reddit.com%"
        )
        adapter = RedditAdapter(cookies)

        if not self.dry_run and not adapter.authenticate():
            print("[Reddit] Failed to authenticate with decrypted cookies.")
            return [
                PostResult(
                    platform="reddit", status="ERROR", error="Unauthenticated session"
                )
            ]

        results = []
        recent_posted = self.get_recently_posted_targets()

        for idx, sub in enumerate(subreddits):
            target_id = f"reddit/r/{sub}"
            
            # Check 72h recency & daily limit
            can_post, reason = self.global_ledger.can_post_reddit(
                sub=sub,
                daily_limit=self.daily_reddit_limit,
                recency_hours=self.max_recency_hours,
                force=self.force
            )
            if not can_post and not self.dry_run:
                print(f"[Reddit] SKIPPED: {target_id} -> {reason}")
                res = PostResult(
                    platform=target_id,
                    status="SKIPPED",
                    error=reason,
                )
                results.append(res)
                continue

            draft_file = self.drafts_dir / f"reddit_{sub}.md"
            if not draft_file.exists():
                draft_file = self.drafts_dir / "reddit.md"

            if not draft_file.exists():
                print(f"[Reddit] Draft file not found for r/{sub}")
                continue

            with open(draft_file, encoding="utf-8") as f:
                content = f.read()

            title = "WorldAI Update"
            body = content
            if "## Title" in content and "## Body" in content:
                parts = content.split("## Body", 1)
                t_part = parts[0].split("## Title", 1)[1].strip()
                title = t_part.splitlines()[0].strip()
                body = parts[1].strip()

            payload = {
                "subreddit": sub,
                "title": title,
                "body": body,
                "kind": manifest.get("reddit_kind", "self"),
                "url": manifest.get("primary_link"),
                "flair_id": manifest.get("flair_ids", {}).get(sub),
                "flair_text": manifest.get("flair_map", {}).get(sub),
            }

            print(
                f"[Reddit] {'Validating (Dry Run)' if self.dry_run else 'Publishing'} to r/{sub}..."
            )
            res = adapter.publish(payload, dry_run=self.dry_run)
            results.append(res)
            self.posted_ledger.append(res)
            
            # Record into persistent global ledger
            if res.status == "LIVE":
                self.global_ledger.record_post(
                    platform="reddit",
                    target=f"r/{sub}",
                    url=res.url,
                    title=title,
                    status="LIVE",
                    post_id=res.post_id,
                )

            if not self.dry_run and idx < len(subreddits) - 1:
                sleep_time = 2 * (idx + 1)
                time.sleep(min(sleep_time, 10))

        return results

    def publish_hackernews(self, manifest: dict[str, Any]) -> PostResult | None:
        if not self.verify_approval("hackernews"):
            return None

        if self.is_already_posted("hackernews"):
            print(f"[HackerNews] SKIPPED: hackernews was posted to within the last {self.max_recency_hours}h.")
            res = PostResult(
                platform="hackernews",
                status="SKIPPED",
                error=f"Recently posted within {self.max_recency_hours}h (recency guard)",
            )
            self.posted_ledger.append(res)
            return res

        creds = self.auth_bridge.decrypt_saved_login("news.ycombinator.com")
        adapter = HackerNewsAdapter()

        if not self.dry_run:
            if not creds or not adapter.login(creds["user"], creds["password"]):
                print("[HackerNews] Failed to authenticate via Chrome Safe Storage.")
                return PostResult(
                    platform="hackernews",
                    status="ERROR",
                    error="Unauthenticated session",
                )

        draft_file = self.drafts_dir / "hackernews.md"
        title = manifest.get(
            "title",
            "Show HN: WorldArchitect.AI – AI TTRPG GM with rules & campaign sharing",
        )
        url = manifest.get("primary_link", "http://worldarchitect.ai")
        comment_text = None

        if draft_file.exists():
            with open(draft_file, encoding="utf-8") as f:
                comment_text = f.read().strip()

        payload = {
            "title": title,
            "url": url,
            "first_comment": comment_text,
        }

        print(
            f"[HackerNews] {'Validating (Dry Run)' if self.dry_run else 'Submitting'} Show HN story..."
        )
        res = adapter.publish(payload, dry_run=self.dry_run)
        self.posted_ledger.append(res)
        if res.status == "LIVE":
            self.global_ledger.record_post(
                platform="hackernews",
                target="hackernews",
                url=res.url,
                title=title,
                status="LIVE",
                post_id=res.post_id,
            )
        return res

    def publish_mastodon(self, manifest: dict[str, Any]) -> PostResult | None:
        if not self.verify_approval("mastodon"):
            return None

        if self.is_already_posted("mastodon"):
            print(f"[Mastodon] SKIPPED: mastodon was posted to within the last {self.max_recency_hours}h.")
            res = PostResult(
                platform="mastodon",
                status="SKIPPED",
                error=f"Recently posted within {self.max_recency_hours}h (recency guard)",
            )
            self.posted_ledger.append(res)
            return res

        instance = manifest.get("mastodon_instance", "mastodon.social")
        adapter = MastodonAdapter(instance_domain=instance)

        if not self.dry_run:
            cookies = self.auth_bridge.decrypt_cookies_via_browserclaw(
                domain_filter=f"%{instance}%"
            )
            if not adapter.extract_token_from_cookies(cookies):
                print(f"[Mastodon] Failed to extract session token for {instance}")
                return PostResult(
                    platform="mastodon", status="ERROR", error="Token extraction failed"
                )

        draft_file = self.drafts_dir / "mastodon.md"
        status_text = ""
        if draft_file.exists():
            with open(draft_file, encoding="utf-8") as f:
                status_text = f.read().strip()

        payload = {
            "status": status_text,
            "image_path": manifest.get("image_path"),
            "image_alt": manifest.get("image_alt"),
            "spoiler_text": manifest.get("spoiler_text"),
            "visibility": "public",
        }

        print(
            f"[Mastodon] {'Validating (Dry Run)' if self.dry_run else 'Publishing'} status..."
        )
        res = adapter.publish(payload, dry_run=self.dry_run)
        self.posted_ledger.append(res)
        if res.status == "LIVE":
            self.global_ledger.record_post(
                platform="mastodon",
                target=f"mastodon/@{instance}",
                url=res.url,
                title=status_text[:60],
                status="LIVE",
                post_id=res.post_id,
            )
        return res

    def save_posted_log(self):
        out_file = self.drafts_dir / "posted.json"
        existing_data = []
        if out_file.exists():
            try:
                with open(out_file, encoding="utf-8") as f:
                    existing_data = json.load(f)
            except Exception:
                existing_data = []

        new_entries = [r.to_dict() for r in self.posted_ledger]
        combined = existing_data + new_entries

        with open(out_file, "w", encoding="utf-8") as f:
            json.dump(combined, f, indent=2)
        print(f"[SocialPosterEngine] Local execution ledger saved to: {out_file}")
        print(f"[SocialPosterEngine] Global ledger synced at: {self.global_ledger.ledger_file}")


def main():
    parser = argparse.ArgumentParser(
        description="Unified Direct REST API Social Media Publisher"
    )
    parser.add_argument(
        "--drafts",
        required=True,
        help="Directory containing staged drafts & manifest.json",
    )
    parser.add_argument(
        "--approval-token", help="Explicit approval token ('POST APPROVED')"
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Execute complete constraint validation without network mutations",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Bypass idempotency, daily caps, and 72h recency checks and force re-posting",
    )
    parser.add_argument(
        "--max-recency-hours",
        type=int,
        default=72,
        help="Skip platforms/subreddits posted within this many hours (default: 72)",
    )
    parser.add_argument(
        "--daily-reddit-limit",
        type=int,
        default=3,
        help="Maximum Reddit posts allowed per 24-hour window (default: 3)",
    )
    parser.add_argument(
        "--platforms",
        help="Comma-separated platforms to publish (default: all approved)",
    )
    args = parser.parse_args()

    if not args.dry_run and not args.approval_token:
        print(
            "[Error] Either --dry-run or --approval-token 'POST APPROVED' is required."
        )
        sys.exit(2)

    engine = SocialPosterEngine(
        drafts_dir=args.drafts,
        approval_token=args.approval_token,
        dry_run=args.dry_run,
        force=args.force,
        max_recency_hours=args.max_recency_hours,
        daily_reddit_limit=args.daily_reddit_limit,
    )
    if not engine.verify_approval():
        sys.exit(2)

    manifest_file = Path(args.drafts) / "manifest.json"
    manifest = {}
    if manifest_file.exists():
        with open(manifest_file, encoding="utf-8") as f:
            manifest = json.load(f)

    target_platforms = (
        [p.strip().lower() for p in args.platforms.split(",")]
        if args.platforms
        else ["reddit", "hackernews", "mastodon"]
    )

    if "reddit" in target_platforms:
        subs = manifest.get(
            "reddit_subs",
            ["GeminiAI", "solorpgplay", "indiegames"],
        )
        engine.publish_reddit(manifest, subs)

    if "hackernews" in target_platforms:
        engine.publish_hackernews(manifest)

    if "mastodon" in target_platforms:
        engine.publish_mastodon(manifest)

    engine.save_posted_log()
    print("Execution complete.")


if __name__ == "__main__":
    main()
