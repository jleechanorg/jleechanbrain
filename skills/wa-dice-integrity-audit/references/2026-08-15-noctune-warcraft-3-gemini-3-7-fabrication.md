# 2026-08-15 — `noctune Warcraft 3` (CID `7HHDMPe0wNLBDTfymzfT`) chi-squared audit

## Headline
- Campaign owner: UID `vnLp2G3m21PJL6kxcuAqmWSOtm73` (Jeffrey / `jleechan@gmail.com`)
- 102 story entries, 51 user + 51 gemini turns
- 68 dice rolls parsed, all `1d20` single-die (66 in subset test)
- Combined χ² = 83.09 (df=19, critical 30.14) → **FAIL uniform at α=0.01**

## Provenance split — the actual root cause
The whole campaign's dice bias is explained by **which LLM produced each turn**, not by any single dice RNG bug:

| `debug_info.llm_model` | story docs | rng_verified=True | rng_verified=False | rng_verified=unset |
|---|---|---|---|---|
| `gemini-3-flash-preview` | 21 | **9 (43%)** | 4 (19%) | 8 |
| `gemini-3.7-flash` | **45 (67% of gemini turns)** | **0** | **0** | **45** |
| `gemini-3.6-flash` | 1 | 0 | 0 | 1 |
| unset (user turns / no debug_info) | 35 | — | — | — |

Subset χ² by provenance:

| Subset | n | mean | χ² | verdict |
|---|---|---|---|---|
| `rng_verified=True` (server RNG path) | 11 | **7.64** | 16.27 | **PASS** uniform |
| `rng_verified=False` (caught fabrication) | 0 | — | — | — |
| `rng_verified=unset` (no telemetry) | 23 | **15.39** | 63.09 | **FAIL** skewed high |

The faces from server RNG: `[1, 3, 4, 5, 6, 7, 8, 8, 12, 15, 15]` — looks fair.
The faces from `unset`: `{13: 2, 14: 6, 15: 5, 16: 4, 17: 4, 18: 1, 19: 1}` — **every single face ≥13**.

## Architectural root cause
`mvp_site/dice_strategy.py:31-39` gates `DICE_STRATEGY_CODE_EXECUTION` on:

```python
if (
    provider.lower() == "gemini"
    and (model_name in constants.MODELS_WITH_CODE_EXECUTION or force_code_exec)
):
    return DICE_STRATEGY_CODE_EXECUTION
```

`mvp_site/constants.py:155-157`:
```python
# Do not add gemini-3.6-flash or gemini-3.7-flash until the application's
# combined structured-JSON + code_execution contract is real-callstack
# verified. They use the existing native two-phase dice path meanwhile.
```

But BQ telemetry for the same campaign shows **0 of 45 `gemini-3.7-flash` calls finished with `TOO_MANY_TOOL_CALLS`** — all 45 completed cleanly with `STOP`. The exclusion comment is stale.

PR #8870 (merged 2026-08-15T20:19:40Z) titled "make gemini-3.6-... code execution models" but the actual diff **does NOT add 3.6/3.7 to `MODELS_WITH_CODE_EXECUTION`** — only rewrites the comment. The merge commit message was misleading.

## Vendor confirmation (vendor-webcheck-first)
`https://ai.google.dev/gemini-api/docs/models/gemini-3.7-flash` capability matrix (live 2026-08-15):

| Capability | 3.7 Flash |
|---|---|
| Code execution | ✅ Supported |
| Structured outputs | ✅ Supported |
| Function calling | ✅ Supported |
| Token limits | 1,048,576 in / 65,536 out |

Vendor-side, 3.7-flash works for the structured-JSON + code_execution contract. Our app excludes it.

## Per-turn ground truth sample
Firestore story doc `5bF5BwINUVIjtDvkTrdZ` (`gemini-3.7-flash`, structured-roll turn):

```python
{
  'rng_verified': None,
  'code_execution_used': None,
  'executable_code_parts': None,
  'system_prompt_chars': 536651,
  'debug_keys (7)': [agent_name, execution_path, intent_classifier,
                     llm_model, llm_provider, system_instruction_char_count,
                     system_instruction_files],
  'ar.rolls[0]': {'rolls': [15], 'total': 22, 'success': True,
                  'result': 15, 'notation': '1d20+7', 'dc': 14,
                  'modifier': 7, 'purpose': 'Stealth check'}
}
```

Roll IS in structured output, dice tool was NEVER called — narrative fabrication.

## BQ telemetry
For campaign `7HHDMPe0wNLBDTfymzfT`, model = `gemini-3.7-flash`, event_type = `gameplay_streaming`, last 7 days:
- All 45 calls finish with `FinishReason.STOP` (not `TOO_MANY_TOOL_CALLS`)
- `output_tokens` range: 378-3,389 (most ~600-2,500). A 378-token output for a `prompt=265237` call leaves no room for code_execution tool-call + tool-result text.
- Cache-hit churn: `cached_tokens` alternates 0 ↔ 143K ↔ 196K across consecutive turns at the same prefix → cache-buster pattern (separate bug, see wa-llm-cache-churn-diag).

## Environment fixes that were needed mid-session

### 1. `firestore.client()` does not exist in this venv
The skill's extractor script does:
```python
from google.cloud import firestore
db = firestore.client()
```
On the project venv (`${HOME}/worldarchitect.ai/.venv/bin/python` Python 3.12) this raises `AttributeError: module 'google.cloud.firestore' has no attribute 'client'`. The fix is `from google.cloud.firestore import Client` + `db = Client()`. Same call site lives in `/tmp/extract_one_campaign.py` (session working copy).

### 2. `WORLDAI_FIREBASE_PROJECT_ID` env override routes to wrong project
Bashrc sets `GOOGLE_CLOUD_PROJECT=ai-universe-2025` (the user's primary project, no llm_forensics dataset). With `WORLDAI_DEV_MODE=true`, the Firestore client follows `GOOGLE_CLOUD_PROJECT` instead of the service-account-key project ID. **The fix is `firebase_admin.initialize_app(cred, {"projectId": "worldarchitecture-ai"})` AND `Client(project="worldarchitecture-ai")` to force the right project.** Without this, you get `PermissionDenied: 403 Missing or insufficient permissions` on `users/{uid}/campaigns` reads even though the service account key claims `project_id: worldarchitecture-ai`.

### 3. `users` collection scan is denied
`db.collection("users").stream()` returns `403 PERMISSION_DENIED`. The correct path per `mvp_site/AGENTS.md` is **email → UID via Firebase Auth, then direct doc lookup**. Walk the user's own subcollections only.

### 4. Module-level `normalize_roll` lacks `campaign` field
Skill's `chi_squared_audit.py:test_actor_by_campaign` does `counter[(p["campaign"], actor)] += 1` — extractor must populate `p["campaign"]`. The skill's `extract_user_dice.py` reads campaign title from the loop variable; my one-campaign extractor needs the campaign name passed explicitly to `normalize_roll(r, campaign_name)`.

## Recommended fix (not yet shipped)

1. `mvp_site/constants.py` — add `gemini-3.6-flash` and `gemini-3.7-flash` to `MODELS_WITH_CODE_EXECUTION`, drop the stale exclusion comment.
2. `testing_mcp/test_gemini_37_flash_code_execution.py` — real-callstack proof: `rng_verified=True` rate on a fresh 3.7-flash gameplay turn, not just `STOP` finish reason.
3. CI guard — fail the build if `rng_verified=False` rate >5% per model in any new run.
4. Open PR off `origin/main` via claudem worker on a clean worktree.

## Proof artifacts (still on disk)
- `/tmp/jleechan_dice.json` — 68 parsed rolls, 102 story entries
- `/tmp/extract_one_campaign.py` — extraction script (single-campaign scope, with the venv patches above)
- `/tmp/audit_subsets.py` — provenance split + per-subset χ²
- All raw telemetry queried live from Firestore `worldarchitecture-ai / users/vnLp2G3m21PJL6kxcuAqmWSOtm73 / campaigns/7HHDMPe0wNLBDTfymzfT`
- BQ queries against `worldarchitecture-ai.llm_forensics.llm_payloads`
- Live fetch of `https://ai.google.dev/gemini-api/docs/models/gemini-3.7-flash`

## Cross-references
- PR #8870 merged 2026-08-15T20:19:40Z — commit body claimed "make gemini-3.6-... code execution models" but diff did not add them. Misleading commit message.
- Skill `wa-llm-cache-churn-diag` — companion for the 3.7-flash cache-buster pattern (0% / 53% / 70% alternation on stable prefix).