#!/usr/bin/env python3
"""
Verify a Markdown pattern-table report has row-level citation integrity.
Walks rows delimited by `|---` separators, confirms each numbered row has
≥1 URL on its source column(s), and reports row/URL counts.

Exit codes:
    0  all rows have ≥1 URL AND unique URL count ≥ row count AND source-diversity holds
    1  any row lacks a URL, or duplicate-slug rows collapse onto one source
    2  structural error (no table rows found)

Usage:
    python scripts/verify_pattern_table.py /path/to/report.md
"""
import argparse
import re
import sys

URL_RE = re.compile(r"https?://[^\s)]+")
ROW_HEADER_RE = re.compile(r"^\|\s*\*\*(\d+)\*\*\s*\|")
SEP_RE = re.compile(r"^\|---")

def walk_rows(md: str):
    """Yield (row_num, [row_lines]) for each numbered table row."""
    in_table = False
    header_seen = False
    cur_num = None
    cur_lines = []
    for line in md.splitlines():
        if not in_table:
            if ROW_HEADER_RE.match(line):
                in_table = True
                m = ROW_HEADER_RE.match(line)
                cur_num = int(m.group(1))
                cur_lines = [line]
                header_seen = False
            continue
        # inside the table
        if SEP_RE.match(line):
            header_seen = True
            continue
        if line.startswith("|---") and header_seen:
            # end of table block
            if cur_lines:
                yield cur_num, cur_lines
                cur_lines = []
                cur_num = None
            in_table = False
            continue
        if ROW_HEADER_RE.match(line):
            # start of next row -> emit previous
            if cur_lines:
                yield cur_num, cur_lines
            m = ROW_HEADER_RE.match(line)
            cur_num = int(m.group(1))
            cur_lines = [line]
            header_seen = False
            continue
        if not line.strip():
            # paragraph break outside table -> close out
            if cur_lines:
                yield cur_num, cur_lines
                cur_lines = []
                cur_num = None
            in_table = False
            continue
        cur_lines.append(line)
    if cur_lines:
        yield cur_num, cur_lines

def slug(url: str) -> str:
    """Normalize a URL to a slug-ish identity (drop trailing punctuation, lowercase host+path)."""
    u = url.rstrip(".,;:!?)")
    u = re.sub(r"[<>]", "", u)
    # drop hash/query so anchors don't fake-diversify
    u = u.split("#", 1)[0].split("?", 1)[0]
    return u.lower()

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("path", help="path to the markdown report")
    args = ap.parse_args()

    md = open(args.path).read()
    rows = list(walk_rows(md))
    if not rows:
        sys.exit("ERROR: no numbered pattern-table rows found (regex: `| **N** |`)")

    missing_url = []
    row_slugs = {}
    all_slugs = []
    for n, lines in rows:
        urls = []
        for ln in lines:
            urls.extend(URL_RE.findall(ln))
        urls = [u.rstrip(".,;:!?)") for u in urls]
        if not urls:
            missing_url.append(n)
        row_slugs[n] = tuple(sorted(set(slug(u) for u in urls)))
        all_slugs.extend(row_slugs[n])

    unique_count = len(set(all_slugs))
    row_count = len(rows)
    fails = []

    print(f"Row count         : {row_count}")
    print(f"Unique URLs cited : {unique_count}")
    if missing_url:
        fails.append(("MISSING_URL", missing_url))
    if unique_count < row_count:
        fails.append(("UNIQUE_URL_LT_ROWS", {"unique": unique_count, "rows": row_count}))

    # Diversity check: every slug set must appear on >1 row (catches copy-paste typos)
    single_row_slugs = [s for s, count in __import__("collections").Counter(all_slugs).items() if count == 1]
    print(f"Slugs appearing on ≥2 rows: {len(set(all_slugs) - set(single_row_slugs))}")
    if not single_row_slugs:
        fails.append(("NO_SOURCE_DIVERSITY",
                      {"reason": "every cited URL appears on only one row — possible copy-paste typo"}))

    if fails:
        print("\nFAIL:")
        for code, payload in fails:
            print(f"  {code}: {payload}")
        sys.exit(1)

    print("\nPer-row URL slug sets:")
    for n, lines in rows:
        first = lines[0][:80]
        print(f"  [{n:>2}] {len(row_slugs[n])} unique URL(s) :: {first}")
    print("\nPASS")
    sys.exit(0)

if __name__ == "__main__":
    main()
