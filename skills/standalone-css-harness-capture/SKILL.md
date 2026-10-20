---
name: standalone-css-harness-capture
version: 1.0.0
description: "Capture before/after screenshots of a CSS change by rendering a self-contained HTML harness that inlines the real stylesheet contents, bypassing the live Flask+MCP path. Use when the live-server capture (full Quick Start -> /game/<id> flow) is broken: MCP server unhealthy, CORS preflight blocking X-Test-Bypass-Auth on /api/* routes, or rate-limit / deploy blocks the test bypass header."
tags: ["evidence", "playwright", "css", "visual-proof", "worldarchitect"]
category: software-development
triggers:
  - "standalone harness"
  - "inline CSS capture"
  - "capture_planning_block_only"
  - "MCP unhealthy capture fallback"
  - "CORS preflight blocking X-Test-Bypass-Auth"
related_skills:
  - wa-visual-proof-playwright
  - inline-attach-evidence
allowed-tools:
  - Read
  - Write
  - Bash
context: inline
---

# Standalone CSS Harness Capture

**When**: Live-server capture fails (MCP server unhealthy, CORS preflight on `/api/*` blocks `X-Test-Bypass-Auth`, or test bypass env not propagated). The full app path through Quick Start → `/game/<id>` requires both Flask AND MCP healthy; if either fails, fall back to a self-rendering HTML harness that loads the real stylesheet contents inline.

**Don't do**: Drive a fake HTML mockup that doesn't load the real CSS — the probe JSON may claim correct values, but the screenshot is meaningless because the rule never resolved. The harness MUST inline the real `planning-blocks.css` (or equivalent) file contents.

## The recipe (verified 2026-08-18, PR #9070 v2)

1. **Read the real CSS file** — `pathlib.Path(...).read_text()` against `mvp_site/frontend_v1/styles/<file>.css`. Don't fetch via `<link>` because Chromium `file://` + cross-origin CSS blocks `cssRules` access on Playwright evaluate().

2. **Build a self-contained HTML harness** — inline the CSS in a `<style>` block, render the exact DOM shape the production code emits (for `.choice-row[data-risk]`, that's `<div class="choice-row" data-risk="X"><div class="choice-head"><button class="choice-button choice-select risk-X"><span class="ctitle">...</span></button></div></div>`).

3. **Toggle the CSS rule via inline `<style>` override** for the `before` label (e.g. `.choice-row[data-risk] { border-left: none !important; background-color: transparent !important; }`); for the `after` label the base CSS rules do the work.

4. **Playwright headless** — `p.chromium.launch(headless=True)`, navigate to the harness HTML (`file://`), wait for `.choice-row[data-risk]` selector, capture `page.screenshot(path=...)`.

5. **Computed-style probe** — same JS evaluate shape as the live capture:
   ```js
   () => {
     const risks = ["safe", "low", "medium", "high"];
     const rows = {};
     for (const r of risks) {
       const el = document.querySelector(`.choice-row[data-risk="${r}"]`);
       const cs = getComputedStyle(el);
       rows[r] = { borderLeftWidth: cs.borderLeftWidth, borderLeftColor: cs.borderLeftColor, backgroundColor: cs.backgroundColor };
     }
     return rows;
   }
   ```
   The probe is the contract proof — if `before.png` shows `borderLeftWidth: 0px` and `after.png` shows `2px` + correct token colors, the CSS rule resolved correctly in the live browser.

## Why this works when the live path doesn't

- **No API dependency** — harness renders DOM directly, no `/api/campaigns/quick-start` call, no `/api/campaigns` 401 cascade.
- **No CORS** — all CSS is inline, no cross-origin policy applies.
- **No MCP** — the planning-block rows are static HTML, not LLM-generated.
- **Faithful to production** — the CSS file is the actual production file, byte-for-byte. The DOM shape matches `parsePlanningBlocksJson` output. The only thing missing is LLM interactivity, which doesn't matter for visual CSS proof.

## Anti-patterns

- ❌ **Use a `<link>` to load the CSS over HTTP** — Chromium `file://` + cross-origin CSS blocks `cssRules` access on evaluate(), AND requires running an HTTP server alongside Playwright (which defeats the "standalone" purpose).
- ❌ **Stub the DOM with hardcoded colors** — the probe must derive colors from the CSS rule chain (`var()`, `color-mix()`, `@supports`), not from JS constants. Otherwise you're testing your stub, not the CSS.
- ❌ **Skip the computed-style probe** — the screenshot alone is ambiguous (a 7% color-mix tint is barely visible by eye). The probe JSON proves the rule chain resolved.

## Verification

Both PNGs must show:
1. `before.png`: rows render plain (no border, transparent bg) — proves the CSS rule can be disabled.
2. `after.png`: rows render with the correct colored borders + tinted backgrounds — proves the rule resolves correctly in the browser.
3. Computed-style probe JSON proves the byte-level contract: token values, var() fallbacks, color-mix() form.

Use `vision_analyze` on both PNGs to confirm visual delta matches the probe claim (e.g. row 1 = green, row 4 = red).

## Reference

Canonical implementation: `evidence/capture_planning_block_only.py` shipped in PR #9070 (commit `7d6a366de5`). The harness HTML is written to `evidence/_harness_<label>.html` so the screenshot provenance is reproducible.
