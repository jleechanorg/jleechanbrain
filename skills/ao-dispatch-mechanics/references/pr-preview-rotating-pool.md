# PR Preview Rotating Pool — deployment shuffle pitfall (verified 2026-08-05, PR #8787)

## The problem

`pr-preview.yml` in `jleechanorg/worldarchitect.ai` is a "Rotating Pool" of shared Cloud Run services — `mvp-site-app-s1` through `mvp-site-app-s10` — not per-PR Cloud Run services. When a new PR's deploy runs, the pool re-assigns the slot to the newest PR. **Your PR's revisions still exist in `gcloud run revisions list` but traffic doesn't route to them.**

## How to detect (don't trust the PR's "Deploy PR Preview" success row)

```bash
# Active revision serving the rotating-pool URL
gcloud run revisions list --service=mvp-site-app-s7 --region=us-central1 \
  --project=worldarchitecture-ai --format='table(metadata.name,metadata.labels.commit-sha,metadata.labels.pr-number)'

# Compare to your PR's HEAD
gh pr view <N> --json headRefOid -q .headRefOid

# Quick bundle-grep probe (the smoked-by-fire check)
curl -fsS https://mvp-site-app-s7-...a.run.app/frontend_v1/auth.*.js \
  | grep -cE 'signup.complete|signin.success|game.open|first_turn.begin|first_turn.outcome'
# If grep returns 0 but your PR is supposed to have these events, the deployed revision is a different PR's.
```

## The "SERVICE_NAME_OVERRIDE" trap

The `pr-preview.yml` workflow comment promises:
> "PRs that need warm preview can override via `SERVICE_NAME_OVERRIDE` + min-instances on a follow-up"

**The comment is aspirational, not implemented.** There is no `workflow_dispatch` block in the workflow — only `pull_request` triggers. The override is a no-op. Verified 2026-08-05: `grep -n 'workflow_dispatch' .github/workflows/pr-preview.yml` returns nothing.

## The fix: empty-commit retrigger

The canonical pattern is documented in the prior commit on the same branch:
```
claudem/minimax-M3: chore(ci): retrigger workflows to clear stuck Auth Browser Tests queue
```

Re-fire the workflow by pushing a no-op commit:

```bash
git -C <worktree> commit --allow-empty \
  -m 'chore(ci): retrigger pr-preview to get fresh per-PR slot' \
  --no-verify
git -C <worktree> push origin <branch>
```

This re-fires `pr-preview.yml`'s `pull_request` trigger. The pool script (`.github/scripts/pr-server-pool.sh`) picks the lowest-load slot from `s1`-`s10` and deploys your PR's HEAD there. Expect 5-10 min for the new revision to be ready, then read the bot comment on the PR for the new preview URL.

## Acceptable costs

- Re-runs the cloud-side CI gates (Green Gate, Styleguide, Design Doc, etc.) — fast (<1 min each).
- Re-runs the slow self-hosted CI gates (Auth Browser, Wizard Mobile, Mobile Auth) — ~5-7 min each.
- Empty commit lands on the branch. Audit-friendly prefix `chore(ci):` keeps it distinct from feature commits.

## Does NOT solve: systemic self-hosted runner queue

If the pool is systemically saturated (14/16 runners busy, 30+ queued runs across many PRs), the empty-commit retrigger will also queue. The empty commit re-fires the workflow, but the new `pr-preview` run joins the same queue. ETA unbounded.

When this happens, the right call is the partial-stack proof + retry-cron handoff — see `references/self-hosted-runner-systemic-saturation.md`.

## What does NOT work

- ❌ Direct Cloud Run revision URL (`mvp-site-app-s7-04005-f6h-...a.run.app`): returns 404 because the rotation doesn't expose direct revision routing.
- ❌ Manual `gcloud run services update-traffic` to point at your PR's revision: the revision exists but the service-level config gates it; touch only if you have explicit go-ahead.
- ❌ Pushing to the branch expecting `workflow_dispatch` to fire the override: `workflow_dispatch` doesn't exist on this workflow.
- ❌ Bypassing to `mvp-site-app-dev` or `mvp-site-app-staging` for the smoke test: those serve `origin/main` HEAD, not your PR's code. Loses Cloud Logging evidence against your PR's path.

## When to skip this recipe

- If your PR only needs CI to pass (no Cloud-Run-bound smoke test), the empty-commit retrigger is overkill — just wait for the existing pr-preview run to be picked up by a runner.
- If your PR has unit tests that don't require a deployed bundle, skip the retrigger entirely.
- If you've already verified the rotation pattern in the last 30 minutes, a second retrigger will likely collide with the first — wait for the first to land first.

## Related skill references

- `~/.smartclaw/skills/workflow/drive-pr-to-green/SKILL.md` — the broader PR-to-green workflow (this pool pitfall is one specific gotcha inside it)
- `~/.smartclaw/skills/finish-the-job/SKILL.md` — the "no-stop-halfway" + decision-tree framework that decides when to apply this recipe vs. handoff
- `references/self-hosted-runner-systemic-saturation.md` — companion reference for when the pool is systemically queued
