# WA Mechanic Rebalance — Prompt + Server Cooldown Dual-Edit Pattern

**Source:** Verified 2026-08-21 on PR `feat/uc-streak-gate-lw-tone-24h-cd14` (in flight). Use when the user says "I want fewer X" / "I want more Y" / "this happens too often" / "make X less aggressive" about a WA game mechanic that is LLM-emitted under a prompt contract.

## When to use

The mechanic in question has ALL of:
- A `state_updates.<thing>` field the LLM emits (e.g. `state_updates.complications`, `state_updates.world_events.background_events[]`)
- A prompt contract that describes the emission rule (e.g. `min(20 + success_streak * 10, 75)`)
- A canonical log string the LLM writes (e.g. `Complication Check: 5 vs Threshold 30 (Triggered)`)
- Currently firing too often (or not often enough) per the user's lived experience

Do NOT use for:
- Pure UI changes (use `wa-frontend-test-guard-scoping`)
- New mechanics the user wants added from scratch (use the existing "How to add a new mechanic" in `SKILL.md` §How to add a new mechanic)
- Schema-only changes (no LLM emission involved)

## The 5-step pattern (verified)

When the user reports "X happens too much", the fix is **prompt contract + server-side cooldown** in tandem. Prompt-only drifts; server-only is opaque to the LLM. Both together is durable.

### Step 1 — Audit the current rate with BQ

Before changing anything, get the real number. The user has a feeling; the data tells you whether the feeling matches reality and where the leak is concentrated.

Recipe: `references/wa-prompt-bq-audit-recipe.md` (sister reference). Output: a 3-line table of (total turns, % with the keyword, % with the canonical log) plus a per-agent breakdown. Put this in the PR body as the "current rate" baseline.

**Concrete (UC, 30d, 2026-08-21):** 2.69% of LLM turns mention "complication" anywhere; 0.09% emit the canonical `vs Threshold <N>` log; HeavyDialogAgent is the heaviest emitter at 18.8% (NOT combat, despite intuition).

### Step 2 — Edit the prompt contract (LLM-side rule)

Two parts:

**2a. Eligibility gate (if "after multiple X" semantics).** If the user said "only after multiple combat successes", the structural fix is an eligibility clause the LLM must check BEFORE the formula:

```
**Eligibility gate (must apply before the formula):**
- If `success_streak < 2`, the <X> System is INELIGIBLE this turn.
  Do not roll, do not emit `state_updates.<X>`, do not narrate <X>.
- Only when `success_streak >= 2` does the probability formula below apply.
```

Add a worked example for the gate:
```
- streak 1, roll 15 → ineligible (streak < 2)
```

**2b. Cadence change (if "only once per period" semantics).** If the user said "only once per day" / "not per turn", edit the trigger comment in the file header AND the cadence paragraph:

```diff
- <!-- TRIGGER: This instruction activates every 3 turns or 24 hours of game time -->
+ <!-- TRIGGER: This instruction activates every 24 hours of game time ONLY -->
```

```diff
- **Standard Cadence:** Living world fires every 3 turns or 24 hours of game time
+ **Standard Cadence:** Living world fires every 24 hours of game time only
+ **The every-3-turns trigger has been removed.**
```

**2c. New required field (if "tag the tone / type" semantics).** If the user said "I want neutral or positive too" / "tag the tone", add a new `tone` field to the canonical state delta with an enum + default + server-override rule:

```diff
 "world_events": {
   "background_events": [
     {
       "type": "rival_advancement",
+      "tone": "antagonist",  // positive | neutral | mixed | antagonist
       ...
     }
   ]
 }
```

**Pitfall: don't edit only one of the two prompt files.** The contract test at `mvp_site/tests/test_unforeseen_complication_prompt_rules.py:143-182` (test_living_world_prompt_states_same_threshold_arithmetic) pins that the two copies must stay in sync. If you only edit `narrative_system_instruction.md`, the LLM loads `living_world_instruction.md` on LW turns and uses the old formula. Always grep both.

### Step 3 — Extend the cooldown helper (server-side enforcement)

`mvp_site/living_world_contract.py:30-44` already has `is_cooldown_turn()` as the canonical pattern. For per-event cooldowns (e.g. "one antagonist per 14 days"), follow the same shape:

```python
ANTAGONIST_COOLDOWN_DAYS = 14  # canonical constant

def is_antagonist_cooldown_active(
    world_event_log: list[dict],
    current_game_day: int,
) -> bool:
    """True when an antagonist-coded event fired in the last 14 in-world days.

    Scans world_event_log[] (most recent first) for the last entry with
    tone == 'antagonist'. If current_game_day - last_antagonist_day < 14,
    return True (new antagonist events should be stripped).
    """
    for event in reversed(world_event_log or []):
        if event.get("tone") == "antagonist":
            return current_game_day - event.get("game_day", current_game_day) < ANTAGONIST_COOLDOWN_DAYS
    return False
```

**Pitfall: don't invent a parallel `validator.py` module.** Operator preference (2026-08-19, locked): "refactor/reuse the existing faction management code... use the existing FACTION_TOOLS / DICE_ROLL_TOOLS pattern. We should reuse/refactor that." Extend `living_world_contract.py`, don't create `mvp_site/cooldown_validator.py` or similar.

### Step 4 — Wire enforcement into BOTH write paths

The two canonical write paths are `mvp_site/world_logic.py` (non-streaming) and `mvp_site/llm_parser.py` (streaming). The streaming path is the production primary per `AGENTS.md` ("Streaming is the primary production path; LLM-behavior evidence must exercise it"). Both must enforce:

```python
# In world_logic.py and llm_parser.py, after parsing state_updates, before commit:
events = state_updates.get("world_events", {}).get("background_events", [])
filtered = []
for event in events:
    if (event.get("tone") == "antagonist"
            and is_antagonist_cooldown_active(world_event_log, current_game_day)):
        logging_util.warning("WA_LW_ANTAGONIST_COOLDOWN_BLOCKED", event=event)
        continue  # strip the event, don't write it
    if "tone" not in event:
        event["tone"] = "neutral"  # server is authoritative on missing tags
    filtered.append(event)
state_updates["world_events"]["background_events"] = filtered
```

**Pitfall: only wire one path.** Verified failure mode — a worker wires `llm_parser.py` only, the non-streaming code path silently writes antagonist events because the cooldown isn't enforced there. The test will pass on streaming-only fixtures.

**Pitfall: don't add a regex blocklist of "antagonist words"** to detect tone. The user said "I want neutral or positive too" — that's a typed-field request, not a semantic-classification request. Regex blocklists false-positive on "dark alley" / "ominous storm" / "rival's warning" and false-negative on "the merchant's men surrounded the warehouse" (clearly antagonist). Use the typed `tone` field; let the LLM fill it.

### Step 5 — TDD with the new contract tests

Three tests minimum, run BEFORE writing the patch (they should fail):

```python
# In test_unforeseen_complication_prompt_rules.py (extend)
def test_narrative_prompt_requires_streak_gate_at_least_2():
    content = _load("narrative_system_instruction.md")
    assert "success_streak < 2" in content or "streak < 2" in content, \
        "Unforeseen Complication System must add eligibility gate: streak<2 = ineligible"

# In test_living_world_tone_cooldown.py (NEW file)
def test_world_logic_rejects_antagonist_event_within_14d_cooldown():
    # when world_event_log has antagonist entry 5 days ago, new antagonist event stripped
    ...

def test_living_world_turn_only_fires_when_24h_elapsed():
    # is_living_world_turn_eligible returns False when last_lw_turn was 12h ago
    ...
```

Run `./run_tests.sh test_unforeseen_complication_prompt_rules test_living_world_tone_cooldown test_living_world_contract test_world_logic test_streaming_contract_integration` — all 5 must be green.

## Files in scope (typical mechanic rebalance)

≤7 files, ≤230 LOC total. Anything larger is a re-architecture, not a rebalance.

| File | Change | LOC |
|---|---|---:|
| `mvp_site/prompts/<surface>.md` (one or two) | Eligibility gate + worked example, OR cadence change, OR new field | +12 to +35 |
| `mvp_site/living_world_contract.py` | New cooldown constant + helper | +25 |
| `mvp_site/world_logic.py` + `mvp_site/llm_parser.py` | Write-path enforcement (both paths) | +30 total |
| `mvp_site/tests/test_<feature>_*.py` (extend or new) | TDD contract tests | +90 to +120 |
| `mvp_site/tests/fixtures/wa_<feature>_query.sql` (NEW, if BQ-backed) | Reproducible audit query for the PR body | +50 |

## Verified worked example (2026-08-21, PR `feat/uc-streak-gate-lw-tone-24h-cd14`)

Three coupled changes from one user message ("I want fewer UC + LW once per day + one antagonist every two weeks"):

1. **UC streak≥2 eligibility gate** in `narrative_system_instruction.md:279` and `living_world_instruction.md:377` — mirrored per the existing contract test.
2. **LW cadence 24h-only** in `living_world_instruction.md:3` (header comment) and `:1077-1080` (cadence paragraph). Removed the "every 3 turns" trigger.
3. **Antagonist 14d cooldown + `tone` field** — new `tone: positive|neutral|mixed|antagonist` on every `world_events.background_events[]`, server-enforced via `is_antagonist_cooldown_active()` extending `is_cooldown_turn()`.

**Predicted impact** (with BQ-backed numbers in the PR body):
- UC: ~50% cut (streak=0/1 now ineligible, was the bulk of fires)
- LW: ~50% cut (24h-only, no more every-3-turns spam)
- Antagonist: ~95% cut (14d cooldown limits to ≤1 in any 14-day window)

**Net:** overall LW/UC volume down ~75%, antagonist-coded events down ~97%.

## Anti-patterns

- **Don't prompt-only rebalance.** Verified drift: prompt-only thresholds drift back to the old value within 10-20 turns because the LLM context decays. The structural fix is server-enforced.
- **Don't server-only rebalance.** A cooldown the LLM never sees is opaque — the LLM keeps trying to emit and getting silently dropped, with no error to learn from. Pair server enforcement with a contract test that fails when the prompt rule is missing.
- **Don't edit only one of the two prompt copies.** The contract test pins them in sync. Always `grep -n "Complication System" mvp_site/prompts/` to find both.
- **Don't add a new "validator" module.** Operator preference: extend `living_world_contract.py`. See `wa-prompt-engineering/SKILL.md` §"Server-computed candidate scope prevents LLM invention" for the pattern.
- **Don't wire only the streaming path.** Always wire both `world_logic.py` AND `llm_parser.py` (the canonical pattern, not the agent-specific paths).
- **Don't bundle a BQ audit with a rebalance PR without saving the SQL.** Save the query at `mvp_site/tests/fixtures/wa_<feature>_query.sql` so future agents can reproduce the numbers from the PR body.

## Cross-references

- `references/wa-prompt-bq-audit-recipe.md` — the BQ audit recipe (3 forced steps for the data gathering half of this pattern)
- `references/wa-four-category-prompt-framework.md` — DECLARATION / HANDLER / OPT-IN / NOT DECLARED classification; rebalance edits usually add HANDLER rules
- `mvp_site/agent_prompts.py:807-853` — the `{{PROMPT_INCLUDE:...}}` resolver; rebalance edits should respect the include chain
- `mvp_site/living_world_contract.py:30-44` — `is_cooldown_turn()`, the canonical cooldown pattern to extend
- `mvp_site/prompts/AGENTS.md` Hard rules 1-9 — must be respected (no version history, no meta-commentary, no editorializing, no campaign-specific hardcoding)
