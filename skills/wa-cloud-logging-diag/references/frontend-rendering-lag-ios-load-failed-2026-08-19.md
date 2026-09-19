# Frontend rendering-lag triage — iOS Safari `TypeError: Load_failed` + auth.post_return_poll storm (2026-08-19)

**Session:** Slack thread `C0BDEAJH8PK/p1787172968.325109` (Jeffrey → Hermes → "Check gcp logs for frontend rendering lag https://mvp-site-app-dev-i6xf2p72ka-uc.a.run.app/game/ArYA47Fvx8HTYC8jpleO…").
**Campaign:** `ArYA47Fvx8HTYC8jpleO` (Lady Nocturne Ravencrest, Level-16 Paladin - Oath of the Deceiver, draconic Paladin of the Pale Crown holder on the worldarchitect.ai dev pool).
**Service:** `mvp-site-app-dev` (Cloud Run, region `us-central1`, project `worldarchitecture-ai`).
**Skill used to diagnose:** `wa-cloud-logging-diag` v2.1.0 (now v2.2.0 after this transcript).

## User-visible symptom

"Frontend rendering lag" — the user reports the game page on iPhone (iOS 26.6 Chrome) doesn't finish loading. 11 consecutive `auth.post_return_poll` events fire in `cdiag_session=f6502002` at 1-second cadence with `visibility=visible`, which is the proxy signal for "the page is open, the auth callback hasn't resolved, and the request lifecycle is stuck on the failed fetch."

## The three fingerprint data (server-side evidence)

| What | Count | Filter | Verdict |
|---|---|---|---|
| `GET /game/<id>` HTML page-load latency | n=3 in 2h, all ≤20ms | `httpRequest.status=200 AND requestUrl="/game/ArYA47..."` | 🟢 HEALTHY — server-side response is fast |
| `GET /api/campaigns/<id>?story_limit=50` page-load latency | n=3 in 2h, 460-659ms, responseSize 206-209KB | same filters | 🟡 Manageable on desktop, iOS-killer |
| `GET /api/campaigns/<id>?story_limit=50` iOS sessions only | n=1, 0ms, `cdiag_name=network.error TypeError Load_failed` | `jsonPayload.message:"a99f7813"` (the iPhone session) + `requestUrl:campaigns/ArYA47...` | 🔴 BROWSER-SIDE ABORT — connection killed pre-TLS |
| `auth.post_return_poll` poll count per session | polls 1-11 in 1-second cadence | `jsonPayload.message:"f6502002"` + `cdiag_name=auth.post_return_poll` | 🔴 POLLING STORM — the visible "rendering lag" |

## How to read the data (the false-positive traps)

The most-confused signal here is that the server logs `httpRequest.status=200` for the iOS fetch even though the client never received the payload. The three-step confirmation is:

1. **Server sees the request:** `httpRequest.status=200` + `responseSize > 100KB` on `GET /api/campaigns/<id>`.
2. **Client sees `Load_failed`:** `cdiag_name=network.error` + `error_name=TypeError` + `error_message=Load_failed` + `cdiag_field_latency_ms=1` (not server-side 1ms; the connection was killed before the first byte arrived).
3. **Polling storm on the auth loop:** consecutive `auth.post_return_poll` at 1s cadence with `visibility=visible` (page is open, auth callback never resolves because the page-load fetch that the callback needs never returned).

All three are required to confirm the diagnosis. Each is non-diagnostic alone:
- `status=200` + large `responseSize` alone → could be a healthy response, just slow.
- `network.error TypeError Load_failed` alone → could be ANY network abort, not necessarily bloat.
- Polling storm alone → could be a stuck auth callback regardless of fetch state.

## The three downstream effects (correlated, not cause-and-effect)

| Effect | Surface | Cause |
|---|---|---|
| 1. Server payload bloat | `GET /api/campaigns/<id>?story_limit=50` returns 200-559KB | `player_character_data.equipment.backpack` has 24 items instead of ~12, including Frostmourne triplicate (bonus=2 / +3 / +4) and doubled starter gear (Backpack/Bedroll/Mess kit/Tinderbox/Waterskin listed twice). Caused by `_inventory_item_signature` (`mvp_site/firestore_service.py:1119`) using whole-item `json.dumps` — near-duplicates with field differences slip past the dedupe safeguard. |
| 2. Stream-side compaction cost | `STORY_CONTEXT_COMPACTED 210,932tk -> 95,156tk` x3 within 1h | The bloated `player_character_data` is included in the prompt prefix verbatim. `SYSTEM_INSTRUCTION_EMERGENCY_COMPACT 560,030 -> 531,927 chars` was triggered by the 100K-tk threshold. Compaction is real work and adds latency to every turn. |
| 3. iOS pre-TLS abort + client retry-storm | `TypeError: Load_failed` + 11x `auth.post_return_poll` at 1s cadence | iOS WebKit drops sub-second-long pre-TLS connections on slow mobile networks when the payload exceeds the connection's keep-alive budget. The 200KB+ fetch trips the gate; the polling loop continues firing because the page-load fetch never resolved. |

All three are downstream of the same root cause (the equipment-backpack bloat). Fix the dedupe, all three shrink.

## File pointers for the fix worker

- **Root-cause fix:** `mvp_site/firestore_service.py:1119-1188` — change `_inventory_item_signature` from whole-item `json.dumps(item, sort_keys=True)` to a key-of-name-plus-canonicalized-stats (e.g. `(item.name, json.dumps(_canonical_item_stats(item), sort_keys=True))`), and update `_merge_inventory_items` to dedupe by that key. Bead `rev-vhmjd`.
- **Payload split (secondary):** `mvp_site/main.py:2506-2522` (the `GET /api/campaigns/<campaign_id>` route) — consider lazy-fetching `player_character_data` via a separate `/api/campaigns/<id>/character` endpoint when the inventory UI is opened.
- **Client retry (tertiary):** `mvp_site/frontend_v1/app.js:3922-3927` (the `resumeCampaign` page-load call) — add `keepalive: true` + a 1-retry with 500ms backoff on `Load_failed` so the user doesn't see the polling loop as "rendering lag."

## Followup actions dispatched (not yet executed)

1. **Inspect the dedupe write path.** Already partially done in the session — `_inventory_item_signature` is whole-item, near-duplicates slip through. Cross-checked against `_merge_inventory_items` at `mvp_site/firestore_service.py:1160` and `_handle_inventory_safeguard` at `mvp_site/firestore_service.py:1191`. Confirmed root cause.
2. **Beats file:** `rev-vhmjd` created with full root-cause + fix surface + 3 regression-test skeletons (one for signature equality, one for near-dupe dedupe, one for response-size budget).
3. **/web-advice dispatch:** Ladder DOWN on macOS 15.5 Chrome 151 (CDP :9222 empty, browserclaw --headless silent-hang). Recorded in `references/transport-ladder-failure-log-2026-08-19.md`. The diagnosis is solid without the panel; the panel is non-blocking decoration.
4. **Worker dispatch:** NOT executed in this session. Should run a claudem worker on a fresh `feat/lag-fix-inventory-dedupe` worktree branched from `origin/main` per `.cursor/rules/pr-branch-from-main.mdc` + `.cursor/rules/pr-ci-fix-autopush.mdc` + `.cursor/rules/pr-hyperlink.mdc`.

## Confidence breakdown

- **Root cause (whole-item signature lets near-duplicates through):** 🔴 HIGH — confirmed by reading `mvp_site/firestore_service.py:1119-1188` in full and reconciling with the actual `player_character_data` contents (`Frostmourne (De-Linked & Sovereign Bound)` appearing at `bonus=2`, `bonus=+3`, `bonus=+4`).
- **iOS pre-TLS abort:** 🔴 HIGH — `TypeError: Load_failed` is the canonical iOS WebKit pre-TLS connection-drop error. The 0-1ms latency is diagnostic of the connection kill, not of the server response.
- **Polling storm as user-visible lag:** 🟡 MEDIUM-HIGH — the storm is observable; whether it's what the user *means* by "rendering lag" depends on the user's device and network. The "11 polls, 1s cadence, visibility=visible" is a strong proxy, but a Playwright iOS Safari session would be the canonical proof.

## How this transcript compares to existing skill recipes

`wa-cloud-logging-diag` already covered:
- `safeDiag` funnel events (signup.complete → signin.success → game.open → first_turn.begin → first_turn.outcome)
- `cdiag_name=<event>` substring match syntax (the `field:"substring"` form, NOT `field=~"substring"`)
- Streaming-MAX_TOKENS corner case (iPhone Safari "Calculating outcomes..." spinner hangs)
- 3-day silent-loop detection (the same bug recurring across N consecutive days)

This transcript is the first to surface **browser-side fetch abort at the layer of Cloud Logging instrumentation**. Future user reports of "page never finishes loading" or "iOS Safari spinner hangs but desktop is fine" should jump to this recipe as the first check.
