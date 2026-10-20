# 2026-08-18 — Rhaenyra v2 share-token mint, end-to-end transcript

This is the canonical worked example for `wa-share-flow`. Captures the full sequence from user request to verified share URL, including the Aside REPL transcript and the curl-equivalent.

## User request (paraphrased)

> "Find the rhaenrya v2 campaign, create a campaign, and give me the share link here. Create it using jleechantest@gmail.com / yttesting and /browser"

The user named a campaign by version (`rhaenrya v2`) and pinned two accounts (`jleechantest@gmail.com` u1, with password `yttesting`; `jleechan@gmail.com` u0) and the `/browser` skill (resolved to Aside via `aside-browser-default`).

## What I tried first (WRONG)

1. **Defaulted to u1 / Aside Profile 1** because that's where the last open Aside tab was.
2. **Searched "rhaenrya"** on u1's dashboard. Got 2 matches:
   - `rhaenrya house dragon (tyland third person)` (id `YPd2pP62IyEiKl5pbPth`)
   - `rhaenrya house dragon (tyland third person) (copy)` (id `HATb4LAmdr4kZ4rHMQae`)
3. **Picked the (copy) as "v2"** by inference — no campaign was literally named "v2" on u1.
4. **Minted a share token** via `POST /api/campaigns/HATb4LAmdr4kZ4rHMQae/share-token` → token `<SHARE_TOKEN_MINTED_EXAMPLE_COPY>`.

This worked end-to-end. **But the user later corrected me**: "jleechan@gmail.com has a rhaenrya v2 or something similar." I had picked the wrong campaign.

## What I did after the correction (RIGHT)

1. **Switched Aside account globally**: `aside account use u0` (NOT `aside --account u0` — that flag doesn't actually switch the daemon's active profile; verified).
2. **Re-opened the dashboard** under u0's auth: `aside repl "const p = await openTab('https://mvp-site-app-dev-i6xf2p72ka-uc.a.run.app/'); await new Promise(r => setTimeout(r, 12000)); await new Promise(r => setTimeout(r, 4000));"` — the extra 4s wait is mandatory after a profile switch (Firebase Auth rehydration).
3. **Searched rhaenrya across u0's campaigns**: `GET /api/campaigns?limit=100` paginated, filtered by `/rhaenrya|rhaenyra/i.test(title + ' ' + initial_prompt)`.
4. **Found 4 matches on u0**:
   - `oA6tCRZNZhAlaPnh7ri7` — **Rhaenyra v2** (created 2026-08-14) ← THIS ONE
   - `f1SUHCwB6kgh0VjCBBaF` — rhaenrya house dragon (created 2026-08-08)
   - `rtDfBGdcPs82yltIDzsg` — rhaenrya house dragon (tyland third person) (created 2026-08-08)
   - `skPXYaSXOT99ENdBmWfH` — rhaenrya house dragon (wziard agent stuck) (created 2026-08-08)
5. **Probed the v2 endpoint with empty body**: `POST /api/campaigns/oA6tCRZNZhAlaPnh7ri7/share-token` with `body='{}'` → 409 `legacy_share_fields_confirmation_required`. The 409 echoed back:
   ```json
   {
     "character": "Rhaenyra",
     "description": "---\ntitle: \"House of the Dragon — The Ashen Crown (Rhaenyra)\"\ntype: campaign-bible\ncreated: 2026-08-13\ncampaign_class: \"Bard (College of Swords) L11 + Dragonrider subclass L1-20 (L25 Divine Ascension track)\"\nanchored_to: \"House of the Dragon Season 3 finale state (post-Helaena-suicide, post-Tumbleton-burned, Aegon-alive-on-Dragonstone)\"\nbook_fallback: \"GRRM Fire & Blood (2018), chapters covering 129-131 AC; only invoked where Season 3 cut off or diverged\"\nendings: none — open-ended campaign system; no canonical endings matrix\ntags: [house-of-the-dragon, hotd, rhaenyra, bard, dragonrider, ashen-crown, hardcore, political-realism, season-3, dance-of-the-dragons, worldarchitect-ai]\n---\n\n# House of the Dragon — The Ashen Crown\n\n> **Solo campaign for WorldArchitect.AI.** You are Queen Rhaenyra Targaryen. The throne is yours. Your son is dead. Your rival lives. Your court despises you. Your dragon waits. What kind of queen survives?\n…[9 KB of bible markdown]…",
     "setting": ""
   }
   ```
6. **First POST with full description**: failed with **400 `legacy_share_field_too_long`** because the bible description is ~9 KB.
7. **Truncated description to first 280 chars + suffix**: re-POSTed with truncated description → 200 OK.
8. **Got the token**: `<SHARE_TOKEN_MINTED_EXAMPLE>`.
9. **Verified by opening the share URL signed-out** in a fresh `aside repl` `openTab`: `h1="Rhaenyra v2"`, `playHref` resolved to `/new-campaign?share_token=<SHARE_TOKEN_MINTED_EXAMPLE>`.

## Final share URL

```
https://mvp-site-app-dev-i6xf2p72ka-uc.a.run.app/shared/<SHARE_TOKEN_MINTED_EXAMPLE>
```

Play CTA deep link:

```
https://mvp-site-app-dev-i6xf2p72ka-uc.a.run.app/new-campaign?share_token=<SHARE_TOKEN_MINTED_EXAMPLE>
```

## Curl-equivalent of the Aside REPL sequence

```bash
# Step 1 — Get a Firebase ID token (via the page's auth context, not via REST)
# This is the only practical way to mint; the API rejects unauthenticated POSTs.

# Step 2 — Probe the endpoint with empty body
curl -fsS -X POST \
  -H "Authorization: Bearer $FIREBASE_ID_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{}' \
  'https://mvp-site-app-dev-i6xf2p72ka-uc.a.run.app/api/campaigns/oA6tCRZNZhAlaPnh7ri7/share-token'
# → 409 {"error":"legacy_share_fields_confirmation_required","legacy_share_fields":{...}}

# Step 3 — Truncate description to first 280 chars, POST with confirmation
DESC='House of the Dragon — The Ashen Crown (Rhaenyra). Bard (College of Swords) L11 + Dragonrider subclass L1-20. Solo hardcore political realism campaign anchored to Season 3 finale state. See full bible in the shared world view.'
curl -fsS -X POST \
  -H "Authorization: Bearer $FIREBASE_ID_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$(jq -nc --arg c 'Rhaenyra' --arg d "$DESC" --arg s '' '{confirm_legacy_fields:true,legacy_share_fields:{character:$c,description:$d,setting:$s}}')" \
  'https://mvp-site-app-dev-i6xf2p72ka-uc.a.run.app/api/campaigns/oA6tCRZNZhAlaPnh7ri7/share-token'
# → 200 {"access_count":0,"share_token":"<SHARE_TOKEN_MINTED_EXAMPLE>","share_url":"…/shared/AuO90y…","success":true}

# Step 4 — Verify signed-out
curl -fsS 'https://mvp-site-app-dev-i6xf2p72ka-uc.a.run.app/shared/<SHARE_TOKEN_MINTED_EXAMPLE>' | grep -oE '<h1[^>]*>[^<]+</h1>'
# → <h1>Rhaenyra v2</h1>
```

## Lessons captured

1. **`aside account use <id>`**, not `aside --account <id>`.
2. **4-second extra wait** after profile switch before reading `firebase.auth().currentUser`.
3. **Search across all profiles** before picking a campaign by version name.
4. **Truncate `description` to ≤300 chars** before the confirmation POST.
5. **Verify the share URL** opens a real signed-out landing with `h1` + a working play CTA.

All five are in the parent SKILL.md.
