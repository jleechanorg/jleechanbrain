#!/usr/bin/env python3
"""
Strip downloaded HTML to text and score paragraphs against configurable
keyword axes. Reads every /tmp/wiki_*.html (or paths given as argv),
keeps the top-N paragraphs by axis-keyword score, writes per-source
.txt files into /tmp/isekai_chunks/ (or --out-dir).

Usage:
    python scripts/score_paragraphs.py [html_path ...] [--out-dir DIR] [--keep N] [--min-len 60] [--max-len 1500]

Default axes (edit AXES below to tune to your task):
    plot, synopsis, story, summary, magic academy, school, magic school,
    guilt, trauma, memory, lie, demon, demons, power, skill, cheat,
    depression, regret, return by death, world emperor, sage, class, rank
"""
import argparse
import glob
import html
import os
import re
import sys
from collections import defaultdict

DEFAULT_AXES = [
    "plot", "synopsis", "story", "setting", "premise", "overview", "summary",
    "magic academy", "demon academy", "school", "hunter",
    "guilt", "trauma", "memory", "memories", "lie", "lies",
    "demon", "demons", "demi-human", "human",
    "power", "skill", "abilities", "cheat", "growth",
    "depression", "regret", "pts", "mental",
    "return by death", "return by Death",
    "class", "rank", "sage", "king class", "world emperor",
]

DROP_TAGS = ("script", "style", "sup", "table", "figure")

def clean_html(raw: str) -> str:
    for tag in DROP_TAGS:
        raw = re.sub(rf"<{tag}[^>]*>.*?</{tag}>", "", raw, flags=re.S)
    raw = re.sub(r"<span[^>]*>|</span>", "", raw)
    raw = re.sub(r"<h([1-6])[^>]*>", r"\n\n## H\1 ", raw)
    raw = re.sub(r"</h[1-6]>", "\n", raw)
    raw = re.sub(r"<li[^>]*>", "\n- ", raw)
    raw = re.sub(r"<p[^>]*>", "\n\n", raw)
    raw = re.sub(r"<[^>]+>", "", raw)
    raw = html.unescape(raw)
    raw = re.sub(r"\n\s*\n\s*\n+", "\n\n", raw)
    return raw.strip()

def score_paragraphs(text: str, axes, min_len: int, max_len: int):
    """Return list of (score, paragraph) sorted desc by score, filtered to length band."""
    paras = [p.strip() for p in re.split(r"\n\n+", text)
             if min_len <= len(p.strip()) <= max_len]
    out = []
    for p in paras:
        s = sum(2 for k in axes if k.lower() in p.lower())
        if s >= 2:
            out.append((s, p))
    out.sort(key=lambda x: -x[0])
    return out

def derive_title(path: str) -> str:
    base = os.path.basename(path).replace(".html", "")
    return base.replace("_", " ").replace("wiki ", "")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("paths", nargs="*", help="HTML files (defaults to /tmp/wiki_*.html)")
    ap.add_argument("--out-dir", default="/tmp/isekai_chunks")
    ap.add_argument("--keep", type=int, default=25)
    ap.add_argument("--min-len", type=int, default=60)
    ap.add_argument("--max-len", type=int, default=1500)
    ap.add_argument("--axes", nargs="*", default=DEFAULT_AXES,
                    help="Override axes; lowercase keywords matched in paragraph text")
    args = ap.parse_args()

    paths = args.paths or sorted(glob.glob("/tmp/wiki_*.html"))
    if not paths:
        sys.exit("No input HTML found (use --paths or place files in /tmp/wiki_*.html).")

    os.makedirs(args.out_dir, exist_ok=True)

    for fn in paths:
        try:
            raw = open(fn).read()
        except OSError as e:
            print(f"{fn}: SKIP ({e})", file=sys.stderr)
            continue
        text = clean_html(raw)
        scored = score_paragraphs(text, args.axes, args.min_len, args.max_len)[: args.keep]
        keep = "\n\n---\n\n".join(f"[score={s}]\n{p}" for s, p in scored)
        title = derive_title(fn)
        out_path = os.path.join(args.out_dir, os.path.basename(fn).replace(".html", ".txt"))
        with open(out_path, "w") as f:
            f.write(f"### {title}\n\n{keep}")
        chars = sum(len(p) for _, p in scored)
        print(f"{title}: kept {len(scored)} paragraphs ({chars} chars) -> {out_path}")

if __name__ == "__main__":
    main()
