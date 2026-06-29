---
description: Hands-off finish protocol — drive the goal to a verifiable end-state (green PR, merged fix, dry-run, or local state verified). Never stops halfway.
type: orchestration
execution_mode: immediate
---

# /finish — Hands-off Finish Protocol

**Alias for the `finish-the-job` skill.** Loads the skill and routes the user's goal through it.

## Usage

```
/finish <goal>
```

## When invoked

1. Load the skill: `~/.smartclaw_prod/skills/finish-the-job/SKILL.md`
2. Pass the full argument as the goal
3. Follow the skill's Phase 0 → Phase 4 contract (classify → /fs if non-trivial → dispatch → drive to conclusion → final reply with proof artifact)

## Equivalent phrases that auto-fire this skill (no /finish prefix needed)

- "finish the job", "finish it", "finish this", "finish that"
- "see this through", "take it all the way", "drive to conclusion"
- "don't stop halfway", "why did you stop", "hands off mode", "fullsend"
- "make hermes hands off", "skillify hermes to be hands off"
- "i started but didn't finish", "work started but didn't finish"

## What you must NOT do

- ❌ Acknowledge then stop (the work is not done until a provable end-state)
- ❌ Post a multi-option question mid-stream — apply your own best judgment
- ❌ "Tests pass locally, want me to push?" — push and merge
- ❌ Investigation with no commit/PR/dry-run — drive to action

See skill: `~/.smartclaw_prod/skills/finish-the-job/SKILL.md` for the full contract.