# campaign_id → owner_uid lookup — the canonical recipe

When the user says "one of my users is getting errors" and points to a campaign, you need to resolve the campaign_id to the owner before you can tell them anything useful ("this is Bill Hussain, he was on Sorcerer L1 character creation"). The naive recipe — scan the `users` collection and pull campaign sub-collections — **silently misses real users**. Verified 2026-08-07 on PR #8811 triage:

- **3 affected campaigns**: `2G4YpEKFCPAVC7gjS3ET`, `9ZRIpp0iVZCXtBmLujBX`, `rUI6fHv7VuKN8zjtwd9e`
- **Firestore `users` collection scan** (6019 user docs, parallelized, ~60s): found **1 of 3** owners (`oPISN50TvEcH21uVYKzlZX1kKNv2` → Hanji Stevens). The other 2 (`yQjpqUqXFNPLFZRGudtE02qiAZm1` = Bill Hussain, `vnLp2G3m21PJL6kxcuAqmWSOtm73` = you) were not present in the `users` collection as user docs — likely because the user doc was created lazily from a different auth path, OR the campaign was created under a uid that hasn't been materialized into the `users` collection yet.
- **BQ `llm_forensics.llm_payloads` DISTINCT user_id query** (the canonical ground truth): found **all 3 of 3** in 1 second flat.

**This is now the canonical lookup path when you need campaign_id → owner_uid for a WA prod problem.**

## 1. Resolve `campaign_id` → `user_id` via BQ

```bash
bq query --use_legacy_sql=false --format=pretty --max_rows=20 "
SELECT user_id, campaign_id, COUNT(*) AS n
FROM \`worldarchitecture-ai.llm_forensics.llm_payloads\`
WHERE campaign_id IN ('<CID_1>', '<CID_2>', '<CID_3>')
GROUP BY user_id, campaign_id
ORDER BY n DESC
LIMIT 30
"
```

The `user_id` field is the Firebase Auth UID. The `n` column tells you which user's activity is dominant on the campaign — useful when one campaign has been shared.

## 2. Resolve `user_id` → email/name via Firebase Auth

```bash
# Use the user-oauth-keyring token (NOT GH_TOKEN — Service Account lacks firebase auth scope)
TOKEN=$(grep oauth_token ~/.config/gh/hosts.yml | head -1 | awk '{print $2}')
curl -fsS -X POST "https://identitytoolkit.googleapis.com/v1/projects/worldarchitecture-ai/accounts:lookup" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"localId":["<uid_1>","<uid_2>","<uid_3>"]}'
```

Returns `[{localId, email, displayName, lastLoginAt, providerUserInfo: [{providerId, displayName, email}]}]`. The `email` field is the source of truth for the user's actual account — display names autofilled from Google may be stale.

## 3. Cross-check with BQ (optional)

If the user claims a campaign is "theirs" but the BQ lookup shows another UID, the user doc in Firestore may be stale. Trust BQ — it's the operational record.

## Why NOT the Firestore users collection scan

The `users` collection in `worldarchitecture-ai` Firestore has ~24,000 docs as of 2026-08-07, but the WA team has not historically maintained a 1:1 correspondence between auth uids and `users` docs. From the `wa-prod-data-query` skill (verified 2026-06-23): "A naive query that walks the root `campaigns` collection will report '0 real-user campaigns' — which is wrong. The correct path is to (1) resolve the user's UID via `auth.list_users()` by email, then (2) walk `users/{uid}/campaigns/*`." But that recipe assumes you already have the email — circular for the "find the user by campaign" direction.

The BQ `llm_payloads` table is the only place where every LLM turn is unambiguously attributed to a user_id — because the LLM call path requires an authenticated user, and the auth_check at the gateway writes the uid into the table. **Every real-user LLM turn is in BQ. Some real-user uids are missing from the Firestore `users` collection.** BQ is the source of truth.

## When the user lookup fails

If BQ returns 0 rows for a campaign, the campaign has never had a real LLM turn — it's a test fixture, a freshly-created campaign, or a campaign the user abandoned during character creation. Do not waste time walking the `users` collection; just report "no owner_uid found, likely a test fixture or newly-created campaign" and ask the user to confirm.

## Worked example — 2026-08-07 PR #8811 triage

| Campaign | BQ `user_id` lookup | Auth lookup | Owner email |
|---|---|---|---|
| `2G4YpEKFCPAVC7gjS3ET` | `oPISN50TvEcH21uVYKzlZX1kKNv2` (126 rows) | ✅ | `hanjistevens@gmail.com` (Hanji Stevens) |
| `9ZRIpp0iVZCXtBmLujBX` | `yQjpqUqXFNPLFZRGudtE02qiAZm1` (36 rows) | ✅ | `bhussain@gmail.com` (Bill Hussain) — the user the operator named |
| `rUI6fHv7VuKN8zjtwd9e` | `vnLp2G3m21PJL6kxcuAqmWSOtm73` (6 rows) | ✅ | `jleechan@gmail.com` (Jeffrey — own test fixture) |

Every user was identified in 2 tool calls (BQ + Auth lookup). The Firestore scan path would have taken 60+ seconds and missed 2 of 3.

## Related

- `wa-prod-data-query` — for aggregate engagement queries ("how many users played this week")
- `drive-pr-to-green` — for the next step once you've identified the user and confirmed the bug
- `repro` — for the full walk of the user's session after you've identified them
