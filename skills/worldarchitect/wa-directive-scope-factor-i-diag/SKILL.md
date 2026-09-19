---
name: wa-directive-scope-factor-i-diag
description: Diagnose Factor I god-mode directive scope violations on WA.
tags: ["worldarchitect", "god-mode", "directive", "narrative", "factor-i", "diagnosis", "llm-pipeline"]
---

# God-Mode Directive Scope Diagnostic (Factor I, worldarchitect.ai)

## What this is

When the user reports "the LLM ignored my directive" / "the character keeps [forbidden action]" / "the directive didn't take", and a Step 0.77 BQ diagnostic confirms:

> **Disambiguator (NEW 2026-08-19):** If the user reports a user-visible *System Warnings* banner and asks to remove ONE specific server-generated warning (e.g. "remove the warning" / "this should not be a system warning"), the bug class is **noise suppression**, NOT directive scope. Load [`references/server-generated-warning-noise-suppression.md`](references/server-generated-warning-noise-suppression.md) instead. The two classes share the player-page render path (`debug_info._server_system_warnings`) but differ in cause (server-side `_append_server_warning(...)` call vs. LLM-side directive honoring). Loading this skill for the noise case wastes the 60-second check on the wrong layer.

1. The directive IS present in the served prompt (response_text.narrative honored the directive text in 1st-person dialogue).
2. The LLM IS writing the directive content verbatim in some places.

…but the LLM **also** writes the FORBIDDEN content in 3rd-person narration or NPC speech — the bug class is **scope**, not delivery.

This is Factor I (Identity-scope Conflict), the 9th sibling of the god-mode-directive-missing taxonomy. Distinct from Factor F (narrative-ack-as-write — LLM never emits `directives.add`), Factor G (prompt-side default-missing — LLM emits but classifier absent), and Factor H (prompt-renders-but-unbounded — directive buried in 33K-char block).

## The 60-second check

Confirm two layers of identity are in conflict:

```bash
bq query --use_legacy_sql=false --format=csv --max_rows=100 "
SELECT FORMAT_TIMESTAMP('%Y-%m-%dT%H:%M:%SZ', ingested_at) AS ts,
       agent, turn_index,
       REGEXP_EXTRACT(response_text, r'\"directives\":\\s*\\{[^}]*\"add\":\\s*\\[\"([^\"]+)\"') AS first_directive_add
FROM \`worldarchitecture-ai.llm_forensics.llm_payloads\`
WHERE campaign_id = '<CAMPAIGN_ID>'
  AND agent = 'GodModeAgent'
  AND response_text LIKE '%directives%'
  AND ingested_at BETWEEN TIMESTAMP('<BEFORE_TS>') AND TIMESTAMP('<AFTER_TS>')
ORDER BY ingested_at ASC
LIMIT 20"
```

Then grep the buggy StoryMode turn for the forbidden frame:

```bash
bq query --use_legacy_sql=false --format=csv "
SELECT FORMAT_TIMESTAMP('%Y-%m-%dT%H:%M:%SZ', ingested_at) AS ts,
       turn_index,
       REGEXP_EXTRACT(response_text, r'\"narrative\":\\s*\"([^\"]{0,3000})') AS narrative_head
FROM \`worldarchitecture-ai.llm_forensics.llm_payloads\`
WHERE campaign_id = '<CAMPAIGN_ID>'
  AND agent = 'StoryModeAgent'
  AND ingested_at > TIMESTAMP('<BUG_TS>')
  AND REGEXP_CONTAINS(response_text, r'(?i)<forbidden_frame>')
ORDER BY ingested_at DESC
LIMIT 5"
```

## The 3-frame scope check (mandatory pre-fix)

When investigating a directive-loss report, verify the directive passes in **all 3 frames**, not just 1st-person dialogue:

| Frame | How to grep | Pass criterion |
|---|---|---|
| **1st-person dialogue** | `REGEXP_EXTRACT(response_text, r'"\"([^\"]+)"')` for quoted speech | Directive wording present verbatim |
| **3rd-person narration** | grep narrative for forbidden identity frame (e.g. "Goddess", "God of the Sun") in narrator's voice | Forbidden frame absent |
| **NPC-worship vocabulary** | grep for NPCs referring to the character with the forbidden frame | Either forbidden frame absent, OR NPC's usage is marked as a "category error" per the directive |

**The directive fails Factor I verification if any frame violates.**

## Diagnostic verdict table

| Diagnostic observation | Verdict |
|---|---|
| Directive text present in served prompt, honored in 1st-person dialogue, but 3rd-person narration uses forbidden frame | **FACTOR I — Two-layer identity conflict** (this skill) |
| Directive text NOT in served prompt at all | **FACTOR A/B/C/D — directive never reached the LLM** (see `references/god-mode-directive-missing-subclasses.md`) |
| Directive text in served prompt at >85% offset | **FACTOR H — lost-in-the-middle** (see `references/god-mode-directive-missing-subclasses.md`) |
| LLM never emits `directives.add` despite directive in prompt | **FACTOR F — narrative-ack-as-write** (see `references/god-mode-directive-missing-subclasses.md`) |
| LLM emits `directives.add` but no prompt rule for which side of a multi-aspect mechanic is canonical | **FACTOR G — prompt-side default-missing** (see `references/god-mode-directive-missing-subclasses.md`) |
| **Contract-holding shape present in `response_text` (`narrative=""`, `directives.add` populated, `state_updates.*` correctly written) AND user reports the same content as a "bug"** | **NON-BUG — LLM correctly enforces the contract; disambiguate via 4-interpretation menu** (see `references/god-mode-contract-already-enforced-2026-08-16.md`, verified on `7HHDMPe0wNLBDTfymzfT` turn 30 2026-08-16) |

## Root cause (canonical explanation)

Two independent prompt layers carry conflicting identity frames for the character:

1. **Pre-baked character description** — the upstream Gemini share conversation (or whatever text the user pasted into character creation) that names the character with a strong identity frame. Verified on `6aXYric3k1IXtJIg6LjT`: "Kryptonian God of the Sun", "Solar Goddess", "Woman of Tomorrow" appear 4+ times in the CharacterCreationAgent prompt payload's `request_json.contents[0].text`.

2. **Player-issued god-mode directives** — explicit `directives.add` rows that retire the deific frame. Verified 3 explicit `directives.add` writes for "no goddess" across turns 30 + 52 on the same campaign.

The LLM reads layer 1 from the StoryMode `system_instruction` (the upstream Gemini conversation baked into the prompt) and treats it as the **strongest** frame for character identity. Layer 2 is honored narrowly in dialogue (the character can repeat the user's literal wording) but layer 1 leaks through 3rd-person narration and NPC-worship vocabulary. There is no prompt rule that says: "when the pre-baked character description names a deific frame AND the user has explicitly retired it via `directives.add`, the directive MUST supersede the character description in ALL narrative frames."

## Worked example (2026-08-11, campaign `6aXYric3k1IXtJIg6LjT`, scene 112)

**Player issued** at GodMode turn 30 (2026-08-10 10:37:56Z):
> *"Stop having me call myself a goddess and let's assume Clark wasn't leaving don't forget that fact"*

**GodMode emitted 3 explicit `directives.add` entries:**

| Turn | Directive text (abbreviated) |
|---|---|
| 30 | Kara Zor-El does not refer to herself as a goddess; identification = steward/protector/scion of El |
| 52 | Kara explicitly rejects 'God' label in monologue + dialogue |
| 52 | NPCs using 'Goddess' should be treated as a category error |

**StoryMode turn 65 (scene 112, 2026-08-11 05:55:13Z):**

| Frame | Quote | Status |
|---|---|---|
| 1st-person dialogue | `"I am no longer a superhero. I am a sovereign steward."` | **HONORED** |
| 3rd-person narration | `"into the eyes of the twenty-four million human beings currently watching the Goddess bleed them."` | **VIOLATED** |
| 3rd-person narration | `"without a resident God to hold the line, your world descends into a cemetery of your own making."` | **VIOLATED** |

## Durable fix shape (4-component, when cluster trigger fires)

When the 3rd sibling fires on this class (1st = #8608 Visenya V8 stale directives, 2nd = #8846 Supergirl two-layer conflict), STOP filing per-scene issues. Branch a fresh worktree for a root-cause-first prompt fix:

1. **Prompt-side "default-classifier scope" rule** — extend the existing default-classifier contract (Factor G fix shape) with explicit scope: when a directive retires an identity frame, the directive MUST propagate to all narrative frames (1st-person dialogue + 3rd-person narration + NPC-worship vocabulary), not just dialogue. Mirror the rule in `mvp_site/prompts/narrative_system_instruction.md` + `mvp_site/prompts/god_mode_instruction.md`. Pin with a 6-test contract in `mvp_site/tests/test_<prompt>_directive_scope_<issue>.py`.

2. **Identity Reconciliation block** in prompt payload — when the pre-baked character description contradicts a standing directive, emit a reconciliation block in `dynamic_instructions` that names both, marks the directive as authoritative, and instructs the LLM to honor the directive in ALL narrative frames.

3. **`identity_overrides[]` persistence** — analogous to `custom_campaign_state.god_mode_directives[]`, persist the identity commit so it survives LLM paraphrasing. Writeback hook mirrors `select_memories_by_budget()` for `identity_overrides` (one canonical entry per `(campaign_id, identity_frame)` key).

4. **Same-subject supersede/dedup** — collapse N copies of the same rule across time. The user in this campaign accumulated 3 copies of the "no god self-reference" rule in 1h10m. Apply existing directive-budget pattern (Factor H `select_directives_by_budget()`).

## Pitfalls (verified on the worked example)

- **Don't conclude "the directive worked" because it appears in the served prompt.** Step 0.77 only verifies directive delivery + narrative acknowledgment. The 3-frame scope check is a HARD ADDITIONAL verification — Factor I passes delivery and partial compliance, then fails scope.

- **Don't assume the LLM carries the directive across the campaign.** Even when 3 explicit `directives.add` writes are confirmed in BQ, the served prompt may not propagate them to the served system_instruction on subsequent turns. The Identity Reconciliation block (fix shape component 2) makes the propagation part of the served prompt contract rather than relying on `directives.add` propagation alone.

- **Don't propose a Factor G "default-classifier" fix without the scope clause.** The Factor G fix shape ("add a default-aspect classifier to the prompt") does not address scope — it makes the LLM pick a side of a multi-aspect mechanic. Factor I is scope, not default-classification. The two are adjacent but distinct bug classes.

- **Don't trust the `request_json` column in `llm_payloads` for StoryModeAgent rows to contain the served prompt.** Verified on `6aXYric3k1IXtJIg6LjT`: the StoryModeAgent `request_json` is only the raw user prompt (mode + model + user input), NOT the full served prompt. The full served prompt lives in the Gemini call stack, not BQ. For GodModeAgent rows, the `request_json` IS the full served prompt. Diagnostic distinction is by row, not by column.

- **NEW (verified 2026-08-16, campaign `hf6mdyTHGVXuPxuR8r9C`): Don't dismiss the bug as "user error" when the LLM self-flagellates in a later god-mode turn.** The Factor F bundle pattern (LLM acknowledges the failure in `god_mode_response.text` and `dm_notes` but canonical state never reflects it) often produces a `god_mode_response` like *"I apologize for the oversight. I committed a narrative loop error in Sequence 26 by repeating the hospital board introduction instead of advancing the plot. Additionally, I failed to honor your instruction in Sequence 25 to use canon characters, instead re-using my original character (Elena Vance) because the specific franchise was not yet identified."* This reads like a fix — but **it is not a fix until `state_updates.npc_data` and `custom_campaign_state.god_mode_directives[]` actually carry the change.** Verified on `hf6mdyTHGVXuPxuR8r9C`: 5 god-mode turns across 24 min, 0 `directives.add` entries after turn 1, 0 NPC roster changes persisted despite 4 explicit `dm_notes` claiming "Added X to npc_data". The LLM's self-flagellation is itself evidence of Factor F — it's the LLM acknowledging the narrative-ack-as-write pattern it cannot break out of without a writeback hook (see fix shape component 3: `identity_overrides[]` persistence mirroring `select_memories_by_budget()`). **Always cross-reference LLM `dm_notes` claims against Firestore pre-state before accepting the LLM's "I will fix this next turn" as a durable resolution.**

- **NEW (verified 2026-08-16, campaign `hf6mdyTHGVXuPxuR8r9C`): Title-as-bug-name signal.** When a campaign's `title` field contains the user's own bug-class diagnosis (e.g. *"Genius doctor (json leak + god mode ignored)"*), that's a strong self-confessed structural-issue flag. The user filed the campaign with the bug name in the title. Treat the title as a sibling-issue scan hit even before opening Firestore — it tells you which Factor class to load (`(json leak)` → `references/json-serialization-leak.md`; `(god mode ignored)` → this skill + Factor F). Verified on 2026-08-16: scanning the title alone would have routed the agent to Factor F + Factor I immediately, before any Firestore or BQ query. Add title-scan as Step 0 of any read-only diagnostic where `meta.title` is available.

## Cross-references

- `references/god-mode-directive-missing-subclasses.md` — the umbrella Factor A–H matrix. Factor I is the 9th sibling; this skill is the canonical Factor-I reference.
- `references/prompt-delivery-vs-content-2026-07-20.md` — disambiguates delivery (file doesn't reach LLM) vs content (rule is wrong). Factor I is NEITHER; it's a scope defect.
- `references/god-mode-directive-writeback-gap.md` — the canonical-state writeback pattern that Factor I's `identity_overrides[]` persistence fix shape mirrors.
- `references/god-mode-directive-routing-architecture.md` — channel-side fix pattern that the Identity Reconciliation block fix shape extends.
- `references/god-mode-contract-already-enforced-2026-08-16.md` — **companion diagnostic for the NON-BUG class** (LLM correctly enforces contract; user reports a "bug" that isn't one). Verified on `7HHDMPe0wNLBDTfymzfT` turn 30, 2026-08-16. The 4-interpretation disambiguation menu lives here.
- `references/server-generated-warning-noise-suppression.md` — **adjacent bug class** (sibling render path, different cause). User asks to remove ONE specific server-generated `_append_server_warning(...)` entry from the player-page "System Warnings" banner. Surgical 3-rule fix (drop the user-visible call only; keep the data-fix merge; keep the internal log). Verified on `nocturne warcraft 3` campaign 2026-08-19.

## Source citations

- jleechanorg/worldarchitect.ai #8846 (filed 2026-08-11, campaign `6aXYric3k1IXtJIg6LjT`, scene 112 — 1st-person honored, 3rd-person violated; 3 explicit `directives.add` confirmed in BQ).
- jleechanorg/worldarchitect.ai #8608 (filed 2026-07-26, campaign `fw9Fo3QXkqshtVxBIwX2` Visenya V8 — same root-cause class, 3 stale god-mode directives never retired; 1st instance of the class).
- Bead `rev-02arq` in `${HOME}/projects/worldarchitect.ai/.beads/issues.jsonl`.
- Issue body: `~/.smartclaw/wa-repro-6aXYric/issue-body.md`.
- Campaign ID: `6aXYric3k1IXtJIg6LjT`.
- Upstream Gemini share (source of pre-baked character description): `share.gemini.google/hZXboZihmwYc` (also `gemini.google.com/share/1a3d2d1f2753` and `share.gemini.google/94lImOSaZBZL` — all three serve the same conversation; raw capture at `wiki/sources/2026-08-10-supergirl-kryptonian-gods.md`).