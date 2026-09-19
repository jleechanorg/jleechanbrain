#!/usr/bin/env python3
"""Smoke test for the read-gemini-share-link skill.

Verifies the skill markdown documents the correct (public, JS-hydration)
recipe without depending on actually running the browserclaw pipeline
(which requires Playwright + optional Chrome cookies).

Checks:
1. SKILL.md exists with proper frontmatter and the anti-patterns block.
2. The recipe documents that Gemini share pages are PUBLIC (no auth gate).
3. The JS hydration framing is present (the actual blocker).
4. The plain-Playwright recipe is documented (alternative to browserclaw).
5. The failure modes table covers the real failure modes (JS hydration
   timing, side-channel redirects, anti-bot CAPTCHA).
6. Cross-references mention browserclaw and read-auth-gated-share-links.
7. The captured-output verification command is documented.
8. The routing-eval.jsonl fixture has at least 3 intent rows.
9. Verified headless parameters are present.
"""

import re
import sys
from pathlib import Path


def main(skill_dir: str = None) -> int:
    skill_dir = Path(skill_dir or Path.home() / ".smartclaw/skills/read-gemini-share-link")
    skill_md = skill_dir / "SKILL.md"
    fixture = skill_dir / "routing-eval.jsonl"

    failures = []

    # 1. SKILL.md exists with proper frontmatter
    if not skill_md.exists():
        failures.append(f"SKILL.md missing at {skill_md}")
        return 1

    text = skill_md.read_text()
    if not re.match(r"^---\n", text):
        failures.append("SKILL.md missing YAML frontmatter")
    if "Anti-Patterns" not in text and "DO NOT DO" not in text:
        failures.append("SKILL.md missing Anti-Patterns / DO NOT DO block")

    # 2. Recipe documents PUBLIC framing (the user-visible fix from 2026-08-10)
    public_keywords = ["PUBLIC", "no auth gate", "public", "incognito"]
    if not any(kw in text for kw in public_keywords):
        failures.append("Skill does not document that Gemini share pages are PUBLIC")

    # 3. JS hydration framing is present
    if "JS hydration" not in text and "hydrate" not in text.lower():
        failures.append("Skill does not document JS hydration as the actual blocker")

    # 4. Plain-Playwright alternative recipe is documented
    if "playwright" not in text.lower() or "sync_playwright" not in text:
        failures.append("Skill missing the plain-Playwright alternative recipe")

    # 5. Failure modes cover real failure modes
    required_failure_keywords = [
        "JS hydration",
        "CAPTCHA",
        "truncated",
        "side-channel",
    ]
    for kw in required_failure_keywords:
        if kw.lower() not in text.lower():
            failures.append(f"Failure modes table missing keyword: {kw}")

    # 6. Cross-references mention browserclaw and read-auth-gated-share-links
    if "browserclaw" not in text.lower():
        failures.append("Cross-references missing browserclaw")
    if "read-auth-gated-share-links" not in text:
        failures.append("Cross-references missing read-auth-gated-share-links-with-browserclaw")

    # 7. Output verification command is documented
    if "wc -c" not in text:
        failures.append("Output verification command (wc -c) missing")

    # 8. The routing-eval.jsonl fixture has at least 3 intent rows
    if not fixture.exists():
        failures.append(f"routing-eval.jsonl missing at {fixture}")
    else:
        rows = [l for l in fixture.read_text().splitlines() if l.strip()]
        if len(rows) < 3:
            failures.append(f"routing-eval.jsonl has only {len(rows)} rows (expected >= 3)")

    # 9. Verified headless parameters are present
    if "--headless" not in text:
        failures.append("Verified --headless parameter missing")
    if "--wait-after-load" not in text or "12" not in text:
        failures.append("Verified --wait-after-load 12 parameter missing")
    if "--browser-channel" not in text:
        failures.append("Verified --browser-channel parameter missing")

    # 10. The 2026-08-10 fix provenance note is present (so future readers know when/why)
    if "2026-08-10" not in text:
        failures.append("Missing provenance date marker (2026-08-10)")

    if failures:
        print(f"FAIL: {len(failures)} check(s) failed")
        for f in failures:
            print(f"  - {f}")
        return 1

    print(f"PASS: all {10} checks satisfied for {skill_dir}")
    print(f"  - SKILL.md: {len(text)} chars")
    if fixture.exists():
        rows = [l for l in fixture.read_text().splitlines() if l.strip()]
        print(f"  - routing-eval.jsonl: {len(rows)} intents")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else None))
