#!/usr/bin/env python3
"""check_resolvable.py — verify the skill's resolver entry is well-formed and
points to an existing SKILL.md. Part of the Skillify 11-item contract (item 9).
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

SKILL_DIR = Path(__file__).resolve().parent.parent
RESOLVER = Path.home() / ".smartclaw" / "skills" / "RESOLVER.md"
SKILL_NAME = SKILL_DIR.name


def main() -> int:
    ap = argparse.ArgumentParser(description=f"Verify {SKILL_NAME} is resolvable.")
    ap.add_argument("--repo", default=str(SKILL_DIR.parent.parent),
                    help="Repo root containing skills/RESOLVER.md (default: ~/.smartclaw)")
    args = ap.parse_args()

    resolver = Path(args.repo) / "skills" / "RESOLVER.md"

    text = resolver.read_text()
    # Find a `## <name>` heading that contains our skill name and trigger phrases
    pattern = re.compile(
        r"^##\s+" + re.escape(SKILL_NAME) + r"\b.*?(?=^##\s|\Z)",
        re.MULTILINE | re.DOTALL,
    )
    m = pattern.search(text)
    if not m:
        print(f"FAIL: no '## {SKILL_NAME}' heading found in RESOLVER.md")
        return 1
    section = m.group(0)
    if "File:" not in section or str(SKILL_DIR / "SKILL.md") not in section:
        # Tolerate relative or absolute path forms
        if f"skills/{SKILL_NAME}/SKILL.md" not in section:
            print(f"FAIL: resolver entry for {SKILL_NAME} does not point to its SKILL.md")
            return 1
    if "Triggers:" not in section:
        print(f"FAIL: resolver entry for {SKILL_NAME} is missing 'Triggers:' line")
        return 1

    # SKILL.md must exist and have YAML frontmatter
    skill_md = SKILL_DIR / "SKILL.md"
    if not skill_md.exists() or skill_md.stat().st_size < 200:
        print(f"FAIL: {skill_md} missing or too small")
        return 1
    head = skill_md.read_text()[:500]
    if not head.startswith("---\n"):
        print(f"FAIL: {skill_md} missing YAML frontmatter")
        return 1

    print(f"OK: {SKILL_NAME} is resolvable")
    return 0


if __name__ == "__main__":
    sys.exit(main())