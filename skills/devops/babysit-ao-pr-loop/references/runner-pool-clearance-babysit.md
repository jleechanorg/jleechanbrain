# Runner-pool / CI-clearance babysit (v1.8.0)

Worked example, recipes, and edge cases for the runner-pool / CI-clearance babysit sub-class added in `babysit-ao-pr-loop` v1.8.0. Read this when:

- Authoring a new cron that targets a structurally-not-fixable PR (no AO worker, takeover worker gone silent, PR head stuck)
- Inheriting a runner-pool babysit and need to confirm the cadence without re-creating the recipe
- Diagnosing why a runner-pool babysit is producing no per-tick output (the SILENT contract is correct — but check the four reconfigurable triggers before assuming noise is the right state)

## When to use this sub-class (vs. AO-worker / deploy-run)

| Shape | Sub-class |
|---|---|
| `babysit wa-NNNN on PR #N` | AO-worker (1.0.0) |
| `babysit deploy run <id> on PR #N` | Deploy-run (1.4.0) |
| `runner-pool clearance` / `CI clearance` / `pool drain` / `no AO worker, pool is saturated` | **Runner-pool (1.8.0)** |

The defining question: **Is there an AO worker session the babysit can nudge?** If no, AND the PR can't be moved by code edits, this is the right sub-class.

## Worked example: PR #8794 (verified 2026-08-06)

**Setup:**
- Cron: `b6c8887f546e`, started 2026-08-06T07:00Z, target thread C0AH3RY3DK6/1785996838.635219
- Branch: `feat/campaign-share-url-phase1`
- Head SHA baked into the cron prompt: `a3c3c19e1416f473e9ae98febb2c5cfc21827cc3`
- Takeover worker: gone silent (no `ao session ls` match)
- Initial queue depth: 152 queued / 3 in_progress (repo-wide)

**Tick at 11:40Z (first tick with non-trivial state change):**

1. **Phase 0 — terminal check.** `gh pr view <N> --json state,mergedAt,closedAt` returned `GraphQL: API rate limit already exceeded for user ID 13840161`. Switched to REST: `gh api repos/<owner>/<repo>/pulls/<N>` → `state=open, head_sha=930210cab680558191c8ac0f65e44678dfc665ff, mergeable=true, draft=false`. NOT merged, NOT closed — proceed.
2. **Phase 1 — observe pool-and-PR.** Ran five parallel REST probes (see commands in SKILL.md §Phase 1).
3. **Phase 1.0 — head drift detected.** PR head `930210ca` ≠ cron-prompt head `a3c3c19e`. Branch tip (most recent commit in `/pulls/<N>/commits?per_page=10`) = `77652b0926b3cb561d0777d3c96955b7e24b4a98` — 7 commits AHEAD of PR head. The takeover worker had force-pushed on the branch without re-advancing the PR ref; the PR's CI ratchet is stuck on `930210ca`.
4. **Phase 2 — decisions crossed.** Queue depth dropped from 152/3 to 1/0 (≥ 20 drop → meaningful pickup, post). Head drift detected (post). 5 CI failures on `930210ca` (post). Branch tip `77652b09` has zero CI runs (post). Operator nudge needed (post).
5. **Phase 3 — single-message post.** Under-12-line status with all five signals. Verifier via `conversations.replies` confirmed `ThreadTs == 1785996838.635219` correctly.

**Outcome of this tick:** Posted one message; loop continues at 10-min cadence.

## Phase 1.1 — REST-vs-GraphQL rate-limit fallback (worked)

Rate-limit error from `gh pr view --json`:
```
GraphQL: API rate limit already exceeded for user ID 13840161.
```

This is the **secondary auth-class bucket** for `gh` CLI's GraphQL endpoint. The REST API uses a separate quota and is typically not blocked at the same time. Switch:

| GraphQL (rate-limited) | REST (usually available) |
|---|---|
| `gh pr view <N> --json state,headRefOid,mergeable,isDraft,updatedAt` | `gh api repos/<owner>/<repo>/pulls/<N> --jq '{state, head_sha: .head.sha, mergeable, draft, updated_at}'` |
| `gh pr checks <N> --json name,state,conclusion,detailsUrl` | `gh api repos/<owner>/<repo>/commits/<HEAD_SHA>/check-runs --jq '[.check_runs[] | {name, status, conclusion}]'` |
| `gh api repos/<owner>/<repo>/actions/runs?per_page=100&status=queued --jq '.total_count'` | Same — REST is unaffected |
| `gh api repos/<owner>/<repo>/actions/runs?per_page=30&branch=<BRANCH>` | Same — REST is unaffected |

**Anti-pattern:** retrying the same `gh pr view --json` command. The GraphQL bucket does not refresh on the order of seconds — assume 5-15 min cool-down unless the operator has reset it. Switch to REST immediately.

## Phase 1.0 — PR-head-vs-branch-tip drift (worked)

The most common drift shape for a structurally-not-fixable PR is: a takeover worker force-pushes on the branch but the PR ref doesn't advance (because the worker is gone — the force-push record is the last action they took). The PR's `headRefOid` continues to point at the OLD HEAD, and the CI ratchet is stuck on the old HEAD's check-runs. The branch has unpushed-to-PR commits that have no CI.

**Detection recipe:**
```bash
# 1. PR head (REST)
PR_HEAD=$(gh api repos/<OWNER>/<REPO>/pulls/<N> --jq '.head.sha')

# 2. Branch tip (most recent commit in the PR's commit list)
BRANCH_TIP=$(gh api repos/<OWNER>/<REPO>/pulls/<N>/commits?per_page=1 --jq '.[0].sha')

# 3. Compare to the SHA baked into the cron prompt
PROMPT_SHA="<a3c3c19e1416f473e9ae98febb2c5cfc21827cc3>"

if [ "$PR_HEAD" != "$PROMPT_SHA" ]; then
  echo "DRIFT: PR head $PR_HEAD differs from prompt-baked $PROMPT_SHA"
fi

if [ "$BRANCH_TIP" != "$PR_HEAD" ]; then
  echo "DRIFT: branch tip $BRANCH_TIP is newer than PR head $PR_HEAD"
  # Count how many commits ahead
  AHEAD=$(gh api repos/<OWNER>/<REPO>/pulls/<N>/commits?per_page=100 --jq 'length')
  echo "Branch is $AHEAD commits ahead of PR head"
fi
```

**Post-bake mitigation:** If the cron prompt MUST reference a SHA (it almost always shouldn't; live-fetch is better), include the live-fetch recipe in the prompt so the cron can refresh its own state on each tick. Update the prompt's SHA to the live `PR_HEAD` at cron create time, and re-fetch periodically.

## Phase 2 — sparse-poster decision tree

Post ONE message per tick ONLY when ANY of these is true. Otherwise emit `[SILENT]`.

| Trigger | Detection | Post? |
|---|---|---|
| CI check transitioned to terminal state | Compare `check-runs` conclusion to last-tick state | ✅ |
| New commit on PR head | `pulls/<N>.head_sha` differs from last-tick reading | ✅ |
| Queue depth changed by ≥ 20 | Compare `actions/runs?status=queued&total_count` to last-tick reading | ✅ |
| Branch tip moved relative to PR head | Compare `pulls/<N>/commits[0].sha` to last-tick reading | ✅ |
| Queue depth changed by < 20 | — | ❌ `[SILENT]` |
| Untracked files in unrelated worktree | — | ❌ `[SILENT]` |
| Worker spawn chatter (if any) | — | ❌ `[SILENT]` |
| Comment posted on PR by operator | — | ✅ (one-line ack) |

**12h staleness ceiling override:** If the loop has been silent for 12h straight, post ONE escalation regardless. The operator needs to know the babysit is still running but the PR is not moving. Then continue but flag staleness in each subsequent post.

## Edge cases observed

### 1. Cron-prompt-baked SHA is stale at cron creation time

If the cron is created from a session that already knows the SHA is stale, the prompt should live-fetch rather than bake. If it cannot, the take-the-baked-SHA-and-verify-each-tick pattern is the fallback. Either way, the babysit should NOT trust the prompt's SHA as authoritative.

### 2. The "head" reported by `pulls/<N>.head.sha` is `930210ca` but the rest of the PR commits show `77652b09` as the most recent

This is the "trailing-comma force-push" shape: the worker's last git push was a force-push that moved the branch to `77652b09` but the PR's `head` field still tracks the older ref. The GitHub UI may show `77652b09` as the most recent commit, but the API returns `930210ca` as the head. Both readings are correct — the branch tip has 7 unpushed-to-PR commits, and the PR is "stuck" on `930210ca` until the operator either force-pushes again to re-advance the PR ref OR closes and reopens the PR.

### 3. CI on the old head has failures, but the new branch tip has no CI at all

This is the diagnostic ambiguity zone. The PR is NOT green because the old head has failures. The PR is also NOT red because the new head has no CI. The right action is: post the dual state ("5 failures on old head; 0 runs on new head"), note that the operator needs to either force-push to re-advance the PR ref OR close-and-reopen, and continue the babysit. Do NOT mark the PR as "ready for /green" because the underlying structural block is still the pool saturation + the missing PR-ref advance.

### 4. Pool drains from 152 → 0 between two ticks

This is the "victory condition" — but the PR is still not green because the takeover worker is gone and the PR head is stuck. The pool drain is necessary but not sufficient. Post the drain as a positive signal ("pool drained; PR now reachable for /green pending operator PR-ref advance"), but do NOT mark the babysit done. The structural block now has TWO layers: pool drain (resolved) + PR-ref advance (still pending operator action).

### 5. The PR head advances between two ticks (a new push happened)

This is the "victory condition variant 2" — the operator or another worker re-pushed and advanced the PR head to the branch tip. CI should re-seed on the new head. Post the advance as a positive signal, run `check-runs` on the new head, and continue the babysit at the same cadence. If the new head's CI goes green, the babysit can mark the PR ready for /green.

### 6. `ao session ls` returns a worker but the cron prompt says "no AO worker"

The cron prompt's "no AO worker" claim was true at the time the cron was created, but a new worker may have been spawned later. The babysit should NOT trust the prompt's claim about worker state — it should live-check `ao session ls` each tick and reconcile. If a new worker is alive AND the PR is in `pr_open` state, the babysit should pivot to the AO-worker sub-class contract (Phase 1.2 in the parent skill) instead of the runner-pool contract.

## Companion: queue-depth-tracking template

If the cron will live for hours, track the queue depth + head SHA tick-to-tick so the post body can compare deltas. State stored in the cron's own state directory or as a comment in the originating thread:

```bash
# On each tick, append a single line to a local state file
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
HEAD=$(gh api repos/<OWNER>/<REPO>/pulls/<N> --jq '.head.sha')
QUEUED=$(gh api "repos/<OWNER>/<REPO>/actions/runs?per_page=100&status=queued" --jq '.total_count')
IN_PROG=$(gh api "repos/<OWNER>/<REPO>/actions/runs?per_page=100&status=in_progress" --jq '.total_count')
echo "${TS} head=${HEAD:0:7} queued=${QUEUED} in_progress=${IN_PROG}" >> ~/.smartclaw/var/babysit-<cron-id>.state
```

The state file is small (one line per tick) and can be `tail`d by the operator at any time. It also tells the babysit whether the previous tick's reading is `queued=1, in_progress=0` vs `queued=152, in_progress=3` — the Δ triggers the post.

## Pattern: rotating cadre of PRs in a single cron prompt

If the operator wants to babysit multiple structurally-not-fixable PRs in one cron, the prompt should iterate over a list of (PR_number, channel, thread_ts) tuples and run the runner-pool sub-class on each. Each iteration produces an independent SILENT-or-post decision. The state file gets a per-PR section. This is uncommon but supported by the recipe above.
