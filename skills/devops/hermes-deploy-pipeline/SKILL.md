---
name: hermes-deploy-pipeline
description: Enforce the Hermes deploy pipeline — always write to ~/.smartclaw/ staging first, test, commit + push to jleechanorg/smartclaw origin main, then deploy to ~/.smartclaw_prod/. Never write to prod directly.
when_to_use: "Use when creating, updating, or deploying any Hermes skill, config, or code artifact. Use when catching yourself writing to ~/.smartclaw_prod/ before staging. Use after any file write under ~/.smartclaw/ or ~/.smartclaw_prod/."
tags: [deploy, staging, pipeline, hermes, smartclaw]
---

# Hermes Deploy Pipeline — Staging First, Always

## The Rule

**All changes flow: `~/.smartclaw/` → test → commit → push → `~/.smartclaw_prod/`**

Never reverse this flow. Never write to prod first.

## Pipeline Steps

### Step 1: Write to Staging

All file writes go to `~/.smartclaw/` (the git-tracked source of truth):

```
~/.smartclaw/         = staging (git remote: jleechanorg/smartclaw)
~/.smartclaw_prod/    = production (deployed output, NEVER the primary write target)
```

This applies to:
- Skills (`~/.smartclaw/skills/`)
- Config (`~/.smartclaw/config.yaml`, `.env`)
- Policy files (SOUL.md, TOOLS.md, HEARTBEAT.md)
- Scripts (`~/.smartclaw/scripts/`)
- Any other artifact under `~/.smartclaw/`

### Step 2: Test

Run relevant tests to verify the change:

```bash
# For skills: verify SKILL.md parses correctly
cat ~/.smartclaw/skills/<name>/SKILL.md | head -10

# For Python code
source venv/bin/activate && python -m pytest tests/ -q

# For config changes
~/.smartclaw/scripts/doctor.sh
```

### Step 3: Commit and Push

```bash
cd ~/.smartclaw
git add -A
git commit -m "<type>(<scope>): <description>"
git push origin main
```

The git remote is `jleechanorg/smartclaw`. Always push to `origin main`.

### Step 4: Deploy to Production

```bash
# Option A: Via deploy script (preferred for policy files)
~/.smartclaw/scripts/deploy.sh --system hermes

# Option B: Explicit copy (for skills that deploy.sh doesn't cover)
cp -r ~/.smartclaw/skills/<name>/ ~/.smartclaw_prod/skills/<name>/
```

Secrets (`.env`, `auth.json`, credentials) live only in `~/.smartclaw_prod/` — never sync through deploy.sh.

## Violation Recovery

If you catch yourself having written to `~/.smartclaw_prod/` first:

1. **Stop** — don't continue writing to prod
2. **Copy** the file(s) to `~/.smartclaw/` staging:
   ```bash
   cp ~/.smartclaw_prod/skills/<name>/SKILL.md ~/.smartclaw/skills/<name>/SKILL.md
   ```
3. **Continue** from Step 2 (test → commit → push → deploy)

## Anti-Patterns

- ❌ Writing directly to `~/.smartclaw_prod/` as primary action
- ❌ Using `skill_manage()` which writes to `~/.smartclaw_prod/skills/` without also writing to `~/.smartclaw/skills/`
- ❌ Forgetting to `git push origin main` after committing
- ❌ Treating `~/.smartclaw_prod/` as source of truth — it's a deploy target only
- ❌ Using `skill_manage(action='create')` and then separately copying — just write to staging first

## Important: skill_manage() Default Behavior

Hermes's `skill_manage()` tool writes to `~/.smartclaw_prod/skills/` by default (the runtime skill path). After using it, you MUST also copy the skill to staging:

```bash
# After skill_manage creates/updates a skill:
mkdir -p ~/.smartclaw/skills/<category>/<name>/
cp -r ~/.smartclaw_prod/skills/<category>/<name>/* ~/.smartclaw/skills/<category>/<name>/
cd ~/.smartclaw && git add skills/ && git commit -m "..." && git push origin main
```

Or better: write the SKILL.md directly to `~/.smartclaw/skills/` first, then let `deploy.sh` or explicit copy move it to prod.

## Verification

After any deploy, verify both locations match:

```bash
diff -r ~/.smartclaw/skills/<name>/ ~/.smartclaw_prod/skills/<name>/
# Should show no differences (except possibly .gitkeep or temp files)
```

## Bug History

| Date | What happened | Root cause |
|------|--------------|------------|
| 2026-05-08 | browser-skill-optimizer written to prod only via skill_manage() | Forgot to copy to staging after creating |
| Multiple | Skills exist in prod but not in smartclaw repo | skill_manage default path is prod, not staging |

## Related

- SOUL.md `## COMMIT: staging-first-deploy` — behavioral enforcement
- AGENTS.md "Deploy Workflow" section — workspace-level guidance
- `scripts/deploy.sh` — the actual deploy mechanism
