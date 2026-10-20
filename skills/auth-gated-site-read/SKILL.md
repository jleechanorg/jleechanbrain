---
apiVersion: "1.0"
name: auth-gated-site-read
description: "Read AND send user-private data on auth-gated sites via Aside (LinkedIn DMs, Slack DMs/threads, Google Docs). Triggers on 'read my LinkedIn', 'who talked to me', 'starred conversations', 'two-month sweep', 'send it', 'lets send', 'fire it off', 'read this Slack thread', 'analyze this DM', 'draft a Google doc', 'draft it in a Google doc', 'create a Google doc', 'save to Drive'. ALSO loads on 'blocked' pages before cookie/session workarounds (2026-08-10 decision rule). ALSO loads for Google Docs asks — the user's signed-in Aside `u0` profile is already authenticated to docs.google.com; no OAuth setup needed."
when_to_use: "LinkedIn DMs, Slack DMs/threads/channels, Google Docs (via signed-in Aside `u0` Google profile), banks, Gmail-class inboxes — READ user-private content via Aside REPL snapshot, structured API (`linkedin.getInbox`/`getConversation`), or the Slack web-client URL shape `app.slack.com/client/<TEAM>/<CHAN>/thread/<CHAN>-<ts>`. CREATE/EDIT Google Docs via `docs.new` + kix-canvas insertText, verified via the `/mobilebasic` URL. SEND replies via the 4-step send flow (Step 5b) when the user says 'lets send' / 'send it' / 'fire it off' in-session after reading the draft. NOT for Playwright/Chromium anti-bot paths, which fail on LinkedIn. ALSO trigger on 'page is auth-walled' / 'this site requires sign-in' / 'I can't read this' — load BEFORE reaching for browserclaw cookies decrypt; the 2026-08-10 decision rule says most 'blocked' pages are JS-not-hydrated, not auth-gated."
allowed-tools: aside, mcp__aside-mcp, browserclaw, mcp__playwright-mcp (fallback, NEVER for LinkedIn)
context: hermes
---

# Auth-Gated Site Read