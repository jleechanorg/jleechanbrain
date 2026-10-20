# WA Prompt / Mechanic Audit via BigQuery — Recipe

**Source:** Generated 2026-08-21 from session `C0AH3RY3DK6/p1787299543.490919` ("How often do unforeseen complications happen?"). Use when you need real fire-rate / emission-rate data to back a prompt-contract change with numbers, instead of guessing.

## When to use

The user asks a "how often does X happen" question about a WA game mechanic where:
- The mechanic is **LLM-emitted** (i.e. a prompt contract — UC, complication, scene_event, arc advancement, mood change, etc.)
- The mechanic is **not directly counted in the schema** (no `complications` count field, no `arc_advances` counter)
- You can grep `response_text` for a canonical string the LLM emits, OR a "X vs Y" threshold pattern

Do NOT use for:
- Server-side counters (use Firestore direct query — `wa-prod-data-query` skill)
- UI surface metrics (use `wa-frontend-test-guard-scoping` or similar)
- LLM cache hit rate (use `wa-llm-cache-churn-diag`)

## The 3 forced steps (any one skipped = query fails)

### Step 1 — Bypass the shadowed `bq` CLI

The Homebrew `bq` on this machine imports `credential_loader` → `wrapped_credentials` → `utils`, and there's a shadow `~/projects_other/hermes-agent/utils.py` on `PYTHONPATH` that breaks the import:

```
ImportError: cannot import name 'bq_error' from 'utils' (${HOME}/projects_other/hermes-agent/utils.py)
```

Don't try to fix it. Don't try to `unset PYTHONPATH` globally. **Bypass with the REST API:**

```python
import subprocess, json, urllib.request, os

env_clean = {k: v for k, v in os.environ.items() if k != "PYTHONPATH"}
tok = subprocess.run(
    ["gcloud", "auth", "print-access-token"],
    capture_output=True, text=True, env=env_clean, timeout=15
).stdout.strip()

# Submit a synchronous-or-async query
req = urllib.request.Request(
    "https://bigquery.googleapis.com/bigquery/v2/projects/worldarchitecture-ai/queries",
    data=json.dumps({
        "query": sql,
        "useLegacySql": False,
        "maxResults": 200,
        "timeoutMs": 180000,
    }).encode(),
    headers={
        "Authorization": f"Bearer {tok}",
        "Content-Type": "application/json",
    },
    method="POST",
)
with urllib.request.urlopen(req, timeout=180) as resp:
    body = json.loads(resp.read())

# Async poll
job_id = body["jobReference"]["jobId"]
import time
for _ in range(60):
    time.sleep(2)
    poll = urllib.request.Request(
        f"https://bigquery.googleapis.com/bigquery/v2/projects/worldarchitecture-ai/queries/{job_id}?maxResults=200",
        headers={"Authorization": f"Bearer {tok}"},
    )
    with urllib.request.urlopen(poll, timeout=30) as r2:
        st = json.loads(r2.read())
    if st.get("jobComplete"):
        rows = st.get("rows", [])
        schema = st.get("schema", {}).get("fields", [])
        # rows is list of {f: [{v: ...}, ...]} — zip with schema for column names
        break
```

**Catch HTTPError explicitly to see the real error message** — `urllib.request.HTTPError` raised by `urlopen(req)` is silently swallowed by some execute_code runners; catch and print `e.read().decode()[:2000]` to debug.

### Step 2 — `REGEXP_EXTRACT` allows only 1 capturing group

BigQuery's `REGEXP_EXTRACT` validates **per call**, even inside `COALESCE()`. A 2-group pattern errors out:

```
Regular expressions passed into extraction functions must not have more than 1 capturing group
```

Workaround: extract each captured value with its own single-group `REGEXP_EXTRACT`, then concatenate or process separately:

```sql
WITH raw AS (
  SELECT
    agent,
    REGEXP_EXTRACT(response_text, r'Complication Check: ([0-9]+) vs') AS roll_str,
    REGEXP_EXTRACT(response_text, r'vs Threshold ([0-9]+)') AS thresh_str
  FROM ...
)
```

### Step 3 — RE2 doesn't support `{n,m}?` lazy quantifiers

If you write `r'world_events[\s\S]{0,3000}?type[\s\S]{0,200}?"([^"]+)"'`, you get:

```
Cannot parse regular expression: invalid repetition size: {0,3000}?
```

Use `r'...[\s\S]*?...'` (unbounded) and rely on BQ's per-row text length cap, OR use multiple smaller queries with `OFFSET`. RE2 also doesn't support lookaheads.

## Canonical WA LLM emission patterns (verified 2026-08-21)

For `worldarchitecture-ai.llm_forensics.llm_payloads` (`is_test != TRUE`):

### Unforeseen Complication — three log-line shapes in the wild

| Pattern | Regex (single group) | Example match |
|---|---|---|
| `Complication Check: X vs Threshold Y (Triggered\|Not Triggered)` | `r'Complication Check: ([0-9]+) vs'` (roll), `r'vs Threshold ([0-9]+)'` (threshold) | `"Complication Check: 5 vs Threshold 30 (Triggered)"` |
| `Living World complication fired (Roll X vs Threshold Y)` | `r'Living World complication fired \(Roll ([0-9]+)'` (roll), `r'\(Roll [0-9]+ vs Threshold ([0-9]+)\)'` (threshold) | `Living World complication fired (Roll 25 vs Threshold 30)` |
| `Unforeseen Complication: X vs Threshold Y (Fires\|...)` | `r'Unforeseen Complication: ([0-9]+) vs'` (roll), `r'Unforeseen Complication: [0-9]+ vs Threshold ([0-9]+)'` (threshold) | `[DICE_ROLL_START]Unforeseen Complication: 9 vs Threshold 50 (Fires)` |

**Emission rate (last 30d, all agents):**
- 19,227 total LLM turns (`is_test = false`)
- 518 (2.69%) mention "complication" anywhere
- 18 (0.09%) emit the canonical `vs Threshold <N>` log
- 204 (1.06%) emit the `Unforeseen Complication` phrase
- 242 (1.26%) emit the `Complication Check` phrase
- 22 (0.11%) emit `Living World complication`

**Heaviest emitters (phrase-mention rate per agent):**
- HeavyDialogAgent 18.8%
- FactionManagementAgent 18.5%
- DialogAgent 9.8%
- RewardsAgent 7.5%
- StoryModeAgent 4.7% (surprising — the prompt's primary surface)
- CombatAgent 4.5% (the user assumes this is highest; it isn't)

### Tone signal scan (for LW events)

For Living World tone, the `world_events.background_events[]` JSON shape doesn't carry an explicit `tone` field yet (the proposed change adds it). The proxy scan uses co-occurrence of tone-keywords with the `Living World` phrase:

| Signal | Keywords (case-insensitive `LIKE`) |
|---|---|
| Antagonist | `ambush`, `attack`, `assassination`, `betrayal` |
| Positive | `ally`, `gift`, `rescue`, `blessing`, `aid` |

**Note on false-positive overlap:** "ally" and "aid" co-occur with most narrative regardless of tone, so the positive column always reads high. The signal-to-noise is better on the antagonist side.

**Emission rate (last 30d, all agents):**
- 151 total LW turns
- 51 (33.8%) have an antagonist signal
- 135 (89.4%) have a positive signal
- Worst offenders: SpicyMode 100%, CombatAgent 90.5%, FactionManagement 57.1%, HeavyDialog 28.6%, Dialog 21.7%

## The full working query (UC + LW tone, 30d)

Save this as `mvp_site/tests/fixtures/wa_uc_fire_rate_query.sql` for the PR body. Two queries:

```sql
-- UC mentions by agent
SELECT
  agent,
  COUNTIF(response_text LIKE '%complication%' OR response_text LIKE '%Complication%') AS n_any_complication,
  COUNTIF(response_text LIKE '%vs Threshold%') AS n_threshold_log,
  COUNTIF(response_text LIKE '%Unforeseen Complication%') AS n_unforeseen_phrase,
  COUNTIF(response_text LIKE '%Complication Check%') AS n_check_phrase,
  COUNT(*) AS total_turns
FROM `worldarchitecture-ai.llm_forensics.llm_payloads`
WHERE is_test != TRUE AND response_text IS NOT NULL
GROUP BY agent
ORDER BY n_any_complication DESC;

-- LW tone
SELECT
  agent,
  COUNTIF(response_text LIKE '%Living World%' AND (response_text LIKE '%ambush%' OR response_text LIKE '%attack%' OR response_text LIKE '%assassination%' OR response_text LIKE '%betrayal%')) AS n_antag,
  COUNTIF(response_text LIKE '%Living World%') AS n_lw_turns
FROM `worldarchitecture-ai.llm_forensics.llm_payloads`
WHERE is_test != TRUE AND response_text IS NOT NULL
GROUP BY agent
HAVING n_lw_turns > 0
ORDER BY n_lw_turns DESC;
```

## Pitfalls

- **Don't trust single-group patterns to match across LLM prompt variants.** The LLM emits 3 different shapes for UC. Always grep first to see what's actually in `response_text` (e.g. `REGEXP_EXTRACT_ALL(response_text, r'[^\n]{0,40}vs Threshold[^\n]{0,40}')`) before designing the count query.
- **Don't conflate the 3 pattern families.** They have different LLM-emission rates (check phrase 242 vs threshold log 18) — the **phrase count is the upper bound on system invocation**, the **threshold log count is the lower bound on canonical-form emission**.
- **Don't use `agent_mode`** — the real column is `agent` (values: `StoryModeAgent`, `HeavyDialogAgent`, `DialogAgent`, `RewardsAgent`, `GodModeAgent`, `CombatAgent`, `FactionManagementAgent`, `PlanningAgent`, `LevelUpAgent`, `SpicyModeAgent`, `DeferredRewardsAgent`, `gemini_provider.stream`, `gemini`, `unknown`).
- **Don't use `is_test` on `dice_rolls` table** — the table is empty (0 rows as of 2026-08-21). Use `llm_payloads` for emission rates.
- **Don't `bq query` from this shell** — the shadowed `utils.py` import breaks it. Use REST + gcloud bearer token.
- **Don't poll forever** — if `jobComplete` is False after 60 × 2s = 120s, print `job_id` and let the operator re-poll. Don't busy-loop.
- **Don't skip the `is_test != TRUE` filter** — test traffic inflates counts by ~30% (verified on the 19,227 turn total — the `is_test` filter matters).
- **Save the BQ numbers to disk** (`/tmp/.../fire_rate_summary.json`) so the worker can include them in the PR body without re-running the query.

## Worked example (2026-08-21)

The user's three-ask ("UC only after multiple combat successes" + "LW once per day" + "one antagonist every two weeks") was backed by:

1. Running this BQ scan to confirm 2.69% of turns mention UC, 33.8% of LW turns carry antagonist signal
2. Drafting the prompt contract changes (UC streak≥2 gate, LW cadence 24h-only, tone field)
3. Extending the existing `is_cooldown_turn` pattern in `living_world_contract.py` for server-enforced 14-day antagonist cooldown
4. Putting the BQ numbers + the predicted cut (50% UC, 50% LW, 95% antagonist) into the PR body so the change is auditable

The SQL at the top of this file is the exact query used.
