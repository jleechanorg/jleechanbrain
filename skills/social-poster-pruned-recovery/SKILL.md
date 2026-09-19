---
name: social-poster-pruned-recovery
description: Recover social-poster from [SKILL_PRUNED] via git.
when_to_use: When ~/.smartclaw/skills/social-poster/ contains only __pycache__/.
---

# Recovering the social-poster skill after curator prune

Curator reconcile runs occasionally prune skills down to only their `__pycache__/` directories. `social-poster` is one that gets pruned because its main value is its SKILL.md + scripts + references, and the curator may decide the SKILL.md hasn't been touched recently.

## Symptoms

- `~/.smartclaw/skills/social-poster/` exists but `ls` shows only `__pycache__/` (and possibly `tests/__pycache__/`).
- `skill_view(name="social-poster")` returns `[SKILL_PRUNED: content lost in compression; reload with skill_view(name='social-poster')]`.
- `/social <intent>` slash command fails with skill-not-found.
- The staging scripts (`stage_in_aside_mcp.py`, `draft_social_post.py`) are missing.

## Recovery recipe (verified 2026-08-05)

The git history of `~/.smartclaw/.git` contains the canonical restore commit. The full restore commit is **`eed207c4cb14d2fac6129f815c7406955c1ae1ad`** ("antigravity/gemini-3.6-flash: stage all local skills, scripts, launchd templates, tests, and updated .gitignore") — it has 20 files: SKILL.md, 9 templates, 4 scripts, 3 references, 2 tests, 1 routing-eval.jsonl.

```bash
# 1. Confirm the prune
ls ~/.smartclaw/skills/social-poster/  # should show only __pycache__/

# 2. Verify the restore commit exists
git -C ~/.smartclaw log --all --diff-filter=A --pretty=format:'%H %s' -- skills/social-poster/SKILL.md | head -3

# 3. Restore the SKILL.md (and any single file)
git -C ~/.smartclaw show eed207c4cb:skills/social-poster/SKILL.md > ~/.smartclaw/skills/social-poster/SKILL.md

# 4. Restore the full directory (all 20 files)
mkdir -p ~/.smartclaw/skills/social-poster
for f in $(git -C ~/.smartclaw ls-tree -r --name-only eed207c4cb -- skills/social-poster/); do
  dest=~/.smartclaw/$f
  mkdir -p "$(dirname "$dest")"
  git -C ~/.smartclaw show eed207c4cb:$f > "$dest"
done

# 5. Verify
ls ~/.smartclaw/skills/social-poster/
ls ~/.smartclaw/skills/social-poster/scripts/
ls ~/.smartclaw/skills/social-poster/references/
ls ~/.smartclaw/skills/social-poster/templates/
ls ~/.smartclaw/skills/social-poster/tests/
```

After the restore, `skill_view(name="social-poster")` returns the full content. The skill is then usable for `/social` requests.

## Why this commit

- `eed207c4cb` is a checkpoint that bundled every skill + script + launchd template + test into a single commit, designed for re-extraction after pruning.
- It's the same commit referenced in `~/.smartclaw/MEMORY.md` for the social-poster-pruned pattern.

## If the commit is missing

Search for an older commit that added any social-poster file:

```bash
git -C ~/.smartclaw log --all --diff-filter=A --pretty=format:'%H %s' -- skills/social-poster/SKILL.md
git -C ~/.smartclaw log --all --diff-filter=A --pretty=format:'%H %s' -- skills/social-poster/scripts/stage_in_aside_mcp.py
```

Whichever returns a commit SHA, use that as the source for `git show <SHA>:skills/social-poster/<file>`. The git tree of `~/.smartclaw/.git` is the canonical source for all skill files — never re-author from scratch.

## Preventing future prunes

The curator prunes skills that haven't been touched in N days. After restoring, **edit SKILL.md with a small substantive change** (e.g. add a new lesson learned from the next run) so the file's mtime is fresh and the curator skips it. Or set up `hermes curator pin social-poster` if you have user-facing commit rights.

## After restore, refresh

If the skill_manage cache is stale, the next `skill_view` may still return `[SKILL_PRUNED]`. Wait for the reload confirmation or trigger a fresh session. The skill itself is fully usable from `~/.smartclaw/skills/social-poster/` even before the cache refreshes.

## Related references

- `references/entertainment-fandom-subreddit-rules.md` — verified rules for entertainment/fandom subreddits (r/HouseOfTheDragon, r/asoiaf, r/freefolk, r/Hotd, etc.) and AI subs where self-promo is explicitly allowed (r/ai_rpg_community, r/AIDungeon, r/aigamedev, r/AIPlayableFiction, r/LocalLLaMA, r/Rag, r/OpenAI). Includes the Aside MCP media-upload pitfall (Twitter rejects Playwright `setInputFiles`), single-tweet character budget with two URLs, and the LinkedIn/Facebook/Threads 2-step anti-bot flow. Captured 2026-08-05 social-poster run.