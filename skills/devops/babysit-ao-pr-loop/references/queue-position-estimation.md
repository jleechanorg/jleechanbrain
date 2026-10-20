# Queue Position & ETA Estimation for Queued GitHub Actions Runs

When a babysit cron watches a queued Actions run id (e.g. waiting on `pr-preview.yml` for a deploy, or any self-hosted runner job), the yellow-tick update should include queue position + ETA. The default `gh` CLI doesn't expose queue length directly — you have to derive it from the Actions API.

## Recipe (paginated, accurate to ~100)

```bash
# Replace <OWNER>/<REPO> and <RUN_ID> with the actual values
REPO="jleechanorg/worldarchitect.ai"
RUN_ID="31072371181"

# Step 1: total queued (paginated; pages 1-5 covers up to 500 queued runs)
total_queued=0
for p in 1 2 3 4 5; do
  count=$(gh api "repos/$REPO/actions/runs?per_page=100&status=queued&page=$p" \
    --jq '.workflow_runs | length' 2>/dev/null)
  if [ -z "$count" ] || [ "$count" = "0" ]; then break; fi
  total_queued=$((total_queued + count))
done
echo "Total queued: $total_queued"

# Step 2: total in_progress
in_progress=$(gh api "repos/$REPO/actions/runs?per_page=100&status=in_progress" \
  --jq '.workflow_runs | length' 2>/dev/null)
echo "In progress: $in_progress"

# Step 3: position of target run = count of queued runs whose id <= target
# (Actions API returns most-recent first; older runs have larger id but were created earlier)
position=$(gh api "repos/$REPO/actions/runs?per_page=100&status=queued" \
  --jq '[.workflow_runs[] | select(.id <= '"$RUN_ID"')] | length' 2>/dev/null)
echo "Position: $position / $total_queued"

# Step 4: ETA estimate
# Conservative: each in_progress run takes ~5 min average for pr-preview jobs.
# Assumes ~14-16 self-hosted runners (verify with: gh api 'repos/<owner>/<repo>/actions/runners?per_page=100' --jq '.total_count')
# throughput_runs_per_min = in_progress / 5
# eta_minutes = position / throughput_runs_per_min
if [ "$in_progress" -gt 0 ]; then
  eta=$(awk "BEGIN { printf \"%.0f\", $position * 5 / $in_progress }")
  echo "ETA: ~${eta} minutes"
else
  echo "ETA: unknown (0 in_progress)"
fi
```

**Edge cases:**
- The Actions API is paginated and inconsistent: a query for `?status=queued&page=2` may return the same items as page 1 if status changed between requests. The loop above treats empty/zero count as the stop signal — that's correct.
- Run id ordering is monotonic but not strictly FIFO. A run id > target id may have been queued LATER if the runner pool reordered, but in practice GitHub queues in id order. The position estimate is a lower bound.
- For repos with >500 queued runs (rare, but possible during major deploy storms), extend the page loop.

## Worked example — PR #8787 deploy-run cron, 2026-08-06 05:30Z

```
Target run: 31072371181 (created 2026-08-06T04:50:30Z, queued ~40 min)
Total repo queued: 171 (100 page-1 + 71 page-2)
Total repo in_progress: 7
pr-preview queued: 2
pr-preview in_progress: 0
Position of 31072371181: ~59/171
ETA: ~42 min (with 7 in_progress runners at ~5 min/cycle)
```

The 0 pr-preview in_progress was the key signal — all 7 active runners were busy with Green Gate / WorldArchitect Tests / Self-Hosted MVP Shards from other PRs that entered the queue earlier. Throughput for pr-preview specifically was zero at that moment.

## What to put in the yellow-tick Slack message

```
:large_yellow_circle: PR <N> smoke test retry tick K/144 — run <id> still queued (~Xmin
in self-hosted runner pool). Repo-wide queue: ~Y queued, Z in_progress, W pr-preview
in_progress. <N_extra> pr-preview runs queued (incl. <target_id> at pos ~P/Y).
Self-hosted pool saturation <unchanged/improving/worsening>. <last_successful_deploy_url>
(if applicable — "see comment id X"). Continuing to monitor.
```

K = tick number (1-144). X = minutes since run created_at. P/Y = position / total. The wording should match the originating cron's expected reply shape; this template is the canonical minimal-yet-complete version.

## Anti-patterns

- ❌ Reporting only "still queued" without position/ETA — the operator can't tell whether to expect 5 min or 5 hours.
- ❌ Reporting "position 59" without total ("59 / 171") — meaningless number.
- ❌ Estimating ETA from position alone without considering in_progress throughput.
- ❌ Calling `gh run list --status=queued` — this CLI surfaces recent runs but does NOT page; for >100 queued, you'll silently miss most of them. Always use `gh api repos/.../actions/runs` with explicit `per_page` + `page` parameters.
- ❌ Treating self-hosted runner queue saturation as "GitHub is slow" — it's a fleet-capacity issue, not a platform issue. The `runner-health` skill has the diagnostic recipe; mention in the tick if the user is debugging the fleet itself.
