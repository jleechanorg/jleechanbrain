---
description: /write-goal — mine last 30d of coding-CLI history + memory, then write an outcome-driven goal spec wired for evidence, green-CI PRs, and high code quality
type: planning
execution_mode: immediate
---

# /write-goal <topic>

Write a goal spec designed to drive agents to a **verifiable outcome** — solid evidence, green CI PRs, high code quality — grounded in the last 30 days of your coding-CLI history.

## Usage

```
/write-goal <topic>
/write-goal fix the auto-deploy precompute OOM
/write-goal ship the Campaign Wizard step-1 default swap
/write-goal rotate the leaked MiniMax key across all configs
```

## When invoked

1. **Load the skill:** `~/.smartclaw/skills/write-goal/SKILL.md` (Codex copy at `~/.codex/skills/write-goal/SKILL.md`; Claude Code copy at `~/.claude/skills/write-goal/SKILL.md` — all symlinked to the canonical Hermes source).
2. **Execute all 7 phases in order**, no skips:
   - Phase 1: intake the topic + outcome shape
   - Phase 2: `/history <topic> --recent 30 --limit 20` + `/ms <topic> --recent 30 --source beads --limit 5`
   - Phase 2.5: if bug-shaped goal → run `/repro` first to get actual error output
   - Phase 3: pick ONE outcome contract (green-pr-merged | pr-open-green | local-state-verified | dry-run-on-machine) — the four provable end-states from `finish-the-job` + audit-grounded goal shapes (verify-completion, meta-goal, design/evaluate)
   - Phase 4: write `.converge/goal.md` using the skill's template (mandatory fields: Outcome, Proof artifact, Scope, Hard constraints, Evidence required, Green-CI definition, Quality bar, Dispatch routing, Definition of Done, Pitfalls, Prior context, Hand-off)
   - Phase 5: run the 6-gate quality scaffold on your own draft (rewrite until pass)
   - Phase 6: post the goal path + hand-off command (`/h` | `/a <topic>` | `ao spawn` | `gh issue create`)

The skill is grounded in a real 30-day audit of 6,433 Hermes + 18,773 Codex sessions (2026-06-28) — see the "Ground truth" section in SKILL.md for actual pattern counts, verbatim user goals from last month, and 8 design decisions derived from the data.
3. **Final reply MUST contain** (per `finish-the-job` Phase 4):
   - Goal doc path with `file://` absolute path scheme (env-preferences rule)
   - One-line outcome summary
   - Provenance: how many history + memory entries fed the spec, dated
   - Hand-off command (one of the four above)
   - What was decided mid-stream (every judgment call with one-line rationale)
   - **NO follow-up question** — "want me to X?" is a violation

## What makes this different from `/h` or `/a`

| Command | Does |
|---|---|
| `/write-goal <topic>` | Mines history + memory, writes a structured goal spec — does NOT execute the goal |
| `/h <topic>` | Reads `.converge/goal.md` and runs the 4 adversarial gates until 4/4 PASS |
| `/a <topic>` | Hands-off single-task drive to the named end-state |
| `ao spawn --task "$(cat .converge/goal.md)"` | Raw worker dispatch with the spec as its task |

`/write-goal` is the **spec stage**. `/h` and `/a` are the **execution stages**. They consume `.converge/goal.md`.

## Anti-patterns this command closes

- ❌ Inventing acceptance criteria that aren't grounded in actual past sessions on this codebase
- ❌ Activity-shaped outcomes ("improve X", "investigate Y") that produce write-ups instead of merged PRs
- ❌ Unit-only evidence for production changes (env-preferences: Layer 2 integration minimum)
- ❌ `gh pr checks` as the green proof (env-preferences: must read raw Green Gate workflow log gate-by-gate)
- ❌ Goals with no dispatch routing — the agent self-executes a 30-commit PR inline and drops it when the gateway session caps (SOUL.md `scope-pivot-to-ao`)
- ❌ Goals with no "no follow-up question" in DoD — reproduces the silent-stop pattern

## Related

- `~/.smartclaw/skills/write-goal/SKILL.md` — canonical skill source
- `~/.claude/commands/goal_harness.md` (`/h`) — adversarial 4-gate loop consumer
- `~/.smartclaw/.claude/commands/a.md` (`/a`) — finish-the-job single-task drive consumer
- `~/.claude/skills/finish-the-job/SKILL.md` — end-state contract this spec plugs into

## Provenance

Created 2026-06-28 (Slack `${SLACK_CHANNEL_ID}` / `1782683653.531329`) at the user's explicit request: *"make a new /write-goal ~/.claude/command pointing to a skill with codex and hermes symlinks, use /ms and /history to review all my coding cli convos and work over the last month and design a good skill for writing goals and to make the agents drive toward outcomes I want with solid evidence, green CI PRs, high code quality."*