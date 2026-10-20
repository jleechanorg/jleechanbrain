# /af stuck-PR dispatch — when the factory is the right answer and you almost missed it

**Verified on [jleechanorg/worldarchitect.ai#8864](https://github.com/jleechanorg/worldarchitect.ai/pull/8864), 2026-08-17 (~20 min from "looks dead" to live worker).** The factory-take-this case for `/af` is the highest-stakes "do not stop halfway" failure mode in this umbrella — the operator lands on a PR that's already `[factory]`-labeled, looks stuck (no PR body, CONFLICTING, no recent commits), and the easy wrong answer is to ask which mode the user meant. The right answer is **always: factory takes it**.

## When this recipe applies (the only question you may ask)

Phase 0 classification for `/af` has **exactly two questions** worth asking, and only when the user's intent is genuinely ambiguous:

1. *User said `/af` at a brand-new goal with no PR yet* → that's feature-mode `/f` (see `dark-factory`).
2. *User said `/af` at an existing PR* → **PR-mode `/f-pr` always**. No second question, no "rebase vs. abandon" menu. The PR's head SHA + the factory label are the spec.

If the answer to question 2 is "yes" but the PR has the symptoms in §1 below, do **not** assume the factory is broken. Run the triage in §2 first. In every observed case (today's PR #8864 + prior PR #8787, PR #8561, PR #8856) the factory-dispatch path was correct and the operator only had to file one beacon issue + wait one intake tick.

## 1. The "looks stuck" symptoms

Any of these alone is enough to trigger the recipe:

- `gh pr view <N> --json mergeStateStatus` returns `DIRTY` (CONFLICTING).
- `gh pr view <N> --json body` returns `""` (no PR body) **AND** `labels` includes `[factory]`.
- `daemon.jsonl` rows for `external_ref=jleechanorg/<repo>#<N>` keep appearing as `SKIPPED_INELIGIBLE` or `SKIPPED_DUPLICATE` for the last 30+ minutes.
- A prior session posted PR comments like *"refusing factory PR adoption — already registered to bead dark-factory-1d2d"*.
- The branch shows `feat/custom-intake-questions` / `fix/x-redesign` — i.e., a named feature branch with prior commits, no factory worktree visible at `~/.worktrees/<repo>/wa-*`.

## 2. The 30-second triage (run in parallel; ~5 sec total)

```bash
gh pr view <N> --repo <O/R> --json url,headRefOid,baseRefName,mergeStateStatus,isDraft,labels
gh api repos/<O/R>/issues?labels=factory&state=open --jq '.[] | {n:.number,t:.title}'
ssh jeff-ubuntu "grep -a '\"external_ref\":\"<O/R>#<N>\"' /home/jleechan/Library/Logs/dark-factory/daemon.jsonl | tail -n 6"
ssh jeff-ubuntu "gh api rate_limit --jq '.resources | {core:.core.remaining, graphql:.graphql.remaining}'"
```

**Use `grep -a`**, not plain `grep`. The daemon JSONL is detected as binary; plain `grep` returns 0 lines silently and you'll diagnose the wrong cause.

The first three are facts; the fourth is the smoking gun ~80% of the time.

## 3. The five causes and falsifiable evidence

### 3.1 `gh` API rate-limit exhausted — the most common mis-diagnosis

**Symptom.** Daemon JSONL rows contain `"precondition":"probe_error:tool gh failed (rc=1): gh: API rate limit exceeded for user ID <UID> (HTTP 403)"`.

**Why it stacks up.** Each intake tick (~60 s) re-probes every labeled PR via REST. When the REST bucket is exhausted, every probe 403s; the factory correctly skips every tick. The rows accumulate but they do NOT mean the factory rejected the PR — they mean `gh` rejected the factory.

**Falsifiable test.** `gh api rate_limit --jq '.resources.core.remaining'` — if <100, this is the cause. The factory resumes automatically on the first tick after the bucket refills (no operator action needed besides filing the beacon).

**DO NOT do.** Do not re-file the same factory issue/bead "to wake it up" — every duplicate intake is itself a probe and another 403. Filing once is correct; re-filing is rate-limit-stacking.

### 3.2 "Branch-key stealing" comments — they're noise, not locks

**Symptom.** Repetitive PR comments like *"refusing factory PR adoption because it is already registered to bead dark-factory-1d2d"* stacked in the PR conversation.

**Why it is a TRAP.** The `dark-factory-XYZ` strings in those comments are ephemeral telemetry from prior coder sessions — collision hashes against sessions whose worktrees have been pruned. They are NOT a real lock on the current PR's adoption slot. The factory self-bypasses them when a fresh bead arrives at the head SHA, by spawning a **new branch `factory/dark-factory-<sid>-r1` derived from the PR head** (logged as `PR_NUMBER_REREZOLVED_NO_OPEN_PR`).

**Falsifiable test.** Does `daemon.jsonl` show an `INTAKE_BEAD_CREATED` row with `attempts=1, lifecycleState=QUEUED` for a NEW `dark-factory-<sid>` ID within the last 5 minutes after you filed the fresh factory-labeled issue? If yes, the new dispatch is alive — the "branch-key stealing" rows are stale noise.

### 3.3 `[factory]` label attached but no factory workspace yet

**Symptom.** PR has `[factory]` label; no `dark-factory-<sid>` events in `daemon.jsonl`; no worktree at `~/.worktrees/<repo>/wa-*`.

**Why.** The label is from a prior session and the factory has not yet been re-tasked. The factory needs an issue, not a PR, to drive its intake cycle (the issue body carries the spec; the PR's comments are output-only).

**Action.** File **one** factory beacon issue:

```bash
gh issue create --repo <O/R> \
  --title "[factory] PR<N>: drive <branch> to /ready + screenshots" \
  --body "target_repo=<O/R>
existing_pr=<N>
existing_branch=<branch>
factory_bead_id=<local-id-or-empty>
operator_priority=P1

REQUIRED: (1) rebase onto current origin/main, (2) PR body w/ Evidence
marker, (3) /es evidence gating, (4) /er PASS, (5) /advice APPROVE, (6)
/green CI rerun, (7) BEFORE/AFTER captioned screenshots.

SCOPE: <out-of-scope items>
NOT TO DO: hand-fix; factory owns the work." \
  --label factory
```

Wait one intake tick (~60 s). If you see `INTAKE_BEAD_CREATED` → `TASK_ROUTED` → `TASK_DISPATCHED` in that order, factory owns it.

### 3.4 Empty PR body + `[factory]` label

**Symptom.** `gh pr view --json body` returns `""`. The label is attached but the factory has not yet picked the PR up because the PR needs a body for the readiness gate (Evidence line, Test plan) to be meaningful.

**Why.** The factory writes the body as gate #2 in the readiness bundle, not as a precondition. Without a body the gate is blank but not unreachable.

**Action.** **Wait for the factory** to write the body. Do NOT write it yourself even if you can; that voids the label→merge E2E proof.

### 3.5 Worker pane shows blocked-on-permission (rare)

**Symptom.** `tmux capture-pane` shows repeated *"⚠ Bash command X requires approval"* with the same shell prompt waiting.

**Why this should be unreachable.** Factory workers spawn with `bypass permissions on` (visible in the pane footer). If you see this state, the worker is a contradiction that needs a `/af` restart from the daemon — do not `y`/Enter it yourself.

**Action.** Escalate to operator immediately.

## 4. The recovery loop after the beacon

After filing the beacon, monitor for **one** intake tick (~60 s):

```bash
ssh jeff-ubuntu "grep -a '\"beadId\":\"dark-factory-<sid>\"\\|\"sessionId\":\"wa-<N>\"' /home/jleechan/Library/Logs/dark-factory/daemon.jsonl | tail -n 10"
```

A live dispatch within ~60 s produces, in order:

| Row | What it means |
|---|---|
| `INTAKE_BEAD_CREATED` (lifecycleState=`QUEUED`) | Factory accepted the bead |
| `TASK_ROUTED` (routingVerdict=`STANDARD_PATH`) | Target repo resolved |
| `TASK_DISPATCHED` (sessionId=`wa-NNNN`, branch=`factory/dark-factory-<sid>-r1`) | Worker spawned |
| `PR_NUMBER_REREZOLVED_NO_OPEN_PR` | Branch doesn't have a PR yet; worker will file one |

If you see all four rows, the factory owns the work. **Stop touching the PR.** Spawning a parallel AO worker, rebasing yourself, or pushing to the branch — any of those steals the branch-key and undoes the dispatch.

## 5. The babysit cron prompt you must arm

After the dispatch, **immediately** arm a babysit cron via `cronjob create` with:

- `deliver='slack:<HOME_CHANNEL>'` (default `C0AJQ5M0A0Y` = `#ai-general`).
- `schedule='15m'` — recurring 15-min cadence — but with `--repeat 1` and one `--at`-style deadline OR clear self-cancel conditions in the prompt. NEVER `--every` without `--delete-after-run` (recurring; spawn-loop-safe). Banning `--keep-after-run` is the explicit rule (`babysit-cron-self-cancel-discipline`).
- The prompt must include these four commands in order, plus explicit self-cancel conditions:

```
1. gh pr view <N> --repo <O/R> --json <state fields>
2. ssh jeff-ubuntu "grep -a '\"beadId\":\"dark-factory-<sid>\"' <daemon.jsonl> | tail"
3. ssh jeff-ubuntu "tmux capture-pane -t <session-id> -p | tail -40"
4. Self-cancel on: MERGED, CLOSED-not-merged + factory STATE BLOCKED,
   pane frozen > 20 min.
5. Escalate on: MANUAL_HOLD event, factory escalation note, >3 ticks
   without token-burn increase.
```

If any of (1)-(4) is missing the babysit will post empty cron-poll pings that confuse the operator into "factory is silent = factory is dead" and re-trigger this same recipe unnecessarily.

For the `--cron-job-id $CRON_JOB_ID` self-remove contract, see the parent SKILL's babysit-cron-self-cancel-discipline section.

## 6. Pitfalls observed in this run

- **Phase 0 question inflation.** This case started with a 4-option clarification menu ("replay_clean_pr / rebase_keep_8864 / abandon / just_fix_8864_minimal"). All four were answerable without the user; the correct Phase 0 answer was *"factory takes it; file the beacon and babysit"* — never ask which mode.

- **Inline rebase. Almost.** Because the PR looked CONFLICTING, the obvious move was "let me rebase and fix that." Wrong: factory does its own rebase (with `--force-with-lease` on the worker-managed branch), and inline rebasing violates `dark-factory / ZERO direct work; monitoring only` rule.

- **`grep -a` flag.** Daemon JSONL is detected as binary; plain `grep` returns 0 lines silently. Always `grep -a -- 'pat'`.

- **Don't re-file the bead on the rate-limit symptom.** Each file is another REST probe = another 403. One file, wait one tick.

- **Don't write the PR body yourself.** The body is gate #2 in the readiness bundle; pre-writing it voids the label→merge E2E proof.

- **Worker pane `⚠ Forming… (Nm · ↓Xk tokens)` is healthy.** That's the worker planning, not stalled. Real stall = pane frozen > 20 min with no tool-call line AND no token-burn increase.

## 7. Cross-reference: half-stop trigger

If the user re-pings their own prior message after your first response ("don't stop", "fullsend", "drive to conclusion" as a verbatim re-utterance), that's the half-stop signal — see `references/half-stop-user-re-ping-signal.md` for the canonical 3-arm self-audit and the worked-example recipe. Combine with THIS recipe (factory takes the PR; file one beacon, monitor one tick, arm babysit) to convert a half-stop into a dispatched-in-30-seconds recovery.

## 8. When the factory IS stuck — branch-key loop on its own factory branch

**The §3.2 "branch-key stealing comments are noise, not locks" rule is WRONG for one specific case**: when the factory's *own* factory branch (`factory/dark-factory-<sid>-r<N>`) is the branch-key-locked target. In that case the comments are NOT stale noise from a prior pruned session — they're the factory refusing to dispatch a new worker onto a branch it already owns.

**Verified on PR jleechanorg/worldarchitect.ai#8994 (2026-08-17, ~90 min stuck).** Sequence:

1. Factory dispatches worker onto a NEW branch `factory/dark-factory-crfl-r1` (correct, see §4 row 3).
2. Worker opens PR #8994 against `factory/dark-factory-crfl-r1`.
3. Worker eventually exits (budget hit, user pause, or normal exit). The bead stays `DISPATCHED` because the branch is still registered to it.
4. Operator files a recovery beacon (or a new bead surfaces through intake) expecting the factory to spawn a new worker onto the same branch — the factory **correctly refuses** (`refusing factory PR adoption for branch factory/dark-factory-crfl-r2 because it is already registered to bead dark-factory-crfl`).
5. Every subsequent tick repeats step 4. The factory does NOT self-recover. The branch is a tombstone.

**This is different from §3.2 because the comments reference the factory's OWN factory branch, not a stale hash from a pruned worktree.** The "ephemeral telemetry" reading in §3.2 is wrong here — `dark-factory-crfl` is the live, owned bead, not a stale one. The branch-key collision is real.

### 8.1 Detection — three falsifiable signals

| Signal | How to verify |
|---|---|
| The branch name is `factory/dark-factory-*-r*` (factory's own naming convention) | `gh pr view <N> --json headRefName` |
| The repeated comment cites the SAME bead name as the original `INTAKE_BEAD_CREATED` row (not a different/stale `<sid>`) | `grep -a '"beadId":"dark-factory-XYZ"' daemon.jsonl \| tail` — same XYZ across the dispatch row AND every subsequent escalation row |
| No new `INTAKE_BEAD_CREATED` / `TASK_DISPATCHED` rows appear for any bead after the loop starts (factory is alive but refusing, not silent) | `grep -a 'INTAKE_BEAD_CREATED\|TASK_DISPATCHED' daemon.jsonl \| tail` |

**Two of three signals = stuck-on-own-branch.** All three signals + >30 min wall time = recovery now required (not "wait one more tick").

### 8.2 Recovery — Variant D: cherry-pick the factory's good work onto a clean branch

When the factory is genuinely stuck on its own branch, the recovery is **not** another beacon (the factory will refuse again) and **not** waiting for self-recovery (it won't happen). It is **Variant D — replay the factory's good commits onto a fresh `fix/<slug>-clean` branch off current `origin/main` and open a NEW PR**:

```bash
# 1. Verify the factory's commits are still good (review-able, in-scope)
git fetch origin <factory-branch>
git log --first-parent origin/main..origin/<factory-branch> --oneline --no-merges
# In-scope = every commit advances the PR's stated scope; no agento drift.

# 2. Fresh worktree from CURRENT origin/main (NOT from the factory branch)
cd /path/to/<repo>
git fetch origin main
git worktree add -b fix/<N>-<slug>-clean-replay origin/main
cd <new-worktree-dir>
git rev-parse HEAD   # MUST equal origin/main SHA
git status --short   # MUST be clean

# 3. Cherry-pick the in-scope factory commits in chronological order with -x
for sha in <commit-A> <commit-B> ...; do
  git cherry-pick -x "$sha" || break
done

# 4. Address any open CI failures from the factory's PR #N
#    (LOC ratchet, evidence gate, test failures, etc.) — these are usually
#    the REAL reason the worker exited without pushing green.

# 5. Capture visual evidence (per AGENTS.md "user-visible changes require
#    captioned video tied to the tested SHA") — committed to the branch.

# 6. Open NEW PR via REST (more reliable than GraphQL when rate-limited)
gh api -X POST repos/<O/R>/pulls \
  -f title="<original PR title> (clean replay)" \
  -f head="fix/<N>-<slug>-clean-replay" \
  -f base="main" \
  -F body="<replay body — see pr-cleanup-replay §Step 7 template>"
```

### 8.3 Why bypass `/af` and use `claude-code-claudem` instead

Per the SOUL.md `claude-code-claudem-over-direct-api` commitment, ordinary coding recovery is `claudem`'s lane, NOT `/af`. `/af` is the factory's lane and the factory is the entity that is stuck. Dispatching another `/af` worker would re-enter the same branch-key loop. `claudem` on a clean worktree bypasses the factory entirely.

```bash
cd <clean-worktree-dir>
bash -lic 'claudem -p "$(cat /tmp/<brief>.txt)"' --max-turns 150
```

Use `--max-turns 150` (~78 min budget — see memory note 2026-08-10). The recovery brief should include: the 4 specific CI failures the factory left red, the cherry-pick order, the evidence capture recipe, and a one-line end-state declaration the worker emits when done.

### 8.4 Close the stuck factory PR AFTER the new PR is open

Once the clean replay PR is open and green CI starts:

1. **Do NOT close the factory PR #N before opening the new one** (the `Closes #N` reference reopens the issue if the old PR is already closed — see `pr-cleanup-replay` Pitfall 6).
2. Comment on PR #N with the new PR URL and one-line reason: `*Clean replay PR #<NEW> opened. Factory was stuck in branch-key loop on this PR's head branch factory/dark-factory-<sid>-r<N>; cannot re-dispatch worker onto its own branch.*`
3. Close PR #N. The factory's `dark-factory-<sid>` bead stays registered to the now-closed branch — that's fine, factory doesn't auto-revive closed branches.

### 8.5 Pitfalls specific to Variant D recovery

- **Don't wait for the factory to self-recover** — once the branch-key loop starts, the factory will not exit it on its own. >30 min wall time on stuck-on-own-branch = manual recovery required.
- **Don't file more factory beacons** — each one is another intake probe the factory will refuse. Wastes REST quota (see §3.1) and the `branch-key stealing` PR comment spam.
- **Don't push onto the factory's own `factory/dark-factory-*-r*` branch** — `never-push-onto-someone-elses-pr-head` applies even when "someone else" is the factory. Cherry-pick onto a fresh branch instead.
- **Don't `git rebase` the factory's branch onto current main inline** — same audit-story problem as the polluted-branch case in `pr-cleanup-replay` §Anti-patterns. The branch's commit set is the factory's work; rebasing rewrites but keeps the factory's provenance, and the factory's branch-key lock still applies to the rewritten history.
- **The factory worker's tmux pane is NOT the recovery point.** Even if the pane is alive and producing tokens, the bead is already `DISPATCHED` to that branch and the factory will refuse to spawn a replacement. The pane is a worker the factory can no longer coordinate.
- **`/af` cannot help** — the factory's own branch-key lock prevents `/af` from adopting the work. Even `/f-pr <N>` against the stuck PR will enter the same loop. The only escape is a fresh branch, which `/af` cannot create for an existing branch-key-locked bead.

### 8.6 Cross-reference

- `pr-cleanup-replay` Variant A — the recipe structure (cherry-pick → new branch → new PR → close old) is the same; only the *trigger* differs (long-stale drift vs. live factory state-machine loop).
- `references/half-stop-user-re-ping-signal.md` — if the user re-pings with "Fullrun don't stop" / "drive to green" / "merge it", that REINFORCES the Variant D path (do NOT ask which mode; bypass `/af` and dispatch claudem now).
- `claude-code-claudem` skill — the worker invocation pattern for the recovery dispatch.
