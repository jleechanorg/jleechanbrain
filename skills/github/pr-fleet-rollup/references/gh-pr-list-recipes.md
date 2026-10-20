# gh pr list recipes for fleet rollups

Verified against `gh` v2.x on this host, 2026-08-18. Owner: `jleechanorg`.

## Canonical query — merged within N days

```bash
gh pr list --repo <owner>/<repo> --state merged \
  --json number,title,mergedAt,labels,url \
  --limit 200 \
  --search 'merged:>=YYYY-MM-DD'
```

Field set:
- `number` — int PR number
- `title` — full title (may include `[agento]`, `model/Name:`, conventional-commit prefix)
- `mergedAt` — ISO-8601 UTC timestamp
- `labels` — array of `{id, name, description, color}`; treat presence of `"factory"` label as light signal only
- `url` — short URL form `https://github.com/<owner>/<repo>/pull/<n>`; some `gh` versions return only `number`, so synthesize if missing

## Common variants

| Variant | `--search` expression | Notes |
|---|---|---|
| Merged after date (inclusive) | `merged:>=2026-08-05` | preferred for "last N days" reports |
| Merged strictly after | `merged:>2026-08-05` | excludes the boundary day |
| Merged in date range | `merged:2026-08-05..2026-08-18` | exhaustive for narrow windows |
| Updated in window | `updated:>=2026-08-05` | catches still-open PRs |
| Created by bot | `author:app/github-actions` | rarely useful; filter post-hoc by title prefix |
| With label | `merged:>=2026-08-05 label:factory` | underused — `--label` flag is cleaner: `gh pr list --label factory ...` |

## Open vs merged

- `--state open` → current open PRs catalog (no time filter useful past ~30d; backlog churn)
- `--state merged` → historical; the only state this skill uses by default
- `--state closed` → merged + closed-not-merged; rarely needed

Combined with `--state all`: scope fuzzes, accuracy drops. Avoid for fleet rollups.

## JSON field expansion

```bash
gh pr list --repo OWNER/REPO --state merged \
  --json number,title,mergedAt,labels,url,author,baseRefName,headRefName,mergeCommit \
  --limit 200 --search 'merged:>=2026-08-05'
```

`mergeCommit.oid` is the SHA on default. Useful if you then need `git log mergeCommit` for a deeper audit.

## Worked sample — 2026-08-18 sweep

Driver script outline (Python) — runs in one `execute_code` call against the `terminal` helper:

```python
import shlex, json
from hermes_tools import terminal

repos = [
    "jleechanorg/agent-orchestrator",
    "jleechanorg/jleechanbrain",
    "jleechanorg/dark-factory",
    "jleechanorg/cmux",
    "jleechanorg/ai_universe",
    "jleechanorg/ai_universe_frontend",
    "jleechanorg/ralph",
    "jleechanorg/browserclaw",
    "jleechanorg/mcp_mail",
    "jleechanorg/cindil-health",
    "jleechanorg/hermes-agent",
    "jleechanorg/ez-gh-actions",
    "jleechanorg/disk_magician",
    "jleechanorg/worldai_claw",
    "jleechanorg/llm_inspector",
    "jleechanorg/jleechanbrain",
    "jleechanorg/heretic-lab",
    "jleechanorg/worldarchitect.ai",
]

results = {}
for repo in repos:
    cmd = (
        f"gh pr list --repo {shlex.quote(repo)} --state merged "
        "--json number,title,mergedAt,labels,url --limit 200 "
        "--search 'merged:>=2026-08-05'"
    )
    r = terminal(cmd, timeout=60)
    out = r.get("output","") if isinstance(r, dict) else str(r)
    try:
        results[repo] = json.loads(out)
    except Exception as e:
        results[repo] = {"err": str(e), "raw": out[:200]}
```

Real output (excerpt, 2026-08-18 14d):

| Repo | Count |
|---|---:|
| `jleechanorg/worldarchitect.ai` | 144 |
| `jleechanorg/dark-factory` | 42 |
| `jleechanorg/worldai_claw` | 27 |
| `jleechanorg/jleechanbrain` | 8 |
| (others) | 0 |

## Classifier — conventional-commit with agent prefixes

```python
import re
from collections import Counter

CONVENTIONAL_RE = re.compile(
    r"(?:^\[[^\]]+\]\s*)?"         # [agento] / [claude/MiniMax-M3] / [antig]
    r"(?:[A-Za-z0-9._/-]+:\s?)?"   # gemini/gemini-3.7-flash:
    r"(?P<type>[a-zA-Z]+)"
    r"(?:\([^)]*\))?"
    r"(?P<sep>!?:|!|\s)"
)
TYPE_TO_KIND = {
    "feat":"feature","fix":"bug","revert":"bug",
    "chore":"chore","refactor":"chore","docs":"chore","test":"chore","style":"chore",
    "perf":"infra","ci":"infra","build":"infra","harness":"infra",
}

def classify(title: str) -> str:
    m = CONVENTIONAL_RE.match((title or "").strip())
    if m:
        return TYPE_TO_KIND.get(m.group("type").lower(), "chore")
    low = (title or "").lower()
    if low.startswith(("fix(","fix ")) or " fix(" in low or low.startswith("revert"):
        return "bug"
    if low.startswith(("feat(","feat ")) or " feat(" in low:
        return "feature"
    return "chore"
```

Result over 221 PRs in 2026-08-18 sweep: bug 115, chore 57, feature 36, infra 13.

## Companion artifact script

`scripts/emit_summary.py` — produce the human-readable companion markdown:

```python
import json
from collections import Counter, defaultdict

with open("/tmp/gh-prs-14d.json") as f:
    prs = json.load(f)

by_kind = Counter(r["kind"] for r in prs)
by_repo_kind = defaultdict(lambda: Counter())
for r in prs:
    by_repo_kind[r["repo"]][r["kind"]] += 1

lines = [f"# 14d PR/Report Summary — window",
          f"", f"Total: {len(prs)}", ""]
for k,v in by_kind.most_common():
    lines.append(f"- **{k}**: {v}")
lines += ["", "## Repo × kind", "",
          "| repo | bug | feature | infra | chore | total |",
          "|---|---:|---:|---:|---:|---:|"]
for repo in sorted(by_repo_kind):
    c = by_repo_kind[repo]
    total = sum(c.values())
    lines.append(f"| {repo} | {c['bug']} | {c['feature']} | {c['infra']} | {c['chore']} | {total} |")

# top-15 lists per kind
for kind in ("bug","feature","infra","chore"):
    lines += ["", f"## Top 15 {kind} (most recent first)"]
    for r in sorted([r for r in prs if r["kind"]==kind],
                    key=lambda r: r["mergedAt"], reverse=True)[:15]:
        lines.append(f"- [{r['repo']}#{r['number']}]({r['url']}) — {r['mergedAt'][:10]}  {r['title']}")

with open("/tmp/gh-prs-14d-summary.md","w") as f:
    f.write("\n".join(lines))
```
