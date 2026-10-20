#!/usr/bin/env python3
"""
social_ledger.py — Persistent Global Social Distribution Ledger.
Stored in ~/.social-poster/ledger.json. Tracks all published posts, subreddits,
external sites, timestamps, and permalinks.
Enforces the 3-Reddit-daily cap and 72h community recency rules.
"""

import json
import os
import sys
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone, timedelta
from pathlib import Path
from typing import Any


GLOBAL_LEDGER_DIR = Path.home() / ".social-poster"
GLOBAL_LEDGER_FILE = GLOBAL_LEDGER_DIR / "ledger.json"


@dataclass
class PostRecord:
    platform: str
    target: str  # e.g. "r/GeminiAI", "twitter", "hackernews"
    url: str | None = None
    title: str | None = None
    status: str = "LIVE"  # "LIVE", "FAILED", "SKIPPED"
    timestamp: str = field(default_factory=lambda: datetime.now(timezone.utc).isoformat())
    post_id: str | None = None
    metadata: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "PostRecord":
        return cls(
            platform=data.get("platform", ""),
            target=data.get("target", data.get("platform", "")),
            url=data.get("url"),
            title=data.get("title"),
            status=data.get("status", "LIVE"),
            timestamp=data.get("timestamp", datetime.now(timezone.utc).isoformat()),
            post_id=data.get("post_id"),
            metadata=data.get("metadata", {}),
        )


class SocialLedger:
    def __init__(self, ledger_file: Path | str = GLOBAL_LEDGER_FILE):
        self.ledger_file = Path(ledger_file).expanduser().resolve()
        self.ledger_file.parent.mkdir(parents=True, exist_ok=True)
        self.records: list[PostRecord] = self._load()

    def _load(self) -> list[PostRecord]:
        if not self.ledger_file.exists():
            return []
        try:
            with open(self.ledger_file, "r", encoding="utf-8") as f:
                data = json.load(f)
                return [PostRecord.from_dict(d) for d in data]
        except Exception as e:
            print(f"[SocialLedger] Warning: Failed to load {self.ledger_file}: {e}")
            return []

    def save(self) -> None:
        try:
            with open(self.ledger_file, "w", encoding="utf-8") as f:
                json.dump([r.to_dict() for r in self.records], f, indent=2)
            # Also mirror to ~/roadmap/social/social_posted_ledger.json if directory exists
            mirror_dir = Path.home() / "roadmap" / "social"
            if mirror_dir.exists():
                mirror_file = mirror_dir / "social_posted_ledger.json"
                with open(mirror_file, "w", encoding="utf-8") as mf:
                    json.dump([r.to_dict() for r in self.records], mf, indent=2)
        except Exception as e:
            print(f"[SocialLedger] Error saving {self.ledger_file}: {e}")

    def record_post(
        self,
        platform: str,
        target: str,
        url: str | None = None,
        title: str | None = None,
        status: str = "LIVE",
        post_id: str | None = None,
        metadata: dict[str, Any] | None = None,
    ) -> PostRecord:
        record = PostRecord(
            platform=platform,
            target=target,
            url=url,
            title=title,
            status=status,
            post_id=post_id,
            metadata=metadata or {},
        )
        self.records.append(record)
        self.save()
        return record

    def get_recent_posts(self, hours: int = 72) -> list[PostRecord]:
        cutoff = datetime.now(timezone.utc) - timedelta(hours=hours)
        res = []
        for r in self.records:
            if r.status != "LIVE":
                continue
            try:
                ts = datetime.fromisoformat(r.timestamp)
                if ts.tzinfo is None:
                    ts = ts.replace(tzinfo=timezone.utc)
                if ts >= cutoff:
                    res.append(r)
            except Exception:
                continue
        return res

    def get_recently_posted_targets(self, hours: int = 72) -> set[str]:
        recent = set()
        for r in self.get_recent_posts(hours=hours):
            t = r.target.lower()
            recent.add(t)
            recent.add(t.replace("reddit/", "").replace("r/", ""))
            recent.add(r.platform.lower())
        return recent

    def get_reddit_posts_count(self, hours: int = 24) -> int:
        """Count Reddit posts published within rolling window (default 24h)."""
        cutoff = datetime.now(timezone.utc) - timedelta(hours=hours)
        count = 0
        for r in self.records:
            if r.status == "LIVE" and (r.platform == "reddit" or "r/" in r.target.lower() or "reddit" in r.target.lower()):
                try:
                    ts = datetime.fromisoformat(r.timestamp)
                    if ts.tzinfo is None:
                        ts = ts.replace(tzinfo=timezone.utc)
                    if ts >= cutoff:
                        count += 1
                except Exception:
                    continue
        return count

    def can_post_reddit(
        self, sub: str, daily_limit: int = 3, recency_hours: int = 72, force: bool = False
    ) -> tuple[bool, str]:
        """
        Check if a given subreddit can be posted to today.
        Enforces:
        1. Max daily limit (3 reddits per 24 hours).
        2. Recency check (no post to same sub in last 72 hours).
        """
        if force:
            return True, "Force flag active"

        # Check recency
        sub_norm = sub.lower().replace("r/", "").replace("reddit/", "")
        recent_targets = self.get_recently_posted_targets(hours=recency_hours)
        if sub_norm in recent_targets or f"r/{sub_norm}" in recent_targets:
            return False, f"Subreddit r/{sub_norm} was posted to within the last {recency_hours} hours."

        # Check daily count
        daily_count = self.get_reddit_posts_count(hours=24)
        if daily_count >= daily_limit:
            return False, f"Daily Reddit cap reached ({daily_count}/{daily_limit} posts in last 24h). Try again tomorrow."

        return True, f"OK ({daily_count}/{daily_limit} posts used today)"

    def sync_with_reddit_api(self, cookies: list[dict[str, Any]]) -> int:
        """Sync live Reddit submissions into the global ledger."""
        import requests
        session = requests.Session()
        for c in cookies:
            domain = c.get("domain") or c.get("hostKey") or c.get("host_key") or ""
            if "reddit.com" in domain:
                session.cookies.set(c.get("name"), c.get("value"), domain=domain, path=c.get("path", "/"))
        session.headers.update({
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"
        })
        added = 0
        try:
            r_me = session.get("https://www.reddit.com/api/me.json", timeout=10)
            if r_me.status_code != 200:
                return 0
            username = r_me.json().get("data", {}).get("name")
            if not username:
                return 0

            r_sub = session.get(f"https://www.reddit.com/user/{username}/submitted.json?limit=50", timeout=10)
            if r_sub.status_code != 200:
                return 0

            existing_ids = {r.post_id for r in self.records if r.post_id}
            children = r_sub.json().get("data", {}).get("children", [])
            for child in children:
                d = child.get("data", {})
                pid = d.get("id")
                if pid and pid in existing_ids:
                    continue
                sub = d.get("subreddit", "")
                created_utc = d.get("created_utc", 0)
                dt = datetime.fromtimestamp(created_utc, timezone.utc)
                permalink = f"https://www.reddit.com{d.get('permalink', '')}"
                record = PostRecord(
                    platform="reddit",
                    target=f"r/{sub}",
                    url=permalink,
                    title=d.get("title"),
                    status="LIVE",
                    timestamp=dt.isoformat(),
                    post_id=pid,
                    metadata={"author": username, "score": d.get("score", 0)},
                )
                self.records.append(record)
                existing_ids.add(pid)
                added += 1

            if added > 0:
                self.save()
        except Exception as e:
            print(f"[SocialLedger] Sync note: {e}")
        return added


# Singleton instance helper
_ledger_instance = None

def get_social_ledger() -> SocialLedger:
    global _ledger_instance
    if _ledger_instance is None:
        _ledger_instance = SocialLedger()
    return _ledger_instance


if __name__ == "__main__":
    ledger = get_social_ledger()
    print(f"Loaded {len(ledger.records)} records from {ledger.ledger_file}")
    recent = ledger.get_recent_posts(72)
    print(f"Posts in last 72h: {len(recent)}")
    for r in recent:
        print(f"  [{r.timestamp}] {r.platform} -> {r.target} ({r.url or r.title})")
    count_24h = ledger.get_reddit_posts_count(24)
    print(f"Reddit posts in last 24h: {count_24h}/3")
