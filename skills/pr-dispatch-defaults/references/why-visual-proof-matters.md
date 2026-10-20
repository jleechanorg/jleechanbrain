# Why visual proof matters (PR #8781 incident, 2026-08-05)

A 7-file / +5/-255 mechanical diff on `jleechanorg/worldarchitect.ai#8781` (remove "AI Personalities" and "Options" rows from the campaign wizard) was technically correct: `node --test` passed, DOM counts confirmed the rows were removed, the Cloud Run preview URL served the new `campaign-wizard.9ccb03ee.js` (matching local md5). Yet the user replied: *"Where are the fucking before/after screenshots and why did you miss them?"*

The agent had:

- Posted a served-JS-hash diff and DOM-count proof to the thread
- Published an `/es` evidence gist with text-only EVIDENCE.md
- Created the PR and got Green Gate to pass on the first run

What the agent had NOT done:

- Captured a captioned BEFORE PNG of the wizard with the rows visible
- Captured a captioned AFTER PNG of the wizard with the rows removed
- Vision-verified the PNGs to confirm they show what the agent claimed

The user's rule, derived from this incident: **DOM counts and hash diffs are backup proof. PNGs of the actual wizard UI are the proof.** When the change is user-visible, BEFORE/AFTER screenshots are non-negotiable, regardless of how clean the rest of the evidence chain is.

## Why DOM counts aren't enough

A user reviewing the PR opens the GitHub PR page, looks at the files changed, runs the diff. They see code removal. But the question they're actually answering is "does the user-facing UI look right after this change?" and that question needs a screenshot of the wizard — not a JS hash diff.

DOM counts prove "the right elements were removed from the DOM." That's a server-side / structural claim. The user-facing claim is "the user no longer sees the rows on the wizard preview." Only a PNG of the rendered page proves the second claim.

## Why hash diffs aren't enough

A `campaign-wizard.9ccb03ee.js` file no longer containing the string "AI Personalities" proves the JS bundle was rebuilt. It does NOT prove the wizard renders correctly. The bundle could be missing a closing tag, the new HTML could have a JS error that crashes the wizard, the wizard could still show the rows because the deletion landed in the wrong place.

A PNG of the wizard proves the rendered UI. A hash diff proves a text-string is gone from a file.

## Why the local-server approach beats the production URL

The instinct is "use the live URL — it's authoritative." But Cloud Run requires Firebase auth, so headless Chromium only sees the login wall. The local server with `?test_mode=true&test_user_id=…` renders the actual wizard because `TESTING_AUTH_BYPASS` is an env var that `mvp_site/main.py` reads at startup.

And the local server is actually MORE faithful proof: it serves the worktree's on-disk file, which is the PR's proposed state. Cloud Run might serve a stale bundle if the deploy lags or if the image wasn't rebuilt.

## Recipe: when to capture what

| Code shape | Visual proof required? | Why |
|---|---|---|
| Pure JS logic (no DOM mutation) | No | Tests + lint are sufficient |
| JS function adds/removes DOM elements | Yes | User-visible mutation |
| CSS / theme / layout | Yes | Visual by definition |
| New modal / wizard step / form | Yes | User-visible new surface |
| Backend logic (Python, server-side) | No | Tests + integration tests |
| Prompt / LLM contract change | No (with caveats) | Smoke tests against the LLM |
| Doc / comment / type hint | No | Lint is sufficient |

For UI changes: the new skill `wa-visual-proof-playwright` (under `~/.smartclaw/skills/`) has the full capture recipe.

## Related

- `wa-visual-proof-playwright/SKILL.md` — the capture recipe
- `evidence-attach-to-slack/SKILL.md` — how to actually upload PNGs to the Slack thread (3-stage `files.completeUploadExternal` flow, not `MEDIA:` tokens)
- `pr-dispatch-defaults/SKILL.md` — the dispatch-vs-inline decision that made this fixable in one session

## What the agent should have done differently

1. After committing the diff, started `./run_test_server.sh start`.
2. Saved the worktree file to a Python variable (`saved = open(abs_file, "rb").read()`).
3. Replaced the on-disk file with `git show origin/main:path` (BEFORE).
4. Captured `/tmp/before.png` via Playwright + DOM-count backup.
5. Restored `saved` to the on-disk file.
6. Replaced the on-disk file with `git show HEAD:path` (AFTER).
7. Captured `/tmp/after.png` + DOM-count backup.
8. Restored `saved` to the on-disk file (worktree unchanged).
9. Vision-verified both PNGs with `vision_analyze`.
10. Committed the PNGs to `evidence/pr-<N>/` in the PR branch.
11. Embedded them in the PR body with markdown image syntax.
12. Attached them to the Slack thread via the 3-stage `files.completeUploadExternal` flow.

This adds ~10 minutes of capture work to a 30-minute PR fix. Worth it.

## The skill-of-the-incident

This is what the `wa-visual-proof-playwright` skill exists for. The trigger phrases include "before/after screenshot", "where are the screenshots", "you forgot the screenshot" — because the user's correction in this exact incident was "where are the fucking before/after screenshots".

If that skill is loaded BEFORE the first patch in any future UI-changing task, this incident doesn't recur.