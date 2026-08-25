# Blog-Post Drafting → Google Docs (`gog` + fallback patterns)

> **Updated 2026-08-22:** `gws` is BANNED for personal Workspace calls (Gmail/Drive/Docs/Sheets/Slides). Canonical CLI is now `gog` (v0.37.0+). See SOUL.md `## COMMIT: gws-banned-for-personal-workspace`.

**Context:** When the user asks for "a 500-word post in Google Docs as a draft", the canonical path is `gog docs create` via the `google-workspace-via-gog` skill. If `gog` OAuth isn't authenticated (the common case for a fresh Mac), the workflow degrades to a local markdown file + manual paste-into-gdoc recipe.

## Path A — `gog` authenticated (canonical)

```bash
unset GOG_KEYRING_BACKEND
ACCT=jleechan@gmail.com

# 1. Pre-strip YAML frontmatter (gog docs create puts it at the top of the doc as a paragraph)
sed '1,/^---$/d; /^---$/d' /tmp/blog-post.md > /tmp/blog-post-stripped.md

# 2. Create the doc
gog --account "$ACCT" docs create "Blog Post Draft" \
    --file /tmp/blog-post-stripped.md \
    --no-input --json

# 3. Overwrite with clean markdown body (formatted as Docs)
# Capture the doc ID from step 2 output, then:
gog --account "$ACCT" docs write <DOC_ID> \
    --file /tmp/blog-post-stripped.md --replace --markdown --no-input
```

**Pitfall (caught 2026-08-22):** `gog docs create --file foo.md` puts YAML frontmatter at the top of the doc as a paragraph. Always pre-strip with the `sed` above AND follow with `docs write --replace --markdown` to overwrite with the clean body.

## Path B — `gog` NOT authenticated (fallback)

If `gog auth status` returns `auth_preferred: none` or `credentials_exists: false`:

1. Write the post to a local markdown file: `/tmp/blog-post-<date>.md`
2. Show the rendered preview to the user (e.g. `cat /tmp/blog-post-<date>.md`)
3. Tell the user the `gog` OAuth setup is needed for automated gdoc creation. Pointer:
   - Run: `unset GOG_KEYRING_BACKEND && gog login jleechan@gmail.com --services drive,docs --drive-scope full --remote --force-consent --no-input --step 1`
   - Open the printed `auth_url` in any browser, sign in, copy the final redirect URL
   - Re-run with `--step 2 --auth-url '<paste redirect here>'`
   - Verify: `gog drive ls --max 3 --account jleechan@gmail.com`
4. The full recipe is in `~/.smartclaw/skills/google-workspace-via-gog/SKILL.md` "OAuth re-consent flow" section.

## Verification (Path A)

```bash
# Confirm doc exists where you think it does
gog --account "$ACCT" drive search "name = 'Blog Post Draft'" --json | head -30

# Show first 25 lines of body to spot-check formatting
gog --account "$ACCT" docs cat <DOC_ID> | head -25
```

## DO NOT walk through this autonomously unless explicitly asked

OAuth re-consent requires human interaction at the Google consent screen. Don't auto-kick it off; show the user the path and let them say "DO IT".

## See also

- `~/.smartclaw/skills/google-workspace-via-gog/SKILL.md` — full `gog` pitfalls + OAuth re-consent recipe (canonical)
- `~/.claude/commands/google.md` — `/google` slash command dispatcher
- Mac keychain entry (ground truth): `gogcli / token:default:jleechan@gmail.com`
- **Removed 2026-08-22:** `~/.smartclaw/skills/productivity/google-workspace/` (Python wrapper, `gws`-based) — replaced by `gog`.
- **Removed 2026-08-22:** `~/.smartclaw/skills/productivity/google-workspace/scripts/gws_bridge.py` — `gws` banned for personal calls.
