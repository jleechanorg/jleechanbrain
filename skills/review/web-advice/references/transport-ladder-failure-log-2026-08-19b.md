# Transport-ladder-failure-log-2026-08-19 (PR #9132 review run)

Fourth-consecutive-day verification of the same /web-advice transport-ladder fingerprint. Focus this run: **Aside REPL → ChatGPT** specifically (other seats not attempted because the user asked for review on a single PR and the Aside path was the only viable rung; we'd already established rung 3 + rung 4 are down per the 2026-08-19a file).

**Session:** Slack thread `C0BDEAJH8PK/p1787123062.649889`.
**Task dispatch:** /web-advice 4-rung probe as multi-model review for PR #9132 (`fix(action_resolution): suppress warning for non-player-action agents + prune stale recovery`).
**Ladder state at start:** 3 of 4 UP (Aside daemon + Aside window + Chrome cookie DB; CDP :9222 DOWN).

## Outcome

**0 of 4 panel seats reachable. Agent correctly STOPPED per §1.** Did NOT synthesize a fake 4-seat panel.

## Aside REPL → ChatGPT route gotchas (new this run)

The Aside REPL is the right path here (signed-in user, real browser, no headless anti-bot). But ChatGPT.com has THREE distinct routes that each behave differently — none of them documented in the SKILL.md body, all three bit this run:

| Route | What happened | Verdict |
|---|---|---|
| `openTab('https://chatgpt.com/')` | Page loaded fine, composer + paper-plane Send button visible (`Ask ChatGPT` placeholder). Logged in as `Jeffrey Nicholas / Personal account`. `keyboard.insertText` typed 13243 chars; composerLen read 13484. THEN `setInputFiles` on `locator('input[type="file"]').first()` produced **0 attachment chips** (silent fail). | **Silent-fail shape.** The verified-upload recipe in §242 requires going through the "Add files and more" button + `expect_file_chooser()` — using `setInputFiles` on the first `input[type="file"]` skips that lifecycle and the upload is silently absorbed by ChatGPT's hidden iframe. |
| `openTab('https://chatgpt.com/?model=o3')` | Page loaded, but **top of screen showed `❌ Something went wrong. If this issue persists please contact us through our help center at help.openai.com.`** | **Model-routing errror**. Adding `?model=` triggers a backend error page; the composer still renders but Send stays disabled. |
| `openTab('https://chatgpt.com/?model=gpt-5')` | Page loaded fine, but the send-arrow was **replaced with a waveform/audio icon** (voice-mode composer). No text-Send control. | **Voice-mode composer only.** Different model id forces voice-mode UI, no text-submit path. |
| `openTab('https://chatgpt.com/c/default')` | Page loaded clean ("Hey, Jeffrey. Ready to dive in?"), composer + waveform icon, **no text-Send button visible**. | **Voice-mode composer only even on bare `/c/default`** in this session — try a different conversation-routing URL or clear cookies for chatgpt.com. |

## Why all three are dead ends, not edge cases

The skill already documents the **ChatGPT dead-end at §131** — verified 3 ways (cookie-copy kills the `.auth.openai.com` security-hardened cookies, plain-headless hits Cloudflare, CDP extension not connected). The new finding here is **Aside REPL doesn't get past the dead-end either**. Once you've burned the session typing, pasting, and probing routes, the conversation URL can't even be opened because there's no real review to share.

## Aside REPL API shape (captured for future agents)

Aside CLI 1.26.818.1059 — confirmed live this run:

- `listBrowserTabs()` returns a **Promise** → `await` it → resolved value is an array of plain tab-info objects with `url`, `title`, `id`, `active` as **properties**, not methods. `t.url()` throws `t.url is not a function`.
- The Page object from `openTab()` is Playwright-shaped for locators but **does NOT expose `waitForTimeout()`**. Use `await new Promise(r => setTimeout(r, N))` for pacing.
- The `aside repl` REPL echoes back `[ok | Nms]` for every expression, **even ones with side effects**; you only know what actually ran by capturing console.log output between `repl.js:` lines.

The `aside repl` ALSO **silently strips backslash-escapes** in template-literal strings. `13243` chars of prompt text survived `Buffer.from('<base64>').toString('utf8')` roundtrip cleanly; raw `\\n` in source got mangled. **For any prompt >2KB: base64-encode it in Python, then `Buffer.from(promptB64, 'base64').toString('utf8')` inside the JS, instead of inlining as a template literal.**

## What WOULD have unblocked

Same as 2026-08-19a: operator clicks **Connect** on the Chrome Remote Debugger extension (the popup that blocked `browser_exec` is the same one). Until then: default ChatGPT to its documented dead-end, do not burn 30+ tool calls trying every route.

## 2026-08-19 (late) — verified *no such unblock script exists*

Follow-up thread root `C0BDEAJH8PK/p1787181286` reached the operator asking "remote debugging is already enabled, why isn't it working." Direct probe of the user's environment contradicted the cron reminder:
- `bash ${HOME}/.smartclaw/scripts/browser-harness-mac-approve.sh --status` returned `No such file or directory` — the script the prior cron reminder cited **does not exist** anywhere on disk (`find /Users/jleechan -maxdepth 6 -type f \( -name "*approve*" -o -name "*harness*mac*" \)` returns only unrelated `cmux-codex-autoapprove` / social-poster `post_approved.py`).
- `lsof -nP -iTCP:9222 -sTCP:LISTEN` showed Chrome PID 58212 already bound to 9222, but `curl http://127.0.0.1:9222/json/version` returns **HTTP 404** and `/json/list` returns blank — the port is bound but the DevTools HTTP service is not advertised (a different fingerprint from "port not listening" or "extension not connected"). Cron's prior reminder both named the wrong script AND misclassified the rung-3 state.
- The real Chrome binding is fine; the bug is in the HTTP debugger surface, not Chrome argv. The remedy is `osascript -e 'quit app "Google Chrome"' && sleep 2 && open -a "Google Chrome" --args --remote-debugging-port=9222` which loses operator open-tab state — explicitly operator-approved action, not "click this single Allow button" as the prior reminder claimed.
- The corollary finding from history+ms search: /web-advice transport-ladder has been DOWN since 2026-08-17 across 5+ independent runs. Prior successes on EDD audit packets were via `read-gemini-share-link`, not /web-advice. Operator voice "its worked before why isnt it wokring now" reflects a real expectation mismatch — the skill has *never* worked on /web-advice in the recorded window; the operator's recollection is of `read-gemini-share-link` runs, which is a different transport.

## Pitfall candidates to consider adding to SKILL.md body

(Listed here for review, not auto-promoted — both are session-specific observations and may harden into durable rules on a 3rd independent observation.)

1. **`setInputFiles` on `chatgpt.com` first `input[type=file]` is a silent no-op — always go through the "Add files and more" button + `expect_file_chooser()` per §242, never bare `.first()`.** This is the ChatGPT equivalent of the Grok 6-input selector ambiguity already in §242.
2. **Aside REPL `\[ok | Nms\]` echoes are not value returns** — wrap every probe in `console.log` and read the stdout between `repl.js:` markers.

## PR-side outcome (separate from /web-advice outcome)

The /rg RED→GREEN phase ran cleanly in the same session and surfaced no new findings beyond what the test suite already covered. PR #9132 is N-green; awaits `MERGE APPROVED`.
