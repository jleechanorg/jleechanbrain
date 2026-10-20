---
name: wa-mobile-ux-regression
version: 1.0.0
description: "Reproduce and fix WA mobile UX bugs via Playwright emulation"
tags: [wa, mobile, regression, playwright, ios, android, css, computed-style, evidence, mobile-emulation]
related_skills: [wa-visual-proof-playwright, wa-live-server-smoke, drive-pr-to-green, wa-frontend-test-guard-scoping]
metadata:
  hermes:
    tags: [wa, mobile, regression, playwright, ios, android, css, computed-style, evidence, mobile-emulation]
    triggers:
      - "android ui issue"
      - "iphone screenshot bug"
      - "mobile ux broken"
      - "button truncated to"
      - "dropdown off screen"
      - "responsive layout broken"
      - "iOS Chrome viewport"
      - "playwright mobile emulation"
---

# WA mobile-UX regression (real-browser repro + computed-style guard)

## When to fire

User reports a UI bug with an iPhone or Android screenshot showing:

- A button or label visually truncated (e.g. "Duplicat" instead of "Duplicate")
- A row clipped against the right edge of the screen
- A dropdown or modal overflowing off-screen
- A flex/grid layout broken on small viewports
- Text wrapping incorrectly, or "nowrap" text overflowing its container
- A page that can be horizontally scrolled when it shouldn't be

Source: 2026-08-20 thread (Slack C0AH3RY3DK6/p1787261209.775249) — three Android screenshots of `worldarchitect.ai` My Campaigns page showing "Duplicat" button truncation, "Last played" date clipping, and theme picker overflow.

## Why the existing toolchain can't catch this alone

`mvp_site/frontend_v1/tests/*.test.js` (node --test, jsdom sandbox) and `mvp_site/tests/test_*.py` (pytest) test against CSS source text or hand-rolled fake DOM. They cannot detect *rendered* layout bugs:

- A CSS rule that exists but doesn't load on the page (e.g. a missing `<link>` in index.html)
- A `flex-shrink: 0` button that gets text-clipped when its container is narrower than the text
- A dropdown that visually overflows but is still in the DOM
- A `white-space: nowrap` element that pushes past its parent's right edge

`wa-visual-proof-playwright` (the existing recipe) does mobile capture but is desktop-default (1400×1100) and only takes screenshots — it has no failure-mode assertion. The bug can render and look fine in PNG but still be broken (e.g. horizontal page overflow only visible when you check `documentElement.scrollWidth`).

This skill adds the **computed-style guard**: the test FAILS RED on the real rendered DOM before the fix, and GREEN after. The PNG is the user-facing evidence; the assertion is the CI gate.

## The 5-step recipe

### Step 1 — Start the local server

```bash
cd ~/repos/jleechanorg/worldarchitect.ai          # or a worktree
PYTHONPATH=. TESTING_AUTH_BYPASS=true python3 mvp_site/main.py serve
# binds 127.0.0.1:8081 by default; picks a random port in 8081-8181 if taken
```

**vpython will fail if `venv/bin/activate` is missing** (the project's venv is often not built). Use system python with PYTHONPATH=. The flask server logs `Development server running: http://localhost:PORT` once ready.

**`TESTING_AUTH_BYPASS` does NOT bypass the Firebase token on `/api/campaigns` POST.** It only relaxes rate limits and CORS. Mobile fixtures that need a real campaign row MUST use synthetic DOM injection (Step 3), not API-based creation.

### Step 2 — Choose the right viewport

Match the user's device. The breakpoint that triggers `@media (max-width: 575.98px)` on the WA frontend is ~576px CSS, so 393-412px is the sweet spot for catching mobile-only CSS bugs:

| Device | viewport | dsf | is_mobile | user_agent |
|---|---|---|---|---|
| iPhone 14 Pro (matches the user's screenshots) | 393×852 | 3 | true | `Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 ...)` |
| Pixel 7 (closest to user Android phone) | 412×915 | 2.625 | true | `Mozilla/5.0 (Linux; Android 13; Pixel 7) ...` |
| iPhone 14 Pro Max | 430×932 | 3 | true | iPhone 14_5 UA |
| Galaxy S22 | 360×780 | 3 | true | SM-S901B UA |

Playwright's `new_context()` REQUIRES nested `viewport` + `screen` dicts, NOT flat width/height. The flat form silently fails with `TypeError: got unexpected keyword argument 'width'`.

### Step 3 — Build the fixture: synthetic DOM injection

The dashboard view (`#dashboard-view`) is hidden by default. Three CSS gates must be lifted in the injected DOM, in this order:

```js
// All three are required; missing any one leaves the element hidden.
document.body.classList.remove('is-logged-out');          // body gate (style.css:28)
document.querySelectorAll('.active-view')
  .forEach(v => v.classList.remove('active-view'));        // view toggle
document.getElementById('dashboard-view')
  ?.classList.add('active-view');                          // target view

const list = document.getElementById('campaign-list');    // canonical target
const row = document.createElement('div');
row.className = 'list-group-item';
row.setAttribute('data-campaign-id', 'synthetic-1');
row.innerHTML = `
  <div class="d-flex flex-column flex-sm-row w-100
              justify-content-sm-between align-items-sm-center
              campaign-list-header">
    <h5 class="mb-2 mb-sm-0 text-break">
      <span class="campaign-title-text campaign-title-link">Dragon Knight</span>
    </h5>
    <div class="d-flex align-items-center flex-shrink-0
                campaign-list-actions mt-1 mt-sm-0">
      <button class="btn btn-sm btn-outline-primary
                     edit-campaign-btn me-2">Edit</button>
      <button class="btn btn-sm btn-outline-secondary
                     duplicate-campaign-btn me-2">Duplicate</button>
      <small class="text-muted text-nowrap">
        Last played: 20/08/2026, 22:05:28
      </small>
    </div>
  </div>`;
list.appendChild(row);
```

This mirrors exactly what `renderCampaignListUI()` in `mvp_site/frontend_v1/app.js:3006` produces. Do NOT paste the user's real Firebase UID into the test — keep the row anonymous so it never collides with prod data.

### Step 4 — Write the regression test (computed-style assertions)

The test MUST be a real Playwright script, not a node --test regex. The assertions check the *rendered* DOM, not source text:

```python
def assert_no_bug_a(page):
    """BUG A: 'Duplicate' button text is clipped."""
    info = page.evaluate("""() => {
        const btn = document.querySelector('.duplicate-campaign-btn');
        if (!btn) return {found: false};
        const r = btn.getBoundingClientRect();
        const cs = getComputedStyle(btn);
        return {
            found: true,
            text: btn.textContent.trim(),
            scrollWidth: btn.scrollWidth,
            clientWidth: btn.clientWidth,
            textOverflow: cs.textOverflow,
            overflow: cs.overflow,
            whiteSpace: cs.whiteSpace,
            rect: {right: r.right, width: r.width, height: r.height},
        };
    }""")
    if info["scrollWidth"] > info["clientWidth"] + 1:
        return {"bug_a": "FAIL", "evidence": info}    # text clipped
    return {"bug_a": "PASS", "evidence": info}
```

Three additional checks belong in the same test:

1. **Text inside element clipped**: `el.scrollWidth > el.clientWidth + 1` (the 1px slop handles sub-pixel rounding).
2. **Element right edge past viewport**: `el.getBoundingClientRect().right > window.innerWidth + 1`.
3. **Page itself has horizontal overflow**: `document.documentElement.scrollWidth > window.innerWidth + 1` — the root-cause check; even if individual elements pass, page-level overflow means the navbar/dropdown will clip when the user scrolls right.

The three checks together catch the bug *class* (mobile responsive layout), not just one symptom.

### Step 5 — Capture BEFORE PNG, apply fix, capture AFTER PNG

```python
# In Playwright:
page.screenshot(path="/tmp/evidence/BEFORE.png", full_page=False)
# After fix:
page.screenshot(path="/tmp/evidence/AFTER.png", full_page=False)

# Tight crop of the buggy element (better than full-page for PR review):
row = page.query_selector('.list-group-item[data-campaign-id]')
row.screenshot(path="/tmp/evidence/BEFORE_zoom.png")
```

Then `vision_analyze` both PNGs with a specific question:
- "Is the word 'Duplicate' fully visible inside the button, or is it truncated?"

Vision description must match the assertion. If `vision_analyze` reports "Du is visible" but the assertion says PASS, one of them is wrong — re-check.

Commit the PNGs under `evidence/<branch-name>/` and embed in the PR body via:
```markdown
![BEFORE: Duplicate truncated to Du](https://github.com/jleechanorg/worldarchitect.ai/blob/<branch>/evidence/BEFORE_zoom.png?raw=true)
```

Bare file paths do not render in GitHub PR view. The `?raw=true` is required.

## Common pitfalls

### TESTING_AUTH_BYPASS does not bypass `/api/campaigns` POST

`/api/campaigns` requires a Firebase ID token even with the bypass env var set. The bypass only relaxes rate limits and adds `X-Test-Bypass-Auth` CORS headers. **Do NOT call `page.request.post('/api/campaigns', ...)` and expect 200.** Use synthetic DOM injection instead.

### `vpython` not found

The venv at `~/repos/jleechanorg/worldarchitect.ai/venv/` is often not built. `vpython` will exit 1 with "activate script not found." Two recovery options:

1. **Use system python** (the skill's current default): `PYTHONPATH=. python3 mvp_site/main.py serve`. Works for ad-hoc smoke tests but doesn't bind to a known port for Playwright.
2. **Symlink the uv-managed venv** (preferred for repeatable captures): `uv sync` creates `.venv/`, but `run_test_server.sh` does `source venv/bin/activate` and aborts with `Virtual environment not found at venv/bin/activate`. Fix in one line:
   ```bash
   mkdir -p venv && ln -sf ../.venv/bin venv/bin
   ```
   Then `./run_test_server.sh start` works and binds to a deterministic port the Playwright script can target. Always `kill -9 $(cat /tmp/worldarchitect.ai/<branch>/test-server.pid)` before re-running `start` if it complains "Server is already running" — the PID file isn't auto-cleared on signal exit.

### Playwright viewport dict shape

`browser.new_context(width=393, height=852)` fails with `TypeError: got unexpected keyword argument 'width'`. The viewport is a nested dict:

```python
ctx = browser.new_context(
    viewport={"width": 393, "height": 852},
    screen={"width": 393, "height": 852},
    device_scale_factor=3,
    is_mobile=True,
    has_touch=True,
    user_agent="Mozilla/5.0 (iPhone; ...)",
)
```

### Dashboard view hidden by default

`#dashboard-view` is gated by THREE CSS rules: `body.is-logged-out #dashboard-view { display: none; }` (style.css:28-33), the `[id]-view { display: none; }` default (style.css:325-331), and the `.active-view` toggle. Removing only `.is-logged-out` is not enough — the view itself must have `.active-view` and the auth view must not.

### `wait_for_selector` timeout when element is "hidden"

Playwright's default `wait_for_selector` waits for visibility, not attachment. The injected `.campaign-list-actions` exists in the DOM but is hidden because its parent is. Use `wait_for_selector(..., state='attached')` if the gate hasn't been lifted yet, or lift all three gates FIRST then wait normally.

### `clientWidth` reports 0 for inline elements

A `<span>` or unstyled inline element has `clientWidth: 0`. The bug only manifests on the actual button element because of `display: inline-block` from Bootstrap's `.btn`. Always check `el.tagName === 'BUTTON'` (or a similar block-level element) before measuring.

### PNG embedding format

GitHub PR markdown needs `?raw=true` to render the image. Without it the user sees a broken link:

```markdown
✅ ![caption](https://github.com/OWNER/REPO/blob/BRANCH/path.png?raw=true)
❌ ![caption](https://github.com/OWNER/REPO/blob/BRANCH/path.png)
❌ ![caption](${HOME}/path.png)            # never renders
❌ ![caption](./evidence/BEFORE.png)               # relative paths don't work cross-fork
```

### Heroic ambition trap

If the user reports 3+ mobile bugs, fix them as ONE PR with a per-bug assertion. Do NOT split into one PR per bug — the regression test file is shared infrastructure and the BEFORE/AFTER evidence is in the same visual context. Three bugs in one PR is fine; three PRs is process overhead.

### Wizard step-2 summary layout bug: when "fix the layout" is wrong, "delete the recap row" is right

If the broken row is a **recap of a value the user already entered on a previous wizard step** (e.g. Step 2 Summary card showing "Campaign description prompt (optional):" echoing the free-text textarea from Step 1), the operator's preferred fix is **delete the row entirely**, not CSS-tweak the label width. Recap rows whose source field is optional and already user-controlled are noise on the summary screen — the user has nothing new to learn from seeing it again.

Verified 2026-08-25, PR #9367 (user Slack message: *"It should just hide the campaign description prompt and summarize choices from last page"*). Symptom pattern: `<strong>` label is a direct flex child of `.editable-preview`, long label wraps to 3+ lines and squeezes `.preview-value { flex: 1 }` into a 1-char column. The right answer was: remove the row, do NOT shrink the label or stack label-above-value at narrow widths (those preserve the recap that the operator doesn't want).

When the operator's preferred fix is row-removal, the safe edit is:
1. Delete the HTML block from `mvp_site/frontend_v1/js/campaign-wizard.js` (most wizard markup lives in a JS template literal, NOT in `index.html`).
2. Verify the JS code that references the deleted node guards with `if (element)` / `?.` — most WA wizard code does, so the change is a safe no-op.
3. Search for tests/docs referencing the deleted `#id` and either delete the test step or update the doc.

The reusable capture script for this class is at **`scripts/capture_wizard_step2_mobile.py`** — drop-in, mobile viewport 390×844 built in, clicks Next exactly once, dumps `{label}.png` (full-page) and `{label}_card.png` (card-only tight crop) plus a DOM probe (`desc_value_width_px` is the quantitative collapse number for the PR description).

### JS template-literal HTML comments: NO backticks inside the comment

The WA wizard HTML lives in a JS template literal (`return \`...\``). A `<!-- ... -->` HTML comment INSIDE that template literal that contains backticks (`\``) silently breaks the JS file — the first backtick ends the template literal early and the file becomes a SyntaxError. Symptom: `node -e "new Function(require('fs').readFileSync('campaign-wizard.js','utf8'))"` returns `SyntaxError: Unexpected token 'if'` (or wherever the first non-string content lands).

Avoidance: never put backticks or `${...}` inside HTML comments embedded in JS template literals. Phrase the comment without code-fence backticks:
```js
return `... <!-- span guards with a null-check, ... --> ...`;
```
This is a recurring foot-gun specifically because the SKILL recipe says "leave a comment explaining why" — the comment is the trap.

### Mobile capture needs a mobile viewport

If the user reports the bug from a phone screenshot (the iOS Safari / Android Chrome status bar is visible, or the URL bar is showing the iOS-style `…v-i6xf2p72ka-uc.a.run.app` truncation), capture at 390×844 / `is_mobile=True` / `device_scale_factor=2` / iPhone user-agent — NOT the desktop 1400×1100 the original `wa-visual-proof-playwright` recipe defaults to. Mobile flex / `flex-shrink` / `white-space: nowrap` bugs only reproduce at phone widths. Use:
```python
ctx = await browser.new_context(
    viewport={"width": 390, "height": 844},
    device_scale_factor=2,
    is_mobile=True,
    has_touch=True,
    user_agent="Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) ...",
)
```

### Wizard step targeting: don't blindly click "Next" 3×

The original `wa-visual-proof-playwright` recipe clicks `button:has-text('Next')` in a 3-iteration loop. That works for the launch/quickstart flow but lands on Step 3 / 4 / "Review" depending on how many fields are required. For Step-2-summary bugs, click Next **exactly once** and assert `.campaign-preview .preview-item` is present:
```python
await page.click('div.campaign-type-card[data-type="custom"]')
await page.wait_for_timeout(600)
await page.locator("button:has-text('Next')").first.click()
await page.wait_for_timeout(1500)
await page.wait_for_selector(".campaign-preview .preview-item", timeout=10000)
```
Then screenshot `.campaign-preview` directly (it's a card-sized element, not a full-page artifact):
```python
await page.locator(".campaign-preview").scroll_into_view_if_needed()
await page.locator(".campaign-preview").screenshot(path="BEFORE_card.png")
```
Card-only screenshots are sharper evidence for PR review than full-page 390×844 PNGs that show 80% background.

### Evidence Gate freshness trap (the WA PR gauntlet)

The repo's `Evidence Bundle Validation` GH workflow checks `metadata.json` SHA against `HEAD`. **Every new commit invalidates the bound.** Three concrete pitfalls when you push a follow-up commit (e.g. test rename or docs/evidence/ map) after the Evidence Gate has already passed once:

1. The gate's Check 7 fails with `STALE — captured at <old_sha>, HEAD is <new_sha>`. Fix: update `metadata.json`'s `git_provenance.git_head` to the new HEAD and re-trigger.
2. `gh gist edit <id> --add <file>` (and `--replace`) **silently does nothing** — exits 0 but raw URLs all show the OLD content. Always `gh gist delete <id> -y && gh gist create ...` to actually replace content.
3. Pushing a new commit doesn't auto-restart all CI checks; jobs that passed on a previous commit stay PASS, jobs that were SKIPPED stay SKIPPED, jobs that were IN_PROGRESS get CANCELLED. To wake the Evidence Gate after fixing the metadata: `git commit --allow-empty -m "ci: re-trigger Evidence Gate after metadata refresh" && git push`.

The full drive-to-green recipe (gist creation, `validate_pr_evidence.sh` claim_artifact_map.md + media requirement, Codex review patterns, libx264 even-pixel-dim trick for the MP4) is in `references/wa-pr-ci-gauntlet-2026-08-20.md`.

### `libx264` requires even pixel dimensions

iPhone screenshots come out at `1179x2556` (odd width — dsf=3 × 393). `ffmpeg -c:v libx264` errors out with `width not divisible by 2`. Apply `scale=trunc(iw/2)*2:trunc(ih/2)*2:flags=lanczos` BEFORE the format conversion. Burned-in captions go through `drawtext=text='<caption>':fontcolor=white:fontsize=24:box=1:boxcolor=black@0.75:boxborderw=12:x=(w-text_w)/2:y=h-50` so each frame carries its own label.

### Codex review: state=COMMENTED, not CHANGES_REQUESTED

`chatgpt-codex-connector[bot]` posts inline review comments at P1/P2 priority but submits with `state=COMMENTED` — it does NOT block the merge directly. Don't waste cycles trying to "dismiss" or "fix" Codex comments; resolve them by addressing the underlying issue (move test to `core_tests/`, add `TEST_BASE_URL` support, attach SHA-bound video) and the next push's diff will make them stale.

### Fixture text MUST reproduce the user's exact screenshot text

When the user provides a screenshot showing clipped/cut text (e.g. "1d20+2 = 4 vs DC 10 – Failure (Persuading Samwise to bolster his willpower)" with the closing paren clipped), the capture-script fixture MUST use that **exact string** — paraphrasing or shortening loses the visual evidence of the bug.

Two failure modes from skipping this (PR #9368, 2026-08-25):

1. **Test fixture too short → no visible clipping → BEFORE/AFTER PNGs look identical.** A 2-line fixture with short labels fits comfortably inside the natural panel height in both states, so the `getComputedStyle().minHeight` delta is real but the PNG diff is invisible. Vision-analyze confirms "the AFTER shows the text fully visible" — but so does the BEFORE. The PR ships with weak evidence and the operator sees no visual change in review.
2. **`ls -la` shows identical file sizes for the two PNGs** because the test rendered both states against the same short fixture; only metadata differs, not pixels. `shasum -a 256` distinguishes them but the content is functionally the same.

**Rule:** when fixing a "this gets clipped" bug, the fixture must be **at least as long as the worst-case content the user reported**. For the dice-rolls panel, the worst case was a single `<li>` containing the full failure-roll description. For "Duplicate button truncation," it's a button label that genuinely overflows at the narrowest viewport. For "Last played clipping," it's a date string plus actions row.

**Verification gate** before opening the PR:

```bash
# 1. Confirm PNG diff is in the panel you changed, not just metadata
python3 -c "
from PIL import Image, ImageChops
a = Image.open('BEFORE.png'); b = Image.open('AFTER.png')
diff = ImageChops.difference(a, b)
bbox = diff.getbbox()
print('diff bbox:', bbox)
import numpy as np
nz = (np.array(diff).sum(axis=2) > 0).sum()
print(f'nonzero diff pixels: {nz}')
"
# Expected: bbox covers the panel under test, >>10000 nonzero pixels.

# 2. vision_analyze both PNGs with a question that distinguishes the two states.
#    e.g. "Is '(Persuading Samwise to bolster his willpower)' fully visible
#    inside the green panel, or clipped at the bottom edge?"
#    If both answers say "fully visible," the fixture is too short — fix it
#    and re-capture before opening the PR.
```

**Reproduction:** after the worker delivered PR #9368 with weak evidence (BEFORE = AFTER visually identical), the script `evidence/dice_rolls_mobile_50_taller/capture.py` was rewritten to inject the user's exact screenshot text into a single `<li>`, which then produced a real `offsetHeight: 91px → 140px = 1.538×` delta with vision-verified visual diff (BEFORE shows text at panel bottom edge with no breathing room; AFTER shows text mid-panel with ~50px of breathing room). PR #9368 was force-pushed with the stronger evidence and the operator-facing review no longer had to trust the `capture_meta.json` numbers.

### Static-file:// CSS-rule harness — no Flask server needed

For **CSS-only** mobile fixes (the rule is added to `style.css`, no JS or HTML changes), the Playwright capture does NOT need a running Flask server, Firebase auth, or synthetic-DOM-injection gymnastics. Build a static `file://` HTML harness that:

1. Embeds a minimal copy of the production element markup (the panel under test + adjacent panels for visual context).
2. Reads the real `style.css` from the worktree via `Path("/path/to/worktree/mvp_site/frontend_v1/style.css").read_text()`.
3. Extracts the mobile `@media (max-width: 575.98px) { ... }` block with `re.search(r"@media \(max-width: 575\.98px\) \{(.*?)\n\}\n", css, re.DOTALL)`.
4. Locates the specific rule under test (e.g. `.dice-rolls { min-height: ... }`) via `re.search`.
5. Toggles the rule in/out of the harness HTML — present for AFTER, stripped for BEFORE.
6. Loads `file://<harness>.html` in two Playwright contexts at the target mobile viewport (393×852, dsf=2, `is_mobile=True`, iPhone UA).

This avoids the cascade of `vpython`/`TESTING_AUTH_BYPASS`/Firebase-token headaches from the full Flask-server path and produces a deterministic, reproducible, serverless capture. Reusable template: **`templates/capture_css_only_mobile.py`** (built for PR #9368 — drop in, change the element selector and the rule regex, run).

### Local `validate_pr_evidence.sh` requires PR-local files for `mvp_site/` PRs

The repo script `scripts/validate_pr_evidence.sh <PR_NUMBER>` runs in CI as part of the gate work and fails (exit 1) for any PR whose `git diff origin/main...HEAD -- mvp_site/` is non-empty UNLESS the branch has BOTH `docs/evidence/pr-<N>/claim_artifact_map.md` AND a `.cast`/`.gif`/`.mp4` media artifact in that directory, both tracked in git. Create them as part of opening the PR, not after — pushing them in a second commit means the gate runs against the initial commit and fails on the first try.

## When NOT to use this skill

- Pure CSS source-text changes (no rendered layout impact) — use `wa-pr-css-contract-load-verification` style regex checks instead.
- Desktop-only UI bugs — skip the mobile viewport and assertion; use the desktop recipe in `wa-visual-proof-playwright`.
- Server-side LLM wire-shape bugs — use `wa-live-server-smoke` (Step 2 wire-shape test).
- LLM output emission bugs (`dice_rolls: []`, missing `action_resolution`) — use `wa-llm-output-emission-false-green-watchdog`.

## Reference

For the originating case (2026-08-20 PR #9178 "fix(my-campaigns): mobile UX — Duplicate button + theme dropdown overflow"), the full diagnosis walkthrough — including the test file, three-step CSS fix, BEFORE/AFTER PNG pairs, and PR URL — is in `references/pr-9178-originating-case.md`.

For the **drive-to-green mechanics** AFTER the PR is open (Evidence Gate freshness trap, `validate_pr_evidence.sh` claim_artifact_map + media requirements, Codex `chatgpt-codex-connector[bot]` review patterns, `--allow-empty` commit trick to re-trigger, `gh gist edit` is broken so DELETE+recreate) — read `references/wa-pr-ci-gauntlet-2026-08-20.md` BEFORE you declare the PR mergeable.

The reusable regression-test template is at `templates/test_my_campaigns_mobile_ux_regression.py`. Copy it, change the selectors + bug names, run.

For **CSS-only** mobile fixes where the rule lives inside `@media (max-width: 575.98px)`, the serverless capture template is at `templates/capture_css_only_mobile.py` — toggle the rule in/out of a static `file://` HTML harness, no Flask/Firebase needed. See the **Static-file:// CSS-rule harness** pitfall below for the full pattern.
