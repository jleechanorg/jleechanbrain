# git archaeology — when did this bug start?

The most common "investigation + fix in parallel" pattern is **"when did this bug start?"** alongside a fix dispatch. The recipe is `git log` archaeology in <5 tool calls.

## When to use

- User says "when did this start", "is this a regression", "did we recently change X", "did we reduce quality"
- You need a commit SHA + date + author + "shipped with" list as the harness answer
- The fix is dispatched in parallel — you need the diagnosis BEFORE writing the worker prompt

## Recipe (verified 2026-08-16 on jleechanorg/worldarchitect.ai avatar-crop pixelation)

### 1. Find when the offending line was introduced

```bash
# When you have the exact code pattern (from `grep` or read_file):
git log --reverse --oneline -G '<exact pattern>' -- <file>

# Examples that worked:
git log --reverse --oneline -G 'canvas.width = zoneSize' -- mvp_site/frontend_v1/js/avatar-crop.js
git log --reverse --oneline -G '280px' -- mvp_site/frontend_v1/css/avatar.css
```

`-G` searches commit DIFFS for the regex (not just messages). `--reverse` puts the OLDEST match first — that's the introduction commit. Pair with `-p` for surrounding diff context if the commit message is sparse.

### 2. Cross-check: was the file's first commit the same one?

```bash
# When the bug is the file's entire reason for existing:
git log --reverse --diff-filter=A --oneline -- <file> | head -1

# Otherwise (file existed before the bug shipped):
git log --reverse --oneline -- <file> | head -1
```

If both return the same SHA, the bug was shipped WITH the file — strong "not a regression" signal. If they differ, the file existed in a working state and the bug was introduced later — narrower "regression window."

### 3. List commits that touched the file since

```bash
git log --all --oneline -- <file> | head -20
git log --all --oneline --grep='<feature-keyword>' -- <file>
```

Build the "what's been done since" list. Cross-reference with bug class — none of these commits touched canvas resolution? Strong "design choice, not regression" finding.

### 4. Confirm with stat

```bash
git show --stat <suspect-commit-sha> -- <file1> <file2>
```

See what OTHER files changed in the same commit. If the bad default was set alongside related scaffolding (e.g. CSS `.avatar-crop-zone { width: 280px }` AND JS `|| 280` both in the same commit), that's a "shipped together" finding.

### 5. Compose the harness answer

```
Origin: commit `<SHORT-SHA>` — <date> (<N> months/days ago). Shipped by <author>.
Commit message: "<message>"
Co-shipped: <list of other files changed in the same commit>
Verified not a regression: <list of commits that touched the file since, none of which changed this pattern>
```

That's the proof artifact. Pair with the file:line citation (`mvp_site/frontend_v1/js/avatar-crop.js:30`) and you're ready to write the worker prompt.

## Pitfalls

- **Don't trust the commit MESSAGE alone.** `git log --all --oneline --grep='<keyword>'` returns messages that LOOK relevant but may have edited unrelated files. Always cross-check with `git show --stat`.
- **Don't trust a single `git blame <line>`**. Blame shows the LAST change to a line, not when the bug class was introduced. For "when did this start," use `git log -G` to walk DIFFS forward in time.
- **If the file moved** (renames tracked by git), use `--follow` on `git log` so the rename is transparent. Otherwise the history appears to start at the rename commit.
- **If the repo has a `feat/` branch with a much newer HEAD than `origin/main`**, check both. The bug may have been fixed on the feature branch already. `git log --all --oneline -- <file>` covers this.

## Worked transcript (jleechanorg/worldarchitect.ai, 2026-08-16)

```text
$ git log --reverse --diff-filter=A --oneline -- mvp_site/frontend_v1/js/avatar-crop.js
1d5c748322 feat: centralize crop UI, compact textarea, spinner overlay

$ git log --reverse --oneline -G 'canvas.width = zoneSize' -- mvp_site/frontend_v1/js/avatar-crop.js
1d5c748322 feat: centralize crop UI, compact textarea, spinner overlay   ← March 3, 2026
3465e43a05 fix: correct testing_mcp stat path (base_attributes) and bundle local changes
2580afd81d trigger: re-run CI for Green Gate (no-op commit)
523d98a7edd9e7ba69eb049da24b872dcff98c5e
... (subsequent commits re-introducing the line after a temporary refactor)

$ git show --stat 1d5c748322 -- mvp_site/frontend_v1/js/avatar-crop.js mvp_site/frontend_v1/css/avatar.css
Author: ${GITHUB_USER}
Date:   Tue Mar 3 23:40:34 2026 -0800

feat: centralize crop UI, compact textarea, spinner overlay

- Extract drag-to-reposition to shared avatar-crop.js module
- Both wizard and in-game change photo use same AvatarCrop.show()
- In-game change photo: fullscreen crop overlay with Use/Cancel buttons
- Wizard: removed 130 lines of inline crop code, uses shared module

 mvp_site/frontend_v1/css/avatar.css       | (deleted in this commit — file replaced)
 mvp_site/frontend_v1/js/avatar-crop.js    | (added)
```

→ Harness answer: 5.5 months old, shipped together with CSS default of 280px, NOT a recent regression. Cross-ref `9e204c0139`, `75dcd90a51`, `3ef807d9ad` — none of those touched canvas resolution.
