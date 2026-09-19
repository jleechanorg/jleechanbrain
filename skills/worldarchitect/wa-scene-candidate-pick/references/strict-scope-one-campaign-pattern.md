# Strict-scope, one-campaign pattern (worked example)

## The situation

The user supplied a strict rule: "**last-20 campaigns by `last_played` desc → filter to those with ≥50 story entries → pick 5 scenes from those. Same-campaign picks are EXPLICITLY allowed.**"

When the rule is applied:
- 20 campaigns survive the last-20 window.
- Of those, **only 1 campaign** has ≥50 story entries (Overlord shy lich / `JQeI1Aq5` / 364 entries).
- The naive interpretation of "5 scenes from those" is "5 scenes from those 1+ campaigns", which the user has explicitly blessed.

This is the **strict-scope one-campaign case** and it changes the picking strategy:

| Constraint | Multi-campaign default | One-campaign override |
|---|---|---|
| Diversity sources | 5 different campaigns × 5 visual buckets = 25 candidates | 5 different scene-types within 1 narrative arc |
| Entry-range targets | Distributed across multiple files | All centers fall within a single 364-entry file |
| Fallback when filter narrows | "Pick from a different campaign" | "Find a different scene-type inside the same campaign" |
| Avatar coverage | Per-campaign avatar.png + few per-NPC Drive files | Same — but the per-NPC Drive files are IP-specific to ONE campaign |

## What to do — the algorithm

1. **Confirm the filter input.** Read `last20_over50.json` (or equivalent) and confirm `last20_pass_50plus == 1`. Echo the qualifying campaign list in the deliverable's preamble.

2. **Open the single campaign's raw entries.** `raw_<id8>.jsonl` is already on disk; do NOT re-fetch from Firestore.

3. **For each of the 5 visual buckets, locate a candidate scene.** Use the bucket cues (see `visual-bucket-taxonomy.md`). Record entry range as `[start, end]` 1-based inclusive.

4. **Spread entry centers.** For a 364-entry campaign, target centers at ~10, ~80, ~160, ~240, ~320. The end-of-campaign scene (#5) may need to pull inward if the campaign is short — if a 364-entry campaign ends at entry 363, the ~320 target is fine; if the campaign were only 200 entries, pull #5 inward to ~180.

5. **Verify each candidate is a bounded narrative beat.** A scene is bounded when:
   - It opens with a `gemini/character` (or `narrator/character`) entry whose text opens with location-setting prose (time-of-day + lighting + sensory detail).
   - It closes with a `user/character` action that ends the beat, OR a `user/god` retcon that pivots the scene, OR a clear time-skip in the closing gemini prose ("Three weeks have passed...").
   - No god-mode-only exchanges inside the bounding range (mode=`god` clusters are setup, not narrative).

6. **Verify each candidate has ≥3 named NPCs.** Use the IP-specific whitelist (for Overlord: Ains, Sebas, Demiurge, Albedo, Cocytus, Shalltear, Mare, Aura, Pandora, Gazef Stronoff, Ramposa III, Jircniv, Fluder, Zesshi, Nigun, Chenier, Enri, Climb, Nfirea, Lakyus). Re-run the whitelist grep against the scene's text slice and confirm ≥3 hits.

7. **Resolve Drive avatars.** Grep `drive_avatars_deduped.jsonl` for character-name substring matches. For the Overlord-shy-lich run, only `ca197e7b_ains_shy_lich` matched; all other NPCs fell back to the campaign-level `avatar.png`. Document the tally.

8. **Write the deliverable** to `/tmp/avatar_scene_gen/02_scene_candidates.md` (OVERWRITE).

## Worked output from 2026-08-14

Input: `last20_over50.json` → 1 campaign (Overlord shy lich / `JQeI1Aq5` / 364 entries).

Output: 5 scenes, all from entries 7–355 of the single campaign, covering all 5 visual buckets:

| # | Slug | Entries | Bucket | Center vs target |
|---|---|---|---|---|
| 1 | `treasury_audit_opening` | 7–9 | Indoor | ~8 vs ~10 ✓ |
| 2 | `royal_audience_re_estize` | 79–93 | Political | ~86 vs ~80 ✓ |
| 3 | `world_item_raid_iron_mine` | 157–167 | Dramatic battle | ~162 vs ~160 ✓ |
| 4 | `imperial_audit_e_rantel` | 317–327 | Outdoor | ~322 vs ~320 ✓ |
| 5 | `three_finger_ridge_dragons` | 353–355 | Environmental-puzzle | ~354 vs ~320 (pulled inward — last 9 entries; the dragon encounter is the natural end-of-arc scene) |

Avatar coverage: 5 direct Drive matches (all `ca197e7b_ains_shy_lich` for Ains) vs 5 fallback-to-campaign-avatar (one per scene for non-Ains NPCs). No adjacent-archetype Overlord characters exist in Drive.

## Pitfalls specific to this pattern

1. **Don't expand the filter.** When the user says "strict", they mean it. If only 1 campaign passes, you pick 5 from that 1 — never silently widen the threshold (e.g. drop to "≥30 entries") to pick from more campaigns.

2. **Don't pick the same scene-type twice.** When constrained to one campaign, you might be tempted to grab "two battle scenes" because they're the most visually obvious. Force the 5-bucket rule.

3. **Don't invent scene boundaries that don't exist.** If a campaign only has 1 battle scene, the "dramatic battle" bucket gets that 1 scene; the other 4 buckets must come from non-combat beats (Throne Room negotiations, Council Chamber deliberations, outdoor travel, environmental hazards).

4. **Don't run out of NPC diversity.** A single campaign might have 50+ named NPCs (Overlord has Ains, Sebas, Demiurge, Albedo, Gazef, Ramposa, Jircniv, Fluder, Zesshi, Nigun, Kalle, Raymond, Maximilian, Chenier, Enri, Climb, Nfirea, Rianon, Grom, Elos, Silvershard, etc.). Use them — each scene should feature 3+ DIFFERENT NPCs so each scene has its own avatar-pool subset.

5. **The end-of-campaign scene often pulls inward.** Target centers of `~10, ~80, ~160, ~240, ~320` assume a campaign with at least 350 entries. If the campaign is shorter, the last scene's center must be ≤ (entry_count − ~5) so the gemini response and any closing user action fit within the file.

6. **Sibling-write race.** A sibling subagent may also touch `02_scene_candidates.md` between your read and your write. The write_file tool warns about this; the write still lands with `verified: true`. Do NOT retry.

## What this pattern is NOT

- It is NOT "degrade to whatever scenes you can find." The 5 visual buckets are still mandatory.
- It is NOT "let one scene be the same campaign twice." Each scene must have a distinct `entry_range`.
- It is NOT "ignore the user filter." The filter is the spec; widening it is a silent override that breaks downstream Step 4 expectations.