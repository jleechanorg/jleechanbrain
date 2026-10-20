---
name: wa-browser-wizard-test
description: Playwright wizard test for WA campaigns.
tags: ["worldarchitect", "playwright", "headless", "wizard", "campaign-creation", "browser-test", "ui"]
related_skills:
  - wa-live-server-smoke
  - wa-visual-proof-playwright
  - wa-mobile-ux-regression
---

# WA headless-browser wizard test

## When to fire this skill

Use when the user asks to drive the WorldArchitect.AI frontend through a multi-step flow (campaign creation, settings change, character wizard completion) end-to-end in a real browser, and verify the resulting game state via the public APIs (`/api/campaigns/{id}/{stats,spells,equipment}`).

Trigger phrases: "test campaign creation via /browser", "walk the wizard", "drive the new-campaign flow", "verify the wizard works in browser", "use /browser for [email] / [password]", "make sure items stats spells ability points all setup properly".

This skill is NOT for: server-side curl smoke (use `wa-live-server-smoke`), pure unit-test evidence (use `mvp_site/tests/`), or visual screenshot capture for an existing PR (use `wa-visual-proof-playwright`).

## Why this skill exists

Server-side curl cannot exercise the wizard's client-side state machine (hidden forms, conditional buttons, multi-step navigation). The wizard is the canonical UX path a real user follows; if it works, the user-facing flow works; if it breaks in the wizard but the API works, the user is blocked.

The wizard's DOM has **two parallel ID sets** — a legacy `customCampaign` / `character-input` form (default-selected) AND a new `wizard-customCampaign` / `wizard-character-input` form (initially hidden behind `FORM.mt-3.wizard-replaced { display: none }`). A naive test that fills `#character-input` clicks a hidden radio and times out — the fix is to navigate through `#go-to-new-campaign` which activates the wizard form. Verified 2026-08-22 on `jleechantest@gmail.com` / `yttesting`.

The 5-step recipe below is the only working path as of 2026-08-22.

## The 5-step recipe

### Step 1 — Sign in via the test token bypass

The local Flask server (port 8088 today, may auto-shift to 8081-8181 per `./local.sh`) exposes a custom-token login at `/api/test_client_token_login?uid={UID}&redirect=/`. Returns an HTML page that signs in via Firebase `signInWithCustomToken` and redirects. The bypass works ONLY when the running server has `WORLDAI_DEV_MODE=true` OR is on a smoke-allowed env with `SMOKE_TOKEN` set; verify with `gog auth status`-equivalent (`curl -i` the URL and confirm `200 OK`).

```python
# Resolve UID for a test email
import os
os.environ['GOOGLE_APPLICATION_CREDENTIALS'] = os.path.expanduser('~/serviceAccountKey.json')
import sys; sys.path.insert(0, '${HOME}/worldarchitect.ai/mvp_site')
sys.path.insert(0, '${HOME}/worldarchitect.ai')
import firebase_admin
from firebase_admin import credentials, auth
if not firebase_admin._apps:
    firebase_admin.initialize_app(credentials.Certificate(os.path.expanduser('~/serviceAccountKey.json')), {'projectId': 'worldarchitecture-ai'})
uid = auth.get_user_by_email('jleechantest@gmail.com').uid   # = 0wf6sCREyLcgynidU5LjyZEfm7D2

# Drive the bypass
URL = 'http://127.0.0.1:8088'
await page.goto(f'{URL}/api/test_client_token_login?uid={uid}&redirect=/campaigns', wait_until='networkidle', timeout=30000)
await page.wait_for_timeout(5000)   # custom-token sign-in + redirect
```

The `redirect=/campaigns` lands on the My Campaigns list with auth cookies set. If a future task uses **Google OAuth** (`jleechantest@gmail.com` / `yttesting` is the password for the real Firebase auth, NOT for the test bypass), fill `accounts.google.com` form with `EMAIL` + `PASSWORD = 'yttesting'`; the password is documented in `~/worldarchitect.ai/roadmap/MILESTONE_1_MATRIX_TESTING.md` and `~/worldarchitect.ai/docs/ai-universe-frontend-test-report.md`.

### Step 2 — Enter the wizard

Click `#go-to-new-campaign` (the visible "📜 Custom Campaign" card). This navigates to `/new-campaign` and activates the new wizard form. Do NOT click `#customCampaign` (the legacy form) — its inputs stay `display:none` because the wizard replaces them.

```python
await page.click('#go-to-new-campaign')
await page.wait_for_url(f'{URL}/new-campaign', timeout=15000)
await page.wait_for_timeout(2000)
```

### Step 3 — Fill step 1 (campaign metadata)

Visible inputs in the wizard step 1:
- `#wizard-campaign-title` (placeholder: "My Epic Adventure")
- `#wizard-character-input` (placeholder: "Random character (auto-generate)")
- `#wizard-setting-input` (placeholder: "Random fantasy D&D world (auto-generate)")
- `#wizard-description-input` if present (rare — only on newer builds)

Submit: click `#wizard-next`.

```python
await page.fill('#wizard-campaign-title', "The Deceiver's Crown (Gender-Neutral Edition)")
await page.fill('#wizard-character-input', 'Nocturne Ravencrest')
await page.fill('#wizard-setting-input', 'Warcraft III: The Third War (alternate timeline, Lordaeron)')
await page.click('#wizard-next')
await page.wait_for_timeout(3000)
```

### Step 4 — Submit step 2 (Enter the World)

Step 2 is the launch screen: an avatar upload widget, a Campaign Summary (Title / Character / Description read-only), `Previous` button, and the visible `Enter the World` button at `#launch-campaign`. There is ALSO a hidden `Begin Adventure!` button — it has no id and is `display:none`; do NOT target it. Click `#launch-campaign` and wait up to 120s for navigation to `/campaigns/{NEW_ID}`.

```python
await page.click('#launch-campaign')
await page.wait_for_url(
    lambda u: '/campaigns/' in u and '/new-campaign' not in u and not u.endswith('/campaigns'),
    timeout=120000
)
campaign_id = page.url.split('/campaigns/')[1].split('?')[0].split('/')[0]
```

### Step 5 — Verify game state via APIs

Hit three endpoints to confirm the LLM-driven world builder populated the right shape:

```python
for endpoint in ['stats', 'spells', 'equipment']:
    r = await page.request.get(f'{URL}/api/campaigns/{campaign_id}/{endpoint}')
    print(f'{endpoint} (status {r.status}):', await r.json())

# Full campaign doc has initial_prompt, player_character_data
r = await page.request.get(f'{URL}/api/campaigns/{campaign_id}')
data = await r.json()
# Expect keys: title, description, initial_prompt, player_character_data.{attributes, spell_slots, spells_prepared, equipment.{ranged,armor,main_hand,ring_1,off_hand,backpack}, health, experience, armor_class, features, alignment}
```

## Mid-game turn driving (a related but different flow)

The skill title says "wizard test" but the same browser primitives apply when the user wants the agent to play ONE turn in an EXISTING campaign (e.g. "click Accept Streetkid Solo Build and screenshot the next scene"). Two new constraints appear at that point:

1. **The campaign must exist in the SAME Firebase-auth account that the browser is signed into.** If the user's screenshot shows Campaign X with title/Scene #N, and `db.collection("users").document(uid).collection("campaigns")` returns empty after a dashboard search for the title slug, the campaign is in another Google account. See Pitfall 8.
2. **`listBrowserTabs()` is unreliable in `aside repl`** for active use — see the alongside-Aside pitfall in `references/2026-08-22-aside-multi-account-partition.md`. Use `aside exec --effort ultrabrowse "..."` with natural-language commands, and verify state via screenshots returned as image attachments, not by trying to read tab URLs from the REPL.

## When NOT to use

- "Read this campaign's *current state* without driving the UI" → use `wa-per-user-campaign-lookup` (Firestore walkthrough) or `download-campaign` (full conversation dump).
- "Move to a different mid-game turn autonomously" — same skill, same path, but if the user pastes a screenshot showing a campaign title/Scene #N that DOES NOT match any tab in the active browser account, stop and ask which Google account owns it (Pitfall 8).
- "Audit a deploy of mvp_site for correctness" → server-side smoke via `wa-live-server-smoke`. Don't open a browser unless the bug is client-side.

## Pitfalls

### Pitfall 8 — Aside account partition: the campaign in the user's screenshot may not be in the active browser profile

When the user pastes a screenshot of a WA game and asks for a turn, the campaign visible in that screenshot belongs to ONE of the Google accounts configured in the local browser. Aside maintains separate browser profiles (`Profile 0`, `Profile 1`); the active profile's signed-in Google account is the only one whose `worldarchitect.ai` IndexedDB, cookies, and dashboard campaigns you can see.

**Symptom:** the user's screenshot shows a campaign title like "Cyberpunk: Jackie's Legacy" Scene #1 with 2 Strategic Choices, but every open WA tab in the current Aside profile renders a completely different campaign (e.g. "noctune Warcraft 3 Scene #253 with 4 Strategic Choices"), and the dashboard search for "jackie" or "cyberpunk" returns 0 of 1195.

**Wrong action:** click on the FIRST choice available in the active tab and pretend it's V's turn. This drives a totally unrelated campaign's LLM and corrupts state for the user.

**Right action:**

1. Read the top-right of the WA dashboard — it shows `jleechan@gmail.com` (Profile 0) or `jleechan@worldarchitect.ai` (Profile 1). Note which.
2. Search the dashboard for the campaign title shown in the user's screenshot (slug or full text).
3. If 0 matches: tell the user which account the current Aside profile is in, name the account you suspect owns the campaign, and ask them to confirm OR switch the Aside profile via `aside --account <u0|u1> "..."` before continuing.
4. **Do NOT** click any choice on the active campaign as a substitute. The LLM response will be for the wrong story and there's no undo.

Verified 2026-08-22: 5 open WA tabs in Profile 0 (`jleechan@gmail.com`) all resolved either to the dashboard or to `/game/Mz4s5zy30noDnSgScPJH` (noctune Warcraft 3 Scene #253) — none to Cyberpunk: Jackie's Legacy, despite the user's screenshot showing that title. Dashboard search returned 0 matches for "jackie" and 0 for "cyberpunk". Real WA UI has no in-app account switcher; the two accounts only separate at the Aside profile level.

Companion reference: `references/2026-08-22-aside-multi-account-partition.md` (full session transcript + recovery recipe).

### Pitfall 1 — `TESTING_AUTH_BYPASS` is NOT the same as `WORLDAI_DEV_MODE` for the bypass endpoint

`/api/test_client_token_login` opens when either:
- `_is_dev_or_test_mode()` returns True (env has `WORLDAI_DEV_MODE=true`), OR
- `_is_smoke_token_login_request()` returns True (request carries valid `X-MCP-Smoke-Token` header AND env is `preview` or `dev` AND `SMOKE_TOKEN` is set)

Production never sets `SMOKE_TOKEN`; the bypass is fail-closed in prod. If `curl -i /api/test_client_token_login?uid=...` returns `404`, the server is in production mode and the bypass is unavailable — use Google OAuth with `yttesting` password instead.

### Pitfall 2 — Legacy form is hidden by default; wizard replaces it

```css
FORM.mt-3.wizard-replaced { display: none; }
```

The legacy `<form class="mt-3 wizard-replaced">` containing `#campaign-title`, `#character-input`, `#setting-input`, `#description-input`, `#customCampaign`, `#prompt-narrative`, `#prompt-mechanics` is `display:none` when the page loads. Filling `#character-input` (without first clicking `#go-to-new-campaign`) will time out with "element is not visible". The wizard has separate IDs prefixed `wizard-`.

### Pitfall 3 — Two "Enter the World" buttons exist; only one is visible

- `#launch-campaign` (visible, step-2 launch button) — click this
- `button:has-text('Begin Adventure!')` (no id, `display:none`, step-2 inner fallback) — do NOT target this

`page.query_selector("button:has-text('Begin Adventure')")` matches the hidden one and `click()` times out. Always target by id (`#launch-campaign`).

### Pitfall 4 — `goto URL` from `await page.goto(URL)` requires `wait_until='networkidle'`

The wizard fires several `fetchApi` calls during hydration (constants/models, settings, etc.). `wait_until='load'` returns before the wizard is interactive; subsequent `page.click('#go-to-new-campaign')` may fire before the click handler is bound, leading to a "not found" error. Use `wait_until='networkidle'` (with timeout 30s) and then `page.wait_for_timeout(2000)` after each navigation to let the wizard render.

### Pitfall 5 — Server-side Gemini API key can be leaked (HTTP 403)

The most common failure mode at step 4 is:

```
[error] Error creating campaign: Error: Failed to create campaign: 403 PERMISSION_DENIED.
  {'error': {'code': 403, 'message': 'Your API key was reported as leaked. Please use another API key.', 'status': 'PERMISSION_DENIED'}}
```

This is a **server-side config issue**, not a browser issue. The WA backend's Gemini API key has been reported as leaked by Google and must be rotated in WA's env / Firebase Functions config. The browser flow worked correctly; only the LLM "craft story hook" call fails. Do NOT chase browser-side fixes — escalate the key rotation to the operator.

### Pitfall 6 — Existing jleechantest campaigns verify the correct game-state shape

If the server-side LLM is blocked, you cannot verify a *new* campaign's shape — but you CAN walk an existing one and confirm the schema:

```python
# Existing campaign (no LLM needed) — read-only verify
for cid in ['<existing-id-from-Firestore>']:
    r = await page.request.get(f'{URL}/api/campaigns/{cid}')
    data = await r.json()
    pcd = data.get('player_character_data', {})
    # Expect: attributes (STR/DEX/CON/INT/WIS/CHA), spell_slots, spells_prepared,
    #         equipment.{ranged,armor,main_hand,ring_1,off_hand,backpack[24-26]},
    #         health.{hp_current,hp_max}, experience.{current,to_next_level,needed_for_next_level},
    #         armor_class, proficiency_bonus, features, alignment, mbti, background
```

This is the fallback when step 4's `launch-campaign` click fails: prove the *shape* of game state by reading existing campaigns, even if you can't *create* a new one through the wizard.

### Pitfall 7 — Firestore is the source of truth; the API is a read cache

If the wizard creates a campaign but the API returns 404, query Firestore directly:

```python
db.collection('users').document(uid).collection('campaigns').order_by('created_at', direction=firestore.Query.DESCENDING).limit(5).stream()
```

The campaign exists in Firestore even if the API call failed mid-flight; you can pull `game_states/current_state` to verify the player_character_data shape directly.

## Quick reference — minimal Playwright script

```python
import asyncio
from playwright.async_api import async_playwright

URL = 'http://127.0.0.1:8088'
TEST_UID = '0wf6sCREyLcgynidU5LjyZEfm7D2'  # jleechantest@gmail.com

async def main():
    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True, channel='chromium')
        page = await browser.new_page()
        await page.goto(f'{URL}/api/test_client_token_login?uid={TEST_UID}&redirect=/campaigns', wait_until='networkidle', timeout=30000)
        await page.wait_for_timeout(5000)
        await page.click('#go-to-new-campaign')
        await page.wait_for_url(f'{URL}/new-campaign', timeout=15000)
        await page.wait_for_timeout(2000)
        await page.fill('#wizard-campaign-title', 'Test Campaign')
        await page.fill('#wizard-character-input', 'Test Character')
        await page.fill('#wizard-setting-input', 'Test Setting')
        await page.click('#wizard-next')
        await page.wait_for_timeout(3000)
        await page.click('#launch-campaign')
        try:
            await page.wait_for_url(lambda u: '/campaigns/' in u and '/new-campaign' not in u, timeout=120000)
            cid = page.url.split('/campaigns/')[1].split('?')[0].split('/')[0]
            for ep in ['stats', 'spells', 'equipment']:
                r = await page.request.get(f'{URL}/api/campaigns/{cid}/{ep}')
                print(f'{ep}:', await r.json())
        except Exception as e:
            print('Launch failed:', e)
            # Pitfall 5/6: server-side blocker; fall back to reading existing campaigns
        await browser.close()

asyncio.run(main())
```

## References

- `references/2026-08-22-jleechantest-wizard-walkthrough.md` — full session transcript: DOM probing sequence, dual-ID discovery, wizard step 1/2 navigation, server-side Gemini 403 fallback, Firestore-direct read of existing campaigns as proof of shape.
- `references/2026-08-22-aside-multi-account-partition.md` — Aside account/profile partition during a "play V's turn in Cyberpunk: Jackie's Legacy" task: which signed-in Google account owns which campaign, why `aside repl`'s `listBrowserTabs()` is unreliable for orchestration, and the recovery path (`aside --account u1` to switch profile). Use when Pitfall 8 fires.