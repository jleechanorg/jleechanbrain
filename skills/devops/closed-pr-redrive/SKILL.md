---
name: closed-pr-redrive
description: Redrive closed PRs off origin/main with repro proof.
version: 1
author: hermes
license: MIT
metadata:
  hermes:
    tags: [github, pr, recovery, ci]
    related_skills: [pr-cleanup-replay, qa-test-failure-dismissal-anti-pattern, pr-ready-checklist, always-pr-never-local-edit]
---

## When to Use

When prior PRs closed without merging (red CI, merge conflicts, Evidence Gate pointing to dead SHAs) and need to be redone cleanly. Force-push / reopen / cherry-pick tricks **do not recover** closed PRs — the honest redo is a fresh worktree off current `origin/main` with same-SHA repro proof + scope separation from upstream CI debt.

Trigger phrases:
- "redo the closed PR"
- "this PR closed but I still need it"
- "drive [N] to merge" when [N] is CLOSED
- "why did my PR close"
- "the redrive pattern"

## Recipe (8 steps)

1. **Verify state honestly.** `gh pr view <N> --json state,mergedAt,closedAt,headRefName` — confirm CLOSED, never merged. Do NOT trust cached "ready" replies from prior turns.

2. **Fresh worktree off CURRENT `origin/main`:**
   ```bash
   git fetch origin
   git rev-parse origin/main  # capture SHA
   git worktree add /path/_wt/<feat>-v2 -b feat/<feat>-v2 origin/main
   ```

3. **Extract the LOGIC changes** (not the full prior diff — prior PRs often have ruff-reformatting noise, unintended unrelated edits, or merged-in CI-debt fixes). Use `git show <prior-PR-head>` as a reference, not a `git diff` to apply.

4. **Apply focused patches** to the fresh worktree with `patch` tool. Keep diff budget tight: <1000 lines for `mvp_site/**` changes per repo conventions.

5. **Run targeted tests locally:**
   ```bash
   cd /path/_wt/<feat>-v2
   TESTING_AUTH_BYPASS=true <venv>/bin/pytest <the-touched-test-file> -q
   ```
   Confirm green before push.

6. **Apply the `qa-test-failure-dismissal-anti-pattern` same-name + same-SHA rule for any pre-existing CI red on `origin/main`:**
   - Same test name? (exact `pytest path::class::test_method`)
   - Same assertion? (same error line)
   - Same file at same commit?
   - Same-SHA reproduction? (run failing tests on clean `origin/main` clone)
   - **Zero-overlap check:** `git diff --name-only origin/main..HEAD | sort` vs the failing test files — must be empty.

7. **Commit + push + open PR** with proof in body:
   ```
   - Branch: feat/<name>-v2 off origin/main@<sha>
   - Diff: N files, +X/-Y
   - Tests: M/N pass, K/K new tests pass
   - Pre-existing CI red: N tests reproduce on clean origin/main@<sha>, diff touches 0 of them
   ```

8. **Do NOT claim "ready"** until `pr_ready_checklist.sh` exits 0. If CI is red on upstream debt, say "scope-clean, blocked by upstream main red — operator choose: (A) merge upstream fix first, (B) ship in 3rd PR, (C) knowingly tag red."

## Pitfalls

- ❌ **Force-pushing to dead branches** — Evidence Gate gists reference the OLD head SHA; force-push doesn't change the gist reference, so the gate stays FAIL forever.
- ❌ **Reopening closed PRs** — `gh pr reopen` creates a new head ref but the upstream SHA the gate checks is still the closed one. Same problem.
- ❌ **`git cherry-pick <prior-PR-commits>`** — pulls the same dirty base, same unrelated edits, same merge conflicts.
- ❌ **Bundling upstream CI fixes into the redo PR** — scope creep + the `pr-clean-branch-from-main-no-history-bloat` violation. Land the upstream fix in its own PR first, then rebase.
- ❌ **Lying about "ready"** when CI is red — root cause of dropped-thread pings. Use exact script-verdict language.

## Verification

- `git diff --stat origin/main..HEAD` shows ONLY the intended scope (typically <1000 lines for `mvp_site/**`)
- `git log origin/main..HEAD` shows ONE focused commit (or logical chain), not a poll of unrelated history
- New worktree's local test runs match the original intent (e.g. 94/94 agy, 20/20 thinking_config)
- PR body cites exact `origin/main@<sha>` and pre-existing CI reproduction proof

## Related rules

- `pr-clean-branch-from-main-no-history-bloat` — never push onto non-clean base
- `never-push-onto-someone-elses-pr-head` — gate against polluting another PR's history
- `qa-test-failure-dismissal-anti-pattern` — same-name + same-SHA + zero-overlap proof
- `pr-ready-checklist-hard-gate` — never claim "ready" before exit 0

## Bug refs

- 2026-08-22 PRs #9166 + #9167 closed (CONFLICTING / Evidence Gate dead SHAs). Redrove as #9242 + #9243 off `origin/main@528ddd5147` with same-SHA repro proof on the 24 pre-existing Directory test failures. PR diffs touched 0 of the failing files.
