# Empirical aggregate LLM-output compliance sampling (the statistical sibling of false-green)

**Added**: 2026-08-18, prompted by delegated task to root-cause why the LLM drops
declared arc/companion-arc scaffolding. The `wa-llm-output-emission-false-green-watchdog`
SKILL.md already covers single-turn diagnostics; this reference captures the
**aggregate-compliance** scale-up: sample N turns across N campaigns and measure the
emission rate of a fixed field set. Empirically confirmed: across 30 sampled
jeffrey-story-mode turns from 6 campaigns flagged in their titles as
"forgot/think-ignored/off-track" failures, mandatory-prompt fields were
present at the following rates:

| Field | Hits / 30 | Rate |
|---|---|---|
| `companion_arc_event` / `companion_arcs` | 4 | 13.3% |
| `arc_milestones` | 1 | 3.3% |
| `scene_event.quest_offered` | 0 | 0.0% |
| `active_mysteries` / `mystery` | 0 | 0.0% |
| Last choice id = `freeform`/`custom_action`/`__custom_action__` | 1 | 3.3% |

`planning_block.choices` count: always 3-5 (mean ~4), no inflation.

## Why this recipe exists

Single-turn diagnostics answer "did this turn's LLM output contain X?" — useful
for one PR, useless for "is X actually working in production?" The aggregate
sample answers the production question with a number.

The headline finding from this round was: companion-arc cadence is **not a
narrative thread the LLM tracks** — it's a per-turn side-effect of the prompt
cadence reminder firing on that turn. The hits cluster at non-consecutive
slots (T1, T30, T60 across different campaigns) and never appear sustained,
which matches the prompt-inventory hypothesis (referenced from
`wa-planning-block-choice-contracts`) that companion-arc cadence reminders fire
only on LW turns.

## Recipe — five steps, <12 minutes wall time

### Step 1 — Pick the population

Use `/tmp/wa_campaigns_over_<threshold>.json` (the file convention from
`wa-planning-block-choice-contracts` "Audit-first trigger pattern") — it already
has campaign metadata plus a "prompt_source" excerpt you can spot-check.

For title-annotated failures, **the parenthetical is the user's own diagnostic**
(e.g. "Visenya v9 (forgot tybolt)", "bg3 nocturne murder god (think ignored)",
"Supergirl (story off track)"). These are not noise — they are the user's
manual labels from their abandonment analysis.

### Step 2 — Single BigQuery query, ROW_NUMBER per campaign

```sql
WITH story_rows AS (
  SELECT campaign_id, ingested_at, turn_index, agent, event_type, model,
         SUBSTR(response_text, 1, 6500) AS head_text,
         SUBSTR(response_text, GREATEST(LENGTH(response_text)-4999, 6501)) AS tail_text,
         LENGTH(response_text) AS response_chars
  FROM `worldarchitecture-ai.llm_forensics.llm_payloads`
  WHERE campaign_id IN ('<CID1>','<CID2>',...)
    AND agent IN ('StoryModeAgent','HeavyDialogAgent','DialogAgent','SpicyModeAgent')
),
ranked AS (
  SELECT *, ROW_NUMBER() OVER (PARTITION BY campaign_id ORDER BY ingested_at) AS rn
  FROM story_rows
)
SELECT campaign_id, rn AS sampled_turn, ingested_at, turn_index, agent, event_type, model,
       head_text, tail_text, response_chars
FROM ranked
WHERE rn IN (1,5,15,30,60,100)
ORDER BY campaign_id, rn
```

**Why `agent IN (...)` and not `path LIKE '%story%'`**: the `agent` column is
already denormalized to a small enum. `request_json.path` lives inside the
350KB+ truncated stub — you cannot reliably filter by path. The 4-agent set
covers all story-mode responses (verified 2026-08-18 against
`worldarchitecture-ai.llm_forensics.llm_payloads` agent histogram).

**Why head 6500 + tail 5000**: the `response_text` field is <50KB in practice
for story-mode turns (longest observed: 12KB). The head covers the response
header + planning_block (top) + the entire narrative block (middle, ~3-5KB).
The tail covers `state_updates` and any other deep-field emissions. The
concat-with-newline strategy avoids the parsing trap that head-only sampling
misses fields that live at the bottom of the JSON.

**Save to**: `/tmp/wa_arc_work/raw_sample.json` (the convention used by the
2026-08-18 sampling run; the intermediate filename doesn't matter but
preserves the head/tail structure).

### Step 3 — Run the regex/recipe checks

The reference implementation lives at
`scripts/aggregate_compliance_check.py` (committed alongside this file). It
implements:

- **A. companion_arc_event / companion_arcs** — regex `'\"companion_arc_event\"|\"companion_arcs\"'` on head+tail
- **B. arc_milestones** — presence of `"arc_milestones"` or `"arc_milestone"`, phase extracted via `r'"phase"\s*:\s*"([^"]+)"'`
- **C. scene_event.quest_offered** — substring `"quest_offered"` (falls back to `"scene_event"` for any related field presence)
- **D. active_mysteries / mystery** — substring `"active_mysteries"` (falls back to `"mystery"`)
- **E. planning_block.choices count** — balanced-brace walker that handles **both** shapes:
  - `[{"id": "..."}, {"id": "..."}]` → count `"id"` entries
  - `{"choice_key": {...}, "choice_key_2": {...}}` → count top-level keys at depth 0
- **F. last choice is freeform** — extract last choice id via the walker, match against `freeform|custom_action|__custom_action__`
- **G. narrative_chars** — string walk between `"narrative": "` and the next unescaped `"`
- **H. response_chars** — already returned by BQ (`LENGTH(response_text)`)

### Step 4 — Per-campaign compliance summary

Group by campaign, emit a 6-line block per campaign like:

```
### fw9Fo3QXkqshtVxBIwX2 — Visenya v9 'forgot tybolt'
- T1: companion_arc=NO phase=— quest=NO mystery=NO choices=4 freeform_last=NO  → narrative 2644 / response 7517
- T5: ...
- T100: campaign_ended_at_turn_72
```

End-of-campaign slots show the run's story-mode turn ceiling (computed as
`MAX(rn)` from the same CTE — see `STORY_TOTALS` dict in the script). When
`MAX(rn) < target_turn`, the slot is reported as `campaign_ended_at_turn_N`.

### Step 5 — Compute overall compliance rate

Across all **non-ended** slots:

```python
total = sum(1 for c in data['campaigns'] for t in c['sampled_turns'] if 'checks' in t)
hits = {'A': 0, 'B': 0, 'C': 0, 'D': 0, 'F': 0}
for c in data['campaigns']:
    for t in c['sampled_turns']:
        if 'checks' not in t: continue
        chk = t['checks']
        if chk['A_companion_arc_event'][0]: hits['A'] += 1
        if chk['B_arc_milestones'][0]:       hits['B'] += 1
        if chk['C_quest_offered'][0]:        hits['C'] += 1
        if chk['D_active_mysteries'][0]:     hits['D'] += 1
        if chk['F_last_choice_freeform']:    hits['F'] += 1
```

Report `hits[k] / total` as a percentage.

## Pitfalls (don't skip)

- **Don't try to parse big nested JSON, regex is enough.** The `response_text`
  field is a flat string. Trying to `json.loads()` it on a 350KB+ row risks OOM
  and is unnecessary — every check you need is a substring or a regex match
  on the raw text. The walker for `planning_block.choices` is the one
  exception (you need balanced-brace walking to handle the two shapes).
- **Don't trust a single turn.** A `B=True` hit at turn 100 is not evidence
  the schema works — it's evidence that *one* LLM invocation chose to emit it.
  Aggregate across N≥5 campaigns × N≥4 turns to get a usable rate.
- **`sampled_turn` comes back as STRING from BQ JSON export.** BQ serializes
  INT64 to string in JSON output. When grouping rows back by
  `(campaign_id, sampled_turn)`, key on the str form. The script handles this.
- **The campaign_ids in the source JSON file are prefixes of the real BQ
  IDs.** `fw9Fo3QXkqshtVxBIwX2` in the campaigns-over-100 file is a 20-char
  prefix of the actual 22-char BQ id (`fw9Fo3QXkqshtVxBIwX2` + 2 chars). Use
  `.startswith()` lookups in the source JSON, but pass full IDs to BQ (resolved
  from the BQ row dump at query time).
- **The two `choices` shapes are real and both are valid.** The early version
  of `count_choices_in_planning_block` over-counted by including nested object
  keys ("description", "text", "pros", "cons") as if they were top-level choice
  ids. The walker only counts keys at depth 0 inside the `"choices": {...}`
  block, never inside nested choice bodies. **Always verify the count matches
  the visible choice list before trusting the script.** For the 2026-08-18 run,
  expected was 3-5; anything above that is a walker regression.
- **The `companion_arcs` field can be nested inside `custom_campaign_state`,
  inside `state_updates`.** The head+tail concat covers this — `state_updates`
  is in the tail. If you only sample the head you will miss every
  `custom_campaign_state.core_memories` / `arc_milestones` emission and your
  compliance rate will understate the true value.
- **Empty choices arrays mean the LLM failed entirely.** A sample with
  `E_choices_count = 0` is NOT "the LLM emitted zero choices on purpose" — it
  means the planning_block is missing or the choices block is malformed.
  Cross-check the response_chars and the agent field; if the agent is
  `StoryModeAgent` and the response is <5KB, the LLM likely truncated.
- **The user's narrative block is ~50% of the response.** Narrative averages
  ~3KB while total response averages ~8KB on this corpus. The rest is
  structural JSON (planning_block + action_resolution + state_updates). When
  the LLM "forgets" a construct, it's usually not the prose dropping it — it's
  the prose having nothing to anchor the construct to.

## Reference data — 2026-08-18 run

| Campaign | Title | Story turns | Evaluated slots |
|---|---|---|---|
| fw9Fo3QXkqshtVxBIwX2 | Visenya v9 (forgot tybolt) | 72 | T1, T5, T15, T30, T60 (T100 = ended) |
| qoQtHsU7DxZnR24VNU9w | Visenya v9 | 50 | T1, T5, T15, T30 (T60, T100 = ended) |
| wc2BBcSgOljiU3vJ160A | bg3 nocturne murder god (think ignored) | 138 | T1, T5, T15, T30, T60, T100 |
| 1jO5rtBMvkvreFGCLahs | Valeria iseki | 113 | T1, T5, T15, T30, T60, T100 |
| EROaUnSbmDhqBedTbJMg | Sariel Valyria | 38 | T1, T5, T15, T30 (T60, T100 = ended) |
| 6aXYric3k1IXtJIg6LjT | Supergirl (story off track) | 90 | T1, T5, T15, T30, T60 (T100 = ended) |

30 evaluated, 6 ended. All campaigns jeffrey (jleechan@gmail.com). All
"completion_state = abandoned" in the source metadata.

## Files for the 2026-08-18 run

- `/tmp/wa_arc_compliance_sample.json` — 6 campaigns × 6 slots, full structured checks
- `/tmp/wa_arc_compliance_readme.md` — per-campaign summaries + overall compliance table + interpretation
- `/tmp/wa_arc_work/raw_sample2.json` — raw BQ pull, 280KB, head+tail concat source
- `/tmp/wa_arc_work/check_compliance.py` — the analyzer that produced the report (now in `scripts/aggregate_compliance_check.py`)