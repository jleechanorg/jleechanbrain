# Section-capture recipe for CSS-rule fixes

When the user's screenshot zooms in on a SPECIFIC UI section (planning-block choices, modal body, accordion panel) and the fix is a CSS rule in `mvp_site/frontend_v1/styles/*.css`, a full-page screenshot is overkill. Section-capture produces tighter evidence and makes the diff obvious in the PR.

**Verified 2026-08-19, PR [#9131](https://github.com/jleechanorg/worldarchitect.ai/pull/9131)** — `.ctitle` `white-space: nowrap` → `white-space: normal` + `word-break: break-word`. BEFORE PNG = 4 long titles truncated mid-word (`Order Astarion t…`, `Use Gale's…`, etc.). AFTER PNG = all 4 titles wrap onto 4 readable lines. Both PNGs are ~750 px tall, focused on the planning-block section only.

## When to use

- User-supplied screenshot crops a specific UI section (planning-block, modal, accordion panel, dropdown, toggle group, toast)
- The CSS change is one rule or a small handful of related rules in `mvp_site/frontend_v1/styles/*.css`
- A full-page screenshot would dilute the visual diff — the section is the proof

## When NOT to use

- Full-page layout / theme / responsive change — use the full-page recipe in `wa-visual-proof-playwright`
- Server-side render function fix — use the shim-served HTML recipe in the parent SKILL.md

## The 4-step recipe

### Step 1 — Render the live page to a static HTML fixture

Save the current deployed URL's HTML (with auth bypass) to a fixture file. The worker in this session used `playwright`'s `page.content()` to dump the rendered DOM. The fixture becomes the canonical BEFORE/AFTER input.

```python
import asyncio
from playwright.async_api import async_playwright

async def dump_fixture():
    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True)
        ctx = await browser.new_context(
            viewport={'width': 375, 'height': 812},  # mobile-first
            device_scale_factor=2,
        )
        page = await ctx.new_page()
        # Live URL with the OLD css (before branch push) — capture the bug
        await page.goto(
            'https://mvp-site-app-dev-...run.app/game/<CAMPAIGN_ID>',
            wait_until='domcontentloaded', timeout=30000,
        )
        await page.wait_for_timeout(3000)
        # Wait for the planning-block section to render
        await page.wait_for_selector('.planning-block-choices', timeout=10000)
        with open('/tmp/before.html', 'w') as f:
            f.write(await page.content())
        await browser.close()

asyncio.run(dump_fixture())
```

For the AFTER capture, repeat with the new branch deployed, OR swap the stylesheet via `page.add_style_tag(content=open('/path/to/new.css').read())` BEFORE waiting for the selector (no second deploy needed).

### Step 2 — Section-only screenshot via element selector

Skip `full_page=True`. Use `page.locator('.planning-block-choices').screenshot(...)` to capture just the section. Result: tighter PNG (~750 px tall instead of 3000+ px) and the bug/fix is the only thing visible.

```python
section = page.locator('.planning-block-choices').first
await section.scroll_into_view_if_needed()
await page.wait_for_timeout(300)
await section.screenshot(path='/tmp/ctitle_wrap_proof/before.png')
```

For AFTER (new css inlined via `add_style_tag`):

```python
new_css = open('${HOME}/projects/wt-ctitle-wrap/mvp_site/frontend_v1/styles/planning-blocks.css').read()
await page.add_style_tag(content=new_css)
await page.wait_for_timeout(300)
await section.screenshot(path='/tmp/ctitle_wrap_proof/after.png')
```

### Step 3 — Computed-style verification

In the SAME Playwright session, before & after `add_style_tag`:

```python
ctitle = page.locator('.ctitle').first
before_styles = await ctitle.evaluate('el => { const s = getComputedStyle(el); return { whiteSpace: s.whiteSpace, overflow: s.overflow, textOverflow: s.textOverflow, wordBreak: s.wordBreak } }')
print('BEFORE:', before_styles)
# ['nowrap', 'hidden', 'ellipsis', 'normal']

await page.add_style_tag(content=new_css)
await page.wait_for_timeout(300)
after_styles = await ctitle.evaluate('el => { const s = getComputedStyle(el); return { whiteSpace: s.whiteSpace, overflow: s.overflow, textOverflow: s.textOverflow, wordBreak: s.wordBreak } }')
print('AFTER:', after_styles)
# ['normal', 'visible', 'clip', 'break-word']
```

A delta where `whiteSpace` flips `nowrap → normal` AND `wordBreak` flips `normal → break-word` is the canonical proof of the fix. Embed this delta table in the PR body.

### Step 4 — Vision-verify both PNGs

Use `vision_analyze` on each PNG with a question phrased to surface the diff:

> This is the [BEFORE/AFTER] screenshot of the planning-block section. Are any choice titles truncated with ellipsis (`…`)? Are the full titles visible? Are any wrapping onto multiple lines?

The vision model's caption must mention specific text content from the section — not a generic "looks similar" — for the evidence to be reviewer-actionable. Captions are mandatory per `~/.smartclaw/SOUL.md` `## COMMIT: ui-change-requires-before-after-visual-proof`.

## Where the PNGs go

```
evidence/
├── ctitle_before.png       # the bug — ellipsis truncation
├── ctitle_after.png        # the fix — wrap onto multiple lines
└── ... (per-PR subdirs OK if you do multiple)
```

Commit them inside the worktree branch (NOT as a Git LFS object — these PNGs are tiny, ~100 KB each). Reference in the PR body with `raw.githubusercontent.com` markdown image links so they render inline when the PR is opened:

```markdown
![BEFORE](https://raw.githubusercontent.com/jleechanorg/worldarchitect.ai/<BRANCH>/evidence/ctitle_before.png)
![AFTER](https://raw.githubusercontent.com/jleechanorg/worldarchitect.ai/<BRANCH>/evidence/ctitle_after.png)
```

Per SOUL.md `evidence-attach-not-path-cite`: bare `${HOME}/.../ctitle_before.png` paths render as literal text in the PR view. The `raw.githubusercontent.com` URL is what reviewers see.

## Pitfalls

- **Don't `full_page=True`.** The bug is in a specific section. A full-page screenshot pushes the relevant diff off-screen and inflates the PNG. `page.locator('.section').screenshot()` is the right primitive.
- **Same viewport for BEFORE and AFTER.** If you mix 375×812 (mobile) for BEFORE and 1440×900 (desktop) for AFTER, the comparison is meaningless. Pick ONE viewport — mobile-first is correct for planning-block because that's where the truncation is worst.
- **Wait for the section to render.** `await page.wait_for_selector('.planning-block-choices', timeout=10000)` BEFORE taking the screenshot. On a streaming SPA, the planning-block is emitted after `state_updates.planning_block` arrives — without the wait, the screenshot is empty.
- **`page.add_style_tag` does NOT persist across navigations.** If your AFTER capture does a fresh `goto()`, the inlined style is gone. Either (a) inject the style into the page BEFORE the initial navigation via `page.add_init_script`, or (b) use a branch preview deploy for AFTER (slower but more rigorous), or (c) save the rendered AFTER HTML to a fixture and serve it via the shim pattern in the parent SKILL.md.
- **PNG size hints at diff.** A BEFORE PNG with truncated titles is ~70 KB; an AFTER PNG with wrapped text is ~140 KB (twice the ink = twice the bytes). If they're the same size, the diff probably didn't land — re-run.
- **DON'T use `MEDIA:/abs/path` for Slack uploads.** Per SOUL.md `evidence-attach-presend-gate`, the Slack `MEDIA:` token renders as literal text. Use the 3-stage `files.getUploadURLExternal` recipe (`~/.smartclaw/skills/evidence-attach-to-slack/SKILL.md`) or just embed the `raw.githubusercontent.com` markdown link.

## Reference

- Parent skill: `~/.smartclaw/skills/html-render-visual-proof/SKILL.md` — shim-served HTML recipe for server-side render function fixes.
- Sister skill: `~/.smartclaw/skills/wa-visual-proof-playwright/SKILL.md` — full Flask + browser recipe for JS/CSS UI changes.
- Origin: 2026-08-19, PR `jleechanorg/worldarchitect.ai#9131` — `.ctitle` wrap fix. Branch `fix/ctitle-wrap-closed-state-9130`, commit `1c31019f4f` (fix) + `34a4e01826` (evidence PNGs). Bead `rev-1hkxk`. Issue #9130.