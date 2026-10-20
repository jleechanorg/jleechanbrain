# Session 2026-08-19 — Demon Queen Reincarnated ("Ash of Aetheria")

## Thread

- Slack: `C0AUXSVFSA2/1786951500.855119` (the same thread as the 2026-08-17 hybrid isekai pitch — this is the v2 design the user asked for)
- User: Jeffrey Lee-Chan (`jleechan`, `U09GH5BR3QU`)
- Three prior assistant turns hit provider timeouts (240s × 3 + 752s). User said "keep going" twice before this turn resumed. Triggered the new HARD-GATE exception rule.

## Files shipped

| File | Path | Size | Lines |
|---|---|---|---|
| Full bible | `~/llm_wiki/wiki/sources/demon-queen-reincarnated.md` | 41,782 chars | 486 |
| Slim paste-ready | `~/llm_wiki/wiki/sources/demon-queen-reincarnated-slim.md` | 15,977 chars | 156 |

Both files staged; **no public-wiki push, no commit, no PR** per User Pref #3.

## Concept locked (defaults picked after 2× "keep going" — user can rename)

- **Working title:** Ash of Aetheria
- **Protagonist:** Ash (cover name) / Astheria, the Ash-Crowned Queen (true name)
- **Age:** 12 (Academy student)
- **Class:** Gestalt Wizard (Bladesinger) 12 / Sorcerer (Aberrant Mind) 12; true ceiling L25 (old magic) gated behind Veil + Guilt Lock
- **Starting scene:** "The Crystal That Knew Her Name" (Option A — magic-school arc fits the Mushoku Tensei cadence the user asked for)
- **3-way cold war:** Imperial Court (humans want her dead) / Abyssal Court (demons want her back on throne) / The Academy (Headmistress Vey wants the truth)
- **Companions:** Captain Reyna (mentor, doesn't know but suspects), Liriel (demon great-great-granddaughter envoy, doesn't know), Cassian (Hero-King's great-grandson, doesn't know)

## Synthesis sources (verified, sampled)

| Source bible | Pattern borrowed |
|---|---|
| `veleria-iseki-reborn` | Hidden-apex + reveal-is-local-not-global + reincarnation-who-refuses-the-crown |
| `aristocrat-reborn-v2` (Sylphina) | Margrave's-daughter + mana-veil spoofing + two-mentor babysitter dynamic |
| `nocticula-general-hidden-power` | Half-demon hunted by both sides + Frieren Scale (Mana Veil + Demonic Overcasting + Subtle Weaving) |
| `iseki-v1` (Renjiro) | Demon lord reincarnation, morally grey, child's-life-as-hostage reason for losing |
| `bumpkin-swordsman / Vaelen` | L12 mortal ceiling as structural fact + 3-way cold war + grounded grimdark |

## Mechanics introduced (new to the user's bible library)

- **The Veil** (passive, L1) — Mana Veil Mastery. Detection sees "L4 student" unless caster is L15+.
- **The Guilt Lock** (active, L5+) — Wisdom save DC 10+spell level. Failure = flashback ends turn. Success = narrative beat.
- **Subtle Bladesong** (Bladesinger 6 substitution) — Psionically silent weapon attacks.
- **Ash-Crowned Memory** (L17 unlock, Veil-drop) — Once/long rest, cast a first-life spell. L9 = Mourning of the Ash-Crowned (rebuilds what was destroyed). Veil drops for everyone within 1 mile.
- **Aether Escalation** (L6 unlock) — Cast one tier higher for 1 Veil Point. Earned by lying successfully about identity.
- **Quad-Pillar stats** (replaces Mortal Anchor): Paranoia, Hidden Apex, Guilt, Witnesses — all independent.
- **Demon-vision mechanic** — demons see soul silhouettes; Veil-thinned Ash shows crown-shaped silver burn at temples.

## Rank tables (11 / 8 / 8)

- **Imperial Nobility:** Esquire → Landed Knight → Baron → Viscount → Count → Marquis → Duke → Archduke → King (reserved) → Emperor (Empress Cassia XI reigning) → World Emperor (mythic, vacant 800y, last holder was Astheria's father)
- **Martial:** Squire → Knight-Errant → Knight of the Realm → Knight Commander → Paladin → High Paladin → Holy Marshal → Sword Saint (mythic, one alive)
- **Mage:** Apprentice → Adept → Magister → Archmagister → High Magus → Imperial Magus → Veilwarden (mythic, 3 alive) → Archmage of the Hidden Tower (mythic, last one was Astheria's teacher)

## Slim-pass iteration log

| Pass | Char count | Δ | Section cut |
|---|---|---|---|
| Initial slim | 17,001 | — | (full prose dump, first pass) |
| Pass 1 | 16,372 | -629 | Rank table prose → arrow chains |
| Pass 2 | 16,075 | -297 | Section 1 + Section 3 verbosity |
| Pass 3 | 16,032 | -43 | NPC descriptions + family table trailing note |
| Pass 4 | 15,977 | -55 | Section 9 stage directions + Liriel/Cassian trimming |
| **Final** | **15,977** | **-1,024 total** | Under 16k cap with 23 chars headroom |

**Critical tooling note:** used
`awk 'BEGIN{total=0}{total+=length($0)+1}END{print total}' <slim_file>` for char
counting, NOT `wc -c`. `wc -c` counts bytes and over-reports on multi-byte
UTF-8 (em-dashes, curly quotes) which appear in every bible. The skill's
slim-pass playbook section now documents this.

## What was NOT done (and why)

- **/research + /web-advice** — skipped after timeouts; only tone references (Mushoku Tensei / Frieren / Witcher) appear in the bible. User can request the actual trope-mining pass.
- **No public-wiki push** — User Pref #3 default is staging-only.
- **No live WA wizard test** — User Pref #12 canon-check would require the user to `/repro` it themselves in real Chrome. The bible has a canon-correction notes section ready for that round.

## User-feedback signals to carry forward

- User said "keep going" twice after timeouts. **HARD-GATE exception is now codified** in the SKILL.md Workflow section.
- User's explicit thread-direction list (Mushoku Tensei cadence / 12yo girl / reincarnation Demon Queen / Bladesinger + Aberrant Mind / demons sentient / today's demon royalty descended from her / old magic stronger) was a sufficient design source — no clarification menu was needed.
