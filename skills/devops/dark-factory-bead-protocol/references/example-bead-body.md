# Example factory-bead body (rev-t50ny — real 2026-08-19 filing)

This is the exact body that drove PR #9148 to factory adoption after the
issue-label fix landed. Use as a template; replace the placeholders.

```
target_repo: jleechanorg/worldarchitect.ai
existing_pr: https://github.com/jleechanorg/worldarchitect.ai/pull/9148
existing_branch: feat/world-sim-mega-local
head_sha: 4a3ef18251ad6ffed322682c1e72f4bc2fe2478f
labels: factory

Drive PR #9148 (mega combined unit — local-testable queue + agy provider + evidence) to /ready.

SCOPE (4 commits on feat/world-sim-mega-local):
- Cherry-pick f28fd8b3b5 (PR2): roster-anchored tools + prompt contract
- Cherry-pick 4d94b034b9 (PR3a): async tick engine with idempotency
- Cherry-pick a6038e9da8 (PR3b): GCP dispatcher + firestore lease + HTTP worker
- Mega commit 4a3ef18251: LocalQueue + driver switch + local_worker + agy_client + e2e tests

ACCEPTANCE (5 green-gate conditions):
1. CI passes
2. No merge conflicts (mergeable=true)
3. CodeRabbit APPROVED
4. Bugbot clean
5. Unresolved comments = 0
Plus evidence + skeptic PASS for code PR.

DO NOT:
- Hand-fix unrelated bugs
- Split this back into 3 PRs
- Change the e2e test contract
```

## Key features of this template

- **First line is `target_repo:`** — daemon parses this BEFORE the rest.
- **`existing_pr`, `existing_branch`, `head_sha`** form the existing-PR
  adoption trio. All three required.
- **≤ 4096 chars** — this body is 2,690 chars (well under cap).
- **`labels: factory`** in the body matches the br create `--labels factory`
  flag — they must agree.
- **No emoji, no `# heading`** markers — the body is read as raw text by the
  AO spawn prompt. Markdown headers add noise without value here.
- **Acceptance criteria are concrete gate conditions** — the AO worker uses
  these to know when to stop. Vague acceptance ("make it work") produces
  no-op PRs.

## What was wrong with the first filing

The first filing of `rev-t50ny` had all the body fields correct, but
issue #9139 (the parent issue) was NOT labeled `factory`. The daemon's
two-phase intake means the PR-side bead can't be adopted until the
issue-side bead exists. Symptom: bead filed at 22:46, daemon polled
20+ sweeps, no `beads_created` increment for the new PR. Fix was a
single `POST /repos/.../issues/9139/labels` with `["factory"]` —
adoption fired within the next 5s tick.