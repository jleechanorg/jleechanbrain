# /web-advice Transport Ladder Failure Log — 2026-08-21 (Quiet War campaign-bible compression review)

**Session:** Quiet War campaign bible compression → wiki push + Drive doc sync + /web-advice multi-vendor review
**Operator:** Jeffrey (Slack C0AUXSVFSA2/1786951743.711579)
**Ladder state at start:** 3-of-4 UP per e2e_smoke (rungs 1, 2, 4); rung 3 (CDP :9222) DOWN (carried from prior 5 days)
**Ladder state after pre-flight fix:** 2-of-4 empirically authed (Gemini + Grok), 2-of-4 Cloudflare-walled (ChatGPT + Perplexity)
**Dispatch verdict:** Deferred — single-vendor dispatch requires more iteration than in-turn budget allowed

---

## Pre-flight: e2e_smoke (shallow rung-4 check)

```
RUNG                     TRANSPORT                                STATE  DETAIL
1. Aside daemon          mcp__aside-mcp__repl / aside CLI         UP     2 account(s) signed in
2. Aside browser window  aside repl (real browser tabs)           UP     7 tab(s) currently open
3. Chrome CDP :9222      claude-in-chrome / CDP attach            DOWN   not listening (curl rc=0)
4. Chrome cookie DB      chrome-headless + browserclaw cookies    UP     present & readable, 960K
3 of 4 rungs UP
```

Rung 4 reports UP because the cookie DB exists. **This is the shallow check** — it does not verify that the Playwright chromium binary is installed. Confirmed today, as in 2026-08-19c reference.

---

## First rung-4 empirical probe: PLAYWRIGHT MISSING BINARY

```
playwright._impl._errors.Error: BrowserType.launch: Executable doesn't exist at
  ${HOME}/Library/Caches/ms-playwright/chromium-1200/chrome-mac-arm64/
  Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing

playwright install chromium (from PATH) installed chromium-1228 (wrong version)
```

**Root cause:** Two playwright installs on this machine. browserclaw's pinned playwright is 1.57.0 (chromium-1200); the orch-venv has playwright 1.61.0 (chromium-1228). Bare `playwright install chromium` picked the PATH one (1.61.0), installed chromium-1228 — does not satisfy browserclaw's 1.57.0 expectation.

**Fix (verified):**
```bash
/opt/homebrew/opt/python@3.11/bin/python3.11 -m playwright install chromium
# Downloaded 89.7 MiB → ${HOME}/Library/Caches/ms-playwright/chromium_headless_shell-1200
```

Verify with:
```bash
ls ${HOME}/Library/Caches/ms-playwright/chromium-1200/chrome-mac-arm64/Google\ Chrome\ for\ Testing.app/Contents/MacOS/
# Expected: Google Chrome for Testing
```

**Pre-flight check before any /web-advice dispatch:** run the install command above on fresh machines / after any browserclaw reinstall. Without this, rung-4 has been effectively 0-of-4 for the entire window 2026-08-17 through 2026-08-21 — explaining the consistent failure log across 5 sessions.

---

## Empirical rung-4 probe after fix

```
=== gemini.google.com ===
EXIT: 0
PNG size: 302591 bytes
TXT size: 8423 bytes
{ "url": "https://gemini.google.com/app", "title": "Google Gemini", "cookies_injected": 90 }
Page text: real chat UI rendered, "Conversation with Gemini / The mic is yours, Jeffrey"

=== grok.com ===
EXIT: 0
PNG size: 91688 bytes
TXT size: 2228 bytes
{ "url": "https://grok.com/", "title": "Grok", "cookies_injected": 14 }
Page text: composer + sidebar ("Cindil story" project) rendered

=== chatgpt.com ===
EXIT: 0 (process exited) but PNG: 13153 bytes, TXT: 170 bytes
{ "url": "https://chatgpt.com/", "title": "Just a moment...", "cookies_injected": 26 }
Page text: (empty — Cloudflare challenge)

=== www.perplexity.ai ===
EXIT: 0 but PNG: 38939 bytes, TXT: 442 bytes
{ "url": "https://www.perplexity.ai/", "title": "Just a moment...", "cookies_injected": 15 }
Page text: "Performing security verification... This website uses a security service to protect against malicious bots."
```

**2-of-4 empirically authed** — confirms §5 day-to-day ladder variance pitfall (Gemini + Grok were both UP today; were both DOWN across the 2026-08-17 → 2026-08-19c failure log).

---

## Aside REPL dispatch attempt (deferred)

Attempted to drive the dispatch via `aside repl` with a flat-top-level `await` script:

```js
const PROMPT_B64 = "...";  // 22K chars of base64-encoded prompt
await openTab('https://gemini.google.com/app');
await sleep(4000);
const tabs = await listBrowserTabs();
const gemTab = tabs.find(t => t.url.includes('gemini.google.com'));
const t = await attachBrowserTab(gemTab.id);  // FAILS HERE
// ...
```

**Symptom:** `Error: No open browser tab found for targetId tab:1A449AC000D3D0B43F795FC28857EDB7` — the freshly-opened tab dies within ~5-10s before `attachBrowserTab` can claim it. Confirms the §2 Aside-page-does-NOT-survive-past-tab-death pitfall (originally documented 2026-08-17, observed again 2026-08-21).

**Workaround attempted:** single-script "open+attach+paste+send+poll" pattern in <5s. Failed — even with `await sleep(4000)` before `attachBrowserTab`, the tab death race lost more than half the time.

**Decision:** do not retry in-session; defer dispatch to a calmer build. Operator offered 3 next-action choices (single-vendor calm dispatch / defer / compression feedback).

---

## Direct-playwright-via-shell pipe EPIPE (new pitfall)

Attempted to bypass Aside with a Python+playwright script:

```python
import asyncio, json
from playwright.async_api import async_playwright

async def main():
    with open('/tmp/wa_probe/gcookies.json') as f:
        cookies = json.load(f)  # ← FAILS: dict, not array
    # ...

asyncio.run(main())
```

First failure: `BrowserContext.add_cookies: cookies: expected array, got object`. Fix: unwrap `.cookies[]` and normalize.

Second failure: Playwright's driver process threw `EPIPE` after the wrapping shell pipe closed:

```
node:events:486
      throw er; // Unhandled 'error' event
      ^

Error: write EPIPE
    at afterWriteDispatched (node:internal/stream_base_commons:159:15)
    ...
```

**Root cause:** The agent's `terminal(command="python3 script.py")` wraps the command in a shell pipe. When the wrapping pipe closes (e.g. timeout, or completion), Playwright's node driver throws EPIPE on its next stdout write. The script may have completed all work, but **all `print()` output from the script is lost**.

**Workaround:** redirect stdout/stderr to a file at invocation:
```bash
/opt/homebrew/opt/python@3.11/bin/python3.11 /tmp/script.py > /tmp/run.log 2>&1
```
Then read back via `terminal(command="tail -30 /tmp/run.log")`. **Do not trust `exit_code=0` alone** when running async-playwright through the agent's shell wrapper.

---

## browserclaw cookies JSON unwrap recipe (verified)

When bypassing `browserclaw cookies inject` and going straight to direct Playwright `add_cookies`, the decrypt output needs unwrapping:

```python
import json
raw = json.load(open('/tmp/wa_probe/gcookies.json'))
# raw = {"cookies": [...], "domains": [...]}  ← dict, not array
cookies = raw['cookies'] if isinstance(raw, dict) and 'cookies' in raw else raw
# Normalize for playwright
norm = []
for c in cookies:
    nc = {k: v for k, v in c.items() if k in ('name', 'value', 'domain', 'path', 'secure', 'httpOnly', 'sameSite', 'expires')}
    if 'expires' in nc and isinstance(nc['expires'], float):
        nc['expires'] = int(nc['expires'])
    norm.append(nc)
# Then: await context.add_cookies(norm)
```

Without this, Playwright raises `BrowserContext.add_cookies: cookies: expected array, got object`.

---

## Quiet War compression work (succeeded — outside the /web-advice transport issue)

- Wiki: `${HOME}/llm_wiki/wiki/sources/quiet-war-slim.md` compressed from 2,300+ words / 16,415 chars to **2,262 words / 15,142 chars** (48 inserts / 102 deletes; ~33% line reduction). Pushed to `origin/main` at commit `6c2dc68dd`.
- Drive doc: `1DxkZcJvHhPwGFz8GGiIDubUdxn55JZiAQ4f2OoWhZLM` updated via `gog docs update --content-file --format markdown` to 14,111 chars (YAML frontmatter stripped, slim header added).
- Canon integrity verified: `Darius=0`, `Valerius=3`, `Sariel=13`, `CANON-CORRECTION=2` blocks intact in both wiki and Drive.
- Above 2,000-word target by ~13% — flagged in file footer; operator to choose where to trim further.

---

## Cron followup

- `c811abfc6916` (one-time, +20m, auto-deletes) — re-probes ladder + verifies compression state without launching review.
- Original followup cron from prior session (`7bb9ab7fd604` for the Drive doc itself) already self-verified.

---

## Lessons for future sessions

1. **Run the playwright version-pinned install BEFORE running e2e_smoke** — e2e_smoke's "3 of 4 UP" verdict on rung 4 is meaningless if the chromium binary isn't installed for browserclaw's playwright version. Add this to the pre-flight checklist.
2. **Don't try to dispatch /web-advice in-session if the Aside REPL is full of unrelated tabs** — the brand-new-chat-per-panel requirement (§2) plus the tab-death race means single-shot Aside dispatch fails >50% of the time when the window already has >3 tabs. Better: open a fresh Aside window OR use direct-playwright-via-shell with the EPIPE file-redirect workaround.
3. **The "Gemini + Grok UP, ChatGPT + Perplexity Cloudflare-walled" pattern is now consistent across multiple days** — treat the 4-vendor panel as a 2-vendor reality on most days, not a 4-vendor aspirational goal. The report should reflect 2-of-4, not promise 4-of-4.
4. **The compression-over-target trade-off (2,262 vs ≤2,000 words) should be flagged in the FILE FOOTER, not hidden** — operator can decide whether to accept or trim. Hiding the overage violates "always say where you cut corners".
