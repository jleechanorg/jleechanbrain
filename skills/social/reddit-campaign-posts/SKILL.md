---
name: reddit-campaign-posts
version: 0.1.0
description: Reddit submissions for product launches across subs.
when_to_use: |
  Use when drafting / staging / posting Reddit submissions — especially for product
  launches, campaign updates, or any "post across N subs" ask. Triggers: "draft a Reddit
  post", "post to r/<sub>", "post this to Reddit", "use the house dragon share campaign
  post format", "/social reddit", any Reddit-aware /history follow-up.
allowed-tools:
  - Read
  - Write
  - Bash
  - Edit
  - Grep
triggers:
  - "draft a Reddit post"
  - "post to r/"
  - "Reddit submit"
  - "house dragon share campaign"
  - "HotD share campaign format"
  - "post across subs"
  - "/social reddit"
context: inline
---

# Reddit Campaign Posts

Class-level umbrella for **Reddit post-drafting work that spans multiple subs** for an ongoing product launch — distinct from one-off Reddit questions or comment replies. Companion to the broader `social-poster` skill (user-owned), but focused on the campaign-post structure that has shipped to 5+ subs across the Aug-2026 batch.

## When to use this skill (not social-poster)

- User asks to draft a Reddit post **for a specific campaign/feature** they've shipped (not a generic launch)
- User references "the house dragon share campaign post format" or similar prior format name
- User wants the same post **re-tailored across multiple subs** (the typical "post to 5–10 subs" pattern)
- A /history follow-up asks "did I already post about X here?" — covers the live-permalink verification + draft-staging loop

## Core deliverables (always)

1. **Reusable post structure** captured in `templates/hotd-share-campaign.md` — 9-section template derived from the r/AiBuilders → r/SoloDevelopment pattern
2. **Old.reddit submit-form DOM pitfalls** — three traps the React-reddit-form selectors don't catch (see SKILL.md §Pitfalls + references/old-reddit-dom-pitfalls.md)
3. **POST APPROVED gating contract** — drafts go in Aside / disk, never live without explicit `POST APPROVED` (inherits from social-poster §6)

## Pitfalls (Reddit old-submit-form DOM)

Staging via `old.reddit.com/r/<sub>/submit` has three traps that don't appear on the new Reddit React form. Hit all three in one r/SoloDevelopment session on 2026-08-25.

1. **Title is a `<TEXTAREA>`, not `<INPUT>`.** Common selectors miss it. Correct selector: `document.querySelector('textarea[name="title"]')`. Must `focus()` + `click()` first, then set value via the native `HTMLTextAreaElement.prototype.value` setter and dispatch `input` + `change` events. Without focus, the title value reverts to empty even though `.value` reports the right length.

2. **The "text" / "link" tabs are decorative `<li>` elements, not real toggles.** Clicking them does nothing. To actually switch modes, **navigate** to:
   - Text mode: `https://old.reddit.com/r/<sub>/submit?selftext=true` (URL field hidden, body textarea visible)
   - Link mode: `https://old.reddit.com/r/<sub>/submit` (URL required, body hidden)
   - Image mode: requires `kind=image` and a separate `/submit?image=true` flow

3. **Two submit-looking buttons exist. Only one is the real submit:**
   - `<button>save</button>` (text=`save`) — stays `disabled: true` even when form is valid. Ignore.
   - `<button name="submit" type="submit">submit</button>` — the actual submit. Check this one's `disabled` state.

4. **Image upload in text mode is impossible.** Reddit's old submit form forces text / link / image as exclusive `kind` values. If the draft is text+image, you must either (a) drop the image and ship text-only, (b) switch to image mode and lose the body text, or (c) post text-only first and add the image as a comment reply. For text-friendly subs like r/SoloDevelopment, option (a) is usually right.

## Verbatim worked example

The 2026-08-25 r/SoloDevelopment draft (`/tmp/drafts/solodev-2026-08-25/reddit_solodevelopment_worldai.md`, md5 `af22e2bf409e2528057c2b49cfef4dcd`) is the canonical worked example. It uses the HotD share-campaign template and adds a sub-specific "What being solo on this actually feels like" section after the standard 9-section close — a pattern that should extend whenever a target sub has a focus the standard template doesn't address.

## Files

- `templates/hotd-share-campaign.md` — reusable 9-section template (Title → Intro → Numbers → Hero campaign → Audience-specific insights → Comparison table → What's missing → Links → Disclosure)
- `references/old-reddit-dom-pitfalls.md` — copy-paste recipes for the three DOM traps above

## Companion skills

- `social-poster` (user-owned) — broader skill covering all platforms (Reddit + HN + Mastodon + LinkedIn + Twitter + Dev.to + Threads + Facebook + Instagram). Use this skill instead of social-poster for the Reddit-only subset, OR run both in parallel: social-poster for the cross-platform rules, this skill for the campaign-structure + Reddit-DOM-specific lessons.
- `memory-search` — surface prior Reddit drafts from session_search before drafting a new one
- `aside-browser-default` — primary browser for staging (Reddit works in Chrome, anon-curl is blocked)