---
name: wa-share-flow
version: 1.2.0
category: worldarchitect
description: Mint WA campaign share-tokens via the legacy-fields API. Local-server bypass path + Gemini-key investigation pattern + gcloud key-mint + SHARE_URL_BASE override added 2026-08-22.
author: hermes-curator
license: MIT
metadata:
  hermes:
    tags:
      - worldarchitect
      - share-token
      - share-link
      - legacy-fields
      - cross-account
      - aside
      - local-server-bypass
      - gemini-key-rotation
    related_skills:
      - wa-per-user-campaign-lookup
      - wa-prod-data-query
      - aside-browser-default
related_skills:
  - wa-per-user-campaign-lookup
  - wa-prod-data-query
  - aside-browser-default
last_verified: 2026-08-22
---

# WA share-link mint + verify

## When to use

- User says *"give me the share link for campaign X"*
- User names a campaign by version (`rhaenrya v2`, `dragon knight v3`) — see the "search by name" recipe below
- A bug report mentions "share token broken", "/new-campaign?share_token=… returns blank", "share URL doesn't show play CTA"
- A test/proof bundle needs a real share link + signed-out landing screenshot (the 2026-08-18 `canonical_login_redirect_2026-08-18` bundle in `gist 5645c8…` is the worked example)

## When NOT to use

- Just want to *read* a campaign (no minting) → use `wa-per-user-campaign-lookup` (Firestore path) or `GET /api/campaigns/<id>` (API path)
- Bulk-export of one campaign's full story → use `download-campaign`

> ## Trigger phrases
> - "share this campaign with X"
> - "give me the share URL"
> - "create a share link for rhaenrya v2"  ← version-named query
> - "mint a share token on campaign Y"
> - "I need a signed-out share-link proof"
> - "let me try your campaign" → WA share link, not Google Doc share link (see Pitfall 8)

> ## Trigger phrases — adjacent (load `auth-gated-site-read` instead)
> - "share this Slack thread" → Slack, not WA
> - "share this LinkedIn post" → LinkedIn, not WA
> - "share this Google Doc" → Google Doc, load `google-workspace-via-gog` and use `gog drive share` not this skill

---

## Pitfall 8 — "Share link" almost always means the WA campaign share link, not a Google Doc (added 2026-08-22)

**Symptom:** User says *"give me the share link to try it"* after a `/Google` step. The literal next thing produced is a Google Doc share URL (`docs.google.com/document/d/<id>`). The user comes back: *"no the share link is a campaign share link see recent PRs last 2 weeks where i added the feature"*.

**Root cause:** "Share link" in WA context means the `/shared/<token>` URL produced by `POST /api/campaigns/<id>/share-token`. Google Doc share links only land there if the user's task is *literally* "share the doc". When the task chain is "create campaign bible in a Google Doc → test it → give me a share link to try it", the second "share link" targets the WA campaign, not the doc.

**Decision rule:**
1. If the previous turn produced a Google Doc via `/google` or `gog docs create`, the user's NEXT "share link" ask is almost always the WA campaign share link they actually want to play — mint that, not the doc share.
2. Both can be produced. The doc share is one `gog drive share <docId> --anyone` call (Google-side permissions). The campaign share is the full 4-step mint recipe below.
3. When ambiguous, lead with the campaign share link and note the doc share as a secondary deliverable. Better to be told "no I wanted the doc" than to be told "no I wanted the campaign" (the latter requires re-routing the whole flow).

---

## The API endpoint (verified 2026-08-18, deployed git HEAD `6d90bc02`)

```
POST https://mvp-site-app-dev-i6xf2p72ka-uc.a.run.app/api/campaigns/<campaign_id>/share-token
Authorization: Bearer <firebase_id_token>
Content-Type: application/json

{
  "confirm_legacy_fields": true,
  "legacy_share_fields": {
    "character": "<string>",
    "description": "<string — TRUNCATE to ~300 chars; see Pitfall 2>",
    "setting": "<string>"
  }
}
```

Success response (200):

```json
{
  "access_count": 0,
  "share_token": "<REDACTED_SHARE_TOKEN_EXAMPLE>",
  "share_url": "https://mvp-site-app-dev-i6xf2p72ka-uc.a.run.app/shared/<REDACTED_SHARE_TOKEN_EXAMPLE>",
  "success": true
}
```

The `share_url` renders signed-out to anyone with the link — no auth required to view the campaign landing page. The "Play in this world →" CTA on that landing deep-links to `/new-campaign?share_token=<token>`, which is the path that triggers the dual-OAuth login-redirect flow (verified end-to-end on 2026-08-18).

---

## The 4-step mint recipe

### Step 1 — Cross-account: pick the right Firebase UID

The share-link API is open to any signed-in user on this deployment — but the campaign's `user_id` field (Firestore doc owner) is the canonical "creator". Picking the right UID matters because:
- The `legacy_share_fields_confirmation_required` 409 echoes back the campaign's stored character/setting — these come from the **owner's** doc, not the minter's.
- The token is bound to the campaign, not the minter. Anyone with the token can play it.

**If the user says "use jleechantest@gmail.com"** (u1, Aside Profile 1) but the actual campaign is owned by u0 (`jleechan@gmail.com`), the mint still succeeds — the token is campaign-scoped, not user-scoped. But mint under the owner's UID if you can, because:
1. It produces cleaner audit trails (logs show "owner minted share link" not "third party minted").
2. Some future endpoint might enforce ownership; baking the right pattern now is cheap insurance.

To switch Aside profiles (verified 2026-08-18):

```bash
aside account use u0    # global daemon default; persists for subsequent `aside repl` calls
aside repl "const p = await openTab('https://mvp-site-app-dev-i6xf2p72ka-uc.a.run.app/');
           await new Promise(r => setTimeout(r, 12000));
           await new Promise(r => setTimeout(r, 4000));  // extra for Firebase Auth rehydrate
           const u = window.firebase.auth().currentUser;
           console.log('UID:', u.uid, 'EMAIL:', u.email);"
```

The extra 4s wait is **mandatory** after a profile switch — Firebase Auth client takes a moment to rehydrate to the new cookie jar, and `currentUser` reads `null` if you query too early.

### Step 2 — Find the campaign by name (substring search, paginated)

```js
const p = await openTab('https://mvp-site-app-dev-i6wf2p72ka-uc.a.run.app/');
await new Promise(r => setTimeout(r, 12000));
await new Promise(r => setTimeout(r, 4000));

const result = await p.evaluate(async () => {
  const w = window;
  const u = w.firebase.auth().currentUser;
  const token = await u.getIdToken();

  let all = [], cursor = null;
  for (let i = 0; i < 80; i++) {
    const url = cursor
      ? `/api/campaigns?limit=100&cursor=${encodeURIComponent(cursor)}`
      : '/api/campaigns?limit=100';
    const r = await fetch(url, { headers: { Authorization: `Bearer ${token}` } });
    const body = await r.json();
    const arr = Array.isArray(body) ? body : (body.campaigns || body.items || body.data || []);
    all = all.concat(arr);
    if (!arr.length) break;
    cursor = body.next_cursor || body.nextCursor || body.cursor;
    if (!cursor) break;
  }
  // For "rhaenrya v2" — match on title OR initial_prompt
  const re = /rhaenrya|rhaenyra|v2|v3|v4/i;
  const matches = all.filter(c => re.test((c.title || c.name || '') + ' ' + (c.initial_prompt || '')))
    .map(c => ({ id: c.id, title: c.title || c.name,
                 created_at: c.created_at || c.createdAt,
                 has_share_token: !!c.share_token,
                 initial_prompt: (c.initial_prompt || '').slice(0, 220) }));
  return { uid: u.uid, total: all.length, matches: matches.slice(0, 30) };
});
console.log('SEARCH:', JSON.stringify(result));
```

**Critical:** `limit=4000` returns `{ "error": "…" }` (the API caps). `limit=100` with cursor pagination is the safe path. Cursor key varies by response shape — try `next_cursor`, `nextCursor`, then `cursor`.

### Step 3 — Probe then mint (the two-step legacy-fields dance)

The endpoint gates on the **legacy** schema (older campaigns had `character`/`description`/`setting` as separate fields; newer campaigns use the `wa-campaign-bible-rhaenrya` markdown stuffed into `initial_prompt`). When the campaign still has the legacy fields, the API demands confirmation:

```js
const cid = '<campaign_id>';
const probe = await p.evaluate(async () => {
  const token = await window.firebase.auth().currentUser.getIdToken();
  const r = await fetch('/api/campaigns/' + cid + '/share-token', {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type':'application/json' },
    body: '{}',
  });
  return { status: r.status, body: await r.text() };
});
console.log('PROBE:', JSON.stringify(probe));
```

**Three possible probe outcomes:**
| Status | Body | What to do |
|--------|------|-----------|
| **200** | `{"success":true, "share_token":"…", "share_url":"…"}` | Token already minted. Skip to Step 4 (verify). |
| **409** | `{"error":"legacy_share_fields_confirmation_required", "legacy_share_fields":{character, description, setting}}` | Echo back the legacy fields with `confirm_legacy_fields: true` (Step 3b). |
| **400** | `{"error":"legacy_share_field_too_long"}` | The echo'd `description` is too long (bible markdown stuffed in). Truncate before re-POSTing. |

### Step 3b — POST with confirmation (and truncate if needed)

```js
const result = await p.evaluate(async () => {
  const token = await window.firebase.auth().currentUser.getIdToken();
  const cid = '<campaign_id>';
  // Re-probe to get the exact legacy fields the API wants
  const probeRes = await fetch('/api/campaigns/' + cid + '/share-token', {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type':'application/json' },
    body: '{}',
  });
  const probeBody = await probeRes.json();
  const legacy = probeBody.legacy_share_fields || {};

  // TRUNCATE description to ~300 chars (Pitfall 2). The API rejects >300-ish.
  const shortDesc = (legacy.description || '').length > 300
    ? (legacy.description.slice(0, 280) + '… [see full bible in shared world view]')
    : legacy.description;

  const r = await fetch('/api/campaigns/' + cid + '/share-token', {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type':'application/json' },
    body: JSON.stringify({
      confirm_legacy_fields: true,
      legacy_share_fields: {
        character: legacy.character || '',
        description: shortDesc,
        setting: legacy.setting || ''
      }
    }),
  });
  return { status: r.status, body: await r.text() };
});
console.log('MINT:', JSON.stringify(result));
```

### Step 4 — Verify the share URL renders signed-out

The mint returning 200 is necessary but not sufficient. The `share_url` should render the campaign title + description + a working "Play in this world →" CTA. Verify on a **fresh tab** so the page is genuinely signed-out:

```js
const shareUrl = '<share_url from mint response>';
const p = await openTab(shareUrl);
await new Promise(r => setTimeout(r, 12000));

const verify = await p.evaluate(() => {
  const links = Array.from(document.querySelectorAll('a'));
  const play = links.find(a => /play in this world/i.test(a.textContent || ''));
  return {
    url: location.href,
    title: document.title,
    h1: document.querySelector('h1')?.innerText,
    blurb: (document.querySelector('h1')?.parentElement?.innerText || '').slice(0, 400),
    playHref: play ? play.href : null,
  };
});
console.log('VERIFY:', JSON.stringify(verify));
```

A passing verification has:
- `h1` = the campaign title (e.g. `"Rhaenyra v2"`)
- `playHref` = `https://mvp-site-app-dev-i6xf2p72ka-uc.a.run.app/new-campaign?share_token=<token>`
- No "Sign in" gate on the landing page itself (sign-in only triggers on the "Play in this world →" CTA)

If `h1` is null or `playHref` is null, the mint succeeded but the rendering is broken — that's a different bug class (regression on the shared-landing template). Don't claim success in that case.

---

## The local-server bypass path (added 2026-08-22)

When the campaign was created via the local dev server (`mvp_site/main.py serve` on a random 8081-8181 port, reachable at `http://127.0.0.1:<port>/`), the share-link mint flow is identical except for three differences:

1. **Auth bypass.** No Google OAuth required. Hit `/api/test_client_token_login?uid=<firebase_uid>&redirect=/` and the server writes a Firebase custom token into a sandbox browser session. The browser then auto-signs-in via the local Firebase config baked into the page. UID `0wf6sCREyLcgynidU5LjyZEfm7D2` is the canonical `jleechantest@gmail.com` test UID (verified 2026-08-22).

2. **API base is the local port, not `mvp-site-app-dev-…run.app`.** All `/api/...` calls go to `http://127.0.0.1:<port>`. Share URLs come back as `http://127.0.0.1:<port>/shared/<token>` — same shape, just on localhost.

3. **Bearer token retrieval is via the page's `firebase.auth().currentUser.getIdToken()`**, not OAuth. The custom-token sign-in rehydrates the auth state in the same browser context.

### Local-server share-mint recipe (Playwright headless, works without OAuth)

```python
import asyncio, json
from playwright.async_api import async_playwright

URL = "http://127.0.0.1:8088"  # or whatever the local server landed on
TEST_UID = "0wf6sCREyLcgynidU5LjyZEfm7D2"  # jleechantest@gmail.com
CAMPAIGN_ID = "<from firestore scan or wa-per-user-campaign-lookup>"

async def main():
    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True, channel="chromium")
        ctx = await browser.new_context(viewport={"width": 1400, "height": 900})
        page = await ctx.new_page()
        await page.goto(f"{URL}/api/test_client_token_login?uid={TEST_UID}&redirect=/",
                        wait_until="networkidle", timeout=30000)
        await page.wait_for_timeout(5000)
        id_token = await page.evaluate("""
            async () => {
                if (!window.firebase || !window.firebase.auth) return null;
                const u = window.firebase.auth().currentUser;
                if (!u) return null;
                return await u.getIdToken();
            }
        """)
        if not id_token:
            print("Not authed — server may not be in WORLDAI_DEV_MODE or SMOKE_TOKEN env")
            return
        # Direct mint (probe is only needed when the campaign has stored legacy fields)
        mint = await page.request.post(
            f"{URL}/api/campaigns/{CAMPAIGN_ID}/share-token",
            headers={"Authorization": f"Bearer {id_token}", "Content-Type": "application/json"},
            data=json.dumps({
                "confirm_legacy_fields": True,
                "legacy_share_fields": {
                    "character": "<character from bible>",
                    "description": "<first 300 chars of bible description>",
                    "setting": "<setting from bible>",
                }
            }),
        )
        body = json.loads(await mint.text())
        print(f"share_url: {body.get('share_url')}")
        print(f"share_token: {body.get('share_token')}")
        # Verify signed-out (fresh tab, no cookies)
        verify = await ctx.new_page()
        await verify.goto(body['share_url'], wait_until="networkidle", timeout=30000)
        await verify.wait_for_timeout(5000)
        await verify.screenshot(path="/tmp/share-landing.png", full_page=True)
        await browser.close()

asyncio.run(main())
```

**Why this works:** `WORLDAI_DEV_MODE=true` (or `SMOKE_TOKEN` env on `preview`/`dev`) gates `/api/test_client_token_login` on the local server. The browser signs in via Firebase custom token (no OAuth), gets an ID token, and the bearer-authenticated share-token mint succeeds.

---

## The Gemini-key investigation pattern (added 2026-08-22)

When the local WA server fails campaign creation at the LLM-crafting step with `HTTP 403 PERMISSION_DENIED — Your API key was reported as leaked. Please use another API key.`, the fix path is **almost never** "mint a new key in /browser". It is:

1. **Extract the healthy key from bashrc.** `~/.gemini_api_key_secret` holds `export GEMINI_API_KEY=AIzaSy…` — load it via `python3 -c "import re; ..."` against the secret file. The user often has a healthy key already wired in.

2. **Verify it's actually healthy** via `curl -fsS "https://generativelanguage.googleapis.com/v1beta/models?key=$KEY" | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('models', [])))"`. Should return ≥10 models. If `0` or HTTP 403, that key is also leaked — look further.

3. **Compare the running server's `GEMINI_API_KEY`** to the bashrc one: `ps eww -p <WA_PID> | tr ' ' '\n' | grep '^GEMINI_API_KEY='`. If they differ, the running server is using a leaked/orphaned key.

4. **Rotation cannot happen from inside the gateway session.** The gateway blocks `kill` of child processes — same blocker as `hermes gateway restart`. Write the rotation as a script (`/tmp/rotate-wa-gemini-key.sh`) and have the operator run it from a fresh terminal outside the gateway. The script: extract healthy key → kill WA server PID → relaunch with `GEMINI_API_KEY=*** WORLDAI_DEV_MODE=true` → verify.

**Why AI Studio headless Chrome fails to mint a new key:** Google returns `Failed to generate API key, The request is suspicious. Please try again.` on headless Chromium. Anti-automation token is checked server-side. The user has to mint in their own visible Chrome session, or use an existing healthy key.

**Why you should NOT spend cycles inventing an AI Studio workaround:** the healthy key is usually already in bashrc. The OOB correction pattern is: user says "the gemini key is fine, check all of them from bashrc, where are you getting yours?" → that means you missed checking bashrc. Recover by extracting `~/.gemini_api_key_secret` and the bashrc-sourced `WORLDAI_DEFAULT_GEMINI_MODEL` / `GEMINI_MODEL` / `AGY_MODEL` lines in the same turn.

### MINT a fresh Gemini key when bashrc has no healthy key (added 2026-08-22, third turn)

When the bashrc `GEMINI_API_KEY` is also leaked/invalid AND the user has explicitly said "make a new one in /browser", the fastest working path is `gcloud services api-keys create` against the project that has the Vertex AI API enabled. Verified 2026-08-22 against `worldarchitecture-ai`:

```bash
# 1. Mint the key (interactive project picker if you have multiple)
gcloud services api-keys create \
    --project=worldarchitecture-ai \
    --display-name="wc3-gender-neutral-2026-08-22" \
    --api-target=service=generativelanguage.googleapis.com

# 2. Extract the keyString. Watch the prefix:
gcloud services api-keys get-key-string \
    projects/754683067800/locations/global/keys/43a71747-75d5-445c-86c0-be607a2fc446
# Returns: "keyString: AIzaSy..."   <-- the literal "keyString: " prefix MUST be stripped

# 3. Verify the new key is healthy
curl -fsS "https://generativelanguage.googleapis.com/v1beta/models?key=AIzaSy..." \
  | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('models',[])))"
# Should print >= 10. If 0 or HTTP 403, that key is also leaked.
```

**Three non-obvious pitfalls:**

- The `--key=...` flag does NOT work on `get-key-string`; it expects the positional `KEY : --location=LOCATION` syntax. Confused 2026-08-22 trying `--key=projects/.../keys/...` and got "unrecognized arguments".
- The output is `keyString: AIzaSy...` with a literal `"keyString: "` prefix. Use `| sed -E 's/^keyString: //'` to strip. If you forget and pass the whole line to `?key=`, you get `URL can't contain control characters`.
- `gcloud services api-keys create` works without OAuth anti-automation blocks because it uses the service-account path, not the AI Studio web UI. Verified 2026-08-22: 50 models accessible on the minted key, no Google "request is suspicious" page.

**Why this is the canonical path over AI Studio's web UI:** AI Studio's `Create API key` flow runs Google's anti-automation token check on the server side. Headless Chromium (Playwright), Aside REPL, and the user's own Chrome with `--remote-debugging-port=9222` all hit `Failed to generate API key, The request is suspicious. Please try again.` Verified 2026-08-22 across all three. `gcloud` doesn't.

---

## Pitfalls

### Pitfall 0 — Double-encoded Unicode escapes render as literal `\u2019` on the share-landing page

**Symptom (verified 2026-08-18, prod share `eXd9t9xMsG0qBj279Tw9QtYEspqtd45tFOH1LngLQ-U`):**

The blockquote on `/shared/<token>` rendered `King\u2019s Landing` instead of `King's Landing` — the six-character literal `\u2019` printed verbatim, not the U+2019 right single quotation mark. Same defect class for `\u2014` em dash, `\u00d7` multiplication sign, etc.

**Root cause:**

A `setting`/`description` field was JSON-escaped after an earlier JSON round-trip (e.g. an LLM-generated string was `json.dumps`'d, the result was stored, then `json.dumps`'d again on read). The 6-char literal `\\u2019` made it into Firestore instead of U+2019. `markupsafe.escape` in `mvp_site/share_token.py::render_shared_landing_page` only encodes `& < > " '` to HTML entities — it does **not** decode `\\uXXXX` sequences, so the 6-char literal passed through verbatim.

**Fix pattern (applied to `mvp_site/share_token.py`, PR #9100):**

Add a regex-gated decoder that walks the string and converts `\uXXXX` / `\xNN` / `\UXXXXXXXX` literals to Unicode code points, then apply it to `title`, `setting`, `description` in BOTH `get_shared_payload()` (the `/api/shared/<token>` JSON endpoint — clients consuming the API also see the right character now) and `render_shared_landing_page()` (the HTML page), BEFORE the existing HTML-escape pass.

```python
_EMBEDDED_UNICODE_ESCAPE_RE = re.compile(
    r"\\u[0-9A-Fa-f]{4}|\\x[0-9A-Fa-f]{2}|\\U[0-9A-Fa-f]{8}"
)

def _decode_embedded_unicode_escapes(value):
    if not isinstance(value, str) or not value:
        return value
    if not _EMBEDDED_UNICODE_ESCAPE_RE.search(value):
        return value  # byte-identical pass-through on clean strings
    out, i, n = [], 0, len(value)
    while i < n:
        ch = value[i]
        if ch != "\\" or i + 1 >= n:
            out.append(ch); i += 1; continue
        nxt = value[i + 1]
        if nxt == "u" and i + 5 < n and all(c in "0123456789abcdefABCDEF" for c in value[i + 2 : i + 6]):
            out.append(chr(int(value[i + 2 : i + 6], 16))); i += 6
        elif nxt == "U" and i + 9 < n and all(c in "0123456789abcdefABCDEF" for c in value[i + 2 : i + 10]):
            out.append(chr(int(value[i + 2 : i + 10], 16))); i += 10
        elif nxt == "x" and i + 3 < n and all(c in "0123456789abcdefABCDEF" for c in value[i + 2 : i + 4]):
            byte_val = int(value[i + 2 : i + 4], 16)
            out.append(bytes([byte_val]).decode("latin-1")); i += 4
        else:
            out.append(ch); i += 1  # unknown escape — keep the backslash
    return "".join(out)
```

**Why not `codecs.decode(value.encode("utf-8"), "unicode_escape")`:**

The `unicode_escape` codec treats `\xNN` as a single ISO-8859-1 byte. That silently breaks UTF-8 multi-byte sequences: `\xF0\x9F\x98\x83` (the bytes for U+1F603 GRINNING FACE) decodes to `'ð\x9f\x98\x83'` (4 garbage Latin-1 chars) instead of `😃`. The custom walker treats `\u` / `\U` as Unicode code points and `\x` as a single UTF-8 fragment — the right semantics for the actual bug.

**Why the regex pre-check matters:**

A no-embedded-escape string must pass through **byte-identical**. Always applying `codecs.decode(..., "unicode_escape")` would silently transform otherwise-correct content (real Unicode chars, JSON-style escapes that are part of normal prose, etc.). The regex gate keeps the fix narrow: the helper is a no-op on 99% of strings and only kicks in when the user-visible `\u2019` literal pattern is present.

**Regression coverage (4 tests in `mvp_site/tests/test_share_token.py`):**

- `test_decode_embedded_unicode_escapes_helper_passes_through_clean_strings`
- `test_decode_embedded_unicode_escapes_helper_decodes_known_patterns`
- `test_render_shared_landing_page_decodes_embedded_unicode_escapes` — full end-to-end regression against the prod symptom
- `test_render_shared_landing_page_preserves_clean_strings_unchanged` — proves the fix is narrow

**See also:** `references/share-landing-render-encoding-bugs.md` for the full incident transcript + diff stats + verifier commands.

### Pitfall 1 — `firebase.auth().currentUser` returns null after a profile switch

The most common "the wrong account opened" failure mode. After `aside account use u0`, the page handle from a prior `openTab` is still on the old account. Two fixes:

1. **Re-openTab** to get a fresh page handle on the new account.
2. **Wait 4s extra** after page load for Firebase Auth to rehydrate. The daemon's `currentUser` is populated lazily after the cookie jar settles.

Without both, `currentUser` is `null` and `getIdToken()` throws `Cannot read properties of null`.

### Pitfall 2 — `legacy_share_field_too_long` (400) on bible-stuffed campaigns

Campaigns whose `description` is the full `wa-campaign-bible-rhaenrya` markdown (~9 KB) will pass Step 3's probe but fail Step 3b's confirmation POST with 400. The fix is to truncate `description` to ≤300 chars before POSTing. The `character` and `setting` fields are short enough to never trip this — only `description` does.

**Anti-pattern:** echoing back the full bible description verbatim. The API rejects it; the user sees `{"error":"legacy_share_field_too_long"}` and assumes the mint failed entirely.

### Pitfall 3 — Picking the wrong campaign by version (e.g. "v2")

When the user names a campaign by version (`rhaenrya v2`), do NOT assume the latest (copy) variant is what they meant. Verified 2026-08-18: a search for `rhaenrya` on `jleechantest@gmail.com` (u1) returned 2 matches — `(copy)` and the original — but neither was literally named "v2". The actual "v2" (`oA6tCRZNZhAlaPnh7ri7`, "Rhaenyra v2") lived on `jleechan@gmail.com` (u0) and was 4 days newer.

**Recipe:** search across **all** accessible Aside profiles with `/rhaenrya|v2|v3/i` (case-insensitive, match title AND initial_prompt) before picking. If the user's intent is ambiguous, mint on the literal-title match and tell them what you picked.

### Pitfall 4 — Token ≠ ownership

A `share_token` minted by u1 on a u0-owned campaign is still bound to the campaign, not the minter. The recipient plays it under their own UID. The minter's UID only matters for the audit log. Don't refuse to mint just because "you're not the owner" — the API doesn't enforce that and the token works regardless.

### Pitfall 5 — `GET /api/campaigns?limit=4000` returns an error

The API caps `limit` (verified 2026-08-18). Use `limit=100` with cursor pagination instead. Cursor field is not stable across response shapes — try `next_cursor`, then `nextCursor`, then `cursor`. Some response shapes wrap campaigns under `body.campaigns` or `body.items` — handle both.

### Pitfall 6 — Aside REPL `p.evaluate` return values are sometimes dropped from stdout

Bare `await p.evaluate(async () => …)` at the end of an `aside repl` script was silently dropped from stdout (only `[ok | <Nms>]` appeared). The reliable patterns:

```js
// Pattern A — top-level const + console.log
const r = await p.evaluate(async () => { … return { … }; });
console.log('OUT:', JSON.stringify(r));

// Pattern B — console.log inside the evaluate
await p.evaluate(async () => { console.log('OUT:', JSON.stringify({ … })); });
```

### Pitfall 7 — Mac provenance xattr blocks ffmpeg/dd/shasum on freshly-downloaded mp4s

If you capture or download an mp4 into `~/Downloads/`, macOS may attach a `com.apple.provenance` xattr that breaks ffmpeg/dd/shasum reads with `EINTR`. The reliable workaround is to copy to `~/.smartclaw/cache/videos/<id>.mp4` first (no xattr) or to strip the xattr with `xattr -d com.apple.provenance <file>`.

This is general macOS friction, not WA-specific, but it bites hard when capturing share-flow screen recordings.

### Pitfall 8 — "share link" means the WA campaign share URL, not a Google Doc

See the "Trigger phrases" section above. Decision rule: if a `/google` step just produced a Google Doc, the user's *next* "share link" ask targets the WA campaign unless they say "share the doc". Both are produced when ambiguous.

### Pitfall 9 — Probe echoes empty `legacy_share_fields` when the campaign stores everything in `initial_prompt`

**Symptom (verified 2026-08-22, nocturne warcraft 3 campaign `VlE5OakMI0ztNeEY1vrH`):**

```json
{"error":"legacy_share_fields_confirmation_required","legacy_share_fields":{"character":"","description":"","setting":""}}
```

The 409 fires (the campaign is missing stored `character`/`description`/`setting` because everything was stuffed into the single `initial_prompt` markdown field by a newer wizard), but the echoed-back legacy fields are empty strings — POSTing `{confirm_legacy_fields:true, legacy_share_fields:{character:"", description:"", setting:""}}` returns `400 setting is required`.

**Fix:** Skip the probe. POST directly with `confirm_legacy_fields: true` and pass `legacy_share_fields` populated from the source bible (or the v1.0.0 source character/setting/description if you have them). The API will accept the explicit fields even though the probe returned empty ones. Verified end-to-end on the same campaign — minted token `CGggCavVwA_dWIU0QSKfemdpSA_rhWPJk01-mKHc2KA` on 2026-08-22 with this recipe.

### Pitfall 10 — Cross-account: the bashrc path is faster than the Firestore scan for finding a campaign_id

**Symptom:** You need a campaign_id to mint, but you don't know which jleechantest/jleechan campaign is "the one". The naively-correct path is `wa-per-user-campaign-lookup` (Firestore walk via the `download-campaign` skill path). The faster path:

```python
import os, sys, json
os.environ['GOOGLE_APPLICATION_CREDENTIALS'] = os.path.expanduser('~/serviceAccountKey.json')
sys.path.insert(0, '${HOME}/worldarchitect.ai/mvp_site')
sys.path.insert(0, '${HOME}/worldarchitect.ai')
import firebase_admin
from firebase_admin import credentials, firestore
if not firebase_admin._apps:
    firebase_admin.initialize_app(
        credentials.Certificate(os.path.expanduser('~/serviceAccountKey.json')),
        {'projectId': 'worldarchitecture-ai'},
    )
db = firestore.client()
camps = db.collection('users').document('0wf6sCREyLcgynidU5LjyZEfm7D2').collection('campaigns').stream()
noct = sorted(
    [(c.id, (c.to_dict() or {}).get('last_played')) for c in camps
     if 'noct' in ((c.to_dict() or {}).get('title') or '').lower()
        and 'warcraft' in ((c.to_dict() or {}).get('title') or '').lower()],
    key=lambda x: x[1] or '1970', reverse=True,
)
campaign_id = noct[0][0]
```

This is ~10× faster than the API pagination recipe and gives you the canonical owner UID without a separate auth round-trip. The `last_played` sort works as a "most recent" heuristic when the user doesn't name a specific campaign.

**Anti-pattern:** Trying to mint against the latest `id` from `GET /api/campaigns?paginate=true&limit=10`. The local-server API has no auth gating on that endpoint but it returns a paginated list of campaign stubs without owner info; you then need a second call to resolve the campaign's actual Firestore state. Skip it — go straight to Firestore when you have bashrc service-account access.

---

## Tests

```bash
# Run the reference script end-to-end against the deployed API
python3 ~/.smartclaw/skills/wa-share-flow/scripts/mint_share_token.py \
  --campaign-id oA6tCRZNZhAlaPnh7ri7 \
  --firebase-uid vnLp2G3m21PJL6kxcuAqmWSOtm73 \
  --server https://mvp-site-app-dev-i6xf2p72ka-uc.a.run.app
```

The script:
1. Probes the campaign's legacy fields via empty POST.
2. Truncates `description` to ≤300 chars if needed.
3. POSTs the confirmation with `confirm_legacy_fields: true`.
4. Verifies the minted `share_url` renders signed-out (HTTP 200 + h1 visible).

Output: `{"share_token": "…", "share_url": "…", "verified": true}` or `{"error": "…"}`.

### Local-server variant (added 2026-08-22)

```bash
# Same script, but pointed at the local Flask server on port 8081-8181
python3 ~/.smartclaw/skills/wa-share-flow/scripts/mint_share_token.py \
  --campaign-id VlE5OakMI0ztNeEY1vrH \
  --firebase-uid 0wf6sCREyLcgynidU5LjyZEfm7D2 \
  --server http://127.0.0.1:8088 \
  --auth-bypass
```

The `--auth-bypass` flag swaps the OAuth-flow bearer-token retrieval for the `/api/test_client_token_login` browser auto-signin. Output is identical to the prod variant. Verified end-to-end on 2026-08-22 against the local Flask server.

### Local-server + `SHARE_URL_BASE` override to mint a *public* dev URL (added 2026-08-22, third turn)

When the user wants a share link on the **GCP dev URL** (`https://mvp-site-app-dev-i6xf2p72ka-uc.a.run.app/shared/...`) but the campaign lives on the local server, the local server can mint it directly via the `SHARE_URL_BASE` env var (set in `mvp_site/share_token.py::build_share_url`):

```python
os.getenv("SHARE_URL_BASE", "").strip() or "https://worldarchitect.ai"
```

The flow is: kill the local WA server, relaunch it with `SHARE_URL_BASE=https://mvp-site-app-dev-i6xf2p72ka-uc.a.run.app`, then mint the share token against `http://127.0.0.1:<port>` as normal. The minted `share_url` comes back as the public dev URL even though the bearer was issued by the local server. Verified 2026-08-22: `gcloud services api-keys create` minted a fresh `generativelanguage.googleapis.com` API key in the `worldarchitecture-ai` project, the rotate script set both `GEMINI_API_KEY` and `SHARE_URL_BASE` on the relaunched local server, and the mint returned `https://mvp-site-app-dev-i6xf2p72ka-uc.a.run.app/shared/<token>`.

**Why this works:** the `build_share_url(token, request_origin=None)` helper validates `request_origin` against an allowlist (loopback, prod, dev). When `request_origin` is null (which is what the local server's `/api/campaigns/<id>/share-token` handler passes in production code paths), it falls back to `os.getenv("SHARE_URL_BASE")` and only then to `"https://worldarchitect.ai"`. Setting the env var to the dev URL overrides the default without any code change.

### Gemini-key health probe (added 2026-08-22)

```bash
# Returns the count of models accessible to a given Gemini key (0 = leaked/invalid)
python3 ~/.smartclaw/skills/wa-share-flow/scripts/gemini_key_health.py \
  --key-file ~/.gemini_api_key_secret \
  --key-name GEMINI_API_KEY
```

Output: `KEY_HEALTHY: 50 models accessible` or `KEY_LEAKED: HTTP 403`. Use this BEFORE claiming "Gemini API key is leaked" — the bashrc key is often healthy while the server's env has a different, leaked key.

---

## References

- `references/2026-08-18-rhaenrya-v2-mint.md` — full worked session: search → probe → confirmation → truncate → mint → verify, with the exact Aside REPL transcript and curl-equivalent.
- `references/share-token-api-shape.md` — every endpoint variant the share-link flow touches (mint, verify, list-with-token, revoke if any), with status codes.
- `references/aside-profile-switch-recipe.md` — the `aside account use` + 4s-wait dance, captured separately because it generalizes beyond WA share-flow to any cross-account WA work.
- `references/share-landing-render-encoding-bugs.md` — the embedded-Unicode-escape decoder bug (Pitfall 0): full incident transcript, the `_decode_embedded_unicode_escapes()` helper, before/after curl evidence, and the verification commands a future session should re-run if the symptom recurs.
- `references/2026-08-22-nocturne-wc3-gender-neutral-mint.md` — added 2026-08-22: full worked session for the gender-neutral wc3 campaign. Includes the local-server test-bypass recipe (Pitfall 9 empty-legacy-fields), the Gemini-key bashrc extraction + rotation script, the AI Studio headless-mint "suspicious" block, and the "share link vs Google Doc" disambiguation (Pitfall 8).
- `references/2026-08-22-gcloud-gemini-key-mint.md` — added 2026-08-22: when bashrc's key is also leaked, the working path is `gcloud services api-keys create --project=worldarchitecture-ai --api-target=service=generativelanguage.googleapis.com` (bypasses AI Studio's "request is suspicious" anti-automation block). Includes the `keyString: ` prefix-stripping gotcha and the `get-key-string` positional-arg gotcha.
- `wa-per-user-campaign-lookup/SKILL.md` — for resolving a campaign by name across all users' Firestore docs (when the API path isn't enough).
- `wa-prod-data-query/SKILL.md` — for the production-data gotchas (timestamps, projectId override) that share-flow inherits.
