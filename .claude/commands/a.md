---
description: /a — "Your call. Drive it." Hands-off directive for a single task. Same evidence stack as /fullrun, but scoped to one goal (not multi-worker backlog).
type: orchestration
execution_mode: immediate
---

# /a — "Your Call. Drive It."

**Shortest hands-off directive.** For a single task where you've given Hermes autonomy and don't want to be interrupted mid-flight. The "a" stands for "your call" or "autonomous" — pick whichever matches your intent.

## Usage

```
/a <goal>
/a fix the cold-start bug
/a ship the Luke + Daenerys default-POV campaigns
/a investigate the BQ logging gap
```

## When invoked

1. **Load the skill:** `~/.smartclaw/skills/finish-the-job/SKILL.md`.
2. **Skip Phase-0 clarifying question** — your phrasing is enough. Make the call yourself.
3. **Drive to ONE of the four provable end-states** per the `finish-the-job` contract.
4. **Final reply** MUST contain the full evidence stack (see `## COMMIT: a-fullrun-evidence-stack`):
   - PR URL(s) as markdown hyperlinks (NEVER bare `#N`)
   - `/er` evidence verdict or link
   - `/skeptic` verdict (worldarchitect.ai PRs)
   - Captioned screenshot/gif of the user-facing surface (UI changes only)
   - List of remaining human-only steps
   - One-line note on every mid-stream judgment call made
   - **No follow-up question** — the work is done; the user reviews.

## Equivalent phrases that auto-fire this command

- "drive with /a"
- "your call", "do it", "just do it", "you decide", "handle it", "ship it", "merge it"
- "your call on the approach"  # also registered in skills/RESOLVER.md
- "/a fullrun" (composes /a + /fullrun — see /fullrun)  # also registered in skills/RESOLVER.md

## Differences from /fullrun

| | `/a` | `/fullrun` |
|---|---|---|
| Scope | Single task | Backlog / multi-worker / multi-PR |
| Babysit cadence | n/a (single task, usually inline) | terminal-only |
| Brief template | Optional (single-task may be small enough to inline) | Mandatory (every spawn gets a brief first) |
| Mid-stream questions | NEVER | NEVER |
| Final reply | Evidence stack | Evidence stack |
| Use when | "Just fix this thing" | "Drive everything" |

## What you must NOT do

- ❌ Ask a clarifying question before starting — make the call
- ❌ Stop at "I started, will update" — drive to conclusion
- ❌ Post a follow-up "want me to X?" — the work is done; user reviews
- ❌ Stop at local commit / local PR open / local state change — verify the end-state is provable
- ❌ Skip the evidence stack — UI changes need visual proof, PR changes need /er + /skeptic

## Related

- `/finish` — same contract, allows Phase-0 clarifying question
- `/auto` — alias for `/finish`
- `/fullrun` — multi-worker / multi-PR variant
- `~/.smartclaw/skills/finish-the-job/SKILL.md` — the substrate contract

## Provenance

Promoted from `/roadmap` Step 8.5 directive (2026-06-26, commit `8d6e888a4a`) where `/a fullrun` was the user's verbatim phrase: *"all things must be driven with /a and fullrun"*. This makes `/a` and `/fullrun` first-class slash commands usable outside the `/roadmap` flow.