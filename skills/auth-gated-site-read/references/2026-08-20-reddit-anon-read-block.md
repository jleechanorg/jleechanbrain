# Reddit Anon-Read Block (2025+)

A separate failure mode from the 2026-08-10 "auth-walled vs JS-not-hydrated" decision rule. This one is **network-level**: the Reddit origin returns the bare React shell to any agent-side request, even with a real browser User-Agent and even on the `.json` API endpoints. It's not auth-gated, and the JS-hydration fix doesn't apply because there's nothing to hydrate against.

## Symptom (verified 2026-08-20)

Every `curl` to a Reddit URL from this network returns the same shell:

```bash
$ UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
$ curl -sA "$UA" -L "https://www.reddit.com/r/vibecodingcommunity/s/yMO6O1hHfN.json"
<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <link href="https://www.redditstatic.com/shreddit/assets/favicon/64x64.png" ... />
    <title>Reddit</title>
    <script nonce="99010e5a-badf-49fe-8693-5ec067b2b590">
      document.addEventListener(...)
```

- `<title>` is literally `Reddit`, not the thread title
- `og:description` / `og:title` / `articleBody` are absent
- The HTML is the React SPA shell (`shreddit/assets/...`) — no thread payload
- The same shape appears on `reddit.com`, `old.reddit.com`, and `.json` endpoints
- It is NOT a Cloudflare/anti-bot challenge page — it's the unauthenticated React root that Reddit serves to fingerprint-flagged clients
- HTTP status is `200 OK`, so the request didn't fail — the response is just empty of useful content

## Why it happens

Reddit's 2025 anti-scraping layer fingerprints client requests and serves the React shell to anything that doesn't look like a real signed-in browser. The fingerprint covers:

- TLS fingerprint (JA3/JA4)
- HTTP/2 SETTINGS frame ordering
- Missing `Sec-Fetch-*` headers (real browsers send them; `curl` doesn't by default)
- Cookie store absence — anonymous requests look like headless bots
- IP reputation from residential/cloud ranges

None of these are fixable by adding a User-Agent string. `--user-agent` and `-L` are not the problem.

## What does NOT work

- ❌ `curl -sSL -A "Mozilla/5.0 ..." <reddit-url>` — same shell
- ❌ `curl -A "<real Chrome UA>" -H "Accept: text/html" -L <reddit-url>` — same shell
- ❌ `curl -L https://old.reddit.com/<path>` — `old.reddit.com` redirects to `www.reddit.com` and returns the same shell
- ❌ `curl -L <reddit-url>.json` — returns the same HTML shell, not JSON (Reddit gates `.json` the same way as HTML)
- ❌ `web_extract(<reddit-url>)` — returns empty (no body to extract)
- ❌ `web_search("site:reddit.com <thread title>")` — may find the title but cannot return the body
- ❌ Trusting a curl-200 + `<title>Reddit</title>` as evidence the thread loaded — it didn't

## What works (ranked)

### 1. Aside REPL `openTab` against a logged-in Reddit session

If the user is signed into Reddit in their Aside browser profile, the SPA renders normally because the request comes from the user's real authenticated session, not an agent-side curl. Same recipe as the LinkedIn/Slack sections in the parent skill:

```bash
aside repl "
const p = await openTab('https://www.reddit.com/r/<sub>/comments/<id>/<slug>/');
await new Promise(r => setTimeout(r, 9000));
const s = await snapshot(p, { interactive: false });
console.log(s.tree.slice(0, 4000));
"
```

For megathread comment targets (`/r/<sub>/s/<shortid>` shortlinks), navigate to the long-form URL once the title is known. Or just `openTab` the shortlink — Aside's Chromium has the full fingerprint + auth, so the shortlink resolves to the thread body.

### 2. Reddit OAuth (script-type app)

If Aside isn't signed in to Reddit, register a script-type app at `https://www.reddit.com/prefs/apps` and use OAuth to read the thread via the JSON API:

```bash
# After OAuth handshake, use the bearer token:
curl -H "Authorization: bearer <ACCESS_TOKEN>" -H "User-Agent: <your-app-name>/0.1 by /u/<your-username>" \
  "https://oauth.reddit.com/r/<sub>/comments/<id>/<slug>?limit=50&depth=10"
```

Script-type apps get a 2-hour bearer token via the standard `client_credentials` grant (for read-only) or `authorization_code` (for user-context reads). Requires:

- `REDDIT_CLIENT_ID` (the app's 14-char ID, e.g. `abc123def45678`)
- `REDDIT_CLIENT_SECRET`
- For user-context reads: `REDDIT_USERNAME` + `REDDIT_PASSWORD` (Reddit password-grant flow is deprecated; use `authorization_code` with a manual browser step)

The JSON response has the full thread body + comments — `data.children[0].data.selftext` for the post body, `data.children[1..].data.body` for top-level comments. No HTML scraping needed.

### 3. Ask the user to paste the title + body

Last resort. Costs the user 30-60 seconds. Use ONLY when Aside isn't signed in AND OAuth isn't available. Frame it as "I can't read the thread from here — paste the title + first paragraph so I can draft contextually" rather than "please paste the body" (which is the load-bearing pitfall in `vendor-share-link-reader`).

## Why this isn't the "auth-walled vs JS-not-hydrated" rule

The 2026-08-10 rule (in the parent skill) covers two failure modes:

- **Auth-walled:** page requires sign-in to view content
- **JS-not-hydrated:** page is publicly renderable but the agent's first snapshot is empty because React hasn't hydrated

The Reddit case is NEITHER:

- Public megathreads render to anyone with the link (not auth-walled)
- The shell has no JS to hydrate — it's a static HTML placeholder (not a JS-hydration timing issue)
- The shell is the *intended* response to fingerprint-flagged clients, not an intermediate state

The correct mental model is: **Reddit's anti-scraping layer treats agent-side requests as bots regardless of authentication, and serves them the shell.** The incognito-check from the 2026-08-10 rule still applies (ask the user to verify the page renders normally in incognito — if it does, the page is public and the agent just needs a real browser path) but the "JS hydration" branch doesn't apply because there's no JS payload to wait for.

## When the agent should load this reference

- The user pastes a Reddit URL and asks to "summarize this thread", "read this post", "find the megathread for X", "draft a comment under this thread", "what's in this subreddit's wiki"
- `curl` to any `reddit.com` / `old.reddit.com` / `reddit.com/*.json` URL returns `<title>Reddit</title>` or the shreddit SPA shell
- The user names a Reddit thread title in conversation but the thread URL doesn't load via `web_extract` or `browser_navigate`
- A `/social` draft task targets a specific megathread and the drafter needs `--parent-context` to acknowledge the thread prompt

## Companion updates already made

- `~/.smartclaw/skills/social-poster/SKILL.md` rule #10 documents the anon-read block for the social-poster use case (Reddit `--mode comment` without a readable thread)
- `~/.smartclaw/skills/social-poster/scripts/draft_social_post.py` accepts `--parent-context` so a comment draft can acknowledge a thread prompt even when the drafter couldn't scrape the thread itself
- `vendor-share-link-reader` covers share-link reads but not megathread-comment targets (Reddit share URLs are rare — the common case is megathread URLs the user pastes for comment drafting)

## Provenance

- Verified 2026-08-20, `C0AJQ5M0A0Y/1787216910.979069` — Jeffrey asked `/social` to draft a comment on `https://www.reddit.com/r/vibecodingcommunity/s/FJH0ME5iI4`. Anonymous `curl` to that URL (and `reddit.com` and `old.reddit.com`) returned the React shell. Authenticated Reddit path would have been needed; instead, the drafter emitted a tight standalone "what are you vibecoding" comment that fits any weekly-share megathread, and the user was offered to paste the megathread title for a sharper draft with `--parent-context`.
- The earlier 2026-08-10 decision rule in the parent skill covers a different failure class — see "Why this isn't the 'auth-walled vs JS-not-hydrated' rule" above.

## Pointer in parent SKILL.md

The parent `auth-gated-site-read/SKILL.md` `## References` section lists this file (2026-08-20 entry). If the references list drifts from the file index, this reference file is the source of truth — keep the SKILL.md references section in sync via `skill_manage patch` against the parent.
