#!/usr/bin/env python3
"""Canonicalize a tracked append-only log file — sort by id ascending + dedup by id.

Template adapted from `dark-factory/scripts/sort_beads_jsonl.py` (PR #8798, 2026-08-05).
Adapt this template to your record shape:

  1. Change JSONL to your format / path glob.
  2. Replace `id` with your record's primary-key field.
  3. Replace `updated_at` (or remove tie-breaker logic if your record has none).
  4. Update the malformed-line stderr prefix to include your record shape's
     minimum fields so an operator can diagnose recovery.

Exit code 0 on success, 1 only on fatal I/O error. Idempotent: running it twice
never changes the output.
"""

import json
import os
import sys
from pathlib import Path

# === ADAPT THIS LINE FOR YOUR SCHEMA ===
JSONL = Path(".beads") / "issues.jsonl"
ID_FIELD = "id"
TIE_FIELD = "updated_at"
# ======================================


def _load(lines):
    """Yield valid records; for malformed input yield (None, line_no, preview)."""
    for line_no, line in enumerate(lines, start=1):
        if not line.strip():
            continue
        try:
            rec = json.loads(line)
        except json.JSONDecodeError as e:
            yield (None, line_no, line.rstrip()[:120])
            continue
        yield (rec, line_no, None)


def _key(rec):
    return rec.get(ID_FIELD, "")


def _keep(a, b):
    """Pick the survivor when two records share an id.

    Tie-breaker: keep the one with the LATER TIE_FIELD (ISO 8601 string
    compare is UTC-safe). Fall back to first-occurrence when either record
    is missing TIE_FIELD.
    """
    a_tie = a.get(TIE_FIELD, "")
    b_tie = b.get(TIE_FIELD, "")
    if a_tie == b_tie:
        return a
    if not a_tie:
        return b
    if not b_tie:
        return a
    return b if b_tie > a_tie else a


def main() -> int:
    if not JSONL.exists():
        return 0
    text = JSONL.read_text(encoding="utf-8")
    records = []
    malformed = []
    for rec, line_no, preview in _load(text.splitlines()):
        if rec is None:
            malformed.append((line_no, preview))
        else:
            records.append(rec)

    if not records and not malformed:
        return 0

    # Dedup by ID, preserving first-occurrence and applying tie-breaker
    by_id = {}
    dups_collapsed = 0
    for rec in records:
        key = _key(rec)
        if key in by_id:
            dups_collapsed += 1
            by_id[key] = _keep(by_id[key], rec)
        else:
            by_id[key] = rec

    deduped = list(by_id.values())
    deduped.sort(key=_key)

    writeback = "".join(json.dumps(r, separators=(", ", ": ")) + "\n" for r in deduped)
    if malformed:
        writeback += "".join(
            f"# malformed line {ln}: {p!r}\n" for ln, p in malformed
        )

    if writeback == text:
        print(f"{JSONL.name}: {len(deduped)} records already canonical"
              + (f", {len(malformed)} malformed lines preserved" if malformed else ""))
        return 0

    tmp = JSONL.with_suffix(JSONL.suffix + ".tmp")
    tmp.write_text(writeback, encoding="utf-8")
    os.replace(tmp, JSONL)
    print(
        f"{JSONL.name}: {len(records)} -> {len(deduped)} records"
        f" ({dups_collapsed} dup-ids collapsed"
        + (f", {len(malformed)} malformed lines preserved" if malformed else "")
        + ")"
    )
    for ln, preview in malformed:
        print(
            f"warning: malformed JSON at line {ln}: {preview!r}",
            file=sys.stderr,
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
