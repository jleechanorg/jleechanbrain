---
name: pr-body-grep-gate-fix
description: Fix body-grep CI gates fast via PATCH + rerun-failed-jobs.
version: 1.0.0
author: Hermes Agent
license: MIT
tags: [github, ci, pr, body-content, gate-fix]
metadata:
  hermes:
    tags: [github, ci, pr, body-content, gate-fix]
    related_skills: [drive-pr-to-green, github-pr-workflow, qa-test-failure-dismissal-anti-pattern]
---

# PR-Body-Content Gate Fix Recipe

When a CI check reads the **PR description** (not the code diff), pushing code will not help.
A no-op code push + force-push re-triggers the full CI matrix (3-5 min) while leaving
the body-driven gate unfixed.

This is the canonical recipe for fixing body-content-driven check-runs fast and surgical.

## When this applies

The check-run failure log line explicitly references the PR description or its
contents. Common phrasings:

- `PR description` / `PR body` / `PR has N non-test delta lines`
- `Tenets` / `Design Decision` / `Governing Design Doc`
- `Linked artifact` / `Linked bead`
- `>50 non-test delta lines` + missing-tenets framing

If those phrases appear, the gate is body-driven → use this skill.

Real-world canonical example: `jleechanorg/worldarchitect.ai` PR #9142, 2026-08-19 —
`Design Doc Grep Gates` failed because the PR body had no `## Tenets` section linking
to a bead (`rev-xxxx`) or a roadmap `.md` doc.

## Recipe (5 steps, ~30s end-to-end)

### 1. Patch the PR body via REST (avoids GraphQL rate limit)

```bash
gh api -X PATCH repos/<owner>/<repo>/issues/<N> \
  --field body="$(cat /tmp/new-body.md)"
```

A PR body lives at the **issue endpoint** (PRs inherit from issues). The body
must include a `## Tenets` / `## Design Decision` / `## Governing Design Doc`
section AND inside that section at least one linked artifact — a bead ID
(`rev-xxxx`), a `.md` path, or an absolute file path to a roadmap doc.

### 2. Find the failed run_id from the failing check-run

```bash
gh api "repos/<owner>/<repo>/commits/<HEAD>/check-runs" \
  --jq '.check_runs[] | select(.conclusion=="failure") | {name, id, details_url}' \
  | head -5
```

Pull the run id (the number after `/runs/` in `details_url`) — `head_sha` is
`gh pr view <N> --json headRefOid -q .headRefOid`.

### 3. Re-run ONLY the failed job (not the whole matrix)

```bash
gh api -X POST repos/<owner>/<repo>/actions/runs/<run_id>/rerun-failed-jobs
```

A body-only edit does NOT auto-trigger workflow runs. `rerun-failed-jobs` keeps
all other green checks untouched and runs the failed ones in ~30s-2min.

### 4. Poll for the new attempt to land

```bash
for i in 1 2 3 4 5 6 7 8; do
  sleep 20
  R=$(gh api repos/<owner>/<repo>/actions/runs/<run_id> \
        --jq '{conclusion, run_attempt, status}')
  echo "[$i] $R"
  [[ "$R" == *'"conclusion":"success"'* || "$R" == *'"conclusion":"failure"'* ]] && break
done
```

The `run_attempt` increments on retry. New `conclusion="success"` = done.

### 5. Verify the full PR is green

```bash
gh api "repos/<owner>/<repo>/commits/<HEAD>/check-runs" \
  | jq '[.check_runs[] | .conclusion] | group_by(.) | map({(.[0] // "null"): length}) | add'
```

Look for the single `{success: N}` or `{success: N, skipped: M, cancelled: K}`
distribution where `success + skipped > 0` and there is no `failure`.

## Anti-patterns (do NOT do these)

- **No-op code commit + force-push** — does not re-evaluate body content, re-triggers
  full matrix, wastes 3-5min CI minutes, spams reviewers with a "no real change" diff.
- **`gh pr edit --body ...`** — uses GraphQL, hits rate limits fast on shared-rate-limit accounts.
  Use the `issues/<N>` PATCH endpoint instead.
- **Re-run all jobs via `gh workflow run`** — also re-triggers the entire matrix;
  should only be used if multiple gates broke together for *unrelated* reasons.

## Related skills / cross-references

- `drive-pr-to-green` — Step 7 ("Watch CI to green"). Body-content gates are a
  sub-case that needs the recipe above instead of a code push.
- `github-pr-workflow` — Section 5 (Auto-Fixing CI Failures). Bundled twin of the recipe.
- `qa-test-failure-dismissal-anti-pattern` — if the body-grep gate is suppressing
  documentation links that already exist on origin/main, that's a separate bug class.

## Provenance

Verified on jleechanorg/worldarchitect.ai PR #9142 (2026-08-19, `4aea98cc766012906374c7e5fe7bf54e8fa7e404`).
Body patched + `Design Doc Grep Gates` re-run → success on attempt #2 in ~30s.
Subsequent full PR check-runs: 12 success, 12 skipped (matrix-not-triggered), 4 cancelled
(re-runs superseded), 1 neutral Bugbot. PR is mergeable+green without a code push.
