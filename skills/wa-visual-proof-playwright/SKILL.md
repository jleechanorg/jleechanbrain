---
name: wa-visual-proof-playwright
version: 1.0.0
description: Capture captioned BEFORE/AFTER PNG evidence for any user-visible change in jleechanorg/worldarchitect.ai. Use when making UI changes (CSS, layout, theme, color, toggle, modal, form, input visibility, animation, text copy under mvp_site/) and need visual proof. Original incident was 2026-08-05 PR 8781 where the agent captured only the served JS hash diff but skipped the captioned screenshots, and user replied with "where are the fucking before/after screenshots".
triggers:
  - "before/after screenshot"
  - "visual proof"
  - "PNG evidence"
  - "/es ui evidence"
  - "captured screenshot"
  - "where are the screenshots"
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash
  - Grep
context: inline
---

# wa-visual-proof-playwright

The contract for any user-visible change to jleechanorg/worldarchitect.ai is: BEFORE PNG and AFTER PNG, both captioned, both captured against the same surface (same code path, same data, same viewport).

DO NOT claim "fix landed" without both PNGs in the PR or PR comments, paired with vision descriptions and computed-style deltas.

## When to use

ANY frontend change. Triggers:

- Removing, adding, or reordering UI text rows, buttons, fields
- CSS, theme, color, animation, or responsive tweak
- Modal, toggle, dropdown, or accordion change
- Wizard step reorder or step copy change
- Fix of UI behavior

If you are touching mvp_site/frontend_v1/** (HTML, CSS, JS, JSX) or any URL-served UI, this skill applies.

## What it is NOT

- Tests do not satisfy it (node --test, pytest). They prove logic, not UI.
- DOM counts do not satisfy it. They are a backup proof; the user wants screenshots.
- Server returned 200 does not satisfy it. Browser rendering can break without a 5xx.
- "I shipped the change" is a write operation. The proof is what shipped.

## The 4-step recipe

### Step 1 — Start the local server

```bash
cd ~/projects/worldarchitect.ai          # or a worktree under .worktrees/
./run_test_server.sh start               # prints PORT=XXXX URL=http://localhost:XXXX
```

If CEREBRAS_API_KEY is missing, the server may abort. Set TESTING_AUTH_BYPASS=true at minimum. If still failing, fall back to a Cloud Run preview URL (mvp-site-app-s{N}-i6xf2p72ka-uc.a.run.app) — see Step 2 caveat.

### Step 2 — Capture the BEFORE

If you are running the server yourself, you can swap between branches. The cleanest BEFORE capture uses origin/main content with `git show origin/main:path > on-disk-file` followed by a server restart. Save bytes, restart, capture, then restore bytes + restart.

If you do not have time to swap, use the production URL: `mvp-site-app-s1-i6xf2p72ka-uc.a.run.app/new-campaign` (and any other live URL your changes will land on). Note: production URLs require Firebase auth — the user-supplied screenshot is the proxy.

The capture script (headless Chromium, no auth needed because of `?test_mode=true&test_user_id=...`):

```python
import asyncio
from playwright.async_api import async_playwright

async def capture(BASE, label):
    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True)
        ctx = await browser.new_context(viewport={"width": 1400, "height": 1100})
        page = await ctx.new_page()
        await page.goto(f"{BASE}/new-campaign?test_mode=true&test_user_id={label}",
                        wait_until="domcontentloaded", timeout=30000)
        await page.wait_for_timeout(3000)
        try:
            await page.wait_for_selector('div.campaign-type-card[data-type="custom"]', timeout=10000)
        except Exception as e:
            print("type card err:", e); return
        await page.click('div.campaign-type-card[data-type="custom"]')
        await page.wait_for_timeout(800)
        for _ in range(3):
            btn = page.locator("button:has-text('Next')").first
            if await btn.is_visible(timeout=2000):
                await btn.click(); await page.wait_for_timeout(700)
            else: break
        await page.wait_for_timeout(2000)
        await page.evaluate("window.scrollTo(0, document.body.scrollHeight)")
        await page.wait_for_timeout(500)
        await page.screenshot(path=f"/tmp/{label}.png", full_page=True)
        rows = await page.locator(".preview-item").count()
        for i in range(rows):
            print(f"  row {i}: {(await page.locator('.preview-item').nth(i).inner_text())[:80]}")
        await browser.close()

asyncio.run(capture("http://localhost:8081", "before"))
asyncio.run(capture("http://localhost:8081", "after"))   # after restoring your fix
```

### Step 3 — Restore main + restart, capture AFTER

Same script, after `git show HEAD:path > on-disk-file` and server restart.

The bytes-around-the-restore MUST round-trip exactly: save, replace, capture, restore (with the saved bytes — do NOT re-`git show` after-the-fact because the working tree may have drifted), restart server. Otherwise the second capture uses stale code.

### Step 4 — Vision-verify both PNGs

For each PNG, use `vision_analyze` with this prompt:

> This is the [BEFORE/AFTER] screenshot. Look at the campaign summary preview. List every preview row labeled with a bold name. Specifically: is there an X row? Is there an Y row? How many total preview rows?

Required response shape:

- BEFORE: 5 rows including X and Y
- AFTER: 3 rows, NO X, NO Y
- Both PNGs have identical viewport width
- Vision description matches the DOM-count backup

If vision_analyze cannot tell, capture a wider screenshot or scroll-to-element the specific section.

## Where the PNGs go

```
evidence/
├── pr-{N}/
│   ├── before.png         (user prod screenshot, OR local-server with main code)
│   ├── before_local.png   (local server with origin/main code)
│   └── after_local.png    (local server with this PR's code)
└── ...
```

Commit them. Reference in PR body with markdown image link so they render in the GitHub PR view.

## Pitfalls (from 2026-08-05 incident PR 8781)

- **Login wall on production URLs**: `mvp-site-app-s1-...run.app` and `mvp-site-app-s8-...run.app` require Firebase sign-in. The `?test_mode=true&test_user_id=...` bypass only works on `localhost`. Always use the local server for visual evidence.
- **Login screen does not equal wizard**: a screenshot showing the Firebase sign-in box tells the reviewer nothing about the wizard UI fix. Re-do the capture against the local server.
- **cache_busting.py rot**: the served file is `campaign-wizard.HASH.js` based on content hash. Cloud Run may serve stale content if the image was not rebuilt. Verify by `curl -s https://...run.app/frontend_v1/js/campaign-wizard.HASH.js | grep AI Personalities` after the deploy.
- **Server dance + restart is slow**: budget 60-90s for `pkill && run_test_server.sh start` cycle. Do not shortcut it.
- **Saving bytes around the swap must round-trip**: if you re-`git show HEAD:` after the swap, you may pick up changes your in-flight rebase applied. Read into a local variable at the START and write that variable back.
- **Counts without vision is blind**: 3 vs 5 rows can mean many things. `vision_analyze` on the actual PNG prevents misinterpretation.

## When to invoke

This is a contract, not a one-off workflow. Code that touches the UI without producing captioned visual evidence fails review (see SOUL.md `## COMMIT: ui-change-requires-before-after-visual-proof`).

If `## COMMIT: ui-change-requires-before-after-visual-proof` fires, load THIS skill before the first patch. The before-capture step needs to happen BEFORE any code edit so the diff is visible.
