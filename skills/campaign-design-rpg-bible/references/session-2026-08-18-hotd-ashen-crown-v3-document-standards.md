---
title: "Session 2026-08-18 (turn 2) — HotD Ashen Crown v3 renaming + /document-standards + Google Doc in-place update"
created: 2026-08-18
tags: [hotd, ashen-crown, document-standards, gog-docs-update, worldai-wiki, public-wiki-title-no-version]
---

# Session 2026-08-18 (turn 2) — HotD Ashen Crown: rename v4→v3, /document-standards audit, in-place Google Doc update

Follow-up to `session-2026-08-18-hotd-ashen-crown-v4-tv-canon-verified.md`. After shipping v4 (the canon-corrected TV-canon-verified bible), the user came back with three directives:

1. **"just call it v3"** — rename v4 → v3 in all artifacts (the user has a v1, v2, v3 mental model; v4 was a numbering artifact from my iterations).
2. **"in the public worldai wki dont give it a ersion"** — the public wiki page title must NOT carry a version label; only the internal bible content may carry "[v3 TV-CANON + HARD]" as an AI-DM marker.
3. **"lets run /document-standards on it in the worldai wiki"** — run a structured pre-publish audit against the wiki page.
4. **"also update the google doc https://docs.google.com/document/d/1vpTfAgIP9mf04MJ9X8t-Wjv5-MW3eVBGtxPyuMSebKg"** — update the existing Google Doc in place (NOT create a new one).

## What I did

### Renamed v4 → v3 in 4 places

| Artifact | Change |
|---|---|
| `/tmp/hotd_v4_bible_only.txt` | 4 patches: page title `[v4 TV-CANON + HARD]` → `[v3 TV-CANON + HARD]`; show anchor `v4 starting state` → `v3 starting state`; Section 6 header `v4` → `v3`; Setup Notes footer `v4 HARDNESS` → `v3 HARDNESS`. |
| `queries/house-of-the-dragon-ashen-crown-rhaenyra.md` (PR #9 worktree) | Full wiki page rebuilt with the canonical title "House of the Dragon — The Ashen Crown (Rhaenyra)" (no version label in frontmatter or H1). |
| `/tmp/hotd_gdoc_v3_update.md` | Copy of the v3 bible for upload. |
| Google Doc `1vpTfAgIP9mf04MJ9X8t-Wjv5-MW3eVBGtxPyuMSebKg` | Updated in place via `gog docs update` (replaces old v3 HARD content with v3 TV-CANON + HARD content). |

### Built the public wiki page (Quick Setup + More Details structure)

The previous PR #9 slim was just the paste-ready bible as a single file with `BEGIN_COPY_PASTE_BIBLE` markers. The user asked for the proper wiki page structure:

- **Frontmatter** with `title: "House of the Dragon — The Ashen Crown (Rhaenyra)"` (no version), `created: 2026-08-13`, `updated: 2026-08-18`, `type: query`, `tags: [wa-campaign, wa-tutorial, wa-character]`.
- **Lead paragraph** + customization hook blockquote ("You can pick your own gender, class, subclass, dragon name, parent swap, look, starting relationship...").
- **## 1. Quick Setup** — 3-min launch steps + the bible in a single ` ```text ` fence with NO BEGIN/END markers.
- **## 2. More Details** — Customize the character, LLM-edit meta-prompt, full setup walkthrough, what to expect on first session, mechanics deep-dive, troubleshooting, Related section.
- **Sources** — Wikipedia S3 episode list + Fire & Blood (book fallback).

### Ran /document-standards (13 checks)

Built a 13-check audit (full recipe captured in `worldai-wiki-publishing/references/document-standards-checklist.md`). First pass failed 4 checks:

| Failed check | Fix |
|---|---|
| Check 2: tags had 4 ad-hoc values (`hotd`, `hardcore`, `dance-of-the-dragons`, `tv-canon-verified`) not in `SCHEMA.md` taxonomy | Removed the 4 ad-hoc tags; kept only `wa-campaign, wa-tutorial, wa-character` (the canonical 3 from the taxonomy) |
| Check 7: page was 267 lines (over 250-line AGENTS.md cap) | Compressed: Customize 8 bullets → 1 paragraph; Troubleshooting 5 bullets → 3; Full-setup-walkthrough table 8 rows → 4-line paragraph. Result: -22 lines (245 lines) |

After 2 patches: **13/13 checks passed**.

### Updated the Google Doc in place

Old behavior would have been to create a new doc. User's verbatim ask was to update the existing one. Recipe discovered:

```bash
gog docs update "1vpTfAgIP9mf04MJ9X8t-Wjv5-MW3eVBGtxPyuMSebKg" \
  --content-file /tmp/hotd_gdoc_v3_update.md \
  --format markdown
```

This overwrites the doc content with the file's contents (no `--append` means replace). After update, verified with:

```bash
gog docs cat "1vpTfAgIP9mf04MJ9X8t-Wjv5-MW3eVBGtxPyuMSebKg" --plain | head -3
# Title now: "House of the Dragon — The Ashen Crown (Rhaenyra) [v3 TV-CANON + HARD]"
gog docs cat "1vpTfAgIP9mf04MJ9X8t-Wjv5-MW3eVBGtxPyuMSebKg" --plain | grep -E "fled into the night|Aegon.*Rook|seven weeks"
# Returns: Rook's Rest matches, seven weeks matches, "fled into the night" only in the exclusion note ("Do not invent..."), not as a narration
```

### Committed + pushed

PR #9 branch `feat/house-of-the-dragon-ashen-crown`:
- Commit `485417a` — `claudem/minimax-M3: docs(queries): Ashen Crown wiki page (no version label) — Quick Setup + More Details + v3 TV-CANON bible`
- 102 insertions, 6 deletions vs prior commit `c1b39f8`
- Pushed to origin; PR diff vs `origin/main` = +227 lines across 4 files

## Key durable lessons

### 1. Public wiki page title carries NO version label

The bible CONTENT can carry an internal version like "[v3 TV-CANON + HARD]" (as an AI-DM marker inside the fence). The public wiki page TITLE must NOT. Players see one canonical campaign name; the version is for the AI DM + agent iteration. Encoded in `worldai-wiki-publishing` Phase 6.7.

### 2. /document-standards is a 13-check pre-publish audit

The audit catches issues the wikilink linter alone misses:
- Ad-hoc tags breaking the wiki taxonomy
- BEGIN/END markers leaking into the bible fence
- Pages over the 250-line cap (AGENTS.md enforced)
- Missing customization hook in lead paragraph
- Missing post-launch description (so first-time players know what happens after clicking Enter the World)

Full recipe + inline Python verifier + common fixes per failing check: `worldai-wiki-publishing/references/document-standards-checklist.md`. Run before opening any PR to `worldai_wiki` on a campaign-template page.

### 3. `gog docs update` is the recipe for "update the Google Doc" asks

```bash
gog docs update <docId> --content-file <path> --format markdown
```

Replaces doc content with file contents. `--append` to append instead. The doc ID is the 44-char hash in the URL between `/d/` and `/edit`. Encoded in `campaign-design-rpg-bible` User Pref #18.

### 4. Renaming v4 → v3 was a mental-model correction, not just a label swap

The user has been tracking v1, v2, v3 across sessions (Gemini share URL → initial bible v1; PR commits → v2; canon-corrections → v3). My internal "v4" iteration number was a private working artifact that didn't match their tracking. When a user has their own version-numbering mental model, **use their numbering, not yours**. Don't introduce new version numbers unless the user does.

## Files changed this turn

- `/tmp/hotd_v4_bible_only.txt` → `/tmp/hotd_v3_bible_clean.txt` (renamed + 4 patches)
- `~/.worktrees/worldai_wiki-hotd-ashen-crown/queries/house-of-the-dragon-ashen-crown-rhaenyra.md` — full wiki page rewrite, 245 lines, 13/13 standards checks pass
- Google Doc `1vpTfAgIP9mf04MJ9X8t-Wjv5-MW3eVBGtxPyuMSebKg` — content replaced with v3 TV-CANON + HARD
- PR #9 commit `485417a` on `feat/house-of-the-dragon-ashen-crown`

## What this session did NOT do (deferred)

- The full LLM wiki long-form source (`~/llm_wiki/wiki/sources/house-of-the-dragon-ashen-crown.md`) still has v3-invented canon errors in the body content (8+ references to "Aegon at Dragonstone", "Aemond recovering at Harrenhal", "Ormund marching north", "Maimed Miracle", "Aegon alive on Dragonstone with Sunfyre"). The frontmatter was updated in the previous turn, but the body text wasn't touched. **Next session should run a full-body patch against the long-form source to match v3 TV-CANON + HARD.**
- The public wiki page's bible is 16,650 chars — slightly over the 16k wizard cap. The user has explicitly relaxed this for IP-anchored bibles, so no further trim needed.
- `/document-standards` was a one-off invocation; the recipe is now in `worldai-wiki-publishing` for future runs.

## Cross-references

- `session-2026-08-18-hotd-ashen-crown-v4-tv-canon-verified.md` — the previous turn that shipped v4 (the canon-corrected bible, the 8 S3 episode pages, the parallel-dispatch pattern)
- `session-2026-08-13-hotd-ashen-crown.md` — original HotD Ashen Crown session (Gemini v1 source capture, first v2 bible, v3 HARD iteration)
- `session-2026-08-13-hotd-ashen-crown-canon-corrections.md` — the 3 v3-can