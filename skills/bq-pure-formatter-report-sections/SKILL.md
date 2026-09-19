---
name: bq-pure-formatter-report-sections
version: 1.0.0
author: claude/MiniMax-M3
license: MIT
description: Add a BQ-backed section to a periodic report. Trio-PR safe.
tags: [bigquery, bq, report, formatter, pure-function, trio-pr]
metadata:
  hermes:
    tags: [bigquery, bq, report, formatter, pure-function, trio-pr]
    related_skills:
      - wa-prod-data-query
      - github-pr-workflow
      - pr-cleanup-replay
      - drive-pr-to-green
      - always-pr-never-local-edit
---

# BQ-backed report sections — pure-formatter pattern + trio-PR boundary

> ## When to use this skill
>
> Load this skill BEFORE writing any new section that:
>
> 1. Is rendered into an email, Slack digest, daily/weekly summary, or any periodic report
> 2. Is backed by a BigQuery query (REST round-trip via `bigquery.googleapis.com`, gcloud SDK, or `google-cloud-bigquery`)
> 3. Touches a script that already has siblings dispatched in parallel against the same source file
>
> Triggers: "add a cost breakdown to the daily email", "BQ section for the weekly report", "show per-model / per-user breakdown in the report", "extend `scripts/daily_*_report.py` with another section", "the report is wrong — it should look at cached tokens / model / etc.".

## Overview

Periodic reports backed by BigQuery have a recurring failure shape: the agent writes a single monolithic function that does Firebase Auth → Firestore scan → google-auth token refresh → BQ REST round-trip → result aggregation → string rendering → list-of-lines concatenation. By the time tests are added, the only way to exercise the formatter is to mock all five external services. The tests are flaky, the mocks drift from real behavior, and a refactor in any of the five layers breaks tests that should be testing the renderer.

The fix is a hard split:

* `load_X_for_real_users(target_day, cutoff, **kwargs)` — does all I/O, returns rows. Falls back to `[]` on any failure (prints to stderr).
* `format_X(rows, target_day, cutoff, **kwargs)` — **pure**, no I/O, no imports of firebase_admin / google.auth / BQ. Returns the rendered string.
* `format_report(...)` accepts the rendered block as an optional kwarg and splices it in at the right point.

Tests cover `format_X` only. `load_X` is exercised indirectly by the integration cron / smoke test, not by unit tests. Result: 6 unit tests in ~0.85s with zero mocking.

## The recipe (verified 2026-08-22, PR #9249)

### Step 1 — Build the real-user UID set via Firestore, push the filter into SQL

The single most common failure in BQ-backed report sections is doing the real-user filter in Python after the BQ round-trip. BQ scans the entire window's worth of `llm_payloads` rows before you filter — 10–100× more data than necessary, slower cron runs, and bigger BigQuery bills. Push the filter into the SQL `WHERE` clause via an IN-list of UIDs.

```python
from scripts.wa_prod_data_query import _resolve_real_user_uids  # or copy the pattern

real_uids = sorted(_resolve_real_user_uids())  # set[str] from Firebase Auth + rate_limits
if not real_uids:
    return []  # empty IN-clause would match nothing; skip the query entirely

uid_literals = ", ".join(f"'{uid.replace(chr(39), chr(39)*2)}'" for uid in real_uids)
sql = f"""
SELECT user_id, model,
       SUM(prompt_tokens) AS prompt_tokens,
       SUM(output_tokens) AS output_tokens,
       SUM(cached_tokens) AS cached_tokens,
       COUNT(*)           AS turns
FROM `{llm_table}`
WHERE ingested_at >= TIMESTAMP('{start_iso}')
  AND ingested_at <  TIMESTAMP('{end_iso}')
  AND model IS NOT NULL
  AND user_id IN ({uid_literals})
GROUP BY user_id, model
"""
```

The defensive post-filter (drop any returned row whose `user_id` isn't in `real_uids`) is cheap and catches the "BQ lied / row came from outside the IN-clause" edge case. Don't skip it.

### Step 2 — `load_X_for_real_users` wraps the BQ plumbing, falls back to `[]`

```python
def load_token_breakdown_for_real_users(
    target_day_utc: datetime,
    cutoff_utc: datetime,
    *,
    llm_table: str | None = None,
) -> list[dict]:
    llm_table = llm_table or cost_report_lib.LLM_FORENSICS_TABLE
    billing_project = cost_report_lib.DEFAULT_GCP_BILLING_PROJECT

    real_user_uids = sorted(_resolve_real_user_uids())
    if not real_user_uids:
        print("  No real WA user UIDs resolved; section will be empty.",
              file=sys.stderr)
        return []

    token = cost_report_lib._get_google_token()
    if not token:
        print("  Google auth token unavailable; skipping BQ section.",
              file=sys.stderr)
        return []

    try:
        raw_rows = cost_report_lib._bq_query(token, billing_project, query, timeout=30)
    except Exception as exc:
        print(f"  BQ query failed: {exc}", file=sys.stderr)
        return []

    return [
        {
            "user_id": (row.get("user_id") or "").strip(),
            "model":   (row.get("model")   or "").strip(),
            "prompt_tokens": int(row.get("prompt_tokens") or 0),
            "output_tokens": int(row.get("output_tokens") or 0),
            "cached_tokens": int(row.get("cached_tokens") or 0),
            "turns":         int(row.get("turns")         or 0),
        }
        for row in raw_rows
        if (row.get("user_id") or "").strip() in set(real_user_uids)
        and (row.get("model") or "").strip()
    ]
```

Three fall-back-to-`[]` paths: (a) no real UIDs resolved, (b) google-auth token unavailable, (c) BQ REST round-trip failed. All print to stderr (so cron output stays clean), all return `[]` rather than raising. The caller renders the section header either way — "no data" beats "section missing".

### Step 3 — `format_X` is pure, no external imports

```python
MODEL_PRICING_USD_PER_MILLION_TOKENS = {
    "gemini-2.5-pro":   {"input": 1.25, "output": 10.00, "cached": 0.31},
    "gemini-2.5-flash": {"input": 0.075, "output": 0.30, "cached": 0.01875},
    # ...
}
MODEL_PRICING_FALLBACK_USD_PER_MILLION_TOKENS = {"input": 0.50, "output": 1.50, "cached": 0.10}

def _pricing_for_model(model: str) -> dict:
    return MODEL_PRICING_USD_PER_MILLION_TOKENS.get(
        model, MODEL_PRICING_FALLBACK_USD_PER_MILLION_TOKENS
    )

def _estimate_cost_usd(model: str, prompt: int, output: int, cached: int) -> float:
    rates = _pricing_for_model(model)
    return (
        prompt / 1_000_000 * rates["input"]
        + output / 1_000_000 * rates["output"]
        + cached / 1_000_000 * rates["cached"]
    )

def format_token_breakdown(
    rows: list[dict],
    target_day_utc: datetime,
    cutoff_utc: datetime,
    *,
    top_n: int = 10,
) -> str:
    """Pure renderer. No I/O. No firebase_admin / google.auth / BQ imports."""
    # ... aggregate by model, sort by cost desc, render multi-line block ...
```

Hard rules for the pure function:

* **No `import firebase_admin`, `import google.auth`, `import google.cloud.bigquery`** at module top level. If they're imported for the `load_*` function, the test loader imports them too — and tests now need `firebase_admin._apps` to be empty or they'll hit init errors.
* **No `print(...)` for non-error output.** Errors go to stderr; success is the returned string.
* **All aggregation lives here.** `load_*` returns raw rows; `format_*` aggregates per model / per user / per whatever the section needs.
* **Unknown values render gracefully.** Missing model name → `N/A — pricing not in table`. Missing UID → dropped at `load_*`, never reaches the formatter.

### Step 4 — Wire into `format_report(...)` as an optional kwarg

```python
def format_report(
    dau_wau_stats,
    top_users_week,
    top_users_4weeks,
    show_daily=True,
    duplicate_report=None,
    token_breakdown: str | None = None,  # NEW
):
    # ... existing rendering of Last Week / Last 4 Weeks / Top 10 Users ...
    lines.append("")
    if token_breakdown:
        lines.append(token_breakdown)
        lines.append("")
    lines.append(format_duplicate_summary(duplicate_report))
    return "\n".join(lines)
```

`token_breakdown=None` → section is omitted entirely. The caller in `main()` always passes a value (which is the rendered header + "No real-user LLM traffic in this window" body when rows are empty), but tests can pass `None` to assert the section is gated correctly.

### Step 5 — `main()` calls `load_*`, renders, passes to `format_report`

```python
parser.add_argument("--no-cost-breakdown", action="store_true",
                    help="Skip the per-model + per-token-class cost breakdown")
args = parser.parse_args()

token_breakdown_block: str | None = None
if not args.no_cost_breakdown:
    token_cutoff = now - timedelta(days=1)
    try:
        token_rows = load_token_breakdown_for_real_users(
            target_day_utc=now, cutoff_utc=token_cutoff,
        )
    except Exception as exc:
        print(f"  Token breakdown query failed: {exc}")
        token_rows = []
    token_breakdown_block = format_token_breakdown(
        token_rows, target_day_utc=now, cutoff_utc=token_cutoff,
    )

report = format_report(..., token_breakdown=token_breakdown_block)
```

Always render the section header (even when rows are empty) — operators expect the "Window: ... → ... UTC" label to appear, not a silently-dropped section.

## Section placement in the assembled report

The heaviest attachment (zip file, Markdown pair dump, etc.) goes LAST. Sections in this order:

1. Header (DAU/WAU averages from existing Top 10 blocks)
2. **Existing "Top N Users" blocks** (don't remove them — operators read these)
3. **NEW section** (the BQ-backed breakdown)
4. Heaviest attachment summary (duplicate-scene pairs, zip references, etc.)
5. Daily bar chart / 28-day breakdown (tail)

A new section landing between two existing Top N blocks forces the operator to scroll — they will. A new section at the top pushes the heaviest attachment into the most-skipped position. Slot 3 is the right answer.

## Tests — pure function only, zero mocking

```python
def test_format_X_aggregates_by_model():
    rows = [
        _row("u1", "model-a", prompt=4_000_000, output=800_000, cached=200_000, turns=200),
        _row("u2", "model-b", prompt=200_000, output=50_000, cached=200_000, turns=50),
    ]
    text = dcr.format_X(rows, TARGET_DAY, CUTOFF)
    assert "SECTION HEADER" in text
    pro_idx, flash_idx = text.find("model-a"), text.find("model-b")
    assert pro_idx < flash_idx  # cost-desc ordering

def test_format_X_says_unknown_for_unlisted_model():
    rows = [_row("u1", "gemini-99-future", ...)]
    text = dcr.format_X(rows, TARGET_DAY, CUTOFF)
    assert "pricing not in table" in text

def test_format_X_includes_cached_share_line():
    rows = [_row("u1", "model-a", prompt=1_000_000, output=200_000, cached=800_000, turns=50)]
    text = dcr.format_X(rows, TARGET_DAY, CUTOFF)
    assert "cached input share:" in text

def test_format_X_includes_real_users_only():
    sql = dcr._wa_X_query(llm_table="t", start_iso="...", end_iso="...",
                          real_user_uids=["uid-real-1", "uid-real-2"])
    assert "user_id IN" in sql
    assert "uid-real-1" in sql and "uid-fake-test" not in sql

def test_pricing_dict_contains_canonical_model():
    assert "model-a" in dcr.MODEL_PRICING_USD_PER_MILLION_TOKENS
    rates = dcr.MODEL_PRICING_USD_PER_MILLION_TOKENS["model-a"]
    assert rates["output"] > rates["input"]      # output premium
    assert rates["cached"] < rates["input"]      # caching discount

def test_format_report_includes_section_when_enabled():
    block = dcr.format_X([_row("u1", "model-a", 100_000, 10_000, 50_000, 10)],
                         TARGET_DAY, CUTOFF)
    fake_stats = {"one_week": {...}, "four_weeks": {...}}
    text = dcr.format_report(fake_stats, [], [], show_daily=False,
                              duplicate_report=None, token_breakdown=block)
    assert "SECTION HEADER" in text
    top_idx = text.find("Top N Users")
    sec_idx = text.find("SECTION HEADER")
    heavy_idx = text.find("HEAVIEST ATTACHMENT")
    assert top_idx < sec_idx < heavy_idx
```

6 tests, ~0.85s total, no mocks. The worktree typically doesn't have its own `.venv/`; run via the canonical repo's venv:

```bash
cd ${HOME}/projects/<repo>
.venv/bin/python -m pytest \
    ${HOME}/wt-<branch>/scripts/tests/test_<section>.py -q
```

## Trio-PR boundary recipe (parallel work on the same report script)

When the parent dispatcher splits a single feature into N sibling PRs that all touch `scripts/daily_*_report.py`, collisions on shared constants/functions are inevitable. The boundary recipe that worked for PRs #9248 (top-N) + #9249 (cost breakdown) + sibling turn-count:

1. **Name the constant / function each PR owns in its task prompt.** Don't say "improve the cost estimate" — say "rename `COST_PER_ENTRY` to `COST_PER_TURN`". Don't say "add a top-N section" — say "add `format_top_n_block` and call it from `format_report` between the existing Top 10 Users block and the new token breakdown section".
2. **Defer renames to a single PR.** If one PR renames `COST_PER_ENTRY` to `COST_PER_TURN`, no other PR should also touch the constant. Put the rename in the PR that has the most natural reason to make the change.
3. **Defer new module-level constants to a single PR.** Pricing tables, default thresholds, etc. Each sibling PR introduces its own constants, none reference constants owned by another PR.
4. **Test for the constant's existence, not its value.** `assert "gemini-2.5-pro" in dcr.MODEL_PRICING_USD_PER_MILLION_TOKENS` is durable; `assert dcr.MODEL_PRICING_USD_PER_MILLION_TOKENS["gemini-2.5-pro"]["input"] == 1.25` will break when Google changes pricing. Assert presence + shape (`{"input", "output", "cached"}` keys, all numeric, `output > input`, `cached < input`) — that's invariant across pricing changes.
5. **Document the boundary in the PR body.** Each PR's commit message / PR description should call out the constants and functions it owns vs. the ones it does NOT touch.

When sibling PRs merge cleanly in the order the orchestrator specifies, no conflict. When the orchestrator reorders (e.g., merge turn-count first), the cost-breakdown PR's `COST_PER_ENTRY` references auto-resolve to the renamed constant if the constant rename was a pure rename. If not, merge conflict — resolve by re-running the cost-breakdown PR's tests against the new name.

## Pitfalls

### Pitfall 1 — `load_*` does too much

Symptom: the `load_*` function also aggregates per model / per user / renders to markdown. Tests now need real BQ data to exercise aggregation logic.

Fix: `load_*` returns RAW rows (`{user_id, model, prompt_tokens, ...}`). ALL aggregation (per-model rollup, cost estimation, ranking) lives in `format_*`. The unit-testable surface stays maximal.

### Pitfall 2 — `format_*` imports `cost_report_lib`

Symptom: `format_X` works in production but tests can't import it because `cost_report_lib` triggers `firebase_admin` initialization at module load.

Fix: `cost_report_lib` is fine to import at module top level IF it's pure (no `firebase_admin._apps` check at import time). If it isn't, defer the import inside `load_*` only. The `format_*` function NEVER imports the I/O library — it only consumes the raw rows.

### Pitfall 3 — Hardcoded model list in `format_*`

Symptom: `if model == "gemini-2.5-pro": rates = ... elif model == "gemini-2.5-flash": ...`. New model = code change + new test.

Fix: dict lookup with fallback. `MODEL_PRICING_USD_PER_MILLION_TOKENS.get(model, MODEL_PRICING_FALLBACK_USD_PER_MILLION_TOKENS)`. Unknown model renders "est N/A — pricing not in table" instead of crashing.

### Pitfall 4 — Empty IN-clause hits BQ with empty result, not "skipped"

`AND user_id IN ()` is a SQL syntax error. Guard with `if not real_user_uids: return ""` (or `return []` from the loader) BEFORE building the query string.

### Pitfall 5 — `format_X` returns `None` for empty rows → silent omission

The caller (`main()`) checks `if token_rows:` before passing to `format_X`. If `format_X` returns `None` for empty rows, the section disappears. Render the header even when rows are empty — operators expect the "Window: ... → ... UTC" label.

### Pitfall 6 — The `MODEL_PRICING_*` constants drift

A silent refactor that moves `MODEL_PRICING_USD_PER_MILLION_TOKENS` into a sibling module or deletes an entry passes `pytest` if the test only asserts "pricing table exists". Add `assert "gemini-2.5-pro" in dcr.MODEL_PRICING_USD_PER_MILLION_TOKENS` to the constant-presence test so dropping a model fails CI loudly.

### Pitfall 7 — Worktree has no `.venv/`

The worktree created at `git worktree add -b feat/... origin/main` shares git internals but NOT the `venv/` directory. Run tests via the canonical repo's venv at absolute path:

```bash
cd ${HOME}/projects/<repo>
.venv/bin/python -m pytest ${HOME}/wt-<branch>/scripts/tests/test_*.py -q
```

Same pattern as `drive-pr-to-green` Pitfall 8 / `pr-cleanup-replay` Pitfall 8.

## Worked example — PR #9249 (cost breakdown, jleechanorg/worldarchitect.ai, 2026-08-22)

**Context:** The `scripts/daily_campaign_report.py` daily email rendered cost as `turn_count × $0.07` — conflated models, ignored cached input, ignored output premium. User asked: "Fix the cost report. It should look at their cached tokens and distribution between cached input input and output and the model used."

**Split:**

| Function | Lines | Imports | Tested by |
|---|---|---|---|
| `load_token_breakdown_for_real_users` | ~80 | firebase_admin, firestore, cost_report_lib (BQ) | integration cron only |
| `format_token_breakdown` | ~150 | stdlib only | unit tests |
| `_wa_token_breakdown_query` | ~25 | stdlib only | unit tests (real_user_uids IN-clause) |
| `_pricing_for_model`, `_estimate_cost_usd`, `_format_token_count` | ~30 | stdlib only | covered transitively |
| `format_report(token_breakdown=...)` integration | ~5 | existing | unit tests |

**Tests:** 6 unit tests, ~0.85s total, zero mocks. The `format_token_breakdown_includes_real_users_only` test exercises `_wa_token_breakdown_query` directly with a known `real_user_uids` set; the `format_token_breakdown_includes_cached_share_line` test exercises the formatter directly with synthetic rows.

**Trio-PR boundary:**

| PR | Owns | Does NOT touch |
|---|---|---|
| #9248 (top-N, merged) | `format_top_n_block`, `--no-top-n` flag | `COST_PER_ENTRY`, `MODEL_PRICING_*` |
| #9249 (cost breakdown, this skill's origin) | `MODEL_PRICING_*`, `load_token_breakdown_*`, `format_token_breakdown`, `--no-cost-breakdown` | `COST_PER_ENTRY` rename |
| sibling turn-count | `COST_PER_ENTRY → COST_PER_TURN` rename | `MODEL_PRICING_*`, `format_token_breakdown` |

Three sibling PRs, zero overlap on constants/functions. All three mergeable independently in any order.

## Verification checklist (run before declaring done)

- [ ] `load_*` returns `[]` on every I/O failure path (no exceptions raised)
- [ ] `format_*` has zero imports of firebase_admin / google.auth / BQ at module top level
- [ ] `format_*` accepts `rows`, `target_day_utc`, `cutoff_utc` as positional args; everything else is `**kwargs`
- [ ] Empty rows → header line still rendered, body is "No data"
- [ ] Unknown model → "est N/A — pricing not in table", no crash
- [ ] Section appears in `format_report(...)` output in the right slot (AFTER Top N, BEFORE heaviest attachment)
- [ ] `token_breakdown=None` → section omitted entirely (no header, no body)
- [ ] Unit tests run in <2s with zero mocking of external services
- [ ] `--no-<section>` CLI flag added for operators who want the pre-existing layout
- [ ] PR body documents what's owned vs. what's deferred to sibling PRs

## Related skills

- `wa-prod-data-query` — owns the `_resolve_real_user_uids()` helper this skill builds on
- `github-pr-workflow` — for the `gh pr create` / push steps
- `drive-pr-to-green` — for the post-PR drive-to-merge workflow
- `pr-cleanup-replay` — for the worktree / cherry-pick pitfalls when a sibling PR goes wrong
- `always-pr-never-local-edit` — for the "this needs to be a PR" gate
