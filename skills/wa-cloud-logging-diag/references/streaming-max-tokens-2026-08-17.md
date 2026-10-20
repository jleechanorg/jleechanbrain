# Streaming MAX_TOKENS corner case — campaign `Mz4s5zy30noDnSgScPJH`

**Date:** 2026-08-17
**Operator:** Jeffrey Lee-Chan (Slack C0BDEAJH8PK/1786939007.538329)
**Surface:** `mvp-site-app-dev` (`https://mvp-site-app-dev-i6xf2p72ka-uc.a.run.app/game/Mz4s5zy30noDnSgScPJH`)
**User symptom:** iPhone Safari "Calculating outcomes..." spinner never resolves after streaming response appears to complete.

## Symptom

User typed a turn into the planning block ("Cold Silence" mode, Thought/Plan button), clicked Send, and saw the prose stream in fully (~10-15 seconds of streaming text). The "Calculating outcomes..." spinner appeared but never resolved — no planning block came back, no "Send" became re-enabled. They opened the URL on desktop and observed the same hang.

This is NOT a "stream cut off" symptom — the SSE stream completed naturally server-side. It's "stream completed without the structured `state_updates` close the client needs to advance the turn."

## What GCP showed

**One streaming POST**, on `mvp-site-app-dev-04393-v2p` (commit `c4ba6ab`):

```
POST /game/Mz4s5zy30noDnSgScPJH/interaction/stream
  wall_clock    = 253.13 s
  http_status   = 200
  response_size = 1,209,870 bytes
  llm_chunks    = 1957
  user_agent    = Mozilla/5.0_(iPhone;_CPU_iPhone_OS_26_6_0_like_Mac;_...)  (mobile Safari)
```

**STREAM_TIMING log line:**

```
campaign_id=Mz4s5zy30noDnSgScPJH | STREAM_TIMING | token_calculation: 0.000s | prompt_tokens=181020 system_tokens=96322 max_output=50000
```

**First chunk at +18.7s wall-clock**, then 1957 chunks streamed over the next 234s. Server-side POST closed cleanly at +253s with HTTP 200.

## What BQ showed (the smoking gun)

```sql
SELECT FORMAT_TIMESTAMP('%Y-%m-%dT%H:%M:%SZ', ingested_at) AS ts,
       agent, finish_reason,
       output_tokens, prompt_tokens, cached_tokens, story_history_entry_count
FROM `worldarchitecture-ai.llm_forensics.llm_payloads`
WHERE campaign_id = 'Mz4s5zy30noDnSgScPJH'
ORDER BY ingested_at DESC LIMIT 5;
```

| ts | agent | event_type | finish_reason | output_tokens | prompt_tokens | cached_tokens | story_history_entry_count |
|---|---|---|---|---|---|---|---|
| 2026-08-17T03:58:56Z | CombatAgent | stream_story_with_game_state | success | 49308 | 313560 | 236477 | NULL |
| 2026-08-17T03:58:54Z | CombatAgent | gameplay_streaming | **FinishReason.MAX_TOKENS** | **49308** | 313560 | 236477 | **40** |

The LLM hit `MAX_TOKENS` at **49,308 / 50,000** output tokens. The 2nd row (the `stream_story_with_game_state` parse) recorded `success` because the parser silently accepted the truncated final chunk, but the structured `state_updates` close was never emitted by the model — so the planning layer had nothing to schedule against.

## Pool-wide prevalence — NOT a regression

```sql
SELECT
  CASE WHEN finish_reason = 'FinishReason.MAX_TOKENS' THEN 'MAX_TOKENS' ELSE 'NORMAL_STOP' END AS bucket,
  COUNT(*) AS n
FROM `worldarchitecture-ai.llm_forensics.llm_payloads`
WHERE ingested_at >= TIMESTAMP("2026-08-16T00:00:00Z")
  AND agent IN ("StoryModeAgent","CombatAgent","HeavyDialogAgent","DialogAgent","PlanningAgent","RewardsAgent")
GROUP BY bucket;
```

| bucket | n |
|---|---|
| NORMAL_STOP | 1169 |
| MAX_TOKENS | 5 |

**5/1174 (0.4%)** of agent-streaming calls hit MAX_TOKENS across the last 24h. Distinct campaigns, distinct stories — long-context corner case, not a deploy regression. Healthy cache hit ratio (75.4% on this campaign) rules out the cache-starvation latency class.

## Why the user perceived "seems finished but never completes"

1. **iOS Safari `fetch()` streamed all 1957 chunks** (~1.2 MB of prose). User reads the prose as "the response is done."
2. **Server-side handler returned HTTP 200** with a clean SSE close.
3. **But the `state_updates` close was never emitted** because the model ran out of tokens mid-generation. The combat agent's parser still wrote a `success` row because it accepted the truncated final chunk as a valid parse — but the structured payload was empty.
4. **The client's "Calculating outcomes..." spinner is keyed on the planning step**, NOT on the SSE close. It waits for the next `/interaction/stream` round-trip, which never comes because the server-side pipeline couldn't determine what turn to schedule next.
5. **User clicks Send again** → pipeline can't proceed → spinner sits forever.

## Three durable fix shapes (presented as user options, no autonomous action taken)

1. **Reroll the turn** — fastest path. Truncated branch gets pruned; LLM usually finishes a turn this size in <2 attempts. User option.
2. **Bump `max_output` above 50K for `CombatAgent` streaming** — fixes the corner case but adds wall-clock latency (current ~250s POST → ~360-450s). Code change.
3. **Add a `story_history_entry_count > N` turn-size guard on combat** — force a story compaction before the next LLM call when the trunk fills up. Verified threshold appears to be ~30 entries for `CombatAgent` (this campaign already at 40). Code change, fixes underlying cause.

**Operator decision pending.** No PR filed. No issue filed. No bead filed (operational, not campaign-state bug — `/repro` does not apply).

## BQ query gotchas verified this session

1. **`gameplay_streaming` is `event_type`, NOT `agent`.** The streaming LLM call records `agent=CombatAgent`. `WHERE agent = 'gameplay_streaming'` returns 0 rows; `WHERE event_type = 'gameplay_streaming'` returns the right rows.

2. **`_PARTITIONTIME > TIMESTAMP('2026-08-16T03:00:00Z')` returns 0 rows** even when data exists. BQ partitions are bound at UTC midnight; `TIMESTAMP(non-midnight)` resolves to the partition's timestamp but `>` excludes it, so the entire day's data is skipped. Use `ingested_at >= TIMESTAMP(...)` for arbitrary windows, OR `_PARTITIONTIME >= TIMESTAMP('YYYY-MM-DD')` with date-only strings.

3. **`bq query --format=csv` chained with `&&` silently drops stdout.** Verified `cd / && unset PYTHONPATH && bq query ... --format=csv` → empty stdout, exit 0, no stderr. Workaround: write SQL to file via heredoc, pipe via stdin (`bq query --format=csv < /tmp/q.sql`), or use `--format=pretty`.

## Full transcript

Slack thread `C0BDEAJH8PK/1786939007.538329` — operator message: "Run /repro the response streams and seems finished but never completes investigate gcp logs https://mvp-site-app-dev-i6xf2p72ka-uc.a.run.app/game/Mz4s5zy30noDnSgScPJH" + iPhone screenshot of "Calculating outcomes..." spinner.

Agent diagnostic reply at `ts=1786939558.436149` (Slack `C0BDEAJH8PK` thread `1786939007.538329`).