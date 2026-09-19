# Worked example: continue_story + /4layer contract (PR #8803, 2026-08-06)

Session-specific detail for `wa-planning-block-choice-contracts` SKILL.md. Captures the exact code paths, test patterns, and pre-existing-failure audit from the original implementation.

## The user message that triggered this skill

> I think we used to have a planning block choice **continue the story** or something always included? Add it back using TDD and **/4layer should always be the last choice**. Backend python can do this doesn't need LLM.

Ambiguous: `/4layer` could mean (a) the slash command, or (b) a literal last UI choice. **Decision logged:** both interpretations are addressed — the helper guarantees the literal `/4layer` choice is appended as the last element of `planning_block.choices`, AND the work is verified via TDD discipline (test-driven-development skill). If the user only meant (a), the UI piece can be trimmed without invalidating the test harness.

## Files changed (4 files, +585/-12)

| File | Δ | Purpose |
|------|---|---------|
| `mvp_site/llm_parser.py` | +268/-11 | Injection layer: `_FOUR_LAYER_CHOICE`, `_planning_block_owns_modal`, `_ensure_continue_story_choice`, `_ensure_four_layer_last_choice`, rewired `_build_custom_action_planning_block` and `_ensure_custom_action_planning_block` |
| `mvp_site/world_logic.py` | +13/-1 | Reorder layer: `existing_four_layer` carve-out in `inject_modal_finish_choice_if_needed` so `/4layer` survives as last |
| `mvp_site/tests/test_streaming_orchestrator.py` | +19/-7 | Updated 4 existing tests whose pinned 2-element fallback ordering changed to 3-element `[continue_story, __custom_action__, 4layer]` |
| `mvp_site/tests/test_planning_block_continue_story_always.py` | +306/-0 | New contract test file (11 cases) |

## The 11 contract tests (the "always include + always last" gate)

`mvp_site/tests/test_planning_block_continue_story_always.py`:

1. `TestEnsureContinueStoryChoiceHelper.test_injects_continue_story_when_model_returned_no_choices` — bare empty dict → `continue_story` injected.
2. `TestEnsureContinueStoryChoiceHelper.test_appends_continue_story_when_model_returned_its_own_choices` — model emits `[attack_goblin, flee]` → result `[attack_goblin, flee, continue_story]`.
3. `TestEnsureContinueStoryChoiceHelper.test_does_not_duplicate_when_model_already_emitted_continue_story` — model emits `[investigate, continue_story]` → no duplicate; result unchanged.
4. `TestEnsureContinueStoryChoiceHelper.test_handles_choices_dict_shape_legacy` — legacy dict-shape → normalized to list with `continue_story` appended.
5. `TestEnsureFourLayerLastChoiceHelper.test_appends_four_layer_when_no_choices` — empty → `4layer` is last.
6. `TestEnsureFourLayerLastChoiceHelper.test_four_layer_is_last_after_existing_choices` — `[attack_goblin, flee, continue_story]` → `[attack_goblin, flee, continue_story, 4layer]`.
7. `TestEnsureFourLayerLastChoiceHelper.test_does_not_duplicate_when_already_last` — `[investigate, 4layer]` → no duplicate, last still `4layer`.
8. `TestEnsureContinueStoryAndFourLayerSkipModal.test_continue_story_not_injected_when_level_up_modal_active` — `level_up_in_progress=True` → no `continue_story`.
9. `TestEnsureContinueStoryAndFourLayerSkipModal.test_four_layer_not_injected_when_level_up_modal_active` — `level_up_in_progress=True` → no `4layer`.
10. `TestEnsureContinueStoryAndFourLayerSkipModal.test_continue_story_not_injected_during_character_creation` — `character_creation_active=True` → no `continue_story`.
11. `TestIntegrationThroughEnsureCustomActionPlanningBlock.test_ensure_injects_pair_when_no_llm_choices` — full-stack through `_ensure_custom_action_planning_block` → ends with `4layer`.

Plus `TestEnsureCustomActionPlanningBlockBundlesThePair.test_fallback_includes_continue_story_and_4layer` — pins the deterministic fallback order `[continue_story, __custom_action__, 4layer]`.

## The modal gate surface (paste-able snippet)

```python
def _planning_block_owns_modal(game_state_dict):
    if not isinstance(game_state_dict, dict):
        return False
    custom_state = game_state_dict.get("custom_campaign_state")
    if isinstance(custom_state, dict):
        for key in (
            "level_up_in_progress",
            "level_up_pending",
            "character_creation_active",
            "god_mode_active",
        ):
            if custom_state.get(key):
                return True
    level_up_session = game_state_dict.get("level_up_session")
    if isinstance(level_up_session, dict):
        status = str(level_up_session.get("status") or "").strip().lower()
        if status in {"pending", "in_progress"}:
            return True
    return False
```

**Why this surface?** Verified 2026-08-06 against the regression cluster for PR #8489 (phantom `continue_story` in RewardsAgent's informational-only banner). Each detection key is a strong signal by itself; the union covers all observed modal-active paths without needing to enumerate every niche (e.g. `level_up_session.modal_open == true` would have been redundant — covered by the `status` check).

## The world_logic carve-out (paste-able snippet)

```python
# In the for-loop at mvp_site/world_logic.py:~4780:
if choice_id == "4layer":
    if existing_four_layer is None:
        existing_four_layer = dict(existing)
    continue

# At mvp_site/world_logic.py:~4855 (after finish_choice append):
if existing_four_layer is not None:
    reordered_choices.append(existing_four_layer)
```

**Why these two changes are both required** (verified during this session's PR): the iteration loop carve-out prevents `4layer` from being shuffled up by `existing_custom_action`; the final re-append guarantees it lands at index -1. Omitting either one breaks the invariant.

## Pre-existing failure audit (same-name rule applied)

The wider regression sweep caught one failure: `test_world_logic_modal_coverage.py::TestEnforceModalLockLevelUpPaths::test_active_level_up_choices_are_not_renamed_or_reordered`.

Verification recipe (run BEFORE reporting a regression):

```bash
# 1. Reproduce on origin/main baseline
git worktree add /tmp/wa-baseline jleechanorg/worldarchitect.ai --detach origin/main
cd /tmp/wa-baseline
./venv/bin/python -m pytest \
  mvp_site/tests/test_world_logic_modal_coverage.py::TestEnforceModalLockLevelUpPaths::test_active_level_up_choices_are_not_renamed_or_reordered \
  --tb=short -q

# Result: same failure on origin/main with NO changes from PR #8803 → pre-existing.
# Documented in PR #8803 body as pre-existing, not blocking.
```

This is the same-name rule from `qa-test-failure-dismissal-anti-pattern` skill applied to the WA planning-block context. The test expects `result == planning_block` unchanged for a state with `level_up_in_progress=True, level_up_pending=True` but the function re-orders. This is independent of the `continue_story`/`4layer` work and lives on origin/main.

## Regression profile (final counts)

| Test file | Tests run | Pass | Skip/XFail | Fail | Notes |
|-----------|-----------|------|------------|------|-------|
| `test_planning_block_continue_story_always.py` (NEW) | 11 | 11 | 0 | 0 | contract |
| `test_server_generated_scope.py` | 4 | 4 | 0 | 0 | regression |
| `test_world_logic.py` | ~620 | ~620 | 0 | 0 | regression |
| `test_rewards_engine.py` | — | all | 0 | 0 | regression |
| `test_rewards_engine_wiring.py` | — | all | 0 | 0 | regression |
| `test_streaming_orchestrator.py` | 112 | 112 | 9 | 0 | regression (4 updated) |
| `test_streaming_contract_integration.py` | 25 | 25 | 0 | 0 | regression (~2min) |
| `test_planning_block_robustness.py` + `test_planning_block_choices_format.py` + `test_planning_block_streaming_passthrough.py` | — | all | 0 | 0 | regression |
| `test_planning_block_analysis.py` + `test_planning_block_normalization.py` + `test_planning_blocks_ui.py` | — | all | 0 | 0 | regression |
| `test_level_up_lean_v2_5.py` + `_shape_fallback_phantom_finish.py` + `_obvious_prompt.py` + `_god_mode_planning_blocks.py` + `_world_logic_v2_cowrite.py` + `_page_load_*` (3 files) | 65 | 65 | 0 | 0 | regression |
| `test_rewards_ensure_planning_block_no_synthesis.py` + `_planning_block_validation_integration.py` + `_canonical_state_anchor_8444.py` + `_completed_milestone_7373.py` + `_future_leak_7763.py` + `_narrative_response_*` + `_backend_adjustment_registry.py` + `_clear_level_up_lock_flags.py` | 106 | 106 | 2 | 0 | regression |

Total: **1000+ tests pass, 0 new failures, 1 pre-existing failure documented**.

## Open follow-ups (NOT done in this PR)

- `test_active_level_up_choices_are_not_renamed_or_reordered` pre-existing failure should get its own bead (`br create`) and its own fix PR — out of scope here.
- The `_inject_modal_finish_choice_if_needed` function is reaching 480+ lines; if a third "always-last" choice gets added, consider extracting a registration-driven reorder pass. Out of scope here.
- The modal gate surface is duplicated as ad-hoc checks at 4+ call sites (`_enforce_character_creation_modal_lock`, `_level_up_modal_genuinely_active`, `_level_up_active_signal`, etc.). Future refactor could consolidate behind `_planning_block_owns_modal`. Out of scope here.

## Git provenance

- Branch: `feat/planning-block-continue-story` off `origin/main` (SHA `fad9db6e07`)
- Commit: `5d7651d1d8` (claudem/minimax-M3, per `env-preferences.mdc`)
- PR: [#8803](https://github.com/jleechanorg/worldarchitect.ai/pull/8803) (draft, awaiting review)