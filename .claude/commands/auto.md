---
description: /auto — ultra-short alias for /finish. Say "auto" or "/auto" to switch Hermes into hands-off mode for whatever goal follows.
type: orchestration
execution_mode: immediate
---

# /auto — Ultra-short alias for /finish

**One-word alias for `/finish`.** Same behavior, same skill, same contract.

## Usage

```
/auto <goal>
/auto
```

When `/auto` is invoked alone (no goal), treat the next user message as the goal and route through the `finish-the-job` skill.

## When invoked

1. Load the skill: `~/.smartclaw_prod/skills/finish-the-job/SKILL.md`
2. Pass the goal through Phases 0-4 of the skill
3. End-state must be provable (green PR / merged fix / dry-run / local state verified)

## Why this exists

"auto" is the shortest command that signals "stop asking, start driving." When you say `/auto`, you're saying: I don't want options, I want completion. The `finish-the-job` skill is what makes that promise enforceable.

## Equivalent natural-language triggers

- "auto", "automate this", "do it autonomously"
- "you decide", "your call", "handle it"
- "hands off", "no questions", "just finish"
- "ship it", "merge it"

See skill: `~/.smartclaw_prod/skills/finish-the-job/SKILL.md` for the full contract.