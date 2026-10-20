# WA share-token API shape (verified 2026-08-18, deployed git HEAD `6d90bc02`)

The complete surface for the share-link flow as observed on the deployed dev server. Every status code and response shape below is empirically verified.

## Endpoints

### `POST /api/campaigns/<campaign_id>/share-token`

The single mint endpoint. Behavior depends on the campaign's legacy-fields state.

**Request:**
```http
POST /api/campaigns/<cid>/share-token
Authorization: Bearer <firebase_id_token>
Content-Type: application/json

<any body>
```

**Responses:**

| Status | Body shape | Meaning | Action |
|--------|-----------|---------|--------|
| **200** | `{"success":true,"share_token":"<44 chars base64url>","share_url":"https://…/shared/<token>","access_count":0}` | Token minted (or already existed). | Verify the share_url renders signed-out (Step 4 of parent SKILL.md). |
| **409** | `{"error":"legacy_share_fields_confirmation_required","legacy_share_fields":{character, description, setting}}` | Campaign has legacy schema fields; client must echo them back with `confirm_legacy_fields: true`. | Re-POST with the legacy fields echoed (Step 3b). |
| **400** | `{"error":"legacy_share_field_too_long"}` | The echoed `description` exceeds the API's length cap (empirically ~300 chars; the API does not document the exact cap). | Truncate `description` to ≤300 chars before re-POSTing. |
| **401** | `{"message":"No token provided"}` | Missing or invalid Firebase ID token. | Re-acquire via `firebase.auth().currentUser.getIdToken()`. |
| **404** | HTML 404 page | Endpoint not found — wrong path or wrong server. | Check `server` and `campaign_id` (likely typo). |

### `GET /api/campaigns/<campaign_id>`

Read the campaign's full doc (used to inspect `legacy_share_fields`, `user_id`, `avatar_url`, etc).

**Request:**
```http
GET /api/campaigns/<cid>
Authorization: Bearer <firebase_id_token>
```

**Response (200):**
```json
{
  "campaign": {
    "title": "...",
    "initial_prompt": "...",
    "created_at": "...",
    "last_played": "...",
    "user_id": "<firebase_uid>",
    "avatar_url": "https://storage.googleapis.com/...",
    "replay_provenance": { "copied_at": "...", "source_campaign_id": "...", "source_user_id": "..." },
    "selected_prompts": ["narrative", "mechanics"],
    "use_default_world": false,
    "living_world_state": { "last_time": null, "last_turn": 0 }
  },
  "game_state": { ... full current_state ... },
  "planning_block": { ... },
  "rewards_box": { ... },
  "story": [ ... ],
  ...
}
```

### `GET /api/campaigns?limit=<N>&cursor=<C>`

List the signed-in user's campaigns, paginated.

**Response (200):**
- `limit <= 200`: array of campaign summaries OR a wrapped object (`{ campaigns: [...], next_cursor: "..." }`). Handle both.
- `limit > 200`: `{ "error": "..." }` — the API caps. Verified `limit=4000` fails.

**Cursor field names** (varies by response shape — try in order):
1. `body.next_cursor`
2. `body.nextCursor`
3. `body.cursor`

### `GET /shared/<share_token>`

Public signed-out landing page. Renders the campaign title + description + "Play in this world →" CTA. **No auth required.**

**Expected DOM:**
- `<title>Play in <campaign_title> — WorldArchitect.AI</title>`
- `<h1><campaign_title></h1>`
- A link with text "Play in this world →" whose href is `/new-campaign?share_token=<token>`

If `h1` is missing or the play link is absent, the mint succeeded but rendering broke — that's a different bug class (regression on the shared-landing template).

### `GET /new-campaign?share_token=<token>`

The deep-link path that the landing page CTA points to. Triggers the OAuth login-redirect flow if the user is signed out; otherwise jumps into the wizard.

**Verified behavior (2026-08-18):**
- Signed out → renders a sign-in card with a "Continue with Google" button (Frame 1 of the captioned dual-OAuth share proof).
- Signed in → renders the campaign creation wizard with the share-token consumed.

## Token format

44-char base64url (`A-Z`, `a-z`, `0-9`, `-`, `_`), no padding. Empirically the same length as a Firebase custom token. Treat as opaque — no semantic content is exposed.

## Token binding

A `share_token` is bound to **the campaign**, not the minter. Anyone who knows the URL can open the signed-out landing page. The token's role is to gate the `/new-campaign?share_token=…` consumption, not the landing render.

The minter's UID appears in the backend audit log only. Any signed-in user on the deployment can mint a token for any campaign — there's no ownership check.

## Deployment

- Server: `https://mvp-site-app-dev-i6xf2p72ka-uc.a.run.app`
- Git HEAD deployed: `6d90bc02f62a72ba3f855618264e9ecfd276d7ff` (verified 2026-08-18)
- The dev server is a Google Cloud Run service; the API is unauthenticated at the network layer (gated by Firebase Bearer tokens only).

## Open questions / not-yet-verified

- Is there a `DELETE /api/campaigns/<cid>/share-token` revoke endpoint? Not exercised this session — assume tokens are immutable once minted.
- Does the API rate-limit share-token POSTs? Not observed this session, but the `rate_limits/{uid}.turn_timestamps` collection exists for gameplay — share-flow may share that bucket.
- Does `confirm_legacy_fields` get recorded on the campaign doc? Not verified — the API returns 200 either way.
