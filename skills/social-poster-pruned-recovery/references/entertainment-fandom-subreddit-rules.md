# Entertainment / Fandom Subreddit Rules — Live-Verified 2026-08-05

Verified via `aside mcp` `openTab('https://old.reddit.com/r/<sub>/about/rules')` against the signed-in browser session.

**Use case:** when a campaign/product/launch has an entertainment or fandom angle (TV show tie-in, book universe, game IP, etc.) and you want to post to the relevant Reddit sub, not just the AI subs. Many of these subs have **hard self-promo rules** that require modmail permission BEFORE posting.

## TV show tie-ins

### r/HouseOfTheDragon (1.3M weekly visitors — primary HotD sub)

- **Self-promo rule:** "**Posts about your own site/channel/product/social media account/etc. will be removed, unless you have received express permission from the mod team before posting.**"
- **Content scope:** "Content (not the title) of any submission should have some direct relationship to the A Song of Ice and Fire universe (House of the Dragon, Game of Thrones, supplementary materials, etc.)"
- **Spoilers:** Use `>!spoiler!<` formatting; tag scope in brackets.
- **Verdict:** **Modmail first.** Campaign templates that play IN the HotD universe ARE on-topic, but the self-promo rule is hard. Frame as "community resource", not "our product."

### r/Hotd (459K weekly, "unofficial subreddit")

- **Self-promo rule:** "We don't allow spam, low effort content and self promo in this community."
- **Verdict:** **Skip.** Hard no-self-promo.

### r/asoiaf (597K weekly — A Song of Ice and Fire)

- **Civility:** "Don't be Rude or Condescending. No Trolling, slapfights, personal attacks or witch hunts."
- **Spoilers:** Strict tag enforcement `[TWOW]`, `[ASOS]`, etc. — every post needs a spoiler tag in the title.
- **Self-promo:** No explicit rule, but mods remove "silly posts, external funny links, memes" at discretion.
- **Verdict:** **Modmail first.** Heavy moderation; high-quality canon-aware audience.

### r/freefolk (1.2M weekly — the "open" GoT sub)

- **Content rule:** "All posts must be related to Game of Thrones and A Song of Ice and Fire. Truly off topic posts will be removed."
- **Politics ban:** Real-life politics not permitted (season 8 poll result).
- **Spoiler policy:** "This is a spoiler friendly sub. We will not ever require posts or comments to be tagged as spoilers."
- **Self-promo:** No explicit rule. Famous for lenient moderation.
- **Verdict:** **Modmail first** for non-obvious self-promo. The "fookin" sub is open to off-topic fanfic if framed right.

### r/HOTDGreens / r/HOTDBlacks (455K / 282K weekly — Team Green / Team Black factions)

- **Content scope:** Strictly faction-specific content. Cross-faction content routinely removed.
- **Self-promo:** Fan-faction subs — no tolerance for external promotion.
- **Verdict:** **Skip.** Even well-framed campaign templates will get removed as off-topic.

## Skip list (dead / joke subs)

- r/HOUSE_OF_THE_DRAGONS — 79 weekly visitors, dead
- r/TheHouseOfTheDragon — 14 weekly visitors, dead
- r/DaenerysWinsTheThrone — joke sub (17K weekly but no legitimate engagement)
- r/shittyASOIAFdetails — joke/meme sub, off-topic for serious launches

## Decision tree for "should we post this to a fandom sub?"

1. **Is the campaign / product a worldbuilding/tabletop artifact, not a promotional video/ad?** If yes, mods may accept it as a "community resource". If no, modmail will decline.
2. **Modmail first** with: link to the campaign template, brief description, disclosure of authorship, offer to take feedback.
3. **If modmail declines:** skip that sub, post only to AI subs (r/LocalLLaMA, r/AIDungeon, r/aigamedev, r/AIPlayableFiction, r/ai_rpg_community) where self-promo is explicitly allowed.
4. **If modmail approves:** include the mod approval note in the Reddit draft body: "Mod-approved community resource post."

## Pattern for the AI subs (explicit self-promo permission)

These subs allow self-promo without modmail:

| Sub | Rule on self-promo | Audience |
|---|---|---|
| r/ai_rpg_community | "You are allowed to self promote just don't go crazy :)" | AI RPG devs |
| r/AIPlayableFiction | "AI use is assumed. You do not need to justify using AI here." | AI fiction |
| r/AIDungeon | No explicit self-promo rule; AI RPG on-topic | AI dungeon users |
| r/aigamedev | "No promotion of commercial services or products ... Commercial GAMES are OK" | AI game devs |
| r/LocalLLaMA | "1/10 rule is a good guideline: self-promotion should not be more than 10% of your content." | Open-source AI |
| r/Rag | 10/90 rule, citation required | RAG / vector DB |
| r/OpenAI | "Self-promotional direct link posts to projects are not allowed. If you are promoting your own project, context must be provided in a text post" | OpenAI / LLM general |
| r/ClaudeAI | Claude-specific only | Claude users |

**Always include "Disclosure: I'm the maintainer."** at the end of every AI-sub draft.

## Aside MCP media-upload pitfall (verified 2026-08-05)

When staging posts via Aside HTTP MCP (`aside mcp` at `http://127.0.0.1:8013/mcp`), Playwright's `locator.setInputFiles(path)` works on **Dev.to, Mastodon, Reddit, HN, LinkedIn, Facebook** but **fails on Twitter/X** with `"Some of your media failed to load"` in the compose dialog. The image file is correctly transferred to the browser but Twitter's media upload endpoint rejects the upload (likely fingerprint/CSRF check that flags automation).

**Workarounds for Twitter media attachments:**

1. **Text-only reply** (≤280 chars) — `Post` button stays enabled, no image attached.
2. **Manual image attach** — user clicks the photo icon in the compose dialog and selects the local file themselves after the agent stages the text.
3. **xurl CLI media upload** — requires `~/.xurl` to have a registered app + OAuth tokens (`xurl auth status` must show an app with oauth2 token). Manual setup via `xurl auth apps add` + `xurl auth oauth2 --app <name>` (see `social-media:xurl` skill).

For **Dev.to** the image upload slot is the **cover image** (separate from the markdown body) — the `textarea#article_body_markdown` accepts markdown but does NOT embed images. To attach an image to Dev.to, use the "Upload Cover Image" button at the top of the editor; the image goes into the post header, not inline.

For **Mastodon** the image attach requires clicking the paperclip icon below the textarea BEFORE setInputFiles works — Playwright finds 1 file input but the input is hidden until the attach button is clicked. Set the `<input type="file">` directly via `locator(input[type="file"]).first().setInputFiles(path)` even when the input is hidden — Playwright bypasses the visibility check on file inputs.

For **Reddit** the image attach requires switching the post type from "text" to "image" (or "link") via the radio buttons — and Reddit text posts cannot have inline images. Image posts upload via the dedicated image upload UI; text posts cannot embed images.

## Single-tweet character budget with two URLs (verified 2026-08-05)

For a single-tweet X post that includes both a project URL and a GitHub instructions URL:

- `worldarchitect.ai/new-campaign` = 33 chars
- `github.com/jleechanorg/worldai_wiki/blob/main/queries/house-of-the-dragon-campaign.md` = 85 chars
- Two URLs alone: 118 chars (plus the `\n\n` separator = 120 chars)
- Remaining budget for narrative: 280 - 120 = **160 chars**

Sample single tweet that fits:

```
Start your WorldAI House of the Dragon campaign to celebrate the season finale — custom D&D stories in the HotD universe.

https://worldarchitect.ai/new-campaign
https://github.com/jleechanorg/worldai_wiki/blob/main/queries/house-of-the-dragon-campaign.md
```

= 161 chars (with the trailing newline). Fits.

If the narrative alone would exceed 160 chars, use a 2-tweet thread instead — first tweet = narrative, second tweet = both URLs. Twitter enforces 280 hard limit; over-limit text disables the Post button with a red counter (e.g. "-48").

## LinkedIn / Facebook / Threads compose-modal anti-bot (verified 2026-07-15, re-confirmed 2026-08-05)

These three platforms have a 2-step share-box → type-of-post popover → compose modal flow. Programmatic clicks via Playwright `getByText('Start a post', { exact: true }).first().click()` work once per session, then fail with a rate-limited event chain. Default workflow for these three:

1. Open the platform's home feed (not the compose URL).
2. Click "Start a post" / "Create a post" manually (or via the agent).
3. Paste the draft into the now-open compose modal.

If the compose modal fails to open via Playwright, surface the draft `.md` file to the user with a manual-paste instruction. Do NOT block the rest of the staging run on these three.