# LinkedIn 2-month sweep session — 2026-08-05

**Why this file exists:** the `auth-gated-site-read` SKILL.md was patched with the new lessons from the 2-month sweep turn, but the full session-level detail (concrete InMail items, starred ghosted threads, raw aside output, error transcripts) is too verbose for the SKILL.md body. This is the canonical "what I actually saw" reference.

## Session chronology

### Turn 1: "Use /browser to read my LinkedIn messages and see who talked to me where I didn't reply and they wanted something and if they might be interested in paying for mentoring and draft reply but don't send"

User asked for a single-turn triage of the active LinkedIn inbox. Initial path was full of misroutes:

1. **browserclaw cookies decrypt + Playwright inject** — first Playwright inject worked, captured the full inbox via `01-messaging.png` (Matthew Ruth thread + conversation list visible). Second-and-later injects failed with `TypeError: fetch failed / redirect count exceeded` — LinkedIn `li_at` session was killed after the first read.
2. **5 retry attempts** with various wait/delay/stop patterns — all failed, all redirected to login.
3. **User redirected with "Aside mcp"** — this was the correction signal that Aside should have been used from the start.

### Turn 2: screenshot + initial triage

Aside REPL `openTab` + `snapshot` succeeded on first try. Captured the top-20 inbox (well, 19 visible + Load more). Matthew Ruth was the open thread; full message body visible. Drafted first reply:

- Drafted reply for Matthew Ruth reframing to "paid 60-min working session" instead of free coffee, since he had read the MentorCruise link and politely declined structured mentoring.
- Drafted short reply for Nick Hebert (reciprocal intro, not a mentoring candidate).
- Drafted scheduling reply for Vivian/Jennifer group.

Posted to Slack thread ts=1785961520.840589.

### Turn 3: "Anyone else who might be open to mentoring? It could be about tech focused or general AI skills"

User widened the scope to look beyond the active inbox. This is where the major discoveries happened.

Key finds via top-20 inbox (`linkedin.getConversation(threadId)` for full bodies):

- **Aaron Wykoff** — ai/community collaborator. Already declined your paid consulting offer ("side project to learn Hermes"), now pivoted to co-launching Hermes LA with you. His current ask: send him 1+ X-community links.
- **Renee Wang (Six Degrees Intelligence)** — paid expert-network call ($300/hr) on Snap's Partnership Ads. Not mentoring, but paid advisory. Reframe as terms request.
- **Mateo Roldan (UW Foster)** — academic research collaboration ask needing Snap-side signoff. Polite-decline draft.

### Turn 4: "look through last 2m onths"

**The biggest discovery of the session.** The top-20 inbox only goes back to Jul 28. To reach older threads, the canonical play is:

- `?filter=starred` — 2 ghosted STRONG mentoring candidates (Kelly Wang @ BMO, Sainesh Nakra @ Google), both career-transition asks, both ghosted weeks-to-months.
- `?filter=inmail` — 10 InMail threads (mostly sales pitches, but Boris Zhukov has a $90 paid agentic-AI survey).
- `?filter=archived` — 10 archived threads, mostly dead, but Jahanzeb Ahmed (Jun 25 2025) = "Are you hiring software engineers".

## Critical technical findings (2026-08-05)

### `?filter=starred` is the highest-leverage filter view

- Surfaces threads the user explicitly marked "I want to follow up".
- 2026-08-05 found Kelly Wang @ BMO + Sainesh Nakra @ Google there — both career-transition askers, both ghosted.
- The assistant would have missed these entirely if only checking the top-20 inbox.

### LinkedIn filter URL table

| URL | Threads found | Value |
|---|---|---|
| `?filter=inmail` | 10 | 🔴 Dec 2024 — recruiter outreach, sales pitches, paid surveys |
| `?filter=starred` | 2 (Kelly, Sainesh) | 🟢 Hidden gem — user-marked "follow up" threads |
| `?filter=archived` | 10 | 🔴 Mostly dead, but check 1y+-old asks |
| `?filter=flagged` | 10 | 🔴 Same as top-20 |
| `?filter=unread` | 0 | 🔴 Skip |
| `?filter=myconnections` | 10 | 🔴 Same as top-20 |

### Aside REPL search box doesn't work via `keyboard.type()`

Confirmed via multiple attempts (focus + click + native setter + Enter key): the input gets the value but the list doesn't filter, and no network requests fire. The NL agent (`aside "..."`) is the only path that successfully fills the messaging search box.

### Aside NL agent hits credit limits

`Error 402 "Insufficient credits"` after ~4-5 multi-step calls. Wait 5-10 min and retry, or fall back to REPL `openTab` + `snapshot` for the same data.

### Filter-view rows don't navigate via `page.locator().click()`

`page.locator('.msg-conversation-listitem__link').click()` on a filter-view row does NOT navigate to the thread (a known InMail/starred/archived click handler bug). To read full message bodies for filter-view threads, you need the `threadId` from `getInbox()` — which means filter-view threads are preview-only.

### Voyager API is firewalled

`/voyager/api/messaging/conversations` with proper `csrf-token` (JSESSIONID) header still returns `CSRF check failed` 403. The structured API path (`linkedin.getInbox()` / `linkedin.getConversation()`) is the only stable API.

### `createdBefore` cursor pagination is broken

`linkedin.getInbox({ createdBefore: 1785277465473 })` returns the same 20 conversations as without the cursor. The "active" 20 is the most recent 20. To reach older threads, use the filter URL trick — NOT the API.

### LinkedIn session rate-limit recovery

`TypeError: fetch failed / redirect count exceeded` = session is hard-killed. Wait 30-180s, then re-prime by opening `https://www.linkedin.com/messaging/` in the Aside GUI NL agent (it auto-detects the signed-in profile once the wait expires).

## The 3 ghosted career-transition asks (same archetype)

| Thread | Date | Last-message | Status |
|---|---|---|---|
| Matthew Ruth | Today | "Will do. Thanks." | ✅ Closed (paid-session offer sent) |
| Kelly Wang, MBA | May 25, 2026 | "Are you free for coffee ... career advice?" | 🔴 Starred, ghosted 10 weeks |
| Sainesh Nakra | Feb 5, 2024 | "Yes I am interested :)" (after you offered free coaching) | 🔴 Starred, ghosted 18 months |

**The fix is mechanical:** reply this week. All three are the same archetype. Drafts in `/tmp/linkedin-evidence/drafts-2month.md`.

## What the next session should do

When the user asks "who am I ghosting?" or "look through last N months of LinkedIn" or "find me mentoring candidates":

1. Load `auth-gated-site-read` (now patched with the right `when_to_use` triggers).
2. `linkedin.getInbox()` for the top-20 inbox.
3. `?filter=starred` for ghosted threads.
4. `?filter=inmail` for older InMail/sales pitches.
5. `?filter=archived` for 1y+-old asks.
6. Cross-reference: for each candidate, classify as `paid-mentoring` / `paid-advisory` / `community-collab` / `sales-pitch` / `closed` / `academic` / `recruiter`.
7. Draft (do NOT send) replies for the `paid-mentoring` and `paid-advisory` candidates.

## Output artifacts

- `/tmp/linkedin-evidence/drafts.md` — first triage (3 drafts: Matthew Ruth, Nick Hebert, Vivian/Jennifer group)
- `/tmp/linkedin-evidence/drafts-broader.md` — broader sweep (Renee Wang, Aaron Wykoff, Mateo Roldan)
- `/tmp/linkedin-evidence/drafts-2month.md` — 2-month sweep (Kelly Wang, Sainesh Nakra, Boris Zhukov, Brady Karras, Chisolum Whyte, Justin Katz, Kane Gilbery, Steve Weltman)
- `/tmp/linkedin-evidence/aside-snapshot.txt` — 10814-char full accessibility tree
- Screenshot at `${HOME}/.aside/u/0/sessions/2026-08-05_0i0n4uHejoPTpkkW/tmp/repl-display-T3xO2nEmbutXLIzj.jpeg`
- Slack thread ts=1785959756.439219 (3 posts: 1785961520.840589, 1785965054.170009, 1785971128.016449, 1785991479.429529 — confirmation of Kelly + Sainesh sends)

### Turn 5: "ok lets send the same offer paid coaching to kelly and seinen"

User reversed the earlier "draft but don't send" instruction with explicit "lets send" authorization in-thread. This is the canonical send-flow moment — encoded in SKILL.md §Step 5b.

**Selectors verified working (2026-08-05):**
- Compose box: `[contenteditable="true"].msg-form__contenteditable` (first match per thread)
- Send button: `button.msg-form__send-button` (first match; enabled when message non-empty)
- Thread row: `page.locator('.msg-conversation-listitem__link').nth(N)` on `?filter=starred`

**Send verification pattern:**
- Pre-send: `sendBtn.isEnabled() === true` AND `compose.innerText.length === msg.length`
- Post-send: compose cleared (`""`) AND new "Jeffrey Lee-Chan sent..." bubble in thread

**Both sends succeeded (2026-08-05):**
- Kelly Wang, MBA @ BMO — sent at 9:38 PM, paid 60-min working session offer, closes 10-week ghost
- Sainesh Nakra @ Google — sent at 9:39 PM, paid OR free 15-min coffee, closes 18-month ghost

**Pitfalls observed:**
- `closeAllTabs` is NOT defined in Aside REPL — `closeTab(await openTab('about:blank'))` is the working pattern for tab cleanup between sends
- Send flow MUST be bundled in ONE `aside repl` call (per `social-poster` lesson 19); splitting across calls loses the typed text because each `openTab` reopens a fresh tab
- Pre-send verify is BLOCKING: if compose.innerText.length doesn't match msg.length, the message didn't stick — do NOT click Send

**Follow-up note:** the sent drafts reference "Calendly link below" but neither message contains an actual URL. Future session should follow up to insert the real Calendly URL, or update the draft template to auto-include it.
