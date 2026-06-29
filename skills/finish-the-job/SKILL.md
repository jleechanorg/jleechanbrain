---
name: finish-the-job
version: 1.0.0
description: "End-to-end finish protocol for any Slack thread, CLI invocation, or cron task where the user has handed off a goal. Routes to /fs (spec gen) → /f (Dark Factory loop) → drives to a verifiable conclusion (green PR with non-unit-test evidence, finished code change, or dry-run to local machine state). Never stops halfway. Loads automatically when the SOUL.md `finish-the-job` commit fires."
tags: [autonomy, finish, dark-factory, dispatch, pr, evidence, anti-stop-halfway]
category: workflow
triggers:
  - finish the job
  - finish it
  - finish this
  - finish that
  - drive to conclusion
  - see this through
  - take it all the way
  - don't stop halfway
  - why did you stop
  - hands off mode
  - hands-off mode
  - fullsend
  - full send
  - take it from here
  - i started but didn't finish
  - work started but didn't finish
  - stalled thread
  - threads that stalled
  - threads i started but didn't finish
  - skillify hermes to be hands off
  - make hermes hands off
  - /finish
  - /auto
  - auto
  - automate this
  - do it autonomously
  - your call
  - handle it
  - ship it
  - merge it
related_skills:
  - dark-factory
  - drive-pr-to-green
  - always-pr-never-local-edit
  - ao-babysit
  - dropped-messages
  - skillify
  - hermes-deploy-pipeline
---

# finish-the-job

**The hands-off finish protocol.** When a user hands you a goal — in Slack, in a CLI turn, or via a cron task that wasn't finished — this skill is the *single* pipeline that drives it to a verifiable conclusion. It composes existing primitives (`/fs`, `/f`, `workflow/drive-pr-to-green`, `workflow/always-pr-never-local-edit`) so the assistant stops halfway **never**.

## Why this skill exists

Three drift patterns were observed in the user's last week of Slack threads (2026-06-12 to 2026-06-19, C0AH3RY3DK6 / ${SLACK_CHANNEL_ID}):

1. **"Ack + design prose + silence"** — agent acknowledges, writes 200 lines of design options, asks one more clarifying question, never executes. The dropped-thread-followup cron fires 4h later.
2. **"Started + fork + multi-option question"** — agent reads files, makes a local commit, hits a judgment call, posts a 3-option menu. User doesn't reply (busy). Thread goes cold.
3. **"Investigation without end-state"** — agent reads 6 files, posts "Here's what I found: …" with no PR, no commit, no dry-run. The "I'm waiting for the right moment to ship" trap.

**The pattern in all three:** the agent stopped at a place that required *the user* to make a decision or supply a follow-up, instead of making the call itself and posting the result. The user's explicit rule (2026-06-19): *"I am ok with outcomes that aren't my goal as long as they are correct ie. Green PR, real evidence, like correct but misinterpret is fine but stopping halfway is not."*

## Contract

**When this skill fires, the work is not done until ONE of these end-states is provably true:**

| End-state | Proof artifact |
|---|---|
| **Green PR merged** | `gh pr view <N> --json state` = `MERGED` + Green Gate workflow log gate-by-gate PASS + non-unit-test evidence bundle URL |
| **PR open with green CI awaiting user merge** | `gh pr view <N> --json mergeStateStatus,reviewDecision` shows `MERGEABLE` + review clean; ONE-LINE message naming PR URL + the one gate the user must clear |
| **Local state change verified** | `git diff` + `git log --oneline -3` + the actual test run output captured in the final reply (not described — shown) |
| **Dry-run to local machine** | The exact commands the user would run, executed against a fresh worktree, output captured; the user can paste the same commands and get the same result |

**NOT acceptable end-states:**

- ❌ "Here's the design, want me to ship it?" — that's design-proposal-and-silence
- ❌ "Tests pass locally, PR is ready, want me to push?" — that's local-commit-and-ask
- ❌ "Investigation complete, here are the findings" without a commit, PR, or dry-run
- ❌ "I've started the worker, will update when done" — that's ack-and-walk-away
- ❌ Mid-stream question without first exhausting the LLM's own judgment (per the user's rule: "in the middle I want AI to use its best judgement")

## Phases (execute in order, no pauses between)

### Phase 0 — Classify the goal (one decision, ≤30 seconds)

Classify the user's goal into ONE of:

| Goal shape | Examples | Routing |
|---|---|---|
| **PR fix** | "fix the CI on PR #N", "/green this PR", "address CodeRabbit on PR #N" | `workflow/drive-pr-to-green` |
| **New code / new feature** | "add X to the repo", "implement Y", "build a Z" | `/fs` then `/f` (feature-mode) |
| **New PR for existing work** | "open a PR for my branch", "ship my changes", "merge my draft" | `workflow/always-pr-never-local-edit` |
| **Investigation / read-only** | "find out which key leaked", "what does X do", "review my plan" | Inline research → answer with **proof artifact** (file:line + quoted text + reproducible command) |
| **Ops / config / infra** | "rotate the key", "bump the Cloud Run memory", "fix the daily cron" | Inline gcloud/kubectl/etc. with output captured; if a code PR is also needed, file as follow-up |
| **Meta / about-Hermes** | "skillify X", "make this a skill", "improve Y workflow" | `skillify` skill |

**If the classification is ambiguous after 30 seconds, ASK ONE QUESTION** (the only question in this whole pipeline). The user is willing to invest up-front in Q&A specifically to avoid mid-stream steering. Use `clarify`.

### Phase 1 — `/fs` first if the goal is non-trivial

**Trigger `/fs` if ANY of these are true:**

- Goal is a new feature or non-trivial refactor (not a 1-line fix)
- Goal mentions multiple components, files, or repos
- Goal has ambiguous wording that the agent could misinterpret in 2+ ways
- Goal is a design task the user wants reviewed

`/fs` produces `spec.md` + `attractor_spec.md`, both codex-cold-reviewed, before any code is written. The user's up-front Q&A investment pays off here — by the time the worker starts, the spec is unambiguous.

**Skip `/fs` if:**

- Goal is a PR fix on an existing branch (the PR diff IS the spec)
- Goal is <50 lines of mechanical change
- Goal is investigation / read-only (no code to spec)

### Phase 2 — Dispatch (do not self-execute multi-step code work)

For PR fixes: load `workflow/drive-pr-to-green` and follow its full sequence (worktree at explicit SHA → fix → push → watch CI → clear review → self-merge when authorized).

For new features: dispatch via `dispatch-task` skill (`ao spawn`) so the worker gets its own tool-call budget. Inline gateway sessions cap at ~25 tool calls; AO workers have their own budget.

For new PR from local branch: `workflow/always-pr-never-local-edit` → fresh worktree from `origin/main` → port the local diff if needed → push → `gh pr create`.

For ops/investigation: execute inline (gcloud, curl, file reads). The "inline-able" boundary is one tool call OR a tight sequence with no fork.

### Phase 3 — Drive to conclusion

The dispatched worker OR inline execution runs until one of the end-states in the Contract is provably true. If the worker hits a fork mid-stream:

1. Apply the user's rule: make the call yourself, surface it in the final reply ("I picked X over Y because Z; if you wanted Y, here's the one-line revert").
2. **Never post a multi-option question to the user mid-stream.** The exception is Phase 0 — that's up-front Q&A, which is allowed.
3. If the fork is *truly* unrecoverable without user input (e.g. force-push authorization, secrets the agent can't see, env-specific config only the user has), halt with the ONE-LINE BLOCKER shape: "PR #N is at <state>; one blocker: <one command the user runs>."

### Phase 4 — Final reply shape (mandatory)

Every completion reply MUST contain:

1. **End-state declaration** — "✅ Done: <green PR #N merged> | <PR #N open + green, awaiting your review> | <local state X verified>"
2. **Proof artifact** — PR URL, `gh pr view` JSON, or `git log` + `git diff --stat` output, or the actual command output captured
3. **What was decided mid-stream** (if anything) — every judgment call the agent made instead of asking, with one-line rationale
4. **No follow-up question** — "want me to X?" is the violation. The work is done; the user reviews.

## Anti-patterns (do not do)

- ❌ **"I started the worker, will update when done"** — the agent has 25 calls; the worker has its own budget. The reply IS the worker. If you have to wait, write the cron babysit reference (see `babysit-openclaw` skill) and post a status link.
- ❌ **"Here's a design with 3 options, which would you like?"** — that's Phase 0 question-count inflation. ONE option (your best judgment) + the path forward. The user's rule: "correct but misinterpret is fine."
- ❌ **"Local commit + ask 'want me to push?'"** — `always-pr-never-local-edit` is in the same skill family; do not violate it.
- ❌ **"Tests pass locally, opening PR now"** (then going silent) — the PR URL goes in the final reply, not in a follow-up.
- ❌ **"Investigation complete, here are 6 findings"** — every finding needs a "what to do about it" line, and at least one finding must be acted on.
- ❌ **Stopping at "I asked AO to spawn a worker"** — that's an ack. The work isn't done until the worker reports OR the cron takes over.

## Loader / auto-fire contract

This skill is registered in `~/.smartclaw_prod/skills/RESOLVER.md` and the `## COMMIT: finish-the-job` block in `SOUL.md` makes it load automatically for any user message that contains a goal phrase ("can you X", "please Y", "make Z", "investigate A", "fix B"). The trigger phrases are listed in the YAML frontmatter at the top of this file.

**When auto-fired:** Phase 0 runs first. If classification returns PR-fix / new-code / new-PR, the skill proceeds autonomously. If classification returns investigation / ops, the skill executes inline and posts the final reply with proof.

**When explicitly invoked (`/finish <goal>`):** Same as auto-fire, but the user has signaled they want this pipeline regardless of the goal shape.

## Deploy sync awareness (read this before rolling out a finish-the-job artifact)

**`scripts/deploy.sh` Stage 4.5 only syncs `POLICY_FILES=(CLAUDE.md SOUL.md TOOLS.md HEARTBEAT.md)`.** It does NOT sync `skills/` or `skills/RESOLVER.md`. A skillify pass that creates `~/.smartclaw_prod/skills/<name>/` works locally, but:

1. If you only wrote to prod, the staging git checkout at `~/.smartclaw/skills/<name>/` is empty — a future `git pull --ff-only` won't reintroduce it.
2. If you wrote to staging only, the prod resolver won't see the skill — `~/.smartclaw_prod/skills/RESOLVER.md` won't have the trigger entry.
3. If you wrote both, you still need a manual `cp ~/.smartclaw/SOUL.md ~/.smartclaw_prod/SOUL.md` (the symlink at `~/.smartclaw/SOUL.md` → `~/.smartclaw/workspace/SOUL.md` lands in the staging tree; deploy copies it to prod) — UNLESS you run `deploy.sh` end-to-end and accept the canary + restart.

**The skillify anti-pattern guard (run in the same turn as any rollout claim):**

```bash
echo "1. SKILL.md:           $(test -f ~/.smartclaw_prod/skills/<name>/SKILL.md && echo PRESENT || echo MISSING)"
echo "2. tests pass:         $(cd ~/.smartclaw_prod/skills/<name>/tests && python3 -m pytest -q 2>&1 | tail -1)"
echo "3. cron executable:    $(test -x ~/.smartclaw/scripts/<script>.sh && echo YES || echo NO)"
echo "4. plist template:     $(plutil -lint ~/.smartclaw/launchd/<label>.plist.template 2>&1 | tail -1)"
echo "5. RESOLVER entry:     $(grep -c '^## <name>$' ~/.smartclaw_prod/skills/RESOLVER.md) match"
echo "6. resolver triggers:  $(grep -c '<user-phrase>' ~/.smartclaw_prod/skills/RESOLVER.md) match"
echo "7. SOUL.md staging:    $(grep -c '^## COMMIT: <name>$' ~/.smartclaw/SOUL.md)/1"
echo "8. SOUL.md prod:       $(grep -c '^## COMMIT: <name>$' ~/.smartclaw_prod/SOUL.md)/1"
echo "9. SOUL.md in sync:    $(diff -q ~/.smartclaw/SOUL.md ~/.smartclaw_prod/SOUL.md >/dev/null && echo YES || echo DRIFT)"
```

**Test portability (CodeRabbit MAJOR, 2026-06-19):** the test file `tests/test_finish_the_job_contract.py` uses `HERMES_PROD_SKILLS` (env var, defaults to `$HERMES_HOME/skills`) instead of a hardcoded `${HOME}/...` path. Run the tests with:

```bash
# Default (Hermes dev machine: ${HOME}/.smartclaw_prod/skills)
cd ~/.smartclaw/skills/finish-the-job/tests && python3 -m pytest -q

# Other developer checkout
HERMES_HOME=~/my-hermes HERMES_PROD_SKILLS=~/my-hermes/skills/finish-the-job python3 -m pytest -q
```

If items 1-7 land in the same turn as the rollout and 8-9 land within the next deploy cycle, the work is done. Anything outside that pattern is a half-finished rollout — apply the same anti-pattern audit you'd apply to a PR.

## Related skills — load order when this fires

1. `dark-factory` (always — for the `/f` and `/fs` definitions)
2. `drive-pr-to-green` (only if goal shape is PR-fix)
3. `always-pr-never-local-edit` (only if goal shape is new-PR or local-changes-exist)
4. `dispatch-task` (only if Phase 2 decides to dispatch via `ao spawn`)
5. `dropped-messages` (only if the goal was itself a dropped-thread recovery — meta-finish)

## Worked example — the 2026-06-19 incident

User said: *"Look at the last week of slack threads with work that started but didn't finish. … Is there some way we can /skillify Hermes to be more hands off? I want it to fully drive everything to a conclusion like a final /green PR … correct but misinterpret is fine but stopping halfway is not."*

Phase 0 classified: meta / about-Hermes (`skillify` skill).

Phase 1: `/fs` was unnecessary — the request itself is a skillify task, not a feature implementation.

Phase 2: Inline execution (single-session skillify pass). No dispatch needed.

Phase 3: Built the skill, ran the 10-item checklist, deployed, verified all artifacts in the same turn.

Phase 4: Final reply with the 10-item re-audit (counts of files, line numbers, deploy SHA) — no follow-up question. The user's rule is satisfied: the work landed, the skill is reachable from the resolver, the SOUL.md commit fires it automatically on the next goal-shaped message.
