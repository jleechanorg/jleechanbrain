---
name: stale-planning-block-after-completed-level-up
description: Full Firestore field-level evidence table + cross-campaign cluster mapping + 3-component fix template for the level-up-planning-block-stale sub-class (verified 2026-08-04 on jleechanorg/worldarchitect.ai #8767).
tags: [repro, worldarchitect, level-up, planning-block, stale-state, modal-lock, canonical-state-anchor]
---

# Stale planning_block after completed level-up — full evidence table

Verified 2026-08-04 on [jleechanorg/worldarchitect.ai #8767](https://github.com/jleechanorg/worldarchitect.ai/issues/8767) (campaign `7eKaVrHTWFLIVmcio32D`, dev `mvp-site-app-dev`, bead `rev-8uhc6`).

## Firestore field-level evidence table (direct REST read 2026-08-04 23:46 PT)

Path: `users/vnLp2G3m21PJL6kxcuAqmWSOtm73/campaigns/7eKaVrHTWFLIVmcio32D/game_states/current_state`

| Field path | Value | Implication |
|---|---|---|
| `level_up_session.status` | `"complete"` | ceremony finished |
| `level_up_session.modal_open` | `false` | backend modal lock is OFF |
| `level_up_session.review_open` | `false` | backend review is OFF |
| `level_up_session.from_level` | `3` | was L3→L4 ceremony |
| `level_up_session.to_level` | `4` | was L3→L4 ceremony |
| `level_up_session.target_level` | `4` | matched current_level |
| `level_up_session.current_level` | `4` | post-ceremony |
| `level_up_session.applied` | full Paladin L4 loadout (hp_max=36, attributes STR18/CHA16, Fighting Style Dueling, 9 L1 spells, equipment) | selections committed |
| `level_up_session.offered_choices` | `{}` | empty after ceremony |
| `custom_campaign_state.level_up_in_progress` | `false` | modal guard OFF |
| `custom_campaign_state.level_up_pending` | `false` | modal guard OFF |
| `custom_campaign_state.level_up_complete` | `false` | guard flag is OFF (yet status is complete — guard is stale) |
| `player_character_data.level` | `4` | player is post-level-up |
| `player_character_data.experience.current` | `3366` | XP ledger correct |
| `player_character_data.experience.needed_for_next_level` | `6500` | XP ledger correct |
| `player_character_data.experience.to_next_level` | `3134` | XP ledger correct |
| `planning_block.context` | `"Passing through the Main Gate of Winter-Mourn Keep under the Right of Parley."` | post-level-up scene |
| `planning_block.choices[0].id` | `enter_keep_courtyard` | scene-12 courtyard choice (CURRENT scene) |
| `planning_block.choices[0].text` | `"Cross the Threshold into the Courtyard"` | canonical courtyard choice |
| `planning_block.choices[1].id` | `signal_detachment_hold` | scene-12 courtyard choice (CURRENT scene) |
| `planning_block.choices[1].text` | `"Reiterate Orders to Detachment Before Entering"` | canonical courtyard choice |
| `planning_block.choices[2].id` | `level_up_transition` | STALE — leftover from prior L2→L3 ceremony |
| `planning_block.choices[2].text` | `"Process Level Up (Level 2 -> Level 3)"` | references an OLD level-up that already happened |
| `planning_block.choices[2].freeze_time` | `true` | canonical level-up-modal-envelope signature |
| `planning_block.choices[2].description` | `"Open character advancement menu to select Sacred Oath and Level 3 features before advancing further into the keep."` | L3 features already chosen — STALE |
| `player_turn` | `12` | scene 12 |
| `turn_number` | `12` | scene 12 |
| `last_living_world_turn` | `12` | scene 12 |
| `last_living_world_time` | `{year: 95, month: "Frost-Fall", day: 12, hour: 10, minute: 15, time_of_day: "morning"}` | Frost-Fall day 12, year 95, morning |
| `last_state_update_timestamp` | `2026-08-05T06:43:06.286Z` | most recent state write |

## Cross-campaign cluster mapping

Verified instances on this exact class:
- #8767 — campaign `7eKaVrHTWFLIVmcio32D` (Dragon Knight, dev mvp-site-app-dev)

Suspected-may-match (verify in each by running the 5-step diagnostic):
- #7922 — `level_up_session stuck at 'available' after finish_level_up_return_to_game click` (campaign `kD2x7Qew0p7xEqaAIg2r`). Possibly the same root cause with a different surface symptom — the click landed but the planning_block was already stale, so the user's UI re-rendered the modal.
- #7503 — `stuck-mid-final-review modal blocks new-threshold rewards_box.level_up_available` (Natsumi 2NldINv7kbIseLP7m8vV L2). The `review_open == false` contradiction in the new sub-class is structurally similar to "review_open stuck true"; same code path, opposite flag direction.
- #7609 — `level-up freeform commit not caught by exit classifier` (campaign `NTHkeoR3aAN9GpBanY9i` L1→L2 Cleric Forge Smith). Less likely — freeform is involved.
- #7554 — `level-up freeform commit not caught by exit classifier` (campaign `9VSQ8CbbG8Nc9QORtsSR`). Less likely — freeform is involved.

## Code-path pointers

The completion path in `mvp_site/world_logic.py:finalize_streaming_state_before_persistence` (lines 4888+) does NOT clear-or-replace `planning_block` when `level_up_session.status` transitions to `complete`. The companion `_scrub_stale_level_up_offer_unless_xp_pending` (lines 4823–4885) only scrubs `rewards_pending.level_up_available`, NOT `planning_block.choices`. So the `level_up_transition` choice from the prior turn persists into the next scene's planning_block render.

The frontend's modal-lock detector (per `AGENTS.md` modal-lock patterns) keys off the `level_up_transition` choice id alone, not the server-side `level_up_session.modal_open` flag — which is why the modal UI re-renders despite the backend saying the modal is closed.

Key file paths:
- `mvp_site/world_logic.py:4718-4817` — `inject_modal_finish_choice_if_needed` (the WRONG target for this bug)
- `mvp_site/world_logic.py:4823-4885` — `_scrub_stale_level_up_offer_unless_xp_pending` (only touches rewards_pending, not planning_block)
- `mvp_site/world_logic.py:4888+` — `finalize_streaming_state_before_persistence` (the right target for the fix)
- `mvp_site/main.py:10653+` — `finalize_page_load_story_projection` (the L2 cache path that ALSO needs the scrub)

## 3-component fix template (mirrors prior sibling fix shapes)

Where: `mvp_site/world_logic.py:finalize_streaming_state_before_persistence` (after the `level_up_session.status = "complete"` transition is written).

1. **Add `scrub_stale_level_up_transition_choice()` helper** that filters `planning_block.choices` for any entry with `id == "level_up_transition"` AND `level_up_session.status == "complete"` AND `level_up_session.target_level == level_up_session.current_level` (no pending advance), and removes it.
2. **Mirror the scrub in the L2 cache path** (`mvp_site/main.py` `finalize_page_load_story_projection` around line 10653) so the page-load render path also drops the stale choice before serving the frontend. This is the second-mirror step because the L2 cache may serve a stale planning_block even after the streaming path has been cleaned.
3. **Contract test** in `mvp_site/tests/test_level_up_planning_block_stale_8767.py`:
   - Setup: create a campaign with `level_up_session.status = "complete"` and `planning_block.choices` containing a `level_up_transition` entry.
   - Action: invoke `finalize_streaming_state_before_persistence` (or the L2 path).
   - Assert: `planning_block.choices` contains NO `level_up_transition` choice after the call.
   - Second test: page-load render path also drops the stale choice.

## Test campaign for replay (verified created 2026-08-04 23:46 PT)

- Copy campaign: `YwtUbSQlPY3vrgwacyRw` (test UID `0wf6sCREyLcgynidU5LjyZEfm7D2`, email `jleechantest@gmail.com`, title `Dragon Knight (copy)`)
- 42 story docs + 1 game_states doc copied successfully
- First-touch pre-state on the copy at `users/0wf6sCREyLcgynidU5LjyZEfm7D2/campaigns/YwtUbSQlPY3vrgwacyRw/game_states/current_state` shows the copy is at a different point in the story (planning_block.choices[2].id = `level_up_transition` for L2→L3 from a prior turn that has not been consumed by the test copy yet)

## In-flight fix overlap (verified 2026-08-04)

- OPEN PR [#8177](https://github.com/jleechanorg/worldarchitect.ai/pull/8177) — `fix(world_logic): atomically clear level-up modal lock on level-up completion`. **Direct overlap.** If #8177's scope extends to clearing `planning_block.choices` (not just the lock flags), merging + redeploying to mvp-site-app-dev should close this bug. Verify on the test copy `YwtUbSQlPY3vrgwacyRw`.
- OPEN PR [#8728](https://github.com/jleechanorg/worldarchitect.ai/pull/8728) — `fix(zfc): register _repair_malformed_modal_choices in backend_adjustment_specs` — may cover this if "malformed" includes "stale from prior ceremony".
- OPEN PR [#8729](https://github.com/jleechanorg/worldarchitect.ai/pull/8729) — `refactor(world_logic): remove dead branches in _is_level_up_agent` — may surface this class during cleanup.

## Pitfalls before applying the fix

- **Front-end cache mismatch:** the frontend may cache the planning_block from a prior SSE stream and re-render the stale modal even after the server state is clean. Verify the fix by clearing the frontend cache (or testing on an incognito session) before assuming the server-side scrub is broken.
- **Cross-turn race:** if the LLM emits a new `level_up_transition` choice in the same turn the previous ceremony completes (multi-level-up chain), the scrub would incorrectly remove the new choice. Guard: only scrub if `level_up_session.target_level == level_up_session.current_level` (no pending advance).
- **`rewards_pending.level_up_available` ≠ `planning_block.choices`:** the existing `_scrub_stale_level_up_offer_unless_xp_pending` only touches the rewards_pending field. The new helper must operate on `planning_block.choices` directly — different path, different field.

## Cross-references

- Sibling bug-class taxonomy: `references/npc-status-persistence-bug.md` (the 7-sub-class taxonomy is the model; this is the 8th sub-class under the planning-block anchor family).
- Completion-path code: `mvp_site/world_logic.py:4823-4885` (`_scrub_stale_level_up_offer_unless_xp_pending`) + `mvp_site/world_logic.py:4888+` (`finalize_streaming_state_before_persistence`).
- Verify-then-fix discipline: `references/phenotype-lock-static-evidence.md` (the 3 greps to run BEFORE writing the fix PR; for this class the critical grep is `grep -rin "level_up_transition" mvp_site/prompts/` to confirm the choice id is canonical, not invented).
- Parent skill: `level-up-planning-block-stale` (umbrella SKILL.md with the 5-step diagnostic).
- Verified repro case: [#8767](https://github.com/jleechanorg/worldarchitect.ai/issues/8767) (campaign `7eKaVrHTWFLIVmcio32D`, bead `rev-8uhc6`).
