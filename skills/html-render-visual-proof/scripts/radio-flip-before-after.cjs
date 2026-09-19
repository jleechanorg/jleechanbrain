// Screenshot a single radio toggle row BEFORE/AFTER a patch flips it.
// Start from this template: replace the page URL, the selector for the
// radio group, and the patched-block mirror inside `page.evaluate(...)`.
//
// Verified 2026-08-19 on jleechanorg/worldarchitect.ai PR #9134 (mode-radio
// auto-flip after think submit). Use the in-DOM reveal recipe in
// `references/local-worktree-server-and-in-dom-reveal.md` to handle
// elements hidden by auth gating + opacity:0.

const fs = require('fs');

const playwright = require('/opt/homebrew/lib/node_modules/@playwright/mcp/node_modules/playwright/index.js');
const { chromium } = playwright;

const OUT = '/tmp/wa-feat-auto-char/evidence';
const BASE_URL = process.env.WA_URL || 'http://127.0.0.1:8188/';
fs.mkdirSync(OUT, { recursive: true });

(async () => {
  const browser = await chromium.launch({
    headless: true,
    args: ['--no-sandbox', '--disable-dev-shm-usage'],
  });
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 700 }, deviceScaleFactor: 2 });
  const page = await ctx.newPage();
  page.on('pageerror', (err) => console.log('  pageerror:', String(err).slice(0, 200)));

  await page.goto(BASE_URL, { waitUntil: 'networkidle' });
  await page.waitForTimeout(700);

  // ---- 1. Reveal the off-screen element -------------------------------
  // Edit the selector + reveal block to match the element under test.
  await page.evaluate(() => {
    const game = document.getElementById('game-view');
    if (game) { game.style.opacity = '1'; game.style.transform = 'none'; }
    const tg = document.querySelector('div[role="radiogroup"]'); // ← EDIT ME
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

  // ---- 2. Helper: restyle the active pill -----------------------------
  const stylePills = (activeId, labels) => page.evaluate((args) => {
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
  }, { activeId, labels });

  const labels = ['char-mode', 'think-mode', 'god-mode']; // ← EDIT ME

  // ---- 3. BEFORE ------------------------------------------------------
  await page.evaluate(() => {
    const r = document.getElementById('think-mode'); // ← EDIT ME for which radio starts checked
    r.checked = true;
    r.dispatchEvent(new Event('change', { bubbles: true }));
  });
  await stylePills('think-mode', labels);
  await page.waitForTimeout(150);
  await page.screenshot({ path: `${OUT}/before-submit.png`, fullPage: false });

  // ---- 4. AFTER — mirror the patched block ----------------------------
  await page.evaluate(() => {
    // Paste the EXACT logic from app.js (or equivalent surface) here.
    const charModeRadio = document.getElementById('char-mode'); // ← EDIT ME for the new radio
    if (charModeRadio && !charModeRadio.checked) {
      charModeRadio.checked = true;
      charModeRadio.dispatchEvent(new Event('change', { bubbles: true }));
    }
  });
  await stylePills('char-mode', labels);
  await page.waitForTimeout(150);
  await page.screenshot({ path: `${OUT}/after-submit.png`, fullPage: false });

  await browser.close();
  console.log('  evidence written to', OUT);
})().catch((err) => {
  console.error('  fatal:', err);
  process.exit(1);
});
