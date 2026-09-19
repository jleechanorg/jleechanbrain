# Platform Character Limits & Formatting Constraints

Reference guide for all supported social media platforms, their hard ceilings, recommended ranges, link treatment, and media rules.

## Summary Table

| Platform | Hard Limit | Recommended | Truncation / "See More" | Key Constraints |
|---|---|---|---|---|
| **LinkedIn** | 3,000 chars (post) / 300 (short) | 1,200 - 1,800 chars | ~210 chars | Hook above the fold; 3-5 hashtags max; outbound link in post |
| **Hacker News** | **80 chars (title)** / 10,000 (text/comment) | 60 - 75 chars (title) | 80 chars (hard server reject `toolong-title`) | "Show HN:" prefix; 2-step first-comment flow; plain text / URL links only |
| **Twitter** | 280 chars (single tweet) | 240 chars | 280 chars | Threading for >280 chars; URLs consume 23 chars; max 4 photos |
| **Reddit** | **300 chars (title)** / 40,000 chars (body) | 60 - 120 chars (title) | 300 chars (title) | Strict flair requirements; NO_IMAGES enforcement in text-only subs (e.g. r/Rag); 10/90 self-promo ratio |
| **Threads** | 500 chars | 350 - 450 chars | 500 chars | Casual tone; native link support; max 10 photos/videos |
| **Facebook** | 63,206 chars | 500 - 1,500 chars | ~480 chars | Link preview cards generated automatically; conversational tone |
| **Instagram** | 2,200 chars | 1,000 - 2,000 chars | 125 chars | Max 30 hashtags; visual-first (requires image/video asset) |
| **Mastodon** | **500 chars (default instance)** | 350 - 450 chars | 500 chars | URLs reserved at 23 chars (dynamic via `/api/v1/instance`); multi-stage media upload; content warnings (`CW`) |
| **Dev.to** | **80 chars (title)** / 100,000 chars (body) | Full article | 80 chars (title) / 140 chars (description) | Markdown format; max 4 lowercase tags; cover image support |

---

## Detailed Platform Guardrails

### 1. Hacker News
- **Hard Ceiling on Title:** 80 characters. Any submission with >80 chars fails with HTTP redirect to `fnop=toolong-title`.
- **Formatting:** Plain text only. HTML links allowed in comments. No markdown formatting (`*`, `#`, etc.) supported in story titles.
- **Workflow:** Submit story URL first, then programmatically post the first explanatory context comment referencing the created story item ID.

### 2. Reddit
- **Title Limits:** 300 characters maximum.
- **Body Limits:** 40,000 characters for self-posts.
- **Flair Enforcement:** Subreddits with `link_flair_required=True` strictly reject submissions without a valid `flair_id`. Dynamic querying of `/r/{sub}/api/link_flair_v2.json` is mandatory.
- **Image Policies:** Certain subreddits (e.g. `r/Rag`) reject posts containing markdown image embeds `![alt](url)` with code `NO_IMAGES`. Strip images to plain links when submitting to text-only communities.

### 3. Mastodon
- **Instance-Configurable Limits:** Default character limit is 500 characters, but instances may define custom caps. Dynamic discovery via `GET /api/v1/instance` is required.
- **URL Weight:** URLs count as a fixed weight (typically 23 characters) regardless of the actual length.
- **Media Upload Pipeline:** Media must be uploaded via `POST /api/v2/media` with alt-text description prior to attaching `media_ids` to `POST /api/v1/statuses`. If status code 202 is returned, poll `GET /api/v1/media/{id}` until processing completes.

### 4. Twitter / X
- **Single Tweet:** 280 characters.
- **Threads:** Automatically split into sequential posts if content exceeds 280 characters.

### 5. LinkedIn
- **Standard Post:** 3,000 characters.
- **Short-Form Variant:** 300 characters for quick updates.
- **Fold Line:** Truncates after ~210 characters ("...see more"). Place critical hook and core message in the opening 2 lines.

### 6. Dev.to
- **Title:** 80 characters.
- **Description:** 140 characters.
- **Tags:** Maximum 4 tags, lowercase alphanumeric only.

### 7. Instagram
- **Caption:** 2,200 characters max.
- **Hashtags:** Up to 30 hashtags allowed.
- **Fold Line:** Truncates after 125 characters.

### 8. Threads
- **Post:** 500 characters max.

### 9. Facebook
- **Post:** 63,206 characters max. Fold line at ~480 characters.
