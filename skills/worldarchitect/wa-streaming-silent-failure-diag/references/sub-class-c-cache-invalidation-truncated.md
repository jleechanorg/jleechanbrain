# Sub-class C — Cache-invalidation truncated 3-token response

**Verified 2026-08-19, campaign `FsiyESY987DF2lfgolCI` (swtor - tenebria, 490 entries), turn @ 09:24:41 PT.** This is the third distinct streaming-failure sub-class discovered on WA; Sub-class A is empty-candidate `{"candidates": []}` (18-byte parts), Sub-class B is circuit-breaker wall-clock, **Sub-class C is a 3-output-token truncated `FinishReason.STOP` that fires on the same turn the implicit prompt cache invalidated**.

## Signature (verified)

BQ `worldarchitecture-ai.llm_forensics.llm_payloads`:

```sql
SELECT FORMAT_TIMESTAMP('%Y-%m-%dT%H:%M:%SZ', ingested_at) AS ts,
  campaign_id, agent, model, finish_reason,
  output_tokens, prompt_tokens, cached_tokens,
  ROUND(100.0 * cached_tokens / NULLIF(prompt_tokens, 0), 1) AS cache_pct,
  LENGTH(response_text) AS resp_bytes,
  LENGTH(response_parts_json) AS parts_bytes,
  SUBSTR(response_text, 1, 80) AS resp_sample
FROM `worldarchitecture-ai.llm_forensics.llm_payloads`
WHERE campaign_id = '<CAMPAIGN_ID>'
  AND event_type = 'gameplay_streaming'
  AND ingested_at >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 48 HOUR)
ORDER BY ingested_at DESC
```

Distinctive row shape on the failing turn (verified 2026-08-19, FsiyESY987DF2lfgolCI, gemini-3-flash-preview, GodModeAgent):

| col | Sub-class A | Sub-class B | **Sub-class C** |
|---|---|---|---|
| `finish_reason` | `error: validation_failed` | varies (STOP at boundary) | **`FinishReason.STOP`** |
| `output_tokens` | 0 | 0 (circuit-broken) | **3** (or <50) |
| `cached_tokens` | varies | varies | **0** ← the cache-bust turn |
| `response_text` | empty | empty | **"The story continues..." (22 chars)** |
| `response_parts_json` bytes | 18 (`{"candidates": []}`) | empty envelope | **~250-500 (real shape, tiny prose)** |
| `prompt_tokens` | small (~250) | huge (~200K+) | **huge (~220K, full served prompt)** |
| `latency` (from Cloud Run) | sub-1s | 90s+ (wall-clock hit) | **60-260s (full LLM roundtrip)** |

**The triple that identifies Sub-class C: `cached_tokens=0 AND output_tokens<50 AND prompt_tokens>200000`.** All three must hold.

## What the user sees

A near-empty page on a god-mode / heavy-dialog turn:

- The LLM call DID happen (full prompt sent, full prompt received, `FinishReason.STOP` not `MAX_TOKENS` or error)
- The LLM emitted 3 tokens of placeholder text ("The story continues...") and stopped cleanly
- The composer receives HTTP 200 with the 3-token `response_text`, renders the placeholder, and the user sees what looks like a 1-line "narrative" with no content
- The next turn may complete normally (cache re-warms) — the failure is intermittent, not persistent

This is **distinct from the Sub-class A empty-candidate case** because:

- Sub-class A: server marks the turn as `error: validation_failed` (visible in BQ `finish_reason`); response parts envelope is exactly 18 bytes
- Sub-class C: server marks the turn as `success` (or `FinishReason.STOP`); the LLM actually emitted prose, just a tiny amount

This is **distinct from the Sub-class B wall-clock case** because:

- Sub-class B: 90s wall-clock circuit breaker trips; no `FinishReason` from the LLM; HTTP 200 with empty body
- Sub-class C: full LLM roundtrip completes; the LLM chose to emit 3 tokens and stop

## Root cause

The 3-token response is **NOT a Gemini SDK bug** — it is a model-side response to a **cache-invalidated prompt**. When the implicit prompt cache breaks (cached_tokens=0), the served prompt prefix has shifted, and the LLM re-derives the response from a slightly different starting point. On a god-mode turn with a complex retcon prompt, the LLM often emits a small "I'm thinking..." placeholder rather than the full retcon.

**The 4/11 turn failure rate in the last 2h of the FsiyESY987DF2lfgolCI session** (08:26 PT through 09:24 PT) is the smoking gun: 4 of 11 turns had `cached_tokens=0`, and those 4 turns are the only ones with the "near-empty content" symptom. Cache-warm turns (63-70% hit) take 14-49s and produce normal-length output. Cache-cold turns (0% hit) take 28-260s and produce 3-token placeholders 25% of the time.

## Diagnostic recipe (verified)

1. **Find the failing turn in the live URL** — note the timestamp from the URL header bar (e.g. `09:24 PT`).
2. **Pull the 6-10 surrounding turns in BQ** with the query above.
3. **Compute cache_pct for each turn** — if the failing turn is one of the `cached_tokens=0` rows in a sea of `cached_tokens=150000+` rows, the cache is the suspect.
4. **Check `output_tokens` on the failing turn** — if `<50`, this is Sub-class C. If `=0` with `parts_bytes=18`, this is Sub-class A. If `=0` with no `parts_bytes` and a `CIRCUIT_BREAKER_TRIPPED` line in Cloud Logging 90s prior, this is Sub-class B.
5. **Look at the user's story entry from the failing turn** — read it from Firestore via the download-campaign recipe. The 22-char "The story continues..." string is the verbatim on-disk entry from the 09:24:41 PT FsiyESY987DF2lfgolCI turn. This is the user-visible signature of Sub-class C.
6. **Confirm the pool-wide pattern** — run the pool-wide `/interaction/stream` query:
   ```bash
   gcloud logging read \
     'resource.type="cloud_run_revision" AND resource.labels.service_name="mvp-site-app-dev" AND httpRequest.requestUrl:"/interaction/stream" AND httpRequest.status=200' \
     --limit=500 --project=worldarchitecture-ai --format='value(httpRequest.latency)' --freshness=7d \
     | grep -oE '[0-9]+\.[0-9]+' | sort -n | awk '... p50 p90 max ...'
   ```
   p50 20-30s, p90 45-50s, max 100-600s is the long-context growth mode (sibling symptom of issues #9059, #7961, #8501).

## Fix shape

Sub-class C is **prompt-side, not server-side**. The fix is to re-anchor the served-prefix byte-identity so the cache hit rate stays >70% across turns. Candidate fixes (not yet shipped):

1. **SHA256-pin the system instruction prefix** — `mvp_site/prompts/narrative_system_instruction.md` is currently the canonical long-form prompt. Re-derive its served SHA from the active dev revision and diff against `origin/main` HEAD. If the prefix drifted, that's the cache-break.
2. **Move the god-mode directive array out of the dynamic-injection channel** — the `build_god_mode_directives_block()` path (per `mvp_site/agent_prompts.py:2351`) emits a 16K-30K character block on every god-mode turn; if its order or content varies, the implicit cache breaks. Mirror the `select_directives_by_budget()` pattern from `mvp_site/memory_utils.py:186` (used for `core_memories[]`).
3. **Add a `story_history_entry_count`-aware turn-size guard** — when `story_history_entry_count > 30` (verified threshold for `CombatAgent`, similar for `GodModeAgent`), force a story compaction before the next LLM call. Long-context turns correlate with both cache-miss AND truncated-response rate.

## User workaround (immediate)

- **Click "Send" again** — the truncated 3-token turn is a one-off; the next turn usually has a fresh cache re-warm and completes normally. Document this in any user-facing issue reply.
- **Avoid rapid-fire turns on a long-context campaign** — a 5-second gap between user actions lets the LLM-side cache re-anchor. The 0%-cache 4/11 turn pattern on FsiyESY987DF2lfgolCI clustered around rapid god-mode retcon turns.
- **Switch the campaign's model to `gemini-3.7-flash`** (verified clean on sibling issue #9059) — the Sub-class B wall-clock circuit breaker is less likely to fire on the 3.7-flash model. Sub-class C is not model-specific, so the workaround is partial.

## Pitfalls

- **Do not assume Sub-class A from a 0-byte response_text alone.** Sub-class A is `parts_bytes=18` (`{"candidates": []}` envelope). Sub-class C is `parts_bytes≈250-500` (real shape, tiny prose). Sub-class B is `parts_bytes=0` (envelope empty, no candidates) AND a `CIRCUIT_BREAKER_TRIPPED` line 90s prior in Cloud Logging. The 3 sub-classes have different `response_parts_json` byte sizes — measure before classifying.
- **Do not trust `FinishReason.STOP` as "successful turn."** Sub-class C emits `FinishReason.STOP` with `output_tokens=3` — the SDK's reporting layer does not distinguish between "I have 3 tokens to say" and "I had 3000 tokens and stopped at the natural boundary." A 3-token `FinishReason.STOP` on a 220K-token prompt is suspicious by definition.
- **Do not blame the user's prompt for a Sub-class C failure.** The 3-token response is a model-side response to a cache-broken prefix. Even a "perfect" prompt produces the same failure when the implicit cache is invalidated. The fix is on the prompt-assembly side, not on the user-input side.
- **Do not skip the pool-wide p50/p90 check.** Sub-class C is more visible on long-context campaigns (≥200K-token prompts). A single campaign with a 4/11 turn failure rate is a real symptom; a pool-wide spike is a deploy regression. Distinguish via Step 6 of the diagnostic recipe.

## Cross-references

- `wa-cloud-logging-diag` skill — the latency triage recipe (Step 1-4) is the same shape, this reference specializes it for the truncated-response symptom.
- `references/bq-llm-payload-truncation-pitfall.md` — `request_json` column truncation, but `output_tokens` / `cached_tokens` / `LENGTH(response_text)` are full-fidelity.
- `~/.smartclaw/skills/repro/references/bq-llm-payload-truncation-pitfall.md` §"Cross-campaign cache-hit comparison" — the cross-campaign cache-hit ratio diagnostic (Step 0.76 in `repro` SKILL.md) is the broader pattern this is a sub-class of.

## Source citations

- jleechanorg/worldarchitect.ai [#9129](https://github.com/jleechanorg/worldarchitect.ai/issues/9129) — filed 2026-08-19, campaign `FsiyESY987DF2lfgolCI`. Owner: `vnLp2G3m21PJL6kxcuAqmWSOtm73` / `jleechan@gmail.com`. Active dev revision: `mvp-site-app-dev-04527-dvr` (same content hash as `04526-wfp` immediately prior, NOT a deploy regression).
- Verbatim story entry from the 09:24:41 PT failing turn: "The story continues..." (22 chars) — this is the on-disk story entry written by the failing 3-output-token LLM call.
- BQ query template above is verified working as of 2026-08-19.
- Related (sibling symptoms, NOT same sub-class): #9059 (nocturne 273k-318k prompt tokens, cache unused), #8501 (q04GfOEl4SWnEQrFUVST 76-176s streaming latency), #7961 (dev login 30-110s, gunicorn import = cold-start).
- Related (sibling sub-classes, same skill umbrella): #9106 (Sub-class A empty-candidate on `SGxsM2xdermqwOmI37SF`), #9106 is the original sub-class-A reference case.
