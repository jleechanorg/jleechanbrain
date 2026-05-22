---
name: skeptic-evidence-capture
description: Capture browser UI evidence video for Skeptic Gate (Gate 6) on worldarchitect.ai PRs.
---

# Skeptic Evidence Browser Video Capture

Capture browser UI evidence video for Skeptic Gate (Gate 6) on worldarchitect.ai PRs.

## When to use

PR has `VERDICT: FAIL (Evidence Required)` from `github-actions[bot]` on `skeptic-trigger` job, requiring UI/video evidence of the behavior change.

## Prerequisites

```bash
# Verify Playwright is available
python3 -c "from playwright.sync_api import sync_playwright; print('ok')"

# Check display (should be empty — headless mode)
echo $DISPLAY

# Verify gh CLI auth
gh auth status
```

## Workflow

### Step 1 — Identify the preview app URL and auth bypass

The preview app URL follows pattern: `https://mvp-site-app-s1-<hash>-<region>.a.run.app`

**Auth bypass patterns tried (and what actually works):**

| Pattern | Works? | Notes |
|---------|--------|-------|
| `?test_mode=true` | No | Sets test_mode flag but doesn't bypass login |
| `?test_mode=true&test_user_id=test_scroll_6782` | No | Auth still required; #story-content exists but is hidden (landing page) |
| Direct campaign URL (e.g. `/campaign/<id>`) | No | Returns 404 if not logged in |

**What DOES work:** The test user authentication must be set server-side or via a session cookie, not URL params alone. The correct approach is:
1. Look at `testing_ui/test_final_red_green_proof.py` for the actual auth flow pattern used in other evidence captures
2. Check `testing_ui/debug_structured_test.py` for how it loads a campaign as a logged-in test user
3. The MCP server (`testing_ui/lib/browser_test_base.py`) handles auth/campaign creation — use it, don't reinvent

**Key insight:** Do NOT assume URL params bypass auth. The test mode params set flags that are checked *after* login, not instead of login.

### Step 2 — Find existing test that loads a campaign

```bash
grep -r "test_mode\|test_user\|campaign.*load\|load.*campaign" \
  ~/worldarchitect.ai/testing_ui/ \
  --include="*.py" -l 2>/dev/null | head -5
```

Look in `test_final_red_green_proof.py` — it was used for previous Skeptic evidence captures.

### Step 3 — Use Playwright with built-in video capture

Playwright has built-in video recording — no ffmpeg or Xvfb needed:

```python
from playwright.sync_api import sync_playwright

with sync_playwright() as p:
    browser = p.chromium.launch(
        headless=True,
        args=[
            '--use-fake-ui-for-media-stream',
            '--use-fake-device-for-media-stream',
        ]
    )
    context = browser.new_context(
        viewport={'width': 1280, 'height': 720},
        record_video_dir='/tmp/evidence_video/',
        record_video_size={'width': 1280, 'height': 720},
    )
    page = context.new_page()
    
    # Navigate to preview app
    page.goto('https://mvp-site-app-s1-i6xf2p72ka-uc.a.run.app')
    
    # ... perform actions ...
    # page.wait_for_timeout(2000)
    
    # Save video — get path BEFORE closing
    video_path = page.video.path()
    context.close()
    browser.close()
```

### Step 4 — Caption the video

Use Python moviepy or a subprocess with ffmpeg to burn in captions. Caption requirements per `CLAUDE.md`:
- URL bar visible (1280x720 viewport)
- Timestamps
- Git SHA burned in
- Before/action/after frames clearly marked

### Step 5 — Upload via GitHub Release

Per `CLAUDE.md` evidence policy: use `gh release` for hosting, not external services.

```bash
cd ~/worldarchitect.ai

gh release create \
  --repo jleechanorg/worldarchitect.ai \
  --title "PR 6782 evidence" \
  --notes "Browser evidence for scroll behavior" \
  evidence-pr-6782 \
  /path/to/video.mp4

# The release URL becomes the evidence URL
```

### Step 6 — Link evidence in PR

```bash
gh pr comment <PR_NUMBER> --body "## Evidence

Browser video: <release_url>

Caption summary:
- [Before] ...
- [Action] ...
- [After] ..."

gh pr edit <PR_NUMBER> --body "$(cat <<'EOF'
## Evidence
<uploaded release URL>
EOF
)"
```

## Evidence Staleness Tolerance

**If all commits after the evidence-generation SHA are test-only or docs-only, fresh evidence recapture is NOT required.** Per the user-scope evidence standards (`~/.claude/skills/evidence-standards.md` → "Evidence Staleness Tolerance for Test/Docs-Only Changes"), evidence remains valid across non-behavioral changes.

When posting evidence for a PR where the HEAD differs from the evidence SHA:

1. Compute: `git diff --name-only <evidence-sha> HEAD`
2. Classify each changed file:
   - **Test-only**: `*_test.py`, `*_test.ts`, `tests/`, `testing_mcp/`, `__tests__/`
   - **Docs-only**: `*.md`, `docs/`, `README`, `CLAUDE.md`
   - **CI/workflow**: `.github/workflows/*.yml`, `Makefile`, lint configs
   - **Type hints/comments**: `*.pyi`, type annotations, docstrings
3. If ALL files match these categories → evidence is still valid; document the tolerance in the PR comment
4. If ANY file is a behavioral change → fresh evidence IS required

Include in your PR evidence comment:
```
Evidence captured at SHA: <evidence-sha>
Current HEAD: <head-sha>
Diff: <N> file(s) — all test/docs/CI-only
Verdict: Evidence valid (no behavioral changes since capture)
```

## Verification

After uploading evidence, re-check the Skeptic status:
```bash
gh api repos/jleechanorg/worldarchitect.ai/commits/<SHA>/status
gh pr checks <PR_NUMBER>
```

## Common Failures

| Problem | Root Cause | Fix |
|---------|-----------|-----|
| `#story-content` exists but is hidden | Auth not bypassed — landed on landing page | Use MCP server auth flow or find correct campaign URL |
| `?test_mode=true&test_user_id=...` doesn't work | URL params set flags after auth, not instead of | Look at existing test files for real auth pattern |
| ffmpeg can't capture | No DISPLAY / Xvfb | Use Playwright's built-in record_video_dir API instead |
| Video path empty after close | Must get page.video.path() BEFORE closing browser | Get path before context.close() |

## Files to reference

- `testing_ui/test_final_red_green_proof.py` — auth + campaign loading pattern
- `testing_ui/debug_structured_test.py` — alternative debug flow
- `testing_ui/lib/browser_test_base.py` — MCP server auth infrastructure
- `mvp_site/frontend_v1/app.js` — scroll behavior source (to understand what to demonstrate)

## Metadata to include in caption

- PR number and branch name
- Git SHA (git rev-parse HEAD in the worktree)
- Preview app URL
- Date of recording
- What behavior is being demonstrated
