#!/usr/bin/env python3
"""WA prompt include chain map — list every {{PROMPT_INCLUDE:...}} reference and find orphaned shared/ files.

Usage:
  python3 scripts/wa_prompt_includes.py [/path/to/worldarchitect.ai/mvp_site/prompts]

Outputs:
  - include_map: dict mapping each shared file to its includers (and mode: normal vs chain).
  - orphaned: list of shared files with zero references. THESE MAY BE FALSE POSITIVES — verify by grepping
    mvp_site/agent_prompts.py before deletion. Some shared files are loaded via conditional import, not
    {{PROMPT_INCLUDE:...}} placeholders.
"""

from __future__ import annotations
import argparse
import re
from collections import defaultdict
from pathlib import Path


INCLUDE_RE = re.compile(r"\{\{PROMPT_INCLUDE:([^}]+)\}\}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("prompt_dir", nargs="?", default=str(Path.home() / "projects/worldarchitect.ai/mvp_site/prompts"))
    args = ap.parse_args()

    prompt_dir = Path(args.prompt_dir)
    if not prompt_dir.is_dir():
        print(f"not a directory: {prompt_dir}")
        return 1

    include_map: dict[str, list[str]] = defaultdict(list)
    referenced_paths: set[str] = set()
    parent_files: list[Path] = []

    for path in sorted(prompt_dir.rglob("*.md")):
        rel = path.relative_to(prompt_dir)
        text = path.read_text(encoding="utf-8", errors="ignore")
        matches = INCLUDE_RE.findall(text)
        if matches:
            for inc in matches:
                include_map[inc].append(str(rel))
                referenced_paths.add(inc)
        if matches and "shared/" not in str(rel):
            parent_files.append(rel)

    print("=== Include map ===\n")
    if not include_map:
        print("(no {{PROMPT_INCLUDE:...}} references found)\n")
    else:
        for inc in sorted(include_map.keys()):
            size_path = prompt_dir / inc
            size = size_path.stat().st_size if size_path.exists() else 0
            print(f"  {inc:60s} {size//1024:>3d}KB × {len(include_map[inc])} reference(s)")
            for ref in include_map[inc]:
                print(f"    └─ {ref}")

    print("\n=== Orphaned shared/ files (zero {{PROMPT_INCLUDE}} references) ===")
    orphans: list[str] = []
    for path in sorted((prompt_dir / "shared").glob("*.md")):
        rel = f"shared/{path.name}"
        if rel not in referenced_paths:
            orphans.append(rel)
            print(f"  ⚠️  {rel}  ({path.stat().st_size}B)")

    if not orphans:
        print("  (none)")
    else:
        print(f"\n  → {len(orphans)} candidate(s) for deletion.")
        print("  → ⚠️  BEFORE DELETING: grep mvp_site/agent_prompts.py for each orphan path.")
        print("     Some shared files are loaded via conditional path (read_file_cached, dynamic include)")
        print("     rather than {{PROMPT_INCLUDE:...}} placeholders. False-positive deletion will break")
        print("     the served prompt at runtime.")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
