#!/usr/bin/env python3
"""
reddit-competitor-complaints.py — daily 8:00 AM PT launchd job.

Finds top Reddit threads where people complain about (or compare) AI
Dungeon, Friends & Fables, and Voyage. Emits a deduplicated top-10
digest (sorted by relevance) between the markers:

    === Reddit competitor-complaints digest ===
    ...per-thread blocks...
    ---

The shell wrapper parses everything between the open/close markers and
posts it to Slack. Do not change the marker strings without updating
~/.smartclaw/scripts/reddit-competitor-complaints.sh accordingly.

Data source: PullPush.io (community-run Pushshift successor).

Why PullPush, not headless browser?
  - 2026-06-23: every public search engine (Brave, Mojeek, DDG, Bing,
    Kagi, you.com, Searx, Marginalia, Qwant) rate-limited or captcha-
    walled the MacBook's IP within 2-4 queries. Even Playwright
    Chromium with a desktop UA got 429 from Brave and a "Just a moment"
    captcha page on Google/DDG/Bing.
  - Reddit's own anonymous .json search returns 403 (verified 2026-06-23).
  - PullPush.io is a free, no-auth, no-rate-limit Pushshift mirror. It
    returns the same submission JSON (id, title, selftext, score,
    num_comments, subreddit, permalink, created_utc). Verified working
    via `curl https://api.pullpush.io/reddit/search/submission/...`
    with a custom User-Agent, ~60 req/min sustained, no captchas.
  - Cost: $0/mo. No Vercel/AWS credentials needed.

Staging source: ~/.smartclaw/scripts/reddit-competitor-complaints.py
Deployed copy:  ~/.smartclaw/scripts/reddit-competitor-complaints.py
Plist:          ~/Library/LaunchAgents/ai.smartclaw.schedule.reddit-competitor-complaints.plist
Logs:           ~/.smartclaw/logs/scheduled-jobs/reddit-competitor-complaints.{out,err}.log
"""

from __future__ import annotations

import json
import math
import os
import subprocess
import sys
import time
import urllib.parse

USER_AGENT = "hermes-reddit-monitor/1.0 (jleechan)"


# ---------------------------------------------------------------------------
# Pain-point lexicon — used to rank "complaint-ish" threads higher than
# generic fan posts or dev updates. Keep additions narrow: each new word
# adds noise if it shows up in non-complaint contexts. Tuned 2026-06-23.
# ---------------------------------------------------------------------------
PAIN_WORDS = (
    "nsfw", "filter", "censorship", "censored", "banned", "latitude",
    "alternative", "instead", "recommend", "better than", "rather use",
    "broken", "unplayable", "paywalled", "subscription", "expensive",
    "open source", "self-host", "self host", "dragon", "wyvern", "griffin",
    "goodbye", "left", "leaving", "quit", "stopped using", "stopped playing",
    "suck", "sucks", "garbage", "terrible", "disappoint", "disappointed",
    "frustrated", "bug", "crash", "error", "unhappy", "scam", "boycott",
    "no longer", "looking for", "is there a", "dropped", "refund", "lapsed",
    "hate", "is it just me", "am i the only", "any good", "any better",
    "worse", "downgrade", "regress",
)
POS_WORDS = (
    "love", "obsessed", "amazing", "awesome", "best ever", "first time",
    "new user", "loving it", "really good", "fantastic", "incredible",
    "10/10", "must try", "highly recommend", "addicted",
)

# Gap-language keywords — phrases that signal a user is describing a
# missing feature or unmet need that a competitor (or WorldAI) could fill.
# Higher weight = stronger "I wish this existed" signal.  Tuned 2026-06-24
# against r/AIDungeon top complaint threads.
GAP_WORDS_HEAVY = (
    "wish", "i want", "i need", "would be nice", "would love",
    "feature request", "missing feature", "is there a way",
    "is there any way", "how do i", "how to make", "how can i",
    "no way to", "can't even", "is it possible",
    "i'd pay", "would pay", "subscription", "patreon",
    "if only", "too bad", "unfortunately",
)
GAP_WORDS_LIGHT = (
    "feature", "support", "improve", "improvement", "update",
    "add", "added", "ability", "enable", "let me",
    "custom", "customize", "control", "settings", "config",
    "roleplay", "lorebook", "memory", "remember",
    "image", "avatar", "character", "scenario",
)


# ---------------------------------------------------------------------------
# SOURCES — Reddit data feeds via PullPush.io (Pushshift successor).
#
# Verified limitations (2026-06-23 on this MacBook):
#   1. PullPush index for r/AIDungeon newest post is ~400 days old.
#   2. Reddit RSS returns 0 entries after the 2nd request (rate-limited
#      from this IP even with desktop Chrome UA).
#   3. Reddit search.rss returns 0 entries (blocked).
#   4. Reddit OAuth API requires CLIENT_ID (not set up).
#   5. Vercel/agent-browser sandbox needs Vercel project link (not set up).
#
# Conclusion: there is no way to get live "last week" data for these
# specific brands from this IP.  PullPush gives us the deep historical
# complaint signal (NSFW filter era, alternatives mega-threads) — which
# is the actually-useful signal for "what do people complain about?".
# A weekly digest that surfaces *new* threads on the day they're created
# would require a residential proxy or Reddit OAuth.
#
# User pref 2026-06-23: "in parallel these threads too old lets focus on
# threads with an update in the last week" — implemented as:
#   - Soft filter: only include posts created in the last POST_WINDOW_DAYS
#     days.  This is a wider window than the comment window because niche
#     AI text RPG subreddits (r/AIDungeon, r/friendsandfables) have only a
#     handful of posts per week.  A 7-day hard filter returns 0-1 results.
#   - Comment-recency boost: after collecting candidates, query
#     api.pullpush.io/reddit/search/comment/ for each post and count
#     comments posted in the last COMMENT_WINDOW_DAYS.  Posts with ≥1
#     recent comment get a COMMENT_RECENCY_BOOST multiplier — this is the
#     "updated in the last week" signal the user asked for.
#   - Posts with 0 recent comments are still kept (old threads can still
#     be the top complaint) but ranked below the boosted ones.
# ---------------------------------------------------------------------------
POST_WINDOW_DAYS = 90      # how old can a post be to be eligible
COMMENT_WINDOW_DAYS = 7    # the actual "updated in the last week" signal
COMMENT_RECENCY_BOOST = 1.5  # rank multiplier for posts with ≥1 recent comment
COMMENT_VELOCITY_BOOST = 2.0  # rank multiplier for posts with ≥5 recent comments

# PullPush user-agent.  Reddit/PullPush don't enforce a strict UA policy,
# but a descriptive UA helps if they ever start looking at us.
USER_AGENT = "hermes-reddit-monitor/1.0 (PullPush; +launchd@Jeffrey)"

# Path to the helper that extracts the Reddit session JWT from the
# local browser cookie store (Comet/Chrome Safe Storage keychain).
# Set as a module-level constant so tests can monkey-patch it.
EXTRACT_SESSION_SCRIPT = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "extract_reddit_session.py",
)

# (label, url, source_type)  — primary: live Reddit via your existing
# browser session (extracted from Comet/Chrome cookies).  Fallback:
# PullPush (historical).  See references/pullpush-migration.md.
SOURCES = [
    # === LIVE SOURCES (your Reddit session cookie) ===
    # AI Dungeon: most recent posts in r/AIDungeon
    ("AI Dungeon",
     "https://www.reddit.com/r/AIDungeon/new.json?limit=100",
     "reddit_oauth"),
    # AI Dungeon: complaint-keyword search
    ("AI Dungeon",
     "https://www.reddit.com/r/AIDungeon/search.json?q=nsfw+OR+filter+OR+censored+OR+alternative+OR+disappointed+OR+broken&restrict_sr=on&sort=new&limit=100",
     "reddit_oauth"),
    # Friends & Fables: most recent posts
    ("Friends & Fables",
     "https://www.reddit.com/r/friendsandfables/new.json?limit=100",
     "reddit_oauth"),
    # Voyage: brand search across all of Reddit (live)
    ("Voyage",
     "https://www.reddit.com/search.json?q=voyage+ai+text+rpg&sort=new&limit=50&type=link",
     "reddit_oauth"),

    # === HISTORICAL FALLBACK (PullPush, 3-15mo stale but valuable for
    # deep complaint signal) ===
    # AI Dungeon: NSFW filter era complaint signal
    ("AI Dungeon",
     "https://api.pullpush.io/reddit/search/submission/"
     "?subreddit=AIDungeon"
     "&q=nsfw+OR+filter+OR+censorship+OR+banned+OR+latitude+OR+open+source+OR+dragon+model"
     "&size=100&sort=desc&sort_type=created_utc",
     "pullpush"),
    # AI Dungeon: top posts in r/AIDungeon
    ("AI Dungeon",
     "https://api.pullpush.io/reddit/search/submission/"
     "?subreddit=AIDungeon&size=100&sort=desc&sort_type=created_utc",
     "pullpush"),
    # Friends & Fables: dedicated sub
    ("Friends & Fables",
     "https://api.pullpush.io/reddit/search/submission/"
     "?subreddit=friendsandfables&size=100&sort=desc&sort_type=created_utc",
     "pullpush"),
]

# Subreddits where AI-RPG / fantasy-RPG discussion is on-topic — boosts rank
RELEVANT_SUBS = frozenset({
    "aidungeon", "friendsandfables", "dndai", "soloroleplaying",
    "localllama", "textadventures", "novelai", "koboldai",
})

# How many of each competitor we want in the top 10 (1 buffer each)
TARGET_PER_COMPETITOR = {"AI Dungeon": 4, "Friends & Fables": 3, "Voyage": 3}

INTER_QUERY_SLEEP_S = 3
CURL_TIMEOUT_S = 25


def log(msg: str) -> None:
    print(f"[{time.strftime('%Y-%m-%d %H:%M:%S %Z')}] [reddit-competitor] {msg}",
          flush=True)


def to_float(v) -> float:
    if isinstance(v, (int, float)):
        return float(v)
    if isinstance(v, str):
        try:
            return float(v)
        except ValueError:
            return 0.0
    return 0.0


# Lazy-loaded session JWT — set on first call to reddit_oauth().
_SESSION_JWT: str | None = None


def reddit_oauth(url: str, retries: int = 2):
    """Fetch one Reddit /.json endpoint using the local session cookie
    (extracted from Comet/Chrome by extract_reddit_session.py).

    Returns parsed JSON or None on failure.  No-op on rate-limit / 401
    / "Blocked" page — those mean the cookie expired, caller should
    fall back to PullPush.
    """
    global _SESSION_JWT
    if _SESSION_JWT is None:
        try:
            r = subprocess.run(
                [sys.executable, EXTRACT_SESSION_SCRIPT],
                capture_output=True, text=True, timeout=15,
            )
            if r.returncode == 0 and r.stdout.strip():
                _SESSION_JWT = r.stdout.strip()
            else:
                log(f"  reddit_oauth: no session cookie extracted (rc={r.returncode}): {r.stderr[:120]}")
                return None
        except Exception as e:
            log(f"  reddit_oauth: extract_reddit_session failed: {e}")
            return None

    last_err = "?"
    for attempt in range(retries):
        try:
            r = subprocess.run(
                ["curl", "-sL", "--max-time", "20",
                 "-A", USER_AGENT,
                 "--cookie", f"reddit_session={_SESSION_JWT}",
                 url],
                capture_output=True, text=True, timeout=25,
            )
            if not r.stdout.strip():
                last_err = "empty body (rate-limited?)"
                time.sleep(3)
                continue
            if "<title>Blocked</title>" in r.stdout or "<!doctype html>" in r.stdout.lower()[:200]:
                # Cookie expired or session invalid — fall back to PullPush
                last_err = "Blocked (cookie expired?)"
                return None
            data = json.loads(r.stdout)
            # Normalize Reddit's nested listing shape:
            # {"data": {"children": [{"kind": "t3", "data": {post}}]}}
            # PullPush uses {"data": [post, post, ...]} (flat).
            # Flatten Reddit to {"data": [post, post, ...]} so gather_candidates
            # can treat both backends the same.
            if isinstance(data, dict) and "data" in data and isinstance(data["data"], dict):
                children = data["data"].get("children", [])
                flat = [c.get("data", {}) for c in children if isinstance(c, dict) and c.get("data")]
                data = {"data": flat}
            return data
        except (json.JSONDecodeError, subprocess.TimeoutExpired) as e:
            last_err = f"{type(e).__name__}: {e}"[:120]
            time.sleep(3)
    log(f"  reddit_oauth gave up: {last_err}  url={url}")
    return None


def pullpush(url: str, retries: int = 3):
    """Fetch one PullPush endpoint with retries. Returns parsed JSON or None."""
    last_err = "?"
    for attempt in range(retries):
        try:
            r = subprocess.run(
                ["curl", "-sL", "--max-time", str(CURL_TIMEOUT_S),
                 "-A", USER_AGENT, url],
                capture_output=True, text=True, timeout=CURL_TIMEOUT_S + 5,
            )
        except subprocess.TimeoutExpired:
            last_err = "subprocess timeout"
            time.sleep(3 * (attempt + 1))
            continue

        if r.returncode != 0:
            last_err = f"curl rc={r.returncode}: {r.stderr[:120]}"
            time.sleep(3 * (attempt + 1))
            continue
        if not r.stdout.strip():
            last_err = "empty stdout"
            time.sleep(3)
            continue
        try:
            return json.loads(r.stdout)
        except json.JSONDecodeError as e:
            last_err = f"JSON parse: {e}, raw={r.stdout[:120]}"
            time.sleep(2)
    log(f"  pullpush gave up after {retries} tries: {last_err}  url={url}")
    return None


def pain_score(title: str, body: str) -> int:
    text = ((title or "") + " " + (body or "")).lower()
    return (
        sum(1 for w in PAIN_WORDS if w in text)
        - sum(1 for w in POS_WORDS if w in text)
    )


def gap_score(title: str, body: str) -> int:
    """Score how strongly a post describes a gap a competitor could fill.

    Heavy gap-language (e.g. "I wish", "feature request") is worth 3 pts.
    Light gap-language (e.g. "feature", "memory") is worth 1 pt.
    POS_WORDS still deduct to avoid surfacing "I love this feature" posts.
    Patch notes / dev announcements are downweighted 50% — they describe
    features the vendor shipped, not gaps users wish existed.
    """
    text = ((title or "") + " " + (body or "")).lower()
    heavy = sum(1 for w in GAP_WORDS_HEAVY if w in text) * 3
    light = sum(1 for w in GAP_WORDS_LIGHT if w in text)
    neg = sum(1 for w in POS_WORDS if w in text) * 2  # POS counts double
    score = heavy + light - neg
    title_lower = (title or "").lower()
    if any(marker in title_lower for marker in ("patch notes", "release notes", "update notes", "changelog")):
        score = int(score * 0.5)
    return score


def gather_candidates() -> list[dict]:
    candidates: list[dict] = []
    seen: set[str] = set()
    cutoff = time.time() - (POST_WINDOW_DAYS * 86400)
    for i, entry in enumerate(SOURCES):
        # Backwards-compat: support both (label, url) and (label, url, type)
        if len(entry) == 3:
            label, url, source_type = entry
        else:
            label, url = entry
            source_type = "pullpush"
        if i > 0:
            time.sleep(INTER_QUERY_SLEEP_S)
        log(f"  source[{i}] {label} ({source_type})  ...")
        if source_type == "reddit_oauth":
            data = reddit_oauth(url)
        else:
            data = pullpush(url)
        if data is None:
            continue
        hits = data.get("data", []) or []
        log(f"  source[{i}] {label}: {len(hits)} hits")
        kept = 0
        for h in hits:
            # Reddit /search.json and /new.json wrap in {"kind":..., "data":...}
            # but reddit_oauth() unwraps that for us.
            pid = h.get("id") or h.get("name", "").replace("t3_", "")
            if not pid or pid in seen:
                continue
            seen.add(pid)
            title = h.get("title") or ""
            body = h.get("body") or h.get("selftext") or ""
            created = to_float(h.get("created_utc", 0))
            # User pref 2026-06-23: hard filter to threads updated in the
            # last week.  PullPush doesn't index "last_comment_at", so we
            # approximate "updated" as "created in window" — old threads
            # that are still being commented on are surfaced via the
            # comment-recency boost in rank_and_select().
            if created < cutoff:
                continue
            kept += 1
            candidates.append({
                "competitor": label,
                "id": pid,
                "title": title,
                "body": body,
                "score": int(to_float(h.get("score", 0))),
                "comments": int(to_float(h.get("num_comments", 0))),
                "subreddit": h.get("subreddit", "?"),
                "permalink": h.get("permalink", ""),
                "created_utc": created,
                "pain": pain_score(title, body),
                "gap": gap_score(title, body),
                "source_type": source_type,
            })
        log(f"  source[{i}] {label}: {kept} kept after {POST_WINDOW_DAYS}d recency filter")
    return candidates


def get_recent_comment_count(permalink: str, since: float) -> int:
    """Query PullPush's /search/comment/ for a permalink, count comments
    posted after `since` (unix epoch sec).  Returns 0 on any failure.
    `permalink` looks like `/r/AIDungeon/comments/abc/title/`.
    """
    # PullPush's comment endpoint doesn't take a permalink; it takes a
    # `link_id` (the t3_ prefixed submission id).  Parse the submission id
    # from the permalink.
    import re
    m = re.search(r"/comments/([a-z0-9]+)/", permalink)
    if not m:
        return 0
    link_id = f"t3_{m.group(1)}"
    url = (
        f"https://api.pullpush.io/reddit/search/comment/"
        f"?link_id={link_id}&after={int(since)}&size=100"
    )
    data = pullpush(url)
    if data is None:
        return 0
    return len(data.get("data", []) or [])


def rank_and_select(candidates: list[dict]) -> list[dict]:
    """Rank by composite pain-aware score, then pick top 10 with per-competitor caps.

    The recency boost has two parts:
      1. Post-age decay: posts older than POST_WINDOW_DAYS are filtered out
         by gather_candidates().  Among the survivors, recency still
         decays linearly to 0.4 at the window boundary.
      2. Comment-recency boost (the "updated in the last week" signal):
         query PullPush /search/comment/ for each top-30 candidate and:
           - ≥1 comment in last COMMENT_WINDOW_DAYS: × COMMENT_RECENCY_BOOST
           - ≥5 comments in last COMMENT_WINDOW_DAYS: × COMMENT_VELOCITY_BOOST
         Higher boosts for higher velocity (posts people are actively
         arguing about right now).
    """
    now = time.time()
    cutoff = now - (POST_WINDOW_DAYS * 86400)
    comment_cutoff = now - (COMMENT_WINDOW_DAYS * 86400)

    for c in candidates:
        age_days = max(0, (now - c["created_utc"]) / 86400.0)
        recency = max(0.4, 1.0 - (age_days / max(1, POST_WINDOW_DAYS)))
        sub_boost = 1.5 if c["subreddit"].lower() in RELEVANT_SUBS else 1.0
        c["rank"] = (
            c["pain"] * 6.0
            + math.log1p(max(0, c["score"])) * 1.0
            + math.log1p(max(0, c["comments"])) * 1.5
        ) * recency * sub_boost
        c["age_days"] = round(age_days, 0)

    candidates.sort(key=lambda x: x["rank"], reverse=True)

    # Comment-recency pass — only check the top-30 candidates (cheaper
    # than checking all 100+).  We sleep 3s between queries to respect
    # PullPush's ~60 req/min throttle.
    top_pre_boost = candidates[:30]
    log(f"  comment-recency pass: checking top {len(top_pre_boost)} candidates "
        f"for comments in last {COMMENT_WINDOW_DAYS}d")
    boosted = 0
    high_velocity = 0
    for c in top_pre_boost:
        n_recent = get_recent_comment_count(c["permalink"], comment_cutoff)
        if n_recent >= 5:
            c["rank"] *= COMMENT_VELOCITY_BOOST
            c["recent_comments"] = n_recent
            boosted += 1
            high_velocity += 1
        elif n_recent > 0:
            c["rank"] *= COMMENT_RECENCY_BOOST
            c["recent_comments"] = n_recent
            boosted += 1
        else:
            c["recent_comments"] = 0
        time.sleep(INTER_QUERY_SLEEP_S)
    log(f"  comment-recency pass: {boosted}/{len(top_pre_boost)} threads had recent comments "
        f"({high_velocity} high-velocity with ≥5 recent)")
    # Re-sort after boosts
    candidates.sort(key=lambda x: x["rank"], reverse=True)

    selected: list[dict] = []
    per_comp = {k: 0 for k in TARGET_PER_COMPETITOR}
    for c in candidates:
        if len(selected) >= 10:
            break
        comp = c["competitor"]
        if per_comp.get(comp, 0) >= TARGET_PER_COMPETITOR.get(comp, 3) + 1:
            continue
        selected.append(c)
        per_comp[comp] = per_comp.get(comp, 0) + 1

    if len(selected) < 10:
        for c in candidates:
            if c in selected:
                continue
            selected.append(c)
            if len(selected) >= 10:
                break
    return selected


def format_digest(candidates: list[dict], total_candidates: int) -> str:
    """Emit the digest in the exact format the shell wrapper parses.

    Output format (consumed by ~/.smartclaw/scripts/reddit-competitor-complaints.sh):
      === Reddit competitor-complaints digest — <timestamp> ===
      <per-competitor sections>
      ---
      <summary footer>
    """
    lines: list[str] = []
    lines.append("=== Reddit competitor-complaints digest — "
                 f"{time.strftime('%Y-%m-%d %H:%M:%S %Z')} ===")
    lines.append("")
    lines.append(f"_Source: PullPush.io (Pushshift successor). "
                 f"{total_candidates} unique submissions scanned._")
    lines.append("")

    by_comp: dict[str, list[dict]] = {}
    for c in candidates:
        by_comp.setdefault(c["competitor"], []).append(c)

    counter = 0
    for label in ["AI Dungeon", "Friends & Fables", "Voyage"]:
        items = by_comp.get(label, [])
        if not items:
            lines.append(f"*{label}* — no Reddit threads found in PullPush index. "
                         f"Brand may be pre-launch or marketing elsewhere.")
            lines.append("")
            continue
        lines.append(f"*{label}* ({len(items)} threads)")
        for c in items:
            counter += 1
            url = f"https://reddit.com{c['permalink']}"
            title = (c["title"] or "(no title)").strip()
            lines.append(f"## {counter}. [{label}] {title}")
            lines.append(url)
            recent = c.get("recent_comments", 0)
            if recent >= 5:
                recent_marker = f" • {recent} new comments in last {COMMENT_WINDOW_DAYS}d 🔥"
            elif recent:
                recent_marker = f" • {recent} new comment{'s' if recent != 1 else ''} in last {COMMENT_WINDOW_DAYS}d ⏰"
            else:
                recent_marker = ""
            meta = (f"r/{c['subreddit']} • {c['score']}↑ • "
                    f"{c['comments']} comments • {int(c['age_days'])}d ago "
                    f"• pain={c['pain']}{recent_marker}")
            lines.append(f"_{meta}_")
            body = (c.get("body") or "").strip()
            if body:
                body = body.replace("\r", "").replace("&amp;", "&")
                body = body.replace("\u00a0", " ")
                snippet = body[:300].replace("\n", " ")
                lines.append(f"> {snippet}{'…' if len(body) > 300 else ''}")
            lines.append("")

    lines.append("---")
    lines.append(f"Top 10 threads selected from {total_candidates} candidates in the last {POST_WINDOW_DAYS} days "
                 f"(comment activity in last {COMMENT_WINDOW_DAYS}d boosts rank).")
    lines.append("Ranking: pain-keyword score × engagement × recency × subreddit relevance × comment-recency boost.")
    lines.append("")
    return "\n".join(lines)


def format_gap_digest(candidates: list[dict], top_n: int = 3) -> str:
    """Pick the top N r/AIDungeon threads by gap_score × recency and emit
    a "WorldAI gap" section describing what users wish the product had.

    Only considers posts that mention AI Dungeon (subreddit = AIDungeon).
    Recency decay: same as rank_and_select (linear to 0.4 at window edge).
    """
    if not candidates:
        return ""
    pool = [c for c in candidates if c["subreddit"].lower() == "aidungeon"]
    if not pool:
        return ""
    now = time.time()
    cutoff = now - (POST_WINDOW_DAYS * 86400)
    ranked = []
    for c in pool:
        age_days = max(0, (now - c["created_utc"]) / 86400.0)
        recency = max(0.4, 1.0 - (age_days / max(1, POST_WINDOW_DAYS)))
        # gap_score dominates; recency breaks ties; engagement boosts
        gap_rank = (
            c["gap"] * 5.0
            + math.log1p(max(0, c["score"])) * 0.5
            + math.log1p(max(0, c["comments"])) * 0.5
        ) * recency
        if gap_rank <= 0:  # skip net-negative gap (e.g. "I love this feature")
            continue
        ranked.append((gap_rank, c, age_days))
    ranked.sort(key=lambda x: x[0], reverse=True)
    top = ranked[:top_n]
    if not top:
        return ""
    lines = [
        "",
        "---",
        "",
        f"### :dart: Top {len(top)} AI Dungeon threads where users describe a gap WorldAI could fill",
        "",
        "_Filter: r/AIDungeon only · ranked by gap-language density × recency × engagement_",
        "",
    ]
    for i, (rank, c, age_days) in enumerate(top, 1):
        url = f"https://reddit.com{c['permalink']}"
        title = (c["title"] or "(no title)").strip()
        lines.append(f"**{i}. {title}**")
        lines.append(url)
        lines.append(f"_r/AIDungeon • {c['score']}↑ • {c['comments']} comments "
                     f"• {int(age_days)}d ago • gap={c['gap']} • pain={c['pain']}_")
        body = (c.get("body") or "").strip()
        if body:
            body = body.replace("\r", "").replace("&amp;", "&").replace("\u00a0", " ")
            snippet = body[:400].replace("\n", " ")
            lines.append(f"> {snippet}{'…' if len(body) > 400 else ''}")
        lines.append("")
    return "\n".join(lines)


def main() -> int:
    log("=== start (PullPush.io backend) ===")
    candidates = gather_candidates()
    log(f"=== {len(candidates)} unique candidates ===")
    selected = rank_and_select(candidates)
    digest = format_digest(selected, total_candidates=len(candidates))
    # Append the WorldAI gap section (r/AIDungeon only, top 3 by gap_score)
    gap_section = format_gap_digest(candidates, top_n=3)
    if gap_section:
        digest = digest + gap_section
    # Print the digest to stdout — shell wrapper reads this
    print(digest, flush=True)
    log(f"=== end ({len(selected)} threads emitted) ===")
    return 0


if __name__ == "__main__":
    sys.exit(main())
