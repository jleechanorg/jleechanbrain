-- WA compliance turn sampling (BigQuery)
--
-- Pulls 6 representative turn slots per campaign (1, 5, 15, 30, 60, 100 — the slots humans
-- typically analyze for cadence). Filters to story-mode turns (excludes LevelUpAgent,
-- CharacterCreationAgent, RewardsAgent informational banners, etc.).
--
-- Use ROW_NUMBER() OVER (PARTITION BY campaign_id ORDER BY ingested_at) as the per-campaign turn
-- index when the natural turn_number field is not visible.
--
-- Source table: worldarchitecture-ai.llm_forensics.llm_payloads

WITH turn_index AS (
  SELECT
    campaign_id,
    user_id,
    model,
    turn_id,
    ingested_at,
    response_text,
    prompt_tokens,
    ROW_NUMBER() OVER (PARTITION BY campaign_id ORDER BY ingested_at) AS turn_n
  FROM `worldarchitecture-ai.llm_forensics.llm_payloads`
  WHERE response_status = 'ok'
    AND response_text IS NOT NULL
    AND prompt_tokens > 1000
    AND (path LIKE '%story%' OR path LIKE '%StoryMode%')
    AND is_test = false
)
SELECT
  campaign_id,
  user_id,
  model,
  turn_n AS target_turn,
  turn_id,
  prompt_tokens,
  LENGTH(response_text) AS response_chars,
  -- Empirical compliance constructs (see scripts/wa_compliance_sampler.py)
  REGEXP_CONTAINS(response_text, r'"companion_arc_event"|"companion_arcs"') AS emits_companion_arc,
  REGEXP_CONTAINS(response_text, r'"arc_milestones"')                       AS emits_arc_milestones,
  REGEXP_CONTAINS(response_text, r'scene_event[^}]*?quest_offered|"quest_offered"') AS emits_quest_offered,
  REGEXP_CONTAINS(response_text, r'"active_mysteries"|"mystery_template"|"three_suspect"') AS emits_mystery,
  REGEXP_CONTAINS(response_text, r'"id"\s*:\s*"(custom_action|__custom_action__|freeform)"') AS emits_freeform
FROM turn_index
WHERE turn_n IN (1, 5, 15, 30, 60, 100)
ORDER BY campaign_id, turn_n
;

/*
Companion: aggregate per-campaign compliance rate.

WITH flagged AS (
  SELECT
    campaign_id,
    SUM(CAST(emits_companion_arc AS INT64)) AS sum_arc,
    SUM(CAST(emits_arc_milestones AS INT64)) AS sum_milestones,
    SUM(CAST(emits_quest_offered AS INT64)) AS sum_quest,
    SUM(CAST(emits_mystery AS INT64)) AS sum_mystery,
    SUM(CAST(emits_freeform AS INT64)) AS sum_freeform,
    COUNT(*) AS n
  FROM <result of above query>
  GROUP BY campaign_id
)
SELECT
  campaign_id,
  n,
  ROUND(100.0 * sum_arc / n, 1) AS companion_arc_pct,
  ROUND(100.0 * sum_milestones / n, 1) AS arc_milestones_pct,
  ROUND(100.0 * sum_quest / n, 1) AS quest_pct,
  ROUND(100.0 * sum_mystery / n, 1) AS mystery_pct,
  ROUND(100.0 * sum_freeform / n, 1) AS freeform_pct
FROM flagged
ORDER BY companion_arc_pct ASC;
*/
