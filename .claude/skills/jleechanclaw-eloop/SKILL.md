---
name: jleechanbrain-eloop
description: Custom evolve loop for jleechanbrain orchestrator — drains dropped Slack thread backlog via /claw, fixes hermes issues, proposes new work items. Max 50 items, newest-first.
type: skill
---

## Purpose

This is the **jleechanbrain**-specific backlog eloop **discovery entry** (distinct from `.claude/skills/evolve_loop/SKILL.md`). Use this file as a pointer to the canonical procedure rather than the authoritative source itself.

**Authoritative procedure** (full phases, bash snippets, Slack channels): read **`skills/jleechanbrain-eloop.md`** at the repository root of the harness checkout.

After `scripts/bootstrap.sh`, the same text is available at **`~/.smartclaw/skills/jleechanbrain-eloop.md`** (symlink to the repo file).

AO `orchestratorRules` and project `agentRules` reference the runtime path and/or repo `skills/jleechanbrain-eloop.md`; this `.claude/skills/.../SKILL.md` exists so Claude Code discovery finds the eloop. Agents and operators should follow the procedure in the authoritative file/path above.

**Related:** `agent-orchestrator.yaml` — **CUSTOM ELOOP — BACKLOG PROCESSOR (jleechanbrain)** summary and per-cycle limits.
