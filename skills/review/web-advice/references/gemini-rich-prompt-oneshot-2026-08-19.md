# Gemini rich-prompt single-shot Aside REPL pattern (verified 2026-08-19)

This is the working pattern that produced 3 real Gemini reviews of the worldarchitect.ai
living-world-tick design (response sizes 5,025 + 4,667 + 4,067 chars, all VERDICT: APPROVED
with notes) on 2026-08-19. It bypasses the silent-hang fingerprint issue (rung-4 4a) by
running in the operator's already-authenticated Chrome via Aside CLI + clipboard paste,
NOT via a headless chromium launch.

## Verified recipe (Gemini Web, fresh chat, rich prompt 8-10KB)

**Why this works when the browserclaw headless path is walled:** the cookies injected
into a fresh chromium are rejected by Google's server-side fingerprint check (rung-4 4a).
Aside runs in the operator's existing Chrome process, which already has the operator's
real Google session cookies + fingerprint accepted. Pasting the prompt via clipboard +
`Meta+V` is how the user pastes; the rich-text composer accepts it and the framework's
input event fires correctly.

**Script shape** (Aside REPL — top-level `await`, NO IIFE wrapper — see web-advice SKILL
pitfall §"Aside REPL: top-level `await` is required"):

```js
// Inlined prompt as base64 (escape-safe for shell arg)
const PROMPT_B64 = "...";
const t = await openTab('https://gemini.google.com/app');  // or /app/<existing_chat_id>
await new Promise(r => setTimeout(r, 7000));               // 7s for chat shell to render

// Paste via clipboard (the only path that fires the framework's input event)
await t.click('div[contenteditable="true"]', { force: true });
await new Promise(r => setTimeout(r, 800));
await t.keyboard.press('ControlOrMeta+A');
await t.keyboard.press('Backspace');
await t.evaluate(s => navigator.clipboard.writeText(s),
                 Buffer.from(PROMPT_B64, 'base64').toString('utf8'));
await t.keyboard.press('ControlOrMeta+V');
await new Promise(r => setTimeout(r, 2000));

// Send (try multiple selectors — Gemini renames the aria-label sometimes)
const sendOk = await t.evaluate(() => {
  const sels = ['button[aria-label*="Send" i]', 'button[mattooltip*="Send" i]'];
  for (const sel of sels) {
    const b = document.querySelector(sel);
    if (b && !b.disabled) { b.click(); return true; }
  }
  return false;
});

// Poll for response — Gemini 1-2 model takes 30-60s for 4-5K responses
let resp = '';
for (let i = 0; i < 30; i++) {
  await new Promise(r => setTimeout(r, 5000));
  resp = await t.evaluate(() => {
    const sels = ['model-response', 'message-content', '.model-response',
                  '[data-test-id="message-content"]', 'div[class*="model-response"]'];
    let longest = '';
    for (const sel of sels) {
      for (const c of document.querySelectorAll(sel)) {
        const t = (c.innerText || '').trim();
        if (t.length > longest.length) longest = t;
      }
    }
    return longest;
  });
  if (resp && resp.length > 300 && i > 3) break;  // real response
}
```

**How to drive a chat URL that has a real chat ID:** a fresh visit to
`gemini.google.com/app` often stays at `/app` with no chat ID assigned — the share
button doesn't render in that state. To get a real thread, either (a) load an existing
chat URL like `gemini.google.com/app/<chat_id>`, or (b) paste a tiny "hi" first, wait
for the URL to change to `/app/<id>`, then paste the real prompt.

## What is NOT yet verified (2026-08-19)

- **Share-button click in this Aside-CLI flow.** The `Show more options` button was
  found (kebab next to each assistant message, `aria-label="Show more options"`), and
  clicking it did open a menu, but the subsequent hunt for the `Share` menuitem
  didn't find a clean selector in this build of Gemini. Past-session 2026-08-17
  successfully clicked share via a different path that is not in the current script.
  Treat the share-URL capture path as **TBD** — the response capture itself is
  fully working and is the primary artifact; the public share URL is the secondary
  artifact (operator's 2026-08-19 ruling requires it before reporting a panel).

## Why this matters

- The Gemini response text in this build is reliable enough to act on. Three independent
  runs on the same prompt produced three coherent reviews with verdict-table
  structure (`VERDICT:`, `REASONING:`, `RISK:`, `CONFIDENCE:`) and rich cross-citations
  to file:line references from the prompt's `inline code excerpts` block.
- The "ai-driven second opinion" path is now a 30-60 second latency cost instead of
  a 4-hour failed Aside-CLI recovery loop.
- The same Aside-CLI + clipboard-paste pattern should work for ChatGPT and Grok
  (both render the composer as a standard contenteditable / ProseMirror); Grok was
  authed-but-paste-not-attempted in this session, ChatGPT was Cloudflare-walled.
  Per-vendor caveat: Grok uses `textarea` (not contenteditable); ChatGPT uses
  `#prompt-textarea` with `force: true` click (per `references/transport-ladder-failure-log-2026-08-17.md`).
