"""Regression tests for scripts/bq_coverage_watcher.py.

Bug under test
--------------
`_per_day_is_test_null_query()` joins a `date_range` CTE (whose `d` column is
DATE, produced by `GENERATE_DATE_ARRAY`) against an aggregated subquery `t`
whose `d` column was previously projected as `CAST(DATE(ingested_at) AS STRING)`.

The `USING (d)` clause in BigQuery requires the joined columns to share the
same data type; mixing DATE and STRING yields:

    HTTP 400 — "JOIN type mismatch at column d: DATE vs STRING"

The run is aborted before the rest of the watcher executes, which is why this
silent breaker turned into "coverage check does not run at all" rather than a
visible coverage miss. This file pins the fix in place.
"""
from __future__ import annotations

import re
import sys
import types
from pathlib import Path

# `scripts/` is not on the default testpath; add it explicitly so the test can
# import the module under test without requiring an install step.
SCRIPTS_DIR = Path(__file__).resolve().parents[1] / "scripts"
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))


# Stub the google.auth modules so the test runs in fresh checkouts that do
# not have `google-auth` installed (pyproject.toml only declares it transitively
# via production use; the test never actually calls any Google API). Real
# production runs use the real modules — see `_bq_token()` in the script under
# test for the live code path.
def _install_google_auth_stubs() -> None:
    google_auth = types.ModuleType("google.auth")
    google_auth.default = lambda *args, **kwargs: (None, None)  # type: ignore[attr-defined]
    google_auth_transport = types.ModuleType("google.auth.transport")
    google_auth_transport_requests = types.ModuleType("google.auth.transport.requests")
    google_auth_transport_requests.Request = object  # type: ignore[attr-defined]
    sys.modules.setdefault("google", types.ModuleType("google"))
    sys.modules.setdefault("google.auth", google_auth)
    sys.modules.setdefault("google.auth.transport", google_auth_transport)
    sys.modules.setdefault(
        "google.auth.transport.requests", google_auth_transport_requests
    )


_install_google_auth_stubs()

import bq_coverage_watcher  # noqa: E402


def _extract_left_join_subquery(sql: str) -> str:
    """Return the body of the LEFT JOIN (...) subquery used in the per-day query.

    Matches the production pattern `LEFT JOIN (...) t USING (d)`. We anchor on
    `USING (d)` because that is the join column whose type compatibility is
    under test.
    """
    match = re.search(
        r"LEFT\s+JOIN\s*\((.*?)\)\s*t\s+USING\s*\(\s*d\s*\)",
        sql,
        re.DOTALL,
    )
    assert match is not None, (
        "Could not locate `LEFT JOIN (...) t USING (d)` block in per-day query"
    )
    return match.group(1)


def test_per_day_is_test_null_query_join_key_is_date_not_string() -> None:
    """USING (d) requires DATE=DATE. Regression for the HTTP 400 type mismatch.

    The fix replaces `CAST(DATE(ingested_at) AS STRING) AS d` with
    `DATE(ingested_at) AS d` inside the LEFT JOIN subquery so that the join
    key matches the DATE column produced by GENERATE_DATE_ARRAY.
    """
    sql = bq_coverage_watcher._per_day_is_test_null_query()
    inner = _extract_left_join_subquery(sql)

    # Bug signature: inner subquery projects the join key `d` as STRING. Scope
    # the negative assertion to the exact bad projection so that an unrelated
    # `CAST(... AS STRING)` elsewhere in the subquery does not fail the test.
    assert not re.search(
        r"CAST\s*\(\s*DATE\s*\(\s*ingested_at\s*\)\s+AS\s+STRING\s*\)\s+AS\s+d",
        inner,
    ), (
        "LEFT JOIN subquery still casts the join key `d` to STRING. "
        "BigQuery rejects mixed-type USING joins with HTTP 400 "
        "'JOIN type mismatch'. Got:\n" + inner
    )

    # Fix signature: inner subquery exposes the join key as DATE.
    assert re.search(r"DATE\s*\(\s*ingested_at\s*\)\s+AS\s+d", inner), (
        "Expected the inner subquery to expose `DATE(ingested_at) AS d` so "
        "that the join key matches the DATE column from GENERATE_DATE_ARRAY. "
        "Got:\n" + inner
    )


def test_per_day_is_test_null_query_selects_consistent_day_count() -> None:
    """Defensive: the dense-day query must keep producing 30 rows (one per day).

    The `date_range` CTE emits 30 dates (today + previous 29). After the fix
    the LEFT JOIN still merges against `t`; if a future regression changes the
    cardinality (e.g. accidentally drops one side), the streak counter in the
    caller will mis-classify consecutive-zero days. Pin the expected row count.
    """
    sql = bq_coverage_watcher._per_day_is_test_null_query()
    # GENERATE_DATE_ARRAY(today - 29 days, today) yields 30 dates inclusive.
    assert "INTERVAL 29 DAY" in sql, "Expected 29-day trailing window"
    assert "INTERVAL 30 DAY" in sql, (
        "Inner subquery must aggregate over a 30-day window to keep the date "
        "domain aligned with the dense date_range CTE."
    )


def test_per_day_is_test_null_query_outer_cast_preserves_string_output() -> None:
    """The outer SELECT still casts `dr.d` to STRING for display formatting.

    The fix only changes the *join* column inside the LEFT JOIN subquery; the
    outer SELECT's display-time CAST must remain so that downstream consumers
    (and humans reading logs) see the day as a printable string, not a DATE
    literal (`2026-06-29 00:00:00 UTC`).
    """
    sql = bq_coverage_watcher._per_day_is_test_null_query()
    # The outer projection should still emit a STRING-formatted day column.
    assert "CAST(dr.d AS STRING)" in sql, (
        "Outer SELECT must keep `CAST(dr.d AS STRING)` for human-readable "
        "day labels in the streak output."
    )