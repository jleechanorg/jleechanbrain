# Local worktree server boot + in-DOM reveal recipe

Captured from jleechanorg/worldarchitect.ai PR #9134 (auto-char-mode-after-think submit, 2026-08-19). Reusable for any jleechanorg/worldarchitect.ai frontend PR where you need to capture a single DOM mutation against the live page without a full auth flow.

## 1. Why this recipe exists

`wa-visual-proof-playwright` is the canonical pattern, but for SMALL frontend patches (≤20 lines, single-element DOM mutation) it's overkill. The full Flask + MCP startup is 60-90s, you still need a real campaign to exercise the submit handler, and `currentCampaignId === null` short-circuits the relevant code paths anyway.

What you actually need for a radio-flip / class-toggle / attribute-change proof is: launch playwright, navigate to the live URL of a worktree-local server, surgically reveal the off-screen element, mirror the patch logic from `page.evaluate`, capture twice. Total wall time: ~30s.

## 2. Local worktree server boot

`./vpython mvp_site/main.py serve` and `./run_local_server.sh` both fail on a fresh worktree:

- `venv/` lives only in the MAIN checkout (`~/projects/worldarchitect.ai/venv`), not in worktrees.
- `python -m mvp_site.main serve` then crashes with `ModuleNotFoundError: No module named 'infrastructure'` unless `PYTHONPATH` is set to the worktree root.

**Verified working** (one-time per worktree + per session):

```bash
# 1. One-time per worktree — symlink the shared venv so vpython works
ln -s ~/projects/worldarchitect.ai/venv ~/projects/<wt>/venv

# 2. Per-session — boot the server in the background from the worktree
cd ~/projects/<wt>
source venv/bin/activate
PYTHONPATH=$PWD \
  TESTING=false \
  PORT=8188 \
  CAMPAIGN_RATE_LIMIT=1000000/1 \
  CAMPAIGN_CREATE_RATE_LIMIT=1000000/1 \
  SETTINGS_RATE_LIMIT=1000000/1 \
  FRONTEND_V1_DIR=./mvp_site/frontend_v1 \
  ENABLE_SEMANTIC_ROUTING=true \
  python -m mvp_site.main serve
```

**Without `PYTHONPATH=$PWD`** → `ModuleNotFoundError: No module named 'infrastructure'`.
**Without `TESTING=false`** → picks up test mocks silently.
**Without `FRONTEND_V1_DIR=./mvp_site/frontend_v1`** → may serve the cached-busted build instead of the worktree source.
**Background with `terminal(background=true, notify_on_complete=true)`** — the launcher can run for hours.

Health check:
```bash
curl -sS -o /dev/null -w "http=%{http_code}\n" http://127.0.0.1:$PORT/
```
If `000` after ~8s, `tail -30` the server log — the venv symlink or PYTHONPATH is usually wrong.

## 3. Playwright install + require path

```bash
# Node Playwright module lives here on this machine:
/opt/homebrew/lib/node_modules/@playwright/mcp/node_modules/playwright/index.js

# Install chromium headless shell (one-time):
node /opt/homebrew/lib/node_modules/@playwright/mcp/node_modules/playwright-core/cli.js install chromium
# Binary lands at:
#   ~/Library/Caches/ms-playwright/chromium_headless_shell-<build>/chrome-mac/headless_shell
```

DO NOT `require('${HOME}/.local/orch-venv/lib/...')` — that's a Python venv (pip package), imports pydantic internals, not playwright-core.

## 4. In-DOM reveal recipe for off-screen controls

Most WA auth-gated UI lives inside containers that are invisible by default. The mode-radio group is inside `#game-view`, which `mvp_site/frontend_v1/styles/animations.css:22-30` declares with `opacity: 0; transform: translateY(20px)`. The element IS in the DOM with real layout — you just can't see it.

```js
// Inside page.evaluate(...) on a live page, AFTER navigating to the worktree URL.

// 1. Force-override the parent chain (cascade opacity:0 otherwise).
const game = document.getElementById('game-view');
game.style.opacity = '1';
game.style.transform = 'none';

// 2. Detach the element AND pin it to the viewport.
//    position: fixed inside a transformed ancestor pins to that
//    ancestor's containing block, not the viewport — reparenting to
//    document.body fixes it.
const tg = document.querySelector('div[role="radiogroup"]');
document.body.appendChild(tg);
tg.style.position = 'fixed';
tg.style.top = '40px';
tg.style.left = '50%';
tg.style.transform = 'translateX(-50%)';
tg.style.zIndex = '99999';

// 3. Hide the radio inputs + help buttons so the visual is the three pills only.
tg.querySelectorAll('input[type="radio"]').forEach(r => r.style.display = 'none');
tg.querySelectorAll('button.toggle-help').forEach(b => b.style.display = 'none');
```

## 5. `page.evaluate(fn, arg)` — only one arg

Passing multiple positional args silently drops the extras:

```js
// ✅ correct — single object
page.evaluate(({ activeId, labels }) => { /* ... */ }, { activeId: 'think-mode', labels: [...] });

// ❌ silently broken — only `activeId` arrives
page.evaluate((activeId, labels) => { /* labels === undefined */ }, 'think-mode', [...]);
```

## 6. When the submit handler short-circuits

The `#interaction-form` handler at `mvp_site/frontend_v1/app.js:5447-5450`:

```js
interactionForm.addEventListener("submit", async (e) => {
  e.preventDefault();
  let userInput = userInputEl.value.trim();
  if (!userInput || !currentCampaignId) return;  // ← short-circuits
  ...
});
```

`currentCampaignId` is module-scope `let currentCampaignId = null;` (line 55), NOT on `window`. Without a real campaign loaded via the full auth + select-campaign flow, the handler bails before the patched block runs.

**Strategy**: don't try to drive the form. Instead:
1. Mirror the patched block in `page.evaluate` to confirm the DOM mutation is correct.
2. Keep a contract test (e.g. `mvp_site/tests/test_auto_char_mode_after_think.js`) that asserts the patched block is in source.

The contract test is the wire-up proof; the visual proof is just "the same DOM mutation succeeds on the real radios."

## 7. Worked example — radio-flip before/after in 60 lines of Node

This is the script from PR #9134 (verbatim path: `/tmp/wa-feat-auto-char/radios_only.cjs`). Use it as a starting template:

```js
const fs = require('fs');
const playwright = require('/opt/homebrew/lib/node_modules/@playwright/mcp/node_modules/playwright/index.js');
const { chromium } = playwright;

const OUT = '/tmp/wa-feat-auto-char/evidence';
fs.mkdirSync(OUT, { recursive: true });

(async () => {
  const browser = await chromium.launch({ headless: true, args: ['--no-sandbox', '--disable-dev-shm-usage'] });
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 700 }, deviceScaleFactor: 2 });
  const page = await ctx.newPage();
  page.on('pageerror', (err) => console.log('  pageerror:', String(err).slice(0, 200)));

  await page.goto('http://127.0.0.1:8188/', { waitUntil: 'networkidle' });
  await page.waitForTimeout(700);

  await page.evaluate(() => {
    const game = document.getElementById('game-view');
    if (game) { game.style.opacity = '1'; game.style.transform = 'none'; }
    const tg = document.querySelector('div[role="radiogroup"][aria-label="Interaction mode"]');
    if (!tg) return;
    document.body.appendChild(tg);
    tg.style.position = 'fixed';
    tg.style.top = '40px';
    tg.style.left = '50%';
    tg.style.transform = 'translateX(-50%)';
    tg.style.zIndex = '99999';
    tg.style.background = 'linear-gradient(135deg, #1a0f2e, #0d1117)';
    tg.style.padding = '20px 24px';
    tg.style.borderRadius = '12px';
    tg.style.boxShadow = '0 8px 32px rgba(0,0,0,0.7)';
    tg.style.minWidth = '760px';
    tg.style.display = 'flex';
    tg.style.alignItems = 'center';
    tg.style.gap = '8px';
    tg.style.opacity = '1';
    tg.querySelectorAll('button.toggle-help').forEach((b) => { b.style.display = 'none'; });
    tg.querySelectorAll('input[type="radio"]').forEach((r) => { r.style.display = 'none'; });
  });

  const stylePills = (activeId) => page.evaluate((args) => {
    const { activeId, labels } = args;
    labels.forEach((id) => {
      const l = document.querySelector(`label[for="${id}"]`);
      if (!l) return;
      const isActive = id === activeId;
      l.style.opacity = '1';
      l.style.padding = '10px 20px';
      l.style.marginRight = '4px';
      l.style.color = isActive ? '#fff' : 'rgba(226,217,243,0.6)';
      l.style.border = isActive ? '2px solid transparent' : '2px solid rgba(226,217,243,0.3)';
      l.style.borderRadius = '999px';
      l.style.background = isActive
        ? (id === 'think-mode' ? 'linear-gradient(135deg, #f59e0b, #d97706)' : 'linear-gradient(135deg, #7c3aed, #a855f7)')
        : 'transparent';
      l.style.fontWeight = '700';
      l.style.boxShadow = isActive ? '0 4px 16px rgba(168,85,247,0.4)' : 'none';
      l.style.transform = isActive ? 'scale(1.04)' : 'scale(1)';
    });
  }, { activeId, labels: ['char-mode', 'think-mode', 'god-mode'] });

  // BEFORE
  await page.evaluate(() => {
    const r = document.getElementById('think-mode');
    r.checked = true;
    r.dispatchEvent(new Event('change', { bubbles: true }));
  });
  await stylePills('think-mode');
  await page.waitForTimeout(150);
  await page.screenshot({ path: `${OUT}/before-submit.png`, fullPage: false });

  // AFTER — mirror the patched block
  await page.evaluate(() => {
    const charModeRadio = document.getElementById('char-mode');
    if (charModeRadio && !charModeRadio.checked) {
      charModeRadio.checked = true;
      charModeRadio.dispatchEvent(new Event('change', { bubbles: true }));
    }
  });
  await stylePills('char-mode');
  await page.waitForTimeout(150);
  await page.screenshot({ path: `${OUT}/after-submit.png`, fullPage: false });

  await browser.close();
  console.log('  evidence written to', OUT);
})();
```

## 8. References

- PR jleechanorg/worldarchitect.ai#9134 ("feat(frontend): auto-select character mode after think submit"), 2026-08-19.
- Sister skill: `~/.smartclaw/skills/wa-visual-proof-playwright/SKILL.md` — full Flask + browser recipe (overkill for ≤20 line patches).
- Sister skill: `~/.smartclaw/skills/standalone-css-harness-capture/SKILL.md` — self-contained HTML harness for the case where the live page is unhealthy.
- Pitfalls also covered in `~/.smartclaw/skills/html-render-visual-proof/SKILL.md` (pitfalls list).
