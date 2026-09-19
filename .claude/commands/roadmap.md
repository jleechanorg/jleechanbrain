---
description: /roadmap — audit Slack threads last 48h, run /nextsteps, push report to roadmap repo
type: orchestration
execution_mode: immediate
---

# ⚡ EXECUTION INSTRUCTIONS FOR CLAUDE

**When this command is invoked, YOU (Claude) must execute the `roadmap` skill.**

## What this command does

`/roadmap` runs a 48h Slack thread audit:

1. Pulls Slack history from configured channels
2. Classifies each thread as finished / pending / needs-human-decision
3. Runs `/nextsteps` on each pending thread
4. Pulls `gh pr list --state open` for the active repo
5. Builds a Markdown report (per § Report Shape in the skill)
6. Pushes the report to `jleechanorg/worldarchitect-roadmap`
7. Posts the URL back to the originating Slack thread

## Canonical skill

The full pipeline definition lives at:

```
${HOME}/.smartclaw/skills/roadmap/SKILL.md
```

(Same canonical Hermes root; staging uses an overlay config, not a second skill tree.)

## How to invoke

**Inline (from this Claude session):**
```
skill_view(name='roadmap')
```
Then follow the § Pipeline steps in the skill body, in order.

**Headless / via cron:**
The launchd job `ai.smartclaw.schedule.roadmap-audit` runs this Mon-Fri at 09:00 PT + 17:00 PT. It calls `${HOME}/.smartclaw/scripts/roadmap-audit.sh`, which writes a dispatch marker and the AO worker picks it up.

## Trigger phrases (auto-loaded by resolver)

- `/roadmap`
- `audit my slack threads`
- `push roadmap repo`
- `what's still pending`
- `nextsteps on all threads`
- `show me the roadmap report`
- `roadmap all my slack asks`

## Related skills

- `worldarchitect` — auto-loaded for threads from `#worldai-bugs` channel
- `jleechanbrain-slash-command-rollout` — wiring recipe for the three wiring points
- `hermes-deploy-pipeline` — staging/prod + POLICY_FILES rules
- `skillify` — the 10-item contract this skill satisfies
