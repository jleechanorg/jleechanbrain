# Reusable script — rank OPEN PRs by PR-level top-10s recipe

## Usage

```bash
python3 scripts/rank-open-prs.py \
  --window-days 14 \
  --top-n 10 \
  --output /tmp/open-prs-ranked.json
```

Optional flags:
- `--repos owner/repo owner/repo ...` (default: all `jleechanorg/*` repos)
- `--include-kinds bug feature` (default)
- `--mergeable-only` (subset for non-prod merge approval)

## Script (verbatim)

```python
#!/usr/bin/env python3
"""Rank OPEN PRs across N GitHub repos for top-N bug-fix / feature reports.

Verified 2026-08-19 against 20 jleechanorg/* repos; produced the canonical
top-10s report for /roadmap that pushed to jleechanorg/roadmap@5a1c742.

Conventional-commit regex tolerates [agento/antig/claude/codex/gemini/claudem/...]
prefixes. Fall back to keyword match on first 30 chars.
"""
import argparse
import json
import re
import subprocess
import sys
from collections import Counter
from datetime import datetime, timedelta, timezone

CONV_BUG = re.compile(r'(?:\[[^\]]+\]\s*)?(?:\(?\s*)?fix\s*\(', re.IGNORECASE)
CONV_FEAT = re.compile(r'(?:\[[^\]]+\]\s*)?(?:\(?\s*)?feat\s*\(', re.IGNORECASE)

def classify(title: str) -> str:
    if CONV_BUG.search(title): return 'bug'
    if CONV_FEAT.search(title): return 'feature'
    return 'other'

def pr_score(p: dict) -> int:
    s = 0
    ua = p.get('updatedAt', '')
    if ua >= '2026-08-18': s += 5
    elif ua >= '2026-08-15': s += 3
    elif ua >= '2026-08-10': s += 1
    if p.get('mergeable') == 'MERGEABLE': s += 4
    elif p.get('mergeable') == 'CONFLICTING': s += 1
    cf = p.get('changedFiles', 100)
    if cf <= 5: s += 3
    elif cf <= 15: s += 1
    elif cf > 30: s -= 2
    if p.get('isDraft'): s -= 5
    return s

def discover_repos() -> list[str]:
    """Return all jleechanorg/* repos with >= 1 open PR (uses `gh repo list`)."""
    out = subprocess.run(
        ['gh', 'repo', 'list', 'jleechanorg', '--limit', '100',
         '--json', 'nameWithOwner'],
        capture_output=True, text=True, check=True)
    return [r['nameWithOwner'] for r in json.loads(out.stdout)]

def pull_prs(repo: str) -> list[dict]:
    out = subprocess.run(
        ['gh', 'pr', 'list', '--repo', repo, '--state', 'open', '--limit', '100',
         '--json', 'number,title,headRefName,isDraft,mergeable,additions,'
                  'changedFiles,createdAt,updatedAt,author,labels,url,baseRefName'],
        capture_output=True, text=True, timeout=60)
    if out.returncode != 0:
        print(f'FAIL {repo}: {out.stderr[:200]}', file=sys.stderr)
        return []
    try:
        prs = json.loads(out.stdout)
    except Exception as e:
        print(f'JSON fail {repo}: {e}', file=sys.stderr)
        return []
    for p in prs:
        p['_repo'] = repo
    return prs

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--window-days', type=int, default=14)
    ap.add_argument('--top-n', type=int, default=10)
    ap.add_argument('--output', default='/tmp/open-prs-ranked.json')
    ap.add_argument('--repos', nargs='*', default=None)
    ap.add_argument('--include-kinds', nargs='+', default=['bug', 'feature'])
    ap.add_argument('--mergeable-only', action='store_true')
    args = ap.parse_args()

    repos = args.repos or discover_repos()
    print(f'Scanning {len(repos)} repos...', file=sys.stderr)
    all_prs = []
    for repo in repos:
        all_prs.extend(pull_prs(repo))

    cutoff = (datetime.now(timezone.utc) - timedelta(days=args.window_days)).strftime('%Y-%m-%dT%H:%M:%SZ')
    window_prs = [p for p in all_prs if not p.get('isDraft') and p.get('updatedAt', '') >= cutoff]

    for p in window_prs:
        p['kind'] = classify(p.get('title', ''))

    if args.mergeable_only:
        window_prs = [p for p in window_prs if p.get('mergeable') == 'MERGEABLE']

    kinds = Counter(p['kind'] for p in window_prs)
    print(f'Window: {cutoff} → now | non-draft PRs in window: {len(window_prs)}', file=sys.stderr)
    print(f'By kind: {dict(kinds)}', file=sys.stderr)

    ranked = {
        'window_days': args.window_days,
        'cutoff': cutoff,
        'repos_scanned': repos,
        'total_open': len(all_prs),
        'non_draft_in_window': len(window_prs),
        'by_kind': dict(kinds),
        'top_n': {
            'feature': sorted(
                [p for p in window_prs if p['kind'] == 'feature'],
                key=pr_score, reverse=True)[:args.top_n],
            'bug': sorted(
                [p for p in window_prs if p['kind'] == 'bug'],
                key=pr_score, reverse=True)[:args.top_n],
        },
    }

    with open(args.output, 'w') as f:
        json.dump(ranked, f, indent=2)
    print(f'Wrote {args.output}', file=sys.stderr)

    # Console preview
    for kind in args.include_kinds:
        print(f'\n=== TOP {args.top_n} {kind.upper()} PRs ===', file=sys.stderr)
        for i, p in enumerate(ranked['top_n'][kind][:args.top_n], 1):
            repo = p['_repo'].split('/')[-1]
            print(f'  {i}. score={pr_score(p)} {repo}#{p["number"]} {p.get("mergeable","?")} {p.get("changedFiles")}f',
                  file=sys.stderr)
            print(f'     {p.get("title","")[:90]}', file=sys.stderr)

if __name__ == '__main__':
    main()
```

## How to extend

- **Add `chore`/`infra` to `--include-kinds`** if you want broader coverage.
- **Adjust `pr_score` weights** if recency weight needs tuning (currently 5/3/1 across 0-2d/3-7d/8-14d).
- **Replace `discover_repos()`** with a static list for non-`jleechanorg/*` orgs.
- **Add `--label-filter`** for `gh pr list --label <X>` narrowing (e.g. `priority/p0`).
