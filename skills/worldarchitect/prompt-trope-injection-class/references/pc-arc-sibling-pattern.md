# PC Arc Sibling — positive-rule variant of the trope-injection class

**Skill:** `prompt-trope-injection-class` (curator-managed)
**Verified:** 2026-08-18
**Use when:** User asks for a *new* recurring prompt rule (a new arc, mandate, cadence, dialog beat, etc.) — the inverse of the canonical "rule is absent, fix the absence" pattern. The skill's Pitfall 6 ("the section doesn't exist yet, use the three structural pieces but the worked example is *fresh*, not a mirror") covers this case directly.

## Trigger shape (vs. the canonical class)

| | Canonical trope-injection | PC arc variant |
|---|---|---|
| Direction | **Suppress** a forbidden trope | **Add** a recurring rule |
| User phrase | "LLM keeps doing X despite my correction" | "I want X for my character / my campaign" |
| 0-hits grep on | forbidden vocabulary (`supervillain`, `scryer`, …) | existing positive scaffolding (`pc_arcs`, `player_arc`, `protagonist_arc`) |
| Fix shape | Option A (minimal rule in `master_directive.md`) or Option B (declarative schema) | Same Option A/B fork |
| LLM target | Suppress an output pattern | Drive a new output pattern |

The diagnostic recipe is identical except the grep vocabulary changes. Both classes land on the same 4-component durable fix shape (Rule section + Mirror + Test file + CI lint).

## Worked example — PC quest arc (option A path)

**User ask (2026-08-18):** "main character arcs for myself" — the player character (PC).

**Step 1 — Static-evidence grep (the callback, not the trope).**

```bash
cd ${HOME}/projects/worldarchitect.ai
rg -n --no-heading -i \
  'pc_arc|player_arc|character_arc|protagonist_arc' \
  mvp_site/prompts/ mvp_site/agent_prompts.py \
  mvp_site/narrative_response_schema.py
```

Expected: 0 hits. **Confirmed** on 2026-08-18 (full sweep across `mvp_site/prompts/`, `agent_prompts.py`, `narrative_response_schema.py`, `game_state.py`).

**Step 1b — Find the closest analog (skip if the user already knows the shape).**

```bash
# companion_arcs is the only Arc-tracking contract in the codebase.
rg -n --no-heading -B 1 -A 30 'def get_companion_arcs_summary' \
  mvp_site/agent_prompts.py
rg -n --no-heading -A 50 '## Companion Quest Arcs' \
  mvp_site/prompts/living_world_instruction.md
```

Output: 3-layer contract (DECLARATION in `living_world_instruction.md` L920–L1070, SCHEMA in `custom_campaign_state.companion_arcs` from `game_state.py` L2383–L2403, HANDLER in `agent_prompts.py` L2621–L2626).

**Step 2 — Classify the gap.**

| Layer | Companion arc today | PC arc today |
|---|---|---|
| DECLARATION (prompt advances the arc) | `living_world_instruction.md` L920–L1070 — 150 lines of hard rules | **NONE.** No rule to initialize, advance, or callback a PC arc. |
| SCHEMA (where state lives) | `custom_campaign_state.companion_arcs.<name>` (free-form dict, LLM-owned) + `next_companion_arc_turn` counter | No `pc_arcs` or `pc_arc_event` key. |
| HANDLER (server enforces) | `agent_prompts.py` L2621–L2626 injects rendered "Current Companion Arcs" string | Nothing. |

A PC arc needs **all three layers built from scratch**. The companion_arcs contract is the shape to reuse (verbatim where possible — the 8 arc types, 4 phases, 6 event_types are generic enough).

**Step 3 — Apply the 4-component durable fix shape (Option A).**

| Component | Location | Estimated content for PC arc |
|---|---|---|
| Rule section | `living_world_instruction.md` (new "PC Quest Arcs" section, parallel to "Companion Quest Arcs") | ~150 lines: cadence, types, phases, callback rules, anti-patterns. Mirror the companion_arcs structure but keyed to the PC. |
| Mirror | (none — there's no existing PC arc surface to mirror. Pitfall 6 applies: worked example is *fresh*, not a mirror.) | Section is self-contained. |
| Test file | `mvp_site/tests/test_prompts.py` (add `test_pc_arc_*`) | Pin section anchor, eight arc types, four phases, six event_types, the `companion_arcs` anchor (so the contract is mutually exclusive), the hard-prohibition list. |
| CI lint | `scripts/check_pc_arc_prompts.py` | Walk `mvp_site/prompts/` for the section anchor; assert all required JSON shape entries have at least one worked example. |

**Step 4 — The handler (server-side injection).**

`agent_prompts.py` L2621–L2626 inserts a `**Current Companion Arcs:**` block into the system instruction. The PC arc parallel is a `**Current PC Arc:**` block, ~3 lines of code, no schema change. Test in the same PR as the rule-section edit.

**Step 5 — Do NOT add a schema validator.**

The companion_arcs system has no `narrative_response_schema.py` validator today (zero references). If we want server-side validation for PC arcs, we're adding the first arc validator in the codebase — reusing the `ARC_MILESTONE_SCHEMA` validator pattern (`narrative_response_schema.py` L658–672, L1298–1330). **Default to no validation** to match the existing companion_arcs surface; add validation only if a regression-pattern requires it.

**Step 6 — Bundle compression with the addition.**

The prompt surface is 909 KB across 47 files (verified 2026-08-18). Adding ~150 lines for PC arc would add ~7 KB to `living_world_instruction.md`. Net effect on bytes is roughly neutral. The PR should bundle one compression win (the easiest two are item 1 of the compression profile: collapse `mechanics_system_instruction.md` ↔ `mechanics_system_instruction_code_execution.md` into one file with a dice-strategy branch, ~4 KB; or item 5: extract the 3 duplicated `companion_arc_event` JSON examples in `living_world_instruction.md` to `shared/companion_arc_event_example.md`, ~3 KB) so the net PR is byte-negative. **Cache-fragmentation priority:** the biggest win is reducing the number of distinct system-instruction prefixes, not reducing bytes.

## Output filenames for the survey

Session pre-PR1 surveys (the "/tmp" output of the pre-PR1 investigation step) follow this naming:

- `/tmp/wa_pc_arc_survey.md` — gap analysis: existing scaffolding, classification (DECLARATION/SCHEMA/HANDLER), closest analog, brief contrast on shape reuse.
- `/tmp/wa_prompt_compression_profile.md` — profile of the prompt surface: size table, duplication pairs, rule-vs-reference classification, `PROMPT_INCLUDE` inventory, ranked compression opportunities.

Save the survey outputs into `.claude/notes/` per project if the user wants the artifact to land in the repo (not `tmp`).

## Hand-off to the 4-component fix

Once the survey is approved, the actual PR is just the canonical 4-component durable fix shape (Pitfall 6: worked example is fresh, not a mirror) bundled with one compression win. The survey is the input; the durable fix is the output.
