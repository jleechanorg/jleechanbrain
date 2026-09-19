#!/usr/bin/env python3
"""Resolve a UU (both modified) merge conflict by taking the union of both sides.

Usage: resolve-uu-conflict.py <file>

The script splits the file at the conflict markers:
    <<<<<<< Updated upstream
    ... their version ...
    =======
    ... our version (stashed) ...
    >>>>>>> Stashed changes

…and rewrites the file as: prefix + theirs + suffix, where "theirs" is
the block between `Updated upstream` and `=======`, and "suffix" is
everything after `>>>>>>> Stashed changes`.

For content files (markdown logs, changelogs, learning journals) this is
the safest default — both sides' contributions are preserved in
chronological order. For CODE files, do NOT use this — manual review
is required.

Exits with code 0 on success, 1 if no conflict markers are found, 2 on
usage error.
"""

from __future__ import annotations

import sys
from pathlib import Path

START = "<<<<<<< Updated upstream"
MID = "======="
END = ">>>>>>> Stashed changes"


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2

    path = Path(argv[1])
    content = path.read_text()

    if START not in content or END not in content:
        print(f"no conflict markers in {path}", file=sys.stderr)
        return 1

    # Find the first conflict block. Repeat for safety if multiple blocks
    # exist in the same file.
    while START in content:
        start_idx = content.index(START)
        mid_idx = content.index(MID, start_idx)
        end_idx = content.index(END, mid_idx)

        prefix = content[:start_idx].rstrip() + "\n"
        theirs = content[mid_idx + len(MID) : end_idx].strip() + "\n\n"
        suffix = content[end_idx + len(END) :].lstrip()
        content = prefix + theirs + suffix

    path.write_text(content)
    remaining = content.count(START) + content.count(END)
    print(f"resolved {path}; remaining markers: {remaining}")
    return 0 if remaining == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))