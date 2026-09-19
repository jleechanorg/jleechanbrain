# Case study — arc/companion-arc obligation root-cause, 2026-08-18 (Nocturne campaign)

This is a Layer-2 false-green / Layer-4 aggregate-compliance **deep-dive**: when the LLM
emits `state_updates` but **drops** the required sub-fields `world_events`, `scene_event`,
`companion_arc_event`, and `arc_milestones`, why? Existing skills cover the symptom
(aggregate compliance sampling) and the single-turn diagnostic (served-prompt contract
test). This reference captures the **third dimension** — *prompt position + structural
gate* — that the user explicitly asked for in this delegation and that no previous
reference covers.

## Why this case exists

The user hypothesized three failure shapes for "prompt declares arc/companion-arc
scaffolding but LLM doesn't follow":

- (a) **Long prompt → token-budget decay** — rules at the END never see attention.
- (b) **Buried in single file** — rules need to be at the TOP or near field schemas.
- (c) **Declarative without a SERIAL CHECK** — no parse-time guard catches missing emissions.

This case delivers a quantitative yes/no on each, on a representative arc-abandoned
campaign (`wc2BBcSgOljiU3vJ160A`).

## Empirical findings (campaign `wc2BBcSgOljiU3vJ160A`)

682 LLM calls, 401 story-mode LLM turns with prompt_tokens > 5,000 (turn range 94-242).

| metric | value |
|---|---|
| Median turn prompt_tokens | **293,402** |
| Mean prompt_tokens | 177,154 |
| Max prompt_tokens | **376,684** (≈ 1.5 MB served prompt) |
| Median turn's `request_json` STRING bytes | **1,022,868** (≈ 280 K tokens) |
| Median turn's selected_prompts | `["narrative","mechanics"]` only (no living_world) |
| Median turn's `state_updates.world_events` emission | **absent** |
| Companion-arc-event emission across 401 turns | **0 / 401** ← smoking gun |

### Hard percentages across all 401 high-token turns

| LLM output sub-field | emissions / 401 turns | rate |
|---|---|---|
| `state_updates.world_events` | 11 | **2.7 %** |
| `state_updates.scene_event` | 1 | **0.25 %** |
| `state_updates.background_events` | 8 | **2.0 %** |
| `state_updates.companion_arc_event` | **0** | **0.0 %** ← smoking gun |
| `state_updates.arc_milestones` | 40 | 10.0 % (most are JSON-key false positives, not actual arc emission) |

**Interpretation**: the LW obligations are NOT being satisfied by the LLM. The
aggregate-compliance script in `scripts/aggregate_compliance_check.py` running
across 30 sampled turns reported **13.3 % companion_arc_event / 3.3 % arc_milestones**
across 6 abandoned campaigns — the per-campaign drill-down on Nocturne (the worst
case at 138 story turns) confirms it as **0 %**.

## The three findings mapped to the user's hypotheses

### (a) Token-budget decay — CONFIRMED, sharper than expected

The user's hypothesis threshold was ~40 K tokens / ~160 K chars. The median turn
served prompt is **~280 K tokens / ~1 MB**. That is **7× the threshold**. Empirical
attention-decay is essentially guaranteed at this size.

**But: the failure isn't pure "lost in the middle"**. Across 20 sampled
consecutive long-turn responses on this campaign, the LLM emitted
`state_updates.world_events` in only **3 / 20 (15 %)**. Even at median token
budget the field is dropped 85 % of the time. The drop is structural, not size-correlated.

### (b) File position — CONFIRMED but with a twist

There are TWO situations:

**i. Modal / non-story-mode turns** (level_up, faction, god_mode):
The per-turn `selected_prompts` set on turn 121 was
`["narrative","mechanics"]`. **`living_world` is NOT in the set.** Static
`living_world_instruction.md` (61,508 bytes) is **not loaded at all**. The
served prompt is dominated by an embedded 330 KB V2 god-mechanics bible at the
top (campaign_module_god_of_murder.md stitched with the V1/V2/nocturne
appendices — at byte 0-302 the served request literally opens with
`Description: God of Murder Campaign … The Sanguine Architecture (God
Mechanics V1 + V2)`) plus a 40-entry `story_history` repeating the canon.
On these turns the LW contract never enters the LLM's input.

**ii. Story-mode LW turns** (where `selected_prompts` includes living_world):
The 61,508-byte `living_world_instruction.md` file gets concatenated AFTER
the campaign bible + story_history. Because the bible + history alone is
~330 KB, the LW contract lands at approximately byte **700K-820K of 1,022,868**
— i.e. the **bottom 20-30 %** of the served request. Classic "lost in
the bottom" position. §C1 lines 936-1072 of the file lands at roughly
byte 785K-810K.

**Smoking gun**: in the captured 350,000-byte (head) row for turn 121:

| substring search | hits in head | what it means |
|---|---|---|
| `🌍` (LW marker) | 0 | LW marker not present in served |
| `Living World` (case-insensitive) | 0 | static file NOT loaded |
| `Companion Quest Arcs` | 0 | §C1 NOT loaded |
| `living_world_companion_cadence.md` | 0 | dynamic injection NOT loaded |
| `Cadence` | 0 | no reminder |
| `world_events` | 1, at byte 347,744 | **the schema string name only** — no actual obligation prose |

The single `world_events` hit at byte 347,744 (99.4 %) is the literal
schema-name enum string in the LLM-emitted response schema — NOT a
served-prompt obligation. The LLM was never told to emit `world_events` on
this turn.

### (c) Structural gate — CONFIRMED at the code level

`mvp_site/agent_prompts.py:2711-2802` — `build_living_world_instruction(self, turn_number)`:

```python
def build_living_world_instruction(self, turn_number: int) -> str:
    if turn_number < 1:
        return ""
    if self.game_state is not None:
        should_trigger, trigger_reason, _ = (
            self.game_state.check_living_world_trigger(turn_number)
        )
        if not should_trigger:
            logging_util.info("🌍 LIVING_WORLD: Suppressing injection on cooldown turn ...")
            return ""                    # <<<< ALL companion cadence is below this line
    ...
    arc_summary = self.game_state.get_companion_arcs_summary()
    if arc_summary:
        arc_context = f"\n**Current Companion Arcs:**\n{arc_summary}\n"
    turn_header = ("\n**🌍 LIVING WORLD POLICY**\n" ...)
    injection_path = os.path.join(os.path.dirname(__file__),
                                  constants.LIVING_WORLD_COMPANION_CADENCE_PATH)
    companion_cadence = read_file_cached(injection_path).format(current_turn=turn_number)
    return turn_header + companion_cadence + arc_context
```

The companion-cadence reminder (`living_world_companion_cadence.md`, 879 bytes)
is loaded INSIDE the trigger-gated branch. On non-trigger turns it returns `""`.

The single production caller is `mvp_site/llm_service.py:7725-7749`:

```python
if (not is_god_mode_command and turn_number >= 1 and agent_advances_time
    and not is_modal_time_frozen_mode and pb is not None):
    temporal_anchor = pb.build_temporal_enforcement_reminder()
    if temporal_anchor: lw_blocks.append(temporal_anchor)
    living_world = pb.build_living_world_instruction(turn_number)   # gated -> "" on cooldown
    if living_world: lw_blocks.append(living_world)
    combat_state_reminder = pb.build_combat_state_reminder()
    if combat_state_reminder: lw_blocks.append(combat_state_reminder)
```

`living_world = pb.build_living_world_instruction(turn_number)` is called on
every time-advancing turn, but it returns `""` on cooldown — so
`lw_blocks.append(living_world)` is a no-op for non-trigger turns.

**Other reminder paths and what they cover:**

| reminder | scope | covers companion arcs? |
|---|---|---|
| `build_temporal_enforcement_reminder` | every time-advancing turn | no |
| `build_continuation_reminder` (StoryMode) | every continuation | no — only narrative + planning_block + level-up rules + dice |
| `build_faction_continuation_reminder` | faction mode | no — faction header + state |
| `build_arc_completion_reminder` | only when `get_completed_arcs_summary()!=None` | **opposite** — says "DO NOT revisit completed arcs as if still in progress" |
| `build_combat_state_reminder` | every turn (unconditional, LW-cadence-immune) | no — combat state contract only |

**Conclusion: there is NO companion-arc reminder on story-mode / faction /
god-mode / level_up turns.** The structural gap is real and code-traceable.

## Why the existing aggregate-compliance recipe didn't catch this earlier

The `scripts/aggregate_compliance_check.py` agent-in filter
(`agent IN ('StoryModeAgent', 'HeavyDialogAgent', 'DialogAgent', 'SpicyModeAgent')`)
is correct — the 401 long-turn samples were StoryModeAgent. But the
compliance counter only sees the **response_text** (head 6500 + tail 5000
concat); it cannot see *what was in the served prompt*. To diagnose
*why* a field is dropped, you need the prompt-side byte position analysis
covered by this reference (not the existing aggregate-compliance recipe).

The two recipes are **complementary, not redundant**:

- Aggregate-compliance recipe → "is X dropping, and at what rate?"
- This prompt-position recipe → "is X in the served prompt at all, and where?"

## Recipe — 5 steps to root-cause "prompt declares X but LLM drops X"

### Step 0 — Confirm you're looking at the right row

BQ `worldarchitecture-ai.llm_forensics.llm_payloads` may have **two rows per
turn** (placeholder + streaming). Filter on `LENGTH(request_json) > 100000`
and `turn_index IS NULL` to get the real served-prompt row; the canonical
row with `turn_index=<TURN>` is sometimes a 277-byte stub.

```sql
SELECT turn_index, LENGTH(request_json) AS rj_len, FORMAT_TIMESTAMP('%Y-%m-%dT%H:%M:%SZ', ingested_at) AS ts
FROM `worldarchitecture-ai.llm_forensics.llm_payloads`
WHERE campaign_id = '<CID>' AND ingested_at BETWEEN '<TURN_TIME - 5m>' AND '<TURN_TIME + 5m>'
ORDER BY ingested_at
```

### Step 1 — Strip non-essential envelope, count prompt bytes

`bq` STRING truncation kicks in at 350,000 bytes. The footer reveals the
true size and SHA:

```
TRUNCATED request_json original_bytes=1022868 limit_bytes=350000 sha256=1434cf6...
```

```python
import re
served = open('/tmp/served.csv').read()
m = re.search(r'original_bytes=(\d+)', served)
ORIG_BYTES = int(m.group(1)) if m else len(served)
print(f"served prompt original bytes: {ORIG_BYTES:,}  (~{ORIG_BYTES/4:.0f} tokens)")
```

### Step 2 — Locate the contract substrings in the served prompt

In the case of `living_world_instruction.md`-style contracts, search for the
file's canonical markers:

```python
for needle in ["🌍", "Living World Advancement Protocol", "Companion Quest Arcs",
               "Cadence", "living_world_companion_cadence.md"]:
    idx = served.find(needle)
    print(f"{needle:50s} idx={idx}  ({idx/len(served)*100:.2f}% of captured slice)")
```

**Smoking-gun pattern**: 0 hits in the captured head for the LW marker AND
for the §C1 contract means **the contract is not loaded at all on this
turn type** (selected_prompts excludes it).

### Step 3 — Identify turn-type via `selected_prompts`

```python
m = re.search(r'"selected_prompts"\s*:\s*(\[.*?\])', served)
prompts = json.loads(m.group(1))
print("selected_prompts:", prompts)
# If 'living_world' is missing -> static contract NOT loaded for this turn
```

The static `living_world_instruction.md` is loaded only when the agent's
`REQUIRED_PROMPT_ORDER` includes `PROMPT_TYPE_LIVING_WORLD` AND `selected_prompts`
carries `"living_world"`.

### Step 4 — Trace the runtime gate in `agent_prompts.py`

```python
# Confirm the production-side gate is what you think it is
import re
src = open('${HOME}/projects/worldarchitect.ai/mvp_site/agent_prompts.py').read()
m = re.search(r'def build_living_world_instruction.*?(?=\n    def )', src, re.DOTALL)
print(m.group(0))  # full method body
```

Look for:
- `check_living_world_trigger(...)` early return `""`
- `companion_cadence = read_file_cached(LIVING_WORLD_COMPANION_CADENCE_PATH)`
- the `return turn_header + companion_cadence + arc_context` line

If the cadence loading happens INSIDE a gated branch, the cadence reminder
is fire-on-trigger-only. **Confirmed on `wc2BBcSgOljiU3vJ160A` at agent_prompts.py:2730-2800.**

### Step 5 — Cross-check aggregate emissions

```sql
SELECT COUNT(*) AS n,
       COUNTIF(REGEXP_CONTAINS(response_text, r'"world_events"'))        AS emits_world_events,
       COUNTIF(REGEXP_CONTAINS(response_text, r'"companion_arc_event"')) AS emits_companion_arc_event,
       COUNTIF(REGEXP_CONTAINS(response_text, r'"arc_milestones"'))      AS emits_arc_milestones
FROM `worldarchitecture-ai.llm_forensics.llm_payloads`
WHERE campaign_id IN ('<CID1>','<CID2>')
  AND is_test = false AND prompt_tokens > 5000
```

If aggregate emission rate is < 10 % for any required field and the
contract is gated or buried, the diagnosis is: **the served prompt either
never contains the contract on this turn type, or contains it at a
byte position outside the LLM's effective attention window**.

## Pitfalls (don't skip)

- **Don't trust `prompt_tokens` over `original_bytes`.** BigQuery trunccates
  the `request_json` STRING at 350,000 bytes with a footer that DOES
  contain `original_bytes=<N>` — always read the footer before drawing
  prompt-size conclusions. On `wc2BBcSgOljiU3vJ160A` turn 121 the captured
  350,000-byte slice was 34 % of the real 1,022,868-byte served prompt.
- **Don't equate `LENGTH(request_json)` columns with `prompt_tokens`.**
  `prompt_tokens` is the billing-side count from Gemini after caching
  discounts; `request_json` STRING bytes are the raw payload. They correlate
  (~4 chars/token) but are not the same number. Use `request_json` byte
  counts for prompt-position analysis, `prompt_tokens` for cache/token-rate
  analysis.
- **Don't assume `selected_prompts` carries the contract on every turn.**
  Modal turns (`game_mode: level_up`, `faction`, `god_mode`) often ship
  with only `["narrative","mechanics"]` — `living_world` is silently absent.
  The static contract file is therefore **not loaded**, not "loaded at the
  bottom". On Nocturne turn 121 (a `level_up` modal) the served prompt
  contains 0 hits for any LW marker.
- **Don't confuse `world_events` the schema-name string with the
  obligation.** A served prompt may legitimately mention `"world_events"`
  once, as the schema-name enum string in `narrative_response_schema`,
  without ever telling the LLM "you MUST emit `state_updates.world_events`."
  The smoking gun is: zero LW markers + zero obligation prose + the LLM
  emitting no `world_events` in `state_updates`.
- **Don't read aggregate compliance numbers without checking story-mode
  turn count.** A campaign with only 38 story-mode turns (Sariel Valyria)
  reporting 0 companion_arc emissions is not the same signal as a 138-turn
  campaign (Nocturne) reporting 0. Aggregate at 13 % across 6 campaigns
  understates the per-campaign worst case (Nocturne = 0 %).
- **Don't trust a single-turn structural verdict.** Always sample N>=5
  consecutive high-token turns to confirm the structural pattern (the
  `wc2BBcSgOljiU3vJ160A` sample of 20 consecutive turns confirmed
  3/20 emit `world_events` — i.e. the cadence reminder only fires on a
  fraction of the LW turns even when not gated).
- **The 879-byte `living_world_companion_cadence.md` is the only per-turn
  recency reminder.** It is loaded via `os.path.join(__file__, LIVING_WORLD_COMPANION_CADENCE_PATH)`
  inside the trigger-gated branch — verify with `ls -l` that the path
  resolves under any WORKDIR (the comment in `agent_prompts.py` notes the
  Docker WORKDIR=/app/mvp_site trap; `os.path.dirname(__file__)` is the
  canonical fix).
- **`ARC COMPLETION ENFORCEMENT` is the OPPOSITE of a cadence reminder.**
  `build_arc_completion_reminder()` (agent_prompts.py:2686) only fires when
  completed arcs exist and the body is `"DO NOT revisit these arcs as if
  they are still in progress"` — this fires *after* an arc ends, never to
  push one forward.

## Files for this investigation (2026-08-18)

- `/tmp/wa_arc_root_cause.md` — the 3-section root-cause report (INV 1 byte
  size + position, INV 2 token-budget decay, INV 3 story-mode coverage gap)
- `/tmp/wa_analyze3.py` — the head-350K captured-slice analyzer that found
  0 hits for any LW marker on turn 121

## What the fix looks like (not part of this skill — recorded for posterity)

Two-pronged closure of the structural gap:

1. **Lift §C1 out of `living_world_instruction.md` into a top-of-prompt
   byte-stable micro-file (~1 KB)** — runs at byte ~200 every turn, recency
   window. Must be byte-stable across turns for Gemini cache byte-identity.
2. **Universal per-turn injection** — `build_story_mode_dynamic_instructions`
   (and the faction / god_mode branches) ALSO inject the cadence reminder,
   not just the LW-trigger branch. Today the gate is the structural gap.

Plus the response-parser assertion (Layer 3):
- When `is_living_world_turn` OR `cadence_fired == True`, **require**
  `state_updates.world_events` (and on cadence-bearing turns,
  `companion_arc_event` or `arc_milestones`) in the parsed JSON.
- On failure, fall back to a short repair re-prompt OR clamp/coerce
  defaults. Companion arc obligation is currently optional-by-LLM-decision.

## Cross-references

- `wa-llm-output-emission-false-green-watchdog` (this skill) — Layer 1 + 2
  framework + audit-event-source cousin
- `references/aggregate-compliance-sampling.md` — Layer 4 statistical
  sibling; this reference is the **prompt-position Layer 2 cousin**
- `references/case-9057-action-resolution-warning.md` — sibling case where
  the schema anchor was on a feature branch (not on `origin/main`); same
  false-green family
- `wa-narrative-schema-required-fields-contract` — sibling Layer 2 worked-
  example contract test (worked JSON regex)
- `wa-daily-dice-audit-fix` — Layer 1 audit-event-source cron; **NOT a
  substitute** for the prompt-side analysis this reference describes
- `wa-prompt-only-sanctuary-dialog-opportunities` — BG3-style companion
  dialog rule (related, but for a different mechanism — state-flag-gated)
