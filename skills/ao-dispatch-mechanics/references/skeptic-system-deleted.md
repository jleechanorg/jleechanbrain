# Skeptic system was deleted 2026-07-09 — what "trigger Skeptic Self-Verify" used to mean and what to do now

**Verified 2026-08-05, PR #8561 → `worldarchitect-202` worker dispatch.** The worker's discovery is the canonical evidence: `gh workflow list --repo jleechanorg/worldarchitect.ai --json name` returns zero matches for any of `Skeptic | Skeptic Self-Verify | Skeptic Cron | skeptic-self-verify | skeptic-cron`. PR #8217 disabled the workflows on 2026-07-09 and removed `.gemini/skeptic.toml` + the `skeptic-self-verify.yml` + `skeptic-cron.yml` files.

## Why this matters

The `drive-pr-to-green` skill (user-owned, not curator-managed) still has Step 7a titled *"Trigger Skeptic Self-Verify manually when the cron is idle"* with a working recipe. That recipe is now dead — running it produces zero workflows to dispatch, and an agent that follows it will burn cycles searching for a workflow that doesn't exist.

If the gateway session or the worker proposes to "trigger Skeptic Self-Verify as alternative runner path" — STOP. That was the pre-2026-07-09 reflex. It saves zero cycles today.

## The current /green definition (verified 2026-08-05, PR #8561)

The worker loaded the `pr-green-definition` skill and reported the canonical /green bar is **2 gates, not 7**:

| # | Gate | Pass criterion |
|---|---|---|
| 1 | CI green | Every check at PR head has `conclusion: success` (SKIPPED, NEUTRAL for Bugbot, CANCELLED, and PENDING-stale are NOT pass) |
| 2 | mergeable | `gh pr view --json mergeable` returns `MERGEABLE` |

The legacy "7 green criteria" framework (Skeptic + CodeRabbit + Bugbot + Evidence Gate + Skeptic cron) conflated draft-phase gates with /green gates. Per `draft-first-pr`, those are draft-phase concerns — not /green gates. The 2-gate definition matches what the worker's `pr-green-definition` skill loaded.

## What the worker did right on PR #8561

When steered to "trigger Skeptic Self-Verify manually as alternative path", the worker:

1. Searched `gh workflow list --jq '.[] | select(.name | test("skeptic|verdict|self-verif|verify|self_review|self-re…"))'` — returned 48 PR-gate workflows, none named Skeptic.
2. Cross-checked with CLAUDE.md evidence-before-claim rule: *"The Skeptic system was deleted on 2026-07-09 — PR #8217, workflow disabled, .gemini toml deleted."*
3. Pivoted back to the 2-gate /green definition and reported honestly: *"CI is not green. The PR is structurally correct but blocked by infrastructure."*
4. Stopped polling and posted a terminal Slack message identifying the exact ops command (`systemctl --user restart ezgha` on `jeff-ubuntu`).

This is the anti-fabrication discipline the harness wants — refusing to invent a "Skeptic VERDICT" that doesn't exist.

## What the gateway did wrong (lessons)

1. **Initial brief told the worker to "trigger Skeptic Self-Verify manually"** — this was the dead-recipe reflex. Worker correctly refused. Future dispatches must remove that line from the brief template.
2. **The brief told the worker "7 green conditions"** — wrong; it should be "2 gates: CI green + mergeable". Update the brief template.
3. **Worker re-pushed (`b046e1e037` → `e9f693c62c`)** hoping to re-queue cancelled checks. This churns the queue and doesn't change runner availability. Future workers should NOT re-push when checks are `cancelled` and the runner pool is saturated — the new push also gets cancelled.

## Recommended brief template (post-Skeptic deletion)

When dispatching an AO worker to /green a PR, the brief should say:

```
Drive PR #N to green on <repo>. The /green bar is the 2-gate definition
(per pr-green-definition skill): Gate 1 = CI green (every check at head
has conclusion: success), Gate 2 = mergeable=true. The legacy "7 green
conditions" framework is dead — Skeptic was deleted 2026-07-09 (PR
#8217); do NOT try to dispatch Skeptic Self-Verify (no such workflow
exists). If CI checks are conclusion: cancelled because the self-hosted
runner pool is saturated, that is a same-name-rule infra issue, not a
PR code issue. Stop polling, surface the literal ops-heal command
(systemctl --user restart ezgha on jeff-ubuntu for Linux runners;
delete + re-register mac runners in SESSION CONFLICT per
runner-health.sh), and exit. Do NOT force-push again hoping to re-queue.
```

## Detection recipes

```bash
# Is the Skeptic workflow still around? (should return nothing after 2026-07-09)
gh workflow list --repo jleechanorg/worldarchitect.ai --json name \
  --jq '.[] | select(.name | test("skeptic|verdict"; "i")) | .name'

# Are the workflow files still in the repo?
gh api repos/jleechanorg/worldarchitect.ai/contents/.github/workflows/skeptic-self-verify.yml \
  --jq '.message'  # "Not Found" means deleted

# Is the .gemini config still around?
gh api repos/jleechanorg/worldarchitect.ai/contents/.gemini/skeptic.toml \
  --jq '.message'  # "Not Found" means deleted
```

If any of these returns a hit, the system is back (someone re-enabled it) and the prior drive-pr-to-green Step 7a recipe is valid again. As of 2026-08-05, all three return "Not Found".

## Why this isn't in drive-pr-to-green directly

`drive-pr-to-green` is user-owned (created_by=None); the curator rejects autonomous patches to it. The Step 7a section still has the dead Skeptic recipe. If you want it fixed, the user must run `hermes curator adopt drive-pr-to-green` and then patch it, OR paste the updated Step 7a content into the skill directly. Until then, this reference file is the curator-managed supplement.

## Related references

- `references/self-hosted-runner-systemic-saturation.md` — the runner-saturation pattern that triggers the "Skeptic alternative path" temptation in the first place
- `references/half-stop-user-re-ping-signal.md` — the half-stop pattern that a dead-recipe dispatch can slip into