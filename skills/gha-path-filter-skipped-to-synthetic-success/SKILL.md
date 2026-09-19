---
name: gha-path-filter-skipped-to-synthetic-success
description: "Refactor GHA path-filter gates to emit synthetic-success."
version: 1.0.0
author: Hermes Agent
license: MIT
metadata:
  hermes:
    tags: [GitHub-Actions, CI, paths-filter, dorny, workflow-yaml, UX, skipped]
    related_skills: [github-pr-workflow, drive-pr-to-green]
---

# Convert Path-Filter-Gated GHA Jobs: Skipped → Synthetic-Success

A surgical YAML refactor that turns the GitHub Actions pattern "use `dorny/paths-filter` outputs as a job-level `if:` gate" into the cleaner pattern "always run the job, but emit a synthetic-success step when no relevant diff exists, and gate the heavy work at the step level." End result: PR checks render green checkmarks instead of yellow circles for irrelevant file groups.

## When to use this skill

Use it any time a workflow uses `dorny/paths-filter` (or any equivalent path-based gate) at the JOB level and you observe:

- `gh pr checks <N>` shows many `skipped` rows that confuse reviewers about whether CI is broken.
- A PR's diff only touches a few file groups, and reviewers see 8-12 yellow "skipped" circles on jobs that don't even apply.
- The user complaint pattern: "why so many skipped CI checks? Seems like it's many PRs."

**Do not use this skill** when:
- The skips are caused by `if: failure()` / `if: always()` style control flow — those are intentional and shouldn't be touched.
- The repo does not use path-based gating at all (the issue is real CI failure, not UX).
- The user wants the actual checks to run (e.g., docs-only PRs should still run smoke tests) — that's a different fix (broader paths filter).

## The 3-step surgical patch

For each gated job, do exactly three things:

### Step 1 — Strip the path-filter clause from the job-level `if:`

Original:
```yaml
jobs:
  python-lint:
    if: needs.detect-changes.outputs.python == 'true' && (github.event_name != 'pull_request' || (github.event_pull_request.head.repo.fork == false && github.event_pull_request.draft == false))
    steps:
      ...
```

After:
```yaml
jobs:
  python-lint:
    if: (github.event_name != 'pull_request' || (github.event_pull_request.head.repo.fork == false && github.event_pull_request.draft == false))
    steps:
      ...
```

The `&&` clause involving `outputs.<key> == 'true'` (or its multi-line `|` block scalar variant `(outputs.<key> == 'true' || github.event_name != 'pull_request')`) gets removed. Keep the fork / draft guard.

### Step 2 — Insert a synthetic-success step at the top of `steps:`

```yaml
    steps:
      - name: "No python-relevant changes - synthetic success"
        if: needs.detect-changes.outputs.python != 'true'
        run: |
          echo "::notice::No python-relevant changes in this PR; emitting synthetic success (filter: python)"
      # ... original steps below ...
```

This step has zero runner cost (one `echo` + `::notice` + `exit 0`). It runs ONLY when the filter is `false` and the event is a PR.

### Step 3 — Add step-level `if: outputs.<key> == 'true'` to EVERY non-synthetic step

For every existing step that does not already have an `if:` line directly under its `- name:` line, insert `if: needs.detect-changes.outputs.<key> == 'true'` immediately after the `- name: FOO` line.

**CRITICAL PITFALL — duplicate `if:` key:** YAML silently picks the LAST `if:` when you write two of them in the same mapping. So if a step ALREADY has `if: runner.os != 'macOS'` or `if: always()`, do NOT insert another `if:` line. Leave it alone. The reference patcher script (`scripts/patch_path_filter_skipped.py` in this skill) has a "peek next line for existing `if:`" guard that handles this automatically.

The reason every step needs the gate (not just the first one): some jobs have a `Repair workspace permissions` step BEFORE `Checkout repository`. Only gating `Checkout` would leak runner cost on no-diff PRs.

## YAML indentation rules (these vary by file)

- `presubmit.yml` uses 6-space-indented step entries with 8-space children.
- `test.yml` and `self-hosted-mvp-shard1.yml` use 4-space-indented step entries with 6-space children.

The reference patcher auto-detects the indentation by inspecting the first step's leading whitespace and matching it. If you patch by hand, match the indentation of existing steps exactly — wrong indentation causes YAML parse errors.

## The reference patcher

See `scripts/patch_path_filter_skipped.py` for a working, idempotent Python implementation. It:
- Validates that the workflow parses as YAML before AND after each job patch.
- Strips BOTH `presubmit.yml` single-line form (`outputs.X == 'true' && (...)`) AND `test.yml` / `shard1.yml` form (`(outputs.X == 'true' || github.event_name != 'pull_request')`).
- Auto-detects indentation by inspecting the first existing step.
- Skips steps that already have an `if:` line (avoiding the duplicate-key pitfall).
- Re-finds job regions on the current text after each mutation (handles multi-job files where regions shift).

To use it on a new repo:

```bash
# 1. Identify which jobs in which workflows need patching
gh api repos/<owner>/<repo>/contents/.github/workflows/presubmit.yml | jq -r '.content' | base64 -d | \
  python3 -c "import sys, yaml; d = yaml.safe_load(sys.stdin); [print(f'{j} uses {next((o for o in d[\"jobs\"][j].get(\"if\",\"\").split() if \"outputs\" in o), \"\")}') for j in d['jobs']]"

# 2. Edit the JOBS list in scripts/patch_path_filter_skipped.py to enumerate them

# 3. Run the patcher
python3 scripts/patch_path_filter_skipped.py

# 4. Run actionlint on every patched file
actionlint .github/workflows/*.yml
```

## Companion regression test

`scripts/tests/test_workflow_skip_synthetic_success.py` — 4 cases that run as a normal unittest:

1. All three workflow files parse as valid YAML.
2. No gated job's `if:` still references `detect-changes.outputs.*`.
3. Each gated job has exactly one synthetic-success step.
4. Every non-synthetic step has SOME `if:` gate (existing or newly added).

This catches the most common regression: someone later adds a new gated job and forgets to patch it. Run via:

```bash
python3 scripts/tests/test_workflow_skip_synthetic_success.py
```

## Why this matters (UX rationale)

Reviewers scan PR checks visually. Yellow `skipped` circles look broken. Green checkmarks look good. When 8 of 27 checks are yellow, the reviewer has to mentally compute "this is `skipped` because there's no Python diff in this PR, not because Python is broken" for each one — that's a tax on every reviewer of every PR in the repo.

A synthetic-success step costs ~1 second of runner time on a no-diff PR and zero diff-PRs (the synthetic step is skipped, the heavy work runs). That's strictly better than the prior skipped behavior.

## Anti-patterns

- ❌ Inserting `if:` BEFORE the `- name:` line — YAML expects `if:` to be a child key of the step dict.
- ❌ Inserting `if:` on the SAME line as `- name: FOO` — produces malformed YAML.
- ❌ Inserting `if:` after a step that already has its own `if:` (e.g. `runner.os != 'macOS'`) — YAML silently overrides the original control flow with the new one. The result is broken macOS behavior, even when there IS a relevant diff.
- ❌ Adding `if: outputs.X == 'true'` to ALL existing steps unconditionally — same duplicate-key issue.
- ❌ Leaving the job-level path-filter gate in place AND adding the synthetic step — the synthetic never runs because the job-level gate already short-circuits.
- ❌ Replacing the synthetic step's `run: |` with a heavier check (e.g., re-running paths-filter) — defeats the "zero cost on no-diff PR" goal.

## What this skill does NOT address

- **Push-churn cancellations** (`mypy` / `merge-commit-gate` cancelled mid-run when a new commit supersedes the in-flight run) — that's a `limit-pr-runs` / concurrency issue, separate fix in `.github/actions/limit-pr-runs/action.yml`.
- **Skipped jobs caused by draft PRs** — those are deliberate (CI capacity hardening) and should stay skipped.
- **Skipped jobs caused by event type mismatch** (e.g., `pull_request` from a fork) — also deliberate, keep skipped.
- **The actual gate semantics** — synthetic-success preserves the original control flow exactly. Heavy work still only runs when relevant files are touched.

## Worked example — jleechanorg/worldarchitect.ai PR #9140 (this skill's origin)

Inputs: PR #9132 user complaint "Why so many skipped CI checks?" Diagnostic:
1. `gh pr view 9132 --json statusCheckRollup` showed 12 `skipped` + 3 `cancelled` rows.
2. `gh api repos/.../actions/runs/<id>/jobs` showed `skipped` rows had `steps: 0` (the job-level `if:` short-circuited before any step ran).
3. Inspecting the workflow YAMLs revealed `dorny/paths-filter` gating 8 jobs in `presubmit.yml`, 4 in `test.yml`, 4 in `self-hosted-mvp-shard1.yml`.

Output: PR #9140 — `+291/-16` across 4 files. After merge, all 16 gated jobs render green checkmarks on no-diff PRs (was: yellow circles). Regression test added. PR is currently mergeable, awaiting human review.
