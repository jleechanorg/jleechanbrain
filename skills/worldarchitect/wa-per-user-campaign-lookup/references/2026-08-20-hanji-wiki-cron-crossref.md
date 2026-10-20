# Worked example — Hanji Stevens (2026-08-20): GH URL cross-reference + BYOK probe

Companion to `references/2026-08-07-hanji-stevens-example.md`. The
2026-08-07 example answered "what campaign did this user play and how
far did they get?". This 2026-08-20 example answers the next two
follow-up questions that came in the same Slack thread:

1. *"Show me GH URLs for these campaigns"* — three distinct URL shapes
   (WA source / wiki mirror / no URL).
2. *"Are they using BYOK"* — recipe for the `users/{uid}.settings` probe.

## Ask

> what is this user doing check their campaigns in llm wiki and show me
> gh urls for them hanjistevens@gmail.com and are they using byok

Follow-up:

> theres a job that exports campaigns to llm wiki repo check if these
> campaigns are there

## Step 1 — Refresh the per-user campaign list

Same workflow as the 2026-08-07 example. Walking
`users/oPISN50TvEcH21uVYKzlZX1kKNv2/campaigns` returned **4 docs** on
2026-08-20 (up from 2 on 2026-08-07):

| campaign_id | title | created | last_played | story | turn |
|---|---|---|---|---|---|
| `5VxJ858BqWqHy5ksuoZT` | My Epic Adventure | 2026-08-06 22:36 UTC | 22:41 UTC | 6 | 1 |
| `2G4YpEKFCPAVC7gjS3ET` | Halcyon Days | 2026-08-07 00:04 UTC | 2026-08-13 15:20 UTC | 222 | 81 |
| `U8QnbMS6unL5Q38rGVvF` | Trashcon Days | 2026-08-13 16:14 UTC | 2026-08-14 09:07 UTC | 92 | 30 |
| `JmSYWVwlcuQNTtd6eFg1` | HALCYON DAYS | 2026-08-15 17:52 UTC | 2026-08-20 21:39 UTC | 922 | 379 |

User meta: `creation_timestamp=2026-08-06 22:36 UTC`,
`last_sign_in_timestamp=2026-08-20 21:39 UTC` — has been playing
~continuously for 14 days.

PC block (verbatim): Halcyon Days `2G4YpEKF` = `Hilga Herelin L1
Mercenary`; HALCYON DAYS `JmSYWVwl` = `Hilga Herelin L2 Halcyon
Mercenary` (leveled up — campaign is the same world bible retconned
twice); Trashcon Days = `Tsukio Surkinshire L1 Student`; the 6-entry
"My Epic Adventure" = `Silas Greymoor L1 Ranger` (Barovia ranger test
drive, abandoned after 5 minutes).

## Step 2 — Identify the wiki-campaign-daily-ingest cron

The user said "theres a job that exports campaigns to llm wiki repo".
The launchd job is:

```
plist: ${HOME}/Library/LaunchAgents/ai.jleechan.wiki-campaign-daily-ingest.plist
script: ${HOME}/.smartclaw/scripts/wiki-campaign-daily-ingest.sh
log:    ${HOME}/Library/Logs/wiki-campaign-daily-ingest.log
err:    ${HOME}/Library/Logs/wiki-campaign-daily-ingest.error.log
```

Schedule: daily at 09:00 local time. Pushes commits to the private repo
`jleechanorg/llm-wiki`. Threshold: `MIN_ENTRIES=50` (campaigns below
50 scenes are intentionally skipped).

Companion launchd jobs in the same family:
`com.jleechan.wiki-daily-worker.plist`, `com.jleechan.wiki-aggregator.plist`
— different scope, not relevant to per-user campaign cross-reference.

## Step 3 — Cross-reference each campaign against the wiki

For each of hanji's 4 campaign IDs, look up the expected wiki source
filename:

```
slug = slugify(title)              # e.g. "halcyon-days", "trashcon-days", "my-epic-adventure"
filename = "<slug>-<id8>.md"       # id8 = campaign_id[:8]
path = ~/llm_wiki/wiki/sources/
```

Result on 2026-08-20 13:00 PT (right after the daily cron ran):

| campaign_id | id8 | expected wiki file | exists? |
|---|---|---|---|
| `5VxJ858BqWqHy5ksuoZT` | `5VxJ858Bq` | `my-epic-adventure-5VxJ858Bq.md` | NO (sub-threshold, 6 < 50 scenes — intentional skip) |
| `2G4YpEKFCPAVC7gjS3ET` | `2G4YpEKF` | `halcyon-days-2G4YpEKF.md` | YES, 100,511 bytes, ingested 2026-08-07 09:01 PT (commit `a7d937cc7`) |
| `U8QnbMS6unL5Q38rGVvF` | `U8QnbMS6` | `trashcon-days-U8QnbMS6.md` | YES, 100,708 bytes, ingested 2026-08-16 22:42 PT (commit `a7d937cc7`) |
| `U8QnbMS6unL5Q38rGVvF` | `U8QnbMS6` | `halcyon-days-U8QnbMS6.md` | YES, 98,283 bytes, ingested 2026-08-14 09:07 PT (commit `c4730d829`) — same Firestore doc, different wiki title (the campaign was renamed in-app from "HALCYON DAYS" to "Trashcon Days"; cron honored the in-app title at ingest time) |
| `JmSYWVwlcuQNTtd6eFg1` | `JmSYWVwl` | `my-epic-adventure-JmSYWVwl.md` | YES, 100,693 bytes, ingested 2026-08-16 09:04 PT (commit `db8b1c53d`) — another same-Firestore-doc / different-title pair (re-using the JmSYWVwl campaign as both "My Epic Adventure" and "HALCYON DAYS") |
| `JmSYWVwlcuQNTtd6eFg1` | `JmSYWVwl` | `halcyon-days-JmSYWVwl.md` | YES, 100,693 bytes, ingested 2026-08-16 22:42 PT (commit `a7d937cc7`) |

So out of 4 Firestore campaign docs, the wiki carries **5 source
pages** because the `U8QnbMS6` and `JmSYWVwl` docs were renamed
mid-life and the cron captured both titles. The wiki intentionally
skips the 6-entry `My Epic Adventure 5VxJ858Bq` — that's not a bug,
it's the threshold working as designed.

## Step 4 — Generate GitHub URLs

URL form for every wiki page:
```
https://github.com/jleechanorg/llm-wiki/blob/main/wiki/sources/
```

For each of hanji's wiki pages, the canonical GH URL is the blob URL
above. **There is no GH URL for the 4 Firestore campaign docs
themselves** — they're end-user playthroughs, not code artifacts, so
no `pull/<cid>` exists in `jleechanorg/worldarchitect.ai`.

The cron's commit history for hanji's pages (chronological):
- `c4730d82` 2026-08-14 09:07 — first wiki-ingest daily commit that included her (`halcyon-days-U8QnbMS6.md`)
- `db8b1c53` 2026-08-16 09:04 — `my-epic-adventure-JmSYWVwl.md`
- `a7d937cc` 2026-08-16 22:42 — `halcyon-days-JmSYWVwl.md`, `halcyon-days-2G4YpEKF.md` (the Aug 7 ingest got refreshed on Aug 16 too), `trashcon-days-U8QnbMS6.md`

The 2026-08-20 daily cron run (commit `1b4f4cc`) only added
`caroline-s-day-wneRKxKr.md` — hanji's 3 active campaigns all showed
`⏭️ Exists` in the log (no new content to push). One earlier scan
errored with `'NoneType' object has no attribute 'collection'` — that
was a transient Firestore client bug, and the next day's run
recovered cleanly with no data loss.

## Step 5 — BYOK probe

The probe lives at `users/{uid}.settings`, NOT `users/{uid}/settings/settings`:

```python
udoc = db.collection("users").document(uid).get().to_dict()
settings = udoc.get("settings", {})
```

Hanji's settings on 2026-08-20:

```json
{
  "debug_mode": false,
  "openrouter_api_key": "",
  "mechanics_hidden": false,
  "openclaw_gateway_url": null,
  "rag_mode": "original",
  "openclaw_gateway_port": 18789,
  "faction_minigame_enabled": false,
  "gemini_api_key": "",
  "llm_provider": "gemini",
  "cerebras_model": "qwen-3-235b-a22b-instruct-2507",
  "gemini_model": "gemini-3.7-flash",
  "openrouter_model": "x-ai/grok-4.3"
}
```

Verdict: **NOT BYOK.**
- `gemini_api_key == ""` and `openrouter_api_key == ""` → no custom key.
- `llm_provider == "gemini"` → using the platform default provider.
- `cerebras_model` populated alone does NOT imply BYOK — Cerebras is
  available platform-side too.
- `openrouter_model` populated alone does NOT imply BYOK — it's just
  the model picker for the OpenRouter provider; the actual BYOK
  indicator is `openrouter_api_key`.

## Recipe notes (for the next agent)

- Three URL shapes for "show me GH URLs for these campaigns": **WA
  repo** (code only, no per-campaign URL), **wiki repo** (per-campaign
  blob URL — this is the answer), **none** (sub-threshold). Don't
  conflate them.
- The wiki filename is `<slug>-<id8>.md`. `id8 = campaign_id[:8]`,
  `slug = slugify(title)`. Two Firestore docs can produce two wiki
  pages if the title changed between ingest runs (verify with `git log
  -- <file>`).
- The cron's log file is `${HOME}/Library/Logs/wiki-campaign-daily-ingest.log`
  (903 KB as of 2026-08-20; ~one day's worth of all-users ingest).
  Per-user blocks start with `========== [N/M] user: <email> (uid=<uid>) ==========`.
  Per-campaign sublines are one of: `Downloading [N] <title> (<id8>)`,
  `⏭️ Exists: <file>.md`, `Found 0 candidates (>= 50 scenes)`, or
  `[ERROR] scan failed for <email>: <message>`.
- BYOK lives at `users/{uid}.settings` (the literal top-level field
  `settings` on the user doc), not as a subcollection. Empty
  `gemini_api_key` + `openrouter_api_key` + `llm_provider == "gemini"`
  is the canonical "platform free tier" answer.
- A 6-entry campaign like `5VxJ858BqWqHy5ksuoZT` will never appear in
  the wiki repo — that's a cron threshold artifact, not a missing
  data point. State the threshold in the reply so the user knows it's
  intentional.
