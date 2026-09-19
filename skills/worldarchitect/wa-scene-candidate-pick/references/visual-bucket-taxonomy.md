# Visual bucket taxonomy — extended cues per IP

For Step 1 scene-candidate-pick, classify each candidate scene into one of 5 visual buckets. Use the per-IP cues below to disambiguate when scenes span multiple buckets (a battle can happen outdoors, a Throne Room is indoor but political, etc.).

## The 5 default buckets

| # | Bucket | Visual frame |
|---|---|---|
| 1 | Indoor | chamber / hall / throne room / vault / library / private study — enclosed architecture, no outdoor cues |
| 2 | Outdoor | gate / square / mountains / ridge / forest / sky / clouds / wind / mist on open ground |
| 3 | Dramatic battle | combat / named spells / casualties / armor / weapon / offensive posture / defensive formations |
| 4 | Political | throne / sovereign / covenant / treaty / negotiation / Social HP / kingdom / empire / theocracy / formal address |
| 5 | Environmental-puzzle | climbing / terrain navigation / natural hazards / tracking trail / magical signature on landscape / extreme environment |

## Disambiguation rule

When two buckets overlap, **pick the bucket that is the dominant visual frame** (the one whose visual cues dominate the gemini prose). The secondary bucket can be noted in the deliverable's Notes section if relevant.

Examples:
- Throne Room scene with combat → **political** (the throne and covenant dominate; combat is incidental).
- Outdoor dragon encounter → **environmental-puzzle** (the dragon "battle" element is incidental; the climb / signature-tracking / thin air dominate).
- Indoor heist with environmental-puzzle (locked vault) → **indoor** (architecture dominates; the vault puzzle is incidental).

## Per-IP positive/negative cues

### Overlord (isekai, dark-comedic)

| Bucket | Positive cues | Negative cues (avoid) |
|---|---|---|
| Indoor | "Council Chamber", "Throne Room", "Inner Sanctum", "Solarium", "private study", "Embassy basement", "Merchant Guild", floating arcane crystals, mahogany, incense | none specific |
| Outdoor | "Carne Village", "E-Rantel gate", "Three-Finger Ridge", "Cloud-Sea Terrace", "open ground", "morning light", "sun" + "cobbles"/"grass" | none specific |
| Dramatic battle | named spells ("Mirror Wall", "Dominate Person", "Lightning"), casualties, "Silver Scripture" mages, "Iron-Mine Ruins" raid, "Sunlight Scripture" | generic combat without named spells |
| Political | "Sovereign's Covenant", "Pontifex Maximus", "High King Ramposa", "Cardinal", "Social HP", "Imperial Auditor", "treaty", "non-aggression pact" | generic dialogue without political stakes |
| Environmental-puzzle | "Three-Finger Ridge", "Platinum Spire", "Absolute Stillness markers", "Silent Step enchantment", "thin air", "Wild Magic anchor", "dragon encounter" | indoor scenes with magic puzzles |

### Star Wars MMO (isekai, claustrophobic espionage)

| Bucket | Positive cues | Negative cues |
|---|---|---|
| Indoor | "station corridor", "datacenter", "cargo bay", "crew quarters", bulkhead, hatch | outdoor desert/space |
| Outdoor | "Tatooine dune sea", "orbit", "open vacuum", "desert plain" | station interior |
| Dramatic battle | blaster fire, lightsaber, ship-to-ship combat, "hold them at the airlock" | political negotiation |
| Political | Senate chamber, Imperial officers, Sith meditation, "Imperial command deck" | generic combat |
| Environmental-puzzle | zero-gravity repair, broken hyperdrive, "unshielded power cables", navigating asteroid belt | any standard encounter |

### ASOIAF (dark political drama)

| Bucket | Positive cues | Negative cues |
|---|---|---|
| Indoor | "throne room", "small council chamber", "Maester's library", "brothel backroom", "dungeon cell" | open battlefields |
| Outdoor | "King's Landing street", "Riverlands forest", "the Wall", "Wolfswood", "frozen lake" | any indoor scene |
| Dramatic battle | named battle ("Blackwater", "Red Wedding"), cavalry charge, trial by combat | political scheming |
| Political | "small council", "Queen Regent", "Hand of the King", "coronation", "trial", "rival house negotiation" | any non-political scene |
| Environmental-puzzle | "beyond the Wall", "Children of the Forest cave", "navigation through snowstorm" | generic encounter |

### DC superheroes (iconic-NPC banter)

| Bucket | Positive cues | Negative cues |
|---|---|---|
| Indoor | "Fortress of Solitude", "Batcave", "Daily Planet newsroom", "LexCorp tower office", "Watchtower", "lead-lined air" | generic city street |
| Outdoor | Metropolis skyline, Gotham alley, "the bridge", "rooftop chase", skyline with sun | any interior |
| Dramatic battle | named superpowers ("heat vision", "kryptonite"), "Earth-shaking impact", casualties | political scheming |
| Political | "White House briefing", "Congressional hearing", "Justice League council", "alien ambassador", "treaty negotiation" | any non-political scene |
| Environmental-puzzle | "Kryptonian artifact puzzle", "dimensional portal", "Orrery of Worlds", "tracking alien tech-signature" | generic encounter |

### Fantasy Spellblade (isekai, dramatic dawn combat)

| Bucket | Positive cues | Negative cues |
|---|---|---|
| Indoor | dungeon room, "obsidian walls", "geometric kill-box", throne hall | outdoor dawn combat |
| Outdoor | "dawn light", "open battlefield", "obsidian walls in ghostly shifting hues" | any indoor scene |
| Dramatic battle | named kill-box spell, "obsidian walls", dawn-light combat, named martial techniques | generic combat |
| Political | lord's court, treaty negotiation, formal petition | any non-political scene |
| Environmental-puzzle | "geometric kill-box", "broken ward-line", "tracking mage-signature on landscape" | generic encounter |

## How to use this taxonomy

1. After identifying a candidate scene (Step 4 of the skill), read the gemini opening prose verbatim.
2. Look for the bucket whose positive cues match the prose.
3. If two buckets both match, apply the disambiguation rule (dominant visual frame).
4. Quote the cue verbatim in the diversity checklist row.
5. If no bucket fits cleanly, the scene is probably not a good candidate (likely mid-action pivot or god-mode exchange) — skip it.