---
name: wa-per-user-campaign-lookup
version: 1.3.0
category: worldarchitect
description: One WA user's campaigns and progress in Firestore — or from the raw/ mirror when no credentials are available.
related_skills:
  - wa-prod-data-query
  - download-campaign
  - repro
  - wa-byok-probe
last_verified: 2026-08-20
---

# WA per-user / per-campaign drill-down

Companion to `wa-prod-data-query`. That skill answers "what did real users do *in aggregate* over a window"; this one answers "what did *this specific user* play, and how far did they get?"

> ## ⚠️ LOAD `wa-prod-data-query` FIRST for the data-model gotchas
>
> This skill assumes you already know:
> 1. Real-user campaign data lives at `users/{uid}/campaigns/{camp_id}/story/{entry_id}` and `users/{uid}/campaigns/{camp_id}/game_states/current_state` — NOT at the root `campaigns` collection (which is test-only).
> 2. `rate_limits/{uid}.turn_timestamps` is the gameplay signal but the array can be populated with raw seconds (showing 1970) — the timestamps inside `story/{entry}.timestamp` are the reliable chronological signal.
> 3. Initialize the Firebase Admin SDK with an explicit `projectId` to bypass `GOOGLE_CLOUD_PROJECT` env var leakage (see Pitfall 1).

## When to use

- "What campaign did `<email>` play?"
- "How far did they get?"
- "What happened in their campaign?"
- "Show me user X's last session"
- Single-user investigation when `wa-prod-data-query`'s aggregate query points at an interesting user
- **No Firestore credentials available** (sandbox, fresh machine, expired key) but you still need to answer "what does jleechan's campaign X look like" → use the `~/llm_wiki/raw/campaigns/` mirror fallback below

## When NOT to use

- "What did *all* real users do last week?" → use `wa-prod-data-query`
- Bulk downloading the full conversation narrative of one campaign (entry-by-entry export to disk) → use `download-campaign`
- Investigating a bug in a specific session → use `repro`

## The standard query workflow

### Step 1 — Initialize with an explicit projectId

```python
import os, sys
sys.path.insert(0, "${HOME}/.smartclaw/skills/wa-prod-data-query/scripts")
import firebase_admin
from firebase_admin import credentials, firestore, auth

if not firebase_admin._apps:
    firebase_admin.initialize_app(
        credentials.Certificate(os.path.expanduser("~/serviceAccountKey.json")),
        {"projectId": "worldarchitecture-ai"},   # ← mandatory override
    )
db = firestore.client()
```

### Step 2 — Resolve email → uid via Firebase Auth

```python
user = auth.get_user_by_email("<email>")
uid = user.uid
print(user.display_name, user.user_metadata.creation_timestamp,
      user.user_metadata.last_sign_in_timestamp)
```

If this raises `auth.UserNotFoundError`, the email is not in this project — stop, do not scan `users/` docs for an email match.

### Step 3 — Walk `users/{uid}/campaigns`

```python
camps = list(db.collection("users").document(uid).collection("campaigns").stream())
for c in camps:
    cd = c.to_dict()
    print(c.id, cd.get("title"), cd.get("created_at"),
          cd.get("last_played"), cd.get("initial_prompt", "")[:80])
```

For each campaign, drill into `story` (entries sorted by `timestamp` field — not by document id) and `game_states/current_state`:

```python
camp = db.collection("users").document(uid).collection("campaigns").document(c.id)
stories = list(camp.collection("story").stream())
sorted_stories = sorted(stories, key=lambda d: d.to_dict().get("timestamp"))
gs = camp.collection("game_states").document("current_state").get().to_dict()
```

Useful `current_state` fields (verified 2026-08-07):
- `player_turn`, `turn_number`, `last_living_world_turn` — the canonical "turn count"
- `player_character_data.level` — current character level
- `player_character_data.experience.current` / `to_next_level` / `needed_for_next_level` — XP triplet
- `player_character_data.health.hp` / `hp_max` / `temp_hp`
- `player_character_data.resources.gold`
- `npc_data.<name>.relationships.player.trust_level` — NPC relationships
- `combat_state.combatants.<id>.hp_current` / `hp_max` — active combat snapshot

Useful `current_state` image assets (verified 2026-08-14):
- **ONE campaign-level avatar** per campaign, walked from any string
  containing `googleapis.com/.../campaign_avatars/<uid>/<cid>/avatar.{png,jpeg}`.
  Hosted in `game_states/current_state` (typically nested under
  `player_character_data.avatar` or a top-level `avatar` field depending on
  campaign age). This is the **only** image asset in any campaign —
  per-NPC portrait URLs do not exist (see Pitfall 5). If a downstream task
  needs per-character portraits (e.g. avatar-dedupe, scene illustration),
  it must generate them from the campaign avatar as a base, or use the
  campaign avatar as a single-character depiction.

Story entry shape:
- `actor`: `"user"` or `"gemini"` (or `"narrator"` / other LLM ids on other providers)
- `mode`: `"character"` (story), `"god"` (admin/system), `"character_creation"`, etc.
- `timestamp`: Firestore Timestamp — **the canonical chronological key**
- `text`: the visible narration or action
- `session_header`: an optional `[SESSION_HEADER]\nTimestamp: ...\nLocation: ...\nStatus: Lvl X | HP: a/b | Gold: Ngp | XP: c/d` block, useful as a one-liner snapshot of progress at that moment

### Step 4 — Synthesize

The "how far did they get" answer is: **turn count + character level + XP triplet + last `session_header` Location/Status line + last user action text**. The "what happened" answer is: an `actor`-labeled narrative digest, ideally with the god-mode retcon chunks called out as setup.

## Credentials-free fallback: the `~/llm_wiki/raw/campaigns/` mirror

**When the standard workflow fails because you have no service-account JSON** (sandbox, fresh machine, key expired, env not wired up), the `download-campaign` skill's batch runs keep a local mirror at:

```
~/llm_wiki/raw/campaigns/
  ├── <campaign_id>/
  │   ├── <title>_<id8>.txt              # full story text, scenes included
  │   ├── <title>_<id8>_game_state.json  # current_state doc, JSON-serialised
  │   └── <title>_<id8>.md               # wiki source page (frontmatter + body)
  ├── <another_campaign_id>/...
  └── alexiel-swtor-entry-001.md ...     # also: per-scene entry stubs in flat form
```

A real campaign's mirror directory is identified by the **20-char Firestore campaign ID** (e.g. `QUrgoflLFNtIerEUIccc`) and contains exactly three files: `.txt` (story), `_game_state.json` (current state), `.md` (wiki source). All three were written together by `download_campaign.py`.

**To answer "what does jleechan's campaign X look like" without Firestore access:**

```python
import json, os
from pathlib import Path

RAW = Path.home() / "llm_wiki" / "raw" / "campaigns"
uid = "vnLp2G3m21PJL6kxcuAqmWSOtm73"  # jleechan's UID; the only user with a populated mirror

# 1. Find every campaign mirror directory
camps = [d for d in (RAW).iterdir() if d.is_dir() and len(list(d.iterdir())) >= 3]
print(f"Found {len(camps)} mirrored campaigns for user {uid}")

# 2. For a specific campaign, read the game_state JSON (canonical current PC data)
for camp in camps:
    jsons = list(camp.glob("*_game_state.json"))
    if not jsons:
        continue
    gs = json.loads(jsons[0].read_text())
    # Verify the user_id matches (every mirrored campaign carries its owner in game_state)
    if gs.get("user_id") != uid:
        continue
    title = gs.get("player_character_data", {}).get("display_name", "?")
    pcd = gs.get("player_character_data", {})
    print(f"{camp.name:20s} | {jsons[0].name[:50]:50s} | "
          f"turn {gs.get('turn_number'):>3} | L{pcd.get('level', '?'):>2} {pcd.get('class_name', '?'):30s} | "
          f"{pcd.get('display_name', '?')}")
```

**Coverage caveat (as of 2026-08-17)**: the mirror only contains campaigns that the `download-campaign` daily cron or one-off batch has pulled. For jleechan the mirror is comprehensive (228+ campaigns). For other users it is sparse to empty — check the per-campaign `_game_state.json` `user_id` field to confirm ownership before trusting it.

**What you CAN answer from the mirror:**
- "What's the player's name/class/level/stats/spells?" — full `player_character_data` is in `_game_state.json`.
- "What NPCs are present?" — `npc_data` dict in the same file.
- "Where is the story set / what's the current location?" — `world_data.current_location_name`, `world_data.world_time` (year/month/day/hour).
- "What was the opening scene?" — first ~500 chars of the `.txt` after the "God Mode:" prompt preamble.
- "How far did the user get?" — `turn_number` + total `len(.txt.split())` words.

**What you CANNOT answer from the mirror (need live Firestore):**
- Chronological "what did real users do this week" → `wa-prod-data-query`
- Live write/deletes (the mirror is read-only)
- Per-user `rate_limits.turn_timestamps` (those live at `rate_limits/{uid}`, not in campaign docs)

Verified 2026-08-17: read the Larion campaign (id `QUrgoflLFNtIerEUIccc`, level 12 half-elf Abys-Sovereign "Alexiel Tethlar", year 1492 Hammer day 1, location "Royal Palace - Training Yard") end-to-end from the mirror with no Firestore connection. See `references/raw-mirror-2026-08-17-alexiel-example.md` for the full worked output.

## Hard rules (proven correct 2026-08-07)

1. **Sort story entries by `timestamp`, not by document id.** Document ids are random; timestamp is chronological. Verified: sorting by id yields a wrong order.
2. **`rate_limits/{uid}.turn_timestamps` is unreliable for chronological math.** On at least one user (Hanji Stevens, 2026-08-07) the array contained values that, interpreted as ms-since-epoch, decoded to 1970. The `story/{entry}.timestamp` field is the trustworthy signal — derive turn count from `current_state.player_turn` instead.
3. **Always include the user-mode (actor=user) story entries in the synthesis.** God-mode entries (`mode="god"`) are setup/retcon commands — interesting to flag, but not part of the narrative arc.
4. **Display the campaign `last_played` and the story `last timestamp` together.** If they diverge by hours, the campaign is in a "saved but abandoned" state. If `last_played` is null but stories exist, the campaign was created and never re-opened (test-only path).
5. **Don't conflate `current_state.player_turn` with `len(story entries)`.** They're usually equal-ish for normal play but `player_turn` is the game's authoritative count; `len(stories)` includes god-mode exchanges.

## Pitfalls

### Pitfall 1 — `GOOGLE_CLOUD_PROJECT` env var leaks into `firebase_admin.initialize_app`

Many local shells export `GOOGLE_CLOUD_PROJECT=ai-universe-2025` (or another unrelated project) for vite/firebase web builds. When you call `firebase_admin.initialize_app(cred)` *without* an explicit `options={...}`, the SDK picks `ai-universe-2025` as the project. Subsequent calls then fail with:

```
firebase_admin._auth_utils.InsufficientPermissionError:
  INSUFFICIENT_PERMISSION ... accounts:lookup
```

…because the WA service account (`firebase-adminsdk-fbsvc@worldarchitecture-ai.iam.gserviceaccount.com`) has no role on `ai-universe-2025`.

**Fix** — pass an explicit projectId that matches your credential JSON:

```python
firebase_admin.initialize_app(
    credentials.Certificate("~/serviceAccountKey.json"),
    {"projectId": "worldarchitecture-ai"},
)
```

If you don't know which project your credential belongs to, `cat ~/serviceAccountKey.json | jq -r .project_id` will tell you. Don't trust `GOOGLE_CLOUD_PROJECT` from the env.

### Pitfall 2 — `auth.get_user_by_email` raises `UserNotFoundError` for real users that *do* exist

If you see "no such user" but the user has clear activity, double-check the projectId override from Pitfall 1 — that's almost always the cause. A wrong-project `accounts:lookup` returns 400 / INSUFFICIENT_PERMISSION (not UserNotFoundError); but if you bypass auth and walk `users/` docs, you'll find email-less docs and conclude "no user found" incorrectly.

### Pitfall 3 — Walking root `campaigns` returns test fixtures only

Naive `db.collection("campaigns").stream()` returns the 20 `test-user-*` docs, all from before 2025-09-30. A query that says "0 real-user campaigns" is silently lying — every real campaign lives at `users/{uid}/campaigns/{cid}`. (See `wa-prod-data-query` for the full breakdown.)

### Pitfall 4 — `users/{uid}` doc can exist with no email / displayName populated

Don't try to filter `db.collection("users")` by email — emails are unreliable in this DB. Resolve email ↔ uid via `auth.get_user_by_email` or `auth.list_users()` only.

### Pitfall 5 — `character_image_urls` walks always yield at most ONE campaign avatar (no per-NPC portraits)

Even though `npc_data` carries rich metadata (name, level, role,
relationships, sometimes MBTI/alignment) and `player_character_data`
carries the PC's full stat block, **neither contains any portrait URL**.
A thorough walk of every string value in:
- the campaign root doc (any `character_image` / `avatar` / `portrait` /
  `pc_image` key),
- `player_character_data` (any nested string),
- every `npc_data.<name>.*` entry,
- the entire nested `game_states/current_state` dict,

returns at most one image: the campaign-level avatar hosted at
`https://storage.googleapis.com/worldarchitecture-ai-frontend-static/campaign_avatars/<uid>/<cid>/avatar.{png,jpeg}`.
Verified 2026-08-14 across 5 distinct 50+ entry campaigns for jleechan
(Overlord shy lich 364 entries, Valeria iseki 406, swtor-tenebria 466,
Visenya v9 824, Supergirl 258) — every single one returned exactly 1
URL, the campaign avatar. `npc_data.<name>` had zero portrait fields.

Don't waste cycles hoping for per-NPC images — they don't exist in WA
Firestore. Downstream pipelines that need per-character portraits
(avatar dedupe against an external library, scene illustration, etc.)
must either (a) depict one character using the campaign avatar, or
(b) generate per-NPC portraits from the campaign avatar as a base.

### Pitfall 6 — No service-account JSON? Use the raw/ mirror

If `credentials.Certificate("~/serviceAccountKey.json")` fails because the
file doesn't exist, the key is revoked, or the SDK can't talk to the
project, **don't pretend you can answer per-campaign questions**. The
correct path is to check the `~/llm_wiki/raw/campaigns/` mirror (see
"Credentials-free fallback" above). The mirror is a per-campaign cache
written by `download-campaign` and it contains the same `user_id`,
`player_character_data`, and `npc_data` you would have pulled from
Firestore, just from a prior batch run.

**Verification step (mandatory before trusting any mirror read):** the
campaign's `_game_state.json` carries a top-level `user_id` field. Compare
it against the UID you were asked about. If they disagree, that mirror
directory belongs to a different user and your answer will be wrong. (In
practice, jleechan's UID `vnLp2G3m21PJL6kxcuAqmWSOtm73` is the only one
with a populated mirror today; the rest of `raw/campaigns/` may contain
stragglers from earlier test campaigns.)

### Pitfall 7 — "Show me GitHub URLs for this user's campaigns" requires THREE sources, not one

A user asking for "GH URLs for these campaigns" wants three different
artifacts — they are NOT all the same URL:

1. **Firestore campaign doc** — `users/{uid}/campaigns/{cid}`. No GitHub URL exists for an end-user playthrough; only the *wiki mirror* (item 3) is reachable via GH.
2. **WA repo (worldarchitect.ai)** — source code only; campaign IDs are runtime data, not source-tree artifacts. Don't fabricate a `pull/<cid>` URL — there is none.
3. **Wiki mirror** (private repo `jleechanorg/llm-wiki`) — pages written by the `wiki-campaign-daily-ingest` cron for any campaign with `>=50` scenes. URL form: `https://github.com/jleechanorg/llm-wiki/blob/main/wiki/sources/<slug>-<id8>.md`. Sub-50-scene campaigns (e.g. hanji's 6-entry "My Epic Adventure" id `5VxJ858BqWqHy5ksuoZT`) are intentionally never mirrored — explain the threshold, don't lie about a missing URL.

The canonical read path:
- Cross-reference the per-user campaign list against `~/llm_wiki/wiki/sources/*.md` filenames matching `<slug>-<id8>.md` (where `id8 = campaign_id[:8]` and `slug = slugify(title)`).
- If a wiki page exists, the GH URL is the blob URL above. If not, the cron has not yet picked it up (or it falls below the threshold).
- For audit, the cron's log is at `~/Library/Logs/wiki-campaign-daily-ingest.log`. Every per-user block follows `========== [N/M] user: <email> (uid=<uid>) ==========` and then per-campaign `Downloading [N] <title> (<id8>)` / `⏭️ Exists: <file>.md` / `Found 0 candidates (>= 50 scenes)` lines.

### Pitfall 8 — BYOK status lives in `users/{uid}.settings`, NOT in a subdoc

When the user asks "are they using BYOK", the answer is in the TOP-LEVEL
`users/{uid}` Firestore document under the `settings` key — NOT in
`users/{uid}/settings/settings` (that path doesn't exist and will silently
return `DocumentReference` exists=False, making you think the field is
absent).

```python
udoc = db.collection("users").document(uid).get().to_dict()
settings = udoc.get("settings", {})  # always a dict, even if user never opened settings
```

BYOK-relevant keys (verified 2026-08-20, project `worldarchitecture-ai`):

| Key | Meaning | BYOK truthy if |
|---|---|---|
| `gemini_api_key` | custom Gemini key | non-empty string |
| `openrouter_api_key` | custom OpenRouter key | non-empty string |
| `cerebras_model` | Cerebras model slug (always set if user picked Cerebras) | non-empty string AND `llm_provider == "cerebras"` |
| `openrouter_model` | OpenRouter model slug | non-empty string AND `llm_provider == "openrouter"` |
| `gemini_model` | Gemini model slug (always set when `llm_provider == "gemini"`, regardless of BYOK) | NOT a BYOK signal by itself |
| `llm_provider` | active provider (`gemini` / `openrouter` / `cerebras`) | NOT a BYOK signal by itself |
| `openclaw_gateway_url` | local OpenClaw gateway URL | proxy-route BYOK (not classic BYOK) |
| `debug_mode`, `mechanics_hidden`, `rag_mode`, `faction_minigame_enabled` | UI flags, not BYOK | ignore |

**Verdict rule:** user is using BYOK iff `(gemini_api_key or openrouter_api_key) != ""` AND that key matches `llm_provider`. Empty strings everywhere + `llm_provider == "gemini"` = platform-default free tier (verified hanji 2026-08-20: `gemini_api_key=""`, `openrouter_api_key=""`, `llm_provider="gemini"` → NOT BYOK). `cerebras_model` populated alone does NOT mean BYOK — Cerebras is also offered platform-side without a user key.

`llm_provider` is set the moment the user changes provider in Settings — it is NOT proof they brought their own key. Always read both the `*_api_key` field AND the provider field, and only call it BYOK when the key matches the provider.

## Tests

```bash
cd ~/.smartclaw/skills/wa-per-user-campaign-lookup
python3 -m unittest discover -s tests -v
```

Covers: projectId override prevents env-var leakage, email→uid resolution, per-campaign field extraction, story-entry chronological sort by `timestamp` field, current_state field path normalization.

## References

- `references/2026-08-07-hanji-stevens-example.md` — full worked example: email → uid → 2 campaigns → 1 active (156 story entries, turn 61, Level 1 Mercenary, "Halcyon Days") + 1 abandoned (6 entries, "My Epic Adventure"). Real-user signal timeline and the resulting narrative synthesis.
- `references/2026-08-20-hanji-wiki-cron-crossref.md` — worked example of cross-referencing a real user's per-campaign list against the `wiki-campaign-daily-ingest` cron log and generating GitHub URLs in the private `jleechanorg/llm-wiki` repo. Covers the 4-campaign case with sub-threshold / wiki-mirrored / Not-Yet-Mirrored sub-cases, and the BYOK probe recipe.
- `references/firestore-paths-cheatsheet.md` — every useful path under `users/{uid}/campaigns/{cid}/` with field-name shortcuts and what each is for.
- `references/character-image-scope-2026-08-14.md` — evidence that
  `character_image_urls` walks always yield at most ONE campaign-level
  avatar (no per-NPC portraits). Includes 5-campaign sample table and
  the regex used. Cites Pitfall 5.
- `references/wa-daily-email-pipeline-2026-08-21.md` — canonical
  `daily_campaign_report.py` workflow + the 5 traps hit live (creation_timestamp
  int-vs-datetime branching, missing `vpython` venv, helper-window bias,
  hardline parser block on inline multi-line env-var extraction, no
  scheduled cron). Use when the user says "the WA daily report", "send
  the usual email early", or asks for the same DAU/WAU report that's in
  their inbox — find this script FIRST before building anything parallel.
- `references/raw-mirror-2026-08-17-alexiel-example.md` — worked example of reading
  the Larion campaign (id `QUrgoflLFNtIerEUIccc`) end-to-end from
  `~/llm_wiki/raw/campaigns/` with no Firestore connection. The opening
  scene, the PC stat block, and the world-time snapshot. Companion to
  the new "Credentials-free fallback" section above.
- `wa-prod-data-query/SKILL.md` — aggregate real-user signal; companion to this skill.
- `download-campaign/SKILL.md` — for archival downloads of one campaign's story (use when the question is "give me the campaign as a file", not "summarize it for Slack").
- `repro/SKILL.md` — for investigating a specific session's bug, not summarizing it.