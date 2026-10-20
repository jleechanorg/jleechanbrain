# Transport-ladder failure log — 2026-08-17 (EDD audit review run)

Verbatim transcript from a real `/web-advice` attempt that hard-stopped on §1. Capture as a baseline for future failures: if a new run looks similar, you can copy this report shape and substitute the new probe output.

## Setup

- Operator: Jeffrey Lee-Chan (jleechan, U09GH5BR3QU)
- Slack thread: C0AMM2B4319/p1787036255.121579
- Underlying task: 5-answer EDD audit reply packet (Structure Law Group / Jorge Martins) reviewed by 4 web LLMs
- Pre-flight script: `bash ~/.claude-wa/skills/web-advice/scripts/e2e_smoke.sh`

## e2e_smoke verbatim output

```
===============================================================================
 /web-advice E2E transport smoke test — 2026-08-18T07:35:15Z
 Diagnostic only. No prompt was submitted to any model. No tab was opened.
===============================================================================
RUNG                     TRANSPORT                                STATE  DETAIL
----                     ---------                                -----  ------
1. Aside daemon          mcp__aside-mcp__repl / aside CLI         UP     2 account(s) signed in
2. Aside browser window  aside repl (real browser tabs)           UP     3 tab(s) currently open
3. Chrome CDP :9222      claude-in-chrome / CDP attach            DOWN   not listening (curl rc=0) — needs Chrome relaunched with --remote-debugging-port=9222, or extension Connect click
4. Chrome cookie DB      chrome-headless + browserclaw cookies    UP     present & readable, 896K (${HOME}/Library/Application Support/Google/Chrome/Default/Cookies)
-------------------------------------------------------------------------------
 3 of 4 rungs UP
```

## Why rung 3 stayed DOWN

Primary Chrome (PID 642) had `--remote-debugging-port=9222` argv but `lsof -nP :9222 -sTCP:LISTEN` returned nothing across 4 attempts. Tried:

- `osascript 'tell application "Google Chrome" to quit'` then `open -ga "...Google Chrome.app" --args --remote-debugging-port=9222 --no-sandbox --no-first-run` — Chrome process restarted but never bound TCP
- `killall -KILL "Google Chrome"` then fresh `open` — process came back as PID 63917 with the flag in argv but still didn't bind
- Manual `kill -9 60472` + relaunch — same outcome

Symptom: macOS Chrome 151 silently refuses to honor `--remote-debugging-port` in some macOS-15.5 states. **Operator fix**: open Chrome with `chrome://inspect/#remote-debugging` or click Connect on the Chrome Remote Debugger extension.

## Why rung 4 (cookie-inject headless) failed

`browserclaw cookies inject --browser-channel chromium --headless` against each of 4 vendor sites with valid decrypted cookies:

| Site | URL | Page title | Body excerpt | Verdict |
|---|---|---|---|---|
| ChatGPT | `https://chatgpt.com/` | "Just a moment..." | (empty) | Cloudflare |
| Grok | `https://grok.com/` | "Grok" | (empty) | Cloudflare |
| Perplexity | `https://www.perplexity.ai/` | "Just a moment..." | "Performing security verification ... Ray ID a2cf6ef8ee181f54" | Cloudflare |
| Gemini | `https://gemini.google.com/` | "Google Gemini" | "Sign in / New chat / Sign in to save activity" | Cookie domain mismatch |

Decrypted cookie counts: 25 chatgpt.com / 15 grok.com / 14 perplexity.ai / 5 gemini.google.com / 7 accounts.google.com.

Gemini auth cookies live at `accounts.google.com`, not `gemini.google.com`. Always broad-domain decrypt for Google.

## Why Aside `openTab` lost tabs

`listBrowserTabs()` reported 3 tabs after opening chatgpt.com / gemini.google.com / grok.com / perplexity.ai via 4 separate `openTab` calls. Returned list was:
- `gemini.google.com/app/572f57e437426716` (existing — RP / XP-bug thread, NOT fresh chat)
- `http://localhost:8081/game/LPJW5VT77Pxxvp5dRHdU` (localhost game)
- `http://localhost:8081/game/QcwsDc1PBovsJwZI6Kvb` (localhost game)

3 of 4 `openTab` calls returned successfully, but the chatgpt / grok / perplexity tabs got silently closed (likely Aside window-focus rotation closing inactive tabs). Operator override path: use Chrome directly, not Aside.

## Outcome

§1 hard-stop triggered. Reported verbatim state to operator, no chat URLs fabricated, no in-session fallback used. Operator's stated next move (after this stop): would have been to click Connect on Chrome Remote Debugger to flip rung 3 green.

## What to do if a run looks like this

1. Surface the table (UP/DOWN with details) verbatim.
2. Surface each cookie-inject attempt with title + body excerpt.
3. Propose ONE concrete operator action — not a multi-option menu.
4. Do NOT propose "let's try Playwright with fingerprint spoofing" — that is a `STOP` per §1 and ought not become a recommended path.
