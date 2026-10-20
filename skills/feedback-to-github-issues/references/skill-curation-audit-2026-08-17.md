# Skill-curation audit (kevin feedback review session, 2026-08-17)

## Skills I tried to update but couldn't (user-owned)

- **`download-campaign`** — wanted to add pitfalls #9-12 (two jleechan UIDs, title fallback chain, 22-char campaign_id, slow→parallel scan pattern). All are real session lessons but the skill is user-owned (created_by=None). Recommend `hermes curator adopt download-campaign` to enable patching.
- **`wa-prod-data-query`** — wanted to add a 7th pitfall about email-vs-UID jleechan filter. Same user-owned blocker. Recommend `hermes curator adopt wa-prod-data-query`.

## Skills I successfully updated

- **`parallel-investigate-and-dispatch`** (curator-managed) — added an anti-pattern about the 4th sync subagent (max_concurrent_children=3 cap). One bullet addition under Anti-patterns.
- **`feedback-to-github-issues`** (curator-managed) — added a "Cross-user validation pattern" section with the worked example (kevin → 6 complaints → 26-campaign scan → distribution-driven priorities). Also added a reference file `references/all-users-download-recipe.md` containing the working inline Python script for downloading all real-user campaigns. SKILL.md gained a one-line pointer to the reference.

## Why I parked the user-owned skills

Per SOUL.md and the curator rules: user-owned skills cannot be patched by autonomous agents — only by the user in a foreground session. The pitfalls I'd add to `download-campaign` are durable and would help every future agent — recommend adoption so the next kevin-style "download all X" request doesn't repeat the same 22-char-ID confusion or title-fallback confusion.