# Worked example — Hanji Stevens (2026-08-07)

First real-world exercise of the `wa-per-user-campaign-lookup` recipe. Captured end-to-end so future agents have a worked receipt, not a blank procedure.

## Ask

Slack message: *"Which campaign did this person play and how far did they go? hanjistevens@gmail.com"*, follow-up *"What happened in the campaign"*.

## Step 1 — Initialize

`firebase_admin.initialize_app(cred, {"projectId": "worldarchitecture-ai"})` — required because the local shell exports `GOOGLE_CLOUD_PROJECT=ai-universe-2025`. Without the override, the first `auth.get_user_by_email` fails with `INSUFFICIENT_PERMISSION` (Pitfall 1).

## Step 2 — Email → uid

```python
user = auth.get_user_by_email("hanjistevens@gmail.com")
# uid=oPISN50TvEcH21uVYKzlZX1kKNv2
# display_name=Hanji Stevens
# creation=2026-08-06T22:37 UTC (signed up yesterday)
# last_sign_in=2026-08-06T23:41 UTC (last touched the app an hour before this query)
```

## Step 3a — Campaign listing

`db.collection("users").document(uid).collection("campaigns")` returned **2 docs**:

| campaign_id | title | created_at | last_played | story entries | turns |
|---|---|---|---|---|---|
| `5VxJ858BqWqHy5ksuoZT` | My Epic Adventure | 2026-08-06 22:36 UTC | 22:41 UTC | 6 | 1 |
| `2G4YpEKFCPAVC7gjS3ET` | Halcyon Days | 2026-08-07 00:04 UTC | 2026-08-07 05:22 UTC | 156 | 61 |

Total activity span: 2026-08-06 22:36 → 2026-08-07 05:22 UTC = ~6h 46m, in two distinct sessions (abandonment gap 1h 23m, return and play 5h 18m).

## Step 3b — Per-campaign signal

### Campaign 1: "My Epic Adventure" (Barovia ranger test drive)

- 6 story entries, last timestamp 22:41 UTC (5 min after creation)
- `current_state.player_turn=1`, `turn_number=1`, `last_living_world_turn=0`
- Character: Silas Greymoor, Lvl 1 Ranger, 12/12 HP, 10gp, 0 XP
- Opening narrative only — user never took a second action. Abandoned.

### Campaign 2: "Halcyon Days" (the real playthrough)

- 156 story entries, 78 user turns / 78 gemini turns
- `current_state.player_turn=61`, `turn_number=61`
- Character: **Hilga Herelin**, Lvl 1 Mercenary, 5/12 HP (in active combat), 100gp, **10/300 XP** (per the latest `session_header`)
- Latest `session_header` location: **Old Halcyon – Right Inspection Tunnel** mid-fight against Sechi Senokima
- Latest user action: *"So go on chase after him. Five four three two one…."*

Useful `current_state` sub-trees seen:
- `player_character_data.health.{hp, hp_max, temp_hp, death_saves.{successes,failures}}`
- `player_character_data.experience.{current, to_next_level, needed_for_next_level}`
- `player_character_data.resources.spell_slots.level_1.{current, max}` and `.gold`
- `npc_data.<name>.{level, hp_current, hp_max, relationships.player.trust_level}`
- `combat_state.combatants.<id>.{hp_current, hp_max}` for live combat
- `custom_campaign_state.next_companion_arc_turn: 60` (story-side trigger threshold)

## Step 3c — Story arc digest

The story has three phases. Sort by `story/{entry}.timestamp`, not by document id.

1. **World + character setup** (turns 0–14, ~1h 50m of god-mode): user posts a long prompt building a Bleach/Persona-style twin-city cyberpunk world (New Halcyon over Old Halcyon, Wardens/Mercatorum/Custolii factions, 10 Kits spells). Mid-edit, user retcons Hilga from Warden to street mercenary (Erron Black + trickster archetype), names his partner **Namaro Malavise** (Lamar Davis from GTA V vibes). Locks the "Kits de-materialize in New Halcyon" rule.
2. **Halcyon High** (turns 15–63, ~50m): rainy London morning. Boys enter school in disguise. Hilga deliberately sits next to Sechi Senokima (brunette Warden), pulls playboy charm routine, solves a vector equation to showboat, plays it off as a guess. End of class, Bizzar Key retrieved, descent into Old Halcyon.
3. **The heist + ambush** (turns 64–155, ~2h): broker Hamicho Duran (Urahara vibes, fishing-rod Kit "Fijini", ramen-shop front) lowballs the boys on a Drive Core (5k vs 100k+ from two girl buyers). Boys head to a dry-docks meet. Ambush: the "buyers" are Seda Saisanoo and Sechi Senokima, the Wardens who've been tailing them. Hilga ambushes Sechi through smoke, pins her, knees her, elbows her, takes her Stremma pistol. Seda arrives, Namaro escapes via speakerphone bluff, Hilga uses Sechi as a shield, talks Seda into chasing Namaro. Counts down on his fingers. Seda sprints off.
4. **Cliffhanger** (turn 155): Hilga realizes he never released Sechi; she's still pinned under him, conscious and angry. User pauses into god-mode twice (combat-difficulty crank, "make Sechi up and fighting"), then *"Continue Story"* → Sechi lunges with the Stremma. Combat paused mid-engagement.

## The "how far did they get" one-liner

> **Halcyon Days**, **turn 61 of 156 story entries**, **Level 1 Mercenary** (Hilga Herelin), **5/12 HP mid-combat**, **10/300 XP**, paused on a cliffhanger in Old Halcyon's Right Inspection Tunnel. 5h 18m of actual play across one extended session last night.

## Recipe notes (for the next agent)

- This user has only ever played at night UTC (22:36 → 05:22). If they come back, expect same window.
- They like god-mode mid-game for retconning NPCs and difficulty. Don't interpret god-mode entries as story beats.
- They played one test campaign for 5 minutes and one real campaign for 5+ hours. Worth flagging in any aggregate funnel — almost all their tokens went into the second campaign.

## Repro

```bash
cd ~/worldarchitect.ai && \
  GOOGLE_CLOUD_PROJECT=worldarchitecture-ai \
  WORLDAI_DEV_MODE=true \
  GOOGLE_APPLICATION_CREDENTIALS=~/serviceAccountKey.json \
  .venv/bin/python <<'PY'
import os, sys
sys.path.insert(0, "${HOME}/.smartclaw/skills/wa-prod-data-query/scripts")
import firebase_admin
from firebase_admin import credentials, auth, firestore
if not firebase_admin._apps:
    firebase_admin.initialize_app(
        credentials.Certificate(os.path.expanduser("~/serviceAccountKey.json")),
        {"projectId": "worldarchitecture-ai"},
    )
db = firestore.client()
uid = "oPISN50TvEcH21uVYKzlZX1kKNv2"
# walk the same path as before
PY
```