# case — action_resolution warning: stale pre-#9058 entries, not a live regression

**Date:** 2026-08-19
**Reported via:** Slack `#worldai-bugs` C0BDEAJH8PK (this thread)
**PR context:** #9058 (`df86fabd`, MERGED 2026-08-19 01:17 UTC) — "fix(prompt): re-land REQUIRED RESPONSE SCHEMA section (rev-1acx5, fixes #9057 / #9021)"
**Operator hypothesis (rejected):** "dice rolls moved to code-execution, validator didn't follow"
**Actual cause:** warning text comes from old entries (May 2026) on older campaigns where the LLM never emitted `action_resolution`; live dev-GCP turns are clean.

## Symptom

Operator pasted a "Missing action_resolution field (required for player actions)" warning from the WA UI and asked where the fix PR is. The operator also asked us to pull their recent dev GCP campaigns and verify the hypothesis.

## Firestore sweep (Step 0 from `wa-llm-output-emission-false-green-watchdog` v1.5.0)

```python
import os, json
os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = os.path.expanduser("~/serviceAccountKey.json")
os.environ["WORLDAI_DEV_MODE"] = "true"
import sys
sys.path.insert(0, "${HOME}/worldarchitect.ai/mvp_site")
sys.path.insert(0, "${HOME}/worldarchitect.ai")
from clock_skew_credentials import apply_clock_skew_patch
apply_clock_skew_patch()
import firebase_admin
from firebase_admin import auth, credentials, firestore
if not firebase_admin._apps:
    firebase_admin.initialize_app(credentials.Certificate(os.path.expanduser("~/serviceAccountKey.json")))
uid = auth.get_user_by_email("jleechan@gmail.com").uid
db = firestore.client()
CIDS = [
    ("0P8IwPXOpW79z3yy6XDc", "nocturne warcraft 3 (failed req no planning b)"),
    ("ArYA47Fvx8HTYC8jpleO", "nocturne warcraft 3"),
    ("SGxsM2xdermqwOmI37SF", "nocturne warcraft 3 (code loop)"),
    ("29l48q6zFo7chxWnyjEY", "bg3 nocturne murder god v2"),
]
for cid, label in CIDS:
    docs = list(db.collection("users").document(uid).collection("campaigns")
                .document(cid).collection("story")
                .order_by("timestamp", direction=firestore.Query.DESCENDING).limit(60).stream())
    ar_present = ar_null = warn = code_exec = 0
    for d in docs:
        e = d.to_dict()
        if e.get("actor") == "user":
            continue  # LLM turns only
        ar = e.get("action_resolution")
        debug = e.get("debug_info") or {}
        if debug.get("code_execution_used"):
            code_exec += 1
        if ar is None:
            ar_null += 1
            if any("Missing action_resolution" in str(w)
                   for w in (debug.get("_server_system_warnings") or [])):
                warn += 1
        else:
            ar_present += 1
    print(f"{label[:50]:50s} ar_present={ar_present} ar_null={ar_null} warn={warn} code_exec={code_exec}")
```

## Sample output (active 5 campaigns, last ~30 LLM turns each)

```
nocturne warcraft 3 (failed req no planning b): ar_present=29 ar_null=0 warn=0 code_exec=22
nocturne warcraft 3                              ar_present=29 ar_null=0 warn=0 code_exec=22
nocturne warcraft 3 (code loop)                  ar_present=29 ar_null=0 warn=0 code_exec=22
bg3 nocturne murder god v2                       ar_present=30 ar_null=0 warn=0 code_exec=14
                                                  ---
                                              TOTALS: ar_present=117 ar_null=0 warn=0 code_exec=80
```

## Sample live entry (campaign `0P8IwPXOpW79z3yy6XDc`, 2026-08-19 06:33:35 UTC)

```json
{
  "action_resolution": {
    "mechanics": {
      "rolls": [
        {"dc": 18, "rolls": [1], "total": 15, "label": "Persuasion (Reassure Uther)", "modifier": 14, "success": false, "notation": "1d20+14"},
        {"dc": 18, "rolls": [10], "total": 24, "label": "Persuasion (Negotiate Jaina)", "modifier": 14, "success": true, "notation": "1d20+14"}
      ]
    },
    "reinterpreted": false,
    "audit_flags": []
  },
  "dice_audit_events": [
    {"dc": 18, "rolls": [1], "total": 15, "label": "Persuasion (Reassure Uther)", "source": "code_execution", "modifier": 14, "success": false, "notation": "1d20+14"},
    {"dc": 18, "rolls": [10], "total": 24, "label": "Persuasion (Negotiate Jaina)", "source": "code_execution", "modifier": 14, "success": true, "notation": "1d20+14"}
  ],
  "dice_rolls": [],
  "debug_info": {
    "code_execution_used": true,
    "executed_code": "...",
    "stdout": "...",
    "rng_verified": true,
    "dice_seed_verified": true,
    "_server_system_warnings": []
  }
}
```

Note: `dice_rolls: []` because the LLM correctly delegated the roll to code-execution, and `backfill_dice_rolls()` at `mvp_site/structured_fields_utils.py:29` is a no-op when `dice_audit_events` is also empty by the LLM's view. The validator does NOT fire here — `action_resolution` is populated with full mechanics + reinterpreted + audit_flags.

## Sweep of older campaigns (where warnings DO fire)

After confirming live behavior is clean, expand to all 1183 campaigns, look at last 100 LLM turns each:

| campaign_id8 | title                                | null_ar | warn | code_exec | last_ts                       |
|--------------|--------------------------------------|---------|------|-----------|-------------------------------|
| JEVMaM2Y     | Gaia julia v7                        | 13      | 4    | 0         | 2026-05-13                    |
| GsWU2p6Z     | My Epic Adventure 2                  | 4       | 3    | 0         | 2026-05-11                    |
| 2fSEq5hl     | My Epic Adventure                    | 3       | 2    | 0         | 2026-05-10                    |
| 4huVowBr     | Alexiel V2 (copy)                    | 13      | 1    | 0         | 2026-05-06                    |
| KQ8feC27     | Alexiel V2 (rev-knvfx-brandnew)      | 13      | 1    | 0         | 2026-05-06                    |
| ZXMGklvL     | Alexiel swtor v2                     | 2       | 1    | 0         | 2026-05-10                    |

**Pattern:** every warning-firing entry is from May 2026 (3+ months before #9058 merged on 2026-08-19), all have `code_execution_used=False`, all `gemini-3-flash-preview`. These campaigns haven't been actively played since then, so the entries are frozen with the warning baked in.

## Sample warning-firing entry (campaign `GsWU2p6Z`, 2026-05-11 21:18:38 UTC)

```json
{
  "action_resolution": null,
  "dice_audit_events": [],
  "dice_rolls": [],
  "debug_info": {
    "code_execution_used": false,
    "llm_model": "gemini-3-flash-preview",
    "_server_system_warnings": ["Missing action_resolution field (required for player actions)"]
  }
}
```

The validator fired correctly — LLM genuinely didn't emit the field. But the campaign hasn't been played since May, so the warning stays in the doc forever.

## Interpretation matrix (from SKILL.md v1.5.0 Step 0)

| warn | null_ar | last_ts    | Diagnosis                                                  |
|------|---------|------------|------------------------------------------------------------|
| > 0  | any     | months old | Stale pre-fix era; live is fine. Hard-refresh browser tab. |
| > 0  | any     | recent     | Real regression. Proceed to Step 1 (BQ drill-down).        |
| 0    | > 0     | recent     | LLM omits field but validator exempt (god-mode, char-cre). |
| 0    | 0       | recent     | Live is healthy. Warning from cache/old tab/other surface. |

## Resolution given to operator

The fix is already on `origin/main` deployed to dev GCP:
- **PR #9058** MERGED `df86fabd` 2026-08-19 01:17 UTC
- 117/117 recent LLM turns have `action_resolution` populated correctly
- 0 warnings fired across 80 code-execution turns (validator works alongside code-execution, not against it)
- Warnings still seen in the UI are from old May 2026 entries that haven't been touched since
- Suggested action: hard-refresh the browser tab on those old campaigns; if warning persists on a campaign last played after #9058 merge, then it's a real regression and Step 1 drill-down is needed

## Lesson

1. **Don't hypothesize first, sweep first.** Operator's "dice moved to code-execution, validator didn't follow" was a plausible-sounding diagnosis that the data flatly contradicted. The sweep cost ~3 minutes; the alternative (reading validator code, tracing commit graph, possibly writing a fix PR) would have cost hours and shipped a no-op patch.
2. **The validator's `_server_system_warnings` is the authoritative surface, not the entry `text` field.** Grepping the saved `.txt` archives for the warning string returns zero hits — the warning is appended to `debug_info` on the story doc, never rendered into the prose.
3. **Stale warnings live forever.** Firestore story docs are append-mostly; once `_server_system_warnings: ["Missing action_resolution field"]` is written in May 2026, it stays in every subsequent fetch of that entry. The UI sees it on every load. Hard refresh doesn't clear it because it's server-side data, not client cache. The only fixes are (a) re-running the LLM on that turn to regenerate the entry, (b) backfilling the field via a one-time Firestore script, or (c) accepting it as historical noise.

## When to fire this recipe

Use Step 0 of the umbrella skill (`wa-llm-output-emission-false-green-watchdog`) when ANY of these is true:
- User reports a recurring WA UI warning + offers a specific cause hypothesis
- User asks "where is the PR to fix this?" and the existing skill suggests a recent merged fix
- User asks "the validator doesn't follow X move" — verify before patching the validator
- User opens an old campaign tab and sees a warning from before a recent fix merged
