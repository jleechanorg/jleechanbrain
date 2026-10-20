---
name: wa-planning-block-choice-contracts
description: "Add or audit server-injected planning_block choices."
tags: [worldarchitect, planning-block, choices, server-injected, contract, tdd, modal-gate, world_logic]
---

# Server-side planning_block.choices guarantees

The WA planning block has THREE layers that all produce choices. Any "always present" / "always last" contract must update ALL relevant layers.

1. **Injection layer** — `mvp_site/llm_parser.py`
   - `_ensure_continue_story_choice()` — appends `continue_story` (id `continue_story`)
   - `_ensure_four_layer_last_choice()` — appends `/4layer` (id `4layer`)
   - `_build_custom_action_planning_block()` — fallback when LLM returns no actionable choices; emits `[continue_story, __custom_action__, 4layer]`
   - `_ensure_custom_action_planning_block()` — pipes an LLM-supplied block through both helpers before falling through to the canonical fallback; canonical entry point for the streaming path
   - Server-injected choices like `enable_spicy_mode` / `disable_spicy_mode` (`_inject_spicy_mode_choice_if_needed`) and modal-finish pairs (`finish_level_up_return_to_game`, `finish_character_creation_start_game`) follow the same shape

2. **Reorder layer** — `mvp_site/world_logic.py inject_modal_finish_choice_if_needed`
   - Categorizes each choice as: `finish_*`, `custom_action` / `__custom_action__`, or "other"
   - Holds finish and custom_action back, re-appends them in deterministic order
   - `reordered_choices.append(finish_choice)` at the end

3. **Frontend render-time fallback** — `mvp_site/frontend_v1/app.js:2554-2669` (`parsePlanningBlocks`)
   - Renders every choice as a `.choice-button`. If the backend did NOT inject `custom_action` / `__custom_action__`, the frontend appends its own fallback button at line 2663-2668:
     ```js
     <button class="choice-button risk-low custom-action-button"
       data-choice-id="__custom_action__"
       data-choice-text=""
       data-action-behavior="focus"
       data-switch-to-story="false"
       title="Type your own custom decision">Custom Action: decide whatever you want to do</button>
     ```
   - `data-action-behavior="focus"` triggers `handleChoiceClick` (line 2408-2414) which only calls `userInputEl.focus()` — no submit. The button is **semantically a label, not a peer action**, even though it visually sits in the numbered list.
   - **Visual-relocation contract** (verified 2026-08-16 design review, branch `feat/planning-block-custom-action-presentation`): if a UI redesign moves this affordance out of the numbered list (e.g. into a dashed/italic label docked on the input field with a "↓ type below" cue), the change MUST live in this layer — lines 2661-2669 (skip the fallback) plus a new `<label class="custom-action-hint">` rendered next to the `<textarea id="user-input">` (index.html line 363). The data contract is fine; only the render shape needs updating. Do NOT re-shape the backend to compensate.
   - **Suppression gate**: the `renderedCustomAction` flag (line 2581-2583) must keep working — if the backend already injected `custom_action` / `__custom_action__`, the frontend fallback must NOT emit a duplicate. Verified during the C3 redesign.

**Why three layers exist**: the backend guarantees are server-authoritative (the contract); the reorder layer guarantees stable ordering across modal flows; the frontend fallback guarantees the user ALWAYS sees a freeform-action affordance even on a backend that skipped injection (older clients, CDN lag, feature-flagged rollouts). Any of the three can add a `__custom_action__` row; the `renderedCustomAction` flag in layer 3 plus the carve-out in layer 2 must keep them honest.

**THE INVARIANT** (user-stated, 2026-08-06 Slack for `/4layer`): a choice marked as "always last" by the user MUST survive the reorder layer as the literal last choice. This requires a paired carve-out in layers 1 and 2.

## ⚠️ Vocabulary collision: UI `planning_block` vs the `next_companion_arc_turn` cadence

"Planning block" in the WorldArchitect.AI codebase refers to **two distinct things**, and conflating them is a frequent source of confusion (verified 2026-08-18 in a delegated /history+/ms+/wiki-search task on arc/quest/companion-arc framing — both this skill and `living_world_instruction.md` matched the same query, yet they govern unrelated systems).

| Term | What it is | Where it lives | What this skill governs |
|---|---|---|---|
| `planning_block` (UI choice block) | The level-up / character-creation / god-mode modal UI choice list a player clicks at the end of each turn | `mvp_site/llm_parser.py`, `mvp_site/world_logic.py`, `mvp_site/frontend_v1/app.js` parsePlanningBlocks | **THIS SKILL** — server-injected contract choices (`continue_story`, `__custom_action__`, `/4layer`, finish-modal pairs) |
| `next_companion_arc_turn` + `companion_arcs[]` | The cadence counter and per-companion state the server uses to tell the LLM when to introduce / advance a personal quest arc for a traveling companion | `mvp_site/prompts/living_world_instruction.md` "Companion Quest Arcs" section; persisted in `custom_campaign_state`; actively wired in PR #8979 (rest-anchored dialog) | **NOT THIS SKILL** — see the prompt contract, not the choice-injection rules. PR #8979 patches the LivingWorld turn contract, not the UI modal layer. |

**Pitfall (added 2026-08-18):** When a task says "planning block on new goal" or "where does the system plan for a new arc/quest", disambiguate BEFORE reading code. If the goal is a UI modal choice contract, this skill is correct. If the goal is the narrative-layer arc/quest cadence the LLM emits, this skill is wrong — read `mvp_site/prompts/living_world_instruction.md` (Companion Quest Arcs section) and PR #8979 / sibling sidekick state files instead. Mixing them leads to writes against `mvp_site/llm_parser.py` for a problem that lives in `mvp_site/prompts/living_world_instruction.md`.

**Anti-trigger (clarification question to post):** "Are you asking about the **UI planning_block** (the choice menu the player sees — Continue Story / Custom Action / etc.) or the **companion-arc planning step** (where the server tells the LLM to introduce a personal quest for a companion)? They live in different layers and need different fixes."

## Cross-reference — four-category classification for narrative-layer prompt fixes

When a user reports "the LLM doesn't follow prompt-declared arc/quest rules even though some exist" (the symptom that produced this skill's vocabulary-collision pitfall in the first place), the right next move is to inventory the prompt surface and classify each match into one of:

1. **DECLARATION** — prompt rule with no server enforcement beyond `state_updates.<field>` example (LLM is the sole authority)
2. **HANDLER** — server injects a reminder, formatter, schema validator, or `build_*_reminder()` call
3. **OPT-IN** — a `planning_block.choices` entry the LLM must include (e.g. `level_up_review`)
4. **NOT DECLARED** — referenced but no rule tells the LLM what to do

The recurring false-green class is that an LLM-facing rule exists but is **DECLARATION-only** (no server enforcement), or that the concept is **NOT DECLARED AT ALL** and the user assumed it was. For the full inventory of every arc / quest / companion-arc prompt site across `mvp_site/prompts/`, `agent_prompts.py`, `narrative_response_schema.py`, see `references/wa-arc-quest-companion-prompt-surface-inventory.md` — 47 files, 8-item gap list, with patch-recipe for each gap (most fixes are multi-layer: prompt + schema + handler must move together).

Key asymmetries surfaced by the inventory (verified 2026-08-18):

| Field | Enum? | Where |
|---|---|---|
| `companion_arcs.<name>.phase` | ✅ enum-locked against `constants.COMPANION_ARC_PHASES` (`discovery`, `development`, `crisis`, `resolution`) | `game_state_mixins.py:1157-1159`, `constants.py:1624` |
| `arc_milestones.<arc_name>.phase` | ❌ free-form `str` — `narrative_response_schema.py:759` declares `"phase": str` with no enum | `narrative_response_schema.py:759` |
| `arc_milestones.<arc_name>.status` | ✅ enum-locked against `VALID_ARC_MILESTONE_STATUS = {"in_progress", "completed"}` | `narrative_response_schema.py:755` |

If a 3-act / 5-act scaffold is added, all three layers must move: prompt worked-example + `ARC_MILESTONE_SCHEMA.phase` enum extension + `_validate_arc_milestones` enum check. Prompt-only enum guidance will silently accept invented strings.

Other gaps (full list in the reference file):
- No persistent quest log prompt (only `deferred_rewards_instruction.md:53-56` reads `active_quests`)
- No "new goal introduced" detection rule (goal evolution is reactive-only)
- No `planning_block.choices` opt-in for new arc/quest (only `level_up_review` exists as the template)
- Companion-arc enforcement is by LW-trigger-only dynamic-channel reminder (`agent_prompts.py:2701-2790` + `injection/living_world_companion_cadence.md`) — non-LW turns have no mirror

## When to Use

Use this skill when:

- Adding a new "always-present" planning_block choice (continue_*, finish_*, custom_action, /4layer, debug-helpers)
- Modifying an existing server-injected choice contract
- Auditing "is choice X actually last/present in the SSE done payload" claims
- Diagnosing "the LLM forgot to emit choice X" or "the modal loses the choice" reports

Do NOT use this skill for:

- LLM-prompted choice addition (model owns it; see `llm-narration-format-clarifier`)
- Schema field changes to choice dicts (different file shape — see `level-up-planning-block-stale` for stale-choice scrubbing)
- Backend data-model changes that don't change the inventory of choices (e.g. adding a `pros` field — that's a schema change, not a contract change)
- Frontend-only UI ordering changes inside the .choice-button list (e.g. sort the buttons by risk_level — that's pure CSS/JS, not a contract)
- Adding brand-new action types (different layer — see `dispatch-task` / workflow skills)

- **Mobile layout bugs where a tap on a choice row (chevron) appears to "collapse" or "shrink" the choices panel** — see "Two-layer disclosure coordination pitfall" below

DO use this skill for layer 3 (frontend render-time fallback) changes — especially visual relocations of the `__custom_action__` fallback that need to keep the suppression gate and modal-skip behavior intact. The data contract is the contract; the render location is implementation detail.

## ⚠️ Two-layer disclosure coordination pitfall (added 2026-08-19, video ${HOME}/.smartclaw/cache/videos/video_2031326c1b8e.mp4, Slack C0BDEAJH8PK/p1787125293.103429)

The composer has TWO independent disclosure layers that the user perceives as one:

| Layer | What it toggles | Where |
|---|---|---|
| **Outer (peek-strip)** | Whole `.composer-choices` show/hide via `.is-collapsed` | `#composer-choices-peek` click → `setComposerChoicesCollapsed()` (`app.js:2572`) |
| **Inner (per-row chevron)** | Single `.choice-row` Pros/Cons expand via `.open` → `.choice-detail { display: block }` | `.chev-btn` click → `toggleChoiceDetail()` (`app.js:2414`) |

**The bug:** when a row's chevron is tapped on mobile, the row's `.choice-detail` block grows inside `.composer-choices`. But `.composer-choices` is capped at **`max-height: 148px; overflow-y: auto`** on phones (`planning-blocks.css:621-627`). The cap does NOT re-grow when one row inside grows taller — `snapComposerChoicesToRow()` (`app.js:2636-2669`) only fires on row-count changes via the `ResizeObserver`, not on `.open` state toggles. Result: the expanded detail visually overflows the scroll container, **overlapping the Debug Info disclosure and the input row above** that the user perceives as "the choices panel shrinking/collapsing."

**Why prior mobile fixes (`17787ce40`, `6d1a063`, `42e8a9c8`) missed it:** they added the cap, fixed mid-row clip counting, and added the peek-strip — but NONE of them wired the chevron toggle to re-snap the cap.

**Diagnostic recipe (verified):**
1. Extract frames from the user's video at ~2 fps with ffmpeg: `ffmpeg -i <video.mp4> -vf "fps=2" frame_%03d.png` (see `references/video-frame-extraction-recipe.md` for full workflow)
2. Read frames at the transition points (chevron tap = 1-2 frame change). Look at whether expanded `.choice-detail` content extends past the scroll container's clip boundary.
3. Confirm in DOM: `app.js:2414-2422` `toggleChoiceDetail()` only toggles `.open` + `aria-expanded`. No call to `snapComposerChoicesToRow()` or unset of `host.style.maxHeight`.
4. Confirm in CSS: `planning-blocks.css:621-627` mobile media query has hard cap with no `.composer-choices:has(.choice-row.open)` escape hatch.

**Fix shape (~30 LOC, 3 files):**
- `app.js:2414-2422` — `toggleChoiceDetail` calls `snapComposerChoicesToRow()` after `classList.toggle`; peek-strip indicator text recomputes based on `host.querySelectorAll('.choice-row.open').length` (when any row is open: "Tap to expand all"; else: "Tap to collapse")
- `planning-blocks.css:621-627` — optional escape hatch: `.composer-choices:has(.choice-row.open) { max-height: none; }` (the JS snap is the spec'd fix; CSS escape hatch is a fallback)
- `mvp_site/tests/test_planning_block_chevron_expand_grow.py` — contract: after `toggleChoiceDetail` on a row, `.composer-choices` `scrollHeight <= clientHeight` for the (re-snapped) cap

**Why copy/state mismatches:** peek-strip copy says "Tap to collapse" while a row is in `.open` state — the two layers can disagree on what state the composer is in. The dynamic indicator fix removes the misleading copy but does NOT fix the overlap; both fixes need to ship together.

**Cross-reference:** `references/frontend-render-fallback-layer3.md` covers the broader "frontend fallbacks must mirror backend state" pattern. This pitfall is the specific mobile-layout instance where two frontend disclosure layers fail to coordinate.

## The 5-step recipe (TDD)

Verified 2026-08-06 in [PR #8803](https://github.com/jleechanorg/worldarchitect.ai/pull/8803) (`feat/planning-block-continue-story`). Use this exact sequence; do NOT skip steps.

### Step 1 — Write the contract tests FIRST (RED)

Create `mvp_site/tests/test_planning_block_<feature>_contract.py` with at minimum:

```python
# Minimal RED skeleton — adapt for the specific contract.
from mvp_site import llm_parser

def test_<helper>_injects_choice_when_block_empty():
    block = {}
    out = llm_parser._<helper>(block, game_state_dict={})
    assert any(c.get("id") == "<id>" for c in out.get("choices", []))

def test_<helper>_is_last_when_user_stated_invariant():
    block = {"choices": [{"id": "a"}, {"id": "b"}]}
    out = llm_parser._<helper>(block, game_state_dict={})
    ids = [c["id"] for c in out.get("choices", []) if isinstance(c, dict)]
    assert ids[-1] == "<id>", f"last must be <id>, got {ids}"

def test_<helper>_skipped_when_modal_active():
    gs = {"custom_campaign_state": {"level_up_in_progress": True}}
    block = {"choices": [{"id": "a"}]}
    out = llm_parser._<helper>(block, game_state_dict=gs)
    ids = [c["id"] for c in out.get("choices", []) if isinstance(c, dict)]
    assert "<id>" not in ids, "modal owns planning_block; no server injection"

def test_<helper>_no_duplicate_when_already_present():
    block = {"choices": [{"id": "<id>"}]}
    out = llm_parser._<helper>(block, game_state_dict={})
    ids = [c["id"] for c in out.get("choices", []) if isinstance(c, dict)]
    assert ids.count("<id>") == 1
```

Run with the project venv:

```bash
cd ${HOME}/worldarchitect.ai && \
  ./venv/bin/python -m pytest mvp_site/tests/test_planning_block_<feature>_contract.py --tb=short
```

**RED confirmation**: tests fail with `AttributeError: module 'mvp_site.llm_parser' has no attribute '_<helper>'`. If they fail with anything else (typo, missing fixture, wrong shape), the test is wrong; fix the test, not the implementation.

**Completion criterion**: every contract test fails with the AttributeError pattern above. If a test passes immediately, you're testing existing behavior — fix the test.

### Step 2 — Implement the helper in `mvp_site/llm_parser.py`

Mirror the existing shape:

```python
# 1) Add a constant near _CONTINUE_STORY_CHOICE (line ~82-96 of llm_parser.py):
_<NEW>_CHOICE_ID = "<id>"
_<NEW>_CHOICE = {
    "id": _<NEW>_CHOICE_ID,
    "text": "<human-readable label>",
    "description": "<what the choice does>",
    "risk_level": "safe",
}

# 2) Add a modal gate helper (only if you don't already have _planning_block_owns_modal):
def _planning_block_owns_modal(game_state_dict):
    """Return True when a level-up, character-creation, or god-mode modal owns the planning block.
    Modal ownership means the player is mid-ceremony; injecting extra choices would corrupt
    the modal flow (PR #8489 regression class)."""
    # ... detect via custom_campaign_state.level_up_in_progress /
    #     level_up_pending / character_creation_active / god_mode_active +
    #     level_up_session.status in {pending, in_progress}

# 3) Add the injection helper:
def _<helper>(planning_block, *, game_state_dict):
    """Server-side guarantee that <the choice> is always present in non-modal planning blocks."""
    if not isinstance(planning_block, dict):
        return planning_block
    if _planning_block_owns_modal(game_state_dict):
        return planning_block
    choices = planning_block.get("choices")
    # ... normalize legacy dict-shape to list
    # ... skip if already present (no duplicate)
    # ... if "always last" invariant: insert before existing trailing <id>, else append
    return planning_block

# 4) Wire it into _ensure_custom_action_planning_block and/or
#    _build_custom_action_planning_block (the canonical entry points for the streaming path).
```

**Completion criterion**: all Step 1 contract tests pass.

### Step 3 — Run GREEN + adjacent regression suite

```bash
cd ${HOME}/worldarchitect.ai && \
  ./venv/bin/python -m pytest \
    mvp_site/tests/test_planning_block_<feature>_contract.py \
    mvp_site/tests/test_server_generated_scope.py \
    mvp_site/tests/test_streaming_orchestrator.py \
    mvp_site/tests/test_world_logic.py \
    mvp_site/tests/test_rewards_engine.py \
    mvp_site/tests/test_rewards_engine_wiring.py \
    mvp_site/tests/test_planning_block_robustness.py \
    mvp_site/tests/test_planning_block_choices_format.py \
    mvp_site/tests/test_planning_block_streaming_passthrough.py \
    mvp_site/tests/test_planning_block_analysis.py \
    mvp_site/tests/test_planning_block_normalization.py \
    mvp_site/tests/test_planning_blocks_ui.py \
    --tb=short -q
```

Expected: ~1000+ tests pass with zero new failures.

**Completion criterion**: all listed test files pass; failure count is zero or unchanged from `origin/main` baseline.

### Step 4 — The reorder-layer carve-out (the part agents miss)

`world_logic.inject_modal_finish_choice_if_needed` at `mvp_site/world_logic.py:~4501` REORDERS the choices list. Even if your helper correctly appends the choice as last, the reorder layer can shuffle it elsewhere.

**Symptom**: your helper-level contract test passes (Step 1 test 2), but the end-to-end test in `test_streaming_orchestrator.py` or `test_world_logic_modal_coverage.py` fails with the choice at position [1] instead of last. Diagnose by running the failing test in isolation:

```bash
cd ${HOME}/worldarchitect.ai && \
  ./venv/bin/python -m pytest \
    mvp_site/tests/<failing-test-file>::<failing-test-method> \
    --tb=long -q 2>&1 | tail -30
```

**Fix shape** — mirror the existing `custom_action` / `finish_*` carve-outs in the iteration loop:

```python
# mvp_site/world_logic.py:4780 — in the for-loop that categorizes choices
for existing in choices if isinstance(choices, list) else []:
    if not isinstance(existing, dict):
        continue
    choice_id = existing.get("id")
    if finish_key and choice_id == finish_key:
        if existing_finish_choice is None:
            existing_finish_choice = dict(existing)
        continue
    if mode_label != "level_up" and choice_id in ("custom_action", "__custom_action__"):
        if existing_custom_action is None:
            existing_custom_action = dict(existing)
        continue
    # NEW carve-out:
    if choice_id == "<NEW>":
        if existing_<NEW> is None:
            existing_<NEW> = dict(existing)
        continue
    reordered_choices.append(existing)

# mvp_site/world_logic.py:4838 — after the finish_choice append, re-append the carved-out choices:
if existing_<NEW> is not None:
    reordered_choices.append(existing_<NEW>)
```

Don't forget to declare `existing_<NEW> = None` near the top of the function alongside `existing_finish_choice` / `existing_custom_action`.

**Completion criterion**: the end-to-end streaming test passes; the choice appears at the literal last index in the SSE done payload.

### Step 5 — Same-name pre-existing check (BEFORE claiming a regression)

For any test that fails in the broader sweep, run the same test on `origin/main` HEAD BEFORE assuming you caused it:

```bash
cd /tmp  # or any fresh worktree
git worktree add /tmp/wa-baseline jleechanorg/worldarchitect.ai --detach origin/main
cd /tmp/wa-baseline
./venv/bin/python -m pytest \
  mvp_site/tests/<failing-test-file>::<failing-test-method> \
  --tb=short -q
```

If the same failure reproduces on `origin/main` with no changes from your branch, it is **pre-existing** — NOT a regression you introduced. Document it in the PR body as such; do not block on it. This is the same-name rule from `qa-test-failure-dismissal-anti-pattern` applied to WA planning-block work.

Verified example: 2026-08-06 PR #8803 — `test_active_level_up_choices_are_not_renamed_or_reordered` fails identically on `origin/main` (no changes from PR #8803); documented in the PR body as pre-existing, not blocking.

**Completion criterion**: every failure in the wider sweep is either (a) caused by this PR and fixed, or (b) verified pre-existing on `origin/main` via same-name reproduction and documented in the PR body.

## Reference

- `references/continue-story-and-4layer-contract.md` — full worked example from [PR #8803](https://github.com/jleechanorg/worldarchitect.ai/pull/8803): 11 contract tests, modal-skip matrix, the dual-layer carve-out, and the exact pre-existing-failure audit log.
- `references/wa-arc-quest-companion-prompt-surface-inventory.md` — four-category (DECLARATION / HANDLER / OPT-IN / NOT DECLARED) classification of every arc / quest / companion-arc prompt site across 47 files; 8-item gap list with patch-recipe per gap (most are multi-layer). Use this skill's vocabulary-collision pitfall as the trigger to load this inventory.
- `references/frontend-render-fallback-layer3.md` — covers the "frontend render-time fallback vs backend guarantee" coordination pattern; load when designing or auditing `app.js` layer-3 fallbacks that must mirror backend state. Cross-referenced from the two-layer disclosure coordination pitfall.
- `references/video-frame-extraction-recipe.md` — verified ffmpeg + vision_analyze workflow for inspecting user-attached videos when the bug is visual (mobile UI layout, animations, scroll behavior). Cross-referenced from the two-layer disclosure coordination pitfall diagnostic step 1.

## Audit-first trigger pattern (added 2026-08-18)

When the user reports *"the LLM doesn't follow [arc/quest/scaffolding] rules"* or *"the system declared X but it's not happening in real runs"* — the failure mode is **prompt surface mismatch**: either the rule exists but the LLM ignores it, or the concept isn't actually declared and the user assumed it was. **Do not propose a fix without first auditing the prompt surface** in three parallel lanes:

1. **Population identification** — which real campaigns have actually run this rule? Use BQ (`worldarchitecture-ai.llm_forensics.llm_payloads`) FIRST; fall back to Firestore via `wa-prod-data-query`. Filter to user-relevant rows; count by owner (test/farm vs jeffrey vs other_user). Capture literal parenthetical campaign titles — they are the user's own diagnostic ("forgot tybolt", "think ignored", "off track").
2. **Prompt surface inventory** — `grep -rn -iE "<concept>|<related-concept>"` across `mvp_site/prompts/`, `agent_prompts.py`, `narrative_response_schema.py`, `structured_fields_utils.py`. Classify each match into DECLARATION / HANDLER / OPT-IN / NOT DECLARED with file:line anchors.
3. **Prior art / past proposals** — `/history` (session_search) + `/ms` (memory-search 9-store fan-out) + `/wiki-search` for prior framework attempts, related PRs, sanctioned patterns. Surface both WIP proposals and prior fixes that were reverted.

Run all three lanes in parallel via `delegate_task` (3 leaf subagents). Aggregated output is the **evidence base** — patch recipes without this evidence are speculative. Outputs land at `/tmp/wa_<concept>_over_<threshold>.{json,md}` for the population, `/tmp/wa_<concept>_prompt_surface.md` for the inventory, `/tmp/wa_<concept>_history_hits.json` for the prior art. The synthesized reply goes to Slack at channel root with TL;DR + evidence tables + patch-shape proposals (each patch ≤200 LOC, one PR each, clean off `origin/main`).

**Skip-audit anti-pattern.** When a user asks for a single feature ("add a planning_block opt-in for new goals") without asking for an audit, this pattern still applies — start with step 2 (prompt inventory for the concept class) so the proposal enumerates ALL existing gaps, not just the one the user named. Otherwise the fix lands, the user tests it, the next gap is exposed, and you rebuild the audit from scratch.

## Anti-patterns

- **Treating `/4layer` / `continue_story` as a UI-only concern.** They are server-side contracts. The model does not need to be told; the server guarantees them.
- **Only patching `llm_parser.py`.** Without the `world_logic.inject_modal_finish_choice_if_needed` carve-out, the streaming pipeline will shuffle your choice out of its invariant position.
- **Only patching layers 1-2 and forgetting layer 3.** The frontend render-time fallback in `app.js:2663-2668` can produce a duplicate OR drop a freeform affordance if the suppression gate (`renderedCustomAction` flag) and modal-skip paths don't agree with the backend. Always assert on the rendered HTML string, not just the data payload.
- **Adding a server-injected choice to a flow the LLM owns.** If the LLM is supposed to decide the choice, change the prompt instead (see `llm-narration-format-clarifier`).
- **Skipping the modal gate.** PR #8489 regression class: injecting `continue_story` into a RewardsAgent's informational-only banner corrupted the modal flow. Every new server-injected choice MUST consult `_planning_block_owns_modal()` (or its equivalent) and skip when a modal is active.
- **Reporting "ready" before adjacent tests are green.** TDD cycle is: helper-level contract tests pass → adjacent test battery green → reorder carve-out applied → same-name pre-existing audit. Do not skip the adjacent battery; that's how the regression-safety claim is earned.
- **Naming the test after the implementation instead of the contract.** `test_ensure_continue_story_choice_injects_when_block_empty` is fine; `test_continue_story_helper_returns_dict` is testing implementation, not behavior.

## Verification Checklist

- [ ] Step 1: contract tests written FIRST and confirmed RED with `AttributeError`
- [ ] Step 2: helper implemented; contract tests GREEN
- [ ] Step 3: adjacent regression suite run with zero NEW failures
- [ ] Step 4: if a positional invariant was claimed ("always last"), reorder-layer carve-out applied and end-to-end test passes
- [ ] Step 5: every remaining failure in the wider sweep verified pre-existing on `origin/main` (same-name rule) or fixed
- [ ] PR body documents the contract change AND any pre-existing failures NOT addressed
- [ ] Commit message includes `CLI/<model>:` provenance tag per `env-preferences.mdc`