# Case study — issue #9057, Missing action_resolution warning, 2026-08-18

This is the second confirmed instance of the false-green pattern (first was #9021). Captured here so future sessions can grep for "is this #9057-class?" without re-deriving the full evidence.

## User-visible symptom

UI System Warnings panel on every StoryModeAgent turn:
```
• Missing action_resolution field (required for player actions)
```
Live URL: `https://mvp-site-app-dev-i6xf2p72ka-uc.a.run.app/game/SGxsM2xdermqwOmI37SF`

## Root cause — two commits, neither on `origin/main`

1. **Commit `098ca8316d` "fix(prompt): add REQUIRED response schema section for issue #9021"** — added the `## REQUIRED RESPONSE SCHEMA — narrative_response_schema` section at the top of `mvp_site/prompts/narrative_system_instruction.md` with worked examples for `dice_rolls`, `action_resolution`, `planning_block`. Also added `mvp_site/tests/test_narrative_response_schema_required_fields_9021.py` (9 tests) and `scripts/check_narrative_response_schema_required.py` (CI lint).

   **This commit lives ONLY on branch `fix/narrative-response-schema-required-9021`.** Verified `git merge-base --is-ancestor 098ca8316d origin/main` returns exit 1. The user thought it was merged; it never reached `main`.

2. **Commit `9c6f5d723b` "refactor: decouple redundant model-computed arithmetic and centralize dice code execution prompts (#9045)"** — landed on `origin/main` 2026-08-18. Refactored lines 396-510 of `narrative_system_instruction.md`, removing ~100 lines of "DICE ROLLS CENTRALIZATION (MANDATORY)" prose that contained a worked `action_resolution.mechanics.rolls` JSON example. Replaced with a 3-line "DICE RESOLUTION & UI DISPLAY" stub that says *"you do not need to populate `dice_rolls` or copy raw dice rolls into `action_resolution.mechanics.rolls`."*

   Dev revision `mvp-site-app-dev-04475-smb` is on `9c6f5d7`. The new stub actively weakens the schema anchor.

## BQ evidence

Campaign `SGxsM2xdermqwOmI37SF`, turn 142 (StoryModeAgent, 2026-08-18T09:07:49Z):

| Metric | Value |
|---|---|
| `prompt_tokens` | 307,577 |
| `cached_tokens` | 181,701 |
| cache hit rate | 59.1% |
| `output_tokens` | 2,797 |
| Served `request_json` (big row) | 1,214,259 bytes |
| Served `request_json` (small row, canonical turn_index) | 277 bytes (placeholder) |
| LLM emitted `action_resolution` | **absent** |
| LLM emitted `dice_rolls` | `[]` |
| LLM emitted `dice_audit_events` | `[]` |
| LLM emitted `tool_requests` | `[]` |
| LLM emitted `state_updates` keys | only `world_data.{location, world_time}` + `custom_campaign_state.{core_memories, next_companion_arc_turn}` |

**Served-prompt field-mention audit** (regex `"<field>":\s*[\[\{]` for worked JSON examples):

| Field | Mentions | Worked JSON examples |
|---|---|---|
| `dice_rolls` | 27 | 1 |
| `action_resolution` | 73 (all in past-turn history or schema prose) | **0** ← regression |
| `planning_block` | 93 | 1 |

**`"REQUIRED RESPONSE SCHEMA — narrative_response_schema"` header in served prompt:** 0 occurrences.

## What the LLM was supposed to emit

The pure-narrative turn correctly emits empty dice (no rolls were rolled) — but `action_resolution` should still be present with at minimum:

```json
{
  "reinterpreted": false,
  "player_input": "",
  "interpreted_as": "",
  "audit_flags": []
}
```

The LLM emitted nothing at the `action_resolution` key, so the server-side `_requires_action_resolution` guard at `mvp_site/narrative_response_schema.py:3513-3541` correctly appended `"Missing action_resolution field (required for player actions)"` to `debug_info._server_system_warnings`.

## The user's instinct — wrong diagnosis, captured for posterity

> "thought we merged a PR to ensure dice rolls are always copied there or maybe we need to update the warning to look for code execution record or action resolution?"

Two halves:
1. "we merged a PR" — **WRONG**. The fix was on a branch, never on main.
2. "update the warning to look for code execution record" — **WRONG**. The warning is correct; the LLM is wrong. Masking it would hide #9021-class bugs forever.

The right fix is upstream — re-land the schema anchor on `origin/main`.

## Sibling turns (same regression signature)

| Turn | ts | `action_resolution` | `dice_rolls` |
|---|---|---|---|
| 142 | 09:07:49Z | absent | `[]` |
| 139 | 09:04:13Z | absent | `[]` |
| 136 | 08:45:42Z | absent | absent |
| 132 | 08:37:26Z | absent | `[]` |

All on dev revision `9c6f5d7`.

## Why this is the false-green class (3 layers)

- **Layer 1 (audit-event source ≠ LLM-output-side):** `wa-daily-dice-audit` cron passes — audit events are clean. The LLM-side emission is broken.
- **Layer 2 (served-prompt contract):** the served prompt is missing the `REQUIRED RESPONSE SCHEMA` header that anchored the field on the working turn.
- **Layer 3 (canary on LLM-output-side, not just audit):** no existing canary fires on `LLM-emitted action_resolution absent` for non-dice turns — the existing canary focuses on `dice_audit_events` integrity.

## Verification commands (re-runnable)

```bash
# 1. Find the campaign + recent high-token turns
cd / && unset PYTHONPATH && bq query --use_legacy_sql=false --project_id=worldarchitecture-ai --format=csv "
SELECT campaign_id, MAX(turn_index) AS max_turn, COUNT(*) AS n, MAX(ingested_at) AS last_seen
FROM \`worldarchitecture-ai.llm_forensics.llm_payloads\`
WHERE campaign_id LIKE '%SGxsM2xdermqwOmI37SF%' OR request_json LIKE '%SGxsM2xdermqwOmI37SF%'
GROUP BY campaign_id ORDER BY last_seen DESC LIMIT 5
"

# 2. Inspect both rows for turn 142 (canonical + streaming)
bq query --use_legacy_sql=false --project_id=worldarchitecture-ai --format=csv "
SELECT FORMAT_TIMESTAMP('%Y-%m-%dT%H:%M:%SZ', ingested_at) AS ts, turn_index,
       LENGTH(request_json) AS rj_len, LENGTH(response_text) AS rt_len
FROM \`worldarchitecture-ai.llm_forensics.llm_payloads\`
WHERE campaign_id = 'SGxsM2xdermqwOmI37SF' AND turn_index = 142
"

# 3. Pull response_text from the canonical row and parse for action_resolution
bq query --use_legacy_sql=false --project_id=worldarchitecture-ai --format=csv "
SELECT response_text FROM \`worldarchitecture-ai.llm_forensics.llm_payloads\`
WHERE campaign_id = 'SGxsM2xdermqwOmI37SF' AND turn_index = 142 AND agent = 'StoryModeAgent' LIMIT 1
" > /tmp/turn142.csv

# 4. Pull the BIG served prompt row (turn_index IS NULL)
bq query --use_legacy_sql=false --project_id=worldarchitecture-ai --format=csv "
SELECT request_json FROM \`worldarchitecture-ai.llm_forensics.llm_payloads\`
WHERE campaign_id = 'SGxsM2xdermqwOmI37SF' AND turn_index IS NULL
  AND FORMAT_TIMESTAMP('%Y-%m-%dT%H:%M:%SZ', ingested_at) = '2026-08-18T09:07:48Z'
  AND LENGTH(request_json) > 100000 LIMIT 1
" > /tmp/turn142_served.csv

# 5. Verify the fix is NOT on main
git -C ${HOME}/projects/worldarchitect.ai merge-base --is-ancestor 098ca8316d origin/main
# expect: exit 1

# 6. Verify the deployed revision
gcloud run revisions list --service=mvp-site-app-dev --region=us-central1 \
  --project=worldarchitecture-ai --format="table(metadata.name,metadata.labels.commit-sha,status.conditions[0].status)" --limit 1
# expect: commit-sha = 9c6f5d7 (NOT 098ca83)

# 7. Confirm the section is missing from origin/main
git -C ${HOME}/projects/worldarchitect.ai show origin/main:mvp_site/prompts/narrative_system_instruction.md | head -3
# expect: NO "## REQUIRED RESPONSE SCHEMA" line at top
```

## Files touched (or that should be touched)

- `mvp_site/prompts/narrative_system_instruction.md` — needs the `## REQUIRED RESPONSE SCHEMA` section restored at the top
- `mvp_site/tests/test_narrative_response_schema_required_fields_9021.py` — 9-test contract (cherry-pick from commit `098ca8316d`)
- `scripts/check_narrative_response_schema_required.py` — CI lint (cherry-pick from commit `098ca8316d`)

## Out of scope (do NOT touch in this fix)

- `mvp_site/narrative_response_schema.py:3513` (`_requires_action_resolution` guard fires correctly — do NOT mask the warning)
- `mvp_site/structured_fields_utils.py:29` (`backfill_dice_rolls()` is correct — out of scope)
- `mvp_site/tests/test_structured_fields_utils.py:516` (the false-green test is a SEPARATE bead — separate PR)
- The `dice_rolls: []` backfill path (works correctly)

## Dispatch record

- Issue: https://github.com/jleechanorg/worldarchitect.ai/issues/9057
- Bead: `rev-1acx5` in worldarchitect.ai `.beads/issues.jsonl`
- Status cron: `93b9fe10e58a` (one-time, +20m)
- Worker: `deleg_7e32244c` (claudem on `${HOME}/projects/wt-action-resolution-bug`, branch `fix/action-resolution-warning-replay-9057`)
