#!/usr/bin/env python3
"""Test: web-advice-share-button-must-be-self-driven COMMIT.

Verifies the canonical /web-advice skill contains the LLM-driven share-button
mandate AND the FORBIDDEN operator-clicked-share rule, AND the Hermes-side
overlay inverts pitfall #46 to LLM-driven (not operator-clicked).

Run: python3 -m pytest tests/test_web_advice_share_button_contract.py -v
"""
import os
import re

CANONICAL_SKILL = os.path.expanduser("~/.claude-wa/skills/web-advice/SKILL.md")
OVERLAY_SKILL = os.path.expanduser("~/.smartclaw/skills/review/web-advice/SKILL.md")
SOUL_PATH = os.path.expanduser("~/.smartclaw/workspace/SOUL.md")


def test_canonical_skill_has_llm_driven_share_button():
    """Canonical /web-advice skill §1b.3 must mandate LLM-driven Share-button click."""
    with open(CANONICAL_SKILL) as f:
        content = f.read()
    assert "LLM-Driven Share-Button Click" in content, (
        "Canonical skill missing LLM-driven share-button mandate"
    )
    assert "operator-clicked Share is FORBIDDEN" in content or "operator-clicked is FORBIDDEN" in content, (
        "Canonical skill missing FORBIDDEN operator-clicked rule"
    )
    for vendor_recipe in [
        "chatgpt.com/share",
        "grok.com/share",
        "share/<id>",
    ]:
        assert vendor_recipe in content, f"Canonical skill missing recipe for {vendor_recipe}"


def test_canonical_skill_has_curl_probe_gate():
    """After every share-URL capture, curl -s -L -I <url> probe is mandatory."""
    with open(CANONICAL_SKILL) as f:
        content = f.read()
    assert "curl -s -L -I" in content, "Missing curl unauth-probe gate"
    assert "UNAVAILABLE" in content, "Missing UNAVAILABLE fallback when probe fails"


def test_overlay_inverts_pitfall_46():
    """Hermes overlay pitfall #46 must say LLM drives share, NOT operator."""
    with open(OVERLAY_SKILL) as f:
        content = f.read()
    assert "operator-clicked Share is FORBIDDEN" in content, (
        "Overlay pitfall #46 still says operator must click — not inverted"
    )
    assert "LLM MUST drive the share-button click" in content, (
        "Overlay missing LLM-driven share-button directive"
    )
    # The corrected rule block must be present (the "corrected 2026-08-19" line)
    assert "corrected 2026-08-19" in content, (
        "Overlay missing the 'corrected 2026-08-19' rule label"
    )


def test_overlay_quick_contract_rule_6():
    """Quick contract rule 6 must reference the share-URL drive."""
    with open(OVERLAY_SKILL) as f:
        content = f.read()
    assert "6. **Share-URL drive" in content, "Overlay missing Quick Contract rule 6"
    assert "FORBIDDEN" in content, "Rule 6 missing FORBIDDEN operator-clicked"


def test_soul_commit_web_advice_share_button_present():
    """SOUL.md must have a web-advice-share-button-must-be-self-driven COMMIT block."""
    with open(SOUL_PATH) as f:
        content = f.read()
    assert "## COMMIT: web-advice-share-button-must-be-self-driven" in content, (
        "SOUL.md missing the COMMIT block"
    )
    assert "C0AH3RY3DK6/p1787187606" in content, "SOUL.md COMMIT missing bug-ref thread URL"
    assert "MAST" in content and "FC1" in content and "FC3" in content and "ETCLOVG" in content, (
        "SOUL.md COMMIT missing MAST+ETCLOVG classification"
    )


if __name__ == "__main__":
    test_canonical_skill_has_llm_driven_share_button()
    test_canonical_skill_has_curl_probe_gate()
    test_overlay_inverts_pitfall_46()
    test_overlay_quick_contract_rule_6()
    test_soul_commit_web_advice_share_button_present()
    print("OK all 5 web-advice share-button contract tests passed")
