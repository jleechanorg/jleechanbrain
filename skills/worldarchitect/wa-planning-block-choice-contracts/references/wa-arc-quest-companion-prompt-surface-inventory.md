# WA arc / quest / companion-arc prompt surface inventory (2026-08-18)

**Source:** `/tmp/wa_prompt_arc_surface.md` (944 lines, 54,925 bytes) — produced by a delegated /history+/ms+/wiki-search task on the user-reported symptom *"LLM doesn't follow prompt-declared arc/subarc/quest rules even though some exist"*.

This file is the durable patch-surface map. The full inventory with verbatim excerpts is at `/tmp/wa_prompt_arc_surface.md`; this file is the executive summary + classification index for fast lookup.

## Classification framework (four categories)

Every prompt-site match falls into exactly one of:

| Category | What it is | How to spot it |
|---|---|---|
| **DECLARATION** | The prompt tells the LLM to emit (or read) some JSON state, and the LLM is the only authority on whether it happens | A `state_updates.<field>` example with `"MUST"` language; no server-side enforcement in `agent_prompts.py` |
| **HANDLER** | Server injects a reminder, formatter, or schema enforcement that backs the prompt rule | A method like `build_arc_completion_reminder()` or a `_validate_<thing>()` validator |
| **OPT-IN** | A `planning_block.choices` entry the LLM must include (e.g. `level_up_review`) | A choice-id in `planning_protocol.md` "Choice ID Naming" or `rewards_system_instruction.md` |
| **NOT DECLARED** | The concept is referenced tangentially or implied but no rule tells the LLM what to do | A `## References` mention, an example, a hint — but no MUST/SHOULD language |

## Where each concept lives

| Concept | File / line | Category | Schema? |
|---|---|---|---|
| `primary_arc` (single-key arc milestone) | `game_state_instruction.md:1991-2052` | DECLARATION | ✅ `ARC_MILESTONE_SCHEMA` (`narrative_response_schema.py:750-763`) — but `phase` is FREE-FORM |
| Arc completion reminder (server) | `agent_prompts.py:2676-2699` `build_arc_completion_reminder()` | HANDLER | n/a |
| Arc ops (mark/update/is_completed/get_phase/get_summary) | `game_state_mixins.py:996-1128` | HANDLER | n/a |
| AI-generated mystery + internal-drive plot arcs | `shared/ai_generated_mystery_and_internal_drive_plot_arc.md` (96 lines) | DECLARATION | ❌ full schema in prompt, no validator |
| No-forced-ruler progression (anti-mandate) | `shared/no_forced_ruler_progression.md:1-43` | DECLARATION (negative) | n/a |
| Arc-scale sanctuary table (Medium/Major/Epic) | `living_world_instruction.md:464-472` | HANDLER | n/a |
| Master directive loading hierarchy | `master_directive.md:19-53` | DECLARATION | n/a |
| `quest_offered` scene_event (25% probability) | `living_world_instruction.md:742-819` | DECLARATION + HANDLER | ❌ (no schema) |
| Quest milestone XP grant | `rewards_system_instruction.md:645, 667-675` | HANDLER | n/a |
| `active_quests` reference (read-side only) | `deferred_rewards_instruction.md:53-56` | HANDLER (read) | ❌ no writer prompt |
| Quest completion XP grant | `rewards_system_instruction.md:536-539` | HANDLER | n/a |
| NPC goals/conflicts/betrayal (5-field schema) | `narrative_system_instruction.md:944-973` | DECLARATION | ❌ no schema, no write directive |
| God-mode mission management | `god_mode_instruction.md:73, 80-89` | HANDLER | ❌ no mission schema |
| Faction missions | `faction_management_instruction.md` (14 hits, mostly false positives) | DECLARATION | n/a |
| Companion quest arcs (full system) | `living_world_instruction.md:936-1072` | DECLARATION (strongest single rule) | ✅ enum types + phases in `constants.py:1623-1634` |
| Companion arc cadence injection | `injection/living_world_companion_cadence.md` (full 6 lines) | HANDLER (server-injected dynamic tail) | n/a |
| Companion arc constants | `constants.py:1623-1634` | HANDLER | n/a |
| Companion arc state init | `game_state.py:2649-2669` | HANDLER | n/a |
| Companion arc summary formatter | `game_state_mixins.py:1130-1189` + `agent_prompts.py:2742-2746` | HANDLER | n/a |
| `player_character_data.goals` evolution | `shared/ai_generated_mystery_and_internal_drive_plot_arc.md:85-93` | DECLARATION (reactive) | ❌ |
| Seed mysteries without waiting | `shared/ai_generated_mystery_and_internal_drive_plot_arc.md:50-54` | DECLARATION (autonomous seeding) | ❌ |
| Story arc completion → level grant | `shared/mechanics_leveling_protocol_intro.md:24-28, 62` | HANDLER | n/a |
| `PLANNING_BLOCK_SCHEMA` (canonical) | `narrative_response_schema.py:402-435` | DECLARATION (schema) | n/a (the schema) |
| Choice-id naming + regex | `planning_protocol.md:209-224` | DECLARATION | n/a |
| Combined/parallel choice rule | `planning_protocol.md:144-167` | DECLARATION | n/a |
| `level_up_review` opt-in (only `level_up_`-prefixed allowed) | `planning_protocol.md:27-29` | OPT-IN (the precedent) | n/a |
| `continue_adventure` opt-in | `rewards_system_instruction.md:569-574` | OPT-IN | n/a |
| Sanctuary rules (no lethal ambushes etc.) | `living_world_instruction.md:551-561` | HANDLER (narrative gate) | n/a |
| God-mode request-type discriminator | `god_mode_output_contract.md:51-64` | HANDLER | n/a |
| Story continuation reminder (mandatory planning_block) | `agent_prompts.py:2643-2658` | HANDLER (server reminder) | n/a |

## The 8-item gap list (what's missing for "LLM follows arc/quest rules")

1. **No 3-act / 5-act scaffold prompt** — `primary_arc.phase` is free-form `str` (`narrative_response_schema.py:759`).
2. **No sub-arc concept** — `arc_milestones` is a flat dict keyed by arc_name.
3. **No persistent quest log** — `active_quests` is referenced only in `deferred_rewards_instruction.md` for read-side; no prompt tells the LLM to write it.
4. **No "new goal introduced" detection rule** — goal evolution is purely reactive (see `ai_generated_mystery_and_internal_drive_plot_arc.md:85-93`).
5. **No `planning_block.choices` opt-in for new arc/quest** — only `level_up_review` exists as a template.
6. **Companion-arc enforcement is by dynamic-channel reminder only** — non-LW turns have no obligation injection.
7. **Primary `arc_milestones[].phase` is free-form** — companion `companion_arcs[].phase` is enum-validated; primary is not.
8. **No "arc_complete" handler outside living world** — primary arcs rely on LLM to flip `status: "completed"` without a reminder.

## Patch-recipe hints (per gap)

For each gap, the fix is multi-layer (prompt + schema + handler often). Do NOT skip layers.

- **Gaps 1, 2** (3-act scaffold + sub-arcs): extend `ARC_MILESTONE_SCHEMA` in `narrative_response_schema.py:750-763` to enum-lock `phase` AND add new sub-arc shape; add a worked example to `game_state_instruction.md` § 1991-2052; extend `_validate_arc_milestones` at `narrative_response_schema.py:1505-1536`.
- **Gap 3** (persistent quest log): new prompt section in `living_world_instruction.md` (or new `shared/quest_log_contract.md`); new `active_quests` schema in `narrative_response_schema.py`; optional server-side `mark_quest_progress` in `game_state_mixins.py`.
- **Gap 4** (new-goal detection): new prompt section OR new optional planning_block opt-in; the current G1 rule is reactive-only.
- **Gap 5** (planning_block opt-in for new arc/quest): mirror the `level_up_review` pattern in `planning_protocol.md`; update the choice-id regex; add server-side injection helper in `llm_parser.py` and the carve-out in `world_logic.py:4780` (see `wa-planning-block-choice-contracts` skill for the 5-step recipe).
- **Gap 6** (companion-arc enforcement on non-LW turns): extend `build_living_world_instruction` (`agent_prompts.py:2701-2790`) to mirror the cadence injection more aggressively, OR add a new handler that fires on every turn (not just LW trigger turns).
- **Gap 7** (enum-lock `arc_milestones[].phase`): same as Gap 1 — but only requires schema + validator changes, no prompt change.
- **Gap 8** (arc_complete handler): add `build_arc_completion_reminder` analog for `arc_milestones` (not just completed arcs) that reminds the LLM when `progress=100` is reached but `status` is still `in_progress`.

## Files referenced (master index)

```
PROMPTS:
  mvp_site/prompts/game_state_instruction.md                       (A1, sanctuary)
  mvp_site/prompts/living_world_instruction.md                     (A7, Q1, C1, P6)
  mvp_site/prompts/rewards_system_instruction.md                   (Q2, Q4, P5)
  mvp_site/prompts/deferred_rewards_instruction.md                 (Q3)
  mvp_site/prompts/narrative_system_instruction.md                 (Q5)
  mvp_site/prompts/god_mode_instruction.md                         (Q6)
  mvp_site/prompts/faction_management_instruction.md               (Q7)
  mvp_site/prompts/shared/ai_generated_mystery_and_internal_drive_plot_arc.md   (A5, G1, G2)
  mvp_site/prompts/shared/no_forced_ruler_progression.md           (A6)
  mvp_site/prompts/shared/mechanics_leveling_protocol_intro.md     (G4)
  mvp_site/prompts/shared/mechanics_leveling_rewards_body.md       (G4)
  mvp_site/prompts/planning_protocol.md                            (P2, P3, P4)
  mvp_site/prompts/god_mode_output_contract.md                     (P7)
  mvp_site/prompts/injection/living_world_companion_cadence.md     (C2)
  mvp_site/prompts/narrative_lite_system_instruction.md            (C6)
  mvp_site/prompts/master_directive.md                             (A8)

PYTHON:
  mvp_site/agent_prompts.py                                        (PATH_MAP A8, arc reminder A3, LW injection C2, story reminder P8)
  mvp_site/narrative_response_schema.py                            (A2 schema, PLANNING_BLOCK_SCHEMA P1)
  mvp_site/game_state.py                                           (C4 init)
  mvp_site/game_state_mixins.py                                    (A4 ops, C5 formatter)
  mvp_site/constants.py                                            (C3 enum)
  mvp_site/structured_fields_utils.py                              (NO arc content — not a patch surface)
```
