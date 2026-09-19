---
name: wa-narrative-schema-required-fields-contract
version: 0.1.0
description: "Use when reviewing a WA PR that touches mvp_site/prompts/**, mvp_site/agent_prompts.py, mvp_site/narrative_response_schema.py, mvp_site/structured_fields_utils.py, OR when issuing a /harness postmortem on a WA bug whose served prompt is missing structured-output field declarations (e.g. dice_rolls[] / action_resolution / planning_block) with worked examples. Verifies that every Required structured-output field the LLM is expected to emit appears in the served prompt with at least one worked example near a JSON shape the LLM can pattern-match against. Triggered by issue #9021."
tags: ["worldarchitect", "prompts", "narrative_response_schema", "contract-test", "false-green-guard", "llm-output-side"]
changelog:
  - "0.1.0 (2026-08-17): Initial authoring. Triggered by /harness postmortem on issue #9021 (StoryModeAgent dice_rolls[] empty + planning_block absent + action_resolution missing on 315,988-prompt-token turn)."
---

# wa-narrative-schema-required-fields-contract

The recurring false-green class at issue #9021 was: **the served prompt's `narrative_response_schema` declaration did NOT contain worked examples for `dice_rolls[]`, `action_resolution`, or `planning_block`**, so the LLM emitted empty defaults on a high-token turn (`cache_hit_rate=59.4%` vs `72.9%` on the working turn). The post-processor `backfill_dice_rolls()` at `mvp_site/structured_fields_utils.py:29` and the streaming equivalent at `mvp_site/llm_parser.py:503` masked the LLM-side regression.

This skill is the **contract-test side** of the `## COMMIT: wa-llm-output-emission-false-green-watchdog` SOUL.md block (Layer 2). It produces the served-prompt contract test that would have caught #9021 BEFORE the PR landed.

## When to fire

Trigger on any of:
- User issues `/harness postmortem` on a WA bug with the symptom pattern "LLM emitted `dice_rolls: []` / `action_resolution` absent / `planning_block` absent while the audit-event source is populated"
- Hermes is reviewing a WA PR that touches `mvp_site/prompts/**` or `mvp_site/agent_prompts.py` or `mvp_site/narrative_response_schema.py`
- A `/es` evidence check on a prompt-side fix needs served-prompt proof

## The contract

The served `request_json` (the JSON payload Gemini receives) MUST contain, for each Required structured-output field the LLM is expected to emit:

1. **At least 1 textual mention** of the field name (e.g. `dice_rolls`)
2. **At least 1 worked JSON example** of the populated field (e.g. `"dice_rolls": [{"expr": "1d20+14", "result": 24, "rolls": [10], ...}]`)

Required structured-output fields for StoryModeAgent (verified 2026-08-17, the bug class scope):
- `dice_rolls[]` — REQUIRED; the served prompt must include a worked example showing populated entries
- `action_resolution` — REQUIRED; the served prompt must include a worked example showing `reinterpreted: true` + `mechanics.rolls[]`
- `planning_block` — REQUIRED; the served prompt must include a worked example showing `choices: {...}` shape (currently this is the ONLY one with a worked example, via the `{{PLANNING_BLOCK_SCHEMA}}` placeholder injection in `mvp_site/prompts/planning_protocol.md`)

## Recipe

### Step 1 — Pull the served `request_json` for a real StoryModeAgent turn

```bash
# Project id is worldarchitecture-ai (NOT worldarchitect-ai)
# Per wa-cloud-logging-diag v2.0.0 the field-mapping gotcha is
# jsonPayload.message:"cdiag_name=..."
bq query --use_legacy_sql=false --project_id=worldarchitecture-ai --format=json "
SELECT request_json
FROM \`worldarchitecture-ai.llm_forensics.llm_payloads\`
WHERE campaign_id = 'Mz4s5zy30noDnSgScPJH'
  AND agent_class = 'StoryModeAgent'
  AND turn_number = 101
LIMIT 1
" | jq -r '.[0].request_json' > /tmp/served_prompt_turn_101.json
```

### Step 2 — Grep for Required-field mentions + worked examples

```python
import json
import re

REQUIRED_FIELDS = ["dice_rolls", "action_resolution", "planning_block"]

with open("/tmp/served_prompt_turn_101.json") as f:
    served = json.load(f)

failures = []
for field in REQUIRED_FIELDS:
    # Heuristic: a "worked example" must include the field name within 100 chars
    # of a JSON-looking substring (a `{` or `[` followed by `"<field>"`).
    pattern = re.compile(
        r'"\b' + re.escape(field) + r'\b"\s*:\s*[\[\{]',
        flags=re.IGNORECASE,
    )
    body = json.dumps(served)
    if not pattern.search(body):
        failures.append(field)

assert not failures, (
    f"served prompt is missing worked examples for Required fields: {failures}. "
    f"Per issue #9021, this is the regression signature — the LLM will emit "
    f"empty defaults on high-token turns."
)
```

### Step 3 — Wire as a contract test in `mvp_site/tests/`

Add `mvp_site/tests/test_narrative_response_schema_required_fields_9021.py` that runs Step 1 + Step 2 against the latest StoryModeAgent turns in the BQ table (the test queries BQ; mark with `pytest.mark.skipif(not os.getenv("BQ_ACCESS"))` so it doesn't break CI without GCP auth).

### Step 4 — Add a CI lint that catches prompt-side schema drift

`scripts/check_narrative_response_schema_required.py`:
1. Walk `mvp_site/prompts/` for `.md` files registered in `mvp_site/agent_prompts.PATH_MAP`
2. For each Required field, verify the file contains at least one worked JSON example (regex from Step 2)
3. Run as part of `./run_tests.sh --lint` (no BQ needed — works on the prompt source files)

The CI lint catches future regressions WITHOUT needing GCP access; the BQ contract test catches the runtime regression on real served prompts.

## Worked example — the prompt-side fix for #9021

The durable project-side fix (NOT this skill's responsibility — dispatched to the `/rg` worker on PR #9021) extends `mvp_site/agent_prompts._inject_schema_placeholders` with:

```python
"{{DICE_ROLLS_SCHEMA}}": _schema_to_json_string(DICE_ROLLS_SCHEMA),
"{{ACTION_RESOLUTION_SCHEMA}}": _schema_to_json_string(ACTION_RESOLUTION_SCHEMA),
```

…then places `{{DICE_ROLLS_SCHEMA}}` and `{{ACTION_RESOLUTION_SCHEMA}}` in `mvp_site/prompts/narrative_system_instruction.md` (or a new `mvp_site/prompts/shared/narrative_response_schema_contract.md` registered in `PATH_MAP`) with at least one worked example each.

This skill's contract test (Steps 1-3) catches the case where the worked example is REMOVED, the placeholder is REMOVED, or the schema declaration regresses to "0 mentions" on the served prompt.

## Pitfalls

- **Don't confuse audit-event source with LLM-output-side.** The `wa-daily-dice-audit` GCP cron (`wa-daily-dice-audit-fix` skill) operates on the audit-event source (`dice_audit_events[]`) and `notation` field integrity — NOT on the LLM's `response_text` emission. A passing cron is NOT evidence the LLM-side field is populated. #9021 has both `dice_audit_events` populated AND `dice_rolls` empty in the same turn.
- **Search the WHOLE prompt, not just `narrative_system_instruction.md`.** The served prompt concatenates files from `PATH_MAP` per agent. For StoryModeAgent, that's master_directive + game_state + planning_protocol + combat_state_contract + dnd_srd + living_world + ... + narrative. Search the assembled prompt.
- **The 315K-token turn envelope matters.** High-prompt-token turns cause the LLM to truncate structured output (`output_tokens=2334` on turn 101, `cache_hit_rate=59.4%` vs 72.9% on turn 100). The contract test must run against a real high-token turn, not a stub. Filter `bq query` by `prompt_tokens > 200000` to find them.
- **`backfill_dice_rolls()` masks the bug.** The post-processor at `mvp_site/structured_fields_utils.py:29` populates `dice_rolls` from `action_resolution.mechanics.rolls[]` OR `dice_audit_events[]` when the LLM emits empty. The Firestore value CAN be populated even when the LLM's `response_text` is empty — verify BOTH surfaces, not just one.
