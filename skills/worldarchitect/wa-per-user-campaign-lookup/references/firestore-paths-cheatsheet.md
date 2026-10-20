# Firestore paths cheatsheet — `users/{uid}/campaigns/{cid}/`

Verified against the `worldarchitecture-ai` Firestore on 2026-08-07 (Hanji Stevens). Each path below was actually read for a real user; field names are exact.

## Auth

| Path | Purpose | Field gotchas |
|---|---|---|
| `auth.get_user_by_email(email)` | Resolve email → uid | Wrong project = `INSUFFICIENT_PERMISSION`. Always pass `projectId` to `initialize_app`. |
| `users/{uid}.uid` (Firebase Auth record, not Firestore) | displayName, photoURL, lastSignIn, creation | — |
| `users/{uid}` (Firestore doc) | Account-level settings | `email` is unreliable; `displayName` may be empty |

## Per-campaign surface

| Path | Key fields | Use |
|---|---|---|
| `users/{uid}/campaigns/{cid}` | `title`, `initial_prompt`, `created_at`, `last_played`, `selected_prompts`, `living_world_state`, `use_default_world` | Campaign list / metadata |
| `users/{uid}/campaigns/{cid}/story` (subcollection) | `actor`, `mode`, `timestamp`, `text`, `session_header`, `part` | Chronological narrative |
| `users/{uid}/campaigns/{cid}/game_states/current_state` (single doc) | `player_turn`, `turn_number`, `last_living_world_turn`, `player_character_data.*`, `npc_data.*`, `combat_state.*` | Authoritative progress snapshot |

## `current_state` field paths (verified)

```text
player_turn                              # int — canonical turn count
turn_number                              # int — same value
last_living_world_turn                   # int — last LW tick
schema_migration_version                 # int
game_state_version                       # int

player_character_data.level              # int — current level
player_character_data.experience.current # int — current XP
player_character_data.experience.to_next_level        # int
player_character_data.experience.needed_for_next_level # int
player_character_data.health.hp          # int
player_character_data.health.hp_max      # int
player_character_data.health.temp_hp     # int
player_character_data.health.death_saves.successes # int
player_character_data.health.death_saves.failures   # int
player_character_data.resources.gold     # int
player_character_data.resources.spell_slots.level_1.current # int
player_character_data.resources.spell_slots.level_1.max     # int
player_character_data.hp_max             # int — duplicate of health.hp_max (keep both, read either)
player_character_data.hp_current         # int — duplicate of health.hp

npc_data.<name>.level                    # int
npc_data.<name>.hp_current               # int
npc_data.<name>.hp_max                   # int
npc_data.<name>.relationships.player.trust_level  # int — negative = antagonistic

combat_state.combatants.<combatant_id>.hp_current  # int — live combat
combat_state.combatants.<combatant_id>.hp_max      # int

custom_campaign_state.next_companion_arc_turn     # int — story-side trigger
```

## Story entry fields (verified)

```text
actor         # "user" | "gemini" | ("narrator" | other LLM ids)
mode          # "character" (story) | "god" (admin) | "character_creation"
timestamp     # Firestore Timestamp — SORT BY THIS, NOT BY doc id
text          # str — visible narration or action
session_header  # optional "[SESSION_HEADER]\n..." block with one-liner status
part          # int — multi-part turn counter
narrative     # sometimes present (longer LLM responses)
sequence_id   # int — sometimes present (LLM-side)
```

## Common traps

1. **Root `campaigns` collection is test-only.** All real-user campaigns live under `users/{uid}/campaigns/`. A query against root will silently mislead.
2. **`rate_limits/{uid}.turn_timestamps` may be raw seconds, not milliseconds.** On at least one user the values decoded to 1970. Treat as "exists / not exists" only, not as a date signal.
3. **Sort story entries by `timestamp` field, not by doc id.** Document ids are random strings; sort is meaningless without a key.
4. **Campaign `last_played` is null for some campaigns with story entries** — the user created + played once and never re-opened. Use story `last timestamp` for "did they actually use it".
5. **God-mode entries (`mode="god"`)** are setup/retcon commands, not story beats. Filter `actor=user` for narrative synthesis.
6. **The `session_header` block is optional.** When present, it's the easiest single-field progress snapshot.