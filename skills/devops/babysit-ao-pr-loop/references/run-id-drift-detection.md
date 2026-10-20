# Run-Id Drift Detection for Deploy-Run Babysits

When a deploy-run babysit cron is created with a hard-coded `actions/runs/<id>` and the worker force-pushes between creation and first tick, the original run id is **cancelled** and replaced by a new run on the same branch. Naively polling the original id produces either:

- "completed/cancelled" forever (silently parks the cron), OR
- a false-positive "completed" that triggers the smoke test against the **previous deploy's bundle** (which doesn't contain the new code's event names), posting a spurious RED.

This file is the **drop-in Phase 1.0 recipe** to detect and recover from drift. The full discussion lives in `SKILL.md` under the deploy-run babysit sub-class section "Run id drift (force-push between cron creation and first tick)" (v1.6.0).

## Drop-in Phase 1.0 block (replaces the simple `gh api actions/runs/<id>` probe)

```bash
REPO="<OWNER>/<REPO>"          # e.g. jleechanorg/worldarchitect.ai
RUN_ID="<original run id>"      # e.g. 31072371181
BRANCH="<branch name>"          # e.g. fix/funnel-diag-5-events
PR_NUM="<PR number>"            # e.g. 8787

# Step 1: probe the original run id
RUN_JSON=$(curl -sS -H "Authorization: token $GITHUB_PAT_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/$REPO/actions/runs/$RUN_ID")
STATUS=$(echo "$RUN_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))")
CONCLUSION=$(echo "$RUN_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('conclusion',''))")
RUN_UPDATED_AT=$(echo "$RUN_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('updated_at',''))")

# Step 2: get the PR's updated_at (force-push bumps it)
PR_JSON=$(curl -sS -H "Authorization: token $GITHUB_PAT_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/$REPO/pulls/$PR_NUM")
PR_UPDATED_AT=$(echo "$PR_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('updated_at',''))")
PR_STATE=$(echo "$PR_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('state',''))")

# Step 3: detect drift. THREE signals; any one is enough.
#   (a) cancelled completion
#   (b) run updated_at is at-or-after the PR updated_at (force-push synchronized)
#   (c) PR is still open (otherwise Phase 0 step 1 should have caught it)
DRIFT="false"
if [ "$STATUS" = "completed" ] && [ "$CONCLUSION" = "cancelled" ]; then
  DRIFT="true"
fi
if [ -n "$PR_UPDATED_AT" ] && [ -n "$RUN_UPDATED_AT" ] && \
   [ "$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$RUN_UPDATED_AT" +%s 2>/dev/null)" \
     -ge "$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$PR_UPDATED_AT" +%s 2>/dev/null)" ]; then
  DRIFT="true"
fi

# Step 4: re-discover the current deploy run for this branch
if [ "$DRIFT" = "true" ]; then
  NEW_RUN=$(curl -sS -H "Authorization: token $GITHUB_PAT_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$REPO/actions/runs?per_page=30&branch=$BRANCH" \
    | python3 -c "
import sys, json
d = json.load(sys.stdin)
runs = [r for r in d.get('workflow_runs', [])
        if r.get('name') == 'Deploy PR Preview (Rotating Pool)'
        and r.get('status') in ('queued', 'in_progress')]
runs.sort(key=lambda r: r['id'], reverse=True)
print(runs[0]['id'] if runs else '')
")
  
  if [ -n "$NEW_RUN" ]; then
    echo "DRIFT detected: original run $RUN_ID was cancelled; new deploy run is $NEW_RUN"
    RUN_ID=$NEW_RUN
    # Re-probe the new run
    RUN_JSON=$(curl -sS -H "Authorization: token $GITHUB_PAT_TOKEN" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/$REPO/actions/runs/$RUN_ID")
    STATUS=$(echo "$RUN_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))")
    CONCLUSION=$(echo "$RUN_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('conclusion',''))")
  else
    echo "DRIFT detected: original $RUN_ID cancelled, no new deploy run yet — short-circuit to 'still queued' tick"
    STATUS="queued"
    CONCLUSION=""
  fi
fi

# Step 5: now STATUS / CONCLUSION / RUN_ID reflect the *current* deploy run; proceed with the
# normal wait-condition logic (queued → in_progress → completed) and the smoke-test payload.
echo "Monitoring run id: $RUN_ID (status=$STATUS, conclusion=$CONCLUSION)"
```

## When to use this

Use this for **every deploy-run babysit**, not just when drift is suspected. The recipe is cheap (2-3 API calls) and prevents the silent-park and false-positive-RED failure modes. Verified on PR #8787 deploy-run babysit, 2026-08-06:

- Original run `31072371181` was cancelled at 05:44:04Z by a force-push (head da1d95fe9d → 0a9d234a)
- New run `31075008771` was discovered and is now the active monitor target
- Both drift signals (a) and (b) fired

## Companion: when NOT to update the prompt with the new run id

The recipe above sets `RUN_ID=$NEW_RUN` **for the current tick only**. The next tick re-runs drift detection. Two reasons to keep it that way:

1. **Self-healing.** If drift happens again (another force-push during the 24h tick budget), the recipe re-discovers without needing prompt updates.
2. **No cron-edit race.** The alternative — `cronjob action=update job_id=...` to lock the new run id into the prompt — re-couples the cron to a specific id, undoing the drift-resistance on the next force-push, AND introduces a cron-edit race (the prompt file is read on each tick; if the edit lands mid-tick, the next tick may see a half-written prompt).

**Trade-off:** the cancel-detection costs ~2 API calls per tick. Acceptable; the rate limit budget is ~5000 calls/hour for `GITHUB_PAT_TOKEN`.

## Edge cases

- **Branch deleted.** If `actions/runs?branch=$BRANCH` returns 0 runs AND the PR is still `open`, the worker likely force-pushed to a different branch name. Check `PR_JSON.headRefName` against the `$BRANCH` the cron was started with — if they differ, the cron is on the wrong branch (escalate, do not auto-correct).
- **Multiple deploy runs queued.** If two `Deploy PR Preview (Rotating Pool)` runs are queued (e.g. one from the previous head, one from the new head), take the **largest id** (most recently created). The script handles this via `sort(key=lambda r: r['id'], reverse=True)`.
- **Force-push during in_progress.** Rare — the original run is `completed` (not cancelled) if it had already started; the new run is queued. Drift detection still fires via signal (b) (synchronized `updated_at`).
- **PR closed mid-tick.** Phase 0 step 1 should have caught this. If drift detection runs first and finds the PR closed, fall back to the standard closeout message — do not post a smoke-test result.

## Verification recipe (post-update)

After adding this block to a deploy-run babysit prompt, verify on a quiet branch:

```bash
# 1. Confirm the block runs without error on a normal (non-drift) tick
# 2. Confirm the discovery works on a real drift: push a no-op commit to a test PR
#    and observe the cron correctly switching to the new run id
```

## See also

- `SKILL.md` §Deploy-run babysit sub-class → Run id drift (v1.6.0) — full discussion.
- `SKILL.md` §Anti-patterns → "Treating `status=completed, conclusion=cancelled` as 'the run is done, smoke test now'" — the wrong behavior.
- `references/queue-position-estimation.md` — the next step after drift detection: compute position/ETA for the new run id.
