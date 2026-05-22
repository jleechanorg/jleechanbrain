---
name: worktree-from-ambiguous-origin-main
version: 1.0.0
description: Fix "ambiguous origin/main" when creating git worktrees — use remotes/origin/main instead
---

# worktree-from-ambiguous-origin-main

Use when creating a git worktree for a PR-bound branch and `git worktree add ... origin/main` fails with "ambiguous object name".

## The Problem

When a repo has both a local branch named `main` AND a remote tracking branch at `remotes/origin/main`, typing `origin/main` is ambiguous — git's disambiguation rules pick the local `main` first, causing:

```
fatal: ambiguous object name: 'origin/main'
```

## The Fix

Always use the fully-qualified remote reference:

```bash
git worktree add ../worktree_name -b worktree/branch-name remotes/origin/main
```

## What NOT to use

```bash
git worktree add ... origin/main        # FAILS — ambiguous
git worktree add ... main               # uses local main (may be stale)
git worktree add ... refs/heads/main     # also local
```

## Why This Matters for PR Worktrees

You want the worktree based on `origin/main` (fresh remote state), not the potentially stale local `main` branch. The `remotes/origin/main` syntax guarantees this.

## Verification After Creation

```bash
git log --oneline -1   # should match origin/main HEAD
git status             # on correct branch
```

## Related

- `pr-clean-worktree` skill — full PR-bound worktree lifecycle (create → work → commit → PR)
