---
name: all-gates-0-billable-diagnostic
description: Worked example for the v1.10.0 runner-pool sub-class corrections. Use when a babysit is tempted to trust a cron prompt's enumerated gate list, or when a `conclusion=failure` check-run looks like a code failure but might be a 0-billable-duration infra failure.
---

# All-gates gate-check contract + 0-billable-duration diagnostic

## Why this exists

Two operational corrections verified on PR #815 (jleechanorg/jleechanbrain, branch `fix/cost-monitor-self-hosted-rates`, head `d176fba541b391a7ffae2b17bb57a9928fa4e0a7`), 2026-08-06 18:26Z, babysit cron `845b20b295bc` targeting thread `${SLACK_CHANNEL_ID}/1785905655.111039`.

The original v1.9.0 babysit logic had two assumptions that proved wrong on this PR:

1. **The cron prompt's gate list is exhaustive.** It isn't — repos add new required gates over time; the prompt lags.
2. **`conclusion=failure` means code failure.** It doesn't — the same JSON shape can come from a job that was queued 15 min and never started (platform timeout cancels with `failure` conclusion).

If the babysit had merged on the prompt's "the three named gates are green" condition, it would have shipped a PR with a 4th gate (`Example discipline`) in `failure` state.

## Recipe — full check-runs predicate

Replace the prompt's named-gate loop with:

```bash
REPO="jleechanorg/jleechanbrain"
PR=815
HEAD_SHA=$(gh api "repos/$REPO/pulls/$PR" --jq '.head.sha')

# Get ALL check-runs on the current head SHA (not just the prompt's named subset)
gh api "repos/$REPO/commits/$HEAD_SHA/check-runs" --jq '
  .check_runs
  | map(select(.status == "completed"))
  | map(select(.conclusion as $c | $c != "success" and $c != "skipped" and $c != "neutral"))
  | map({name, conclusion, html_url})
'

# If the output is `[]` AND no check-runs are queued/in_progress → ALL gates green.
# If the output is non-empty → at least one gate failed; investigate via the timing probe.
```

Empty array + no queued/in_progress → merge-ready.
Non-empty array → at least one failure. Do NOT merge until each failure is resolved.

## Recipe — 0-billable-duration diagnostic

For each check-run with `conclusion=failure`, probe the timing endpoint:

```bash
REPO="jleechanorg/jleechanbrain"
RUN_ID=31124896276  # the failed Example discipline run from PR #815

TIMING=$(gh api "repos/$REPO/actions/runs/$RUN_ID/timing")
BILLABLE_MS=$(echo "$TIMING" | jq '[.billable | to_entries[] | .value.job_runs[] | .duration_ms] | add // 0')
RUN_DURATION_MS=$(echo "$TIMING" | jq '.run_duration_ms')

if [ "$BILLABLE_MS" -eq 0 ] && [ "$RUN_DURATION_MS" -gt 60000 ]; then
  echo "INFRA failure: queued $((RUN_DURATION_MS/1000))s, never executed"
  echo "Re-queueing via rerun endpoint..."
  curl -fsS -X POST -H "Authorization: token $(gh auth token)" \
    "https://api.github.com/repos/$REPO/actions/runs/$RUN_ID/rerun"
  # Premise INTACT — babysit continues to wait. Do NOT hand off to drive-pr-to-green.
elif [ "$BILLABLE_MS" -gt 0 ]; then
  echo "CODE failure: ran for $((BILLABLE_MS/1000))s, exited non-success"
  # Premise LIFTED — apply the v1.9.0 premise-divergence post + self-cancel + hand off
else
  echo "AMBIGUOUS: billable=0, run_duration<60s — check the workflow's own logs"
fi
```

## Verified worked example (PR #815, 2026-08-06 18:17Z)

```json
{
  "billable": { "UBUNTU": { "total_ms": 0, "jobs": 1, "job_runs": [{"job_id": 92693418623, "duration_ms": 0}] } },
  "run_duration_ms": 902000
}
```

`total_ms=0` + `duration_ms=0` + `run_duration_ms=902000` (15 min, 2 sec) = the Example discipline job was queued on a hosted ubuntu-latest runner for the full 15 min, never picked up (hosted-runner pool was saturated by the same outage that took the self-hosted runners offline), and GitHub Actions platform cancelled it on the queue timeout with `conclusion=failure`.

The fix was `actions/runs/<id>/rerun` (200 OK), which re-queued the run without requiring a new commit. Status moved from `completed/failure` back to `queued`. The babysit then continued waiting for both self-hosted gates (Green Gate / Staging Canary Gate / Full) AND the re-queued hosted gate (Example discipline).

## Anti-patterns

- ❌ Trusting a 3-element gate list when the PR has 4 check-runs. Always iterate the full `check-runs` surface.
- ❌ Treating `conclusion=failure` as code-actionable without the timing probe. A 0-billable-duration failure is INFRA; rerunning it is the right move, not handing off to drive-pr-to-green.
- ❌ Rerunning a cancelled run without checking if the cancellation was caused by a force-push (use the Phase 1.0 cancel-detection recipe in the main SKILL.md).
- ❌ Posting the premise-divergence notification (v1.9.0 protocol) for a 0-billable-duration failure. The premise hasn't lifted — the runner pool is the issue, not the code.

## Why this isn't captured elsewhere

- The `drive-pr-to-green` skill assumes "CI is red → code is bad → fix and re-run." It does NOT distinguish "CI was red because the runner pool cancelled before starting." That distinction belongs in the babysit, which is observe-only and must hand off cleanly.
- The `agento_report` skill aggregates PR status but does not probe timing endpoints. A `failure` looks identical regardless of cause.
- The deploy-run sub-class (v1.4.0–v1.6.0) has its own cancel-detection recipe for force-push-driven cancellations, but that's a different cause (force-push vs runner-pool saturation) with a different remediation (wait for next push vs rerun).

## Verification

After patching the babysit's predicate:

1. Trigger a runner-pool babysit on a PR with at least one failing check-run.
2. Confirm the failing check-run appears in the new predicate output (even if it's not in the prompt's named gate list).
3. For each failure, probe `actions/runs/<id>/timing` and confirm `billable_ms` is computed correctly.
4. If `billable_ms == 0` AND `run_duration_ms > 60_000`: rerun and continue waiting.
5. If `billable_ms > 0`: apply the v1.9.0 premise-divergence protocol.

Tests: extend `tests/test_babysit_runner_pool_subclass.py` (if it exists) with three new cases:
- `test_predicate_catches_unnamed_gate_failure` — predicate returns the failure even when the prompt's gate list doesn't include it
- `test_timing_probe_classifies_0_billable_as_infra` — `billable_ms == 0` + `run_duration_ms > 60_000` → infra, NOT premise-lifted
- `test_timing_probe_classifies_positive_billable_as_code` — `billable_ms > 0` + `conclusion == "failure"` → code, premise lifted, hand off
