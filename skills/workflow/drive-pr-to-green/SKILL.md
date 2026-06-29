---
name: drive-pr-to-green
version: 1.0.0
description: Drive any PR I own (or am asked to) all the way to a green PR state (CI green, required review status clear, MERGEABLE/CLEAN) and hand off to skeptic-cron.yml for the auto-merge when Jeffrey says "do it directly if its easy" or "next time don't ask, just finish the work". Never stop at local commits, never stop at "ready for review", never run `gh pr merge` directly (skeptic-cron owns the merge), never ask "want me to merge?" when the user has already given the go-ahead. Stop-halfway is the exact violation this skill exists to prevent.
tags: [workflow, pr, ci, green, autonomy, dispatch]
related_skills: [always-pr-never-local-edit, github-pr-workflow, dispatch-task]
---

# drive-pr-to-green

## Trigger

Any of these messages should fire this skill — load it BEFORE taking the first action:

| User signal | Action |
|---|---|
| "/green this PR" / "/green up PR #N" / "green up the trigger PR" | Drive that PR to mergeable green; auto-merge handled by skeptic-cron.yml |
| "Lets /green the trigger PR" | Drive to green; auto-merge handled by skeptic-cron.yml (Jeffrey's voice) |
| "actually fix PR comments and coderabbit issues directly and then merge" | Address every CodeRabbit/PR review issue, then merge |
| "do it directly if its easy otherwise spawn AO worker" | Self-execute if trivial; otherwise dispatch AO with "drive to green" instructions |
| "next time don't ask me, just finish the work" / "dont ask me just finish" | Do NOT pause to confirm between (push, CI, review fixes, merge). Execute the whole sequence. |
| "stop stopping halfway" / "why did you stop halfway?" | Reflect root-cause + load this skill on the next iteration |
| Any task that ends with a PR — the work is not done until the PR is MERGED | Apply the full sequence below |

## Rule (the anti-stop-halfway contract)

**A PR is not done until it is green-CI + clear of required review state + either (a) confirmed mergeable and handed off to `skeptic-cron.yml` for the auto-merge, or (b) one short status reply that includes the PR URL and exactly which gate is blocking.**

The "stop halfway" failure pattern, observed verbatim in the 2026-06-12 /levelup+/dice PR #7484 incident:

1. Agent makes the local commit
2. Agent sees CI / CodeRabbit issues
3. Agent reports "ready to merge, just need your push approval" or "blocked on force-push approval"
4. User replies "do it directly, don't ask me, just finish the work" — but by then the session is closed and the next agent has to redo the whole investigation
5. From the user's perspective: the prior agent did 80% of the work, reported completion, and left the PR stranded. The next agent wastes another iteration cycle re-discovering the same state.

**The fix is: never report "ready" as the final state. Either hand the PR off to the auto-merge (verified all 7 green criteria), or report a specific blocker with the exact one-line command the user must run.**

## The full sequence (execute in order, no pauses)

### Step 0 — Load related skills FIRST

Before touching anything, load these in parallel:

- `always-pr-never-local-edit` — to verify you're not editing in the main worktree
- `github-pr-workflow` — for the pr-workflow helpers

If you find yourself mid-task and realize you forgot to load these, stop and load them. The skill library is pre-loaded context; not loading it is the bug, not the skill's fault.

### Step 1 — Locate and read the PR

```bash
gh pr view <N> --repo <owner>/<repo> --json headRefOid,headRefName,reviewDecision,mergeStateStatus,statusCheckRollup
gh pr diff <N> --repo <owner>/<repo> --name-only
```

Record the `headRefOid` (the SHA you'll need for the worktree).

### Step 2 — Diagnose every red signal

Read each signal in this order; do not propose fixes before diagnosis is complete:

1. **CI failures** — fetch the failing run, read the actual error log. Do not guess from the check name.
2. **Stale base** — `git fetch origin main && git log --oneline origin/main..HEAD`. If the PR is many commits behind `origin/main` and any check uses `git diff origin/main...HEAD` (merge-base form), the "failure" is in unrelated files on main. Rebase, do not patch.
3. **CodeRabbit / Cursor Bugbot / chatgpt-codex reviews** — read each as a numbered list of concrete issues. Mark each resolved / unresolved / escalated.
4. **Human review comments** — same; address or escalate.
5. **Review state** — `reviewDecision: ""` is good; `CHANGES_REQUESTED` is blocking; `APPROVED` is good.

### Step 3 — Worktree at the explicit PR head SHA (not the ref)

For an existing PR repair (already-open branch), the worktree must check out the PR's existing branch — creating a new `fix/<purpose>` local branch would put the fixes on the wrong ref, so Step 6's `git push <branch>:<remote-branch>` would push stale content or fail:

```bash
PR_SHA=$(gh pr view <N> --repo <owner>/<repo> --json headRefOid -q .headRefOid)
git fetch origin <branch> --force
git worktree add ../worktree_<purpose> "$PR_SHA"
cd ../worktree_<purpose>
git switch <branch>          # attach the worktree to the existing PR branch so Step 6's push refspec lines up
git rev-parse HEAD           # MUST equal $PR_SHA
```

If HEAD != PR_SHA, the worktree is stale. Destroy and recreate, do not amend.

### Step 4 — Make the fixes

Address every concrete CodeRabbit / PR review issue. For each fix:

- Show the root cause in the commit body, not just "fix review"
- Prefer root-cause fixes over symptom patches (e.g. "composite action can't read secrets" → declare `gcp_sa_key` input; do not just hardcode a different env var)
- If a fix is non-trivial or requires a judgment call (architectural change, schema change, behavior change), STOP and ask Jeffrey. Do not guess.

### Step 5 — Validate locally before pushing

- Python yaml.safe_load all .yml/.yaml files
- actionlint the composite action
- Re-read the diff: `git diff origin/main..HEAD --stat` — should show exactly the intended files

### Step 6 — Force-push (use Form A: bare lease) and audit

The global push-safety rule requires explicit in-thread human approval for force-pushes. **The approval requirement is satisfied when Jeffrey said any of**:

- "/green this PR"
- "actually fix ... and then merge"
- "do it directly if its easy otherwise spawn AO worker"
- "next time don't ask me, just finish the work"

These all authorize the full sequence including any required force-push. Do not re-ask.

```bash
OLD_SHA=$(git rev-parse origin/<branch> 2>/dev/null)
git push --force-with-lease origin <branch>:<remote-branch>
NEW_SHA=$(git rev-parse origin/<branch>)
echo "Force-push: $OLD_SHA -> $NEW_SHA"
echo "Reason: <amend-a-PR | address-coderabbit | rebase-onto-current-main | ...>"
```

Always use Form A (bare lease), never Form B (`=<ref>:<sha>`). Form B is too strict and rejects clean amends with misleading "behind its remote counterpart" errors.

### Step 7 — Watch CI to green

```bash
for i in {1..10}; do
  sleep 30
  STATUS=$(gh pr view <N> --repo <owner>/<repo> --json statusCheckRollup \
    -q '[.statusCheckRollup[] | select(.state != null or .conclusion != null) | "\(.name)=\(.conclusion // .state)"]' | tr '\n' ' ')
  echo "[$i] $STATUS"
  if echo "$STATUS" | grep -qE "FAILURE"; then break; fi
done
```

`detect-changes`, `import-validation`, `Directory tests`, `Green Gate`, `Merge commit validation` are the critical ones. `SKIPPED` is fine (means the change didn't trigger that matrix). `NEUTRAL` (Cursor Bugbot) is fine.

### Step 7b — Clear GraphQL gate 5 (unresolved bot threads) [NEW 2026-06-14]

**Green Gate gate 5 reads GraphQL `isResolved` on review threads, not REST comment count.** `gh pr comment` (REST) does **not** flip `isResolved`. CodeRabbit threads auto-resolve on CR's own confirm-fix reply (it carries the resolved marker), but `chatgpt-codex-connector[bot]` and other non-CR bot threads do **not** auto-resolve — gate 5 stays FAIL until a GraphQL `resolveReviewThread` mutation is called per thread.

**After a fix push, if Green Gate still reports `N unresolved`:**

```bash
# Sourceable helper — handles the entire gate-5-resolution loop
bash ~/.smartclaw/lib/resolve_review_threads.sh <PR_NUMBER>
# Or sourceable:
#   source ~/.smartclaw/lib/resolve_review_threads.sh
#   resolve_review_threads <PR_NUMBER>

# Re-trigger Green Gate after resolution
gh workflow run green-gate.yml --repo <owner>/<repo> --ref <branch> \
  -f pr_number=<N> -f head_sha=<NEW_SHA>
```

**Filter logic** (matches Green Gate gate 5): non-PR-author comments, non-`nit:`/`nitpick` bodies, `isResolved == false`. When `LATEST_CR == APPROVED`, gate 5 is non-blocking even with unresolved threads.

**Anti-pattern (BANNED)**: pushing a fix → replying to all threads via `gh pr comment` → declaring "ready" → leaving the PR blocked on gate 5. The user will discover this on the next skeptic-cron run and force a 2nd iteration. Always run `resolve_review_threads.sh` after a substantive fix-up.

**Reference**: `feedback_2026-06-14_green_gate_gate5_resolveReviewThread` (provenance: PR #621, 3 codex-connector threads required manual GraphQL resolution).

### Step 8 — Clear review state

If CodeRabbit left a `CHANGES_REQUESTED` review but then confirmed "all clear" in a follow-up reply, the prior review state lingers. Post `@coderabbitai all good?` to trigger a fresh re-review, or wait for the bot to auto-resolve on the next push. The PR is mergeable once `reviewDecision` is `""` or `APPROVED`.

### Step 9 — Hand off to auto-merge (do not run `gh pr merge`)

When Jeffrey said any of:
- "do it directly if its easy"
- "actually fix ... and then merge"
- "/green ... and then merge"
- "next time don't ask me, just finish the work"

…then the **green-up authorization** is given. The **merge itself is performed by `skeptic-cron.yml`** every 30 minutes once the 7-point green criteria are all satisfied. `CLAUDE.md` and `AGENTS.md` explicitly forbid LLM agents from running `gh pr merge` directly — running it bypasses the orchestrator / evidence / skeptic merge path and can leave agents following contradictory instructions.

What the agent does in this step:

```bash
# Verify all 7 green criteria are satisfied (the PR is now mergeable)
gh pr view <N> --repo <owner>/<repo> --json headRefOid,mergeable,reviewDecision,mergeStateStatus
# Re-run the full /green check before declaring done
gh pr checks <N> --repo <owner>/<repo>
```

If criteria 1–5 are green and the review is `APPROVED` or empty, the PR is ready; `skeptic-cron.yml` will pick it up on its next run and merge. **Do not ask "want me to merge?" — that IS the stop-halfway violation.** If the user gave the green-up-and-merge instruction, the green-up half is the agent's job; the merge half is the cron's job. The agent's final reply (Step 10) confirms the PR is ready, not that the agent performed the merge.

### Step 10 — Final status reply

Single reply with:
- PR URL
- Confirmation that the PR is ready and `skeptic-cron.yml` will merge it on its next run (do not claim a merge SHA — the cron produces it)
- One-line "what shipped" summary
- List of issues that were addressed (CodeRabbit + CI)
- Confirmation that CI is green and review is cleared
- No "want me to..." follow-up question — the work is done

## When to STOP and ask Jeffrey

Stop and surface the blocker (do NOT proceed with a guess) when:

- A CodeRabbit issue requires an architectural change (e.g. "this should be a new module, not a method on X")
- A CI failure is in an unrelated part of the codebase and the fix would be a behavior change beyond PR scope
- The merge target branch is `main` and the PR was not opened by an authorized human (per repo rules)
- A force-push is needed on a branch you do not own (i.e. someone else opened the PR)
- The required review comes from a real human (not a bot) and their comment is a question, not a fix request

## When to dispatch an AO worker instead of self-executing

Jeffrey's rule: "Do it directly if its easy, otherwise spawn AO worker."

Self-execute when:
- The PR is already known and located
- The fixes are mechanical (rename, add input, add const, add `ref:` to checkout, swap sed for bash -c)
- The PR is small (<10 files) and the diff is already understood

Dispatch AO when:
- The PR scope is unclear (multiple features bundled)
- The fix requires a controlled repro for a CI failure
- The worktree creation + rebase would consume more than 5 minutes of inline time
- Jeffrey explicitly says "spawn AO worker"

When dispatching, the task prompt MUST include:
- "Drive to green. Do not stop at 'ready for review'. Self-merge is authorized."
- The PR URL
- The force-push authorization phrasing (verbatim)
- The full CodeRabbit issue list (so the worker doesn't have to re-fetch)
- The expected number of fixes (e.g. "6 blocking issues")

## Anti-patterns (do not do these)

- **"Local commit + ask 'want me to push?'"** — Jeffrey's verbatim complaint on 2026-06-10 PR #7437. The minimum unit of done-ness is the open PR with URL, not a local commit and a question.
- **"Report 'ready to merge, need your push approval'"** — same violation. The push approval is implied by "/green this PR" or "do it directly".
- **"Report CodeRabbit issues but don't fix them"** — when given the green-up-and-merge instruction, you own the fixes.
- **"Wait 5 min between push and CI check"** — CI is usually <2 min for this repo; poll in 30s loops and break on first signal change.
- **"Re-ask for force-push approval when authorization was already given"** — see Step 6 trigger list.

## Slack narration threading (anti-misroute rule)

When you post ANY Slack message as part of this skill's workflow (PR-status updates, "Bring-to-green status", "CI queue status update", "blocker", "phase complete", "final interim summary", "Worker spawned", etc.), the post MUST pass `thread_ts` equal to the **dispatch root ts** — the first message the agent posted in this flow (or the parent thread of the user message that triggered the flow, if responding to a request).

**If you cannot determine the dispatch root ts, DO NOT post a status update at all.** Log to stderr only. "I don't know the dispatch root" is not a license to post to channel root.

**What this looks like in practice:**

```python
# When calling conversations_add_message, ALWAYS pass thread_ts
mcp__slack__conversations_add_message(
    channel_id="C0AH3RY3DK6",  # the channel the dispatch root lives in
    text=":clipboard: PR #N status: ...",
    thread_ts="1781394331.504119"  # the dispatch root ts
)
```

**How to discover the dispatch root:**

1. **You created it** — you have the `ts` from the `conversations_add_message` response. Persist it in your working state.
2. **Responding to a user request** — the user's message has a `ts`; use that.
3. **An AO worker spawned you** — the spawn command output includes the dispatch root; capture it.
4. **You genuinely don't know** — STOP. Do not post. Ask for the dispatch root in the same channel where the work was originally requested (still thread_ts=parent's ts).

**Detection of self-violation:** before submitting a `conversations_add_message` call, check: "Does this call have a `thread_ts` argument?" If no, and you're posting any text containing the PR number + a status-y word (`status`, `update`, `phase`, `interim`, `pushed`, `CI`, `blocker`, `spawn`, `done`, `merged`), the call is wrong — STOP and find the dispatch root.

**Why this rule exists:** 2026-06-13 PR #7524 incident — drive-pr-to-green agent posted 4 of 6 status narrations to channel root instead of threading. Same bug reproduced in #agentf for ao-6363 (5+ root posts). User's complaint at C0AJ3SD5C79/p1781394553470139: "Why are replies still going out of thread?" This is a **behavioral fix**, not a code fix — the Slack MCP already supports `thread_ts`; the LLM must actively pass it on every narration call.

**Reference:** `~/.claude/projects/-Users-jleechan--hermes/memory/feedback_2026-06-14_llm_narration_unthreaded.md`.

## Pitfall — what "green" actually means

Jeffrey's bar (per 2026-06-12 conversation): **"bring all tasks to at least CI green PR, but maybe green gate and no skeptic is ok like 6 /green"**

Translation:
- **Minimum**: CI green + PR mergeable
- **Acceptable short-cut**: Green Gate green + no Skeptic Gate (i.e. no human skeptic review required) — this is the "/green" definition that came in around the 6th green-up cycle
- **Not acceptable**: "local changes ready" with no PR, or PR open with red CI, or PR open with CHANGES_REQUESTED review

For trigger-style PRs (workflow files, CI changes) the bar is the same. For `mvp_site/` production code changes, AGENTS.md requires `/es` evidence — that's a separate gate, not part of "green" for this skill.

## Worked example — 2026-06-12 PR #7484 (this skill's origin case)

1. **Trigger**: Jeffrey: "lets /green the trigger PR and actually fix PR comments and coderabbit issues directly and then merge. Do it directly if its easy otherwise spawn AO worker."
2. **First pass** (AO worker): located PR #7484, identified stale-base root cause, fixed all 6 blocking CodeRabbit issues, rebased onto origin/main. Local commit `12f0d5d3ec` ready. Hit max-iteration before force-push.
3. **Second pass** (gateway session, this skill loaded): force-push with Form A lease (`8865d97 → 12f0d5d`), watched CI to green, posted `@coderabbitai all good?`, confirmed reviewDecision cleared, verified all 7 green criteria; `skeptic-cron.yml` then performed the squash-merge and `delete-branch` on its next run. Merge commit `c963a0ff`.
4. **Final reply**: PR URL + 1-line "what shipped" + list of issues addressed + "ready for auto-merge". No follow-up question.

Total: 2 iterations instead of 4+. That is what "don't stop halfway" looks like in practice.
