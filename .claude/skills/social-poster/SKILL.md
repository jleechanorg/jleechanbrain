---
name: social-poster
version: 0.2.0
description: |
  Draft, stage, and publish social-media posts for Reddit, Hacker News, Twitter/X,
  Mastodon, LinkedIn, Threads, Facebook, Instagram, and Dev.to. Supports Direct REST
  API publishing with session cookies/tokens, dynamic Reddit flair & constraint pre-flight,
  HN 80-char/2-step guardrails, Mastodon media upload pipelines, and multi-tier auth recovery.
  Posts ONLY go live after explicit user "POST APPROVED" gating.
when_to_use: |
  Use when the user asks to draft a post for any social platform, share a project
  on LinkedIn/HN/Twitter, post to Reddit, prepare a Show HN, draft an Instagram
  caption, or any "draft a post" / "post to <platform>" / "share on social" /
  "/social <intent>" request. Also fires on "/social <intent>" slash command.
allowed-tools:
  - Read
  - Write
  - Bash
  - Edit
  - Grep
triggers:
  - "draft a social post"
  - "draft a post"
  - "post to social"
  - "post to linkedin"
  - "post to hacker news"
  - "post to reddit"
  - "post to twitter"
  - "post to threads"
  - "post to facebook"
  - "post to instagram"
  - "draft linkedin post"
  - "draft hacker news post"
  - "draft reddit post"
  - "draft tweet"
  - "draft twitter thread"
  - "draft instagram caption"
  - "draft threads post"
  - "show hn"
  - "social poster"
  - "/social"
context: inline
---

# Social Poster — Direct REST API & Staging, POST APPROVED Gated

## Contract

1. **Draft, never unapproved post** — default mode produces text files + browser-staged tabs / visual screenshots. No network publishing mutation without explicit `POST APPROVED`.
2. **Direct REST API Path (First-Class)** — uses session tokens / decrypted Chrome cookies (`browserclaw cookies decrypt`) for deterministic REST posting on Reddit (`/api/submit`), Mastodon (`/api/v1/statuses`), and Hacker News (form POST). Bypasses React DOM paste issues.
3. **Subreddit Capability & Constraint Engine** — dynamic flair resolution via `/r/<sub_name>/api/link_flair_v2.json`, subreddit capability checks via `/r/<sub_name>/about.json` (`NO_IMAGES` in r/Rag), and 10/90 self-promo adherence.
4. **Hacker News Guardrails** — hard 80-character title limit enforcement (`toolong-title` server error prevention) and automated 2-step Show HN flow (story link submission → item ID extraction → first context comment posting with partial-failure retry).
5. **Mastodon Guardrails** — instance configuration discovery (`GET /api/v1/instance` for `characters_reserved_per_url` and `max_characters`), session token extraction from `/publish`, multi-part media upload via `/api/v2/media` (with synchronous HTTP 200 vs asynchronous HTTP 202 polling), and status posting via `/api/v1/statuses`.
6. **POST APPROVED Token** — `scripts/post_approved.py` and `scripts/direct_api_poster.py` require literal `POST APPROVED` (or allowlist `POST APPROVED reddit,mastodon`) before executing mutations. Hard exit code 2 if missing.
7. **Multi-Tier Auth Recovery** — automatic fallback chain: Aside active session → Chrome decrypted cookies (`browserclaw`) → Chrome Safe Storage PBKDF2 direct → Headless staging with 1-click unblock detection.
8. **Persistent Global Ledger in `~`** — tracks all published websites, subreddits, platforms, timestamps, and permalinks in `~/.social-poster/ledger.json`. Automatically syncs with live account history.
9. **Daily Reddit Cap & 72h Recency Filter** — enforces a strict rate limit of **maximum 3 Reddit submissions per rolling 24-hour day**, and automatically skips any community or website posted to within the last **72 hours**.
10. **Post Deletions STRICTLY FORBIDDEN** — Agents must NEVER delete, retract, or call deletion endpoints (`/api/del`, `del`, etc.) on published social posts (Reddit, Hacker News, X, LinkedIn, Mastodon, etc.) unless the current user message contains the literal exact phrase `POST DELETE APPROVED`. Paraphrases, focus requests ("only do X", "ignore the rest"), draft corrections, or summaries do NOT grant deletion authority. Once published, posts stay live.

---

## Supported Platforms & Publishing Paths

| Platform | Template | Primary Publish Path | Fallback Path | Constraints & Guardrails |
|---|---|---|---|---|
| **Reddit** | `templates/reddit.md` | Direct REST (`/api/submit` with modhash + session cookie / OAuth) | Headless Playwright (`old.reddit.com`) | Dynamic flair via `link_flair_v2.json`; check image support (`NO_IMAGES` in r/Rag); 10/90 rule; disclose maintainer |
| **Hacker News** | `templates/hackernews.md` | 2-Step Form POST (`/r` story submit + `/comment`) | Headless Playwright | Title **≤80 chars hard limit**; "Show HN:" prefix; dual links in first comment; non-atomic failure retry; no buzzwords/emojis |
| **Mastodon** | `templates/mastodon.md` | Direct REST (`/api/v2/media` + `/api/v1/statuses`) | Headless Playwright (`/publish`) | Dynamic instance character caps; 23-char URL accounting; media upload with alt text & conditional HTTP 202 polling |
| **Twitter/X** | `templates/twitter.md` | Headless Playwright with injected cookies | Aside HTTP MCP | Single tweet **≤280 chars** (thread if >280); manual photo attach fallback if automation flagged |
| **LinkedIn** | `templates/linkedin.md` | Headless Playwright with injected cookies | Aside HTTP MCP | Long-form + 300-char short variant; 1-click Google OAuth unblock detection |
| **Dev.to** | `templates/devto.md` | Direct REST (`/api/articles`) or Headless Playwright | Aside HTTP MCP | Markdown article format; max 4 lowercase alphanumeric tags; cover image upload |
| **Threads** | `templates/threads.md` | Headless Playwright with injected cookies | Aside HTTP MCP | ≤500 chars, casual tone |
| **Facebook** | `templates/facebook.md` | Headless Playwright with injected cookies | Aside HTTP MCP | Medium-length, link-friendly |
| **Instagram** | `templates/instagram.md` | Media upload + caption copy (Mobile/Browser) | Manual copy | Surface caption + 30-hashtag block + direct image path |

---

## Workflow Phases

### Phase 1 — Draft & Rule Constraint Validation (Deterministic)

Run `scripts/draft_social_post.py` with intent, key points, link, and platform list. Checks character budgets and validates subreddit rules.

```bash
PY=${HOME}/.smartclaw/skills/social-poster/scripts/draft_social_post.py
python3 "$PY"   --intent "announce WorldAI House of the Dragon campaign"   --key-points "Interactive HotD universe, custom D&D narratives, open beta"   --link "http://worldarchitect.ai/shared/t3hKKtzBKCKlvg5vCnlW_2hxwH3UmzjFq56yi6hQN2Q"   --platforms hackernews,twitter,reddit,mastodon,devto   --reddit-subs "ai_rpg_community,LocalLLaMA,Rag,OpenAI,aigamedev,AIPlayableFiction"   --image "/tmp/drafts/worldai-share-campaign/campaign_image_cropped.png"   --out /tmp/drafts/social-run/
```

*Subreddit Dynamic Constraint Check*:
- Queries `https://old.reddit.com/r/<sub>/api/link_flair_v2.json` to map flair template IDs.
- Queries `https://old.reddit.com/r/<sub>/about.json` to check `allow_images` (e.g. `NO_IMAGES` on `r/Rag`).

---

### Phase 2 — Session Decryption & Staging

1. **Decrypt Chrome Session Cookies**:
   ```bash
   browserclaw cookies decrypt      --db "$HOME/Library/Application Support/Google/Chrome/Default/Cookies"      --output /tmp/drafts/social-run/cookies.json      --domain-filter "%"      --summary
   ```

2. **Stage in Browser / Capture Visual Proof**:
   Run `scripts/stage_in_aside_mcp.py` (preferred) or `scripts/chrome_stage.py`:
   ```bash
   PY=${HOME}/.smartclaw/skills/social-poster/scripts/chrome_stage.py
   python3 "$PY"      --platform hackernews      --draft /tmp/drafts/social-run/hackernews.md      --screenshot /tmp/drafts/social-run/screenshots/hackernews.png
   ```

---

### Phase 3 — Surface Drafts & Evidence to User

1. Output table of generated `.md` files, character counts, and screenshot paths.
2. If Slack integration is active, upload screenshots directly to the user's DM.
3. Prompt user: *"Drafts staged. Reply with `POST APPROVED` to publish all, or `POST APPROVED reddit,mastodon` for specific platforms."*

---

### Phase 4 — Post (Gated Mutation)

ONLY runs when literal `POST APPROVED` token is provided.

```bash
PY=${HOME}/.smartclaw/skills/social-poster/scripts/direct_api_poster.py
python3 "$PY"   --drafts /tmp/drafts/social-run/   --approval-token "POST APPROVED"   [--platforms reddit,mastodon,hackernews]
```

**Direct API Execution Logic**:
- **Reddit**:
  1. Resolves `flair_id` via dynamic cache or `/api/link_flair_v2.json`.
  2. Sanitizes images to text links if `NO_IMAGES` is enforced in target sub.
  3. Fetches modhash from `/api/me.json`.
  4. POSTs payload to `https://www.reddit.com/api/submit`.
- **Hacker News**:
  1. Validates title ≤80 chars (hard server limit).
  2. Submits Show HN story URL to `/submit` -> extracts new item ID from `/newest` or redirect header.
  3. POSTs first context comment with dual links to `/comment` under `parent=<item_id>`.
  4. Implements retry/backoff for non-atomic comment failures.
- **Mastodon**:
  1. Queries `/api/v1/instance` for `characters_reserved_per_url` (23 chars).
  2. Uploads `--image` asset to `/api/v2/media` (polls `/api/v1/media/<id>` if HTTP 202).
  3. Posts status to `/api/v1/statuses` with `media_ids=[<media_id>]`.
- **Playwright Fallback**:
  - For Twitter, LinkedIn, Facebook, Threads, Dev.to, executes headless session with injected cookies, submits form, and captures final live URL.

Posting log written to `--drafts/posted.json` with timestamps, canonical URLs, and response payloads.

---

## Subreddit Selection & Capability Matrix

| Subreddit | Status / Type | Flair Template Resolution | Image Embed Rule | Self-Promo & Moderation Contract |
|---|---|---|---|---|
| **r/ai_rpg_community** | Canonical Primary | Auto-resolve `Showcase` / `Discussion` | Allowed | Modded by Jeffrey (`u/jl23423f23r323223r3`). Always include for WorldAI updates. Add "Disclosure: I'm the maintainer." |
| **r/AIPlayableFiction** | Canonical Primary | Auto-resolve `Playable Fiction` | Image embed allowed in body | Interactive fiction & narrative sandbox focus. Frame as playable choose-your-own adventure. |
| **r/LocalLLaMA** | Primary AI | Auto-resolve `Show & Tell` | Text post preferred | 1/10 rule. Disclose affiliation. No purely LLM-generated copy. |
| **r/Rag** | Primary AI | Auto-resolve `Showcase` / `Discussion` | **NO_IMAGES** (Text/Tables only) | 10/90 rule. Citation required. Benchmark comparison tables required. Strip `![...]` image tags. |
| **r/OpenAI** | Primary AI | Auto-resolve `Project` / `Discussion` | Text post only for self-promo | Direct link posts banned for self-projects. Must be text post with context. |
| **r/aigamedev** | Fandom / Game | Auto-resolve `Demo \| Project \| Workflow` | Allowed | Commercial games OK; dev tools permitted if framed technically. |

---

## Auth Recovery Fallback Matrix

```text
[Request Auth Substrate]
         │
         ▼
[Tier 1: Aside HTTP MCP (127.0.0.1:8013)] ──(Healthy)──▶ Execute Playwright IIFE
         │ (Fails / Bridge Down)
         ▼
[Tier 2: browserclaw cookies decrypt] ────(Cookies OK)─▶ Direct REST API / Injected Playwright
         │ (Locked / Non-zero return)
         ▼
[Tier 3: Chrome Safe Storage PBKDF2] ─────(Key Derived)─▶ Direct SQLite Decrypt (AES-128-CBC)
         │ (Session Expired / Login Wall)
         ▼
[Tier 4: Visual Staging & User Unblock] ──(Captured)───▶ Surface OAuth / One-Tap buttons to user
```

---

## Critical Lessons & Operational Rules

1. **Direct REST API > DOM Manipulation**: Direct REST calls (`/api/submit`, `/api/v1/statuses`) eliminate silent DOM paste truncations and React state desyncs.
2. **Subreddit Dynamic Flairing**: Reddit subreddits with `submission_flair_required=true` will reject posts with `BAD_FLAIR_TARGET` if `flair_id` is omitted. Always resolve flairs dynamically from `link_flair_v2.json`.
3. **Subreddit Content Sanity (NO_IMAGES)**: Check subreddit capabilities via `about.json`. Convert `![alt](url)` to `[alt](url)` in text-first communities like `r/Rag`.
4. **Hacker News 80-Char Guardrail**: HN backend silently drops or rejects titles over 80 characters (`toolong-title`). Enforce length strictly before submission.
5. **HN Show HN 2-Step Architecture**: A Show HN post is incomplete without its immediate engineering context comment. The publisher must bundle URL submission with comment posting and handle non-atomic recovery.
6. **Mastodon URL & Media Protocol**: Calculate character budgets using instance `characters_reserved_per_url` (23 chars). Media must be uploaded via `/api/v2/media` and verified processed before calling `/api/v1/statuses`.
7. **Twitter Automation Media Flagging**: Twitter compose often flags automated `setInputFiles` via Playwright. When staging Twitter with media, provide text staging + fallback instruction for manual image attach.
8. **Vision Verification on Staged Browser Tabs**: When using browser staging, never trust DOM presence alone. Verify actual text visibility in compose fields via screenshot capture.
9. **Reddit Megathread Comment Mode** — Subs like `r/vibecodingcommunity`, `r/SideProject`, and most "weekly share" subs *forbid top-level self-promo* and expect replies inside the pinned megathread. Use `draft_social_post.py --mode comment --parent-url <megathread-url> --parent-context "<what the thread is asking>"`. The drafter emits `reddit_<sub>_comment_<parent_id>.md` instead of a top-level post. Always pass `--parent-context` so the comment can acknowledge the thread prompt (e.g. "what are you vibecoding this week") instead of sounding like a cold sales pitch.
10. **Reddit Anon-Read Block (2025+)** — `reddit.com` and `old.reddit.com` return the generic React shell (title "Reddit", no OG/body) for any anonymous request from many residential/cloud IPs. `.json` endpoints return the same shell. Do NOT trust a curl-200 + `<title>Reddit</title>` as evidence the thread loaded — it didn't. To read a thread from this network: (a) Aside / browserclaw on a logged-in Chrome profile, OR (b) Reddit OAuth (script-type app from `reddit.com/prefs/apps`). Both paths return real title/body/comments. Without one of those, the drafter must receive the megathread title + parent-context from the user and not pretend to have scraped it.
11. **72h Recency Filter — Verification Recipe** — The recency filter (`--max-recency-hours 72` in `direct_api_poster.py`) prunes communities silently. When the user asks to see *why* a sub was pruned or wants the per-platform evidence, the audit recipe lives at `references/72h-recency-verification.md`. Quick rules: Reddit needs the authenticated Aside browser scrape (anon-curl is 403); HN Algolia is publicly reachable; Twitter/Mastodon/Dev.to need explicit user-supplied URLs or honest "cannot verify" disclosure. Never claim a platform post exists without one of those three.
12. **Reddit Native Rich Media vs. Markdown Selftext** — Reddit selftext markdown treats `![alt](url)` as plain text hyperlinks. An actual widescreen graphic card will ONLY render if the image is uploaded through Reddit's native media pipeline (`<shreddit-media-item>`) in the rich composer or via S3 media asset endpoints.
13. **Aside Session File Containment Invariant** — Aside's `setFiles()` strictly rejects paths outside the active session directory (`pwd`: `~/.aside/u/0/sessions/...`). Always copy image files to `path.join(pwd, 'banner.png')` within the session before triggering file-chooser uploads.
14. **Composer Modal Dialog Dismissal** — Reddit's "Add flair and tags" modal blocks composer focus and covers post screenshots. Always dismiss the modal with `button:has-text("Add")` before typing body text or capturing screenshots.
15. **Absolute Social Post Deletion Ban** — Once a post is published, it stays live. Agents must NEVER delete, retract, or call deletion endpoints on published social posts unless the current live user message explicitly contains the exact literal phrase: `POST DELETE APPROVED`. Focus directives ("only do X", "ignore the rest") or draft corrections do NOT grant deletion authority.
