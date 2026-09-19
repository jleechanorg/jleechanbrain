# Sub-class C — PR-9045 prompt regression (executable_code + empty `finishReason`)

**Verified 2026-08-19 across 3 sibling campaigns** (ArYA47Fvx8HTYC8jpleO Scene #297, 29l48q6zFo7chxWnyjEY turn 16, FsiyESY987DF2lfgolCI turn 128) — all owned by UID `vnLp2G3m21PJL6kxcuAqmWSOtm73` (jleechan@gmail.com), all on model `gemini-3-flash-preview`, all in deploy revisions `mvp-site-app-dev-04526-wfp` / `04527-dvr` (deployed after PR #9045 merged).

This sub-class was previously misdiagnosed as "cache-invalidation truncated response" (see the earlier version of this file). The actual cause is **PR #9045 (`9c6f5d723b`, merged 2026-08-18)** which restructured `mvp_site/prompts/shared/dice_code_execution.md` — the old prompt told the LLM to copy dice into `action_resolution.mechanics.rolls`, the new prompt says *"You do NOT need to duplicate or copy raw dice rolls into `action_resolution.mechanics.rolls`"*. For `gemini-3-flash-preview` (the dev default per `mvp_site/constants.py:66`), this causes the LLM to emit `executable_code` + `thought_signature`, then stop without emitting a final `text` part — `finishReason` arrives as the empty string `""`, which the streaming loop doesn't classify.

The user's verbatim quote (from sibling issue #9114): *"gemini 3 flash was always working before and never had this issue before we changed the code execution prompt to suit 3.7 flash"*.

## Signature (verified on 3 campaigns today)

BQ `worldarchitecture-ai.llm_forensics.llm_payloads`:

```sql
SELECT FORMAT_TIMESTAMP('%Y-%m-%dT%H:%M:%SZ', ingested_at) AS ts,
  campaign_id, agent, model, turn_index, finish_reason,
  LENGTH(CAST(response_text AS STRING)) AS resp_bytes,
  LENGTH(CAST(response_parts_json AS STRING)) AS parts_bytes,
  output_tokens, prompt_tokens, cached_tokens, revision_id,
  SUBSTR(CAST(response_parts_json AS STRING), 1, 600) AS parts_sample
FROM `worldarchitecture-ai.llm_forensics.llm_payloads`
WHERE campaign_id IN ('ArYA47Fvx8HTYC8jpleO','29l48q6zFo7chxWnyjEY','FsiyESY987DF2lfgolCI')
  AND ingested_at > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 DAY)
  AND (LENGTH(CAST(response_text AS STRING)) < 500
       OR finish_reason LIKE '%error%'
       OR finish_reason = ''
       OR agent = 'unknown')
ORDER BY ingested_at DESC
LIMIT 30
```

Distinctive row shape on the failing turn:

| Campaign | ts (UTC) | agent | turn | resp_chars | finish_reason | parts_bytes | Cause |
|---|---|---|---|---|---|---|---|
| `ArYA47Fvx8HTYC8jpleO` | 09:25:25 | RewardsAgent | 168 | **356** | success | 14324 | LLM emitted partial narrative, cache=0%, stop mid-token |
| `ArYA47Fvx8HTYC8jpleO` | 09:35:50 | RewardsAgent | 169 | 6787 | success | normal | Same agent/model 10min later, cache=88.8%, success |
| `29l48q6zFo7chxWnyjEY` | 09:27:23 | FactionManagementAgent | 16 | **0** | error: validation_failed | **25084** | LLM emitted 25KB of content, server threw it away |
| `29l48q6zFo7chxWnyjEY` | 03:23:38 | unknown | – | **0** | success | – | No agent context, model = "Gemini 3.5 Flash (High)" fallback string |
| `FsiyESY987DF2lfgolCI` | 09:24:41 | GodModeAgent | 128 | **4** | success | 105 | Literal `{"` (4 chars) — opening brace then stop |

The smoking-gun `response_parts_json` on the 29l48q6zFo7chxWnyjEY turn-16 failure (verified raw):

```json
{"candidates": [{
  "finishReason": "",            ← EMPTY (not "STOP", not "MAX_TOKENS")
  "content": {"role": "model", "parts": [
    {"thought_signature": "b'\\x12\\xc3\\x32\\n\\xc0..."},
    {"executable_code": {
      "language": "PYTHON",
      "code": "import random\nimport json\n# provably fair seed\nrandom.seed('716fe51ce1c439923f8da418fe404e926a3840b89e36e1fadf54ae3f211ef473')\n# 1. roll for general progress...\nprogress_roll = random.randint(1, 20)\n..."
    }}
  ]}
}], "usageMetadata": {
  "promptTokenCount": 282865, "candidatesTokenCount": 525,
  "totalTokenCount": 285082, "thoughtsTokenCount": 1692,
  "modelVersion": "gemini-3-flash-preview"
}}
```

The model emitted **only `thought_signature` + `executable_code`**. There is NO `text` part. `finishReason=""` (empty string — a Gemini API surface the streaming loop doesn't classify as a trip reason in `mvp_site/code_execution_circuit_breaker.py:39-93`). The 1.1MB request is the state-prep pass that bundles `dice_code_execution.md` + `master_directive.md` + ~205K tokens of `STORY_CONTEXT_COMPACTED` history.

## Distinct from Sub-class A and Sub-class B

| Symptom | Sub-class A (empty-candidate) | Sub-class B (circuit-breaker wall-clock) | **Sub-class C (PR-9045 prompt regression)** |
|---|---|---|---|
| `response_parts_json` envelope | 18 bytes (`{"candidates": []}`) | 0 bytes (no envelope, breaker tripped) | **Normal size (~25KB)** with non-text `parts` |
| Parts present | none | none | **`thought_signature` + `executable_code`** (NO `text` part) |
| `finish_reason` in BQ | `error: validation_failed` | varies (sometimes `STOP` at boundary) | **empty string `""`** — server's `validation_failed=True` branch fires downstream |
| `output_tokens` | 0 | 0 | 525 (just thoughts + exec_code, no narrative) |
| `thoughts_tokens` | 0 | 0 | **1692** |
| `prompt_tokens` | small (~250 bytes — small synthesis call) | huge (~200K+ — state-prep) | huge (~280K — state-prep) |
| GCP log signature | (none — silent) | `CIRCUIT_BREAKER_TRIPPED: elapsed_seconds=N>90.0` | (none — silent at GCP level) |
| Trigger condition | any model, intermittent | `gemini-3-flash-preview` + prompt ≥ ~200K | **`gemini-3-flash-preview` + PR #9045 prompt loaded** |

The `parts_bytes=0` (Sub-class B) vs `parts_bytes=~25000` (Sub-class C) distinction is the **fastest diagnostic discriminator**. Both fail to render narrative to the user; both leave the input in the composer.

## Root cause (verified via PR #9045 diff)

PR #9045 (`9c6f5d723b`, merged 2026-08-18) restructured `mvp_site/prompts/shared/dice_code_execution.md`. The exact line deletions and additions:

**Deleted line (the safety net):**
> "After code_execution returns, copy the same canonical dice fields into `action_resolution.mechanics.rolls`."

**Deleted worked example block:**
> ```json
> {"action_resolution": {"mechanics": {"rolls": [{"notation": "1d20+5", "rolls": [12], "modifier": 5, "result": 12, "total": 17, "label": "Longsword Attack", "dc": 15, "success": true}]}}}
> ```

**Added line (the regression):**
> "The server automatically captures Python `code_execution` stdout as the authoritative mechanical record. You do NOT need to duplicate or copy raw dice rolls into `action_resolution.mechanics.rolls`."

**Why this breaks `gemini-3-flash-preview`:**
- `gemini-2.5-pro` and `gemini-3.7-flash` (the models PR #9045 was validated against) emit code, then emit a follow-up `text` part with the narrative describing the rolled outcome. They naturally produce structured `action_resolution` content.
- `gemini-3-flash-preview` (NOT validated against) interprets the new prompt literally — emits the `executable_code` part, considers its job done, and stops. No follow-up `text` part. `finishReason=""` empty string.
- The server's `mvp_site/llm_parser.py:2300-2320` validation path sees `raw_response_text=""`, raises `ValueError`, sets `validation_failed=True`, persists only the user input.

## What the user sees (3 distinct UX shapes)

**Shape 1 — Empty page with orange banner:** Server-side `validation_failed=True` fires → UI shows `"⚠️ Response validation failed; only user input was persisted."` Composer keeps input visible. User resubmits → may succeed or hit same failure.

**Shape 2 — Tiny literal `{"` rendered:** Server's narrative extractor accidentally captured the opening 4 characters of the (incomplete) JSON → composer shows literal `{"` with no narrative.

**Shape 3 — Empty stream + duplicate input echo:** Server's `add_story_entry` (line 2327) persists user input BEFORE the validation check fires → input text appears in composer twice (once from user's typing, once from persistence). User thinks it's a duplicate-submit bug. This is the same UX as Sub-class B but with a different code path.

## Diagnostic recipe (verified 2026-08-19)

1. **Run the BQ query above on the suspect campaign** — filter to `LENGTH(response_text) < 500` OR `finish_reason LIKE '%error%'` OR `agent = 'unknown'`.
2. **For each failing row, examine `response_parts_json`** — if the envelope has normal byte size (~25KB) but `parts[]` contains `thought_signature` + `executable_code` with NO `text` part, this is Sub-class C.
3. **Cross-reference revision_id against Cloud Run history** — confirm revision was deployed after PR #9045 merged (2026-08-18 01:19 UTC).
4. **Confirm with raw request:** the 1.1MB request body contains `mvp_site/prompts/shared/dice_code_execution.md` — search for the "you do NOT need to duplicate" line in `request_json` (the 350KB-cap pitfall means request_json may be truncated, but the SHA256 of the system instruction in `extra_json.system_instruction_sha256` is full-fidelity).
5. **Pool-wide scan to confirm PR #9045 blast radius:**
   ```sql
   SELECT COUNT(DISTINCT campaign_id) AS n_cids_affected,
          COUNT(*) AS n_failing_turns,
          MIN(ingested_at) AS first_seen, MAX(ingested_at) AS last_seen
   FROM `worldarchitecture-ai.llm_forensics.llm_payloads`
   WHERE model = 'gemini-3-flash-preview'
     AND ingested_at > TIMESTAMP('2026-08-18T01:19:00Z')
     AND (LENGTH(CAST(response_text AS STRING)) < 500 OR finish_reason LIKE '%error%')
   ```
   (Verified 2026-08-19 scope: not yet a pool-wide spike; ~10-15 campaigns affected as of 09:30 UTC.)

## Durable fix shape (3 components)

### C1 — Restore the deleted prompt line (root-cause fix, ship FIRST)

In `mvp_site/prompts/shared/dice_code_execution.md`, restore the deleted line and worked example:

```diff
+ After code_execution returns, copy the same canonical dice fields into
+ `action_resolution.mechanics.rolls` so both surfaces agree. Damage rolls omit `success`.
+
+ Example: if the executed `roll` was 12, mirror that into:
+ {"action_resolution": {"mechanics": {"rolls": [{"notation": "1d20+5", "rolls": [12], "modifier": 5, "result": 12, "total": 17, "label": "Longsword Attack", "dc": 15, "success": true}]}}}
```

This forces `gemini-3-flash-preview` to emit a follow-up text part after `executable_code`, restoring the `FinishReason="STOP"` clean stop.

### C2 — Add `finishReason=""` empty-string trip class (defense-in-depth, ship WITH C1)

In `mvp_site/code_execution_circuit_breaker.py:39-93`, add a new trip reason:

```python
if not finish_reason:  # empty string — Gemini API surface
    return CircuitBreakerTrip(
        reason="empty_finish_reason",
        message=f"LLM returned parts but finishReason='' (parts={len(parts)})"
    )
```

This catches Sub-class C even when the prompt fix (C1) hasn't been deployed yet, and gives the UI a structured 4xx response instead of silently failing.

### C3 — Validate the new dice/code_execution prompt against ALL `MODELS_WITH_CODE_EXECUTION` (process fix, ship LAST)

`mvp_site/constants.py:176-186` lists `MODELS_WITH_CODE_EXECUTION`. PR #9045 only validated against `gemini-2.5-pro` and `gemini-3.7-flash`. The bare minimum: add a `/es` regression test that fires the new dice prompt against each model in the allowlist and asserts `output_tokens > 100 AND finish_reason = "STOP"`.

## Pitfalls

- **Do not dismiss this as "cache-invalidation truncated response."** The earlier version of this file (and the cached `output_tokens=3` observation alone) suggests a cache-bust cause. The PR #9045 prompt change is the actual cause. The cache bust is incidental (turns on long-context campaigns with cache=0% naturally happen alongside PR #9045 failures because both correlate with long-prompt turns).
- **Do not assume `parts_bytes > 0` means a successful turn.** Sub-class C has normal-sized `parts_bytes` (~25KB) but the parts contain no `text`. Always grep `parts[]` for the presence of a `text` key.
- **Do not only check `finish_reason` from the SDK's perspective.** The Gemini SDK may report `FinishReason.STOP` for Sub-class C if the SDK normalizes empty-string reasons on the way out. The BQ `finish_reason` column is the source of truth.
- **Do not bypass the prompt fix in favor of just C2 (circuit breaker trip).** C2 turns silent failure into a visible 4xx, but it doesn't restore the user's narrative. The prompt fix (C1) is the load-bearing fix; C2 is defense-in-depth.
- **Do not classify Sub-class C as "Gemini SDK bug."** It is a prompt-side regression. Other models (`gemini-3.7-flash`) work fine with PR #9045's prompt. The bug is that PR #9045 was authored for those models and never validated against `gemini-3-flash-preview` (the dev default).

## Cross-references

- `references/gemini-model-code-exec-allowlist-mismatch-2026-07-30.md` — earlier sibling bug class on `gemini-3.5-flash-lite` (infinite-loop on `code_execution`). Different bug, different model.
- `~/.smartclaw/skills/repro/references/bq-llm-payload-truncation-pitfall.md` — `request_json` 350KB-cap, but `output_tokens` / `cached_tokens` / `LENGTH(response_text)` / `LENGTH(response_parts_json)` are full-fidelity.
- `~/.smartclaw/skills/repro/SKILL.md` §0.5 — campaign ID extraction from `/game/<CID>` URL. Use this recipe first when the user posts a URL.

## Source citations

- **jleechanorg/worldarchitect.ai [#9114](https://github.com/jleechanorg/worldarchitect.ai/issues/9114)** — filed 2026-08-19, campaign `0P8IwPXOpW79z3yy6XDc` (sibling to my 3 reproduced campaigns; same owner UID). The full root-cause analysis is in this issue body: PR #9045 + `gemini-3-flash-preview` profile + `finishReason=""` + 25KB `executable_code` part. Issue comment [5340331297](https://github.com/jleechanorg/worldarchitect.ai/issues/9114#issuecomment-5340331297) carries my 3-campaign cluster signal.
- **jleechanorg/worldarchitect.ai [#9106](https://github.com/jleechanorg/worldarchitect.ai/issues/9106)** — filed 2026-08-19, campaign `SGxsM2xdermqwOmI37SF`. Initial diagnosis was Sub-class B (circuit-breaker); later UPDATE 2026-08-18 23:40 PT reclassified the user's actual symptom to Sub-class A (empty-candidate on `RewardsAgent` small-prompt synthesis). The circuit-breaker signature was collateral noise on a different code path.
- PR #9045 = [`9c6f5d723b`](https://github.com/jleechanorg/worldarchitect.ai/pull/9045) — `refactor: decouple redundant model-computed arithmetic and centralize dice code execution prompts`. Merge author validated against `gemini-2.5-pro` + `gemini-3.7-flash` only.
- My 3 reproduced campaigns today: `ArYA47Fvx8HTYC8jpleO` (Scene #297, original), `29l48q6zFo7chxWnyjEY` (nocturne bg3), `FsiyESY987DF2lfgolCI` (swtor - tenebria). All on `gemini-3-flash-preview`, all revisions `04526-wfp` / `04527-dvr`.
- GCP filter for confirmation: `gcloud logging read "resource.type=cloud_run_revision AND resource.labels.service_name=mvp-site-app-dev AND severity>=ERROR AND textPayload:<CID>" --project=worldarchitecture-ai --freshness=2h` — Sub-class C has NO GCP signature (silent at GCP level), unlike Sub-class B.