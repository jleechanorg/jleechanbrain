# Character image URL scope in WA Firestore — 2026-08-14 evidence

## TL;DR

WA Firestore stores **one campaign-level avatar** per campaign, and
**zero per-NPC portraits**. A thorough walk of every string in the
campaign root doc, `player_character_data`, every `npc_data.<name>`
entry, and the entire nested `game_states/current_state` dict returned
exactly 1 image URL per campaign in our sample — the campaign avatar.

## Sample: 5 distinct 50+ entry jleechan campaigns

Verified via inline `firebase_admin` queries (Pitfall 1's explicit
projectId pattern). For each campaign, walked every string value in:

- `users/{uid}/campaigns/{cid}` (root doc)
- `users/{uid}/campaigns/{cid}/game_states/current_state` (recursive)
  - including `player_character_data.*`
  - including every `npc_data.<name>.*`

| Campaign | cid8 | entries | `character_image_urls` found | All URLs |
|---|---|---:|---:|---|
| Overlord shy lich | `JQeI1Aq5` | 364 | 1 | `…/campaign_avatars/vnLp2G3m21PJL6kxcuAqmWSOtm73/0lZBWUBP4Na3u4XjArOd/avatar.png` |
| Valeria iseki | `1jO5rtBM` | 406 | 1 | `…/campaign_avatars/vnLp2G3m21PJL6kxcuAqmWSOtm73/fZGt3Rhd243H8rr7itto/avatar.png` |
| swtor - tenebria | `FsiyESY9` | 466 | 1 | `…/campaign_avatars/vnLp2G3m21PJL6kxcuAqmWSOtm73/FsiyESY987DF2lfgolCI/avatar.png` |
| Visenya v9 | `qoQtHsU7` | 824 | 1 | `…/campaign_avatars/vnLp2G3m21PJL6kxcuAqmWSOtm73/fw9Fo3QXkqshtVxBIwX2/avatar.jpeg` |
| Supergirl | `aKlgKJzE` | 258 | 1 | `…/campaign_avatars/vnLp2G3m21PJL6kxcuAqmWSOtm73/6aXYric3k1IXtJIg6LjT/avatar.png` |

(`0lZBWUBP4Na3u4XjArOd`, `fZGt3Rhd243H8rr7itto`, `fw9Fo3QXkqshtVxBIwX2`,
and `6aXYric3k1IXtJIg6LjT` are the cid of *sibling* campaigns — the
avatar directory is shared across the user's campaign history and the
filename inside sometimes matches a sibling's cid, not the queried one.
This is a quirk of the WA upload pipeline, not per-NPC portrait
storage.)

## NPC metadata that does exist (and is rich)

`npc_data.<name>` for these 5 campaigns had multi-named NPCs with
`level`, `role`, `relationships.player.trust_level`, sometimes
`mbti` / `alignment` labels. Examples:

- Overlord shy lich: Ains, Gazef Stronoff, Zesshi Zetsumei, Sebas Tian,
  Aureole Omega, Pontifex Maximus, Nigredo, Nigun Grid Luin, …
- Valeria iseki: Valeria, Baron Roland Vane, Julian of House Thorne,
  Launch-Security Detail, Hana (Genius Tier), Aurelia Vex, …
- swtor - tenebria: Tenebria, Horuset Scions, Kaedus Vex, Liora Talen,
  Malakor, …
- Visenya v9: Gormon Peake, Ser Humphrey Beebury, Ser Joryn Vance,
  Inquisitor 'S', Septon Raynard, Ser Raymun Fossoway, …
- Supergirl: Supergirl, Arthur Curry, Barry Allen, Oliver Queen,
  Wonder Woman, Hal Jordan, Amanda Waller, Victor Stone, …

None of these NPC entries had any field resembling a portrait URL
(no `portrait`, `image`, `avatar`, `picture`, `image_url`,
`portrait_url`). Walking them recursively turned up zero image strings.

## The regex that found them

This regex catches the campaign-level avatar and the other plausible
image URL shapes the WA upload pipeline emits. Walk it against every
string in the docs above and you'll get the same single-URL result.

```python
URL_PATTERNS = re.compile(
    r"(https?://[^\s\"'<>]+\.(?:png|jpg|jpeg|gif|webp|svg)"
    r"|https?://api\.dicebear\.com/[^\s\"'<>]+"
    r"|https?://[^\s\"'<>]*robohash\.org/[^\s\"'<>]+"
    r"|https?://[^\s\"'<>]*googleusercontent\.com/[^\s\"'<>]+"
    r"|https?://[^\s\"'<>]*googleapis\.com/[^\s\"'<>]+"
    r"|https?://[^\s\"'<>]*storage\.googleapis\.com/[^\s\"'<>]+"
    r"|https?://[^\s\"'<>]*cloudfront\.net/[^\s\"'<>]+)",
    re.IGNORECASE,
)
```

(`re.IGNORECASE` so trailing `.PNG` / `.JPEG` extensions don't slip
through.) A simpler campaign-only matcher is:

```python
CAMPAIGN_AVATAR = re.compile(
    r"https?://[^\s\"'<>]*googleapis\.com/[^\s\"'<>]*"
    r"campaign_avatars/[^\s\"'<>]+/avatar\.(?:png|jpeg|jpg|webp)",
    re.IGNORECASE,
)
```

## Implications for downstream pipelines

- **Avatar dedupe / merge** against an external library (Drive folder,
  S3 bucket, etc.) can only operate on the campaign-level avatar.
- **Per-character scene illustration** must generate per-NPC portraits
  from the campaign avatar as a base (e.g. via an LLM image-edit step
  like Grok/Gemini in-painting with NPC-name text prompts). The text
  metadata in `npc_data.<name>` is the descriptive seed for such
  generations.
- **20-campaign sweeps** that look for image-rich data will mostly
  return 0-image rows — short test campaigns (the Dragon Knight /
  Star Wars quick-start fixtures jleechan spawns in volume) don't
  always populate the avatar field. Don't read a 0-image row as a
  schema break; check the campaign's age and entry count first.
