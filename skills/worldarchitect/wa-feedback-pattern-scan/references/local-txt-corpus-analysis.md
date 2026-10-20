# Local .txt corpus analysis — scanning downloaded campaign dumps (verified 2026-08-17, batch C)

This reference covers the **local-corpus variant** of `wa-feedback-pattern-scan`: instead of pulling entries live from Firestore, you scan pre-downloaded `.txt` dumps from a directory like `~/Downloads/all_campaigns/`. Used for the kevin feedback review batches (A/B/C) where campaigns were already exported to disk.

## When to use the local variant vs. the Firestore variant

- **Firestore variant** (default): one campaign at a time, live, via `download-campaign` → `wa-feedback-pattern-scan`. Use when you only need one or two campaigns or want the *latest* entries.
- **Local-corpus variant** (this): batch 5–20 pre-downloaded `.txt` files; same fields, same scoring rubric; no auth/path boilerplate. Use when the parent task is *cross-user comparison via exported dumps* — the case for the kevin feedback review.

Both variants produce **the same per-campaign JSON shape** so the post-hoc summary aggregation is identical.

## File format

Each `campaign.txt` is a transcript dump. Verified headers/markers (regex-parseable):

```
============================================================
SCENE N
============================================================
[Timestamp: ...
Location: ...
Status: Lvl X Class | HP: a/b (Temp: c) | XP: ... | Gold: N gp
Conditions: ... | Exhaustion: N | Inspiration: ...
]
Resources: ...

Game Master:
<one or more paragraphs of narrative prose>

Player (choice: <slug>):
<one-line free-text choice in user voice>

============================================================
SCENE N+1
============================================================
```

Sometimes interleaved with `Dice Rolls:` blocks (after Game Master block). Pre-scene header (before SCENE 1) is the god-mode spec: `God Mode: Character: ... | Setting: ... | Description: ...`.

## Schema (12 fields per campaign, plus 4 useful extras)

Same as Firestore variant plus three additions useful for the local dump:

| Field | Type | Source |
|---|---|---|
| `campaign` | str | folder name (e.g. `My_Epic_Adventure_zoHTbFxY`) |
| `expected_entries` | int | claimed entry count (folder manifest) |
| `scene_marker_count` | int | `SCENE N` markers actually found in file |
| `cc_turns` | int | `Player (choice:)` lines (proxy for user turns) |
| `cc_uses_standarddnd` | bool | D&D 5e markers hit (Paladin/Wizard, d20, AC:, HP:, ability scores, Oath of, 5e) ≥3 of: `\bd20\b`, class list, `HP:\s*\d`, `AC:\s*\d`, `Oath of`, `5e`, `Standard Array` |
| `action_resolution_warning_count` | int | phrase matches: `action resolution warning`, `cannot resolve`, `unclear action`, `invalid choice`, `no valid target` |
| `loop_severity` | `none\|mild\|moderate\|severe` | see Pitfall 1 below |
| `onboarding_score` | 0/1/2 | first 1500 chars contain `character creation` + at least one of {`ability scores`, `class:`} → 2; only `character creation` or `character sheet` → 1; otherwise 0 |
| `friction_score` | 0/1/2 | n_player_choices > 50 AND mean len < 100 → 2; n > 20 OR mean len < 60 → 1; else 0 |
| `goal_score` | 0/1/2 | contains mission keywords in first 3000 chars AND worldbuilding header in first 1500 → 2; either → 1; none → 0 |
| `readability` | 0/1/2 | based on mean chars per `Game Master:` block: <800 → 2, <1500 → 1, ≥1500 → 0 |
| `wall_of_text_evidence` | int | mean chars per `Game Master:` block |
| `file_size_kb` | int | nice-to-have for cross-corpus size sanity |
| `notable_patterns` | list | free-form flags: e.g. `["uses dice rolls", "GM narrator blocks", "structured player choices", "wall-of-text GM blocks (>2k chars)", "deep lore setting", "adult themes", "dragon-themed", "original setting (not standard DnD name)"]` |
| `first_3_user_actions` | list | first 3 `Player (choice: <slug>):` lines verbatim |
| `first_post_cc_text` | str | first narrative GM block after character creation flow — see Pitfall 2 below |

## The two pitfalls that bit this pass (and how to fix them)

### Pitfall 1 — Loop detection that's too lenient catches nothing

A naive detector that uses sentence-bigram repetition on the entire transcript misses the most useful signal: **repeated first lines of `Game Master:` blocks**. In the Halcyon_Days dump:

```
"administrative mutation applied:"     → 9 occurrences
"### administrative modifications log:" → 4 occurrences
"[debug_resources_start]..."           → 3 occurrences
```

These are *system-prompt echoes*, not user content — and they indicate the LLM is bouncing off an admin/debug prompt chain, not actually advancing the narrative. Same surface signal, different bug class than dup-submit loops. **Score loop_severity using repeated first-line frequency in GM blocks** + Player action Jaccard ratio, not document-wide bigrams.

Concrete threshold table (verified across 9 batch-C campaigns):

| `max_repeat` (same first line, ≥15 chars) | `distinctive_count` (lines with freq ≥5) | `player_choice_unique_ratio` | verdict |
|---|---|---|---|
| ≥7 | ≥3 | (any) | severe |
| ≥4 | ≥1 | <0.5 | moderate |
| ≥2 | (any) | <0.75 | mild |
| else | | ≥0.75 | none |

The `akey445@/My Space Adventure` dup-submit pattern (3× identical consecutive player actions, Jaccard≈1.0) is a separate signature — distinguish by inspecting whether the *GM responses* between identical player actions are identical (dup-submit) vs. progressively different (LLM loop). See `references/loops-vs-dup-submit.md`.

### Pitfall 2 — `first_post_cc_text` grabs the wrong GM block

The `Game Master:\s*\n(.*?)(?=\n(?:Player|Dice Rolls|\[Timestamp|={5,}|\Z))` regex captures GM blocks fine, but the *first* GM block in a campaign is almost always a character-sheet dump, not narrative. Common false positives:

| Starts-with | What it actually is | Skip? |
|---|---|---|
| `CAMPAIGN LAUNCH` / `CAMPAIGN SUMMARY` | system summary box | yes |
| `[CHARACTER CREATION - Review]` | CC confirmation | yes |
| `Warden Character Sheet Editor` | sheet-editor block | yes |
| `[debug_resources_start]` | debug | yes |

### Pitfall 2 (added 2026-08-17, batch D) — `action_resolution_warning_count=0` is wrong when empty-timestamp scenes exist

Batch A pitfall #9 said action_resolution warnings are unmeasurable from .txt because the `"Missing action_resolution field"` string is stripped into the `_game_state.json` system_warnings layer. That's still true for the explicit string.

But there's a SAME-CLASS warning visible in the timestamp header itself. Detect with:

```python
import re
empty_ts_count = len(re.findall(r'\[Timestamp:\s*[^]]*,\s*,', scene))
```

The pattern `\[Timestamp:[^]]*,\s*,` matches scenes like `[Timestamp:  DR,  , 12:30:00` (empty date components). Verified in batch D: all three bg3 replays (RED short, RED long, GREEN long) share an empty-timestamp scene 5 — the LLM produced the same bug deterministically at that playthrough position. Score as `action_resolution_warning_count += 1` per occurrence.

**Calendar-drift as a 2nd-order proxy:** also count distinct year-format tokens:

```python
year_tokens = re.findall(r'(\d+\s*(?:A\.G\.|DR|New Peace|NP|N\.P\.)?)', text)
distinct = len(set(year_tokens))
```

If `distinct > 2` AND the campaign uses a single linear timeline (no cross-setting arc), flag as calendar drift. Counter-example: Dragon Knight uses 5 year formats but each maps to a canonical campaign year — `40 AG` (pre-imperium), `11 DR` (Dale Reckoning), etc. Verify against the campaign bible before flagging; only flag when formats collide on the same in-world date.

### Pitfall 3 (added 2026-08-17, batch D) — Validation replays are not real-user UX

Any campaign whose folder name matches `bg3_nocturne_*__replay_*` (or similar `__replay_<date>__<uid>` pattern) is a jleechan validation replay, not a real-user playthrough. Skip UX scoring or mark `is_validation_replay: true`. These will have:
- Player actions 100% freeform (no choice menu).
- 200+ god-mode prompts even for short replays.
- Repeated empty-timestamp scenes + Admin Update scenes throughout.
- Friction score is meaningless — the user is testing parser robustness, not playing.

Don't conflate "small choice-menu usage" with "user gave up"; in validation replays, choice-menu usage is zero by design.

### Pitfall 4 (added 2026-08-17, batch D) — Python dict key ordering makes byte-diff comparators wrong

When two `.txt` exports of the same campaign differ at byte level (e.g., RED vs GREEN validation replays), the differences are almost always JSON-dict key ordering inside `Dice Rolls:` blocks, not content. Naive `diff` shows hundreds of lines different → conclusion "different campaigns" is wrong 100% of the time. Fix: strip the Dice Rolls blocks and re-compare. Verified 279/603 byte-divergent scenes → 0 prose divergences after normalization. See `references/red-green-replay-diff-methodology.md`.

The real first narrative block contains scene-setting prose. Heuristic: scan GM blocks in order, accept the first one whose first 400 chars (lowercase) contain at least one of `the wind`, `the road`, `you find yourself`, `you begin`, `you've`, `you stand`, `you arrive`, `you wake`, `the bite`, `the cold`, `you pull`, `beside you`. Fallback to second GM block if no prose block matches.

## Verified findings (2026-08-17, batch C, 9 campaigns 56–234 entries)

| Campaign | entries | cc_turns | dnd | loop | onboard | friction | goal | read | wall (chars) |
|---|---|---|---|---|---|---|---|---|---|
| My_Epic_Adventure_zoHTbFxY | 56 | 23 | ✓ | none | 1 | 1 | 1 | 0 | 1539 |
| Dragon_Warrioress_adtDKJlS | 68 | 15 | ✓ | moderate | 1 | 0 | 0 | 2 | 725 |
| My_Epic_Adventure_IPdrNpY7 | 82 | 26 | ✓ | mild | 1 | 1 | 1 | 1 | 1439 |
| Wyltopia_y1y9JSfs | 82 | 40 | ✓ | none | 1 | 1 | 1 | 0 | 1508 |
| Trashcon_Days_U8QnbMS6 | 92 | 16 | ✓ | moderate | 1 | 0 | 1 | 2 | 691 |
| My_Epic_Adventure_Rys4n4Bg | 114 | 56 | ✓ | none | 1 | 1 | 1 | 1 | 1408 |
| My_Epic_Adventure_LZKiE0jU | 128 | 62 | ✓ | mild | 1 | 1 | 1 | 1 | 1344 |
| Halcyon_Days_2G4YpEKF | 222 | 14 | ✓ | **severe** | 1 | 0 | 0 | 1 | 999 |
| My_Epic_Ballsac_Dragonurphace_aK8GPGCr | 234 | 73 | ✓ | none | 1 | 1 | 1 | 0 | 1642 |

**Net read (cross-batch with batch A/B):**
- **StandardDND** = 9/9 in batch C (every campaign uses D&D 5e mechanics — `Wyltopia` and `Trashcon` are original settings but still pick up 5e markers via ability scores/d20/`Oath of`).
- **Wall-of-text** median 1408 chars per GM block. `My_Epic_Ballsac…` (1642) and `My_Epic_Adventure_zoHTbFxY` (1539) are the longest; `Dragon_Warrioress` (725) and `Trashcon_Days` (691) are the cleanest.
- **Halcyon_Days_2G4YpEKF** flagged severe for repeated system-prompt echoes — a real loop-class bug, distinct from the dup-submit pattern in `references/loops-vs-dup-submit.md`.
- `action_resolution_warning_count = 0` across all 9 (none of the magic phrases appear).

## Recipe

1. Verify the corpus directory exists: `ls ~/Downloads/all_campaigns/`
2. Copy `scripts/analyze_local_txt_corpus.py` to `/tmp/analyze_batch_X.py` and edit the `CAMPAIGNS` list (folder names + expected entry counts).
3. Run: `python3 /tmp/analyze_batch_X.py` → writes `/tmp/all_readings/batch_X.json` + `/tmp/all_readings/batch_X_summary.json`.
4. Aggregate across batches by reading each `batch_X_summary.json` and concatenating the distribution dicts.
5. For wall-of-text outliers (>2000 chars avg), cross-reference with `wa-narrative-schema-required-fields-contract` to verify the schema is correct, not over-long.

## What this variant does NOT do

- No path-order or auth setup — `.txt` dumps are flat files, no Firestore.
- No `GOOGLE_APPLICATION_CREDENTIALS` env var.
- No UID/email exclusion — the corpus directory is hand-curated (jleechan's own dumps).
- No `planning_block` vs `narrative` separation — the `.txt` dump doesn't preserve the schema split.