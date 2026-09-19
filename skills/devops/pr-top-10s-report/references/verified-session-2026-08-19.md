# Verified session — 2026-08-19

## Original user request (Slack #all-jleechan-ai)

```
Run /roadmap for last 2 weeks and pick top 10 bug fixes and top 10 feature requests
like the skill says and maybe top 10 unresolved slck threads
```

## What the first pass did (wrong)

- Scanned 18 `jleechanorg/*` repos for **GitHub issues** (filed bugs/features) using `gh issue list --state open`
- Ranked by score `recency × 3 + comments × 2 + priority_label_value`
- Output: 10 issues for each list, all from `worldarchitect.ai` (skew)
- Pushed to local `~/roadmap/` only — **DID NOT push to `jleechanorg/roadmap` repo**

## User corrections (turn-by-turn)

1. **"shouldn't /roadmap make a doc in ~/roadmap repo and link me the gh url? for the PRs we want that are non prod merge approved. For the others explain why they are high pri"**
   - Repo push is REQUIRED
   - Need MERGEABLE PR list for non-prod merge approval
   - Need "Why high-pri" rationale column

2. **"Dont you see the /roadmap skill? it should be top 10 feature PRs and top 10 bug fix PRs"**
   - The report was issue-level, NOT PR-level
   - Top-10s are PR-rank, not issue-rank

## What the second pass did (right)

- Scanned 20 `jleechanorg/*` repos for **OPEN PRs** using `gh pr list --state open`
- Classified via conventional-commit regex:
  ```python
  CONV_BUG = re.compile(r'(?:\[[^\]]+\]\s*)?(?:\(?\s*)?fix\s*\(', re.IGNORECASE)
  CONV_FEAT = re.compile(r'(?:\[[^\]]+\]\s*)?(?:\(?\s*)?feat\s*\(', re.IGNORECASE)
  ```
  Tolerates `[agento]`, `[antig]`, `[claude-code/...]`, `[codex/...]`, `[gemini/gemini-3.7-flash]`, `[claudem/MiniMax-M3]`, bare prefix.
- Scored by `recency (5/3/1) + mergeable (4=MERGEABLE, 1=CONFLICTING) + diff size (3/1/-2) - isDraft (-5)`
- Built Markdown with sections: Top 10 Feature PRs / Top 10 Bug PRs / Optional Top 10 Unresolved Slack Threads / Optional Non-prod MERGEABLE PRs / Verification / Recommended actions
- Pushed to `jleechanorg/roadmap@5a1c742` via stash-rebase-pop cycle to preserve sidekick dirty state
- Posted the commit URL back to the originating Slack thread

## Numbers

| Metric | Value |
|--------|------:|
| Repos scanned | 20 |
| Total OPEN PRs | 378 |
| Non-draft + updated in 14d window | 215 |
| bug kind | 145 |
| feature kind | 52 |
| chore kind | 27 |
| other | 154 |

## Top bug-fix PR

`worldarchitect.ai#8935` — `fix(prompts): strengthen state_updates requirements for long rest timestamps and spell slot consumption` (2 files, MERGEABLE)

## Top feature PR

`dark-factory#653` — `[antig] feat(daemon): reap idle worker tmux sessions on promotion to Attested` (5 files, MERGEABLE)

## Self-referential PR found in scan

`openclaw#827` — `fix(cron): dropped-thread-followup died mid-run since 2026-08-11 (set -e abort on detect_active_lock_fail)` — the very cron that fires when a thread goes cold was itself broken. Closed the loop by surfacing it in the report.

## Lessons captured into `pr-top-10s-report` SKILL.md

1. Top-10s are PR-level, NOT issue-level (user correction)
2. Conventional-commit prefix regex tolerance is mandatory (`(?:\[[^\]]+\]\s*)?`)
3. `mergeable=UNKNOWN` ≠ `CONFLICTING`
4. Roadmap repo working tree is usually dirty → stash-rebase-pop cycle
5. `git pull --rebase` blocks on dirty tree
6. Repo push is REQUIRED, not optional (user correction)
7. Skew toward `worldarchitect.ai` is normal — document, don't try to balance

## Companion artifact

`jleechanorg/roadmap@5a1c742` — `2026-08-19-0412Z-roadmap-14d-top-10s.md` (13.5 KB)
