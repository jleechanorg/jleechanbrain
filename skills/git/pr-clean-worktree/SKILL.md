---
name: pr-clean-worktree
description: Create a fresh worktree from origin/main and commit PR changes into it — no pollution from unrelated commits
category: git
---

# PR Clean Worktree — Create a Pollution-Free PR

Every PR must be built on a fresh worktree cloned from `origin/main`. No commits from previous sessions, no stale files, no cross-contamination.

## ⚠️ CRITICAL: Worktree BEFORE Code

**NEVER edit files in the main worktree (the one you're reading this from) when preparing a PR.**

The failure pattern that caused this skill to be strengthened:
> Edit code → commit in main worktree → create PR → PR has wrong commits → polluted PR

The correct sequence is:
1. Create fresh worktree from `origin/main` FIRST
2. Make all code changes in the fresh worktree
3. Commit and PR from the fresh worktree

If you already edited the main worktree by mistake:
- Close the bad PR
- Cherry-pick your commit(s) into a fresh worktree (see Fixing a Polluted PR below)

## When to Use

- Creating any new PR
- Any time you would `git commit` and then `gh pr create`
- **Never** build a PR from an existing worktree that has unrelated commits

## Pattern: One-Shot Worktree + PR

### Step 1 — Create fresh worktree from origin/main

```bash
cd <repo_root>
git fetch origin main
git worktree add ../worktree_<purpose> -b worktree_<purpose> origin/main
```

e.g. `git worktree add ../worktree_zfclevel -b worktree_zfclevel origin/main`

**Rule: Always use `origin/main` as the starting point. Never use HEAD, a branch, or a dirty ref.**

### Step 2 — Verify clean slate

```bash
cd ../worktree_<purpose>
git log --oneline origin/main..HEAD   # should be empty
gh pr diff <owner>/<repo> --name-only # should be empty
```

If anything appears, stop. The worktree is not clean — destroy it and retry.

### Step 3 — Make your changes inside the worktree

Add files, edit, test — all normal work inside the fresh worktree.

### Step 4 — Commit only your changes

```bash
git add <your files>
git commit -m "<conventional commit msg>"
```

### Step 5 — Push and create PR

```bash
git push -u origin worktree_<purpose>
gh pr create \
  --head worktree_<purpose> \
  --title "<title>" \
  --body-file /tmp/pr_body.txt \
  --repo <owner>/<repo>
```

### Step 6 — Verify PR diff is exactly what you intend

```bash
gh pr diff <pr-number> --repo <owner>/<repo> --name-only
```

Compare against what you expect. If extra files appear, the worktree was not clean — **do not proceed**. Fix the root cause.

## Common Pollution Sources

| Symptom | Cause | Fix |
|---------|-------|-----|
| Extra files in PR diff | Worktree started from non-main ref | Destroy and recreate from `origin/main` |
| Stale commits in PR | Cherry-picked from dirty worktree | Always reset --hard to origin/main first |
| Unrelated changes included | worktree not clean before first commit | Always `git log origin/main..HEAD` before committing |
| Force-push rejected | Remote branch has newer commits | Fetch + `--force-with-lease` |
| `gh pr create` fails with "push first" | Branch not pushed before `gh pr create` | Push before creating PR |

## Fixing a Polluted PR

If a PR already has pollution (wrong files, wrong commits):

1. **Do not amend/patch over it** — the fix is to reset
2. Find the base commit: the last clean commit from `origin/main` before any of your changes
3. In the worktree:
   ```bash
   git fetch origin
   git reset --hard origin/main
   git cherry-pick <commit-A> <commit-B> ...  # only your legitimate commits
   git push --force origin worktree_<purpose>
   ```
4. Verify: `gh pr diff --name-only` shows only your intended files
5. If you cannot cleanly isolate, **destroy the worktree and recreate from scratch**

## ~/.smartclaw Symlink Gotcha

`~/.smartclaw/SOUL.md` is a **symlink** to `workspace/SOUL.md`. This affects hermes-repo PR work:

- `~/.smartclaw/SOUL.md` resolves to `~/.smartclaw/workspace/SOUL.md` — there is no real file at the top level
- `git add SOUL.md` from `~/.smartclaw/` stages `workspace/SOUL.md` (correct)
- `git status` at `~/.smartclaw/` shows changes in `workspace/SOUL.md`, not a separate file
- `git log SOUL.md` from `~/.smartclaw/` checks `workspace/SOUL.md`'s history
- Always `git add workspace/SOUL.md` explicitly to avoid confusion

When committing hermes SOUL.md changes, the commit lands on the current branch of `~/.smartclaw/`. Push to origin before deploying.

## Cleanup

When PR is merged, delete the worktree:
```bash
git worktree remove ../worktree_<purpose>
git branch -d worktree_<purpose>
```

## Verification Checklist Before Every PR

- [ ] Worktree created with `origin/main` as starting point
- [ ] `git log origin/main..HEAD` is empty (no pre-existing commits)
- [ ] All commits in the branch are yours (verified by commit message author)
- [ ] `gh pr diff --name-only` shows only intended files
- [ ] No IME artifacts, debug print statements, or temp files
- [ ] PR title and body are accurate to the diff
