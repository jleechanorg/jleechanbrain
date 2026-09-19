---
name: level-up-planning-block-stale
description: "Use when a level-up modal is stuck in any of three sub-classes: (a) stale `level_up_transition` choice id surviving in `planning_block.choices` after server-side `status=complete`, (b) mid-final-review block with `review_open=true` after `modal_open=false`, OR (c) rewards engine queued `rewards_pending` but the modal never opened because the entry-trigger chain never advanced `level_up_session.status` from `available` → `in_progress`. Run the 5-step diagnostic BEFORE assuming `_inject_modal_finish_choice_if_needed` — that fix only matches sub-class (a)."
tags: [repro, worldarchitect, level-up, planning-block, stale-state, modal-lock, canonical-state-anchor, choices-stale, entry-trigger, rewards-pending]
changelog:
  - 1.1.0 (2026-08-23) **3rd sub-class — entry-trigger-missing added.** Verified on jleechanorg/worldarchitect.ai #9327 (campaign `29l48q6zFo7chxWnyjEY`, owner jleechan@gmail.com). Distinct from sub-class (a) [#8767] and the prior sibling cluster [#7922, #7503]: the rewards engine wrote `rewards_pending` with full canonical evidence (level_up_available=true, processed=false, source_id=level_up_14_to_15, new_level=15), the narrative-stream wrote "(Lvl 15 available)" status headers for 3+ consecutive scenes, but the chain that should route to LevelUpAgent and inject the `level_up_now` choice never fired. Smoking gun: `level_up_session.source_story_id="unknown"` (literal string) + `planning_block.choices=[]` + `rewards_pending.processed=false` persisting. Distinct from the existing `seal_orphaned_available_session()` helper (which only fires when `pcd_level >= target_level`) — no helper exists for the inverse case. New `references/level-up-entry-trigger-missing.md` documents the 3-source cross-reference diagnostic (Firestore pre-state + story status headers + planning_block.choices), the 3-component durable-fix shape, and the verified live workaround (god-mode admin commit folds onto `level_up_session.apply_level_up` directly). Description frontmatter broadened to fire on all 3 sub-classes; tags extended with `entry-trigger` and `rewards-pending` for taxonomy-aware skill loader routing.
---

# Level-up modal re-renders from stale planning_block (NEW canonical-state-anchor sub-class)

Verified 2026-08-04 on [jleechanorg/worldarchitect.ai #8767](https://github.com/jleechanorg/worldarchitect.ai/issues/8767) (campaign `7eKaVrHTWFLIVmcio32D`, dev `mvp-site-app-dev`).

## The trap

The natural read for "level-up modal won't go away / no Finish button" is the canonical `_inject_modal_finish_choice_if_needed` class — matches the prior sibling cluster (#7922, #7929, #7364, #7503, #7334, #7609, #7554). **That hypothesis is often wrong.** A direct Firestore read usually reveals the level-up is fully completed on the backend; the frontend is rendering a phantom modal from a stale `level_up_transition` choice id that survives in `planning_block.choices` from a prior ceremony.

## 5-step diagnostic (no live LLM turn required)

1. **Direct Firestore REST read** on the canonical game-state document:
   ```bash
   curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
     "https://firestore.googleapis.com/v1/projects/worldarchitecture-ai/databases/(default)/documents/users/<UID>/campaigns/<CID>/game_states/current_state"
   ```
2. **Check `level_up_session`:** `status == "complete"` AND `modal_open == false` AND `applied != {}` → backend says ceremony is done.
3. **Check `custom_campaign_state`:** every `level_up_*` flag is `false` → backend guards are OFF.
4. **Check `planning_block.choices`:** any choice with `id == "level_up_transition"` (or `freeze_time == true`) → STALE.
5. **Check the choice text vs current level:** choice text says "L2 → L3" but `player_character_data.level == 4` → stale by at least one ceremony.

If steps 2–5 all confirm the contradiction, the bug is **stale planning_block**, not finish-injection-missing. Update the issue body and link to PR #8177 for the fix shape — the original `_inject_modal_finish_choice_if_needed` fix is the wrong target.

## Why the canonical sibling classes do NOT match

- Not `finish-injection-missing` (#7922, #8177 cluster) — the modal is closed server-side; no finish choice needs to be injected because no modal lock is active.
- Not `freeform-not-caught` (#7609, #7554) — no freeform input is involved.
- Not `level-up-never-triggers` (#7929) — the level-up DID trigger and DID complete.
- Not `planning_block-missing-level-up-choice` (#7334) — there IS a level-up choice in planning_block; it's just stale.
- Not `modal-stuck-mid-final-review` (#7503) — `review_open == false`.

## Frontend vs backend mismatch

The frontend's modal-lock detector keys off the `level_up_transition` choice id alone, not the server-side `level_up_session.modal_open` flag. The user sees the modal UI despite the backend saying the modal is closed. This is the structural mismatch that hides the bug — the server is consistent and the client is consistent, but they disagree on what "modal open" means.

## Cross-campaign cluster signal

Verified instances on this exact class:
- #8767 — campaign `7eKaVrHTWFLIVmcio32D` (Dragon Knight, dev mvp-site-app-dev)

Suspected-may-match (verify in each):
- #7922 — same campaign cluster (`kD2x7Qew0p7xEqaAIg2r`); the user reported "stuck at 'available' after finish click" — possibly the same root cause with a different surface symptom (the click landed but the planning_block was already stale, so the user's UI re-rendered the modal).
- #7503 — "stuck-mid-final-review modal blocks new-threshold rewards_box.level_up_available" — the `review_open == false` contradiction in the new sub-class is structurally similar to "review_open stuck true"; same code path, opposite flag direction.

## In-flight fix overlap (verified 2026-08-04)

OPEN PR [#8177](https://github.com/jleechanorg/worldarchitect.ai/pull/8177) — `fix(world_logic): atomically clear level-up modal lock on level-up completion`. **Direct overlap.** If PR #8177's scope extends to clearing `planning_block.choices` (not just the lock flags), merging + redeploying to mvp-site-app-dev should close this bug. Verify on the test copy `YwtUbSQlPY3vrgwacyRw` (copy of `7eKaVrHTWFLIVmcio32D` under UID `0wf6sCREyLcgynidU5LjyZEfm7D2`, email `jleechantest@gmail.com`).

OPEN PR [#8728](https://github.com/jleechanorg/worldarchitect.ai/pull/8728) — `fix(zfc): register _repair_malformed_modal_choices in backend_adjustment_specs` — may cover this if "malformed" includes "stale from prior ceremony".

OPEN PR [#8729](https://github.com/jleechanorg/worldarchitect.ai/pull/8729) — `refactor(world_logic): remove dead branches in _is_level_up_agent` — may surface this class during cleanup.

## Durable fix shape (if #8177 scope is incomplete)

Where: `mvp_site/world_logic.py:finalize_streaming_state_before_persistence` (after the `level_up_session.status = "complete"` transition is written).

3-component mirror of the prior sibling fix shapes:
1. **Add `scrub_stale_level_up_transition_choice()` helper** that filters `planning_block.choices` for any entry with `id == "level_up_transition"` AND `level_up_session.status == "complete"`, and removes it.
2. **Mirror the scrub in the L2 cache path** (`mvp_site/main.py` `finalize_page_load_story_projection` around line 10653) so the page-load render path also drops the stale choice before serving the frontend.
3. **Contract test** pinning the scrub: assert `planning_block.choices` contains NO `level_up_transition` choice after `level_up_session.status == "complete"`, AND the test reloads the page through the page-load render path and asserts the same.

## Pitfalls before applying the fix

- **Front-end cache mismatch:** the frontend may cache the planning_block from a prior SSE stream and re-render the stale modal even after the server state is clean. Verify the fix by clearing the frontend cache (or testing on an incognito session) before assuming the server-side scrub is broken.
- **Cross-turn race:** if the LLM emits a new `level_up_transition` choice in the same turn the previous ceremony completes (multi-level-up chain), the scrub would incorrectly remove the new choice. Guard: only scrub if `level_up_session.target_level == level_up_session.current_level` (no pending advance).
- **`rewards_pending.level_up_available` ≠ `planning_block.choices`:** the existing `_scrub_stale_level_up_offer_unless_xp_pending` only touches the rewards_pending field. The new helper must operate on `planning_block.choices` directly — different path, different field.

## Reference

- `references/stale-planning-block-after-completed-level-up.md` — full Firestore field-level evidence table + cross-campaign cluster mapping + code-path pointers to `mvp_site/world_logic.py:4823-4885` and `:4888+` + 3-component fix template.
- `references/level-up-entry-trigger-missing.md` — **NEW (2026-08-23, #9327)** — 3rd sub-class: rewards engine writes `rewards_pending` but `level_up_session.status="available"` never advances to `"in_progress"` and the modal never opens. Diagnosed on campaign `29l48q6zFo7chxWnyjEY` (bg3 nocturne murder god v2, L14→L15, owner `vnLp2G3m21PJL6kxcuAqmWSOtm73`). Smoking gun: `level_up_session.source_story_id="unknown"` + `planning_block.choices=[]` + story export shows narrative wrote "(Lvl 15 available)" status headers for 3+ scenes but no `level_up_now` choice ever surfaced. Distinct from #7922 (modal FINISHES but session never sealed) and #7503 (modal stuck mid-review).
- Verified repro case: [#8767](https://github.com/jleechanorg/worldarchitect.ai/issues/8767) (campaign `7eKaVrHTWFLIVmcio32D`, bead `rev-8uhc6`); [#9327](https://github.com/jleechanorg/worldarchitect.ai/issues/9327) (campaign `29l48q6zFo7chxWnyjEY`, bead `rev-mi304`).
- Load BEFORE assuming any "level-up modal stuck" repro is the canonical finish-injection-missing class — run the 5-step diagnostic first.
