# Self-hosted runner systemic saturation — same-name rule pattern (verified 2026-08-05, PR #8787)

## The pattern

When the self-hosted runner pool serving `jleechanorg/worldarchitect.ai` is systemically saturated, EVERY workflow that runs on `runs-on: [self-hosted, ...]` queues indefinitely. This is *not* a flaky-test problem — it's a runner-capacity problem. Symptom clusters:

- `Self-Hosted MVP Shards` jobs (`Directory tests (core-mvp-1/2/3)`) — `status: queued`, `runnerName: null`, >30min
- `pr-preview.yml` deploy run — same `status: queued`, `runnerName: null`, >30min
- `gh run rerun --failed` returns `already running` because the GH-side state machine thinks the job is still queued — the rerun does nothing
- `ezgha-watchdog` (the documented restart-only remediation) is **fail-closed** and pending `jleechanorg/ez-gh-actions` PR 67/70 — not available

## How to detect (from the gateway)

```bash
# 1. Is the runner pool saturated?
gh api 'repos/jleechanorg/worldarchitect.ai/actions/runs?status=queued&per_page=100' \
  --jq '.workflow_runs | length'

# 2. Are runners idle? (often returns 0 due to API permission scope)
gh api 'repos/jleechanorg/worldarchitect.ai/actions/runners?per_page=30' \
  --jq '.runners | map({name, busy, status})'

# 3. What PRs are stuck in the same queue?
gh api 'repos/jleechanorg/worldarchitect.ai/actions/runs?status=queued&per_page=20' \
  --jq '.workflow_runs[] | "\(.id) \(.name) \(.head_branch)"'
```

## Same-name rule verdict

If the failing test step is `Directory tests (core-mvp-N (self hosted))` and the same step fails on 20+ unrelated branches across the last 24h, the failure is *infrastructure* (saturated pool), not PR code. Per the `qa-test-failure-dismissal-anti-pattern` skill, documented infra failures are explicitly treated as non-blocking. The PR can still receive Skeptic `VERDICT: PASS` and be merged by skeptic-cron.

## Decision tree (when PR smoke test is blocked by this)

```
  PR needs end-to-end smoke test against deployed bundle
                │
                ▼
  Empty-commit retrigger succeeds but new pr-preview run also queues
                │
                ▼
  Wait 30 minutes. Pool drains slowly because every PR is competing.
                │
                ▼
  Still queued at +30min?  -->  Run partial-stack proof:
                                  (a) source-grep for call sites
                                  (b) JS unit tests pass
                                  (c) schema-level Cloud Logging probe
                                  (d) Skeptic self-verify (code-level 7-green)
                                │
                                ▼
                                Hand off literal end-to-end smoke test to a
                                long-running retry cron (144 ticks × 10 min = 24h)
                                Self-cancels on first successful capture OR timeout.
```

## The partial-stack proof

When end-to-end Cloud Logging evidence isn't available, the partial stack is:

1. **Source-grep proof** that the 5 wired events are at the documented call sites:
   ```bash
   git -C <worktree> grep -n 'safeDiag(' mvp_site/frontend_v1/app.js mvp_site/frontend_v1/auth.js
   ```
2. **Unit test pass** with the new event coverage:
   ```bash
   node --test mvp_site/frontend_v1/tests/instrumentation.test.js
   ```
3. **Schema-level Cloud Logging proof** — POST to `/api/client_diag` against `mvp-site-app-dev` (which serves `origin/main` HEAD but the same `/api/client_diag` endpoint with the same schema) and verify the prod Cloud Logging sink accepts the payload:
   ```bash
   curl -fsS -X POST https://mvp-site-app-dev-i6xf2p72ka-uc.a.run.app/api/client_diag \
     -H 'Content-Type: application/json' \
     -d '{"event_name":"signup.complete","fields":{"uid":"vnLp2...","method":"google"}}'
   # Expect 204
   gcloud logging read 'jsonPayload.event_name="signup.complete"' --limit=5 \
     --project=worldarchitect-ai-prod --format=json
   ```
4. **Skeptic self-verify** against the PR head SHA — per the same-name exception, code-level 7-green PASSes despite the queued CI.

## Document as PARTIAL, not overclaim

The PR body should be updated to:
- Flag the queued-vs-failed distinction
- List the partial-stack proof items present in the thread
- Reference the retry cron ID for the eventual end-to-end capture

## Beads worth filing

- **PR-self-blocker bead**: `pr-preview.yml` `SERVICE_NAME_OVERRIDE` is aspirational — comment promises override but no `workflow_dispatch` exists. Document the gap. Fix candidate: add `workflow_dispatch` with `service_name_override` input.
- **Runner-capacity bead**: self-hosted runner pool saturation >30min across 20+ PRs. Document the same-name rule and the systemic cluster. Fix candidate: scale runner pool or implement `ezgha-watchdog` PR 67/70.

## What does NOT work

- ❌ `gh run rerun --failed` — returns "already running" because jobs are still queued.
- ❌ Waiting for completion — queue actively refills as other PRs push.
- ❌ Manual runner drain (no authority from gateway).
- ❌ Bypassing to `mvp-site-app-dev` / `mvp-site-app-staging` — lose the prod Cloud Logging evidence the user asked for.
- ❌ Pushing the same empty commit twice — second push re-fires the workflow but joins the same queue.

## Related skill references

- `~/.smartclaw/skills/workflow/drive-pr-to-green/SKILL.md` — the PR-to-green workflow
- `references/pr-preview-rotating-pool.md` — companion: the rotating-pool pattern that creates the deploy URL your smoke test depends on
- `~/.smartclaw/skills/finish-the-job/SKILL.md` — the "no-stop-halfway" framework
- `~/.claude/skills/qa-test-failure-dismissal-anti-pattern/SKILL.md` — the same-name rule pattern
