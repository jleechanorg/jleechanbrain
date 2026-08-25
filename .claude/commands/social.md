---
description: Draft social-media posts for 9 platforms (LinkedIn, HN, Twitter/X, Reddit, Threads, Facebook, Instagram, Mastodon, Dev.to). Stages in Aside browser + screenshots. Posts only after "POST APPROVED" token.
type: execution
execution_mode: deferred
---

# /social — Draft + Stage Social Posts

Loads the `social-poster` skill (canonical at `~/.smartclaw/skills/social-poster/SKILL.md`,
thin pointer here in jleechanbrain at `.claude/skills/social-poster/SKILL.md`).

## Usage

```
/social <intent> [--platforms=...] [--reddit-subs=...] [--link=...] [--image=...]
```

## Examples

```
/social announce jleechanbrain open-source release
/social draft a Show HN for jleechanbrain
/social draft a tweet thread about jleechanbrain's deploy pipeline
```

## Behavior

1. Runs `python3 ~/.smartclaw/skills/social-poster/scripts/draft_social_post.py` with the intent + flags.
2. Runs `python3 ~/.smartclaw/skills/social-poster/scripts/stage_in_aside.py` to open Aside tabs + screenshots.
3. Surfaces screenshots via Slack `MEDIA:` + draft text.
4. **WAITS** for user to type `POST APPROVED` (optionally `POST APPROVED <platforms>`).
5. On approval, runs `python3 ~/.smartclaw/skills/social-poster/scripts/post_approved.py`.

## Safety

- Without `POST APPROVED` token, `post_approved.py` exits code 2. No bypass.
- Instagram has no web compose — draft surfaces caption + mobile-app instructions.
- Default mode is pure templating — no LLM call. Pass `--use-llm` to enable LLM refinement.

## Files

- Canonical skill: `~/.smartclaw/skills/social-poster/` (Hermes-side)
- Thin pointer: `.claude/skills/social-poster/` in this repo (jleechanbrain-side, symlinks)
- Slash command: `.claude/commands/social.md`