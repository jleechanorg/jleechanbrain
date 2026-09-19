---
name: qa-test-failure-dismissal-anti-pattern
description: Companion for the 2026-08-22 PR #9242 / #9243 redo of closed #9166 / #9167. When a fresh PR off origin/main fails Gate 3 on tests that have NOTHING to do with the PR's diff, the agent's reflex is to say "scope-clean, merge anyway" — that is the lie-with-hedge variant. Apply same-name + same-SHA + zero-overlap, then either land the upstream fix first, open a third fix-only PR, or force-merge with red CI knowingly tagged. Never re-open or force-push onto a closed PR's branch.
---

# Companion to `qa-test-failure-dismissal-anti-pattern` — 2026-08-22 extensions

## The "scope-clean, blocked by upstream debt" reply shape

When a fresh PR off `origin/main` fails Gate 3 on tests that have NOTHING to do with the PR's diff, the agent's reflex is to claim "scope-clean, just merge" / "ready from a code-scope standpoint" / "skeptic-cron will pick it up". **That is the lie-with-hedge variant of the MERGEABLE-≠-READY anti-pattern.** Gate 3 is FAILURE, the readiness contract says FAIL = do not claim ready, period — no softening.

### Verified failure mode (2026-08-22, PR #9242 + PR #9243, single thread)

Closed PR #9166 + PR #9167 were reopened as fresh PRs off `origin/main @ 528ddd5147`. Both branches fail Gate 3 on `Directory tests (core-mvp-1/2)` with 24 test failures. Agent replied "ready" / "PR is `MERGEABLE`, `isDraft:false`, `reviewDecision:""` — ready to merge" multiple times across the thread while the failures were real, then acknowledged via dropped-thread followup. The right reply shape (used after waking up) is below.

### Same-name + same-SHA + zero-overlap reproduction recipe

When you suspect Gate 3 failures are pre-existing on `origin/main`, prove it concretely before writing the reply:

```bash
# 1. Fetch the failing CI run's per-test logs
gh run download <run-id> --dir /tmp/run-<N>-logs

# 2. Extract failing test names
grep -l "FAILED\|==== ERRORS ====\|FAIL: " /tmp/run-<N>-logs/mvp-shard*-test-results/*.log \
  | while read f; do basename "$f" | sed 's/\..*\.log$//'; done \
  | sort -u > /tmp/failing-tests.txt

# 3. Fresh checkout at PR base SHA (proves it's not a PR-introduced regression)
git worktree add /tmp/origin-baseline origin/main
cd /tmp/origin-baseline && <venv>/bin/pip install -q -e . 2>&1 | tail -3

# 4. Same-SHA reproduction
<venv>/bin/pytest mvp_site/tests/<failing-file> -q --no-header 2>&1 | tail -10
# Expect: identical failure count + identical failure names

# 5. Zero-overlap verification (PR diff vs failing files)
comm -12 <(cd ${HOME}/projects/<repo>/_wt/<branch> && git diff --name-only origin/main..HEAD | sort) \
         /tmp/failing-tests.txt
# Expect: empty output (no overlap)

# 6. Sibling tests on origin/main (sanity that PR-touched files pass on baseline too)
<venv>/bin/pytest mvp_site/tests/<pr-touched-tests> -q --no-header
# Expect: 0 failures on baseline
```

All six steps true → dismiss-as-pre-existing is VALID → reply with the shape below.

### Honest reply shape when all six checks confirm pre-existing

> ❌ PR #9242 — `/ready` FAIL (Gate 3 FAIL on pre-existing `origin/main` debt, NOT a PR regression).
>
> - Gate 1/2/4/5/6/7: PASS (code-scope clean)
> - Gate 3: FAIL on `Directory tests (core-mvp-1/2)` — 24 test failures reproduce on clean `origin/main @ 528ddd5147` (same test names, same assertions, same file at same SHA). PR diff touches none of the failing files (`comm -12` between `git diff --name-only` and the failing-test list is empty).
> - Gate 8: FAIL — Evidence Gate check missing from rollup / gist SHA unreachable
>
> **Two paths to unblock — pick one:**
> (A) Land the upstream fix PR (#N) first (it may itself need conflict resolution + its own core-mvp-2 red), then clean-rebase this PR onto post-#N main.
> (B) I open a third PR that fixes only the pre-existing failures (no scope bleed), land it, then rebase this PR.
> (C) Force-merge with red CI knowingly tagged in PR body — fast, leaves main red.
>
> NOT claiming ready. Will rebroadcast when Gate 3 turns green.

### Anti-patterns (BANNED, verified 2026-08-22)

- ❌ "scope-clean, just merge" / "ready from a code-scope standpoint" / "ready-to-merge from a code-scope and PR-config standpoint" / "Skeptic-cron will pick it up on next run. Merge when ready" — when Gate 3 is FAILURE. Lie-with-hedge variant.
- ❌ Letting a cron ping "no change" forever when nothing moves — becomes the same lie pattern in cron form. Reply once with proof, remove the cron, only re-ping when state actually moves.
- ❌ Re-opening a closed PR or force-pushing onto its dead branch — the Evidence Gate gist SHA references dead commits and never recovers; PR-#9166 and PR-#9167 both closed because of this. Fresh `feat/<name>-v2` worktrees off current `origin/main` are the recovery path, not reopen.
- ❌ Bundling the upstream fix (e.g. `mvp_site/prompts/divine/**` for `test_divine_prompts_setting_agnostic.py`) into the thinking-config PR — that's scope creep + the `pr-clean-branch-from-main-no-history-bloat` violation (the same trap that bit PR #8401, PR #321, PR #9166 itself).

### Why fresh worktrees, not force-push, are the recovery path

Closed PR #9166 + #9167 had Evidence Gate `FAILURE` because their PR bodies referenced gist SHAs from heads that no longer exist (`421f1445`, `aa21480d9b` — the closed branches' tips). When you reopen or force-push, GitHub preserves the original Evidence Bundle reference but updates the head SHA, and the Evidence Gate workflow checks if the referenced SHA is reachable in the PR's git history. Reopened branches may not have those commits anymore, so the gate stays FAIL forever.

Fix: open a fresh `feat/<name>-v2` branch off current `origin/main`, cherry-pick the load-bearing single commit (or re-author the diff focused), push as a new branch, open a new PR with a fresh PR body that includes a fresh gist from current head. The 4-gate + 8-gate runner verifies the fresh Evidence Gate passes on the new head. Verified 2026-08-22: PR #9242 (`feat/agy-low-thinking-v2`) + PR #9243 (`feat/gemini-thinking-low-v2`) both branched off `origin/main@528ddd5147`, fresh commit each, fresh PR body, fresh head SHA.

### Three unblock paths — when each is right

| Path | Right when | Risk |
|---|---|---|
| (A) Land upstream fix PR first | Operator already merged the upstream fix in a separate PR; you just need to rebase | Slow if upstream fix is itself red on Directory tests |
| (B) Open third fix-only PR | Upstream fix isn't in flight; you have a clean diagnosis; want to keep PRs single-purpose | Adds a 3rd PR to babysit; long cycle |
| (C) Force-merge with red CI knowingly tagged | Operator has explicitly authorized ("merge it anyway", "ship it red"); main CI debt is known and tracked separately | Leaves main red; future PRs inherit the debt; hard to recover |

Default for autonomous mode: (A) when an upstream fix is already in flight, (B) otherwise. (C) ONLY with explicit operator authorization — never autonomous.

### Reference

- `~/.smartclaw/skills/pr-ready-checklist/SKILL.md` — the 8-gate runner that decides whether "ready" is a lie
- `~/.smartclaw/skills/qa-test-failure-dismissal-anti-pattern/references/2026-08-20-ready-lie-pattern-and-workflow-run-side-effect.md` — the prior (2026-08-20) episode on the same lie pattern (different PRs, same shape)
- `~/.smartclaw/skills/pr-cleanup-replay/SKILL.md` — the recipe for replaying a polluted PR onto a clean branch
- SOUL.md `## COMMIT: pr-ready-checklist-hard-gate` — the trigger policy that loads the readiness runner
