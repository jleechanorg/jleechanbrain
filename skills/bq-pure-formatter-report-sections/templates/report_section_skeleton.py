#!/usr/bin/env python3
"""Starter skeleton for adding a BigQuery-backed section to a periodic report.

Copy this file's structure into your consumer script (e.g. into
``scripts/daily_<topic>_report.py``) and fill in the three TODOs:

  1. ``_wa_<section>_query`` — SQL string with the real-user IN-clause
  2. ``load_<section>_for_real_users`` — I/O wrapper that returns ``[]``
     on every failure path
  3. ``format_<section>`` — pure renderer, no I/O

The ``format_report(...)`` integration block and the ``main()`` glue
are included verbatim from PR #9249 (cost breakdown) so you can see the
exact wiring pattern that the parent script's existing tests assume.

The unit tests at the bottom are self-contained — copy them into
``scripts/tests/test_<your_section>.py``, replace ``format_X`` /
``_wa_X_query`` with your function names, and they pass against the
canonical repo venv in <1s.
"""

from __future__ import annotations

import os
import sys
from datetime import UTC, datetime, timedelta

# Adjust imports to match the consumer script's existing structure.
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# ----------------------------------------------------------------------------
# Module-level constants — pricing / thresholds / lookups that the formatter
# consumes. Each sibling PR in a trio-dispatch should own its OWN constant
# block and not reference constants owned by other siblings.
# ----------------------------------------------------------------------------
SECTION_PRICING = {
    "default": {"input": 0.50, "output": 1.50, "cached": 0.10},
    "category-a": {"input": 1.25, "output": 10.00, "cached": 0.31},
    # ... extend as needed ...
}


def _pricing_for(kind: str) -> dict:
    return SECTION_PRICING.get(kind, SECTION_PRICING["default"])


# ----------------------------------------------------------------------------
# Step 1 — BQ query string with the real-user IN-clause
# ----------------------------------------------------------------------------
def _wa_section_query(
    table_ref: str,
    start_iso: str,
    end_iso: str,
    real_user_uids: list[str],
) -> str:
    """BQ query: per-(user_id, kind) for the [start, end) window.

    The ``user_id IN (...)`` filter is the real-user enforcement point.
    Empty ``real_user_uids`` returns ``""`` so the caller falls back
    cleanly to "no data" rather than emitting a SQL syntax error.
    """
    if not real_user_uids:
        return ""
    uid_literals = ", ".join(
        f"'{uid.replace(chr(39), chr(39) * 2)}'" for uid in real_user_uids
    )
    return f"""
SELECT
  COALESCE(user_id, '') AS user_id,
  COALESCE(kind, '')    AS kind,
  COALESCE(SUM(prompt_tokens), 0) AS prompt_tokens,
  COALESCE(SUM(output_tokens), 0) AS output_tokens,
  COALESCE(SUM(cached_tokens), 0) AS cached_tokens,
  COUNT(*) AS turns
FROM `{table_ref}`
WHERE ingested_at >= TIMESTAMP('{start_iso}')
  AND ingested_at <  TIMESTAMP('{end_iso}')
  AND kind IS NOT NULL
  AND user_id IN ({uid_literals})
GROUP BY user_id, kind
ORDER BY prompt_tokens DESC
"""


# ----------------------------------------------------------------------------
# Step 2 — I/O wrapper. Falls back to [] on every failure path.
# ----------------------------------------------------------------------------
def load_section_for_real_users(
    target_day_utc: datetime,
    cutoff_utc: datetime,
    *,
    table_ref: str,
    real_user_uids_provider,
    bq_query_runner,
    token_provider,
) -> list[dict]:
    """Per-(user, kind) rows for the [cutoff, target) window.

    All three external collaborators are injectable for tests:
      - ``real_user_uids_provider()`` -> ``set[str]`` (Firestore-side)
      - ``bq_query_runner(sql)`` -> ``list[dict]`` (BQ-side)
      - ``token_provider()`` -> ``str | None`` (google-auth-side)
    """
    real_user_uids = sorted(real_user_uids_provider() or set())
    if not real_user_uids:
        print("  No real user UIDs resolved; section will be empty.",
              file=sys.stderr)
        return []

    token = token_provider()
    if not token:
        print("  Google auth token unavailable; skipping section.",
              file=sys.stderr)
        return []

    start_iso = cutoff_utc.strftime("%Y-%m-%d %H:%M:%S")
    end_iso = target_day_utc.strftime("%Y-%m-%d %H:%M:%S")
    sql = _wa_section_query(table_ref, start_iso, end_iso, real_user_uids)
    if not sql:
        return []

    try:
        raw_rows = bq_query_runner(sql)
    except Exception as exc:  # noqa: BLE001
        print(f"  BQ section query failed: {exc}", file=sys.stderr)
        return []

    real_uid_set = set(real_user_uids)
    out: list[dict] = []
    for row in raw_rows:
        uid = (row.get("user_id") or "").strip()
        if uid not in real_uid_set:
            continue  # defensive: BQ IN-clause already filtered
        kind = (row.get("kind") or "").strip()
        if not kind:
            continue
        try:
            out.append({
                "user_id": uid,
                "kind": kind,
                "prompt_tokens": int(row.get("prompt_tokens") or 0),
                "output_tokens": int(row.get("output_tokens") or 0),
                "cached_tokens": int(row.get("cached_tokens") or 0),
                "turns": int(row.get("turns") or 0),
            })
        except (TypeError, ValueError):
            continue
    return out


# ----------------------------------------------------------------------------
# Step 3 — Pure formatter. No I/O. No firebase_admin / google.auth / BQ.
# ----------------------------------------------------------------------------
def format_section(
    rows: list[dict],
    target_day_utc: datetime,
    cutoff_utc: datetime,
    *,
    top_n: int = 10,
) -> str:
    """Render the section. Pure — never imports I/O libraries."""
    cutoff_label = cutoff_utc.strftime("%Y-%m-%d %H:%M:%S")
    target_label = target_day_utc.strftime("%Y-%m-%d %H:%M:%S")
    lines = [
        "━" * 50,
        "� SECTION TITLE (Last 24h, UTC)",
        "━" * 50,
        f"Window: {cutoff_label} → {target_label} UTC",
        "",
    ]

    if not rows:
        lines.append("No real-user traffic in this window (or BQ query failed).")
        return "\n".join(lines)

    # Aggregate per kind, rank by cost desc.
    per_kind: dict[str, dict] = {}
    for row in rows:
        agg = per_kind.setdefault(row["kind"], {
            "prompt_tokens": 0,
            "output_tokens": 0,
            "cached_tokens": 0,
            "turns": 0,
            "known_pricing": row["kind"] in SECTION_PRICING,
        })
        agg["prompt_tokens"] += row["prompt_tokens"]
        agg["output_tokens"] += row["output_tokens"]
        agg["cached_tokens"] += row["cached_tokens"]
        agg["turns"] += row["turns"]

    kind_rows = []
    total_cost = 0.0
    for kind, agg in per_kind.items():
        rates = _pricing_for(kind)
        cost = (
            agg["prompt_tokens"] / 1_000_000 * rates["input"]
            + agg["output_tokens"] / 1_000_000 * rates["output"]
            + agg["cached_tokens"] / 1_000_000 * rates["cached"]
        )
        total_cost += cost
        kind_rows.append({
            "kind": kind,
            **agg,
            "cost_usd": cost,
        })
    kind_rows.sort(key=lambda r: r["cost_usd"], reverse=True)

    for idx, r in enumerate(kind_rows[:top_n], start=1):
        cost_str = (
            f"est ${r['cost_usd']:.2f}"
            if r["known_pricing"]
            else "est N/A — pricing not in table"
        )
        prompt_total = r["prompt_tokens"] + r["cached_tokens"]
        cached_pct = (
            f"{100.0 * r['cached_tokens'] / prompt_total:.0f}%"
            if prompt_total > 0 else "n/a"
        )
        lines.append(
            f"  {idx}. {r['kind']:<20} "
            f"{r['turns']:>7,} turns  "
            f"prompt={r['prompt_tokens']:>10,}  "
            f"cached={r['cached_tokens']:>10,} ({cached_pct:>4})  "
            f"output={r['output_tokens']:>10,}    {cost_str}"
        )

    lines.append("")
    lines.append(f"Total estimated cost (Last 24h): ${total_cost:.2f}")
    return "\n".join(lines)


# ----------------------------------------------------------------------------
# Step 4 — format_report(...) integration block (paste into your consumer)
# ----------------------------------------------------------------------------
# def format_report(
#     ...,
#     section_block: str | None = None,  # NEW kwarg
# ):
#     # ... existing rendering ...
#     lines.append("")
#     if section_block:
#         lines.append(section_block)
#         lines.append("")
#     lines.append(format_heaviest_attachment(...))
#     return "\n".join(lines)


# ----------------------------------------------------------------------------
# Step 5 — main() glue (paste into your consumer)
# ----------------------------------------------------------------------------
# parser.add_argument("--no-section", action="store_true",
#                     help="Skip the per-kind + per-token-class section")
#
# section_block: str | None = None
# if not args.no_section:
#     cutoff = now - timedelta(days=1)
#     try:
#         section_rows = load_section_for_real_users(
#             target_day_utc=now, cutoff_utc=cutoff,
#             table_ref=...,
#             real_user_uids_provider=_resolve_real_user_uids,
#             bq_query_runner=lambda sql: cost_report_lib._bq_query(
#                 cost_report_lib._get_google_token(),
#                 cost_report_lib.DEFAULT_GCP_BILLING_PROJECT, sql, timeout=30),
#             token_provider=cost_report_lib._get_google_token,
#         )
#     except Exception as exc:
#         print(f"  Section query failed: {exc}")
#         section_rows = []
#     section_block = format_section(section_rows, now, cutoff)
#
# report = format_report(..., section_block=section_block)


# ----------------------------------------------------------------------------
# Tests (paste into scripts/tests/test_<your_section>.py)
# ----------------------------------------------------------------------------
def _row(uid, kind, prompt, output, cached, turns):
    return {
        "user_id": uid, "kind": kind,
        "prompt_tokens": prompt, "output_tokens": output,
        "cached_tokens": cached, "turns": turns,
    }


if __name__ == "__main__":  # ad-hoc demo
    TARGET = datetime(2026, 8, 22, 0, 0, 0, tzinfo=UTC)
    CUTOFF = datetime(2026, 8, 21, 0, 0, 0, tzinfo=UTC)

    rows = [
        _row("u1", "category-a", 1_000_000, 100_000, 500_000, 50),
        _row("u2", "default", 10_000, 2_000, 0, 5),
        _row("u3", "category-a", 1_000_000, 100_000, 500_000, 50),
    ]
    print(format_section(rows, TARGET, CUTOFF))

    # Demonstrate the IN-clause filter at the SQL level
    sql = _wa_section_query(
        "proj.dataset.table", "2026-08-21 00:00:00", "2026-08-22 00:00:00",
        ["uid-real-1", "uid-real-2"],
    )
    print("\n--- SQL with real UIDs ---")
    print(sql)

    sql_empty = _wa_section_query(
        "proj.dataset.table", "2026-08-21 00:00:00", "2026-08-22 00:00:00",
        [],
    )
    print("\n--- SQL with empty real_uids ---")
    print(repr(sql_empty))  # '' — caller falls back to "no data"
