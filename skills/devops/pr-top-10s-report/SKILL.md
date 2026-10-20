---
name: pr-top-10s-report
description: "Use when user asks for top 10 PRs. Produces ranked PR lists."
tags: [pr, github, top-n, ranking, roadmap, audit, merge]
---

# PR Top-10s Report — ranked OPEN PR lists (bug fixes + features)

**Class:** GitHub PR data extraction + classification + ranking + report publish. **Output:** Markdown report pushed to `jleechanorg/roadmap` (canonical) + commit URL posted back to originating Slack thread.

## Trigger Phrases

- "top 10 bug fix PRs" / "top 10 feature PRs" / "top 10 PRs"
- "ranked PR list"
- "what PRs should I merge"
- `/roadmap` (when the user wants PR-level output, NOT issue-level)
- "non-prod merge approved" (subset: filter to `mergeable=MERGEABLE`)

## Inputs

| **repos** | list of `owner/repo` paths (default: all 20+ `jleechanorg/*` with ≥1 open PR) |
| **window_days** | default 14 |
| **top_n** | default 10 |
| **output_repo** | default `jleechanorg/roadmap` (canonical roadmap repo, `main` branch) |
| **include_kinds** | default `["bug", "feature"]`; can add `["chore", "infra"]` for broader reports |

## Pipeline

### Step 1 — Per-repo PR pull (parallel, batch ≤ 6)

```bash
gh pr list --repo <owner>/<repo> --state open --limit 100 \
  --json number,title,headRefName,isDraft,mergeable,additions,changedFiles,createdAt,updatedAt,author,labels,url,baseRefName
```

Loop over all repos in scope. **Do NOT** skip repos with low activity — even 1 PR from a small repo can be top-10 if it's recently updated and small-diff.

### Step 2 — Classify by conventional-commit prefix

The regex tolerates `[agento]`, `[antig]`, `[claude-code/...]`, `[codex/...]`, `[gemini/gemini-3.7-flash]`, `[claudem/MiniMax-M3]`, and bare prefixes (no agent label). Fall back to keyword match on first 30 chars of title.

```python
import re
CONV_BUG = re.compile(r'(?:\[[^\]]+\]\s*)?(?:\(?\s*)?fix\s*\(', re.IGNORECASE)
CONV_FEAT = re.compile(r'(?:\[[^\]]+\]\s*)?(?:\(?\s*)?feat\s*\(', re.IGNORECASE)

def classify(title: str) -> str:
    if CONV_BUG.search(title): return 'bug'
    if CONV_FEAT.search(title): return 'feature'
    return 'other'
```

### Step 3 — Score

```python
def pr_score(p):
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
```

### Step 4 — Filter + sort + take top N

- `isDraft = false`
- `updatedAt >= window_start` (default 14d back from now)
- `kind in include_kinds`
- Sort by `pr_score` descending, take top N

### Step 5 — Build Markdown report

Sections (mandatory order):
1. Header: window, generation time, repo count, PR counts by kind
2. **§1 Top N Open Feature PRs** (table with score, repo#N, title, files, +/-, merge state, "Why high-pri" column)
3. **§2 Top N Open Bug PRs** (same shape)
4. (Optional) **§3 Non-prod MERGEABLE PRs** — additional filter `mergeable=MERGEABLE + ≤15 files + non-draft + not already in top-N`
5. (Optional) **§4 Unresolved Slack threads** — bonus if the user asked for them
6. **§5 Verification** — repos scanned, totals, slack coverage gaps
7. **§6 Recommended actions** — `MERGE APPROVED` suggestions for the smallest MERGEABLE PRs

The "Why high-pri" column is the operator's anchor — it must be one line grounded in:
- recency (`updatedAt`)
- comment count or label priority if visible
- bug class (P0 regression / latency / dice integrity / security)
- whether the PR closes a tracked issue (`Closes #NNNN` in title)
- whether the PR is self-referential (fixes the very system that produced this report)

### Step 6 — Push to roadmap repo (MANDATORY, verified 2026-08-19)

User correction 2026-08-19: "shouldn't /roadmap make a doc in ~/roadmap repo and link me the gh url?" — confirms the repo push is required, not optional. **Every PR-top-10s report pushes to `jleechanorg/roadmap` on `main`.**

```bash
cd ${HOME}/roadmap

# Pre-flight: fetch + check ahead/behind
git fetch origin
git status --branch --short  # check if "ahead" or "behind"

# If working tree has unrelated dirty state (sidekick/, .beads/, nextsteps-*, STATE.md),
# preserve via stash cycle (verified 2026-08-18 + 2026-08-19):
git stash push --keep-index --include-untracked -m "preserve-sidekick-dirty"
# --keep-index is critical: keeps your staged report file, moves sidekick state to stash

git pull --rebase origin main  # safe now (clean tree)
git push origin main           # or use git secret guard wrapper if available

git stash pop  # restore sidekick state for other owners
```

Commit message format (must follow the env-preferences rule):
```
hermes/minimax-M3: docs(roadmap): <PR-level top-N report description>
```
Use `hermes/<model>:` prefix. Do NOT co-commit sidekick dirty state.

### Step 7 — Post the gh URL to the originating Slack thread

Reply in-thread with:
1. The commit URL: `https://github.com/jleechanorg/roadmap/commit/<sha>`
2. Top 10 Feature PRs (markdown table)
3. Top 10 Bug PRs (markdown table)
4. (Optional) Top 10 Unresolved Threads
5. Recommended actions / `MERGE APPROVED` hints

Per `slack-never-hand-post-your-own-reply`: just return as normal model output; the gateway threads it.

## Pitfalls (verified)

- **Top-10s are PR-level, NOT issue-level** (user correction 2026-08-19: "should be top 10 feature PRs and top 10 bug fix PRs"). The canonical format reference is `top10_open_prs_refresh_2026_08_04.md`. Issues are "what needs fixing" — PRs are "what can ship". Conflating them produces a useless report for `MERGE APPROVED <N>` batch-merge dispatch.

- **Conventional-commit prefix tolerance is mandatory.** Verified 2026-08-19 — the bare regex `re.compile(r'fix\s*\(')` matched only 60% of real PRs. Adding `(?:\[[^\]]+\]\s*)?` for `[agento/antig/claude/...]` labels brought it to 100%.

- **`mergeable=UNKNOWN` ≠ `CONFLICTING`.** Verified 2026-08-19 — `UNKNOWN` means GitHub hasn't computed mergeability yet (re-poll in 30s). Don't penalize these; treat as mergeable for the "non-prod merge approved" subset. Re-poll with `gh pr view <N> --json mergeable` if needed.

- **The roadmap repo working tree is usually dirty** (sidekick/, .beads/, nextsteps-*, STATE.md files from other agents). Verified 2026-08-18 + 2026-08-19 — the `git stash --keep-index --include-untracked` cycle is the only safe way to push without co-committing unrelated state. Without `--keep-index`, your staged report gets stashed too.

- **`git pull --rebase` blocks on dirty tree.** Verified — "cannot pull with rebase: You have unstaged changes. please commit or stash them." Always stash first if dirty state exists.

- **Repo push is REQUIRED, not optional.** User correction 2026-08-19. Don't shortcut to local-only save. The operator explicitly expects the gh URL.

- **Skew is normal.** `worldarchitect.ai` typically has 60-80% of all open PRs in the org. The top-N will skew that way. Document in §5 Verification, don't try to "balance" by mixing in unrelated repos.

- **`-` / `+` line counts are not always available.** `additions` may be `null` for very new PRs (GitHub hasn't computed yet). Show as `—` in the table, don't fail the report.

## Cross-references

- `roadmap` SKILL.md — the umbrella orchestrator that invokes this skill for the PR-list sections. NOTE: `roadmap` is currently user-owned (`created_by=None`); recommend `hermes curator adopt roadmap` to enable in-skill patches.
- `slack-history-sweep` SKILL.md — covers the Slack half (top 10 unresolved threads); this skill covers the GitHub PR half
- `drive-pr-to-green` / `workflow/drive-pr-to-green` SKILL.md — handles `MERGE APPROVED` batch-merge dispatch downstream
- `git-dirty-tree-triage` SKILL.md — the general technique for pushing when the working tree has unrelated changes

## Verified instance — 2026-08-19

Created from a user-correction session: operator originally asked for top-10s without specifying PR vs issue; report was first delivered with GitHub issues (filed bugs/features), then operator corrected "should be top 10 feature PRs and top 10 bug fix PRs". Second pass scanned 20 `jleechanorg/*` repos for OPEN PRs, classified via `CONV_BUG/CONV_FEAT` regex, ranked by `recency + mergeability + diff size`, pushed to `jleechanorg/roadmap@5a1c742` (commit `5a1c7426bb62b8502b8d8c954ee0c9cfeaf8365c`), posted commit URL back to the thread.

Top bug-fix PR #1: `worldarchitect.ai#8935` (`fix(prompts): strengthen state_updates for long rest timestamps`, 2 files, MERGEABLE)
Top feature PR #1: `dark-factory#653` (`feat(daemon): reap idle worker tmux sessions on Attested promotion`, 5 files, MERGEABLE)
