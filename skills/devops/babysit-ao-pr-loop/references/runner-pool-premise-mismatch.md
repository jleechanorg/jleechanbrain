# Runner-pool babysit — premise-mismatch self-cancel (v1.9.0)

Worked example + decision recipe for the v1.9.0 "premise-mismatch self-cancel" protocol. Read this when:

- Inheriting a runner-pool babysit that was created when the structural premise held (pool saturated, no CI, takeover worker gone) and the live state has now shifted (pool drained, CI ran, head drifted onto fixable failures)
- Diagnosing why a runner-pool babysit self-cancelled on its first tick with a "Playbook premise no longer holds" post
- Authoring a NEW runner-pool babysit and wanting to bake the premise-check into the prompt

The core insight: **a cron prompt's structural premise can lift mid-loop**. The prompt's "do not propose code fixes" instruction is conditional on the premise ("the only thing keeping this PR red is the runner pool"). When the pool drains and CI actually runs, the failures may be code-actionable — and the babysit is observe-only by design, so it cannot drive a fix. Continuing to tick produces misleading "still red, awaiting operator" posts. The right action is **one premise-divergence notification + self-cancel + hand off to drive-pr-to-green**.

## When this protocol fires

The protocol fires when ALL of the following are true:

1. The babysit is the **runner-pool sub-class** (not AO-worker, not deploy-run).
2. The cron prompt's structural premise has lifted. Three signals (any one is enough):
   - **Pool drained** — queue depth dropped from ≥ 50 to < 50 between two ticks.
   - **Head drifted** — `pulls/<N>.head.sha` no longer matches the SHA baked into the prompt.
   - **CI ran on the new head and failed for a fixable reason** — Tests Required Gate, Directory tests, Playwright, lint/typecheck, or regression.
3. The failures are **code-actionable**, not structural. Distinguishing test: would another worker with worktree access be able to write a fix? If yes, it's actionable. If no (e.g. the failure is "preview URL 502'd", "sandbox env missing a credential"), it's still structural — the protocol does NOT fire.

## PR #8794 verified example (2026-08-06, cron `b6c8887f546e`)

This session IS the v1.9.0 verification. The prior tick (2026-08-06 ~07:00Z, which created v1.8.0) inherited the cron with the structural premise intact:

- Cron prompt baked: head `a3c3c19e1416f473e9ae98febb2c5cfc21827cc3`, queue "152/3 (saturated)".
- Takeover worker gone silent (no `ao session ls` match).
- PR state: open, mergeable, draft.

By the time my tick fired at 11:52Z:

- **Live PR head**: `930210cab680558191c8ac0f65e44678dfc665ff` (drifted — takeover worker had force-pushed 4 commits: `fe49b63c2b` "race rev-ct16e", `3a1c778c1f` evidence refresh, plus the `930210ca` and `77652b09` tip).
- **Queue**: 1 queued / 2 in_progress (drained 99% from the cron-prompt-baked 152/3).
- **CI on `930210ca`**: 5 failures for code-actionable reasons:
  - Tests Required Gate — failure
  - Directory tests (core-tests + core-mvp-1/2/3 self-hosted) — 4 failures
  - Playwright auth browser tests (Chromium + WebKit) — failure
  - Mobile Auth Same-Origin Regression — failure
  - beads-jsonl-validation — failure
- **CI on branch tip `77652b09`**: zero runs (no CI on the newer commits).
- **Takeover worker**: still gone.

The structural premise was wrong on all three signals. The correct action was to post the divergence and self-cancel.

## Detection recipe (run after Phase 1 observe, before Phase 2 decide)

```bash
# Live PR state
PR_HEAD=$(gh api repos/<OWNER>/<REPO>/pulls/<N> --jq '.head.sha')
PR_STATE=$(gh api repos/<OWNER>/<REPO>/pulls/<N> --jq '.state')

# Branch tip
BRANCH_TIP=$(gh api repos/<OWNER>/<REPO>/pulls/<N>/commits?per_page=1 --jq '.[0].sha')

# Queue depth (live)
QUEUED=$(gh api "repos/<OWNER>/<REPO>/actions/runs?per_page=100&status=queued" --jq '.total_count')

# CI failures on the live head (REST, GraphQL rate-limited)
FAILURES=$(gh api "repos/<OWNER>/<REPO>/commits/${PR_HEAD}/check-runs" \
  --jq '[.check_runs[] | select(.conclusion == "failure") | .name]')

# Decide
PREMISE_LIFTED=0
if [ "$QUEUED" -lt 50 ] && [ -n "$FAILURES" ] && [ "$(echo "$FAILURES" | jq 'length')" -gt 0 ]; then
  PREMISE_LIFTED=1
fi
if [ "$PR_HEAD" != "<baked-sha>" ]; then
  # Head drifted — check if new head has CI failures
  if [ -n "$FAILURES" ] && [ "$(echo "$FAILURES" | jq 'length')" -gt 0 ]; then
    PREMISE_LIFTED=1
  fi
fi

if [ "$PREMISE_LIFTED" = "1" ]; then
  # Post divergence + self-cancel + [SILENT] thereafter
  ...
fi
```

**Anti-pattern (verified 2026-08-06):** running the detection AFTER posting the Phase 2 tick update. The order matters — the premise check MUST gate the tick. If the tick is already posted with "still red, awaiting operator" before the premise check fires, the operator reads two contradictory messages in 10 minutes and the cron looks broken.

## Post template (under 12 lines, do NOT propose the fix)

```
:warning: *Playbook premise no longer holds for PR #N* — handing off.

• Head drift: <baked-sha> → <live-sha> (takeover worker landed <commit_count> commits since cron creation: <short_sha1> <headline>; <short_sha2> <headline>; ...)
• Runner pool cleared: <current_queued> queued / <current_in_progress> in_progress (NOT the <baked>/<baked> the playbook assumed)
• CI ran at <live-sha> and FAILED — not structurally blocked:
  - :x: <failure_1>
  - :x: <failure_2>
  - :x: <failure_3>
  - :x: <failure_4>
  - :x: <failure_5>
• :white_check_mark: <check_that_did_pass_1> (green condition #N met)
• :white_check_mark: <check_that_did_pass_2>

This is now a /green-bring babysit with code-actionable failures, not a no-fixable structural block. The current babysit (id `<CRON_JOB_ID>`) was scoped to runner-saturation only and has no fix authority — self-cancelling. Recommend relaunching with `drive-pr-to-green` from `<live-sha>` if you want it pushed.
```

## Self-cancel sequence (after the post lands)

Order matters:

1. **Post first**, verify `ok:true` AND `thread_ts == <correct_thread>` (the post can land at channel root if the prompt's thread_ts is wrong — re-fetch `conversations.replies` after the post).
2. **Then self-cancel**: `hermes cron remove $CRON_JOB_ID` (verified primary on this host — `cronjob` CLI is NOT installed).
3. **Then emit `[SILENT]`** on all subsequent ticks. The cron is inert; the operator decides whether to relaunch with `drive-pr-to-green` or a fresh AO worker.

**Anti-pattern:** self-cancelling BEFORE the post lands. If the post fails (rate limit, network error, missing scope), the cron is already dead and the operator never sees the divergence. Always post-and-verify-then-cancel.

## What the next babysit should be (operator decision)

The operator has three reasonable options after seeing the premise-divergence post:

1. **Relaunch with `drive-pr-to-green`** — the right tool when the failures are real bugs that need investigation. `drive-pr-to-green` has worktree access and can propose fixes.
2. **Relaunch with a fresh AO worker** — the right tool when the failures are flakey and need a careful re-run with `/es` evidence.
3. **Hand off to a human** — the right tool when the failures need a domain decision (e.g. "should this test be marked flaky or should the code be reverted").

The premise-divergence post does NOT pick one — it lists all three. The operator decides.

**Anti-pattern:** the babysit picking one option ("recommend drive-pr-to-green") without surfacing the alternatives. The operator may have a different read on the situation; the babysit should give them the data and the three options, not a recommendation. (Verified 2026-08-06 — my PR #8794 post did recommend `drive-pr-to-green` because the failures looked code-actionable, but a future iteration of the protocol should be more neutral.)

## Companion: how the takeover-handoff skill handles the same premise shift

`hermes-takeover-pr-handoff` deals with a related but distinct scenario: a takeover agent hands off a PR to a babysit at takeover time. The handoff skill already encodes "verify live state in parallel" and "do not trust the report" — the same instinct applies here. The difference: the takeover handoff is at handover time (one-shot verification), while the runner-pool premise-mismatch is at every-tick verification. The premise-mismatch protocol is essentially a "continuous takeover-handoff" — every tick is a tiny handover check.

## Pattern: bake the premise check into the prompt

For a new runner-pool babysit, the prompt SHOULD include the premise check verbatim:

```
Phase 1.5 — premise check (run after Phase 1 observe, before Phase 2 decide):
- If queue depth < 50 AND CI failures exist on the current head AND the failures are
  code-actionable (not structural): post the premise-divergence notification (template
  in `references/runner-pool-premise-mismatch.md`), self-cancel via `hermes cron remove
  $CRON_JOB_ID`, emit [SILENT].
- If queue depth ≥ 50 OR no CI on the current head OR the failures are structural
  (preview-URL 502, missing credential, etc.): continue to Phase 2 normally.
```

Baking the check into the prompt eliminates the "did I forget to run the check?" failure mode at every tick.

## Verification matrix (run after applying v1.9.0 to a new prompt)

| Check | Pass criterion |
|---|---|
| Premise check is invoked between Phase 1 observe and Phase 2 decide | ✅ grep prompt for "premise check" or equivalent |
| Premise-divergence post template is included verbatim | ✅ grep prompt for "Playbook premise no longer holds" |
| Self-cancel uses `hermes cron remove` (not `cronjob action=remove`) | ✅ grep prompt for `hermes cron remove $CRON_JOB_ID` |
| Post-then-cancel order is explicit | ✅ grep prompt for "post first, then self-cancel" |
| Anti-patterns listed: no continuing tick, no proposing fix, no cancel-before-post, no re-running sub-class | ✅ grep prompt for each anti-pattern phrase |
| Worked example references a verified cron id (e.g. `b6c8887f546e`) | ✅ grep prompt for the verified cron id |
