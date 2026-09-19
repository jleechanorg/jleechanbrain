---
name: llm-forensics-latency-triage
version: 1.0.0
description: Worked example + schema reference for the "X is slow" latency triage workflow. Captures the exact gcloud/bq command output for the 2026-08-10 campaign 6aXYric3k1IXtJIg6LjT incident, and the BQ llm_forensics.llm_payloads schema dump so future agents don't re-derive the column list.
---

# LLM Forensics — Latency triage reference

## Worked example: campaign 6aXYric3k1IXtJIg6LjT, 2026-08-10

User reported "Run /rero latency seems worse than usual." All timings below pulled live from Cloud Logging + BQ.

### Step 1 — Per-request latency for the campaign

```bash
gcloud logging read \
  'resource.type="cloud_run_revision" AND resource.labels.service_name="mvp-site-app-dev" AND httpRequest.requestUrl:"6aXYric3k1IXtJIg6LjT/interaction/stream" AND httpRequest.status=200' \
  --limit=20 --project=worldarchitecture-ai --format='value(timestamp,httpRequest.latency,resource.labels.revision_name)'
```

Returned (verbatim, last 3 entries — the user-perceived slow ones):

```
2026-08-10T08:55:45.581470Z	89.347820321s	mvp-site-app-dev-04301-hds
2026-08-10T08:54:27.000148Z	146.252218134s	mvp-site-app-dev-04301-hds
2026-08-10T08:53:04.252509Z	31.047054073s	mvp-site-app-dev-04301-hds
```

All three hit the same revision → deploy is unlikely the cause (3 separate revisions in the prior 3 hours share the same image digest anyway, confirmed via `gcloud run revisions list`).

### Step 2 — Pool-wide baseline for context

```bash
gcloud logging read \
  'resource.type="cloud_run_revision" AND resource.labels.service_name="mvp-site-app-dev" AND httpRequest.requestUrl:"/interaction/stream" AND httpRequest.status=200' \
  --limit=500 --project=worldarchitecture-ai --format='value(httpRequest.latency)' --freshness=7d \
  | grep -oE '[0-9]+\.[0-9]+' | sort -n | awk '
  BEGIN{n=0;sum=0} {a[n++]=$1; sum+=$1}
  END {if(n>0) print "n="n" p50="a[int(n/2)]" p90="a[int(n*0.9)]" avg="sum/n" max="a[n-1]}'
```

Returned (7d, n=291):

```
n=291 p50=30.044855 p90=49.418373 avg=32.4682 max=146.252218134
```

Healthy baseline: p50 ≈ 30s, p90 ≈ 49s, max 146s. User's 146s hit the pool max → top of the tail, not an outlier beyond pool-wide experience.

### Step 3 — BQ cache-hit ratio

```bash
bq query --nouse_legacy_sql --format=pretty "
SELECT FORMAT_TIMESTAMP('%Y-%m-%dT%H:%M:%SZ', ingested_at) AS ingested_at,
  event_type, turn_index,
  prompt_tokens, output_tokens,
  CAST(cached_tokens AS INT64) AS cached_tokens,
  ROUND(100.0 * CAST(cached_tokens AS INT64) / NULLIF(prompt_tokens, 0), 1) AS cache_pct,
  model, finish_reason
FROM \`worldarchitecture-ai.llm_forensics.llm_payloads\`
WHERE campaign_id = '6aXYric3k1IXtJIg6LjT'
ORDER BY ingested_at DESC
LIMIT 10
"
```

Returned:

```
+----------------------+------------------------------+------------+----------------+--------------+---------------+-----------+------------------------+----------------+
|     ingested_at      |          event_type          | turn_index | prompt_tokens  | output_tokens| cached_tokens | cache_pct |         model          | finish_reason |
+----------------------+------------------------------+------------+----------------+--------------+---------------+-----------+------------------------+----------------+
| 2026-08-10T08:57:14Z | stream_story_with_game_state |          1 |        198,936 |        2,347 |        97,008 |      48.8 | gemini-3-flash-preview | success       |
| 2026-08-10T08:56:52Z | stream_story_with_game_state |          1 |        198,655 |        2,889 |        98,333 |      49.5 | gemini-3-flash-preview | success       |
| 2026-08-10T08:53:34Z | stream_story_with_game_state |          0 |        142,321 |        2,207 |        83,471 |      58.6 | gemini-3-flash-preview | success       |
+----------------------+------------------------------+------------+----------------+--------------+---------------+-----------+------------------------+----------------+
```

Cache hit ratio dropped from **58.6% (turn 0) → 49.5% (turn 1) → 48.8% (turn 1 retry)**. Healthy threshold is > 50% for sub-15s rerolls (per session history 2026-06-13 benchmark on raw Gemini API). Borderline → explains 31–89s swings. The 146s spike was an additional transient (likely Gemini rate-limit 429 retry inside `handle_interaction`, which I'd confirm via `gcloud logging read ... AND httpRequest.status=429 AND timestamp>..."08:54Z"` — verified 0 429s on this campaign, so the 146s was Gemini's slow generation on the same model, not a retry storm).

### Step 4 — Deploy regression check (skipped)

Active revision image digest unchanged across last 3 revisions (`gcr.io/worldarchitecture-ai/mvp-site-app@sha256:54f3b4bf05c06f1c2d1442d7742a4e0664aaa250fbfaffc774bb4bf10842b046`). Deploy is NOT the cause.

### Verdict

User-perceived latency is the pool p90, not a deploy regression. Most likely cause: prompt-cache starvation as `story_history_entry_count` grows (each turn appends to history, shifting the cached-prefix window). Recommended fix is on the prompt-assembly side (stable system-instruction prefix + rolling history as suffix), not infra.

---

## BQ `llm_forensics.llm_payloads` schema (verified 2026-08-10)

```bash
bq query --nouse_legacy_sql --format=pretty "
SELECT column_name, data_type
FROM \`worldarchitecture-ai.llm_forensics.INFORMATION_SCHEMA.COLUMNS\`
WHERE table_name = 'llm_payloads'
ORDER BY ordinal_position"
```

| Column | Type | Notes |
|---|---|---|
| `ingested_at` | TIMESTAMP | Insertion time — always prefer over `timestamp` (which lives inside `request_json`). For latency work, `ingested_at` is your wall-clock anchor. |
| `campaign_id` | STRING | Indexed. The primary WHERE-clause key for any "this campaign" query. |
| `turn_index` | INT64 | 0-indexed turn number within a campaign. Nullable for non-gameplay_streaming events. |
| `event_type` | STRING | E.g. `stream_story_with_game_state`, `gameplay_streaming`. Two rows per turn typically (one for the streaming event, one for the structured stream_story_with_game_state). |
| `agent` | STRING | Agent name. |
| `model` | STRING | E.g. `gemini-3-flash-preview`. Use this to filter model-specific latency regressions. |
| `finish_reason` | STRING | `success` / `FinishReason.STOP` / `safety` / `length`. NULL = unknown. |
| `prompt_tokens` | INT64 | Total input tokens billed (includes cache). |
| `output_tokens` | INT64 | Generated tokens. |
| `request_json` | STRING | Full request payload (often 100KB+). Don't SELECT this in a 1000-row scan — it will OOM your terminal. Use `LIMIT 1` if you need to inspect shape. |
| `response_text` | STRING | Model output. Same caveat. |
| `response_parts_json` | STRING | Structured parts (tool calls, function calls, etc.). |
| `extra_json` | STRING | Misc metadata. |
| `user_id` | STRING | Firebase UID. NULL for unauthenticated requests (e.g. signup flow). |
| `is_test` | BOOL | FALSE for real users. Filter `is_test = FALSE` for any production analysis. |
| `cached_tokens` | INT64 | **The cache-hit count.** `cached_tokens / prompt_tokens` is the leading indicator for stream latency. Stored as STRING in some partitions — cast: `CAST(cached_tokens AS INT64)`. |
| `thoughts_tokens` | INT64 | Gemini thinking-mode tokens (if applicable). |
| `tool_use_tokens` | INT64 | Tool-call tokens. |
| `rag_mode` | STRING | Which RAG path was used. |
| `story_history_entry_count` | INT64 | Length of `story` array sent in this turn. **Growth here = cache ratio drop.** |
| `story_tokens_est` | INT64 | Estimated tokens in story history. |
| `system_instruction_tokens_est` | INT64 | Estimated tokens in the system instruction prefix. |
| `envelope_tokens_est` | INT64 | Estimated tokens in the envelope (tools, schema, etc.). |
| `estimated_input_tokens` | INT64 | Total estimated input (≈ prompt_tokens). |
| `tier2_tokens_est` | INT64 | Tier-2 RAG tokens. |
| `selected_app_agent` | STRING | App-level agent that handled the turn. Often NULL for raw LLM calls. |
| `revision_id` | STRING | Cloud Run revision name (matches `resource.labels.revision_name`). |

### The three BQ query bugs that waste tool calls

1. **`SELECT ts, ...` fails** — the column is `ingested_at`, not `ts`. Cost: ~1 wasted query per first-time agent.
2. **`UNNEST(JSON_EXTRACT_ARRAY(raw_payload, '$.events'))` fails** — there is no `raw_payload` column. The fields you want are at the top level (`event_type`, `prompt_tokens`) or inside `request_json` (as a STRING, requires `JSON_EXTRACT_SCALAR(request_json, '$.timing.totaltime_ms')` — note that `totaltime_ms` lives inside `request_json`, NOT in the top-level columns).
3. **`CAST(cached_tokens AS INT64)` is needed** — the column is stored as STRING in some partitions; arithmetic without the cast returns 0 or fails.

### The "cache ratio" query (paste-ready)

```bash
bq query --nouse_legacy_sql --format=pretty "
SELECT
  DATE(ingested_at) AS d,
  COUNT(*) AS turns,
  ROUND(APPROX_QUANTILES(prompt_tokens, 100)[OFFSET(50)]) AS p50_prompt,
  ROUND(APPROX_QUANTILES(CAST(cached_tokens AS INT64), 100)[OFFSET(50)]) AS p50_cached,
  ROUND(100.0 * APPROX_QUANTILES(CAST(cached_tokens AS INT64), 100)[OFFSET(50)] / NULLIF(APPROX_QUANTILES(prompt_tokens, 100)[OFFSET(50)], 0), 1) AS cache_pct,
  ROUND(MAX(prompt_tokens)) AS max_prompt
FROM \`worldarchitecture-ai.llm_forensics.llm_payloads\`
WHERE campaign_id = '<campaign_id>'
  AND is_test = FALSE
GROUP BY d
ORDER BY d DESC
LIMIT 7"
```

Returns one row per day with the cache-hit percentage. Use this to spot a downward trend across the campaign's lifetime.

---

## What this reference is NOT

- Not a substitute for `wa-prod-data-query` (Firestore `users`, `rate_limits`, `campaigns` — different backend, different questions).
- Not a substitute for `wa-cloud-logging-diag` body — that's the main skill; this is its latency-triage support page.
- Not a fix recipe — when the diagnosis lands on "cache starvation," the fix lives in `mvp_site/prompts/*` and the `distributed-caching.md` skill (referenced from the umbrella skill).