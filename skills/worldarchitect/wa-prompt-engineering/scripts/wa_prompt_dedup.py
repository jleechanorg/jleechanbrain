#!/usr/bin/env python3
"""WA prompt dedup — find files with high overlap via 80-char whitespace fingerprints.

Usage:
  python3 scripts/wa_prompt_dedup.py [--min-fp-shared 5] [/path/to/worldarchitect.ai/mvp_site/prompts]

Outputs pairs of files sharing ≥N fingerprint tokens. The two known hard duplicates (as of 2026-08-18):
  mechanics_system_instruction.md (4.0KB) ~99% duplicate of mechanics_system_instruction_code_execution.md (4.1KB)
  game_state_examples.md (9.4KB) shares one 150-char fragment with game_state_mechanics_appendix.md (25.0KB)

The script normalizes whitespace and lowercases before fingerprinting so identical content with different
formatting surfaces. Cross-file fingerprint sets are sorted by descending size of intersection.
"""

from __future__ import annotations
import argparse
import os
import re
from collections import defaultdict
from pathlib import Path


WHITESPACE_RE = re.compile(r"\s+")


def normalize(text: str) -> str:
    return WHITESPACE_RE.sub(" ", text.lower()).strip()


def fingerprint(text: str, n: int = 80) -> set[str]:
    norm = normalize(text)
    return {norm[i : i + n] for i in range(0, max(1, len(norm) - n + 1), n)}


def file_fingerprints(prompt_dir: Path) -> dict[str, set[str]]:
    out: dict[str, set[str]] = {}
    for path in sorted(prompt_dir.rglob("*.md")):
        try:
            out[str(path)] = fingerprint(path.read_text(encoding="utf-8", errors="ignore"))
        except Exception as e:  # noqa: BLE001
            print(f"skip {path}: {e}")
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("prompt_dir", nargs="?", default=str(Path.home() / "projects/worldarchitect.ai/mvp_site/prompts"))
    ap.add_argument("--min-fp-shared", type=int, default=5, help="Min shared fingerprints to flag a pair")
    args = ap.parse_args()

    prompt_dir = Path(args.prompt_dir)
    fps = file_fingerprints(prompt_dir)

    pairs: list[tuple[int, str, str]] = []
    paths = list(fps.keys())
    for i, a in enumerate(paths):
        for b in paths[i + 1 :]:
            shared = fps[a] & fps[b]
            if len(shared) >= args.min_fp_shared:
                pairs.append((len(shared), a, b))

    if not pairs:
        print(f"No duplicate pairs found (min {args.min_fp_shared} shared fingerprints).")
        return 0

    print(f"=== {len(pairs)} duplicate pairs (≥{args.min_fp_shared} shared fingerprints) ===\n")
    for n, a, b in sorted(pairs, reverse=True):
        size_a = Path(a).stat().st_size
        size_b = Path(b).stat().st_size
        print(f"  shared={n:5d}  ({size_a//1024}KB + {size_b//1024}KB)")
        print(f"    {a}")
        print(f"    {b}")
        # Show one sample fingerprint for inspection
        sample = next(iter(fps[a] & fps[b]))
        print(f"    sample: {sample[:100]!r}…\n")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
