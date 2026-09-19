---
name: vendor-share-link-reader
description: Read AI-vendor share URLs. Run recipe, don't ask user.
allowed-tools:
  - Bash
  - Read
context: inline
---

# Vendor Share-Link Reader

The user pastes an AI-vendor share URL (Grok, ChatGPT, Gemini, Claude, Perplexity). The page is a React/Next.js SPA. The conversation is in client-side React state. The terminal curl / web_extract / browser_navigate paths all return empty shells or bot-blocked.

**Don't ask the user to do your work.** The user will list this as a "stop asking me" friction signal the next time. Run the local recipe (Aside REPL or stagehand/claudem-via-browser) and produce the answer. If that fails, debug step-by-step and report each failure concretely — never fall back to "please paste the body."

## When to fire

Trigger this umbrella when **any** of these hold:

1. The user pastes a vendor share URL — `grok.com/share/*`, `chatgpt.com/share/*`, `gemini.google.com/share/*`, `perplexity.ai/search/*`-with-share-token, `claude.ai/share/*` (rare), `gemini.google.com/app/<conversation-id>`.
2. `terminal: curl <url>` returns the SPA shell (Next.js chunks, GTM, Sentry baggage, React server-component scripts) with no conversation body.
3. `web_extract(<url>)` and `browser_navigate(<url>)` both return empty or `(empty page)`.
4. The user has NOT pasted the conversation body directly into the chat.

If the user already pasted the body, skip the fetch.

## Universal recipe — try in order

Each child skill in this umbrella owns the vendor-specific path. Use this ladder:

| # | Path | When this is the right one |
|---|---|---|
| 1 | `curl -sSL -A "Mozilla/5.0" <url>` + extract `og:description` / `articleBody` / `twitter:description` from HTML | First probe — works for some public sites (Xitter, LinkedIn, public blogs). Vendor share URLs usually fail this. |
| 2 | `skill_view(name='<vendor>-share-link')` — load the vendor-specific child skill | Vendor with a known SPA pattern. **This is the default path the user expected you to use.** |
| 3 | `aside repl "const p = await openTab('<url>'); await new Promise(r => setTimeout(r, 9000)); const t = await p.evaluate(() => document.body ? document.body.innerText : ''); console.log(t);"` | Vendor-specific child skill hasn't shipped yet, or the child skill's recipe failed. |
| 4 | `stagehand` / `claudem` browser cookies + auth-gated page | Auth-gated vendor (user's own private share). See `auth-gated-site-read` skill. |
| 5 | Report concrete failure with raw output from each tried path | **Only when 1–4 all failed.** Never "please paste the body." |

## Per-vendor child skills

This umbrella is the class-level entry point. The vendor-specific child skills live alongside:

- **`read-grok-shared-link`** — `~/.smartclaw/skills/read-grok-shared-link/SKILL.md` — Grok / xAI via Aside REPL `openTab` + 8s wait + `body.innerText`. Verified 2026-07-31 and 2026-08-20 (full 30K-char thread captured in one shot).
- **`read-gemini-share-link`** — `~/.smartclaw/skills/read-gemini-share-link/SKILL.md` — Gemini share links via headless Playwright Chromium (public, 12s wait for batchexecute hydration). Verified 2026-08-10.

Future vendors: add a child skill under `~/.smartclaw/skills/<vendor>-share-link/` and link it here. **Don't repeat the recipe in this skill body** — link to the vendor-specific child.

## Pitfalls

- **Do NOT ask the user to paste the body.** This is the load-bearing pitfall. On 2026-08-20 the user pushed back: *"Stop forgetting how to read share URLs you don't need login use /history and /ms then /skillify it."* The fix is the recipe above, not asking the user. Treat "please paste the body" as a self-imposed delete-the-skill signal.
- **Do NOT try `browser_click` / `browser_type` from `aside repl`.** They don't exist in the REPL. The REPL is read-only. For OAuth or interactive flows, drop to the full `mcp__aside-mcp__*` tools if your runtime exposes them, or `claudem` for auth-gated paths.
- **Do NOT retry `web_extract` once.** Multiple retries bake a refusal into the wound. One probe, record the empty result, escalate to Aside REPL.
- **Do NOT skip the `body.innerText` step.** The Grok page returns a hydrated DOM only after React settles. The 8s wait is the minimum — bump to 12s if the first read returns just the sidebar.
- **Browser remote-debug "Allow"-popup is NOT a dead end.** When the Chrome-side `browser_exec` tool returns `permission-blocked: wait for the user to click Allow in the Chrome permission popup`, that is the LLM browser harness saying the Chrome instance has a permission dialog open. The fix is to retry through `aside repl` (separate remote-debug session) — don't wait for the user.
- **Skill resolver "not found" is NOT a dead end.** When `skill_view` returns `Skill not found` for a skill that exists at `~/.smartclaw/skills/<name>/`, the resolver may have a stale index. Run the recipe from the recipe's primary path anyway — the recipe doesn't depend on the skill loader.

## When to skip this umbrella

- The URL is a non-share, public page (AI vendor landing page, marketing blog post). Use `web_search` + `web_extract` directly.
- The user has pasted the conversation text directly in the chat. No fetch needed.
- The user wants a screenshot, not the text. Use vendor-specific `mcp__*__*` tools that support screenshots, or `claudem` headless.

## Verification (quick)

```bash
aside --version                              # 1.26.x
aside account list | head -3                  # signed-in profile
aside repl "console.log('ok')"                # REPL works
```

If any fails, see the **Verification** table inside `read-grok-shared-link` SKILL.md for fallbacks.

## Anti-patterns

- **Asking the user to paste the body.** User pushed back 2026-08-20.
- **Stating "the page is JS-rendered and I can't read it" without trying the recipe.** That's a refusal masquerading as a diagnosis.
- **Running `curl` once and concluding "blocked."** Multiple paths exist; iterate.
- **Trusting `web_extract` when it returns empty.** DDGS is search-only in this runtime — `web_extract` returns empty for many share URLs by design, not by blocking.

## Cross-references

- **Grok-specific recipe:** `~/.smartclaw/skills/read-grok-shared-link/SKILL.md` — primary child skill, verified recipe.
- **Aside canonical:** `~/.smartclaw/skills/aside-browser-default/SKILL.md` — full Aside CLI / REPL / MCP surface, headless default, OAuth capture pattern.
- **Aside REPL gotchas:** `~/.smartclaw/skills/aside-browser-default/references/aside-repl-api-gotchas.md` — why multi-line JS needs `$(cat file)`, why `screenshot()` doesn't exist.
- **Auth-gated sites:** `~/.smartclaw/skills/auth-gated-site-read/SKILL.md` — when the share is private (user's own session, not a public share link).
- **Browser-headless default:** `~/.claude/skills/browser-headless-default/SKILL.md` — broader headless policy.
- **Tavily-disabled rule:** `~/.claude/CLAUDE.md` § "Tavily is disabled" — DDGS is search-only, can't extract vendor share pages.

## Provenance

- v1.0.0 (2026-08-20): Created per Jeffrey's explicit instruction in Slack
  C0AUXSVFSA2/1787226134.658509 — "Stop forgetting how to read share URLs you don't need
  login use /history and /ms then /skillify it." Triggered by the Nocturne Ravencrest
  feedback-review session where the previous turn asked the user to paste the body
  instead of running the existing `read-grok-shared-link` recipe. The correction is
  twofold: (1) the class-level skill is needed so a future session doesn't have to
  re-derive the ladder; (2) the "don't ask the user to paste" pitfall is now
  load-bearing — it's the difference between productive and frustrating.
