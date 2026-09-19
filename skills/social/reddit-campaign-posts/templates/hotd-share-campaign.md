---
title: Reddit HotD share-campaign post template
subreddit: <target_sub>
post_type: text + image (or text-only if image mode not available)
disclosure: "I'm the maintainer of WorldArchitect.AI."
---

# Reusable HotD share-campaign post template

**Use when:** the user asks for a Reddit draft about a specific campaign/feature they've shipped (not a generic launch), AND references a prior post format they used elsewhere. This template captures the structural pattern that has shipped to r/AiBuilders, r/GeminiAI, r/solorpgplay, r/indiegames, r/SoloDevelopment, and others across the Aug-2026 batch.

**Origin:** first drafted for r/AiBuilders on 2026-08-20 (session `@session:default/20260820_175538_6f9f90d4`), then reused with sub-specific tweaks for 5+ other subs. The user explicitly named it "the house dragon share campaign post format" on 2026-08-25 — treat that phrase as a canonical reuse trigger.

---

## Structure (in order)

1. **Concrete title** (≤300 chars, descriptive, no clickbait): "[What you built] — [specific scenario angle] — [implication for the reader]" — usually 130–180 chars. Avoid "Revolutionary", "Game-changing", emoji.

2. **Intro paragraph** (3–5 lines): name the project, link to live URL, state what this specific post is about. End with a positioning statement ("Why I'm posting here" or "What I think <audience> will find interesting").

3. **The numbers / proof block** (bullet list, 6–10 items): concrete stats that prove the project exists. The same number set ships across all subs because it's the source-of-truth.

4. **The hero campaign / feature** (the post-specific centerpiece):
   - For HotD: hardcore-mode Rhaenyra at locked Day-1 state (CS 18%, Treasury 280gp, PTR 75, 200+ smallfolk, Syrax L6 12d6/165HP)
   - For each sub: the "why this matters to *this* audience" angle (r/AiBuilders wants AI system architecture; r/solorpgplay wants solo RPG mechanics; r/SoloDevelopment wants solo-dev workflow)

5. **What I think <audience> will find interesting** (3–5 bullets): technical insights that match the sub's typical reader. Always include at least one "I had to rewrite X because the model underneath changed" confession.

6. **Comparison table** (5 rows): "Hardcore mode" vs "typical easy-mode AI RPG". 5 columns: Aspect | Hardcore | Easy. The table is the most-shared asset — make it scannable.

7. **What's still missing** (3 bullets): genuinely missing features you want feedback on. Not "we're working on it" — actual gaps.

8. **Links block**: live URL + Reddit share-tokens + wiki/bible path. Markdown links, not bare URLs.

9. **Disclosure line**: "I'm the maintainer of WorldArchitect.AI. <scope statement>." Required by r/SoloDevelopment Rule 2 and good practice everywhere.

## Length target

- Title: 130–180 chars
- Body: 5,000–7,000 chars (well under Reddit's 40k selftext cap)
- Self-contained: no cross-references to other subs (each reads as native)

## Anti-patterns to avoid

- Cross-references between subs ("as I posted on r/X...") — kills the native feel
- "Sign up now!" CTAs — replaced with specific asks
- Bare links with no context — every draft has enough that the link is optional
- Buzzwords: "Revolutionary", "Game-changing", "Powerful" — tank posts on every sub

## When to deviate

- If the user names a *different* campaign/feature (not HotD), keep the structure but swap the centerpiece for the new one
- If the target sub has a hard character limit (r/SideProject etc.), cut the comparison table to 3 rows and merge the numbers block into the intro
- If the user wants an *update* post (not a launch), keep sections 4–9 but replace the intro with "Since my last post 6 weeks ago..."

## Verbatim example (r/SoloDevelopment, 2026-08-25)

See `/tmp/drafts/solodev-2026-08-25/reddit_solodevelopment_worldai.md` (md5 `af22e2bf409e2528057c2b49cfef4dcd`) for a complete worked example that adds a "What being solo on this actually feels like" section after section 9 — the solo-dev sub-specific extension.