# 2026-08-14 — No-hardcoded-preset issue templates for `worldarchitect.ai`

Player feedback from Hanji Stevens was filed as 6 GitHub issues
([#8901](https://github.com/jleechanorg/worldarchitect.ai/issues/8901) →
[#8906](https://github.com/jleechanorg/worldarchitect.ai/issues/8906)) in
`jleechanorg/worldarchitect.ai`. Each one was reframed per the User Preference
rule added on 2026-08-14: **the engine exposes a primitive, the player/campaign
declares the rules — never ship a hardcoded preset.**

This file preserves the 6 issue bodies as canonical reference. Use them as
templates any time the user asks to file similar feature requests against this
repo. The point is the shape — the framing and the acceptance criteria —
not the specific content.

---

## Common body template (applies to every issue)

Each issue body in this cluster follows the same shape. Reuse it:

```markdown
## Source
<verbatim quote from the player/user, with date and sender>

## Problem
<Why the current state fails — concrete, player-visible>

## Proposed Solution
<Engine primitive → player/campaign declares rule. NEVER the engine ships a preset.>

### Mechanics (when relevant)
<API shape / data model / prompt behavior>

### Surface
<Where this affects the player>

## Scope estimate
<Files, API surface, prompt edits>

## Difficulty
<Small / Small-Medium / Medium / Medium-Large / Large with time estimate>

## Alternatives Considered
<Why we rejected "ship a preset" or similar shortcuts>

## Acceptance Criteria
- [ ] No <hardcoded reference> appears anywhere in <engine module>
- [ ] Player can author a custom <declaration> without code changes
- [ ] Regression test: <declarable scenario>

## Customer Impact
<What unlocks for the player>

## Source Citation
<Email date + sender>
```

---

## Issue #8901 — Declarative attribute schema (player authors any attribute set)

```markdown
[design] Declarative attribute schema — player-author any attribute set (no hardcoded presets)
```

**Key framing points in the body:**

- WorldArchitect.AI hardcodes 6 D&D attributes (STR/DEX/CON/INT/WIS/CHA).
  The fix is *not* ship more presets — it's engine-neutral attribute lookup.
- Engine has zero hardcoded attribute knowledge. Player declares:
  ```yaml
  attributes:
    - key: reiatsu
      label: "Reiatsu"
      description: "Spiritual pressure powering Kidō and melee amplification."
      category: spiritual
      min: 1
      max: 30
  ```
- Schema is consumed by the dice engine (`attribute_modifier(key)` by lookup),
  prompt layer (loop over schema, not fixed list), character sheet UI, NPC
  stat blocks (same key), and migration (`empty schema → fall back to 6-default`).
- Difficulty: **Large** (2-3 wks) — the schema is the new load-bearing concept.
- Acceptance criteria explicitly include: *"No `STR` / `DEX` / `CON` / `INT` /
  `WIS` / `CHA` (or any specific attribute name) appears anywhere in
  `mvp_site/`, `mvp_site/prompts/`, or character/NPC defaults."*

---

## Issue #8902 — Dice engine: `contested_roll` + multi-attribute sum

**Key framing points:**

- New primitive: `combat.contested_roll(side_a, side_b, attribute_keys_a, attribute_keys_b)`.
- Multi-attribute sum: `attribute_keys=["technique", "speed"]` adds both.
- Schema-driven: keys come from player's schema, no hardcoded names.
- Tiebreak rule is declared per-campaign (default: random with visible flip).
- Always record `actor`/`subject`/`target` (closes open bug #8873).

Acceptance criteria:
- Any campaign, regardless of declared schema, can run a contested roll.
- Schema with only `reiatsu` and `speed` (no `strength`) runs cleanly.
- Tiebreak rule is declared per-campaign, not hardcoded.

Difficulty: **Medium** — additive on top of existing dice infra.

---

## Issue #8903 — Schema-aware NPC stat blocks

**Key framing points:**

- Stat blocks are player-authored `(attribute_key → value)` maps.
- Engine treats them as opaque; never asserts specific keys.
- Roll attribution records `actor: "npc_*"` + explicit `target` (per #8873).
- UI renders the stat block scoped to whatever schema the campaign uses —
  never renders `STR: 14` for a Bleach NPC.

Acceptance criteria:
- An NPC stat block can be authored in any custom schema.
- Same engine runs Bleach + Cyberpunk NPCs without code changes.

Difficulty: **Medium** — most of the work parallel to (and enabled by) #8901.

---

## Issue #8904 — Outcome-tier labels: player-declared bands

**Key framing points:**

- Hanji's specific band table (1-3 negligible / 4-5 slight / 6-9 clean /
  10-14 major / 15+ overwhelming) ships as an **editable default**, NOT
  a hardcoded table.
- Player can ship totally different bands ("polite decline / mild rebuff /
  clear refusal / sharp dismissal / walk away" for slice-of-life).
  Engine never asserts bands exist; just maps margin → label.
- Schema:
  ```yaml
  roll_resolution:
    mode: "tier_bands"   # or "binary" to disable
    bands:
      - { min: 1,  max: 3,  label: "polite decline", narrative_hint: "..." }
      # ...
    tiebreak: "narrative_parity"   # or "side_a" / "side_b" / "reroll"
  ```

Acceptance criteria:
- Tier band mapping is read from campaign config, not hardcoded table.
- A campaign can ship a totally different tier band set without engine changes.
- Empty/missing campaign tier config falls back to the default suggestion.

Difficulty: **Small-Medium** (1-2 days) — margin already exists in engine.

---

## Issue #8905 — Two-sided combat: stabilize CombatAgent + player-overridable defaults

This is the **umbrella issue** in the cluster, and the only one that
inherits existing open bugs. It cross-references:

| Type | # | State | Title (short) |
|---|---|---|---|
| Issue | #8022 | OPEN (2026-06-28) | NPC turns not taken + HP not shown |
| Issue | #8490 | OPEN (2026-07-21) | Trivial/challenging directive not persisted |
| Issue | #8860 | OPEN (2026-08-13) | CombatAgent cache-prefix instability |
| Issue | #8873 | OPEN (2026-08-14) | dice_rolls no actor/subject marker |
| PR | #8023 | CLOSED/MERGED (2026-07-10) | Intent classifier anchors (v1) |
| PR | #8319 | OPEN (2026-08-11) | Re-spin of #8023, add 17 anchors |
| PR | #8491 | OPEN (2026-08-14) | Combat-scope classifier |
| PR | #8559 | OPEN (2026-08-14) | Generic tabletop hard-mode |
| PR | #8668 | CLOSED/MERGED (2026-08-01) | Bootstrap gap where combat_state never populates |

**Key framing points:**

- Two interlocking problems: routing layer (CombatAgent not firing — 7-week
  trail) AND behavioral layer (engine doesn't have "NPC acts first" as a
  declared rule).
- Three-phase solution: (1) stabilize route via in-flight work, (2) expose
  rules as player-declared, (3) surface defense rolls to the player.
- Phase 2 axes player-overrides:
  ```yaml
  combat_rules:
    who_acts_first: "npc_first"   # or "pc_first" / "initiative_roll" / "simultaneous"
    npc_behavior:
      default_engagement: "aggressive"  # or "defensive" / "reactive"
      allows_surrender: true
      retreats_when: "hp_below_25_percent"
  ```
- Engine no longer hardcodes any of these — defaults exist as editable config.

Difficulty: **Medium-Large** (1-2 weeks assuming open PRs land).

---

## Issue #8906 — Player-authored story cards

**Key framing points:**

- Cards are `(key, title, body, scope, applies_when, source, priority, author)`.
  No fixed `type` enums.
- Engine exposes three scope slots + free-form scope string.
- Author-declared priority int. Player story cards rank below God Mode
  directives; player can move them up with explicit confirmation.
- All cards injected as numbered items under "Active Story Cards."
- Surface: campaign wizard, character sheet, scene sidebar.
  ~20 cards soft cap.

Acceptance criteria:
- Player can author a card with a free-form name and body.
- No "card type" enums in engine — engine treats cards as opaque.
- A card titled "Phobia: fire" with arbitrary key `avoid_fire` works
  identically to a card titled "Tone: casual."

Difficulty: **Medium-Large** (1 sprint).

---

## Why this template set matters for future sessions

Whenever the user asks "let's file GH issues for [player feedback about a
game mechanic]" against `worldarchitect.ai`:

1. Investigate existing open/closed issues + PRs first (REST search, not
   GraphQL — see `gh-rate-limit-resilience`).
2. Cross-reference the cluster in any new umbrella issue (#8905 is the
   reference example).
3. Reframe every concrete example in the feedback as "engine primitive +
   player/campaign declares the rule" — never ship a preset.
4. Use `--input /tmp/issue_<n>.json` for the `gh api POST /repos/.../issues`
   call (NOT `-f labels=...` — see the gh-rate-limit-resilience pitfall).
5. Difficulty ratings must be defended with "X files / Y API surface / Z
   prompt rewrites" — estimates, not vibes.
6. Post the summary back to the originating thread with the difficulty
   column + cross-references + verdict (per
   `## slack-reply-inherit-thread-ts` and `slack-channel-routing-policy`).

The 6 issue bodies filed on 2026-08-14 are the canonical proof of all 6
points above. Keep this file as the reference; if a future session needs
to file similar issues, copy the shape, not just the wording.
