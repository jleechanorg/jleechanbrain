---
name: parallel-investigate-and-dispatch
version: 1.0.0
description: "Investigate X and fix Y in parallel — same turn."
author: hermes
license: MIT
tags: ["autonomy", "parallel", "dispatch", "harness", "git-archaeology", "root-cause"]
category: workflow
triggers:
  - in parallel fix
  - in parallel
  - while you investigate
  - while you look
  - investigate and fix
  - investigate and dispatch
  - find out when this started and fix it
  - harness and fix in parallel
  - /harness and fix
related_skills:
  - finish-the-job
  - always-pr-never-local-edit
  - drive-pr-to-green
  - systematic-debugging
changelog:
  - '1.0.0 (2026-08-16): Initial. Verified on jleechanorg/worldarchitect.ai avatar-crop pixelation (Slack ${SLACK_CHANNEL_ID}/1786862462.371799). User: "Run /harness <when did this start> AND in parallel fix it." Investigation found bug origin in commit 1d5c748322 (5.5 months old), dispatch landed in same turn via claudem worker on fix/avatar-crop-resolution-8956 branch.'
---

# parallel-investigate-and-dispatch

## When to Use

Use this skill when the user asks for **both an investigation answer AND a fix in the same breath** — and explicitly says "in parallel" or implies it. Concrete trigger phrases:

- "Run /harness <question> and in parallel fix it"
- "Investigate X and dispatch the fix"
- "While you look into this, also ship Y"
- "Find out when this started AND fix it"

If the user says "investigate first, then we'll decide on the fix" — that's sequential, not parallel, and `finish-the-job` covers it. This skill only fires for explicit parallel asks.

**When the user asks for both an investigation answer AND a fix in the same breath, both must ship in the SAME turn.** This is a pattern `finish-the-job` doesn't address because finish-the-job's phases are sequential (Classify → Spec → Dispatch → Drive). The user's pattern is: deliver the harness answer NOW, dispatch the fix NOW, do not wait for the worker to report before answering the question.

## Contract

When this skill fires:

1. **Investigation answer** lands in the user's reply in the SAME turn as the dispatch call — no "let me find out first, then I'll fix it."
2. **Worker dispatch** lands in the SAME turn — `bash -lic 'claudem -p ...'` or `ao spawn ...` invoked, not deferred.
3. **Final reply shape** combines both: harness answer (with file:line + commit SHA + reproduction recipe) + dispatch confirmation (worker ID / PID, branch name, expected ETA for the PR URL).
4. The follow-up Slack message is the PR URL once the worker reports — this is a SECOND reply, not a continuation of the first.

## Anti-patterns

- ❌ **"Let me investigate first, then I'll dispatch."** Sequential. The user explicitly said parallel.
- ❌ **"Investigation complete, want me to dispatch now?"** That's a multi-option menu. The user already authorized both — execute.
- ❌ **Post the harness answer as a thread reply and the dispatch in the next turn.** Same-turn = both visible at once. If Slack mobile is involved, the user needs to see both without scrolling (per user profile: "Slack mobile doesn't load threaded replies by default").
- ❌ **Dispatching more than 3 subagents simultaneously without checking the limit.** (added 2026-08-17) `delegation.max_concurrent_children` is set to 3 by default in `config.yaml`. The 4th delegate_task call does NOT parallelize — it runs synchronously inline (the user gets the result in the same turn but loses the parallelism benefit). Observed on kevin feedback review 2026-08-17: dispatched 3 parallel subagents + a 4th for the largest campaigns; the 4th ran sync at 283s while the others finished in ~350s. Either batch into 3 calls (use the `tasks` array form) or accept the sync penalty. Check the config first if expecting >3.

## Recipe

### Step 1 — Investigation (inline, fast)

For "when did this bug start?" / "is this a regression?" questions, run `git log` archaeology FIRST in parallel with whatever else. Pattern that works in <5 tool calls:

```bash
# (a) Find the file's first commit on the relevant branch (usually origin/main)
git log --reverse --diff-filter=A --oneline -- <file> | head -1
git log --reverse --oneline -- <file> | head -1  # when file existed before diff-filter tracking

# (b) When the bug is a specific code pattern (e.g. `canvas.width = zoneSize`),
#     use `git log -G` to find when that pattern first appeared:
git log --reverse --oneline -G '<exact pattern from grep>' -- <file>
# → tells you the FIRST commit that introduced the bad line.
# Add -p if you need the surrounding diff context for the commit message.

# (c) Verify it's not a regression by listing commits that touched the file since:
git log --all --oneline -- <file> | head -20
# Cross-reference with grep --grep='<feature>' for any commits that LOOK relevant.

# (d) Confirm with `git show --stat <commit> -- <file>` to see what other files changed
#     in the same commit. If the bad default was set in a feature commit alongside
#     related scaffolding, that's a "shipped together" finding — not a regression.
```

The investigation produces: **commit SHA + date + author + commit message excerpt + "shipped with X/Y/Z"** — enough to answer "when did this start?" with proof.

### Step 2 — Fix dispatch (in parallel, same turn)

The investigation gives you the diagnosis; the dispatch turns the diagnosis into a fix. Default — `claudem` on a clean worktree:

```bash
# Fresh worktree from origin/main, NOT from any open PR branch
git worktree add -b fix/<topic>-<rev-id> /private/tmp/wt-<topic> origin/main

# Dispatch in background — DO NOT wait synchronously, return a session_id
bash -lic 'cd <worktree-path> && claudem -p "<full task>"' --max-turns 120 &
```

**Critical constraints (carried over from finish-the-job + memory):**

- `--max-turns ≥ 120` (NOT 80 — verified 80 stalls at ~52min before PR creation; full recipe in `claudem-worker-max-turns-takeover`).
- Branch from `origin/main`. Never stack on `feat/...` or `fix/...` branches already associated with open PRs (per `never-push-onto-someone-elses-pr-head`).
- One logical commit. `git log --oneline origin/main..HEAD` must show exactly your one commit before `git push`.
- Include the FULL diagnosis in the worker prompt — bug origin, file:line, fix shape, constraints, verification commands. The worker has no session context.

### Step 3 — Same-turn reply shape

Reply contains:

1. **Harness answer** (from Step 1):
   - "Origin: commit `<SHORT-SHA>` — `<DATE>` (`<N>` days/months ago). Shipped by `<author>`."
   - The commit message excerpt + which other files it touched
   - Cross-reference: "verified not a regression" with the list of intervening commits that DIDN'T touch the bug
2. **Fix dispatch confirmation**:
   - Branch name + worktree path
   - Worker session_id / PID
   - "PR URL incoming in ~25-40 min"
3. **Optional harness-gap note** — "no test/regression catches this; recommend adding `<specific check>` to prevent recurrence" (the user's pattern is "make the harness not the agent repeat the failure").

### Step 4 — Second reply (when worker reports)

When `notify_on_complete` fires (or you poll the background process), post the PR URL as a SECOND Slack message. Do NOT edit or replace the first reply — Slack doesn't merge edits into the conversation history cleanly.

## Worked example (2026-08-16)

User: "Ok let's run /harness when did this bug start. And in parallel fix it."

Investigation in same turn:
- `git log --reverse --diff-filter=A -- mvp_site/frontend_v1/js/avatar-crop.js` → first commit
- `git log --reverse -G 'canvas.width = zoneSize'` → confirms pattern shipped in 1d5c748322 (Mar 3, 2026, 5.5 months ago)
- `git show --stat 1d5c748322` → both JS default `|| 280` AND CSS `.avatar-crop-zone { width: 280px }` shipped together
- `git log --all --oneline --grep avatar | head -25` → 12 commits, none touched canvas resolution

Dispatch in same turn:
- `git worktree add -b fix/avatar-crop-resolution-8956 /private/tmp/wt-avatar-resolution origin/main`
- `bash -lic 'cd /private/tmp/wt-avatar-resolution && claudem -p "<full diagnosis + fix recipe + constraints>"' --max-turns 120 &`

Same-turn reply: harness origin answer + "claudem worker running on fix/avatar-crop-resolution-8956, PR URL in 25-40 min."

## Common pitfalls

- **Don't run the investigation AFTER the dispatch.** You need the diagnosis to write the worker's prompt. Sequence is: investigate → write prompt → dispatch → reply.
- **Don't omit the cross-reference** ("verified not a regression"). Just saying "bug shipped in commit X" is half the answer; the user wants to know "did we recently reduce quality?" → "no, it's been 280 since day 1."
- **Don't wait synchronously** for the worker. The whole point of parallel is the worker runs while you reply. `notify_on_complete` or a single `process(action=poll)` is enough.
- **Branch from origin/main, never from `feat/campaign-wizard-round-engine` or any open PR branch** — same trap as `never-push-onto-someone-elses-pr-head`. `git worktree add -b fix/... origin/main` is the safe form.

## Reference

- `references/git-archaeology-when-did-bug-start.md` — condensed `git log -G` recipe + examples for the most common "when did X start / is this a regression" investigation shape.
