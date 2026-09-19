-- WA served-prompt size probe (BigQuery)
--
-- BigQuery truncates STRING columns to 350,000 bytes by default. The footer that BQ writes after a
-- truncation carries the original bytes (`original_bytes=...`) which lets us triangulate the actual
-- served-prompt size even when we only have the first 350K.
--
-- Three pieces of evidence in one query:
--   1. prompt_tokens — Gemini-side billable token count
--   2. BYTE_LENGTH(request_json) — the truncated bytes we actually have
--   3. REGEXP_EXTRACT(request_json, r'original_bytes=(\d+)') — the original before truncation
--
-- If original_bytes > 350000, the prompt is being clipped and we'd only see the first ~34% in BQ.
-- Use this to anchor arguments about why a prompt rule is in the bottom 25% of the served payload.

SELECT
  campaign_id,
  turn_id,
  ingested_at,
  path,
  agent,
  model,
  prompt_tokens,
  estimated_input_tokens,
  story_history_entry_count,
  -- Truncated bytes (what we actually have in BQ row)
  BYTE_LENGTH(request_json) AS bq_trunc_bytes,
  -- Original bytes (from the truncation footer BQ inserts after clips at limit_bytes=350000)
  REGEXP_EXTRACT(request_json, r'original_bytes=(\d+)') AS original_bytes,
  -- Position of the contract we're investigating, in the captured slice
  REGEXP_INSTR(request_json, r'Companion Quest Arcs') AS contract_byte_offset,
  -- Approximate position as % of the captured 350K
  ROUND(100.0 * REGEXP_INSTR(request_json, r'Companion Quest Arcs') / 350000, 2) AS contract_pct_of_captured,
  -- Position relative to the ORIGINAL size (more useful)
  CASE
    WHEN REGEXP_EXTRACT(request_json, r'original_bytes=(\d+)') IS NOT NULL THEN
      ROUND(100.0 * REGEXP_INSTR(request_json, r'Companion Quest Arcs') /
            CAST(REGEXP_EXTRACT(request_json, r'original_bytes=(\d+)') AS INT64), 2)
    ELSE NULL
  END AS contract_pct_of_original
FROM `worldarchitecture-ai.llm_forensics.llm_payloads`
WHERE campaign_id = "wc2BBcSgOljiU3vJ160A"   -- Nocturne BG3 (the median-token measurement)
  AND response_status = 'ok'
  AND prompt_tokens > 5000
  AND is_test = false
ORDER BY ABS(prompt_tokens - 279635) ASC   -- CLOSEST TO MEDIAN OF "LARGE PROMPT" TURNS
LIMIT 10
;

/*
Diagnostic interpretation (worked example from 2026-08-18):
- Median served prompt = 279,635 tokens (~1,022,868 bytes).
- BQ captures only first 350,000 bytes (34% of total).
- "Companion Quest Arcs" appears at byte offset ~327,000 in the captured slice (97% of captured).
- As % of ORIGINAL = byte 327,000 / 1,022,868 = 32% (top third-ish).
- For turns where the static file lives in the bottom 25% (offset > 768K of 1.02M), the contract is
  past the recency window and the LLM is in the lost-in-the-middle zone.

Diagnostic checklist:
1. Look at `original_bytes` — if consistently > 350K, the served prompt is being clipped by BQ exports.
   Real size is larger than what rows show.
2. Look at `contract_pct_of_original` — if > 75%, the contract is past the recency window.
3. Look at `prompt_tokens` — if > 40K, the lost-in-the-middle failure mode is already live.

Next steps if 1 + 2 + 3 all true:
- The fix is to LIFT the contract (not extend it).
- Move cadence rules to a small (~1 KB) injection file at the recency window.
- Mirror the cadence reminder on every turn-type, not just LW trigger turns.
*/
