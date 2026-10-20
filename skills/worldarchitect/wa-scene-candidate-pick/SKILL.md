---
name: wa-scene-candidate-pick
description: "Pick diverse bounded scenes from a WA campaign pool."
when_to_use: "Use when: Step 1 of the avatar-scene-gen pipeline. Given /tmp/avatar_scene_gen/01_campaigns.jsonl (or a scope-filtered subset like last20_over50.json), /tmp/avatar_scene_gen/raw_<id8>.jsonl story entries, and /tmp/avatar_scene_gen/drive_avatars_deduped.jsonl, pick N distinct scenes for downstream Step 4 (wa-scene-rewrite). Do NOT use for Firestore data extraction (wa-per-user-campaign-lookup), Drive-avatar dedupe (this skill consumes its output), LLM rewrite (wa-scene-rewrite), or wiki ingest (llm-wiki)."
version: 1
author: Hermes Agent (auto-curated 2026-08-14; v1 created after strict-last-20 RE-DO on Overlord shy lich / JQeI1Aq5)
license: internal
metadata:
  hermes:
    tags: [scene-gen, pipeline-step-1, scene-pick, scope-filter, visual-diversity, avatar-scene-gen]
    related_skills:
      - wa-per-user-campaign-lookup
      - wa-scene-rewrite
      - download-campaign
      - llm-wiki
arguments:
  - scenes_count
  - scope_filter_json
argument-hint: "[scenes_count=5] [--scope <filter.json>] [--out /tmp/avatar_scene_gen/02_scene_candidates.md]"
context: inline
allowed-tools: terminal, file
---

# wa-scene-candidate-pick — scene selection for the avatar-scene-gen pipeline

## When to use

Use this skill when:

1. **You are sibling-worker Step 1 of the avatar-scene-gen pipeline** — your dispatcher handed you a scope filter (commonly `last20_over50.json` or `01_campaigns.jsonl`), `raw_<id8>.jsonl` files for the qualifying campaigns, and `drive_avatars_deduped.jsonl`. Output is `/tmp/avatar_scene_gen/02_scene_candidates.md`.
2. **Any other scene-candidate pick task** where the deliverable is a markdown table of visually-diverse bounded scenes spanning `raw_<id8>.jsonl` files.

## When NOT to use

- For Firestore data extraction → `wa-per-user-campaign-lookup`.
- For Drive-avatar dedupe → this skill consumes `drive_avatars_deduped.jsonl`; it does NOT produce it.
- For LLM rewrites → `wa-scene-rewrite` (Step 4 sibling).
- For wiki ingest → `llm-wiki` (downstream Step 5).

---

Class-level umbrella for **Step 1 of the avatar-scene-gen pipeline**: given N campaigns that passed a scope filter (last-N-by-last_played, ≥50 entries, or any custom filter), pick `scenes_count` distinct, visually-diverse, bounded-narrative-beat scenes and write the deliverable markdown table. Sibling Step 4 (`wa-scene-rewrite`) reads this output to dispatch Grok/Gemini rewrites.

## The job in one paragraph

Read the campaigns that survive the scope filter (commonly `01_campaigns.jsonl` or `last20_over50.json`). For each qualifying campaign, read its raw story entries from `/tmp/avatar_scene_gen/raw_<id8>.jsonl` (rows of `{idx, ts, actor, mode, text}` sorted by `ts`). Pick `scenes_count` distinct scenes that (1) span different **visual buckets** (default: indoor / outdoor / dramatic battle / political / environmental-puzzle), (2) each form a clearly bounded narrative beat (not mid-action or setup), (3) have ≥3 named NPCs present, and (4) are spaced out across the campaign's entry range so they don't overlap. For each pick, capture entry range, scene summary, why_memorable, named_npcs, and Drive-avatar references (from `drive_avatars_deduped.jsonl` + `~/llm_wiki/raw/assets/avatars/`). Fall back to the campaign-level `avatar.png` when no character-specific Drive match exists. Write `/tmp/avatar_scene_gen/02_scene_candidates.md` (OVERWRITE any previous version).

## Step-by-step

### 1. Resolve the scope filter

The most common inputs:
- `01_campaigns.jsonl` — top-N campaigns sorted by `last_played` desc
- `last20_over50.json` — already filtered to last-20 ∩ ≥50 entries (may have 0–N survivors)
- Custom: any JSON with `{qualifying_campaigns: [{campaign_id, title, entry_count}, ...]}`

Always **echo the filter back in the output's preamble** so downstream stages can audit why specific scenes were chosen.

### 2. When the filter yields < `scenes_count` campaigns

This is the **strict-scope one-campaign case** (overlord-only run, 2026-08-14: 1 campaign passed the filter, 5 scenes needed → all 5 from one 364-entry campaign). Resolution:

1. **Same-campaign picks are explicitly allowed when the filter narrows scope** — don't try to expand the filter to hit diversity-across-campaigns.
2. The 5 visual buckets (indoor / outdoor / battle / political / environmental-puzzle) **still apply WITHIN a single campaign** — you must find 5 different scene types in one source.
3. Spread scenes by **entry-index target centers** (`~10, ~80, ~160, ~240, ~320` for a 364-entry campaign) — adjust inward at end-of-campaign if the last center falls beyond the file length.
4. **Drop the "different campaign per scene" rule entirely** for this case; the per-scene diversity shifts to scene-type diversity inside one narrative arc.

### 3. Read raw entries

```python
import json
entries = [json.loads(l) for l in open(f"/tmp/avatar_scene_gen/raw_{cid8}.jsonl")]
```

`idx` is 0-based; the deliverable's `entry_range` is 1-based inclusive. Always convert: a 0-based `idx=N` is the 1-based entry `N+1`.

### 4. Identify scene boundaries

A **scene** in a WA raw JSONL is a contiguous block of `{user, gemini}` (or `{user, narrator}`) exchanges bounded by:
- A `gemini/character` (or `narrator/character`) entry that opens with location-setting prose ("Soft pale-blue light from floating arcane crystals spills across..." / "Morning mist clings to the jagged maws of..."), AND
- Concluding with either (a) a `user/character` action that ends the beat, (b) a `user/god` retcon that pivots the scene, or (c) a clear time-skip ("three weeks have passed", "Morning on the 160th day...").

**Do not pick:**
- Character-creation exchanges (mode=`character_creation`).
- Pure god-mode retcon clusters with no narrative beat (`user/god → gemini/god` chains about modifier math, mask-layer tracking, level scaling).
- Mid-action pivots — i.e. a scene fragment whose opening or closing action is missing.

### 5. Diversity enforcement

For 5 scenes, target:
| # | Bucket | Visual cues to look for in the gemini prose |
|---|---|---|
| 1 | **Indoor** | chamber / hall / throne room / vault / throne / library / private study, mention of "doors", "rafter", "dusty light", no outdoor cues |
| 2 | **Outdoor** | gate / square / mountains / ridge / forest / sky / clouds / wind / mist on open ground, mention of "sun" + "cobbles"/"grass"/"stone walls" |
| 3 | **Dramatic battle** | mentions of combat / spells named (Mirror Wall, Dominate Person, Lightning, etc.) / casualty reference / armor / weapon / offensive posture |
| 4 | **Political** | throne / sovereign / covenant / treaty / negotiation / Social HP / kingdom / empire / theocracy / formal address |
| 5 | **Environmental-puzzle** | climbing / terrain navigation / natural hazards / tracking trail / magical signature on landscape / extreme environment (altitude / cold / thin air) |

These buckets are **not mutually exclusive** — a battle can happen outdoors, a throne room can have an environmental-puzzle (locked vault). When two buckets overlap, **pick the bucket that is the dominant visual frame** (e.g. Throne Room scene = political, even though it's indoors; outdoor dragon encounter = environmental-puzzle, even though there's a dragon "battle" element).

### 6. NPC extraction

Use a curated whitelist of canonical NPC names for the relevant IP (e.g. for Overlord: Ains, Sebas Tian, Demiurge, Albedo, Cocytus, Shalltear, Mare, Aura, Pandora, Gazef Stronoff, Ramposa III, Jircniv Rune, Fluder Paradyne, Zesshi Zetsumei, Nigun, Chenier, Enri Emmot, Climb, Nfirea, Lakyus). For unknown IPs, grep for `[A-Z][a-z]+(?:\s+[A-Z][a-z]+){0,2}` then filter against common English stopwords.

Goal: **≥3 named NPCs per scene** so 1–3 Drive avatars can be depicted.

### 7. Avatar coverage

For each scene:
1. Grep `drive_avatars_deduped.jsonl` for `kept_filename` matching character names (case-insensitive substring match: "Sebas", "Gazef", "Demiurge", etc.).
2. If a direct character-name match exists → use its sha8 + filename.
3. If **no character-name match** → use the campaign-level `avatar.png` as the single-character stand-in (fetched from `https://storage.googleapis.com/worldarchitecture-ai-frontend-static/campaign_avatars/<uid>/<cid>/avatar.png`).
4. Document the fallback explicitly in the Notes section so Step 4 knows which scenes have rich coverage vs single-avatar coverage.

For the Overlord-shy-lich run (2026-08-14): **only `ca197e7b_ains_shy_lich` matched**. All other named NPCs (Sebas, Demiurge, Gazef, Ramposa, Kalle, etc.) fell back to campaign-level `avatar.png`.

### 8. Write the deliverable

`/tmp/avatar_scene_gen/02_scene_candidates.md` MUST include:
1. **Preamble**: scope filter echo + source-campaign list.
2. **Scene table** (markdown): `# | Slug | Entry range | Scene summary | Why memorable | Named NPCs | Drive avatars (sha8 + filename)`.
3. **Diversity checklist** (markdown): one row per bucket, scene # matched, visual cue verbatim.
4. **Notes for parent**:
   - Strict-scope → only N campaigns → all `scenes_count` scenes from one campaign.
   - Per-NPC portrait situation (still no per-NPC portraits in Firestore, only campaign-level avatar.png).
   - Avatar coverage tally (direct Drive matches vs falls-back-to-campaign-avatar).
   - Entry-range spacing audit (target centers vs actual).
   - Blockers / soft blockers.
   - Files overwritten (this file) and files NOT touched (per task constraints).

### 9. Sibling-write race

`02_scene_candidates.md` is in `/tmp/` which is shared across sibling subagents. The dispatcher may spawn multiple Step-1 siblings simultaneously (e.g. Grok and Gemini siblings). **The write_file tool emits a warning if a sibling modified the file between your read and your write**. If you see that warning:

1. The write still lands — `verified: true` confirms on-disk content hash.
2. Re-read the file once to confirm your content is the version on disk.
3. Do NOT retry the write — your version is correct and the warning is informational.

The race is benign when the dispatcher has coordinated ownership; it indicates parallel sibling workers. The skill that governs the file (this one) is authoritative — overwrite without hesitation.

## Verification (must-pass before declaring done)

1. **Exactly `scenes_count` rows** in the scene table (no more, no less).
2. **All 5 visual buckets covered** when `scenes_count == 5` (or appropriate subset if custom bucket list).
3. **Entry ranges are disjoint** — no entry appears in two scenes.
4. **Entry-range centers roughly match** the requested target distribution (`~10, ~80, ~160, ~240, ~320` for a 5-scene pick from a ~360-entry campaign).
5. **≥3 named NPCs per scene** — verified by re-running the NPC-grep over the scene's text slice.
6. **Each Drive avatar reference** either (a) exists as a sha8-prefixed file in `~/llm_wiki/raw/assets/avatars/`, or (b) is the literal `campaign-avatar-default` placeholder with a fallback note.
7. **Diversity checklist** has one row per bucket with a visual cue quote from the actual scene prose.

## Pitfalls

1. **Don't expand the scope filter to hit diversity-across-campaigns.** When the user says "strict last-20 → ≥50 → pick 5", and only 1 campaign passes, you pick 5 from that 1. The user's instruction is the spec.
2. **Don't re-fetch from Firestore.** The `raw_<id8>.jsonl` files are already on disk; always slice from them. Re-fetching wastes 10–60s and risks introducing timestamp ordering inconsistencies.
3. **Don't fall back to "no good scene here, pick another campaign" when the filter is intentionally narrow.** Same-campaign picks are explicitly allowed when the filter narrows scope; document this in Notes for parent.
4. **Bucket overlap.** A scene with a Throne Room (indoor + political) and a battle (outdoor + dramatic battle) should be classified by its dominant visual frame. Document the secondary bucket in the Notes section if needed.
5. **Avatar-name substring match is greedy.** Searching for "Ains" in `drive_avatars_deduped.jsonl` will also match files containing "Ains" anywhere in the filename. Restrict to canonical character names per IP to avoid false positives (e.g. "Ains" matches `ca197e7b_ains_shy_lich` correctly, but searching "Seb" might pick up unrelated Drive files).
6. **Per-NPC portraits do NOT exist in Firestore.** Documented in `wa-per-user-campaign-lookup`'s Pitfall 5. Don't waste time hunting for them; the campaign-level `avatar.png` is the only image asset. Plan Step 4's avatar slots around this reality.
7. **5 Drive avatars used in earlier Step 4 do NOT carry over.** The 7 Step-4 avatars (Sariel / Alexiel / Arion / Nocturne / Visenya / Valeria) are non-Overlord IPs; for an Overlord-only Step 1 re-do, only `ca197e7b_ains_shy_lich` is the same IP. Step 4 must rebuild its avatar pool from the new Step 1 output.
8. **Don't pick a god-mode-only exchange as a scene.** Entries where `actor=user, mode=god` followed by `actor=gemini, mode=god` are admin/retcon, not narrative. Skip them.
9. **Don't split a scene across multiple prompt chunks.** If the gemini response is 600 words split across 3 entries, treat the whole arc as ONE scene and use the bounding entry range.
10. **Entry index is 0-based `idx`; deliverable uses 1-based entry numbers.** A gemini opening at `idx=78` is entry 79 in the deliverable's `entry_range`.

## Related skills

- `wa-per-user-campaign-lookup` — produces the campaign list and per-user data this skill consumes.
- `wa-scene-rewrite` — Step 4 sibling; reads `02_scene_candidates.md` to dispatch Grok/Gemini rewrites.
- `download-campaign` — produces the `raw_<id8>.jsonl` files this skill slices from.
- `llm-wiki` — downstream Step 5 ingest; uses the rewrites + avatars.
- `references/strict-scope-one-campaign-pattern.md` — the full worked example from the 2026-08-14 Overlord-shy-lich re-do: how to handle a scope filter that yields only 1 campaign, with the entry-target-center adjustment and the avatar-coverage audit.
- `references/visual-bucket-taxonomy.md` — extended bucket definitions with positive/negative cues per IP (Overlord / Star Wars / ASOIAF / DC / Fantasy Spellblade), so future workers can classify scenes consistently across IPs.

## v1 changelog

- **2026-08-14 v1:** Initial creation after the strict-last-20 scene-picking RE-DO on the Overlord shy lich campaign (1 qualifying campaign, 5 scenes all from one source, 5/5 visual buckets covered, only 1 character-name Drive match, 5 fallback avatars). Captured the same-campaign-pick pattern, the diversity-within-one-campaign rule, the avatar-fallback audit, and the entry-target-center spacing strategy.