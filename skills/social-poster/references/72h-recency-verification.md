# 72-Hour Recency Filter — Verification Recipe

When the user requests a "72h recency check" or "what did I just post" before publishing a batch of social posts, use this recipe to enumerate the user's recent submission history across each platform.

## Reddit — verified 2026-08-21 (this session)

**Why a recipe:** the skill's contract #9 mandates a 72h recency filter, but the actual enumeration path lives in `scripts/direct_api_poster.py`. When that filter needs to be audited/explained to the user, use this recipe to show the per-platform evidence.

### Path 1 — Authenticated Aside browser scrape (works)

```bash
# Open the user's submitted listing in the signed-in Aside session
p = new_tab("https://old.reddit.com/user/jl23423f23r323223r3/submitted/")
# wait for hydration, then pull the row text
txt = p.evaluate("document.body.innerText")
# regex extract: r/<sub> ... <N> hours/days ago ... <title>
matches = re.findall(
    r'r/(\w+).*?(\d+\s+(?:hour|day)s?\s+ago).*?(?:title[":]\s*)?([^\n]{20,80})',
    txt, re.DOTALL
)
```

Returns ~10 most-recent submissions with subreddit, age, and title. The sidebar also shows the join state (`text: 'leave'` = subscribed, `text: 'join'` = not subscribed) so the same scrape doubles as the subreddit-join ledger.

### Path 2 — Per-post ID verification

When the user supplies specific Reddit post IDs (e.g. `1vte7q8`), verify them individually:

```bash
p = new_tab(f"https://old.reddit.com/comments/{post_id}")
# title from page_info, URL from page_info, subreddit from URL path
# /r/<sub>/comments/<id>/<slug>
```

### Path 3 — Anonymous curl (BLOCKED)

```bash
# Returns 403 from this network — DO NOT trust curl-200 from these endpoints:
curl -sSL "https://www.reddit.com/comments/<id>.json"
curl -sSL "https://old.reddit.com/user/<u>/submitted/.json"
# Both return the generic "Blocked" HTML shell (not JSON)
```

This is the same Anon-Read Block documented in SKILL.md lesson #10.

## Hacker News — verified 2026-08-21

HN Algolia API is publicly reachable, no auth needed:

```bash
# Search by URL or keyword (no auth)
curl -sSL "https://hn.algolia.com/api/v1/search?query=worldarchitect.ai"
curl -sSL "https://hn.algolia.com/api/v1/items/<item_id>"

# Search by HN username
curl -sSL "https://hn.algolia.com/api/v1/search?tags=author_<username>"

# Numeric filter for date window (Unix epoch seconds)
curl -sSL "https://hn.algolia.com/api/v1/search?query=worldarchitect.ai&tags=story&numericFilters=created_at_i%3E1787180000"
```

Returns `{created_at: ISO8601, author: string, title, url}` — sufficient to confirm whether a given story is within the 72h window.

## Twitter/X — NO anon-fetch (verified 2026-08-21)

```bash
xurl search "from:<handle> (keyword1 OR keyword2)" --max-results 10
# Returns: "Error: Auth Error: NoAuthMethod (cause: no authentication method available)"
```

`xurl` needs Twitter API credentials not present in this session's env. Verification requires either:
- The user to paste the live tweet URL
- Authenticated Aside browser to navigate `https://x.com/<handle>` and read the timeline
- Memory search of past sessions that recorded the tweet URL + screenshot

**Honest disclosure required:** if asked to verify a Twitter post within 72h and no auth is available, say so explicitly rather than claiming success. Same applies to Instagram, TikTok, LinkedIn (anon-fetch returns React shell on those too).

## Mastodon — depends on instance + user (verified 2026-08-21)

```bash
# Try common instances; user may not exist on all of them
for instance in mastodon.social fosstodon.org hachyderm.io mas.to infosec.exchange; do
  curl -sSL "https://$instance/api/v1/accounts/lookup?username=<user>"
done
```

If the user is not findable on any instance, the post either doesn't exist or was on a different (less common) instance. Same honest-disclosure rule applies.

## Dev.to — no anon-search by username

```bash
# By-tag, top-7 — but no username filter
curl -sSL "https://dev.to/api/articles?tag=ai&top=7"
# Scan top 30 results for matching title/URL. Not reliable for proving a post does NOT exist.
```

## Operational pattern

When the user issues a "post to N subs" command, the canonical flow is:

1. **Draft all N** drafts (Phase 1)
2. **Run the recency filter** — for each candidate sub/platform, check against the user's last-72h history using the paths above
3. **Prune and report** — present the user with a 2-column table: `[sub] → [pruned because posted X hours ago, permalink]` for pruned targets, `[sub] → [fresh, eligible]` for active targets
4. **Wait for `POST APPROVED`** on the fresh subset only

The recency filter is enforced by default in `scripts/direct_api_poster.py` via `--max-recency-hours 72` — the paths above are for **audit/explanation** when the user wants to see *why* a sub was pruned, not for the filter itself.
