# Wire-shape regression fingerprint — empty `response_text` + populated `response_parts_json` with empty `finishReason`

**Verified worked example:** jleechanorg/worldarchitect.ai issues [#9106](https://github.com/jleechanorg/worldarchitect.ai/issues/9106) (campaign `SGxsM2xdermqwOmI37SF`) + [#9114](https://github.com/jleechanorg/worldarchitect.ai/issues/9114) (campaign `0P8IwPXOpW79z3yy6XDc`), 2026-08-18, `mvp-site-app-dev`, `gemini-3-flash-preview`.

## The wire shape (verified)

When a turn fails with the user-facing banner **"Response validation failed; only user input was persisted."** but the BQ row shows `finish_reason="success"`, pull `response_parts_json` directly. The wire shape is:

```json
{
  "candidates": [{
    "finishReason": "",       // ← EMPTY (not "STOP", not "MAX_TOKENS", not "TOO_MANY_TOOL_CALLS")
    "content": {
      "role": "model",
      "parts": [
        {"thought_signature": "b'\\x12\\x80\\x05\\n..."},   // thought blob
        {"executable_code": {"language": "PYTHON", "code": "import random\n..."}}  // dice roll code
      ]
    }
  }],
  "usageMetadata": {
    "promptTokenCount": 282865,
    "candidatesTokenCount": 525,
    "thoughtsTokenCount": 1692,
    "modelVersion": "gemini-3-flash-preview"
  }
}
```

**Key signatures (ALL must hold):**
1. `response_text` column is **empty** (`LENGTH(response_text) = 0`)
2. `response_parts_json` is **non-empty** with `candidates[0].content.parts[]` populated
3. `parts[]` contains `thought_signature` AND/OR `executable_code` but **NO `text` part**
4. `candidates[0].finishReason` is the **empty string `""`** (distinct from `"STOP"`)
5. `usageMetadata.candidatesTokenCount` is 100-2000 (model finished emitting; didn't crash; just stopped without a text part)

## Why this is distinct from the existing 3 layers

| Pattern | finish_reason | response_text | response_parts_json | parts[].text |
|---|---|---|---|---|
| **#9021 / #9057** (existing Layer 1) | success | empty `""` | populated, **JSON-like text but missing field** | populated, but no worked example for `action_resolution` |
| **Circuit-breaker runaway** | `CODE_EXECUTION_CIRCUIT_BREAKER_TRIPPED` textPayload log | empty | populated | n/a — wall-clock > 90s or iter > 20 |
| **Empty candidates** `{"candidates": []}` | success | empty | `{"candidates": []}` | absent |
| **This wire shape** | `success` in BQ row, but `finishReason=""` in wire | **empty** | **populated** with code_execution parts | **NO `text` part** |

This is **NOT** the same as #9021/#9057 (those have populated `text` parts with missing structured fields). It's NOT a circuit-breaker trip (wall-clock is normal). It's NOT empty candidates (candidates array is non-empty).

## The regression fingerprint in code

`mvp_site/llm_parser.py:2236-2316` is the path:

```python
# line 2242-2247
if raw_response_text is not None:
    if (
        not isinstance(raw_response_text, str)
        or not raw_response_text.strip()
    ):
        raise ValueError("Empty raw_response_text")
    validation_source = raw_response_text
else:
    validation_source = full_narrative
# line 2307-2320 — what fires when text is empty
validation_failed = True
logging_util.exception("Streaming response validation failed before persistence")
persistence_warnings.append(StreamEvent(
    type="warning",
    payload={"message": "Response validation failed; only user input was persisted."}
))
```

The wire-shape regression lands here because:
1. `raw_response_text` is the parsed `text` field from `response_parts_json.candidates[0].content.parts[]`
2. The wire shape has NO `text` part → `raw_response_text` is `""` (or None)
3. `raise ValueError("Empty raw_response_text")` at line 2247
4. Falls through to `validation_failed = True` at line 2307
5. SSE emits `"Response validation failed; only user input was persisted."`
6. UI shows the orange warning banner, input stays in composer, no narrative renders

## Why this is a PR #9045 regression

Verified 2026-08-18 by `git diff 9c6f5d723b~1 9c6f5d723b -- mvp_site/prompts/shared/dice_code_execution.md`:

**Before PR #9045 (worked):**
```
3. For EVERY dice roll, EXECUTE Python code with the appropriate format:
4. After code_execution returns, copy the same canonical dice fields into
   `action_resolution.mechanics.rolls`.
```

**After PR #9045 (regression):**
```
1. RNG Execution: Do NOT output `tool_requests` for dice. For EVERY dice roll,
   EXECUTE Python `code_execution` with `random.randint()` to generate true
   random numbers.
2. Authoritative Record: The server automatically captures Python
   `code_execution` stdout as the authoritative mechanical record. **You do NOT
   need to duplicate or copy raw dice rolls into `action_resolution.mechanics.rolls`.**
```

The deletion of "copy the same canonical dice fields into `action_resolution.mechanics.rolls`" removed the safety net. `gemini-3-flash-preview`:
- Emits `executable_code` (Python dice rolling) ✓
- Does NOT emit a final `text` part with structured JSON ✗
- `finishReason` is `""` (empty), not `"STOP"` ✗

`gemini-3-flash-preview` was never validated against the new prompt — PR #9045 was authored against `gemini-2.5-pro` + `gemini-3.7-flash` only.

## Diagnostic recipe (add to existing Step 1 of `wa-llm-output-emission-false-green-watchdog`)

When the user reports "Response validation failed; only user input was persisted" on a turn with `finish_reason="success"`:

```sql
-- Step 1: Detect the wire-shape regression fingerprint
SELECT FORMAT_TIMESTAMP('%Y-%m-%dT%H:%M:%SZ', ingested_at) AS ts,
       agent, turn_index,
       LENGTH(request_json) AS req_bytes,
       LENGTH(response_text) AS resp_bytes,
       LENGTH(response_parts_json) AS parts_bytes,
       finish_reason
FROM `worldarchitecture-ai.llm_forensics.llm_payloads`
WHERE campaign_id = '<CID>'
  AND LENGTH(response_text) = 0
  AND LENGTH(response_parts_json) > 0
ORDER BY ingested_at DESC
LIMIT 10
```

`resp_bytes=0` AND `parts_bytes>0` is the wire-shape fingerprint. Distinguish from:
- `parts_bytes=18` = `{"candidates": []}` empty-candidates flake (Gemini SDK-level)
- `parts_bytes=25915` (verified) = wire-shape regression with code_execution parts

```sql
-- Step 2: Confirm finishReason is empty string
SELECT response_parts_json
FROM `worldarchitecture-ai.llm_forensics.llm_payloads`
WHERE campaign_id = '<CID>'
  AND LENGTH(response_text) = 0
  AND LENGTH(response_parts_json) > 100
ORDER BY ingested_at DESC
LIMIT 1
```

Then parse with Python:

```python
import json
data = json.loads(open('/tmp/regression_parts.csv').read())
cands = data[0]['candidates']
print(f'candidates={len(cands)}, finishReason="{cands[0].get("finishReason","MISSING")}"')
parts = cands[0]['content']['parts']
print(f'parts: {len(parts)}')
for i, p in enumerate(parts):
    keys = list(p.keys()) if isinstance(p, dict) else []
    has_text = 'text' in keys
    print(f'  parts[{i}]: {keys}, has_text={has_text}')
```

Expected output for the regression:
```
candidates=1, finishReason=""
parts: 2
  parts[0]: ['thought_signature'], has_text=False
  parts[1]: ['executable_code'], has_text=False
```

**Zero `text` parts = wire-shape regression. Verify by checking the prompt file's commit history for "centralize dice code execution prompts" or similar restructuring commits.**

## Cross-references

- `wa-narrative-schema-required-fields-contract` — Layer 2 served-prompt contract test (use AFTER confirming wire-shape regression, to verify the fix re-anchors worked examples)
- `repro` Step 0.77 — BQ-first diagnostic for directive-loss reports (sibling pattern; same BQ table, different symptom class)
- `references/case-2026-08-18-dice-audit-fp-calc-and-4x-prefix.md` — audit-side cousin of the same false-green family

## Pitfall — initial diagnosis is often wrong

Verified 2026-08-18: the FIRST hypothesis was "circuit-breaker runaway" based on visible `CODE_EXECUTION_CIRCUIT_BREAKER_TRIPPED` log entries. Those were a separate transient (a `PlanningAgent` call), not the cause of the `RewardsAgent` empty-candidate pattern. Always pull the BQ wire shape for the failing turn. The fingerprint `response_text=0` + `response_parts_json>0` + `finishReason=""` + parts without `text` is unambiguous.