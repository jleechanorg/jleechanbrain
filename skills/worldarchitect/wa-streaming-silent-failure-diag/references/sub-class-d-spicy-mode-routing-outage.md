# Sub-class D — Spicy-Mode Model-Routing Outage

**Verified:** 2026-08-21, campaign `gJuFrUAPCfeZRnDB9xXI`, jleechanorg/worldarchitect.ai [#9238](https://github.com/jleechanorg/worldarchitect.ai/issues/9238)
**Bead:** `rev-ukkhq`
**Source user:** Jeffrey Lee-Chan (jleechan@gmail.com, UID `vnLp2G3m21PJL6kxcuAqmWSOtm73`)
**Affected SHAs / deployments:** Cloud Run revision `mvp-site-app-dev-i6xf2p72ka-uc` (no revision change required — bug is upstream-model, not code-side)

## Symptom (user-facing)

User toggles **Spicy mode ON** (top-left 🌶️ switch in campaign page) and sends any user action / `CHOICE:` action / character-creation modal-finish action. Server returns `[Error: Empty response from server]` repeatedly (typically 9+ consecutive turns in <60 seconds). Toggling Spicy OFF returns the campaign to working order on the very next turn.

User-perceived UX is **identical** to Sub-classes A (empty-candidate Gemini flake), B (circuit-breaker wall-clock), and C (PR-9045 prompt regression) — input echoed, HTTP 200 with no narrative, orange error banner. The distinguishing signal is **the Spicy toggle being ON in the user's screenshots** AND **the BQ `model` column starting with `x-ai/` (or another OpenRouter prefix)**.

## BQ signature (verified 2026-08-21)

```sql
SELECT FORMAT_TIMESTAMP('%Y-%m-%dT%H:%M:%SZ', ingested_at) AS ts,
       agent, model,
       LENGTH(request_json) AS req_bytes,
       LENGTH(response_text) AS resp_bytes,
       SUBSTR(IFNULL(response_text, ''), 1, 80) AS response_head
FROM `worldarchitecture-ai.llm_forensics.llm_payloads`
WHERE campaign_id = '<CAMPAIGN_ID>'
  AND ingested_at > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 HOUR)
ORDER BY ingested_at DESC
LIMIT 30
```

Sub-class D signature:

| ts (UTC) | agent | model | req_bytes | resp_bytes | response_head |
|---|---|---|---|---|---|
| 2026-08-22T02:44:30Z | CharacterCreationAgent | gemini-3-flash-preview | 231 | 4505 | `{"narrative":"Morning (09:00:00)...` |
| 2026-08-22T02:44:29Z | CharacterCreationAgent | gemini-3-flash-preview | 410917 | 4505 | `{"narrative":"Morning (09:00:00)...` |
| 2026-08-22T02:38:54Z | **unknown** | **x-ai/grok-4.3** | 402644 | **0** | (empty) |
| 2026-08-22T02:38:49Z | unknown | x-ai/grok-4.3 | 402644 | 0 | (empty) |
| 2026-08-22T02:38:47Z | unknown | x-ai/grok-4.3 | 402644 | 0 | (empty) |
| 2026-08-22T02:38:38Z | unknown | x-ai/grok-4.3 | 402746 | 0 | (empty) |
| 2026-08-22T02:38:34Z | unknown | x-ai/grok-4.3 | 402746 | 0 | (empty) |
| 2026-08-22T02:38:31Z | unknown | x-ai/grok-4.3 | 402746 | 0 | (empty) |
| 2026-08-22T02:38:18Z | unknown | x-ai/grok-4.3 | 402746 | 0 | (empty) |
| 2026-08-22T02:38:13Z | unknown | x-ai/grok-4.3 | 402746 | 0 | (empty) |
| 2026-08-22T02:38:11Z | unknown | x-ai/grok-4.3 | 402746 | 0 | (empty) |

Two distinct tells:

1. **`agent="unknown"`** — every OpenRouter-routed call has `agent="unknown"` because OpenRouter routes bypass the standard `agent` labeler. This is a clean separator from Sub-classes A/B/C (which all have `agent IN ('RewardsAgent','PlanningAgent','StoryModeAgent','gemini_provider.stream', ...)`).
2. **`model` starts with `x-ai/`, `meta-llama/`, `qwen/`, or another OpenRouter prefix** — confirmed by the constants file at `mvp_site/constants.py:330-333` (`OPENROUTER_MODEL_ALIASES` map).

## 24h cross-model empty-rate (verified 2026-08-21)

```sql
SELECT
  model,
  COUNT(*) AS n_calls,
  SUM(IF(LENGTH(response_text) = 0, 1, 0)) AS n_empty,
  ROUND(SUM(IF(LENGTH(response_text) = 0, 1, 0)) * 100.0 / COUNT(*), 1) AS empty_pct
FROM `worldarchitecture-ai.llm_forensics.llm_payloads`
WHERE ingested_at > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 24 HOUR)
GROUP BY model
ORDER BY n_calls DESC
LIMIT 30
```

Verified results:

| model | n_calls | n_empty | empty_pct |
|---|---|---|---|
| gemini-3-flash-preview | 842 | 13 | 1.5% |
| (empty) | 446 | 21 | 4.7% |
| Gemini 3.5 Flash (High) | 385 | 385 | 100.0% *(mock/test data, distinct model-name format with spaces)* |
| gemini-3.7-flash | 225 | 0 | 0.0% |
| **x-ai/grok-4.3** | **18** | **12** | **66.7%** |
| gemini-3.6-flash | 6 | 0 | 0.0% |
| meta-llama/llama-3.1-70b-instruct | 6 | 0 | 0.0% |
| qwen-3-235b-a22b-instruct-2507 | 4 | 0 | 0.0% |
| gemini-2.5-flash | 3 | 3 | 100.0% *(small sample)* |
| llama-3.3-70b | 3 | 0 | 0.0% |
| x-ai/grok-4.20 | 2 | 0 | 0.0% |

**`x-ai/grok-4.3` is the ONLY real model with >50% empty rate over 24h.** The 100% "Gemini 3.5 Flash (High)" is mock data (distinct model-name format). Gemini family is healthy (gemini-3.7-flash 0%, gemini-3.6-flash 0%, gemini-3-flash-preview 1.5%).

Other campaigns confirmed affected same date:
- `29l48q6zFo7chxWnyjEY` (3/3 empty) — same Grok-4.3 routing
- (additional Grok-4.3 campaigns in the 18 calls but not visible in this query because they're the same CID)

## Code path (where the routing happens)

`mvp_site/constants.py:293`:
```python
SPICY_OPENROUTER_MODEL = "x-ai/grok-4.3"
```

`mvp_site/constants.py:313-333`:
```python
# x-ai/grok-4.3: 1M context, frontier tool-calling performance, real-time
OPENROUTER_MODEL_ALIASES = {
    "x-ai/grok-4.3": "x-ai/grok-4.3",
    "x-ai/grok-4.1-fast": "x-ai/grok-4.3",
    ...
}
```

`mvp_site/constants.py:404, 440`:
```python
OPENROUTER_CONTEXT_WINDOWS = {
    "x-ai/grok-4.3": 1_000_000,  # Grok 4.3 - 1M context
}
OPENROUTER_MAX_OUTPUT_TOKENS = {
    "x-ai/grok-4.3": 30_000,
}
```

The Spicy toggle on the campaign page reads this constant and routes every LLM call through `mvp_site/llm_providers/openrouter_provider.py` instead of the standard Gemini path. When OpenRouter returns empty (upstream issue on Grok-4.3 or xAI's API), the streaming loop hits `mvp_site/llm_service.py:11311` (`STREAMING_EMPTY_RESPONSE`) and emits the `error: empty_response` StreamEvent — same path as all other empty-stream sub-classes.

## Why this is distinct from Sub-classes A/B/C

| Sub-class | agent column | model column | finish_reason | GCP signature |
|---|---|---|---|---|
| A — Empty-candidate Gemini flake | `RewardsAgent`, `PlanningAgent`, etc. | `gemini-3-flash-preview` etc. | `error: validation_failed` | none typically |
| B — Circuit-breaker wall-clock | `PlanningAgent` (long-context) | `gemini-3-flash-preview` | (cut off) | `CODE_EXECUTION_CIRCUIT_BREAKER_TRIPPED: elapsed_seconds=N>90.0` |
| C — PR-9045 prompt regression | `StoryModeAgent`, etc. | `gemini-3-flash-preview` | `""` (empty string, not "STOP") | none |
| **D — Spicy-mode model-routing outage** | **`unknown`** | **`x-ai/grok-4.3`** | (depends on upstream) | none |

The `agent="unknown"` + `model` starting with `x-ai/` combination is **unique to Sub-class D** and cannot be confused with any other sub-class.

## Verified worked example (2026-08-21, full sequence)

1. **User action:** opens campaign `gJuFrUAPCfeZRnDB9xXI` with Spicy mode ON, accepts the Ser Arion build (STR 16 / CON 14 / CHA 16 / Lvl 1 Paladin), clicks Send on `CHOICE:finish_character_creation_start_game`.
2. **Server side:** 9 consecutive calls routed to `x-ai/grok-4.3` between 19:38:11 PT and 19:38:54 PT (43 seconds). All return `resp_bytes=0`. `llm_service.py:11311` rejects each with `error: empty_response`. User sees `[Error: Empty response from server]` repeated.
3. **User workaround:** Toggles Spicy OFF (or session times out and Spicy auto-resets to default). Next `CHOICE:finish_character_creation_start_game` action at 19:44:29 PT routes to `gemini-3-flash-preview`. Same prompt, same `CharacterCreationAgent`. Returns 4505 bytes of narrative — Ser Arion's opening scene in Winter-Mourn.
4. **Confirmation:** BQ shows the same action, same prompt, two different model routings, success on Gemini vs empty on Grok-4.3. Cross-model empty-rate scan shows `x-ai/grok-4.3` at 66.7% empty (12/18 calls over 24h) vs Gemini family at <2% empty. **Diagnosis confirmed: Spicy-mode model outage, not a code-side bug.**

## Durable fix shape (recommended sequence)

### Half D1 — Auto-fallback in `llm_service.py:11311` `STREAMING_EMPTY_RESPONSE` branch (root-cause fix, ship FIRST)

In the streaming-loop empty-response path (around `mvp_site/llm_service.py:11311`), add:

```python
# Detect Spicy-mode routing (model starts with x-ai/ or other OpenRouter prefix)
import re
OPENROUTER_MODEL_PREFIXES = ("x-ai/", "meta-llama/", "qwen/", "openrouter/", "anthropic/")
is_spicy_mode_call = (
    getattr(stream_request, "model_name", "") or ""
).startswith(OPENROUTER_MODEL_PREFIXES)

if is_spicy_mode_call and not full_narrative.strip():
    # Auto-fallback: retry ONCE with the default Gemini model
    fallback_model = _DEFAULT_GEMINI_MODEL_FALLBACK  # mvp_site/constants.py:66
    logging_util.warning(
        f"🔄 SPICY_EMPTY_FALLBACK: model={stream_request.model_name} "
        f"returned empty, retrying with {fallback_model}"
    )
    # Re-dispatch the same request with fallback_model
    retry_response = _dispatch_with_model(stream_request, fallback_model)
    if retry_response and retry_response.text.strip():
        # Emit retry_response chunks instead of the empty_response error
        yield StreamEvent(type="chunk", payload={"text": chunk_text, "sequence": sequence})
        # ... continue streaming as normal
        return
    # If retry also fails, fall through to the existing empty_response error path
```

Pair with a contract test in `mvp_site/tests/test_streaming_spicy_fallback.py`:

```python
def test_spicy_empty_falls_back_to_gemini(monkeypatch):
    """When x-ai/grok-4.3 returns empty, the streaming loop should
    auto-fallback to gemini-3-flash-preview instead of returning
    error: empty_response to the user."""
    
    # Mock: first call (Grok-4.3) returns empty, second call (Gemini) returns narrative
    call_count = {"n": 0}
    def mock_dispatch(request):
        call_count["n"] += 1
        # First call: empty response (Grok-4.3)
        if call_count["n"] == 1:
            assert request.model_name == "x-ai/grok-4.3"
            return MockResponse(text="", finish_reason="stop")
        # Second call: full narrative (Gemini fallback)
        assert call_count["n"] == 2
        assert request.model_name == "gemini-3-flash-preview"
        return MockResponse(text="The wind is a blade of ice...", finish_reason="stop")
    
    monkeypatch.setattr("mvp_site.llm_service._dispatch_with_model", mock_dispatch)
    
    events = list(stream_response_with_fallback(
        user_input="CHOICE:finish_character_creation_start_game",
        campaign_id="<test_cid>",
        spicy_mode=True,
    ))
    
    # Verify the user got narrative, not error
    chunk_events = [e for e in events if e.type == "chunk"]
    error_events = [e for e in events if e.type == "error"]
    assert len(chunk_events) >= 1, "Expected narrative chunks after fallback"
    assert len(error_events) == 0, "Expected no error events after successful fallback"
```

### Half D2 — User-visible empty-rate banner (UX fix, ship WITH D1)

In `frontend_v1/app.*.js` campaign page, add telemetry:

```javascript
// Poll the last 5 turns' empty-rate from the campaign state API
const recentEmptyRate = await fetch(`/api/campaigns/${cid}/recent-empty-rate?window=5`);
const { empty_count, total_count, model } = await recentEmptyRate.json();
if (model && model.startsWith("x-ai/") && empty_count / total_count > 0.5) {
  showToast(
    `Spicy model (${model}) is returning empty responses. ` +
    `Toggle Spicy off to use Gemini.`,
    { type: "warning", duration: 10000 }
  );
}
```

Pair with backend route `/api/campaigns/<cid>/recent-empty-rate?window=5` that queries the same `llm_payloads` table.

### Half D3 — Swap `SPICY_OPENROUTER_MODEL` to a healthier model (config fix, optional)

In `mvp_site/constants.py:293`, replace `x-ai/grok-4.3` with a model that has <5% empty-rate over 24h. Verified healthy candidates on 2026-08-21:

- `meta-llama/llama-3.1-70b-instruct` (0/6 empty, n too small for confidence)
- `qwen-3-235b-a22b-instruct-2507` (0/4 empty, n too small for confidence)
- `gemini-3.7-flash` (0/225 empty, n=225 strong confidence — but this is the default model, not Spicy-specific)

**Caveat:** the n=6 and n=4 candidate models above are statistically thin. Wait for n ≥ 30 before swapping — re-run the 24h empty-rate query weekly until a candidate has n ≥ 30 and empty_pct < 5%, then swap.

## Cross-references

- `mvp_site/constants.py:293` — `SPICY_OPENROUTER_MODEL = "x-ai/grok-4.3"` (the routing default)
- `mvp_site/llm_service.py:11311` — `STREAMING_EMPTY_RESPONSE` branch (the durable-fix Half D1 target)
- jleechanorg/worldarchitect.ai [#9238](https://github.com/jleechanorg/worldarchitect.ai/issues/9238) — filed 2026-08-21, campaign `gJuFrUAPCfeZRnDB9xXI`
- bead `rev-ukkhq` in `${HOME}/projects/worldarchitect.ai/.beads/issues.jsonl`
- Parent skill: `~/.smartclaw/skills/worldarchitect/wa-streaming-silent-failure-diag/SKILL.md` — Sub-class D section
