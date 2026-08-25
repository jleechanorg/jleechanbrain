# `social-poster` — Draft + Stage Social Posts (Hermes skill, thin pointer here)

The **canonical** skill lives at `~/.smartclaw/skills/social-poster/`. This directory
in `jleechanorg/jleechanbrain` is a **thin pointer** (symlinks) so Claude Code / Codex
launched from this repo can discover the skill via the standard
`.claude/skills/<name>/SKILL.md` resolver path.

## What's here

```
.claude/skills/social-poster/
  SKILL.md       -> ~/.smartclaw/skills/social-poster/SKILL.md
  scripts/       -> ~/.smartclaw/skills/social-poster/scripts/
  templates/     -> ~/.smartclaw/skills/social-poster/templates/
  references/    -> ~/.smartclaw/skills/social-poster/references/
  tests/         -> ~/.smartclaw/skills/social-poster/tests/
```

## Slash command

`/social <intent> [--platforms=...] [--reddit-subs=...] [--link=...] [--image=...]`
— see `.claude/commands/social.md` for full docs.

## Maintenance

Edit the canonical files at `~/.smartclaw/skills/social-poster/`. The symlinks here
pick up changes automatically. If you need to vendor a copy (no symlinks), use
`cp -RL` to dereference and commit a real tree.

## Why a thin pointer

Per the project's own conventions (see `~/.claude/CLAUDE.md` "Skill discovery
order" + `~/.smartclaw/skills/RESOLVER.md`): the canonical home for a Hermes skill
is `~/.smartclaw/skills/<name>/`. Project repos get a thin pointer so multiple
projects can share one canonical skill without copy-drift. This matches the
pattern used by `email-drafting/`, `evidence-attach-to-slack/`, etc.