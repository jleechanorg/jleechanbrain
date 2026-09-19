---
description: /fullrun — end-to-end autonomous run. Compose finish-the-job + drive-pr-to-green + dispatch-task + ao-babysit. Terminal-only cadence. No mid-stream questions. One final reply with full evidence stack.
type: orchestration
execution_mode: immediate
---

# /fullrun — End-to-End Autonomous Run

**The longest-form hands-off mode.** For multi-worker / multi-PR / backlog drives where you want ONE consolidated final reply and minimal Slack noise. Differs from `/finish` and `/auto` by skipping the Phase-0 clarifying question (when goal is unambiguous) and by forcing terminal-only babysit cadence.

## Usage

```
/fullrun <goal>
/fullrun drive PRs #N #M #P to green with /es and /er
/fullrun handle the cold-start PR backlog end-to-end
```

## When invoked

1. **Load the skill:** `~/.smartclaw/skills/finish-the-job/SKILL.md` (plus `drive-pr-to-green` if goal is PR-fix; plus `dispatch-task` if multi-worker; plus `ao-babysit` if any worker is dispatched).
2. **Skip Phase-0 clarifying question** when the goal contains concrete PR numbers, file paths, or a clear backlog reference. (Only ask if the goal is genuinely ambiguous.)
3. **Set babysit cadence to `terminal-only`** for every worker dispatched in this run — no 5-min spam, post only on terminal-state change (idle-at-prompt / PR-opened / worker-dead / 2× stuck-without-progress).
4. **Pre-flight brief template** — every `ao spawn` from a `/fullrun` MUST write the brief to `/tmp/<project>-<phenotype>/ao-task-brief.md` FIRST, then spawn with `--task` containing the brief inline. (See `dispatch-task` § "Brief before spawn — left-shift composition".)
5. **Drive to ONE of the four provable end-states** per `finish-the-job` contract (agent NEVER runs `gh pr merge` — merge is the user's call, executed by `skeptic-cron.yml` after `MERGE APPROVED`):
   - Green PR open awaiting user merge
   - Local state change verified
   - Dry-run to local machine state
   - Investigation with proof artifact (file:line + quoted text + reproducible command)
6. **Final reply** MUST contain the full evidence stack (see `## COMMIT: a-fullrun-evidence-stack` in SOUL.md):
   - PR URL(s) as markdown hyperlinks (NEVER bare `#N`)
   - `/er` evidence verdict or link
   - `/skeptic` verdict (worldarchitect.ai PRs)
   - Captioned screenshot/gif of the user-facing surface (UI changes only)
   - List of remaining human-only steps
   - One-line note on every mid-stream judgment call made
   - **No follow-up question** — the work is done; the user reviews.

## Brief template (compressed — full version in `dispatch-task` SKILL.md)

```markdown
# <Phenotype> — <one-line goal>

## Scope
- What to build / fix / investigate (verbatim user text preserved)
- Files expected to change: <list>
- Out of scope: <list>

## Branch
- Name: <clean kebab-case, ≤64 chars> — pre-reset BEFORE worker commits
- Base: origin/main (default) or specific base ref

## Evidence bar
- For PR fixes: Green Gate gates 1-6 + /skeptic = mergeable
- For new code: /es (real server + real LLM roundtrip + Playwright headless)
- For prompt-only: scope-controlled (mvp_site/prompts/*.md requires /es)
- Visual proof required: yes/no

## Stop conditions
- Worker hits Claude Max weekly quota → kill, switch to --agent codex or --agent minimax
- Worker scope-drifts → steer with v2 brief to same session (do NOT spawn fresh)
- Worker pushes to wrong branch → undo, re-push with correct refspec

## Report-back shape
- Final reply MUST include: branch name, head SHA, PR URL, /er verdict,
  /skeptic verdict (if worldarchitect), visual proof (if UI)
```

## Equivalent phrases that auto-fire this command

- "drive everything with /a fullrun"
- "fullsend"
- "drive to merge", "drive to green", "drive to 7-green"
- "all things must be driven with /a and fullrun"
- "don't stop until PRs are green"

## What you must NOT do

- ❌ Ask a mid-stream clarifying question — make the call yourself
- ❌ Post babysit updates every 5 min — use terminal-only cadence
- ❌ Spawn a worker without writing the brief first
- ❌ Stop at "report pushed" / "PR opened" — drive to one of the four end-states
- ❌ Post "want me to X?" follow-up — the work is done; user reviews

## Related

- `/auto` — slash command alias (alias for `/finish` per skills/RESOLVER.md)
- `/finish` — same contract, different cadence defaults (Phase-0 question allowed)
- `/roadmap Step 8.5` — `/roadmap` invokes `/a fullrun` internally for § B / § E items
- `~/.smartclaw/skills/finish-the-job/SKILL.md` — the substrate contract
- `~/.smartclaw/skills/ao-babysit/references/cadence-modes-2026-06-27.md` — terminal-only cadence spec