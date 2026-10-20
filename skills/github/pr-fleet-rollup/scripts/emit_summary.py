#!/usr/bin/env python3
"""emit_summary.py — companion artifact generator for pr-fleet-rollup.

Reads /tmp/gh-prs-14d.json and writes /tmp/gh-prs-14d-summary.md
(repos × kind pivot + top-15 per kind). Re-run whenever the JSON
is regenerated to keep the markdown in sync.

Usage:
    python3 emit_summary.py [--json /tmp/gh-prs-14d.json] [--md /tmp/gh-prs-14d-summary.md]
"""
import argparse
import json
from collections import Counter, defaultdict


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", default="/tmp/gh-prs-14d.json")
    ap.add_argument("--md", default="/tmp/gh-prs-14d-summary.md")
    ap.add_argument("--window-label", default="2026-08-05 → 2026-08-19")
    args = ap.parse_args()

    with open(args.json) as f:
        prs = json.load(f)

    by_kind = Counter(r["kind"] for r in prs)
    by_repo_kind = defaultdict(lambda: Counter())
    for r in prs:
        by_repo_kind[r["repo"]][r["kind"]] += 1

    lines = [
        f"# PR/Report Summary — window {args.window_label}",
        "",
        f"**Total PRs captured**: {len(prs)}",
        "",
        "## By kind",
    ]
    for k, v in by_kind.most_common():
        lines.append(f"- **{k}**: {v}")

    lines += ["", "## By repo × kind", "",
              "| repo | bug | feature | infra | chore | total |",
              "|---|---:|---:|---:|---:|---:|"]
    for repo in sorted(by_repo_kind):
        c = by_repo_kind[repo]
        total = sum(c.values())
        lines.append(
            f"| {repo} | {c['bug']} | {c['feature']} | {c['infra']} | {c['chore']} | {total} |"
        )

    def top(kind: str, n: int = 15):
        items = [r for r in prs if r["kind"] == kind]
        items.sort(key=lambda r: r.get("mergedAt", ""), reverse=True)
        return items[:n]

    for kind, n in (("bug", 15), ("feature", 15), ("infra", 15), ("chore", 10)):
        lines += ["", f"## Top {n} {kind} (most recent first)"]
        for r in top(kind, n):
            md_text = r["title"].replace("|", "\\|")
            lines.append(
                f"- [{r['repo']}#{r['number']}]({r['url']}) — "
                f"{r['mergedAt'][:10]}  {md_text}"
            )

    with open(args.md, "w") as f:
        f.write("\n".join(lines) + "\n")

    print(f"wrote {args.md} ({len(prs)} records, {sum(by_kind.values())} kinds)")


if __name__ == "__main__":
    main()
