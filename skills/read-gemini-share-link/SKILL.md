---
name: read-gemini-share-link
version: 1.0.0
description: |
  Read a Google Gemini share link (gemini.google.com/share/<id>) and capture the
  full conversation content. Uses browserclaw to decrypt Chrome cookies for
  google.com and inject them into a headless Chromium so the user's signed-in
  Google session loads the JS-rendered share page. Verified 2026-08-10 against
  share.gemini.google/hZXboZihmwYc (50K char capture, full conversation).
when_to_use: |
  Use when the user pastes a `gemini.google.com/share/<id>` or
  `share.gemini.google/<id>` link and asks to read, save, summarize, or extract
  the conversation content. Triggers on "read this Gemini link", "capture this
  Gemini share", "what does this gemini.google.com link say", "get the content
  from <gemini share URL>".
triggers:
  - "read this gemini link"
  - "capture this gemini share"
  - "what does this gemini.google.com link say"
  - "get the content from <gemini share URL>"
  - "gemini.google.com/share"
  - "share.gemini.google"
allowed-tools:
  - Read
  - Write
  - Bash
context: inline
---

# Read a Google Gemini Share Link

The recipe that works for Google's Gemini share pages, which are JS-rendered
SPAs. As of 2026-08-10, there is **no auth gate** — the user can open a
share link in any browser (including incognito) and read the full
conversation. The page is public. What looks like an auth gate is just
Google's chrome (the "Sign in" button in the nav overlay); the conversation
itself renders for unauthenticated users.

The capture challenge is **not** auth — it is **JS hydration**. The static
HTML returned by `curl` does NOT contain the conversation; the data is
fetched via `batchexecute` calls after the page renders. You need a real
browser, not a text-mode HTTP client.

## Anti-Patterns (DO NOT DO)

1. ❌ **Static HTML extraction** — `curl -sL <url> | grep` returns 800KB of
   shell HTML with `AF_initDataCallback` blobs. The conversation data is NOT
   in the static HTML; it is fetched via `batchexecute` calls after page
   load. No amount of grep magic will recover the conversation.

2. ❌ **Declaring the share page "auth-gated" without verifying.** Gemini
   share pages render publicly. The first time the agent in this session saw
   an empty auth shell, it was the JS-not-hydrated-yet shell, not an auth
   gate. Always check `conversations.history` style screenshots from the
   user before assuming auth.

3. ❌ **Aside REPL `openTab`** with `browser_navigate` against
   `gemini.google.com/share/<id>` — the REPL sometimes returns "Link doesn't
   exist" before hydration completes. If you must use Aside, wait >12s after
   `openTab` before snapshotting.

4. ❌ **Googlebot User-Agent spoofing** — does not bypass any session gate,
   because there is no session gate to bypass.

## The Working Recipe (browserclaw + Playwright Chromium)

The simplest path is to load the share URL in a headless Chromium and dump
the rendered text. Google does not require sign-in to view a share link; any
recent Chrome / Chromium with a normal User-Agent will render the page.

### Step 1 — Confirm the link is public

Open the URL in a private/incognito window first. If the conversation renders
without sign-in, there is no auth gate and you can skip the cookie path. If
it does NOT render in incognito, then you have a genuinely auth-gated share
and need the browserclaw cookies inject path (Step 2 below).

### Step 2 — Capture with headless Chromium (no auth needed for public shares)

```bash
# Use the browserclaw cookies inject path; cookies bundle is harmless if not needed
browserclaw cookies inject \
  --cookies /tmp/google-cookies.json \
  --goto "https://gemini.google.com/share/<SHARE_ID>" \
  --browser-channel chromium \
  --headless \
  --wait-after-load 12 \
  --screenshot /tmp/gemini_share.png \
  --print-text 50000 > /tmp/gemini_full.txt
```

**Verified parameters (2026-08-10):**

| Flag | Value | Why |
|---|---|---|
| `--browser-channel` | `chromium` | Playwright test build; lighter than installed Chrome |
| `--headless` | required | Per `browser-headless-default` SOUL.md commit |
| `--wait-after-load` | `12` | Gemini share is a JS SPA; <8s misses the conversation render, 12s is safe for ~50K chars of content |
| `--print-text` | `50000` | Sufficient for any Gemini conversation; raise to 200000 for very long ones |
| `--screenshot` | optional | Saves evidence PNG |

The `--cookies` flag is passed even for public-share captures because it is
harmless and the cookies bundle may help avoid Google's anti-bot interstitials
on future captures.

### Step 3 (alternative) — Plain Playwright Chromium without cookies

If you don't want to maintain a cookies file, this is even simpler:

```python
# Save as /tmp/capture_gemini.py and run with: python3 /tmp/capture_gemini.py
from playwright.sync_api import sync_playwright

with sync_playwright() as p:
    browser = p.chromium.launch(headless=True)
    page = browser.new_page()
    page.goto("https://gemini.google.com/share/<SHARE_ID>", wait_until="networkidle", timeout=30000)
    page.wait_for_timeout(12000)  # let JS hydrate
    text = page.evaluate("document.body.innerText")
    page.screenshot(path="/tmp/gemini_share.png", full_page=True)
    open("/tmp/gemini_full.txt", "w").write(text)
    browser.close()
print("CAPTURED:", len(text), "chars")
```

This works for any public Gemini share link. The earlier session's belief
that "auth gate" was the blocker was wrong — JS hydration was the blocker.

### Step 4 — Verify the capture

```bash
wc -c /tmp/gemini_full.txt
# expect: ~50K chars for a normal conversation, 100K+ for long ones
```

The captured text contains alternating `You said` / response blocks with
`Response Metrics` (word count, estimated token count) at the end of each
response turn.

## Failure Modes

| Symptom | Likely cause | Fix |
|---|---|---|
| Page loads but `--- Page text ---` body is empty | JS hydration did not complete in time | Bump `--wait-after-load` to 20–30s; or use the plain Playwright script in Step 3 with `wait_until="networkidle"` + 12s extra wait |
| Page shows a CAPTCHA before the conversation | Google's anti-bot heuristic has fired (rare on public shares) | Wait 30–60 minutes; do not retry immediately (escalates the block) |
| Conversation truncated at ~5K chars when the Gemini chat is much longer | `--print-text` cap is too low | Re-run with `--print-text 200000` |
| Side-channel link required (e.g. `share.gemini.google/<id>` 301s to a different URL) | Gemini publishes share links as a short ID that 301-redirects to a longer one | Follow the redirect; both URLs serve the same content |
| Browserclaw returns `Wrote 0 cookies` | Wrong `--domain-filter` or wrong Chrome profile | Drop filter to `%` or check `Profile 1/Cookies`, `Profile 3/Cookies` |
| `Keychain lookup failed for service='Chrome Safe Storage'` | User clicked "Deny" on the Keychain prompt | Open Keychain Access.app, search for `Chrome Safe Storage`; re-run and click "Always Allow" |
| `BrowserType.launch: Executable doesn't exist` | Playwright browsers not installed | `python -m playwright install chromium` |

## Cross-References

- `~/.smartclaw/skills/browserclaw/SKILL.md` — full cookie decrypt + inject reference (used as the headless-Chromium harness)
- `~/.smartclaw/skills/read-auth-gated-share-links-with-browserclaw/` — companion skill for **genuinely** auth-gated vendor share links (LinkedIn DMs, Slack threads, bank messages, vendor share dialogs that DO require sign-in)
- `~/.smartclaw/skills/auth-gated-site-read/SKILL.md` — broader auth-gated site read patterns via Aside
- `~/.smartclaw/skills/evidence-attach-to-slack/SKILL.md` — 3-stage upload protocol for attaching the screenshot PNG to Slack without leaking the path as literal text

## Provenance

This recipe was first verified 2026-08-10 against
`https://share.gemini.google/hZXboZihmwYc` in the Supergirl campaign capture
session. Captured content was 50,224 chars covering a six-turn iterative
campaign design dialogue. Updated 2026-08-10 after user pointed out that
Gemini share pages are public (no auth gate) — the JS-hydration framing
replaced the auth-gate framing. The full capture + the resulting campaign
bible landed at [jleechanorg/llm-wiki PR #24](https://github.com/jleechanorg/llm-wiki/pull/24).
