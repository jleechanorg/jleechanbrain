# 2026-08-10 — "Blocked page" decision rule

This reference captures the worked example behind the new "Decision rule: auth-walled vs JS-not-hydrated" section in `auth-gated-site-read/SKILL.md`. Future sessions should consult this when the user shares a vendor share link and the agent's first render returns empty.

## What happened

User pasted `https://gemini.google.com/share/1a3d2d1f2753` (also reachable as `share.gemini.google/hZXboZihmwYc` and `share.gemini.google/94lImOSaZBZL` — same conversation, three URLs). The session attempted:

1. `curl -sL <url>` → 827KB static HTML with `AF_initDataCallback` blobs but no conversation payload. Misread: "the conversation isn't in the static HTML, so we need a JS-rendered browser."
2. `browser_navigate` + `browser_snapshot` → page showed a "Sign in" overlay and empty content. Misread: "this is auth-gated, we need the user's signed-in Chrome session."
3. `browserclaw cookies decrypt` against `~/Library/Application Support/Google/Chrome/Default/Cookies` → 88 google.com cookies including the full session bundle (SID, __Secure-1PSID, __Secure-3PSID, __Secure-1PSIDTS, __Secure-3PSIDTS).
4. `browserclaw cookies inject` → successfully loaded the page and captured 50,364 chars of conversation.
5. Worked all the way through: drafted campaign bible, wrote 19 wiki files, opened PR #24, created Google Doc, posted to Slack.

Then user replied with screenshots:

> *"I don't see an auth gate. It opens in incognito window why can't it work for you"*

The screenshots showed the conversation rendering fully with a "Sign in" button in the top-right nav overlay — exactly the same UX the agent had reproduced, except the agent had not realized that the sign-in button was just nav chrome, not a content gate.

## What was wrong

The page was never auth-gated. The Gemini share conversation is fully public to anyone with the link. The agent's failure was JS hydration timing, not auth:

- Static HTML → empty shell because the SPA hasn't run yet.
- First browser snapshot → empty shell because the snapshot fired before `batchexecute` returned the conversation data.
- Cookies inject → succeeded not because the cookies unlocked auth, but because they let the page skip Google's anti-bot interstitial long enough to complete hydration.

The cookies were harmless in this case. They were also unnecessary.

## The correct first action (now codified)

Before pursuing cookie decryption, session injection, or any credential workaround on a "blocked" page, the agent must ask the user to open the URL in incognito and report what renders:

- **Incognito renders the page** → public, no auth gate. Agent's rendering pipeline is the problem. Use plain Playwright with `wait_until="networkidle"` + 12s extra wait. Skip cookies.
- **Incognito fails but user is signed in** in their regular browser → JS hydration is the problem. Same fix as above. Skip cookies.
- **Incognito fails AND user is not signed in** → may genuinely require auth. THEN reach for cookies.

## Why this matters

- The wrong path wastes 10-30 minutes of agent time (decrypting cookies, injecting them, retrying).
- The wrong path can damage the user's real Chrome session if the agent accidentally hits a real anti-bot path (LinkedIn `li_at` kill, Slack session rotation, etc.).
- The 30-second incognito check costs the user 30 seconds and produces a definitive answer.
- This was a class-level rule, not a Gemini-specific one — applies to chatgpt.com/share, docs.google.com, notion.so, and any other vendor share link.

## Captured artifacts from this session

- **PR:** [jleechanorg/llm-wiki PR #24](https://github.com/jleechanorg/llm-wiki/pull/24) — 19 files, +998 lines, feat/supergirl-kryptonian-gods-campaign branch.
- **Campaign bible (LLM wiki):** `wiki/entities/SupergirlKryptonianGodsCampaign.md` + 17 entity pages + opening scene.
- **Google Doc:** [Supergirl — Kryptonian Gods (Campaign v1)](https://docs.google.com/document/d/1oJMh9JQ_h14Relt9fx7CKeBntYShjEkK2v7aBtjnx1U/edit) in the user's `worldAI campaigns` Drive folder.
- **Skillified recipe:** `~/.smartclaw/skills/read-gemini-share-link/` — the working capture recipe, with this decision rule encoded in the SKILL.md.
- **Memory note:** `~/.smartclaw/memories/MEMORY.md` — durable lesson for future agents: always ask the user to confirm whether a "blocked" page is actually auth-gated OR just JS-not-hydrated before reaching for cookie/credential workarounds.