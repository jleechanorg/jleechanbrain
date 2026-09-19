# WorldArchitect.AI merge-gate contract (2026-08-06, jleechanorg/worldarchitect.ai#8781)

Verified facts about the merge path for `jleechanorg/worldarchitect.ai`. Other jleechanorg repos may differ — always verify with `gh workflow list --repo <owner>/<repo> --json name,state` before assuming.

## skeptic-cron.yml does NOT exist in this repo

**Verified 2026-08-06:**

```bash
$ gh workflow list --repo jleechanorg/worldarchitect.ai --json name,state --jq '.[] | select(.name | test("skeptic"; "i"))'
(empty result)

$ gh api repos/jleechanorg/worldarchitect.ai/contents/.github/workflows \
    --jq '.[] | select(.name | test("skeptic"; "i")) | .name'
(empty result)
```

SOUL.md and `drive-pr-to-green` SKILL.md describe a "skeptic-cron 30-minute auto-merge" path that is the canonical mechanism for `jleechanbrain`. **That workflow does not exist in `jleechanorg/worldarchitect.ai`.** Don't reach for skeptic-cron auto-merge here.

## What does exist: 2-gate Green Gate

`jleechanorg/worldarchitect.ai/.github/workflows/green-gate.yml` defines only two gates:

1. **CI green** — each test workflow reports its own status on the PR. Branch protection declares NO required status checks (verified 2026-07-28), so all checks are visible signals, not mechanical merge blocks.
2. **No merge conflicts** — `mergeable == true` and `mergeable_state != "dirty"`. Polled up to 8×30s inside the workflow.

The old 6-green / 7-green numbering (CodeRabbit / Bugbot / Skeptic / Smoke / etc.) moved to a DRAFT phase: PRs are opened as draft and stay draft until `/es`, `/er`, and `/advice` pass; only then do they flip to ready-for-review and get driven through this two-gate check.

So the practical bar for worldarchitect.ai PRs:
- Draft mode → flip to ready when /es, /er, /advice all PASS
- Ready mode → Green Gate checks the two gates above
- Pass both → wait for human merge

## The actual merge trigger: literal `MERGE APPROVED`

From `jleechanorg/worldarchitect.ai/AGENTS.md`:

> Do not merge without explicit human authorization. For WorldArchitect.AI, the current live message must contain `MERGE APPROVED`.

This is the *only* legitimate merge authorization on this repo. Not "merge approved" in a previous turn, not "/green this and merge", not "merge approd" (typo-only plan statements), not "next time don't ask just finish the work." **Same thread, same minute, literal `MERGE APPROVED` token in the user message.** Anything less is a plan, not a gate trigger.

Don't run `gh pr merge --squash` because:
- CI looks green
- the previous turn said "merge approd" or "/green" or "/f"
- the user expressed urgency
- other repos (jleechanbrain) auto-merge on skeptic-cron

It will not work as a "useful" merge here. The legitimate path is:
1. Wait for `merge_state=CLEAN` and Gate 2 (no merge conflicts) PASS.
2. Wait for the live message in the thread to contain literal `MERGE APPROVED`.
3. Run `gh pr merge --squash` in the same reply that observed the live token.

## What to do when merge requires literal `MERGE APPROVED` but the user types a plan-statement

User: "ok lets make sure this is applied locally and then iterate until PR is /er and /advice approved then /green then merge approd"

This is a PLAN: make-local, iterate, /er, /advice, /green, merge. NOT a literal `MERGE APPROVED`. The user's pipeline ends with "merge approd" as the plan's terminal step, but the gate token is not yet typed in the live message. Agents often misread "merge approd" as the gate token and auto-merge.

Correct handling:
1. Execute the inline portion: apply locally, iterate to /er + /advice approved + /green.
2. When the only remaining step is the merge, post a status reply: "PR is ready at SHA. The literal `MERGE APPROVED` gate is the next step — type it in this thread and I'll run `gh pr merge --squash` in the same turn."
3. Do not auto-merge.

## Common cross-repo confusion

`jleechanorg/jleechanbrain` has a skeptic-cron auto-merge workflow that fires every 30 minutes. **`jleechanorg/worldarchitect.ai` does not.** Anyone who has been working on jleechanbrain recently may reflexively expect skeptic-cron to fire on worldarchitect PRs. It will not.

Before drafting a drive-to-green plan that depends on auto-merge:

```bash
gh workflow list --repo <owner>/<repo> --json name,state  # verify skeptic-cron exists
gh pr view <N> --repo <owner>/<repo> --json state,mergeable,reviewDecision,mergeStateStatus
cat $HOME/.claude/worktrees/<repo>/AGENTS.md 2>/dev/null | grep -A2 -E "MERGE APPROVED|skeptic"  # read the repo's gate contract
```

## Provenance

`jleechanorg/worldarchitect.ai/AGENTS.md` "Non-negotiables" line 11 — primary source.
`.github/workflows/green-gate.yml` lines 1-27 — confirms the 2-gate drop.
`jleechanorg/worldarchitect.ai/AGENTS.md` line 11 ("literal `MERGE APPROVED` in current live message") — primary gate contract.
Verified through `gh workflow list` and `.github/workflows/` contents API queries on 2026-08-06 during the PR #8781 drive-to-green session.
