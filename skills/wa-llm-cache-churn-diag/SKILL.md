---
name: wa-llm-cache-churn-diag
description: Diagnoses Gemini implicit-cache churn on worldarchitect.ai /rero / reroll / streaming-lag complaints. Cache-hit ratio MUST be aggregated over >=50 turns with the correct denominator prompt_tokens + IFNULL(tool_use_tokens,0) — NOT estimated_input_tokens; a single cached_tokens == 0 reading is NOT a cache miss. Per-turn alternation is not confirmatory. Real-user baseline is ~53% against a ~66.7% structural ceiling (contents is ~33% uncacheable); 100% is unreachable. Pairs the gcloud Cloud Run httpRequest.latency static-serving check with the cache-key-buster search via SUBSTR(request_json,1,500) diff across consecutive turns.
tags: ["worldarchitect", "performance", "llm-pipeline", "gemini", "cache", "diagnosis"]
---

# LLM Cache-Churn Diagnostic (worldarchitect.ai)

The /rero / reroll / streaming-lag complaints on `mvp-site-app-dev` are sometimes a Gemini implicit-cache bug, but NOT one that a single-turn zero `cached_tokens` proves. The first check (BEFORE reading code) is the BQ cache-hit ratio, AGGREGATED over >=50 turns with the correct denominator.

## Scope and caveats

- Only ~28% of rows in `llm_payloads` carry usage metadata at all. Treat a NULL `cached_tokens` as "no data", not as "0 cached" — counting NULLs as misses fabricates a ~70% miss rate out of nothing.
- `is_test` is nullable; `is_test = FALSE` reliably excludes synthetic rows but also drops rows where the flag was never written. Row count after filtering is the conservative real-user sample.
- "Cache churn" is a per-turn alternation hypothesis. It has been REFUTED on a dataset of 322 Gemini calls across 23 runs sharing one byte-identical `systemInstruction` (sha256 prefix `c15a594c`, 368,951 chars) — see Source citations. Sporadic zeros are uncorrelated with prefix change. A per-turn zero is descriptive, not confirmatory.
- Scope limit: this refutes "a lone zero proves churn". It does NOT prove the converse. No churn-POSITIVE arm with cache telemetry exists, so real prefix churn may still have its own distinct signature nobody has measured. Do not overclaim in either direction.
- The structural ceiling is ~66.7% because `contents` is roughly 33% of every request and is uncacheable. 100% is NOT achievable and must never be the target.

## The 60-second aggregate check (>=50 turns)

```bash
bq query --nouse_legacy_sql --format=pretty "
SELECT campaign_id,
  COUNT(*) AS n,
  COUNTIF(cached_tokens IS NOT NULL) AS n_with_metadata,
  ROUND(SUM(cached_tokens) * 100.0 / NULLIF(SUM(prompt_tokens + IFNULL(tool_use_tokens,0)),0), 1) AS cache_hit_pct,
  ROUND(AVG(prompt_tokens), 0) AS avg_prompt,
  ROUND(AVG(system_instruction_tokens_est), 0) AS sys,
  ROUND(AVG(story_tokens_est), 0) AS story
FROM \`worldarchitecture-ai.llm_forensics.llm_payloads\`
WHERE campaign_id = '<CAMPAIGN_ID>'
  AND event_type = 'gameplay_streaming'
  AND model = 'gemini-3-flash-preview'
  AND cached_tokens IS NOT NULL
  AND is_test = FALSE
GROUP BY campaign_id"
```

Interpreting the result
- Pooled real-user reference: 53.22% is normal. Structural ceiling: ~66.7%. Judge a campaign by its distance from 66.7%, not from 100%.
- The denominator is `prompt_tokens + tool_use_tokens` because `toolUsePromptTokenCount` is a SEPARATELY BILLED SECOND PASS that re-sends the same prompt — dividing by `estimated_input_tokens` double-counts the prompt and inflates the ratio above 100%.
- If `n_with_metadata < 50`, the sample is too small to support an aggregate diagnosis; report `n_with_metadata` and stop.

## What a per-turn view can and cannot tell you

A per-turn table is useful for seeing the DISTRIBUTION of hits (e.g. all zeros, all partials, mostly hits with rare zeros), but per-turn alternation is NOT a confirmatory signature. On a warm prefix where every call has the same `systemInstruction`, Gemini returns sporadic `cached_tokens == 0` roughly 3-4% of the time, including MID-SEQUENCE — and ZERO alternating (0, hit, 0) triples have been observed. Treating a single zero as a miss is a false-positive diagnosis.

If any per-turn pattern rule is retained at all, it MUST be joined to an OBSERVED `system_instruction` sha256 CHANGE across the turns in question — never inferred from the zero alone.

```bash
bq query --nouse_legacy_sql --format=pretty "
SELECT FORMAT_TIMESTAMP('%H:%M:%S', ingested_at) AS t,
  cached_tokens, prompt_tokens, IFNULL(tool_use_tokens, 0) AS tool_use_tokens,
  ROUND(SAFE_DIVIDE(CAST(cached_tokens AS INT64)*100.0, NULLIF(prompt_tokens + IFNULL(tool_use_tokens,0),0)), 1) AS hit_pct
FROM \`worldarchitecture-ai.llm_forensics.llm_payloads\`
WHERE campaign_id = '<CAMPAIGN_ID>'
  AND event_type = 'gameplay_streaming'
  AND model = 'gemini-3-flash-preview'
  AND cached_tokens IS NOT NULL
  AND is_test = FALSE
ORDER BY ingested_at DESC
LIMIT 30"
```

What to ACTUALLY look for (after joining to per-turn `system_instruction` sha256):
- If the `systemInstruction` sha256 is byte-identical across the run and there are sporadic zeros, that is expected Gemini behavior, not a churn bug.
- If the `systemInstruction` sha256 ACTUALLY CHANGES between turns AND the cache_hit aggregate drops, that is a confirmed cache-buster — investigate the digsite table below.
- If every turn is at 0% with a stable prefix, that is a different bug class (cache prefix too short or routing miss).

## Static-serving vs LLM-streaming cut

Before going deeper, confirm the static layer is OK:

```bash
DEV='https://mvp-site-app-dev-i6xf2p72ka-uc.a.run.app'
curl -s -o /dev/null -w "GET /game/<id>: ttfb=%{time_starttransfer}s total=%{time_total}s\n" "$DEV/game/<CAMPAIGN_ID>"

gcloud logging read \
  "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"mvp-site-app-dev\" AND httpRequest.requestUrl:\"<CAMPAIGN_ID>/interaction/stream\" AND httpRequest.status=200" \
  --limit=15 --project=worldarchitecture-ai --format='value(timestamp,httpRequest.latency)' --freshness=2h
```

If GET /game/<id> is <300ms but /interaction/stream is >5s for any call, the LLM streaming handler is the bottleneck — proceed to the cache check.

## Where the cache-buster usually lives (for the fix investigation)

After confirming cache-buster (systemInstruction sha256 change + aggregate drop), the prompt-side investigation digsite is:

| File path | Symptom | Search pattern |
|---|---|---|
| `mvp_site/world_logic.py::_build_story_history_bundle` | story_tokens_est jumps >20% between consecutive turns | look for `truncate` / `slice` calls near story bundle assembly |
| `mvp_site/agent_prompts.py::_inject_god_mode_directive_text` | cache busts only on god-mode turns (turn_index with mode=god) | grep for direct f-string concat with user input echo |
| `mvp_site/agent_prompts.py::_compose_system_prompt` | system_instruction_tokens_est varies per turn despite no mode change | grep for `datetime.now()` / `uuid.uuid4()` / counter interpolations |

The SUBSTR diff recipe from issue #8501 thread

```bash
bq query --nouse_legacy_sql --format=csv "
SELECT FORMAT_TIMESTAMP('%H:%M:%S', ingested_at) AS t,
  cached_tokens,
  SUBSTR(REGEXP_REPLACE(request_json, r'\\\\s+', ' '), 1, 500) AS prompt_prefix_500
FROM \`worldarchitecture-ai.llm_forensics.llm_payloads\`
WHERE campaign_id = '<CAMPAIGN_ID>'
  AND event_type = 'gameplay_streaming'
  AND cached_tokens IS NOT NULL
  AND is_test = FALSE
  AND ingested_at > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 2 HOUR)
ORDER BY ingested_at"
```

Then diff the `prompt_prefix_500` between adjacent rows. The diverging character (after REGEXP_REPLACE whitespace) is the cache-buster. Cross-reference with the per-call `systemInstruction` sha256 to confirm the prefix actually changed.

## Confusion-with-precedent guard

Story-history size is NEVER the cache-buster. Visenya V8 had MORE story (14K avg) and ran FASTER (81.6% cache hit) than `6aXYric3k1IXtJIg6LjT` (23K avg story, 58% cache hit). User feedback verbatim: "Visenya V8 had more story entries and didn't have this latency". If you find yourself writing a story-compaction story, STOP and check cache_hit_pct first.

## Pitfalls

- **Don't divide by `estimated_input_tokens`.** It excludes `toolUsePromptTokenCount`, which is a separately billed second pass that re-sends the same prompt. The correct denominator is `prompt_tokens + IFNULL(tool_use_tokens, 0)`. Using the wrong denominator inflates the ratio above 100% and obscures the bug.
- **Don't treat NULL `cached_tokens` as zero.** Only ~28% of rows carry usage metadata; counting NULLs as misses fabricates a ~70% miss rate out of nothing. Every query must include `AND cached_tokens IS NOT NULL`, and the count of rows satisfying that filter is itself worth reporting.
- **Don't trust `is_test = FALSE` to be exhaustive.** The flag is nullable; `is_test = FALSE` also drops rows where the flag was never written. That is the intended conservative behavior for a real-user cohort but the row count will be lower than the raw total.
- **Don't chase per-turn alternation as confirmatory.** A sporadic per-turn zero is uncorrelated with prefix change on a warm prefix. Per-turn alternation alerts (0/hit/0) produced 12 false positives on PR #8856's 322-call constant-prefix dataset. Aggregate over >=50 turns first.
- **Don't trust `gameplay_streaming` alone.** The mirror `stream_story_with_game_state` rows have `prompt_tokens` only — the streaming metrics are on `gameplay_streaming`.
- **Don't compare across models.** `gemini-3-flash-preview` has implicit cache; some other models in this table don't have a comparable cache_hit metric. Scope by `model='gemini-3-flash-preview'`.
- **Don't read `system_instruction_tokens_est` as the source of truth.** It's an est from text length — the actual server-side prefix-keyed prefix can be longer. Use it for trend, not for byte-precise comparison.
- **Always cross-check against the campaign's actual HTTP latency**, not just the LLM call latency. A campaign with `cached_tokens` always >0 and `latency_ms` always >20s is a different bug (likely the streaming SSE handler blocking on full response, see SOUL.md `dispatch-on-install` for SSE-specific advice).
- **Don't chase 100%.** The structural ceiling is ~66.7% because `contents` is roughly 33% of every request and is uncacheable. A campaign at ~53% is normal, not broken.

## Verdict language to deliver to the user

Once confirmed (sha256 prefix changed + aggregate drop), post the diagnosis as an aggregate cache table for 3 reasons:
1. The single-turn zero pattern is unreliable on its own; an aggregate over >=50 turns joined to a prefix-sha256 change is the only confirmatory signal.
2. The sibling-campaign comparison table (campaigns at ~66% vs ~53% vs ~0%) lets the user SEE that other campaigns DON'T have the problem — which rules out "my campaign is just too big" framing.
3. Cite the live issue # reference (e.g. #8501) so the user can find the prior diagnosis from 2026-07-21 with the same root cause.

## Source citations

- jleechanorg/worldarchitect.ai #8501 (filed 2026-07-21, q04GfOEl4SWnEQrFUVST, 48.0% cache hit; sibling RMCPAPdfuErh8MgRuj6n at 81.6% — proof that story-size is not the gating lever). NOTE: those percentages were computed against the wrong denominator (`estimated_input_tokens`); they are not directly comparable to the values produced by the corrected formula above.
- 2026-08-10 live session on `6aXYric3k1IXtJIg6LjT` (per-turn cache sequence 0/54/106/55 — interpreted at the time as a per-turn churn signature). SUPERSEDED on 2026-08-15 by the 322-call / 23-run constant-prefix measurement from PR #8856: 12/322 calls reported cached_tokens == 0 (3.7%), 7 of those mid-sequence on a demonstrably warm prefix, ZERO alternating (0, hit, 0) triples. The per-turn alternation signature is no longer a confirmatory heuristic.
- session_search `20260721_014233_dc2c8ce7` — agent that filed #8501.
- Contract C1: `roadmap/nextsteps-2026-06-24-gemini-implicit-caching-audit-expanded.md:207-231` — "A single-turn `cached_content_token_count == 0` is logged but MUST NOT be interpreted as a cache miss (Gemini returns spurious 0s — `llm_service.py:2026`). Aggregate over >=50 turns."
- SOUL.md / HERMES.md "use the `safeDiag` skill" pitfall (separate concern, not this skill).
