# Transport-ladder failure log — 2026-08-19 (sixth verification, worldarchitect.ai Archmage-mode design review)

## Dispatch

Reviewer D in /web-advice dispatch on `jleechanorg/worldarchitect.ai` `2026-08-19-archmage-mode-living-world-design.md` (159 lines). Goal: post a 5-question design review to **two** vendor web chat UIs and surface a verdict. chatgpt/perplexity SKIPPED per parent-dispatch note (Cloudflare-walled today).

## e2e_smoke verdict (verbatim)

```
===============================================================================
 /web-advice E2E transport smoke test — 2026-08-20T00:30:22Z
 Diagnostic only. No prompt was submitted to any model. No tab was opened.
===============================================================================
RUNG                     TRANSPORT                                STATE  DETAIL
----                     ---------                                -----  ------
1. Aside daemon          mcp__aside-mcp__repl / aside CLI         UP     2 account(s) signed in
2. Aside browser window  aside repl (real browser tabs)           UP     7 tab(s) currently open
3. Chrome CDP :9222      claude-in-chrome / CDP attach            DOWN   not listening (curl rc=0) — needs Chrome relaunched with --remote-debugging-port=9222, or extension Connect click
4. Chrome cookie DB      chrome-headless + browserclaw cookies    UP     present & readable, 896K (${HOME}/Library/Application Support/Google/Chrome/Default/Cookies)
-------------------------------------------------------------------------------
 3 of 4 rungs UP
```

Per skill §5 caveat: smoke rung-4 is shallow (cookie DB non-empty ≠ headless-inject works). Empirical rung-4 probe required.

## Empirical rung-4 probe (per skill §5)

### Gemini — UP

- Decrypt: `browserclaw cookies decrypt --db <cookies.sqlite> --output /tmp/c_<ts>.json --domain-filter '%google.com%'` → rc=0, 90 cookies, includes `__Secure-1PSID`/`OSID`/`SID`/`SAPISID`/`ACCOUNT_CHOOSER`.
- Inject: `browserclaw cookies inject --cookies /tmp/c_<ts>.json --goto https://gemini.google.com/app?model=gemini-2.5-flash --browser-channel chromium --headless --screenshot /tmp/gemini_new_<ts>.png --print-text 100000`. rc=0, 304770 bytes, real page text including "Gemini / Chat / Spark / BETA / New chat / Search chats / Daily brief / ... / Conversation with Gemini / Any new ideas to explore? / Flash / Extended". Auth-passed.

### Grok — DOWN (new rung-4 shape 4c)

- Decrypt attempts:
  - `--domain-filter '%xai%'` → 0 cookies
  - `--domain-filter '%grok.com%'` → 14 cookies, names: `grok_device_id, sso, sso-rw, OptanonAlertBoxClosed, cf_clearance, OptanonConsent, __cuid, __cuid` (client-side only, no `auth_token`)
  - `--domain-filter '%x.com%'` → 73 cookies, includes `auth_token, ct0, guest_id, personalization_id` (real X auth surface)
- Inject: `browserclaw cookies inject --cookies /tmp/cg3_x.com.json --goto https://grok.com/ --browser-channel chromium --headless --screenshot /tmp/grok_new_<ts>.png --print-text 100000`. rc=0, 47759 bytes, page text: "Skip to main content / Imagine / Sign in / Sign up / Grok / What do you want to know? / Fast / By messaging Grok, you agree to our Terms and Privacy Policy. / Your privacy choices / Close / Essential cookies keep the site working and stay on. ... / Cookies Settings / Accept All Cookies".
- Diagnosis: 73 cookies accepted, page shell renders, but `Sign in / Sign up` CTA replaced the composer. The X session token does not authenticate at the Grok vendor even though both are xAI products. Cookie-asymmetric SSO scope mismatch — distinct from 4a (Cloudflare/Google sign-in from anti-bot) and 4b (silent-hang).
- Action: STOP per §1 for Grok. Do not chase by decrypting more DB domains or fingerprint-spoofing. Unlock requires operator to open grok.com in their own browser and sign in directly.

## Aside REPL behavioral pitfall — caught fresh

- Skill already documents the "piped input goes interactive" pitfall (use one quoted arg).
- **New pitfall (this session):** IIFE wrapping causes premature exit. `(async () => { console.log('A'); await sleep(800); console.log('B'); })()` returns `[ok | 16ms]` with only `A` logged; same body as top-level statements `console.log('A'); await sleep(800); console.log('B');` returns `[ok | 1626ms]` with all three logs. The Aside REPL exits when the *outer* expression returns — it does not await an IIFE's returned Promise. **Fix: write scripts as flat top-level statement sequences, not wrapped in `(async () => { ... })()`.**
- Symptom of the bug: a long script that should take 30+ seconds returns in <100ms with only the first synchronous `console.log` captured.

## Vendor paste technique — concrete pattern (Gemini)

- Composer root: `DIV.ql-editor ql-blank textarea new-input-ui` (contenteditable=true).
- Cleanest paste path verified: `t.evaluate(() => { const root = document.querySelector('div.ql-editor[contenteditable="true"]'); root.focus(); root.click(); })` followed by `t.evaluate((p) => document.execCommand('insertText', false, p), promptString)`. Result: 3684 chars from a 3655-char prompt landed cleanly (the 29-char delta is whitespace normalization).
- `innerText` + synthetic `InputEvent` does NOT work — Angular's rich-text binding rejects it and the composer stays empty. The `execCommand` path triggers the framework's real input handler.
- Send button: `Array.from(document.querySelectorAll('button')).find(b => (b.getAttribute('aria-label')||'').toLowerCase().includes('send') || (b.getAttribute('data-test-id')||'').toLowerCase().includes('send') || b.innerText.trim().toLowerCase()==='send')`. Click works on `button` element directly.
- Poll for response: 3s interval, watch for `button[aria-label*="Stop" i]` to disappear (means generation done) AND `message-content` / `[data-message-author="model"]` to have a long innerText. Verified 38s round-trip on a 3655-char prompt.

## Round-trip deliverable

- Vendor: Google Gemini (gemini.google.com/app/f686be344c42400a, fresh isolated chat)
- Operator session: signed in (per skill §4: vendor data-handling trail is operator-attributable)
- Full response vaulted at `/tmp/review_d_gemini_response.txt` (4316 chars)
- Vendor verdict: "Approve with architectural revisions to concurrency control and strict 3-PR decomposition."
- Vendor key concern: "The lack of atomic campaign-level serialization between overlapping turn tasks creates silent state corruption and write-skew risks under rapid player input."
- Vendor confidence: High.

## Cross-check against artifact + local code

- `mvp_site/faction/tools.py` exists (598 LOC, 5 FACTION_TOOL_NAMES confirmed, execute_faction_tool router pattern). Design's "5 tools + router, mirroring dice.py" claim accurate.
- `mvp_site/dice.py` exists (1242 LOC). Pattern claim accurate.
- `god_mode_directives` exists in `mvp_site/game_state.py` (canonicalize fn at line 1568) and `mvp_site/game_state_mixins.py` (line 1347 init, line 1365 get, line 1381 block-builder). Design's "existing god_mode_directives[]" claim accurate.
- `BackgroundEvent` schema referenced in `mvp_site/frontend_v1/app.js` (lines 1858/1889/1901) and `mvp_site/tests/test_merge_background_events.py`. Design's "writes BackgroundEvent-shaped entries" claim accurate.

## Local design verdict (independent of vendor)

| Question | Verdict | Notes |
|---|---|---|
| Q1 per-action-only | Risky | "1999 Archmage feel" demands some wall-clock progression that pure per-action won't deliver. Vendor suggests lazy batch catch-up on next action as the zero-cron compromise; design doesn't mention this. |
| Q2 ZFC | Preserved IF | Filter must stay strictly relational (graph distance, discovery flags). The word "relevance" in the design is fuzzy and must be pinned to a deterministic field, not a subjective heuristic. |
| Q3 module placement | `mvp_site/world_sim/tools.py` (separate) | Avoids main-game router binding engine-level primitives. Vendor agrees. |
| Q4 idempotency | **Real gap** | Atomic `(campaign_id, turn_number)` processing lease required, not just an integer-staleness check. Design's Firestore lease exists for worker-id collision; it does NOT serialize per-turn task execution. |
| Q5 PR partition | 3 PRs | Vendor strongly recommends 3 PRs. User's stated preference is 1 PR. Worth surfacing the conflict because PR3 alone fixes the "LLM invents enemies" bug independent of the tick engine. |

## Files created this session

- `/tmp/review_d_prompt_*.txt` — the prompt text (3655 chars)
- `/tmp/review_d_gemini_response.txt` — vaulted Gemini response (4316 chars)
- `/tmp/c_*.json` — 90 Google cookies (decrypted, dec=0)
- `/tmp/cg3_*.json` — 73 x.com cookies (decrypted, dec=0)
- `/tmp/gemini_new_*.png` — 303KB probe screenshot
- `/tmp/grok_new_*.png` — 47KB probe screenshot
- `/tmp/review_d_post2_*.js` — top-level-await REPL script
- `/tmp/review_d_post_log_*.txt` — full Aside REPL transcript
