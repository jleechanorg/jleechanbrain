-- WA Unforeseen Complication + Living World tone — 30d audit
--
-- Source: worldarchitecture-ai.llm_forensics.llm_payloads
--   is_test = FALSE filter excludes test traffic (~30% inflation)
--   response_text is the LLM's full output (JSON sometimes wrapped in ```json fences)
--
-- Two parallel scans:
--   1. UC mentions by agent (phrase count = upper bound on system invocation)
--   2. LW tone signal (antagonist vs positive via co-occurrence keywords)
--
-- Gotchas (verified 2026-08-21):
--   * Table is `dice_rolls` not `dice_audit_events` (the latter doesn't exist)
--   * `dice_rolls` is currently EMPTY (0 rows) — use llm_payloads for emission rates
--   * `agent` is the column, not `agent_mode`
--   * `REGEXP_EXTRACT` allows only 1 capturing group per call — use COALESCE over
--     multiple single-group extracts, or split into separate SELECTs
--   * RE2 doesn't support {n,m}? lazy quantifiers — use [^X]*? or split
--   * bq CLI is shadowed by ~/projects_other/hermes-agent/utils.py — use the
--     REST API at bigquery.googleapis.com/bigquery/v2/.../queries with a
--     gcloud access token (recipe in skill wa-prompt-engineering SKILL.md)
--
-- Canonical UC log-line shapes in the wild (LLM emits 3 different patterns):
--   "Complication Check: <roll> vs Threshold <N> (Triggered|Not Triggered)"
--   "Living World complication fired (Roll <roll> vs Threshold <N>)"
--   "[DICE_ROLL_START]Unforeseen Complication: <roll> vs Threshold <N> (Fires)"
--
-- 30d baseline (as of 2026-08-21):
--   Total turns (is_test=false):     19,227
--   Any "complication" mention:        518 (2.69%)
--   Canonical "vs Threshold" log:       18 (0.09%)
--   "Unforeseen Complication" phrase:  204 (1.06%)
--   "Complication Check" phrase:       242 (1.26%)
--   "Living World complication":        22 (0.11%)
--   LW turns:                         151
--   LW with antagonist signal:          51 (33.8%)
--   LW with positive signal:           135 (89.4%)


-- PART 1: UC mentions by agent
SELECT
  agent,
  COUNTIF(response_text LIKE '%complication%' OR response_text LIKE '%Complication%') AS n_any_complication,
  COUNTIF(response_text LIKE '%vs Threshold%') AS n_threshold_log,
  COUNTIF(response_text LIKE '%Unforeseen Complication%') AS n_unforeseen_phrase,
  COUNTIF(response_text LIKE '%Complication Check%') AS n_check_phrase,
  COUNT(*) AS total_turns,
  ROUND(100.0 * COUNTIF(response_text LIKE '%complication%' OR response_text LIKE '%Complication%') / COUNT(*), 2) AS pct_with_complication
FROM `worldarchitecture-ai.llm_forensics.llm_payloads`
WHERE is_test != TRUE
  AND response_text IS NOT NULL
GROUP BY agent
ORDER BY n_any_complication DESC;


-- PART 2: LW tone signal
SELECT
  agent,
  COUNTIF(response_text LIKE '%Living World%' AND (response_text LIKE '%ambush%' OR response_text LIKE '%attack%' OR response_text LIKE '%assassination%' OR response_text LIKE '%betrayal%')) AS n_antag,
  COUNTIF(response_text LIKE '%Living World%' AND (response_text LIKE '%ally%' OR response_text LIKE '%gift%' OR response_text LIKE '%rescue%' OR response_text LIKE '%blessing%' OR response_text LIKE '%aid%')) AS n_pos,
  COUNTIF(response_text LIKE '%Living World%') AS n_lw_turns,
  ROUND(100.0 * COUNTIF(response_text LIKE '%Living World%' AND (response_text LIKE '%ambush%' OR response_text LIKE '%attack%' OR response_text LIKE '%assassination%' OR response_text LIKE '%betrayal%')) / NULLIF(COUNTIF(response_text LIKE '%Living World%'), 0), 2) AS antag_pct,
  ROUND(100.0 * COUNTIF(response_text LIKE '%Living World%' AND (response_text LIKE '%ally%' OR response_text LIKE '%gift%' OR response_text LIKE '%rescue%' OR response_text LIKE '%blessing%' OR response_text LIKE '%aid%')) / NULLIF(COUNTIF(response_text LIKE '%Living World%'), 0), 2) AS pos_pct
FROM `worldarchitecture-ai.llm_forensics.llm_payloads`
WHERE is_test != TRUE
  AND response_text IS NOT NULL
GROUP BY agent
HAVING n_lw_turns > 0
ORDER BY n_lw_turns DESC;


-- PART 3 (optional): UC roll/threshold distribution when the canonical log line fires.
-- Use 1-capturing-group REGEXP_EXTRACT (BQ RE2 limit).
-- Empty result is normal — the canonical log line is rare (~0.09% emission rate).
WITH raw AS (
  SELECT
    agent,
    REGEXP_EXTRACT(response_text, r'Complication Check: ([0-9]+) vs') AS roll_str,
    REGEXP_EXTRACT(response_text, r'vs Threshold ([0-9]+)') AS thresh_str
  FROM `worldarchitecture-ai.llm_forensics.llm_payloads`
  WHERE is_test != TRUE
    AND response_text LIKE '%vs Threshold%'
),
parsed AS (
  SELECT
    agent,
    SAFE_CAST(roll_str AS INT64) AS roll_value,
    SAFE_CAST(thresh_str AS INT64) AS threshold_pct
  FROM raw
  WHERE roll_str IS NOT NULL AND thresh_str IS NOT NULL
)
SELECT
  agent,
  roll_value,
  threshold_pct,
  COUNT(*) AS n,
  CASE
    WHEN threshold_pct < 20 THEN 'threshold_drift_bug'
    WHEN roll_value <= threshold_pct THEN 'should_fire'
    ELSE 'should_miss'
  END AS classification
FROM parsed
GROUP BY agent, roll_value, threshold_pct
ORDER BY n DESC
LIMIT 100;
