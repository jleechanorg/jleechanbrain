---
name: campaign-creation
version: 1.0.0
description: "Design self-contained campaign prompts for WorldArchitect.AI's Custom Campaign wizard. The output is an LLM-paste-ready markdown bible with ZERO external references — no wiki links, no Google Doc IDs, no code references, no cross-doc jumps."
license: MIT
type: llm-prompt-generator
metadata:
  hermes:
    tags:
      - rpg
      - worldarchitect
      - campaign-creation
      - 5e
      - solo-rpg
      - self-contained
      - paste-ready
    related_skills:
      - campaign-design-rpg-bible
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash
changelog:
  - 1.0.0 (2026-08-22): Initial creation. Self-contained-prompt rule added per operator OOB ("Make sure the campaign is self contained it can't reference material outside of it. We can make it bigger. Also it shouldn't reference code or anything. It's a prompt to the LLM to create a campaign."). Built on campaign-design-rpg-bible v1.7.0 conventions (9 sections + §10 Continuity Hooks, no endings, Quad-Pillar mechanics, Per-Die-Roll XP, personality MBTI hinge, custom subclasses); rejects ALL cross-doc pointers and codeblock-style references. Working example: Quiet War — The Sword Instructor's Hollow Crown (Alexiel Arcanus).
---

## When to Use

Use this skill when the user asks for a campaign creation **prompt** to paste into the **WorldArchitect.AI Custom Campaign wizard**:

- "Make a campaign for [IP / character / setting]"
- "Design a campaign with [mechanic] at [level], age [N]"
- "Campaign prompt for [scenario]"
- "Self-contained campaign with [constraints]"

**The output is a paste-ready text.** It is the prompt the user drops into the Custom Campaign wizard's "Campaign description prompt" field. The WorldArchitect.AI backend instantiates an AI DM that uses this prompt as its campaign specification.

**Do NOT use this skill for:**
- Editing an existing campaign bible mid-flight (use campaign-design-rpg-bible's iteration loop)
- Wizard-paste handoff from a wiki source bible (use campaign-design-rpg-bible's slim-pass workflow)
- Generic RPG worldbuilding without a target system (use brainstorming)
- One-shot TTRPG sessions or pure creative writing

## v1.0.0 — Self-Contained Prompt Rule (added 2026-08-22)

The output of this skill is an **LLM-facing prompt**, not a designer-facing reference document. Therefore it MUST be:

1. **Self-contained.** The AI DM that reads this prompt must NOT need to fetch any external resource. No wiki links, no Google Doc IDs, no GitHub URLs, no "see §X" cross-doc jumps, no "consult the Assiah wiki for full lore" pointers. If the prompt mentions a fact, the fact must be stated IN the prompt.
2. **No code references.** No Python class names, no module paths, no Flask route strings, no "system" references to the WorldArchitect.AI backend. The prompt names mechanics by player-facing vocabulary (Hidden Apex, Mirror Magic Cascade, Aura suppression, Arcanus-Form).
3. **No external ID references.** No `[CHAR:ID]` lookup calls, no cross-document graph IDs, no campaign-table keys. The character is described by name + role + capabilities, not by database identifier.
4. **Sized for the user.** Default 2,500-4,000 words. Smaller (1,500-2,500) for IP-anchored bibles with simpler mechanics. Larger (4,000-6,000) if the user says "bigger is fine" or "we can make it bigger." The output is one big markdown document the wizard reads in full.

The **hard reason** for this rule: the WorldArchitect.AI AI DM, after parsing the prompt, does NOT execute follow-up fetch calls against external links. An external reference becomes a black box the AI fills with invention. Self-contained prompts are the only ones that produce canon-faithful gameplay on Acts II-V.

## Workflow

### Phase 1 — Intake (single message to user)

Ask the user, in ONE message, for:
1. **Protagonist identity** (name, class chassis, level, age, setting)
2. **Tone/genre** (grimdark / cozy / political / romantic / heroic — pick one or two)
3. **Canonical anchor** (if any — TV show, novel, original setting, prior bible)
4. **Campaign length** (Acts I-IV / I-VI / open-ended)
5. **PC motivation** (one or two sentences)
6. **Optional:** "any elements you want me NOT to include" or "any specific game-mechanic constraints"

Do NOT ask user about section ordering, NPC lists, or game-rule mechanics. Default skill choices already cover these.

### Phase 2 — Draft (no questions, no menus)

Produce the **single self-contained paste** with the **Locked 10-Section + Canon-Assumptions shape** below. Word count target 2,500-4,000 words unless user overrides.

### Phase 3 — Self-Containment Audit (run before delivery)

MUST pass all five:
- [ ] **External URL test:** `grep -E "https?://" output.md` returns 0 lines. No URL anywhere.
- [ ] **External ID test:** No `Drive doc ID`, no `wiki/*` path, no `github.com/jleechanorg/*` references.
- [ ] **Cross-doc backref test:** No `See §X`, no "as noted in §Y", no "see Hook 1 below" shorthand. (Cross-section references within the same file ARE allowed, phrased as "see the §3 Aura rule" — that's within-document. Cross-DOCUMENT references are forbidden.)
- [ ] **Code reference test:** No Python class names, no Flask route strings, no SQL/JSON path, no File path / `/Users/...` paths. The prompt names mechanics by player-facing vocabulary only.
- [ ] **Inlining test:** For every fact named, the fact IS stated in the prompt. Run `grep "<fact>" output.md` to verify each canon assumption block lookup.

If any fails, patch the output before delivery. **The artifact is paste-ready or it doesn't ship.**

### Phase 4 — Deliver

Output one of:
- A path to the markdown file (default to `~/llm_wiki/wiki/sources/<slug>.md`), OR
- A Google Doc (`gog docs create "Title" --parent <folder-id> --file <path> --no-input --json` + `gog docs write <id> --replace --markdown`), OR
- Both (per operator's "3-place sync" preference)

Suggest 3-5 specific changelogs the user can test in the live wizard (e.g., "test session 0 with starting scene option A vs B vs C").

## Locked 10-Section + Canon-Assumptions Shape

The output document MUST contain exactly these sections in this order:

| § | Title | Required content |
|---|---|---|
| (top) | **Canon assumptions** | Inlined lineage, family status, source hierarchy. Lockstate rules. The "correction" rules the AI DM must obey. NO external doc refs. |
| §1 | The Setting + Starting State | Where/when the protagonist wakes up. The immediate inciting incident. Tone rules. Magic caps. Aura rules. |
| §2 | Personality | MBTI hinge + 3 inner-monologue seeds + behavior tags. The protagonist's voice for the AI DM to mimic. |
| §3 | Class + Subclass | Ability scores, HP/AC/DC. Class chassis (base + custom subclass). Spell slots. Combat round structure. Active-passive auras and their exact mechanics. |
| §4 | Assets + Retinue | Starting gold. Named key items (5-8). 3 starting NPCs. Council / loyalty matrix if applicable. Quest hooks surfaced at session 0. |
| §5 | Family / Cold War | Full lineage tree. Pretenders. Family pressure rules. "Never X" canonical corrections. |
| §6 | Factions | 5-12 named blocs with stance/distance/notes. Imperial Inquisition mechanics if applicable. |
| §7 | Mechanical Systems | Quad-Pillar stats (the "campaign health meter"). Per-die-roll XP formula. Magic caps. World-loyalty mechanics. Hidden Apex / awakening mechanic if applicable. |
| §8 | Gazetteer | Each named place: distance, atmospheric detail, key NPCs that are location-anchored, items-only-locations. |
| §9 | Starting Scene | 3-option carousel + **Freeform** 4th option. Mechanical readout at scene start. The 4th option must exist; never pre-decide an option-out. |
| §10 | **Continuity Hooks** (No Canonical Endings) | 5-8 unresolved threads. One per Act the AI DM can pick up. **NEVER** an Ending Determinator / Canonical Ending / Final Verdict. |

After §10:

| Section | Title | Required content |
|---|---|---|
| (tail) | **Setup Notes (For the AI DM)** | Reading order. Hard Rules (5-10 one-liners). Anti-fabrication checklist. Voice rules. Naming style. Self-contained declaration. |

Each section's word budget (default 3,000-word total): §0 350 / §1 350 / §2 200 / §3 350 / §4 300 / §5 300 / §6 250 / §7 300 / §8 200 / §9 200 / §10 350 / Setup Notes 300. Adjust in proportion for the user's stated length.

## Hard Rules (applied across every campaign in this skill)

These rules are inherited from `campaign-design-rpg-bible` v1.7.0 user-locked preferences and ARE NOT optional:

### Rule 1 — No endings (HARD RULE, locked 2026-08-17)

No "Ending Determinator" matrix, no "Canonical Ending" section, no "Final Verdict" binary, no pre-decided outcome. Replace any ending-shaped content with **Continuity Hooks** in §10.

### Rule 2 — Player agency over railroading

Every §9 ends with a 3-option carousel plus a **Freeform** slot. Never force the player into "Option A vs Option B" without an escape hatch.

### Rule 3 — Hidden Apex + (Mortal Anchor: OPTIONAL, not default) + Ascension Track

- **Hidden Apex** is a state-based advantage that scales with PC state, not raw power.
- **Mortal Anchor (ditchbond)**: OPTIONAL. As of 2026-08-17 the user has removed this from the default bible skeleton. The Quad-Pillar Paranoia stat carries the isolation tension without a dedicated anchor NPC. Confirm with user before adding.
- **Ascension Track (NOT death clock):** Reputation / recognized-sovereignty tiers. L25 Divine Ascension is OPTIONAL endgame content, gated behind L20-L25 progression, not a default unlock.

### Rule 4 — Lore anchor (TV-or-book or original-world)

When designing for a TV/novel adaptation, anchor starting state to a specific canonical moment. Where the source cut off or diverged, note "[Book fallback]". **Never invent TV canon that doesn't exist.** For original-world bibles, use the inlined Canon Assumptions block as the source of truth.

### Rule 5 — Naming style

Mechanically named traits get cool names ("DragonsBond", "Silver Drake Sig", "First Song", "Last Light", "Nullwave", "Mordan trap"). NEVER "Fire Resistance +2" phrasing for signature abilities. NEVER "Plan B Option A" — use "the Imperial Path" or "the Maternal Path."

### Rule 6 — Vivid sensory prose

Setting descriptions open with smell, weather, light, sound — not "this is a tavern." A single sensory sentence per §1's starting state.

### Rule 7 — Per-die-roll XP (locked 2026-08-13)

`XP = 0.34 × (next_level_threshold − current_level_threshold)` per successful or failed die roll. NO XP during god mode or time-skip turns. Worked example: L2→L3 distance 600 → 204 XP per die.

### Rule 8 — File naming convention

Omit date prefix from any wiki filename. Use `quiet-war.md`, not `2026-08-22-quiet-war.md`. Internal revision_log entry can carry date.

### Rule 9 — CANON-PRIORITY block (when applicable)

For IP-anchored campaigns, the §0 "Canon assumptions" block MUST name the authoritative source medium: *"The HotD TV show is the single source of truth; book is fallback only."* Without this, AI DMs silently substitute alternate-medium canon.

### Rule 10 — No ending-shaped sections, ever

Reinforces Rule 1. Refuse to write an "Endings Matrix" or "Canonical Ending" section. The bible is **the system the AI DM runs**, not **the story the player reads**. Replace any pre-decided outcome with a Continuity Hook.

### Rule 11 — v1.0 NEW: Self-contained, no code refs

The output is an LLM-facing prompt. No external URLs, no Drive doc IDs, no wiki cross-refs, no code module names, no Flask route strings. The mechanics are described in player-facing vocabulary ("Hidden Apex: 5 = dormant," "Mirror Magic Cascade," "Arcanus-Form") — never in implementation terms ("track this in `world_logic.py:5822`").

### Rule 12 — v1.0 NEW: Canon corrections are inlined, not external

Any locked canon rule (e.g., "Sariel is the Empress, not the Empress's daughter") MUST be stated IN the §0 canon-assumptions block of the output. It cannot be referenced via "see canon-correction file at <path>." The AI DM has no fetch.

## Anti-patterns (skill-level checklist)

- ❌ Don't write an Ending Determinator section.
- ❌ Don't put code references in the §0 Canon Assumptions block.
- ❌ Don't abbreviate sections with "see §3 below" shorthand that risks becoming a fetch in the parsed output.
- ❌ Don't prepend frontmatter YAML with links or IDs.
- ❌ Don't reference "the wiki" — the AI DM in the wizard has no wiki access.
- ❌ Don't link to Google Drive documents — Drive docs require auth the AI DM doesn't have.
- ❌ Don't invent Assiah/HotD/Elden Ring specific lore that contradicts source.
- ❌ Don't use abbreviations like "MaA" or "SAC" that the AI DM might expand differently across runs.

## Working example

The Quiet War — The Sword Instructor's Hollow Crown (Alexiel Arcanus) is the v1.0 reference implementation:
- **3,093 plain words** in `~/llm_wiki/wiki/sources/quiet-war-slim.md`
- **2,837 plain words** in the Drive doc `11oBduyCd6HsydnWi6YwxDHrwDm4L1VQFCGe0hD8mp04` (Drive strips ~250 words of YAML/HTML comments)
- **Zero** external URLs, **zero** cross-doc refs, **zero** code references.
- §0 canon-assumptions block inlines lineage + family status + source hierarchy.
- §10 still has 8 Continuity Hooks, no Canonical Ending.
- §9 still ends with Freeform as the 4th option.
- Setup Notes block ends with the "Self-contained: this bible has zero external references" declaration.

This is the empirical shape every campaign-creation artifact must meet.

## See also

- **Sibling skill:** `campaign-design-rpg-bible` — full design-time bible authoring workflow including slim-pass iteration, 3-place sync (wiki/Drive/doc-pageless), canon-correction against TV-show episode lists, and 18 user-locked preferences. Use that when the user wants the *rich drafting document* (multi-KB, full IP-canon detailing). Use THIS skill when the user wants the *paste-ready prompt* that goes into the WorldArchitect.AI Custom Campaign wizard.
- **Test/verify artifact:** every campaign-creation output MUST pass the Phase 3 Self-Containment Audit. The audit checklist is in §Phase 3 above.
- **WorldArchitect.AI test for live wizard conformance:** the user runs `/repro` or the equivalent against the live wizard and reports any AI-DM-side canon errors. Fix in one push; do not argue.

## Revision marker

`CAMPAIGN_CREATION_V1` (2026-08-22).
