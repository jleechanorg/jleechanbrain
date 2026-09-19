# Four-Category Prompt Surface Framework

**Source:** Refined in `wa-planning-block-choice-contracts/SKILL.md`'s "Cross-reference" section, 2026-08-18. This file is the standalone reference.

Every prompt-site match in `mvp_site/prompts/` falls into exactly one of four categories. Mis-classification is the leading cause of false-green fixes (you patch the prompt, the LLM still ignores, because the rule was DECLARATION-only and the prompt was never the bottleneck).

## The categories

| Category | What it is | How to spot it | The risk |
|---|---|---|---|
| **DECLARATION** | The prompt tells the LLM to emit (or read) some JSON state, and the LLM is the sole authority on whether it happens | A `state_updates.<field>` example with `"MUST"` language; no server-side enforcement in `agent_prompts.py` | If the prompt section is not in the recency window AND no cadence reminder fires on every turn, the LLM ignores it under token-budget pressure |
| **HANDLER** | Server injects a reminder, formatter, or schema enforcement that backs the prompt rule | A method like `build_arc_completion_reminder()` or a `_validate_<thing>()` validator | If the HANDLER's gate fires only on a specific turn type (e.g. `check_living_world_trigger() == True`), the rule applies only on trigger turns |
| **OPT-IN** | A `planning_block.choices` entry the LLM must include | A choice-id in `planning_protocol.md` "Choice ID Naming" or `rewards_system_instruction.md` | If the LLM forgets to include it, no fallback fires unless the server injects it (which is `wa-planning-block-choice-contracts` territory) |
| **NOT DECLARED** | The concept is referenced tangentially or implied but no rule tells the LLM what to do | A `## References` mention, an example, a hint — but no MUST/SHOULD language | The user assumed the engine handled it but no rule exists. Frequent for "newer" concepts (PC arc, sub-arcs) |

## Detection rules

For every match, run this checklist:

1. **Is the LLM required to do anything?**
   - YES with no server enforcement → DECLARATION
   - YES with server enforcement → HANDLER (with prompt side)
   - NO, the prompt mentions but doesn't direct → NOT DECLARED

2. **Is a `state_updates.<field>` example present?**
   - YES with `"MUST"` / `"MUST NOT"` / "**MANDATORY**" markers → DECLARATION (probably the binding contract)
   - YES with no imperative markers → DECLARATION but weak — likely to be invented away under token pressure

3. **Is there a `build_*_reminder()` in `agent_prompts.py`?**
   - YES → HANDLER (check the gate conditional)
   - NO → likely DECLARATION or NOT DECLARED

4. **Is there a `_validate_<thing>()` or schema enum in `narrative_response_schema.py`?**
   - YES with constraint (enum, range) → HANDLER with schema enforcement
   - YES with no constraint (e.g. free-form `str` for `phase`) → schema-validated in name only; treat as DECLARATION

5. **Is it a `planning_block.choices` entry the LLM must emit?**
   - YES → OPT-IN. The 3-layer contract from `wa-planning-block-choice-contracts` applies.

## The decision matrix

When proposing a fix, the gap category dictates the patch surface:

| Gap category | Patch surface | What to add |
|---|---|---|
| DECLARATION-without-HANDLER (LLM forgets under token pressure) | `agent_prompts.py` + new injection file | Add a cadence reminder that fires on every turn (not just triggers) |
| HANDLER-with-too-restrictive-gate (gated to LW-only when it should be every turn) | `agent_prompts.py` | Loosen the gate; mirror the handler into the always-fire channel |
| OPT-IN (LLM owns the choice emission, prompt-only) | `planning_protocol.md` + `narrative_response_schema.py` | Mirror `level_up_review` shape (regex + contract test) OR `wa-planning-block-choice-contracts` server-injected helper |
| NOT DECLARED | New prompt file + handler + schema validator | All three layers must move together. Prompt-only fix does nothing if no handler enforces. |

## Worked example (2026-08-18, Nocturne BG3 campaign)

| Concept | Classification | Why |
|---|---|---|
| `companion_arcs[]` initialization cadence | DECLARATION + HANDLER (gated) | `living_world_instruction.md:920` declares "Turn 3 MUST"; `injection/living_world_companion_cadence.md` is HANDLER but fires on LW trigger turns only |
| `arc_milestones[].phase` enum | HANDLER (weak) | `narrative_response_schema.py:759` declares `"phase": str` with no enum — schema accepts any string, validator never constrains |
| `pc_arcs[]` (player character) | NOT DECLARED | Zero hits across surface. No prompt rule, no handler, no schema field |
| `active_quests[]` | HANDLER (read-side only) | `deferred_rewards_instruction.md:53-56` reads `active_quests` but no prompt tells LLM to write it |
| `level_up_review` | OPT-IN | `planning_protocol.md:27-29` declares the rule; LLM emits a choice with that id; no server fallback |
| `4layer` / `continue_story` | OPT-IN with handler fallback | `wa-planning-block-choice-contracts` covers the server-injected fallback contract |

## When NOT to use this framework

- For UI choice-contract changes (use `wa-planning-block-choice-contracts`)
- For rest-anchored dialog rules (use `wa-prompt-only-sanctuary-dialog-opportunities`)
- For dice-integrity audit work (use `wa-dice-integrity-audit` / `wa-daily-dice-audit-fix`)
- For lore / character-rewrite work (use `wa-scene-rewrite` / `wa-scene-candidate-pick`)
- For frontend test guards (use `wa-frontend-test-guard-scoping`)

This framework is for narrative-layer prompt rules only. It tells you whether the LLM is the bottleneck — if a rule is in DECLARATION form and the LLM is missing it, the fix is structural (recency + cadence) not prompt-volume.
