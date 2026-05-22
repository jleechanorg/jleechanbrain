# Budget Burn Investigation — 2026-05-07 (Actions-side only)

GCP budget alert flagged 2026-05-07. This document covers **only the GitHub Actions
slice** of the investigation; it is **not a determination of the GCP cost driver**.
Window analyzed: **2026-04-23 → 2026-05-07** (last 14 days).

## TL;DR

> **⚠️ Do not treat this document as the GCP root cause.** `ai_universe_living_blog`
> is a **public** repo, so its Actions minutes are **free** and cannot be the GCP
> budget driver. The actual GCP burn is almost certainly elsewhere (Cloud Run, Cloud
> Build, Vertex AI, storage egress, etc.) and **must** be identified from the GCP
> billing export by service before any incident response. **Do not run Phase 0 as a
> GCP-cost mitigation** — run it only as Actions runner hygiene if/when the repo
> goes private. See **Open Questions**.

What this document *does* cover: a runaway Actions-runtime pattern in the ai_universe
family that would be expensive *if* those repos were private. Provisional findings:

- **Largest Actions runtime by far: `ai_universe_living_blog` Skeptic Cron + Daily
  Novel Summary, hung on `ubuntu-latest`, cancelled at the 24-hour timeout.** 369 of
  479 runs (77%) ran for the full 1440-minute timeout before cancellation.
- Counterfactual cost at private-repo rates: ~498,000 minutes ≈ $3,985 over 14 days
  at $0.008/min. **Actual current GitHub bill for that repo: $0** (public). A
  private clone or visibility flip would expose the full cost — that is the only
  scenario where this becomes a billing concern, not a GCP one.
- The org already has **14 online self-hosted runners** (`self-hosted-mikey` label,
  10 × Linux/X64 + 4 × ARM64). They are unused by the ai_universe family.
- **First action is not migration — it is stopping the runaway timeouts.** Migrating
  a hung job to self-hosted just saturates the local fleet. Fix the workflow first
  (timeout-minutes + concurrency cancel-in-progress), then migrate the healthy paths.
- Migration to self-hosted is still the right move regardless, because the org policy
  already mandates self-hosted for private ai_universe repos.

## Top 5 Cost Drivers (14-day window)

Duration is wall-clock between `run_started_at` and `updated_at` (a proxy for billable
minutes — exact billable minutes need the `/timing` endpoint per run, but the cancelled-
at-1440 pattern dominates regardless).

| # | Repo | Workflow | Runs | Total min | Avg min | Runner | Notes |
|---|------|----------|------|-----------|---------|--------|-------|
| 1 | `ai_universe_living_blog` | Skeptic Cron | 456 | **483,552** | 1060 | `ubuntu-latest` | 369 cancelled at 1440m timeout — runaway |
| 2 | `ai_universe_living_blog` | Daily Novel Summary | 15 | **14,667** | 978 | `ubuntu-latest` | Multiple cancellations at 1440m |
| 3 | `ai_universe_frontend` | Deploy PR Preview to GCP | 42 | 229 | 5.4 | `ubuntu-latest` | Healthy, but frequent |
| 4 | `ai_universe` | CI | 4 | 49 | 12.2 | `ubuntu-latest` | Healthy |
| 5 | `ai_universe_frontend` | AI Universe Frontend CI | 50 | 161 | 3.2 | `ubuntu-latest` | Healthy |

Other ai_universe repos run Skeptic Cron on `ubuntu-latest` every 30 min as well
(`ai_universe`, `ai_universe_mobile`, `ai_universe_convo_mcp`, `ai_universe_frontend`),
but their average duration is < 1 min — they are healthy at ~150–170 min total each
over 14 days, and migration of those alone would save roughly $1.20/repo/month.
**The hang in `ai_universe_living_blog` is the entire problem.**

### Why is `ai_universe_living_blog` Skeptic Cron hanging?

- Schedule: `*/30 * * * *` (every 30 min). With a 24h cancel timeout and frequent
  hangs, multiple long runs overlap.
- No `concurrency:` block with `cancel-in-progress: true`, so a hung run does not get
  preempted by the next 30-minute kick-off — they accumulate.
- No `timeout-minutes:` set on the job, so the only safety net is GitHub's hard 1440m
  ceiling (24 hours of billable Linux minutes per hang).

## Current Runner Infrastructure

Org: `jleechanorg`. Single runner group `Default`, public-repo allowed.

| Runner | OS | Status | Labels |
|--------|----|--------|--------|
| `org-runner-1` … `org-runner-10` | Linux X64 | online | `self-hosted`, `Linux`, `X64`, `self-hosted-mikey` |
| `org-runner-mac-1` … `org-runner-mac-4` (hostnames contain 'mac' but OS is Linux ARM64) | Linux ARM64 | online | `self-hosted`, `Linux`, `ARM64`, `self-hosted-mikey` |

14 runners online, all Linux. None of the ai_universe workflows currently pin
`runs-on` to `self-hosted` or `self-hosted-mikey`.

The `smartclaw` policy already mandates the selector pattern for private repos:
`${{ fromJson(vars.SELF_HOSTED_RUNNER_LABELS || '["self-hosted","self-hosted-mikey"]') }}`.

## Recommended Plan

### Phase 0 — Stop the bleeding (do this today, **before** any migration)

This is the highest-leverage change. It does not require any infra work.

1. In `ai_universe_living_blog/.github/workflows/skeptic-cron.yml`:
   - Add `timeout-minutes: 15` to the `skeptic_cron` job.
   - Add a top-level `concurrency:` block: `group: skeptic-cron-${{ github.ref }}`,
     `cancel-in-progress: true`.
2. Same two changes in `daily-summary.yml`.
3. Cancel any in-flight `queued`/`in_progress` Skeptic Cron runs from the queue.

Expected impact: drops `ai_universe_living_blog` Actions burn from ~498,000 min /
14 days to under ~200 min / 14 days — **>99% reduction without touching runners**.

### Phase 1 — Migrate ai_universe family to self-hosted

Order is by current burn × risk. Migrate Skeptic Cron jobs first because they are
private-repo cron jobs that should not be on GitHub-hosted per the org policy.

| Order | Repo | Workflow(s) | Notes |
|-------|------|-------------|-------|
| 1 | `ai_universe_living_blog` | `skeptic-cron.yml`, `daily-summary.yml`, `ci.yml`, `novel-entry.yml` | Highest current burn — **only after Phase 0 lands** |
| 2 | `ai_universe` | `skeptic-cron.yml`, `ci.yml` (private) | Private repo policy says self-hosted by default |
| 3 | `ai_universe_mobile` | `skeptic-cron.yml` | Private |
| 4 | `ai_universe_convo_mcp` | `skeptic-cron.yml` | Private |
| 5 | `ai_universe_frontend` | `ci.yml`, `deploy-pr-preview` | Highest non-cron burn; deploy step talks to GCP, verify auth before flipping |
| – | `ai_universe_chatgpt_sdk` | (very low traffic — defer) | Public repo, low priority |

### Migration recipe per repo (PR per repo)

1. Replace `runs-on: ubuntu-latest` with:
   ```yaml
   runs-on: ${{ fromJson(vars.SELF_HOSTED_RUNNER_LABELS || '["self-hosted","self-hosted-mikey"]') }}
   ```
2. Set `vars.SELF_HOSTED_RUNNER_LABELS` at org level (already required by smartclaw
   policy) to keep the selector overridable.
3. Keep `timeout-minutes` from Phase 0; it matters more on shared runners than on
   GitHub-hosted, since a hung job blocks a real shared machine.
4. For workflows that need GCP auth (e.g. `Deploy PR Preview to GCP`), confirm the
   self-hosted runner already has `gcloud` configured for the right service account
   before merging the migration PR.
5. After merge, watch the runner pool for queue depth. With 14 runners and 5 repos
   running Skeptic Cron every 30 min plus PR CI, peak concurrency should remain
   well under 14, but fix Phase 0 first or hangs will saturate the fleet immediately.

### Phase 2 — Org-level guardrails

1. Add a CI gate (`actions-runner-policy.yml` or a Skeptic check) that fails any PR
   touching `.github/workflows/*.yml` in a **private** ai_universe repo if it
   reintroduces `ubuntu-latest`. Mirrors the policy already enforced in `worldarchitect.ai`.
2. Add a `monitor-actions-burn.sh` cron that pulls per-repo run durations daily and
   alerts in Slack `#ai-slack-test` if any single workflow exceeds 5,000 minutes /
   day — would have caught the living_blog runaway within 24 hours instead of 14 days.
3. Document the runaway pattern in `~/.smartclaw/CLAUDE.md` under a new "Workflow
   timeout discipline" section: every scheduled workflow MUST set both
   `timeout-minutes` and `concurrency.cancel-in-progress`.

## Counterfactual Estimated Savings (private-repo only — not actual billed spend)

**These figures are counterfactual.** The dominant `ai_universe_living_blog` repo is
currently public, so its Actions minutes are free and contribute $0 to current
GitHub or GCP billing. The numbers below model what the burn *would* cost if these
workloads were billed at private-repo GitHub-hosted rates — useful for sizing the
risk if repos go private, not for explaining the current GCP alert.

Assumptions:
- GitHub-hosted Linux: $0.008/min (post-free-tier private repo rate).
- Current 14-day measured burn (ai_universe family): **~498,750 min ≈ $3,990**.
  Annualized at the same rate: **~$104,000/year**. Almost all of that is the
  living_blog hang.
- Self-hosted runner cost: amortized hardware/electricity for the existing fleet,
  treat as ~$0 marginal because the 14 runners are already provisioned and online.

| Action | Min saved / 14d | $ saved / 14d | $ saved / yr |
|--------|----------------:|--------------:|-------------:|
| Phase 0 (timeout + concurrency on living_blog) | ~498,000 | ~$3,984 | ~$103,800 |
| Phase 1 (full ai_universe migration) | additional ~700 | additional ~$6 | ~$150 |
| **Total** | ~498,700 | ~$3,990 | ~$104,000 |

These savings are a **counterfactual** for private-repo GitHub-hosted billing only.
For the current public `ai_universe_living_blog` repo, Actions minutes are not the
present GCP budget driver; use the GCP billing-export-by-service to identify the
actual spend sources.

## Open Questions

- Confirm whether `ai_universe_living_blog` is private or public — `gh repo list` shows
  PUBLIC, in which case GitHub Actions minutes for that single repo are free and the
  budget alert source is elsewhere (likely GCP Cloud Run from `Deploy to GCP` workflows
  in `ai_universe_frontend`, or unrelated GCP services). This needs cross-checking
  against the actual GCP billing line items before declaring the case closed.
- If the budget alert is GCP-side (Cloud Run / Cloud Build), then Phase 1 still applies
  for org-policy reasons but Phase 0 will not move the GCP needle. Pull the GCP billing
  export by service before assuming Actions is the cause.
