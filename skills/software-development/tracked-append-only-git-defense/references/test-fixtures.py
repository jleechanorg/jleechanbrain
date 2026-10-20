"""Regression tests for a tracked-append-only-file canonicalizer.

Drop into `tests/test_<your-name>_canon.py` and adapt the script path.

Copy of `worldarchitect.ai/tests/test_beads_jsonl_canon.py` (PR #8798).
"""

import json
import subprocess
import sys
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "sort_beads_jsonl.py"


def write_jsonl(tmp_path: Path, records) -> Path:
    """Write a JSONL file under tmp_path/beads/issues.jsonl. Each item is a dict."""
    beads_dir = tmp_path / "beads"
    beads_dir.mkdir()
    f = beads_dir / "issues.jsonl"
    with open(f, "w") as fp:
        for r in records:
            fp.write(json.dumps(r) + "\n")
    return f


def run_canon(tmp_path: Path) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(SCRIPT)],
        cwd=tmp_path,
        capture_output=True,
        text=True,
        timeout=30,
    )


def read_jsonl(p: Path):
    return [json.loads(l) for l in p.read_text().splitlines() if l.strip()]


def test_already_sorted_is_noop(tmp_path):
    f = write_jsonl(tmp_path, [
        {"id": "a", "title": "first", "updated_at": "2026-01-01T00:00:00Z"},
        {"id": "b", "title": "second", "updated_at": "2026-01-02T00:00:00Z"},
        {"id": "c", "title": "third", "updated_at": "2026-01-03T00:00:00Z"},
    ])
    before = f.read_bytes()
    res = run_canon(tmp_path)
    assert res.returncode == 0, res.stderr
    assert f.read_bytes() == before  # byte-for-byte identical


def test_unsorted_gets_sorted(tmp_path):
    f = write_jsonl(tmp_path, [
        {"id": "c", "title": "third"},
        {"id": "a", "title": "first"},
        {"id": "b", "title": "second"},
    ])
    run_canon(tmp_path)
    ids = [r["id"] for r in read_jsonl(f)]
    assert ids == sorted(ids)


def test_duplicate_ids_collapsed_to_latest_updated_at(tmp_path):
    f = write_jsonl(tmp_path, [
        {"id": "x", "title": "old", "updated_at": "2026-01-01T00:00:00Z"},
        {"id": "x", "title": "new", "updated_at": "2026-08-05T00:00:00Z"},
    ])
    run_canon(tmp_path)
    recs = read_jsonl(f)
    assert len(recs) == 1
    assert recs[0]["title"] == "new"


def test_duplicate_ids_with_missing_updated_at_keeps_first(tmp_path):
    """When both records lack updated_at, the canonicalizer must keep first."""
    f = write_jsonl(tmp_path, [
        {"id": "x", "title": "first"},
        {"id": "x", "title": "second"},
    ])
    run_canon(tmp_path)
    recs = read_jsonl(f)
    assert len(recs) == 1
    assert recs[0]["title"] == "first"


def test_malformed_line_is_preserved_and_warning_emitted(tmp_path):
    """Recovery is hard — preserve malformed lines and warn loudly."""
    f = write_jsonl(tmp_path, [
        {"id": "a", "title": "good"},
        "not-json{{",
        {"id": "b", "title": "also good"},
    ])
    lines_before = f.read_text().splitlines()
    res = run_canon(tmp_path)
    assert res.returncode == 0
    # File length unchanged (3 lines preserved)
    assert len(f.read_text().splitlines()) == 3
    # Stderr carries a warning about the malformed line
    assert "malformed" in res.stderr.lower() or "warning" in res.stderr.lower()


def test_idempotent_run_twice_same_output(tmp_path):
    f = write_jsonl(tmp_path, [
        {"id": "b", "title": "second", "updated_at": "2026-08-05T00:00:00Z"},
        {"id": "b", "title": "later",  "updated_at": "2026-08-06T00:00:00Z"},
        {"id": "c", "title": "third",  "updated_at": "2026-08-04T00:00:00Z"},
        {"id": "a", "title": "first",  "updated_at": "2026-08-03T00:00:00Z"},
    ])
    run_canon(tmp_path)
    first_pass = f.read_bytes()
    run_canon(tmp_path)
    second_pass = f.read_bytes()
    assert first_pass == second_pass  # idempotency
