---
description: Alias for /memory_search — search across all memory systems (Hermes-side overlay)
type: llm-orchestration
execution_mode: immediate
---

# /ms — Hermes-side Alias for /memory_search

**This file is the Hermes-side resolver entry for the `/ms` slash command.**
Hermes runtimes resolve this repository-owned file when the user types `/ms`.
User-scope Claude and Codex command files are invocation adapters only.

## Action

Read `~/.smartclaw/skills/memory-search/SKILL.md` (Hermes-side overlay) and execute the
full 10-store fan-out end-to-end only in a private one-to-one session with
Jeffrey. Run personal-store searches with direct calls from that private parent
session; never dispatch them to `/e`, `delegate_task`, or another worker. In
shared, cron, or worker contexts, search only sources proven to be scoped to
the current thread, channel, or task. Execute only the repository-owned
allowlist in `skills/memory-search/SKILL.md`; never load a user-scope skill as
an implementation fallback.

## Dispatch authority

For every runtime operating in this workspace, `workspace/SOUL.md` and the
repository overlay `skills/memory-search/SKILL.md` are authoritative before any
user-scope command or implementation helper. Both owners are required. A user-scope `/ms` file may
forward into this workflow, but it is not a policy owner and cannot authorize
personal-store fan-out. If either the workspace gate or the repo overlay is
unavailable, fail closed instead of dispatching through an unchecked fallback.

Private direct sessions can use the same 10 sources (~/roadmap, beads, claude
memories, hermes sqlite, hermes briefings, hermes index, openclaw memories,
wiki, history, slack). Other contexts must not fan out across personal stores.

## Usage

```
/ms <query> [--flags]
```

Examples:

```
/ms slack misroute failure 5
/ms hermes deploy --recent 7
/ms jleechan-owka --source beads --limit 5
```

## Why this overlay exists (added 2026-07-02)

Before 2026-07-02, `/ms` only resolved from Claude Code / Codex runtimes via `~/.claude/commands/ms.md`.
Slack / CLI / cron Hermes sessions could not invoke `/ms` because `~/.smartclaw/skills/memory-search/SKILL.md`
did not exist and there was no slash-command resolver on the Hermes side. The
`## COMMIT: ms-on-new-task` rule in SOUL.md told agents to call `memory-search` skill via
`skill_view`, but the resolver path was broken from Hermes. Telemetry from `~/.smartclaw/state.db`
showed 0 of 1,951 tool-using sessions in 7 days called `memory-search` via `skill_view` — the
wiring was missing, not just the wording.

This overlay + the `skills/memory-search/SKILL.md` overlay close that gap.

## Cross-references

- User-scope adapters: `~/.claude/commands/ms.md` and `~/.codex/commands/ms.md` (invocation only)
- Repository-owned policy and mechanics: `skills/memory-search/SKILL.md`
- Hermes overlay skill: `~/.smartclaw/skills/memory-search/SKILL.md`
- Trigger rule: `~/.smartclaw/workspace/SOUL.md` `## COMMIT: ms-on-new-task`
- Per-session fan-out: `~/.smartclaw/workspace/AGENTS.md` `Session Startup`
- Audit detector: `~/.smartclaw/scripts/audit_ms_proactive_firing.sh`
- Bug-ref: 2026-07-02 Slack C0AJ3SD5C79 ts 1783036536.864119
