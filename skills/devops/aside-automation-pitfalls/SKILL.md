---
name: aside-automation-pitfalls
description: "Aside MCP/REPL/browser automation gotchas — tab routing, Playwright page-object pattern, login forms with saved passwords, ref-stale pitfalls, ambiguous link text, account lockout risk, and 17+ other verified patterns. Load when Aside automation behaves unexpectedly: openTab goes to the wrong window, refs go stale, Chrome autofill overrides typed credentials, MFA login fails silently, getByRole returns not-found intermittently, or aside repl returns no output. Companion to aside-browser-default. Use when working in aside repl or via mcp__aside-mcp__repl to drive a real Chromium tab."
version: 1.5.0
license: MIT
metadata:
  hermes:
    tags: [aside, browser-automation, mcp, repl, pitfall-recipe]
    related_skills: [aside-browser-default]
changelog:
  - "1.7.0 (2026-09-16, AI Studio Gemini quota check): Add pitfalls #32-#36 covering `document`/`window`/`location` are NOT globals in `aside repl` (Node sandbox, not browser) — use `snapshot(p)`; `require('fs')` is blocked — persist via terminal tools from the calling shell; `listBrowserTabs()` lags / omits freshly-opened tabs — track the page handle from `openTab()` directly; `p.title()` returns `{}` for some SPAs (Google AI Studio, Firebase console) — use `snapshot(p).title` or `page.evaluate(() => document.title)`; and `aside --effort ultrabrowse '<nl>'` / `aside '<nl>'` can fail with 'Codex error: The usage limit has been reached' independent of the user's auth — pivot to scripted REPL within seconds, do not retry. Verified against aistudio.google.com/rate-limit scrape on 2026-09-16, Aside daemon v1.26.626.1517."
  - "1.3.0 (2026-08-18, TaxDome 2FA flow for Oren Hen organizer batch): Add pitfalls #18-#22 covering listBrowserTabs() returns plain JSON (not Playwright handles) → use attachBrowserTab(tab.targetId); tab-handle methods include `fill`/`click`/`evaluate` but NOT `type` or `activate`; closeTab() can fail with 'not tracked in this session' for stale tabs; CDP can hang with Page.enable/Runtime.evaluate timeouts on auth-gated reCAPTCHA-like pages (TaxDome 2FA confirmed) → recover by `h.reload()` and split flows into smaller chunks; and `aside repl` nested single-quote bash-quoting workaround via `$(cat file.js)`. Verified against daemon v1.26.818.1059, Oren Hen organizer login attempt 2026-08-18 ~22:36 PT."
  - "1.4.0 (2026-08-18, TaxDome organizer form drive after CDP recovery): Add pitfall #23 — Aside `--account u0` vs `--account u1` does NOT isolate tabs in daemon v1.26.x (both profiles share the same tab list), so per-profile tab assumptions are wrong; and pitfall #24 — the verified recovery path when Aside CDP wedges on a vendor auth form: `browserclaw cookies decrypt` → `browserclaw cookies inject --browser-channel chromium --headless` → Python Playwright via `${HOME}/.local/orch-venv/bin/python` to drive the form. Verified against TaxDome organizer 6464737 (Foreign Accounts) + 6464736 (Cash Donations), 5 fields filled with auto-save preserved across reloads, NO submit clicked."
  - "1.5.0 (2026-08-20, Bluesky + Fediverse multi-account signup): Add pitfalls #25-#30 covering Aside REPL `getByRole({ name: /regex/ })` is NOT supported (use CSS `button:has-text('...')`); `:not([disabled])` and other CSS4 pseudo-selectors are not supported (use `await locator.isEnabled()` before click); re-opening the same URL via `openTab()` resets modal/form state so multi-step wizards (signup, MFA) MUST be in ONE `aside repl` call; Aside NL agent has a sandboxed filesystem that rejects `/tmp/<x>` paths outside its session workspace — use the session-scoped workspace dir; hCaptcha/reCAPTCHA final-step handoff pattern (capture page state, screenshot, PAUSE for user to click — never try to solve image challenges from the agent); and the `page.goto()` inside an SPA modal can close the modal — use `page.locator(...).click()` for in-modal nav instead. Verified against Bluesky signup steps 1-2 (jleechan90 handle, hCaptcha reached), Aside daemon v1.26.821.53."
  - "1.6.0 (2026-08-20, Headless Chrome CDP from terminal + browser_exec venv separation): Add pitfall #31 — headless Chrome started with `--remote-debugging-port=<N>` rejects ALL WebSocket connections from non-allowed origins by default (returns `403 Forbidden` on the WS handshake) — must add `--remote-allow-origins='*'` (or a specific origin) for any CDP client to attach. Verified 2026-08-20 launching Chrome directly to drive Pixelfed signup form via Python `websocket-client` — without the flag, every CDP request was rejected. Companion: `browser_exec` Python sandbox is a separate venv from the system `pip3` — modules installed via `pip3 install <pkg>` are INVISIBLE inside `browser_exec` runs (e.g. `ModuleNotFoundError: No module named 'websocket'`). When you need a CDP script with non-system deps, run it from a `terminal` call where `pip3 install` actually wins."
  - "1.2.0 (2026-08-18, EDD ESO login flow for Mizraim PA-EDD registration): Add pitfalls #11-#17 covering Chrome autofill with saved passwords (user explicitly authorized 'use my saved password in aside'), ref-stale between snapshots, ambiguous link text → query href first, no-explicit-type form inputs, page.evaluate() as the escape hatch, session-cookie scope (don't persist across tab closes), and account lockout risk on retry. Verified against daemon v1.26.818.1059."
  - "1.1.0 (2026-08-13, PR #8870 gemini-3.6-flash settings UI capture): Add pitfall #9 'page object returned from openTab() is Playwright-like, NOT standalone helpers' + pitfall #10 'aside repl accepts code as ONE quoted argument, not stdin'. Verified on the gemini-3.6-flash settings UI dropdown capture: `await snapshot()`, `await annotatedScreenshot()`, `await js()` all returned ReferenceError; the test only worked when treating the openTab() return value as a Playwright `page` object with `.evaluate()`, `.screenshot()`, `.locator()`, `.waitForTimeout()`."
---

# Aside Automation Pitfalls

Class-level knowledge for troubleshooting Aside browser automation that
succeeds at the API layer but doesn't show up in the user's visible window.
Verified during the 2026-08-06 WorldAI HotD social campaign staging
(#all-jleechan-ai Slack).

## 1. openTab() goes to the LAST-FOCUSED window, not the visible one

**Symptom**: `listBrowserTabs()` returns 25 of the user's existing tabs
(Slack, Schwab, LastPass, etc.) and ZERO of the tabs you just opened with
`openTab()`. You spend two hours assuming "tabs are lost."

**Cause**: Per `docs.aside.com/changelog/components.md`:

> "[Fix] CLI browser access — CLI and REPL sessions connect to the
> **last-focused window** when one browser profile is open for your account."

The MCP/REPL session binds to whichever Aside window was focused when it
first connected. If you've been working in Slack/Terminal since the session
started, that's a hidden window. `osascript -e 'tell application "Aside" to
activate'` focuses the visible window but does NOT rebind an existing MCP
session — you may need a fresh `initialize` call.

**Fix**:
```bash
# 1. Focus the visible Aside window
osascript -e 'tell application "Aside" to activate'
# 2. Then start a fresh MCP session
curl -sS -i -X POST "http://127.0.0.1:8013/mcp" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"<label>","version":"1.0"}}}' \
  | grep -i 'mcp-session-id'
# 3. Run openTab in the new session
```

**Verify** before staging: open ONE test tab, then `listBrowserTabs()` and
compare `windowId` against the existing tabs. If they match, you're bound
to the visible window.

## 2. MCP HTTP `tools/call` degrades after 4-6 bundled stages

If you cram openTab+fill+attach for many platforms into a single
`tools/call`, the call may time out at the foreground 600s limit and return
empty. Symptom: "Done. Result:" with no JSON.

**Fix**: split into 3-platform batches (~60-90s each). Between tabs in a
batch use `sleep(6500)` to let the site load before fill. Between batches,
re-init the MCP session because it may have hit the timeout window.

```bash
# Re-init pattern
SID=$(curl ... initialize ... | grep -i mcp-session-id | sed 's/.*: //;s/\r//')
# Then the tools/call with mcp-session-id: $SID
```

## 3. Twitter/X `setInputFiles()` returns "Some of your media failed to load"

X's media upload endpoint rejects browser-automation uploads. Symptom: the
preview thumbnail shows a spinner that never resolves, or "Some of your
media failed to load" appears and the Post button stays disabled.

**Workarounds**:
- **Text-only reply**: skip the image, paste text only, Post button enables
  at <280 chars.
- **xurl CLI** (`pip install xurl` → `xurl auth apps add` to register your
  dev app; requires X API v2 credentials): `xurl media upload <file>` then
  `xurl post --reply-to <tweet_id> --text <text> --media <id>`. This is the
  durable fix but requires manual auth setup once.

## 4. Twitter/X compose retains residual text from prior attempts

When reusing a Twitter compose tab across multiple staging attempts, the
`div[contenteditable="true"][data-testid="tweetTextarea_0"]` may contain
leftover text. `fill()` appends, not replaces.

**Fix**: before filling, dispatch `Ctrl+A` then `Delete` on the textarea.
With Playwright:
```js
await tb.first().click();
await page.keyboard.press('Control+a');
await page.keyboard.press('Delete');
await sleep(400);
await tb.first().fill(tweetText);
```

## 5. Reddit submit pages need selftext=true

`https://old.reddit.com/r/<sub>/submit` shows a card-based UI that needs
two clicks to reach the actual self-post form. **Use**:
`https://old.reddit.com/r/<sub>/submit?selftext=true` to skip directly to
the title + body textareas.

## 6. Dev.to title field is a `<textarea>`, not an `<input>`

`document.querySelector('input#article-form-title')` returns null. Use
`textarea#article-form-title`. Body is `textarea#article_body_markdown`
(underscores, not dashes). Fill body BEFORE title — the title field will
auto-resize based on body length and you don't want it stuck on a tiny box.

## 7. Take FULL-PAGE screenshots, not viewport

Users see "cutoff" screenshots when you capture only the visible viewport.
In the Aside MCP, pass `fullPage: true` to `screenshot()`:
```js
await p.screenshot({ path: '...', fullPage: true });
// or with explicit dimensions
await p.screenshot({ path: '...', clip: { x: 0, y: 0, width: 1280, height: 4000 } });
```

## 8. Jeffrey's directive: when automation misbehaves, /research FIRST

User's verbatim (2026-08-06, #all-jleechan-ai):
*"Use /research what's going on are we using it wrong."*

Don't iterate on a broken assumption for 2+ hours. Check official docs,
run a controlled probe, apply the fix.

## 9. `aside repl` `openTab()` returns a Playwright-like `page` object — NOT standalone helpers

**Symptom** (verified 2026-08-13 PR #8870 setting UI capture): `await snapshot()`, `await annotatedScreenshot()`, `await js()` all returned `ReferenceError: snapshot is not defined` / `await pageInfo()` returned nothing. Time wasted guessing at helper names.

**Cause**: `aside repl` exposes a `page` object whose methods mirror Playwright's API. The standalone globals (`snapshot`, `annotatedScreenshot`, `js`, `pageInfo`) named in other Aside docs are NOT the public repl surface — they exist on the MCP HTTP layer, not the repl.

**Fix**: use the `page` object returned from `openTab()`:

```js
// in aside repl
const r = await openTab('http://127.0.0.1:8081/settings?test_mode=true&test_user_id=...');
const page = r;                                  // the page IS the return value
await page.waitForTimeout(3000);                 // Playwright-compatible wait
const opts = await page.evaluate(() => {        // page.evaluate(<fn>) runs JS
  const sel = document.querySelector('select[name="geminiModel"]');
  return Array.from(sel.options).map(o => o.value);
});
console.log('options:', JSON.stringify(opts));
await page.screenshot({ path: '/tmp/settings.png', fullPage: false });
// Or pull specific element bounds before screenshotting:
const bb = await page.locator('select[name="geminiModel"]').boundingBox();
console.log('select bounding box:', bb);
```

**Verify the page object is what you have**: `console.log(Object.getOwnPropertyNames(Object.getPrototypeOf(page)).filter(n => typeof page[n] === 'function').slice(0, 40).join(','))` — will list `evaluate, screenshot, fill, click, locator, waitForTimeout, …` and confirm you're on the Playwright path.

**Anti-pattern**: `await page.evaluate('document.title')` (string) — needs to be a function reference: `await page.evaluate(() => document.title)`; bare string forms silently return empty.

## 10. `aside repl` accepts code as ONE quoted argument, not stdin

**Symptom**: `aside repl < script.js` returns straight to prompt with no output. Multi-line scripts via heredoc also fail.

**Fix**: pass the WHOLE script as a single quoted argument. For multi-line logic, use semicolons and `await` in sequence:

```bash
aside repl "
  const r = await openTab('http://127.0.0.1:8081/x');
  const page = r;
  await page.waitForTimeout(2000);
  console.log('title:', await page.title());
  await page.screenshot({ path: '/tmp/x.png' });
"
```

For 30+ line scripts, save to a file and use `bash -c "aside repl \"$(cat /tmp/script.js)\""`. The bash quoting gets ugly but it works.

## 11. Chrome autofill OVERRIDES typed usernames (use saved-password sites without asking for credentials)

**Symptom** (verified 2026-08-18 EDD ESO login): Agent typed `jleechan12` into `#user-name-input`, but Chrome's autofill changed it to `jleechan@gmail.com` (the saved account) and silently auto-filled `[redacted]` into `#password-input`. After submit, page reloaded with `CSIAH0303E Incorrect user ID or password`. Wasted two attempts debugging "wrong selector" / "stale form" before realizing Chrome had already taken over.

**Cause**: Aside's Chromium engine inherits the system Chrome password vault. When a saved credential exists for an origin, typing into a login field triggers autofill which OVERRIDES your typed username with the saved one. The user's saved account is authoritative — there's no opt-out from the agent's side.

**Fix pattern (default for any login flow with a saved credential)**:

```js
const page = await openTab('https://example.com/login');
await page.waitForTimeout(3000);
await page.locator('#username, input[name=username]').first().click();
await page.waitForTimeout(400);
await page.keyboard.type('theUser', { delay: 100 });
await page.waitForTimeout(2000);  // give Chrome time to autofill

// VERIFY before clicking submit
const userVal = await page.locator('#username, input[name=username]').first().inputValue();
const pwVal = await page.locator('input[type=password]').first().inputValue();
console.log('username:', userVal, 'password_filled:', pwVal.length > 0);

if (pwVal.length === 0) {
  console.log('Chrome did NOT autofill — do NOT submit, surface to operator');
} else {
  await page.locator('button[type=submit]').first().click();
  await page.waitForTimeout(8000);  // wait for MFA redirect or next page
}
```

**Rules**:
- **Do NOT ask the operator to type credentials manually** — per SOUL.md `## COMMIT: self-service-only`, try harder first. If Chrome has the password, let autofill handle it. If not, surface the blocker honestly.
- **Verify autofill BEFORE submitting** — read back via `inputValue()`. If `pwVal.length === 0`, Chrome didn't fill and submitting is pointless.
- **The override IS the feature** — when the typed value differs from the saved account, Chrome's choice wins. This is the whole point: the saved credential is what the user has authorized.
- **Read the saved username back to confirm** — if your typed `jleechan12` got overridden to `jleechan@gmail.com`, that may be the wrong account. Surface to the operator before clicking submit.
- **MFA / 2FA still pauses the flow** — submit returns a verification challenge; pause and ask the operator for the code.

## 12. Do NOT retry a failed login — account lockout risk

**Symptom**: Submit returned `CSIAH0303E Incorrect user ID or password` (or similar). Agent retries with same credentials hoping the page state is different. After 3-5 retries the account gets locked and the operator must call support.

**Cause**: Many enterprise login systems (EDD's IBM Tivoli MFA, bank portals, healthcare portals) silently lock after 3-5 failed attempts. The page doesn't always tell you the threshold has been crossed. Re-trying without diagnosing the root cause burns the operator's remaining attempts.

**Fix**: after the FIRST failed submit, stop and report. Read back what was actually submitted (`inputValue()` for both fields after Chrome autofill) and surface the mismatch honestly:
- If Chrome filled `jleechan@gmail.com` and you wanted `jleechan12` → tell the operator, do not retry.
- If Chrome filled a saved password that no longer matches the current account → tell the operator the saved password is stale and ask them to re-save it via a browser GUI login.
- If you don't know which is right → ask, do not guess.

## 13. Snapshot `ref=eN` IDs go stale between blocks — re-snapshot OR chain in one block

**Symptom** (verified 2026-08-18): `await p.locator('e8').click()` after a previous block returned `RefStaleError: Ref "e8" is stale — the element was removed or the page changed. Take a new snapshot and retry.`

**Cause**: Each `snapshot()` call assigns fresh `ref=eN` IDs. The IDs from a prior snapshot are invalid once the page state changes (or even on the same page after a network tick).

**Fix patterns**:
- **Best: chain everything in ONE block** — openTab → snapshot → click → snapshot → click → read, all in one `aside repl` call.
- **Alternative: query by role/text/selector, not ref** — Playwright locators are stable across re-renders:
  ```js
  await page.locator('button:has-text("Log in")').first().click();
  await page.locator('input[name=username]').first().click();
  ```
- **Last resort: re-snapshot before each action** — costs ~500ms per call but guarantees freshness.

## 14. `getByRole('link', { name: /pattern/ })` is unreliable for ambiguous link text

**Symptom** (verified 2026-08-18 EDD home page): Three links have overlapping names — "e-Services for Business:", "Learn more about e-Services for Business", etc. `await p.getByRole('link', { name: /e-Services for Business/i }).first().click()` failed with `Role selector not found` because the regex matched the WRONG link's full name and Playwright's `:nth(0)` couldn't disambiguate. Same call sometimes worked (race condition on DOM ready).

**Fix — query the href first, navigate directly**:

```js
const page = await openTab('https://example.com/home');
await page.waitForTimeout(3000);
const href = await page.locator('a').filter({ hasText: 'e-Services for Business' }).first().getAttribute('href');
// Then in a follow-up block (or same block if you can chain):
const page2 = await openTab('https://example.com' + href);
```

This works because `getAttribute('href')` returns the URL the link would navigate to, and `openTab()` accepts a full URL. You skip the click entirely, which means no race condition on which link gets matched.

## 15. HTML form inputs without explicit `type=` fail strict CSS selectors

**Symptom** (verified 2026-08-18 EDD form): `page.locator('input[type=text]')` returned 0 elements even though the form has visible username and password inputs. The HTML is `<input id="user-name-input" name="username">` with no `type` attribute (defaults to `text` per HTML spec but Playwright strict selectors don't infer).

**Fix — use ID, name, or label**:
```js
page.locator('#user-name-input, input[name=username]')
page.locator('input[type=password]')            // always explicit
page.locator('label:has-text("Username") + input')  // label-adjacent
```

When debugging a form that doesn't match your selector, dump all inputs first:
```js
const inputs = await page.evaluate(() => {
  return Array.from(document.querySelectorAll('input')).map(i => ({
    type: i.type, id: i.id, name: i.name, placeholder: i.placeholder
  }));
});
console.log(JSON.stringify(inputs, null, 2));
```

## 16. `page.evaluate(fn)` is the working escape hatch — not `eval` / `evaluateJS` / `js`

**Symptom**: Agent guesses helper names — `eval`, `evaluateJS`, `js`, `execJS` — and each returns `ReferenceError: X is not defined`.

**Fix**: Aside's Playwright-compatible `page` object exposes `page.evaluate(fn)` (lowercase, single arg, returns a Promise of the function's return value). The function must be a real JS function reference — string forms silently return empty:

```js
// ✅ works
const title = await page.evaluate(() => document.title);

// ❌ silently returns empty
const title = await page.evaluate('document.title');
```

Use `page.evaluate` whenever `snapshot()` can't see what you need (shadow DOM, computed styles, hidden form state, dynamically-rendered content).

## 17. Session cookies for `*.mfa.*` / `*.sso.*` origins are bound to the daemon process — don't persist across tab closes

**Symptom** (verified 2026-08-18 EDD): Even when `~/Library/Application Support/Aside/Default/Cookies` has `JSESSIONID` / `CISESSIONIDPR02A` / `CIPD-S-SESSION-ID` for `*.mfa.edd.ca.gov`, opening a fresh tab and navigating to the login URL still shows the login form. The session cookies are bound server-side to the daemon's session handle, which the daemon loses across tab closes or daemon restarts.

**Implication**:
- **Saved PASSWORDS persist** (in Chrome's Login Data DB, keyed by origin).
- **Saved SESSION COOKIES do NOT persist** beyond a single browser session.
- **The operator must log in via the browser GUI first** to establish a session. After that, you can navigate via REPL while the session is alive (minutes to hours depending on server-side timeout).
- **Don't waste time trying to reuse old session cookies** — they will fail. The login flow will re-trigger.

## 18. `listBrowserTabs()` returns plain JSON objects, NOT Playwright handles

**Symptom** (verified 2026-08-18 TaxDome 2FA flow): After `listBrowserTabs()` returns, calling `tab.activate()`, `tab.url()`, `tab.close()`, or `tab.fill()` all fail with `TypeError: tab.X is not a function`. Tab objects have shape `{active: bool, faviconUrl, id, targetId, title, url, windowId}` — plain strings/booleans, no callable methods.

**Cause**: The standalone globals `snapshot`, `annotatedScreenshot`, `openTab`, `listBrowserTabs`, `attachBrowserTab`, `attachActiveBrowserTab`, `getTabByTargetId`, `closeTab` are the public repl surface (per `console.log(Object.keys(this).filter(k => typeof this[k] === 'function'))`). They return Playwright-LIKE handles only when their contract says so; `listBrowserTabs` returns plain metadata.

**Fix**: get the Playwright-compatible page handle separately via `attachBrowserTab(tab.targetId)`:

```js
const tabs = await listBrowserTabs();
const target = tabs.find(x => x.url.includes('taxdome'));
const page = await attachBrowserTab(target.targetId);   // ← the page handle
await page.click('e10');                                 // snapshot ref-based click
const snap = await page.snapshot({ interactive: true });
await page.evaluate(() => document.title);               // DOM escape hatch
```

**Verify the handle works**: `await page.title()` (no method-not-found error) — if `page` was wrong, this errors. Also `Object.getOwnPropertyNames(Object.getPrototypeOf(page))` will list `[constructor, on, off, click, fill, goto, locator, evaluate, snapshot, screenshot, bringToFront, close, ...]`.

## 19. Tab page handle has `fill` and `click` but NO `type` — and `evaluate` is the workhorse

**Symptom** (verified 2026-08-18): `await h.type('e18', '1')` returned `TypeError: h.type is not a function`. Multi-input OTP entry (6 digit boxes for TaxDome 2FA) failed for 3 minutes before switching to `h.fill(ref, value)`.

**Available page-handle methods** (verified via `Object.getOwnPropertyNames(Object.getPrototypeOf(page))` on Aside daemon v1.26.818.1059):

| Method | Use |
|---|---|
| `page.click(ref)` | Click snapshot ref (`eN`) OR selector |
| `page.fill(ref, value)` | Set input value — REPLACES, does not append |
| `page.locator(selector).first()` | Stable selector-based queries |
| `page.getByRole(role, {name})` | ARIA role + name lookup |
| `page.getByLabel(text)` | Label-text lookup |
| `page.evaluate(() => ...)` | Run arbitrary DOM JS — function form, NOT string |
| `page.evaluateInFrame(frameId, fn)` | Frame-scoped evaluate |
| `page.screenshot({path, fullPage})` | Capture PNG |
| `page.snapshot({interactive})` | Tree + refs JSON |
| `page.reload()` | Force reload (recovers CDP hangs sometimes — see #22) |
| `page.bringToFront()` | Focus the tab window |
| `page.close()` | Close the tab — may fail if daemon lost track (see #20) |
| `page.goto(url)` | Navigate the tab |
| `page.waitForLoadState`, `waitForURL`, `waitForSelector`, `waitForEvent` | Wait primitives |
| `page.title()`, `page.url()`, `page.content()` | Metadata reads |
| `page.frameLocator`, `page.frames`, `page.mainFrame` | Frame access |

**Anti-patterns**:
- `await page.type(...)` — `type` doesn't exist on Aside page handles; use `fill`.
- `await page.activate()` — not a method on plain tab objects; use `bringToFront` on the handle.
- `await page.evaluate('document.title')` (string form) — silently returns empty; pass a function.

**OTP/multi-input recipe** (works for TaxDome 2FA, bank OTP, etc.):

```js
// Method A: refs from snapshot
const snap = await page.snapshot({ interactive: true });
for (let i = 0; i < 6; i++) {
  await page.fill('e' + (18 + i), code[i]);   // pin code 1 of 6 = ref e18
}

// Method B: direct DOM via evaluate
await page.evaluate(() => {
  const inputs = document.querySelectorAll('input[aria-label^="pin code"]');
  const code = "159858";
  for (let i = 0; i < inputs.length; i++) {
    const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
    setter.call(inputs[i], code[i]);
    inputs[i].dispatchEvent(new Event('input', {bubbles: true}));
    inputs[i].dispatchEvent(new Event('change', {bubbles: true}));
  }
});
```

Method B bypasses React/Vue controlled-component re-renders that can wipe Method A's values when the framework rebinds after `fill`.

## 20. `closeTab(tab)` / `closeTab(tab.targetId)` may fail with "Tab not tracked in this session"

**Symptom** (verified 2026-08-18 TaxDome): After multiple `listBrowserTabs()` → `attachBrowserTab` → operations on a tab that the daemon loaded >5 minutes ago, `closeTab(tab)` or `closeTab(tab.targetId)` returns `Error: Tab undefined is not tracked in this session` or `Tab CF237DA6850566D597C2FF7598A42C55 is not tracked`. The tab STAYS OPEN.

**Cause**: Aside's daemon tracks an internal session-id for each tab. Long-lived tabs whose first-attached context has been swapped out (e.g. you attached via `--account u0`, then later switched to `--account u1`) may report targetIds the daemon's current session doesn't recognize.

**Workaround**: leave stale tabs alone. Don't try to close them. They don't block new work — `openTab()` opens a new tab alongside. If you really need a clean slate, restart the Aside daemon (`osascript -e 'quit app "Aside"' && open -a "/Applications/Aside.app"`) and re-attach.

**Anti-pattern**: trying every combination of `closeTab(tab)`, `closeTab(tab.id)`, `closeTab(tab.targetId)`, `closeAllTabs()` — none will work on a stale tab, and you'll burn 5 minutes.

## 21. `aside repl` with nested single quotes breaks bash quoting — use `$(cat file.js)`

**Symptom** (verified 2026-08-18): Passing JS containing string literals like `find(x => x.url.includes("taxdome"))` inside `aside repl "<js>"` produces `SyntaxError: Unexpected token ':'` because bash's single-quote-escape of double-quoted bash-with-double-quoted-js strips colons that JS reads as labels.

Tried patterns that all failed:
- `aside repl "const tabs = await listBrowserTabs(); for (const x of tabs) console.log('T:' + x.url);"` → `SyntaxError: Unexpected token ':'` (T: becomes T label)
- `aside repl "$(cat /tmp/_script.js)"` (unquoted command sub) → bash thinks the JS is multiple args
- heredoc (`aside repl <<'EOF' ... EOF`) → REPL opens, JS doesn't auto-execute
- Multi-line via `bash -c "aside repl \"$(cat ...)\""` → works for short scripts but explodes on long ones with special chars

**Fix that works** (verified):

```bash
# 1. Write JS to a file
cat > /tmp/_my_script.js <<'JSEOF'
const tabs = await listBrowserTabs();
for (const x of tabs) console.log("U=" + x.url);
JSEOF

# 2. Pass via bash command substitution, escape the outer quotes
JS=$(cat /tmp/_my_script.js); aside repl "$JS"
```

The trailing `; aside repl "$JS"` pattern with no heredoc wrapping is the one that survives 30-line scripts without quoting bugs.

**Alternative for short scripts**: avoid string literals with `:` (use `T=` instead of `T:` in console.log); avoid arrow functions that contain colons; use double-quoted bash outside, single-quoted JS string literals inside.

## 22. Aside CDP can hang with `Page.enable` / `Runtime.evaluate` timeout on auth-gated pages

**Symptom** (verified 2026-08-18 TaxDome 2FA screen): After clicking "Log in" with autofilled credentials, the 2FA page renders correctly. `attachBrowserTab` + `snapshot()` may succeed once, but follow-up `page.evaluate(...)` and `page.fill(...)` calls return:

```
Error: CDP command timeout: Page.enable
```
or
```
Error: CDP command timeout: Runtime.evaluate
```

This happens *after* the page loaded normally — a clean snapshot proves the page is fine. Pattern: short single-step operations sometimes survive; chained operations across 3+ `page.evaluate`/`page.fill`/`page.click` calls in one script hang.

**Cause** (best guess): Pages with reCAPTCHA-style challenge flows, embedded MFA widgets, or aggressive CSPs may hold CDP channels open in a way Aside's daemon doesn't expect. TaxDome 2FA was confirmed to trigger this. Other suspected culprits: Stripe 3DS, Plaid Link, some SSO redirects.

**Mitigations** (in order of effectiveness):

```js
// 1. RELOAD the tab — clears the hung CDP state
const page = await attachBrowserTab(target.targetId);
await page.reload();
await page.waitForTimeout(4000);   // let reCAPTCHA reset

// 2. Split multi-step flows into SEPARATE aside repl calls
//    Call 1: openTab + login click + wait
//    Call 2: attach + fill OTP
//    Call 3: click submit + wait for dashboard
//    Each call has its own JS engine spin-up; CDP hang in one doesn't poison the next.

// 3. Prefer `page.evaluate(() => singleDomOp())` over multiple page.X calls —
// each evaluate is one CDP roundtrip instead of N.

// 4. If still hung, abandon the TaxDome / reCAPTCHA page and have the operator
// finish the flow in their visible browser (the daemon's other tabs are fine).
```

**Verify before declaring dead**: a single `await page.title()` should succeed in <2s. If it hangs >10s, CDP is wedged.

**Operator hand-off recipe** when CDP won't recover:

1. Tell the user: "Aside CDP is wedged on TaxDome 2FA — finish the login in your visible Chrome (email autofills, password autofills, Gmail 2FA arrives in <10s, type the 6 digits). Then I'll drive the organizers from the dashboard via your signed-in cookies."
2. Don't burn more than 5 minutes on retries before switching to hand-off. The 2FA window is 10 minutes — half that on retries is a guaranteed miss.

## 23. Aside `--account u0` vs `--account u1` does NOT isolate tabs in daemon v1.26.x

**Symptom** (verified 2026-08-18 TaxDome flow): The skill `aside-browser-default` and several old memories imply `--account uN` switches into a fully isolated Aside profile session with its own tab list. In daemon v1.26.818.1059, this is NOT true — both `u0` and `u1` reports the SAME tab list (same `windowId`, same tabs including EDD / WorldAI / Morgan Stanley / TaxDome / Google search). When you `openTab` a TaxDome URL under `--account u1`, both profiles show the tab.

**Cause (best guess)**: Daemon v1.26.x routes `--account` switches at the cookie + auth-state layer but reuses the active tab list. The CLI flag is for *identity*, not for *tab isolation*.

**Implication for automation**:
- Don't rely on `--account` to scope which tabs you see.
- When switching profiles mid-flow, the previous tab may still be visible to the new profile (cookies are separate, but tab presence is shared).
- `listBrowserTabs()` returns the same N tabs from either account — there's no per-account filtering.

**Fix**: use `--account` for cookie/auth purposes only. Use `tab.url` / `tab.title` / `tab.id` filtering to identify the right tab when both profiles share a tab list.

## 24. RECOVERY PATH when Aside CDP wedges on a vendor auth form — switch to `browserclaw cookies inject` + Python Playwright

**Symptom** (verified 2026-08-18 TaxDome organizer forms 6464737 + 6464736): After #22's `page.reload()` recovery fails (CDP still wedges on `Page.enable` / `Runtime.evaluate` for 2+ minutes, multiple retries, daemon not responding to `listBrowserTabs()`), the flow is unfixable from the Aside REPL.

**Recovery — the verified fallback recipe**:

```bash
# Step 1: Decrypt cookies from the profile that owns the vendor session
# (Aside Profile 1 = worldarchitect.ai for TaxDome; keychain account is "Aside", NOT "Aside-Profile1")
browserclaw cookies decrypt \
  --db "$HOME/Library/Application Support/Aside/Profile 1/Cookies" \
  --output /tmp/_vendor_cookies.json \
  --domain-filter '%<vendor>%' \
  --keychain-service 'Aside Safe Storage' \
  --keychain-account 'Aside' \
  --summary

# Step 2: Verify the dashboard loads with --print-text
browserclaw cookies inject \
  --cookies /tmp/_vendor_cookies.json \
  --goto 'https://<vendor>/app/dashboard' \
  --browser-channel chromium --headless \
  --wait-after-load 8 \
  --screenshot /tmp/_dashboard.png \
  --print-text 2000
```

If `--print-text` returns the user's name + dashboard content, you are logged in. Move to Python Playwright.

```bash
# Step 3: Write the form-driving script — Python Playwright via orch-venv
cat > /tmp/_drive_form.py <<'PYEOF'
from playwright.sync_api import sync_playwright
import json

with open("/tmp/_vendor_cookies.json") as f:
    cookies = json.load(f)

with sync_playwright() as p:
    browser = p.chromium.launch(headless=True)
    ctx = browser.new_context(storage_state={"cookies": cookies["cookies"], "origins": []})
    page = ctx.new_page()
    page.goto("https://<vendor>/app/<organizer-id>/edit?intake_step=questionnaire",
              wait_until="networkidle", timeout=30000)
    page.wait_for_timeout(3000)
    # ... drive fields via the recipes below ...
    browser.close()
PYEOF

# Step 4: Run with the orch-venv Python (has Playwright + Chromium installed)
${HOME}/.local/orch-venv/bin/python /tmp/_drive_form.py
```

**Why this works**:
- `browserclaw cookies inject` opens a **fresh Playwright Chromium headless session** — no CDP session is shared with the wedged Aside daemon. The headless session gets cookies injected before any page loads, so it can drive the form with a normal Playwright API.
- The orch-venv (`${HOME}/.local/orch-venv/bin/python`) has Playwright + the Chromium browser bundle pre-installed. The system `node` Playwright is missing the chromium bundle and fails with `Cannot find module 'playwright'`.
- Python Playwright's `wait_until="networkidle"` works on TaxDome-style SPAs without the Aside CDP-wedge behavior.

**Field-by-field fill recipes for TaxDome-style React-controlled forms** (these are the ones that survived the 5-minute fill session):

```python
# Textareas — use the native setter via page.evaluate (React ignores plain fill)
page.evaluate("""(fills) => {
    const setVal = (name, val) => {
        const el = document.querySelector('[name="' + name + '"]');
        if (!el) return;
        const proto = el.tagName === 'TEXTAREA'
            ? window.HTMLTextAreaElement.prototype
            : window.HTMLInputElement.prototype;
        const setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
        setter.call(el, val);
        el.dispatchEvent(new Event('input', {bubbles: true}));
        el.dispatchEvent(new Event('change', {bubbles: true}));
    };
    for (const [name, val] of Object.entries(fills)) setVal(name, val);
}""", {"202307743": "CAD", "202307745": "Scotiabank"})

# Number inputs (inputmode="decimal") — fill("") then fill(value) is the ONLY way
# that survives React's controlled state. press_sequentially APPENDS, Ctrl+A+Delete fails.
for name, val in [
    ("202307744", "15831"),       # Highest balance
    ("202307746", "5127"),          # Last 4 of account
    ("202307764", "01/01/2020"),    # Date — the field formatter parses MM/DD/YYYY
]:
    loc = page.locator("[name='" + name + "']")
    loc.fill("")
    page.wait_for_timeout(200)
    loc.fill(val)
    page.wait_for_timeout(400)

# Hidden radios (Yes/No) — Playwright's click fails with "Element is outside of the viewport"
page.evaluate("""() => {
    const radios = document.querySelectorAll("[name='202307750']");
    if (radios.length >= 2) {
        radios[1].click();          // second radio = "No"
        radios[1].dispatchEvent(new Event('change', {bubbles: true}));
    }
}""")

# Always read back what landed in the DOM before claiming done
filled = page.evaluate("""() => {
    return Array.from(document.querySelectorAll('input, textarea'))
        .filter(el => el.value || el.checked)
        .map(el => el.name + '=' + (el.value || 'CHECKED').slice(0, 60));
}""")
print('\\n'.join(filled))
page.screenshot(path='/tmp/_form_FINAL.png', full_page=True)
```

**When to fall back from Aside to this path**:
- 3+ Aside CDP timeouts on the same page (Page.enable / Runtime.evaluate errors).
- Daemon becomes unresponsive to `listBrowserTabs()` for >60 seconds.
- The user has confirmed they want the work done even if it takes a non-Aside path.

**When NOT to fall back** (try one more Aside-side recovery first):
- First CDP timeout — try `page.reload()` per #22, retry.
- Stale tab issue — open a fresh tab via the HTTP MCP path (see `auth-gated-site-read` references).
- The page is a known-good-side OneShot flow that should complete in <30s of REPL time.

## 25. `page.getByRole(role, { name: /regex/ })` regex name is NOT supported in current Aside daemon

**Symptom** (verified 2026-08-20 Bluesky signup): `await p.getByRole('button', { name: /next/i }).click()` returns `Error: Role selector not found: role:button[name-regex=next][name-regex-flags=i]`. The role+name selector works in vanilla Playwright but the Aside daemon's selector engine doesn't recognize the regex shape.

**Fix — use CSS `:has-text()` selectors** which are robust in the current daemon:

```js
// ❌ doesn't work
await p.getByRole('button', { name: /next/i }).click();

// ✅ works
await p.locator('button:has-text("Next")').first().click();
await p.locator('button:has-text("Create account")').first().click();
await p.locator('input[placeholder*="email" i]').first().fill('...');
```

The `button:has-text("...")` pseudo-class is Playwright-standard and Aside implements it. Combine with `:not([disabled])` checks via the locator API:

```js
const btn = p.locator('button:has-text("Next")').first();
if (await btn.isEnabled()) {
  await btn.click();
}
```

## 26. `:not([disabled])` and other CSS4 pseudo-selectors are NOT supported

**Symptom** (verified 2026-08-20 Bluesky): `p.locator('button:has-text("Next"):not([disabled])').click()` returns `Error: Selector "button:has-text("Next"):not([disabled])" not found`.

**Fix — query `isEnabled()` programmatically**:

```js
const nextBtn = p.locator('button:has-text("Next")').first();
const enabled = await nextBtn.isEnabled();
console.log('NEXT_ENABLED:', enabled);
if (enabled) await nextBtn.click();
```

This pattern works reliably even when the button has the `disabled` attribute, is `aria-disabled`, or uses CSS-class-based disabling. Combine with a short `waitForTimeout` if the disable state is debounced (e.g. waiting on an async availability check).

## 27. Re-opening the same URL via `openTab()` resets modal/form state — multi-step wizards MUST be in ONE `aside repl` call

**Symptom** (verified 2026-08-20 Bluesky signup wizard): Each `aside repl` call starts fresh. If call 1 does `openTab('https://bsky.app/')` → click Create account → fill email → click Next, and call 2 tries to continue the flow, the modal has CLOSED — calling `openTab('https://bsky.app/')` again reloads the page, the modal state is lost, and the agent is back at step 1. Same thing happens for any SPA wizard (signup, MFA challenge, checkout, settings multi-step).

**Cause**: `aside repl` is a fresh JS context each call. `openTab()` opens a tab in the daemon but does not preserve prior form state across calls.

**Fix — chain everything in ONE call**:

```js
// ❌ splits across calls — wizard state lost
// call 1
const p = await openTab('https://bsky.app/');
await p.locator('button:has-text("Create account")').click();
await p.locator('input[placeholder*="email"]').first().fill('jleechan+bluesky@gmail.com');
// call 2 — modal closed, fresh page
const p2 = await openTab('https://bsky.app/');  // modal gone, back to discover page

// ✅ everything in ONE call
const p = await openTab('https://bsky.app/');
await p.waitForTimeout(4000);
await p.locator('button:has-text("Create account")').click();
await p.waitForTimeout(4000);
await p.locator('input[placeholder*="email"]').first().fill('jleechan+bluesky@gmail.com');
await p.locator('input[type=password]').first().fill('GENERATED_PW');
await p.locator('input[type=date]').first().fill('1990-01-01');
await p.locator('button:has-text("Next")').first().click();
await p.waitForTimeout(5000);
await p.locator('input[placeholder*="bsky.social"]').first().fill('jleechan90');
await p.waitForTimeout(3500);
await p.locator('button:has-text("Next")').first().click();
await p.waitForTimeout(6000);
// Now we're at step 3 — snapshot to find the captcha
```

For very long flows (>10 stages), bundle in chunks of ~5 stages per `aside repl` call with snapshot+continue patterns. Between calls, snapshot the URL/state and re-attach via `attachBrowserTab(target.targetId)` (see #18) — but only if the underlying page reload is genuinely necessary.

## 28. Aside NL agent has a sandboxed filesystem — `/tmp/<x>` paths are rejected

**Symptom** (verified 2026-08-20 Bluesky hCaptcha capture): Running `aside --account u0 "screenshot the captcha to /tmp/fediverse-evidence/bluesky-captcha.png"` succeeds in taking the screenshot in-memory but fails on save with `Error: Path escapes Project and session roots: /tmp/fediverse-evidence`.

**Cause**: The NL agent runs in a sandboxed environment that only allows writes to its own session-scoped workspace, e.g. `~/Library/Application Support/Aside/AsideDaemon/mac-arm64/<version>/sessions/<session-id>/tmp/` or the user-scoped `~/Library/Application Support/Aside/u/<n>/sessions/<session-id>/tmp/`. Absolute paths outside that root are rejected.

**Fix — let the NL agent save to its own workspace, then copy out**:

1. Tell the NL agent: `"Save the screenshot to <agent-workspace-path> and report the path"`.
2. The NL agent reports back a path like `${HOME}/Library/Application Support/Aside/u/0/sessions/2026-08-20_xxx/tmp/repl-display-yyy.jpeg`.
3. The terminal session can then `cp` or `mv` the screenshot to wherever you actually need it (`/tmp/...`, a project dir, etc.).

Alternative: do the screenshot from a `terminal` call driving `aside repl` instead of using the NL agent — `aside repl` has fewer filesystem restrictions because the calling shell owns the path.

## 29. hCaptcha / reCAPTCHA final-step handoff — capture state, screenshot, PAUSE for user

**Symptom** (verified 2026-08-20 Bluesky signup): Steps 1-2 (email, password, handle) complete fine. Step 3 is `https://bsky.social/gate/signup?handle=<handle>&state=<state>&colorScheme=dim` — a Bluesky-internal gate iframe hosting hCaptcha with sitekey `e75b29e9-...`. The hCaptcha iframe is cross-origin; you cannot programmatically click the "I am human" checkbox reliably, and any image challenge ("click all images with a bus") requires human judgment.

**Cause**: hCaptcha fingerprints browser environments aggressively and the "I'm human" checkbox is gated behind a behavioral signal that headless agent sessions don't naturally produce. Image challenges explicitly require visual reasoning.

**Fix — explicit handoff to the operator**:

```js
// Once you reach the captcha step:
const captchaFrame = p.frameLocator('#captcha-iframe');
const tree = await captchaFrame.locator('body').innerHTML();
console.log('captcha step reached, html head:', tree.slice(0, 500));
// STOP HERE — report the URL + screenshot to the user and ask them to click
```

In Slack reply:

```
Bluesky form filled — handle jleechan90 accepted. Now on hCaptcha (cross-origin iframe).
Look at your Aside window — there's a "I am human" checkbox on bsky.app.
Click it. If it serves an image challenge ("click all motorcycles"), solve that too.
Tell me when you're past the captcha and I'll continue (next step: email verification link).
```

**Anti-patterns**:
- Don't `await new Promise(r => setTimeout(r, 30000))` and pray the captcha self-resolves.
- Don't try `page.evaluate(() => document.querySelector('#checkbox').click())` from outside the iframe — cross-origin.
- Don't chain more `aside repl` calls hoping the captcha will go away. It won't.
- Don't write the account creation as "complete" in the user-visible report just because the form is filled.

## 30. `page.goto()` inside an SPA modal can close the modal — use locator clicks

**Symptom**: Calling `await p.goto(nextPageUrl)` while a modal is open will close the modal and load the destination URL directly. Form state inside the modal is lost.

**Fix**: Use in-modal links via locator clicks — they keep the SPA's modal stack intact:

```js
// ❌ closes the modal
await p.goto('https://example.com/onboarding/step-2');

// ✅ in-modal nav preserves state
await p.locator('a:has-text("Continue")').first().click();
```

This is the same class of bug as #27 but applies when the modal needs to advance via links rather than buttons. The fix is the same: chain clicks in one block, avoid cross-call state loss.

## 31. Headless Chrome `--remote-debugging-port` rejects ALL WebSocket origins by default — add `--remote-allow-origins='*'`

**Symptom** (verified 2026-08-20 Pixelfed signup attempt): Launching Chrome directly with:

```bash
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage \
  --user-data-dir=/tmp/chrome-pixelfed \
  --remote-debugging-port=9223 \
  --window-size=1280,900 about:blank
```

Then attaching with Python `websocket-client`:

```python
ws = create_connection("ws://127.0.0.1:9223/devtools/page/<id>", timeout=30)
```

Fails immediately with:

```
websocket._exceptions.WebSocketBadStatusException: Handshake status 403 Forbidden
Rejected an incoming WebSocket connection from the http://127.0.0.1:9223 origin.
Use the command line flag --remote-allow-origins=http://127.0.0.1:9223 to allow
connections from this origin or --remote-allow-origins=* to allow all origins.
```

**Cause**: Chrome added `--remote-allow-origins` as a security gate in Chrome 111+ to prevent arbitrary web origins from attaching to a debugging port. Without it, only `chrome://`-scheme origins can connect, and `http://127.0.0.1:<port>` is rejected.

**Fix — add the flag**:

```bash
"$CHROME" --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage \
  --remote-allow-origins='*' \
  --user-data-dir=/tmp/chrome-pixelfed \
  --remote-debugging-port=9223 \
  --window-size=1280,900 about:blank
```

The `--remote-allow-origins='*'` is REQUIRED for any non-Aside CDP client (Python Playwright, Python `websocket-client`, raw CDP scripts). Aside's own daemon attaches to its own Chrome via internal plumbing, so its connections work without the flag — but if you launch Chrome separately, you need it.

**Companion gotcha — `browser_exec` Python sandbox is a SEPARATE venv from system `pip3`** (verified 2026-08-20): If you `pip3 install websocket-client` and then run a Python script via `browser_exec`, the import fails with `ModuleNotFoundError: No module named 'websocket'`. The `browser_exec` tool runs Python inside the browser-use venv (`${HOME}/.cache/uv/archive-v0/<hash>/bin/browser-use`), which has its own `site-packages` independent of `${HOME}/.local/orch-venv/lib/python3.13/site-packages` where `pip3 install` lands.

**Workarounds** (in priority order):

1. **Run the CDP script from a `terminal` call**, NOT `browser_exec`. The `terminal` tool's Python interpreter is the system `python3` at `${HOME}/.local/orch-venv/bin/python3`, which respects `pip3 install`. CDP-driving from `terminal` is the canonical path.
2. **Install the dep into the browser-use venv explicitly**: `${HOME}/.cache/uv/archive-v0/<hash>/bin/pip install websocket-client` — but the hash path is unstable across browser-use upgrades.
3. **Use bare stdlib + raw socket protocol** instead of `websocket-client` — possible but very tedious for CDP frames.

**Verify before declaring dead**: from a `terminal` call, run `python3 -c "import websocket; print('ok')"`. If it succeeds there but the same import fails in `browser_exec`, you've confirmed the venv separation.

## Related

- `~/.smartclaw/skills/aside-browser-default/SKILL.md` — primary Aside browser
  skill (check Phase 2 for the focused-tab pattern)
- `https://docs.aside.com/changelog/components.md` — official changelog
  with the "last-focused window" behavior
- `https://docs.aside.com/help/developers.md` — CLI/MCP/REPL setup
- `references/aistudio-rate-limit-check.md` — verified recipe for live
  AI Studio `/rate-limit` and `/usage` page scrapes (URL paths, REPL
  sequence, snapshot field extraction)

## 32. `aside repl` has NO `document` / `window` / `location` globals — use `snapshot(p)`

**Symptom** (verified 2026-09-16 AI Studio quota check): Inside `aside repl`, `console.log(document.title)` and `console.log(location.href)` both fail with `ReferenceError: 'document' is not defined`. The REPL is a Node sandbox, NOT a browser context.

**Fix — read page state via the `snapshot()` helper**:

```js
const p = await openTab('https://aistudio.google.com/rate-limit');
await new Promise(r => setTimeout(r, 8000));
const s = await snapshot(p);
console.log('title:', s.title, 'url:', s.url);
// s.tree is a YAML-ish accessibility-tree dump of the page — perfect for scraping tables
console.log(s.tree.slice(0, 6000));
```

**Why**: `snapshot()` reads the live Chromium accessibility tree via the daemon's CDP channel and returns it as a JS value. It's the canonical read API in `aside repl`.

## 33. `require('fs')` is blocked inside `aside repl` — persist data via terminal tools

**Symptom** (verified 2026-09-16): Calling `const fs = require('fs'); fs.writeFileSync('/tmp/...', ...)` inside `aside repl` fails with `Error: External modules are not available in the REPL.`

**Cause**: The REPL runs in a sandboxed V8 context with `require` disabled — it's not a full Node runtime.

**Fix — capture data in stdout, persist from the calling terminal call**:

```bash
# 1. In aside repl: print the data you want to save
aside repl "const p = await openTab('https://aistudio.google.com/rate-limit'); await new Promise(r => setTimeout(r, 8000)); const s = await snapshot(p); console.log(JSON.stringify({title: s.title, url: s.url, tree: s.tree}))"

# 2. Capture stdout to a file from a terminal call (or copy-paste the JSON out)
```

For very large trees (>50K chars), pipe through `head -c 100000` and write in chunks rather than relying on a single `aside repl` call's stdout buffer.

## 34. `listBrowserTabs()` lags / omits freshly-opened tabs — track the page handle from `openTab()` directly

**Symptom** (verified 2026-09-16 AI Studio quota check): After `openTab('https://aistudio.google.com/...')` returns success, `listBrowserTabs()` shows only older tabs (e.g. PixelLab from a prior session) and not the newly opened tab. The tab IS open in the daemon but invisible to `listBrowserTabs()`.

**Cause**: `listBrowserTabs()` reads the daemon's current focused-window tab list, which may lag 5-15 seconds behind `openTab()` for tabs in non-focused windows (per #1's "last-focused window" behavior).

**Fix — use the page handle returned by `openTab()` and pass it directly to `snapshot()`**:

```js
// ✅ works — track the page object directly
const p = await openTab('https://aistudio.google.com/rate-limit');
await new Promise(r => setTimeout(r, 8000));
const s = await snapshot(p);  // p is the page handle, not from listBrowserTabs
console.log(s.url);

// ❌ unreliable — listBrowserTabs lags
const tabs = await listBrowserTabs();
const aiStudio = tabs.find(t => t.url?.includes('aistudio'));  // may be undefined
const p2 = await attachBrowserTab(aiStudio.targetId);  // throws if aiStudio is undefined
```

The `p` returned by `openTab()` is a Playwright-compatible page handle (see #9). For LATER calls in the same flow, if the handle has been lost, re-acquire via `attachBrowserTab(tab.targetId)` where `tab` came from a `listBrowserTabs()` poll.

## 35. `p.title()` returns `{}` for some SPAs (Google AI Studio, Firebase console) — use `snapshot(p).title` instead

**Symptom** (verified 2026-09-16 AI Studio): `const t = await p.title()` returns an empty object (`{}`) for AI Studio URLs, even though `p.url()` returns the correct URL. `String(t)` produces `"[object Object]"` which is misleading.

**Cause**: AI Studio's SPA shell uses dynamic `<title>` updates that the CDP `Page.title` command misses on first call. The accessibility tree captured by `snapshot()` reads the resolved title from the DOM directly.

**Fix**:

```js
const p = await openTab('https://aistudio.google.com/rate-limit');
await new Promise(r => setTimeout(r, 8000));
const s = await snapshot(p);
console.log('title from snapshot:', s.title);  // "Rate Limit | Google AI Studio"
console.log('url from snapshot:', s.url);      // "https://aistudio.google.com/rate-limit"
```

**Alternative when you don't need a snapshot**: read `document.title` via `page.evaluate()` instead of the broken `p.title()` shortcut:

```js
const realTitle = await p.evaluate(() => document.title);
```

This bypasses the CDP `Page.title` cache and hits the live DOM.

## 36. `aside --effort ultrabrowse "<nl>"` and `aside "<nl>"` can fail with "Codex error: The usage limit has been reached" — fall back to scripted REPL immediately

**Symptom** (verified 2026-09-16 AI Studio quota check): Running `aside --effort ultrabrowse "Open aistudio.google.com/rate-limit and report the RPM/TPM/RPD for gemini-3.8-flash"` returns:

```
Error Codex error: The usage limit has been reached
```

within seconds, even though the user's Codex account is active and signed in. The NL agent never opens a tab.

**Cause**: Aside's NL agent is routed through Codex (or another vendor model) for planning, not the user's auth state. Codex's per-account quota can be exhausted independently of the user's. Retrying within the same minute re-hits the same wall.

**Fix — pivot to scripted REPL within seconds, do not retry the NL path**:

```bash
# ❌ do not retry NL — same wall for ~60s
aside --effort ultrabrowse "Open aistudio.google.com/rate-limit and report RPM"

# ✅ pivot to REPL — different code path, different quota
aside repl "const p = await openTab('https://aistudio.google.com/rate-limit'); await new Promise(r => setTimeout(r, 8000)); const s = await snapshot(p); console.log(s.tree.slice(0, 8000))"
```

The REPL path is the local daemon + local Chromium, no remote LLM. Quota-bypass recipes like Codex fallbacks don't unblock the NL agent — only time-pass does.

**Symptom variant**: if you see "Rate limit reached" or "429" mid-flow inside an `aside repl` call, that's the daemon's command budget, NOT the Codex NL budget. Wait 30-60s and retry.

## References

- `references/aistudio-rate-limit-check.md` — verified recipe for live
  AI Studio `/rate-limit` and `/usage` page scrapes (URL paths, REPL
  sequence, snapshot field extraction).