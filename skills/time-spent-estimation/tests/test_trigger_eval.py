#!/usr/bin/env python3
"""test_trigger_eval.py — verify the routing-eval.jsonl fixture uses the
correct {intent, expected_skill, ambiguous_with?} schema and every intent
matches at least one trigger phrase in the SKILL.md frontmatter.

Per Skillify 11-item contract item #8.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FIXTURE = ROOT / "routing-eval.jsonl"
SKILL_MD = ROOT / "SKILL.md"


def load_fixture() -> list[dict]:
    rows = []
    for line in FIXTURE.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        rows.append(json.loads(line))
    return rows


def extract_triggers() -> set[str]:
    head = SKILL_MD.read_text().split("---", 2)[1]
    triggers = set()
    for line in head.splitlines():
        m = re.match(r'\s*triggers:\s*$', line)
        if m:
            in_list = True
            continue
        m = re.match(r"\s*-\s*[\"']?(.+?)[\"']?\s*$", line)
        if m:
            triggers.add(m.group(1).strip().strip('"\''))
    return triggers


def test_fixture_schema():
    rows = load_fixture()
    assert rows, "fixture is empty"
    for r in rows:
        assert "intent" in r, f"missing intent: {r}"
        assert "expected_skill" in r, f"missing expected_skill: {r}"
        assert r["expected_skill"] == "time-spent-estimation", \
            f"wrong expected_skill: {r}"


def test_intents_match_triggers():
    rows = load_fixture()
    triggers = extract_triggers()
    # Each intent should have at least one token that appears in the trigger set
    for r in rows:
        intent_tokens = re.findall(r"[a-zA-Z\-]+", r["intent"].lower())
        hits = [t for t in triggers if any(tok in t.lower() or t.lower() in tok
                                            for tok in intent_tokens)]
        # Loose check: at least one common token between intent and any trigger
        assert hits or any(t.lower() in r["intent"].lower() for t in triggers), \
            f"intent {r['intent']!r} matches no trigger in {triggers}"


def test_fixture_min_intents():
    """At least 3 intents to give the resolver something to evaluate."""
    rows = load_fixture()
    assert len(rows) >= 3, f"need ≥ 3 intents, got {len(rows)}"


if __name__ == "__main__":
    import pytest
    sys.exit(pytest.main([__file__, "-v"]))