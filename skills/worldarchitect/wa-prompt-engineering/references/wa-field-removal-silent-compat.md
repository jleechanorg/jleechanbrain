# Contract field removal with silent-compat — session detail

**Source PR**: [#9150](https://github.com/jleechanorg/worldarchitect.ai/pull/9150) `feat/planning-block-narrative-only`, commit `550b28c270`, 5 files / +156/-38 LOC.

**User directive** (Slack `C0AH3RY3DK6/p1787205681.983699`):
> "Let's remove color coded risks in planning block. Should just be narrative hints and player should decide what to versus quantified risks"

**Dispatch brief**: `users/jleechan/projects/worldarchitect.ai/_wt/feat-planning-block-narrative-only/_task.md` (worker reference, deleted post-merge).

**Trigger phrases for this skill section**:
- "remove [field] from [prompt/choice/payload]"
- "drop [field] from planning block"
- "no more [risk_level / cooldown / quantifier]"
- "stop the LLM emitting [field]"
- "delete [field] from contracts"

## The 4-lane audit findings (from this PR)

### Lane 1 — CSS audit

```bash
grep -rn "risk-low\|risk-medium\|risk-high\|risk-safe" ${HOME}/projects/worldarchitect.ai/mvp_site/frontend_v1/
grep -rn "\.risk-low\|\.risk-medium\|\.risk-high\|\.risk-safe" ${HOME}/projects/worldarchitect.ai/mvp_site/frontend_v1/styles/ ${HOME}/projects/worldarchitect.ai/mvp_site/frontend_v1/themes/
```

**Verdict**: Class was set in JS but NOT styled anywhere. Dead CSS. The "color-coded risk" was not visible production behavior — the class was added to the DOM and ignored. The user was preempting a future styling.

**Lesson**: When the user says "color-coded X", first verify the color is actually rendered. If the class is dead code, the fix is purely structural (DOM emission), not visual.

### Lane 2 — JS audit

```bash
grep -rn "risk" ${HOME}/projects/worldarchitect.ai/mvp_site/frontend_v1/app.js
grep -rn "risk" ${HOME}/projects/worldarchitect.ai/mvp_site/frontend_v1/js/test_planning_block_parsing.js
```

**Found 4 emitters** in `app.js:2978, 3038, 3065, 3093` (1 `riskLevel` local + 2 `riskClass` interpolations + 1 hardcoded `risk-low` fallback).

**Found 4 mirrors** in `test_planning_block_parsing.js:133, 168, 184, 203` (legacy test fixture that ships in the production bundle).

**Lesson**: Always grep the legacy test fixtures alongside the production code. They diverge silently.

### Lane 3 — Prompt audit

```bash
grep -rn "risk_level\|risk-low\|risk-medium\|risk-high" ${HOME}/projects/worldarchitect.ai/mvp_site/prompts/
```

**Found 6 prompt files** with `risk_level`:

| File | Surface | In scope? |
|---|---|---|
| `prompts/planning_protocol.md` | planning block choice | YES |
| `prompts/narrative_system_instruction.md` | schema declaration | YES |
| `prompts/dialog_system_instruction.md` | dialog choices | NO (different surface; user said "planning block") |
| `prompts/game_state_instruction.md` | faction / god-mode actions | NO |
| `prompts/game_state_examples.md` | example state | NO |
| `prompts/multiverse/sovereign_ascension_ceremony.md` | ceremony modal | NO |
| `prompts/faction_management_instruction.md` | faction action | NO |

**Lesson**: User-scoped directive matches one surface. The grep returns many. Stay in scope — `dialog_system_instruction.md`, `faction_management_instruction.md`, etc. are separate decisions.

### Lane 4 — Schema audit

```bash
grep -rn "risk_level" ${HOME}/projects/worldarchitect.ai/mvp_site/narrative_response_schema.py ${HOME}/projects/worldarchitect.ai/mvp_site/schemas/field_constants.py ${HOME}/projects/worldarchitect.ai/mvp_site/constants.py
```

**Verdict**: `risk_level` is `Optional[str]` on the choice dict (no enum tightening). Silent-compat is correct — older payloads still parse; the LLM may still emit; the frontend just doesn't render.

**Lesson**: Don't promote "Optional and free-form" to "removed and rejecting". The first breaks older payloads; the second breaks the LLM's memory of the field. Silent-compat is the right default.

## The 5-step recipe — line counts and timing

| Step | LOC | Time |
|---|---:|---|
| 1. Audit (4 lanes) | local | ~3 min |
| 2. Write dispatch brief | 200-300 LOC | ~5 min |
| 3. Worker: contract test | 50-150 LOC | included in worker time |
| 4. Worker: prompt edits | -24 (planning_protocol) + -5 (narrative_system) | included |
| 5. Worker: JS edits | -13 (app.js) + -9 (test_planning_block_parsing.js) | included |

**Total worker time**: ~10 min for the work itself. PLUS 20 min idle in CI poll loop (Lesson below).

## Lesson — CI poll loop trap

The worker, told to "wait for CI green", ran:
```bash
sleep 60 && gh api ...check-runs ...
sleep 90 && gh api ...check-runs ...
sleep 120 && gh api ...check-runs ...
sleep 180 && gh api ...check-runs ...
sleep 180 && gh api ...check-runs ...
```

7+ iterations, 20+ min idle, killed manually. The work was done at the 10-min mark.

**Dispatcher brief fix**: explicit end-state definition. From the brief that worked:

> **End-state**: Single commit, PR open with green CI, branch pushed to `origin/feat/planning-block-narrative-only`. Report PR URL + green-check evidence.

**Tightened version** (would prevent the trap):

> **End-state**: Single commit, PR open, branch pushed. Worker exits with PR URL as soon as PR is open. Do NOT poll for CI green — that's a babysit job left to the operator. If a status check is needed, the operator runs it.

Capture this lesson in `claude-code-claudem` dispatcher template (separate skill, was not editable this session).

## Tests that passed

```
248 passed, 2 warnings, 13 subtests passed in 5.01s
```

Spread across:
- `mvp_site/tests/test_planning_block_narrative_only_contract.py` (NEW, 143 LOC, 3 tests)
- `mvp_site/tests/test_planning_block_choices_format.py`
- `mvp_site/tests/test_planning_block_robustness.py`
- `mvp_site/tests/test_planning_block_streaming_passthrough.py`
- `mvp_site/tests/test_planning_block_normalization.py`
- `mvp_site/tests/test_planning_blocks_ui.py`

**The 3 contract tests** (template for next time):

1. `test_<file>_prompt_drops_<field>` — read the actual prompt file, assert `<field>` literal substring absent.
2. `test_<schema>_prompt_drops_<field>_in_choice_schema` — same for the schema declaration sentence.
3. `test_<component>_render_emits_no_<field>_class` — exec the render-fn string against a sample dict, assert rendered HTML has no `<field>` class.

## Anti-patterns observed

- **Don't auto-add a CSS neutralizer rule** like `.risk-* { all: initial }`. The class is dead code; deleting the JS emitter is the right fix. Adding a CSS escape hatch leaves the dead class on disk and lets future regressions sneak back in.
- **Don't promote "remove the field" to "remove the field from the schema too"**. The user removed the **contract** (LLM-side); the schema is **storage-side**. Different lifecycles.
- **Don't refactor the field name** (e.g. `risk_level` → `danger_class`). The user wants the field removed, not rebranded.

## Reference for adjacent surfaces

The other 5 prompt files that contain `risk_level` are out of scope for this PR. If the user later asks for symmetric removal:

| File | What to edit |
|---|---|
| `prompts/dialog_system_instruction.md` | Same recipe, scoped to dialog choices (~6 occurrences) |
| `prompts/game_state_instruction.md` | Same recipe, scoped to faction/god-mode actions (~6 occurrences) |
| `prompts/multiverse/sovereign_ascension_ceremony.md` | Same recipe, scoped to ceremony modal (~5 occurrences) |
| `prompts/faction_management_instruction.md` | Same recipe, scoped to faction action (~3 occurrences) |
| `prompts/game_state_examples.md` | Example state; lower priority unless user asks |

Each would be its own PR with its own 4-lane audit + 5-step recipe. Don't bundle them.
