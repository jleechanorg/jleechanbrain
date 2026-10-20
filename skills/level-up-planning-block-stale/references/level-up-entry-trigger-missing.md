# Level-up entry-trigger-missing — 3rd sub-class of the modal-state family

Verified 2026-08-23 on [jleechanorg/worldarchitect.ai #9327](https://github.com/jleechanorg/worldarchitect.ai/issues/9327) (campaign `29l48q6zFo7chxWnyjEY`, "bg3 nocturne murder god v2", owner `vnLp2G3m21PJL6kxcuAqmWSOtm73` / `jleechan@gmail.com`, dev `mvp-site-app-dev`). Bead `rev-mi304`.

## Symptom

User reports *"the level up isn't resolving to level 15"* — they see the story text say "(Lvl 15 available)" but no level-up modal ever opens in the UI. The character stays at L14 forever even though XP threshold is met and rewards are queued.

## Why the canonical sibling classes do NOT match

- Not **stale-planning-block** (`#8767` / `level-up-planning-block-stale/SKILL.md` 5-step diagnostic sub-class (a)) — there is no `level_up_transition` choice in `planning_block.choices` at all; `choices=[]`. The bug is the missing choice, not a stale one.
- Not **finish-injection-missing** (`#7922`) — the modal never FINISHED because it never OPENED. `level_up_session.status="available"` (offer queued, never clicked), not `"in_progress"` or `"complete"`.
- Not **mid-final-review** (`#7503`) — `review_open=false`. No review window was ever opened.
- Not **never-triggers** (`#7929`) — the rewards engine DID write the canonical evidence (`rewards_pending.level_up_available=true`, `source_id=level_up_14_to_15`). The signal was created; the entry chain just never acted on it.

## 3-source cross-reference diagnostic (no live LLM turn required)

This sub-class is the first one where **three sources must agree** to confirm the bug from static evidence alone. The previous sub-classes only needed Firestore pre-state.

### Source 1 — Direct Firestore pre-state (canonical, required)

The smoking-gun signature — all four conditions must hold:

| Condition | Value |
|-----------|-------|
| `rewards_pending.level_up_available` | `true` |
| `rewards_pending.processed` | **`false`** (unconsumed) |
| `rewards_pending.new_level` | `> player_character_data.level` (target) |
| `level_up_session.status` | `"available"` (NOT `"in_progress"`/`"committing"`/`"complete"`) |
| `level_up_session.modal_open` | `false` |
| `level_up_session.source_story_id` | **`"unknown"`** ← distinctive — created without story-entry anchor |
| `planning_block.choices` | `[]` (no `level_up_now` choice injected) |
| `player_character_data.level` | stuck at pre-promotion value |

Direct REST read:
```bash
curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  "https://firestore.googleapis.com/v1/projects/worldarchitecture-ai/databases/(default)/documents/users/<UID>/campaigns/<CID>/game_states/current_state"
```

### Source 2 — Story export (`scripts/download_campaign.py --format txt`)

Grep status headers in the story text for the pattern `Status: Lvl <N>.*\(Lvl <N+1> available\)`. When the narrative-stream notices the threshold and writes the "(Lvl <N+1> available)" suffix for **3 or more consecutive scenes** without the modal ever opening, the entry-trigger chain is broken. Worked example on campaign `29l48q6zFo7chxWnyjEY`:

- Scene 55 (line 1981): `Status: Lvl 14 Gloomstalker 15 / Assassin 15 (Gestalt) (Lvl 15 available)` — first appearance of the suffix
- Scene 56 (line 2010): `Status: Lvl 14 Gestalt (Lvl 15 available)`
- Scene 57 (line 2033): `Status: Lvl 14 Gloomstalker Ranger 12 / Assassin Rogue 12 (Gestalt) (Lvl 15 available)`
- Scene 58 (line 2057): `Status: Lvl 14 Gestalt (Lvl 15 available)`

Three scenes writing "Lvl 15 available" without the modal surfacing is the canonical signal. Sub-class (c) requires at least 2 consecutive scenes with the suffix; 3+ is high-confidence.

Bonus smoking gun — when the narrative pre-computes subclass split at the next level (e.g. "Gloomstalker 15 / Assassin 15") but the modal still doesn't open, the discrepancy is unmistakable to the user.

### Source 3 — Planning_block choice array (in pre-state, NOT post-state)

`planning_block.choices` MUST be empty (`[]`) AND `server_generated` must be `true` (frontend got fallback action choices like "continue forward" instead of `level_up_now`). This distinguishes sub-class (c) from sub-class (a): in (a), the choices array is non-empty but stale; in (c), the array is empty because the chain never injected.

## Same-symptom criteria (write before replay)

| Original required symptom | New copied-run observation | Evidence file / doc ID | Verdict |
|---------------------------|----------------------------|------------------------|---------|
| `rewards_pending.processed=false` AND `level_up_session.status="available"` AND `pcd.level < target_level` for 2+ consecutive scenes | pre-state shows all three + story shows "(Lvl N+1 available)" status headers for 3+ scenes with no modal | `/tmp/wa-lvlup-prestate.json` + story export | **REPRO** |
| `level_up_session.source_story_id="unknown"` | pre-state confirms literal `"unknown"` string | pre-state JSON | **REPRO** |
| `planning_block.choices=[]` AND `server_generated=true` after rewards queued | pre-state confirms both | pre-state JSON | **REPRO** |
| Story-side pre-computes subclass split (e.g. "Gloomstalker 15 / Assassin 15") | story export confirms | `<CID>_<short>.txt` line 1981 | **REPRO** |

## Repro recipe (for twin replay)

1. Copy campaign to `jleechantest@gmail.com` via `scripts/copy_campaign.py --find-by-id <CID> --dest-email jleechantest@gmail.com`.
2. Capture twin pre-state via direct Firestore REST read (mirror of source `/tmp/wa-lvlup-prestate.json`).
3. Verify twin pre-state matches source bit-for-bit (107,807 bytes in the verified case).
4. **Skip live replay unless the static-evidence gate is insufficient.** Per `references/static-evidence-sufficient-no-live-turn.md`, this sub-class is fully diagnosable from pre-state + story export alone. The live replay only adds value if you need to confirm the agent-routing layer (which the static evidence cannot prove).
5. If a live replay IS required (e.g. to verify a candidate fix): spin up local Flask with `TESTING_AUTH_BYPASS=true ALLOW_TEST_AUTH_BYPASS=true` env vars (per `references/auth-gate-fallback-repro.md`). The deployed dev server (`mvp-site-app-dev`) does NOT expose auth-bypass headers — `X-Test-Bypass-Auth` / `X-Test-User-Id` only work on the local Flask path.

## Why this bug exists (hypothesis)

The `level_up_session` state machine has multiple entry points, and the rewards engine's `_canonical_pending_level_up_transition` correctly identifies the actionable transition `(14, 15)`. But the call sites that route to `LevelUpAgent` and inject the `level_up_now` choice may see `is_session_active(session) == True` (because `status="available"` is in `ACTIVE_STATUSES = {available, in_progress, committing, error}` per `mvp_site/level_up_session.py:62`) and decide the modal is "already active" without:

(a) Injecting the `level_up_now` choice into `planning_block.choices`
(b) Advancing `level_up_session.status` to `"in_progress"` (the click-transition state)
(c) Setting `entered_at_story_id` and `source_story_id` to the actual story entry where the rewards signal originated (which is why we see the literal `"unknown"` literal string)

The existing `seal_orphaned_available_session()` helper at `mvp_site/level_up_session.py:509` only fires when `pcd_level >= target_level` — the **inverse case** (entry-trigger-missing when `pcd_level < target_level`). No equivalent helper exists. There is a gap in the orphan-handling matrix.

## Durable fix shape (3-component, verified from #9327)

**Where:** `mvp_site/agents.py:_level_up_modal_in_progress_flag()` (around line 3970) AND `mvp_site/rewards_engine.py:_canonical_pending_level_up_transition()` callers in `ensure_planning_block` / `ensure_rewards_box`.

1. **Component 1 — Promote rewards-pending to a primary entry trigger.** When `rewards_pending.level_up_available=true` AND `rewards_pending.processed=false` AND `target_level > pcd.level`, the routing layer MUST atomically: (a) advance `level_up_session.status` from `"available"` to `"in_progress"`; (b) inject the `level_up_now` choice in `planning_block.choices`; (c) set `entered_at_story_id=<current story id>` and `source_story_id=<signal's source story id>`. Today the chain may see the active session and short-circuit without injecting.
2. **Component 2 — Atomic transition guard.** When advancing the session, atomically co-write: `status="in_progress"`, `entered_at_story_id=<current story id>`, `source_story_id=<signal's source story id>` (NOT the literal `"unknown"` string), and mark `rewards_pending.processed` transitioning to `true` when the modal closes OR auto-apply commits.
3. **Component 3 — Contract test** `mvp_site/tests/test_end2end/test_level_up_entry_trigger_end2end.py` mirroring the existing `test_level_up_session_seal_available_end2end.py` structure but for the entry-trigger sub-class:
   - Seed state with `rewards_pending.processed=false`, `level_up_session.status="available"`, `pcd.level < target_level`.
   - POST a normal story turn.
   - Assert: `level_up_session.status` advances to `"in_progress"` (or higher), `planning_block.choices` contains `level_up_now`, `rewards_pending.processed` is `true` (or `rewards_pending` is cleared), `entered_at_story_id` is non-null and matches a story entry id.

## Cross-campaign cluster mapping

Verified instances on this exact sub-class:
- #9327 — campaign `29l48q6zFo7chxWnyjEY` (bg3 nocturne murder god v2, owner jleechan@gmail.com, dev mvp-site-app-dev)

Suspected-may-match (verify in each):
- Any campaign where `rewards_pending.processed=false` persists for 2+ consecutive story entries while the narrative-side status header shows "(Lvl N+1 available)" — the symptom is unmistakable to the user (modal never opens) but hard to spot from a single snapshot.
- Cross-user variant: any campaign (any owner) where the LLM wrote the rewards signal in a turn but the next turn didn't transition `level_up_session.status`. Pattern is owner-agnostic.

## In-flight PR audit (related, not a fix for this symptom)

- OPEN [PR #9314](https://github.com/jleechanorg/worldarchitect.ai/pull/9314): "fix(prompts): detect open level-up review via canonical level_up_session" — addresses review-self-close, NOT entry-trigger.
- OPEN [PR #8177](https://github.com/jleechanorg/worldarchitect.ai/pull/8177): "fix(world_logic): atomically clear level-up modal lock on level-up completion" — addresses post-completion lock clearing, NOT entry-trigger.
- OPEN [PR #8728](https://github.com/jleechanorg/worldarchitect.ai/pull/8728): "fix(zfc): register _repair_malformed_modal_choices in backend_adjustment_specs" — addresses malformed choice repair, NOT entry-trigger.
- OPEN [PR #8729](https://github.com/jleechanorg/worldarchitect.ai/pull/8729): "refactor(world_logic): remove dead branches in _is_level_up_agent" — may surface this class during cleanup.

No in-flight PR addresses the entry-trigger-missing sub-class. The 3-component fix shape above is the proposed durable fix.

## Working workaround for live campaign (verified path)

God-mode admin commit at `mvp_site/agents.py:1142-1158` folds onto `level_up_session.apply_level_up` directly and bypasses the entry-trigger chain. The admin-commit path is the documented escape hatch; per `references/unbounded-scaling-l30-level-up-bug-class-2026-07-21.md`, this works for any level range (not just L21+).

## Verified repro evidence

- Issue: [#9327](https://github.com/jleechanorg/worldarchitect.ai/issues/9327)
- Bead: `rev-mi304`
- Twin copy: `r5zYW4DZQUozwNgNVygl` (under `jleechantest@gmail.com`)
- Twin pre-state: `/tmp/wa-lvlup-twin-prestate.json` (107,807 bytes, bit-for-bit identical to source)
- Source pre-state: `/tmp/wa-lvlup-prestate.json` (107,807 bytes)
- Source export: `/tmp/wa-lvlup-source-export/bg3 nocturne murder god v2_29l48q6z.txt` (117 entries, 192 KB) + `_game_state.json` (72.7 KB)
- Story-side confirmation: [comment 5391724733](https://github.com/jleechanorg/worldarchitect.ai/issues/9327#issuecomment-5391724733)
