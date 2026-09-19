---
name: llm-narrative-foreshadowing-bounds
description: Diagnose LLM trope escalation in narrative foreshadowing.
tags: [llm, narrative, trope, foreshadowing, worldarchitect, prompt-layer, structural-bug]
changelog:
  - 1.0.0 (2026-08-17) Initial creation. Verified on campaign hf6mdyTHGVXuPxuR8r9C, turn 6 (HeavyDialogAgent) — user prompt "accompany the patient... assume the patient is some powerful/rich person and a plotline later organically develops" triggered LLM to invent "synthetic bio-agent designed to mimic Status Epilepticus / neuro-toxins". Sibling cluster in C0BDEAJH8PK across 2026-07-31 → 2026-08-17 (≥7 repros including 1785489080 synergistic DC, 1785722523 scryers, 1786427778 god-self, 1786428506 trial-confusion, 1786429549 Luthor/Waller, 1786438686 Envoy/Sovereign merge, 1786929185 Silas Vane bio-agent). Root cause: mvp_site/prompts/narrative_system_instruction.md lines 873-877 + 1046 actively legitimize assassination/hostile-takeover as plot devices; zero bounding rule for trope class exists anywhere in served prompt layer. User steering 2026-08-13 ("engine should let players declare rules") points to declarative engine approach (Option B).
---

# llm-narrative-foreshadowing-bounds

A bug class for LLM-driven narrative engines where the LLM escalates a user-invited plotline seed into a **forbidden trope class** (supervillain, synthetic bio-weapon, assassin, magic-detection default, mass-destruction default, life-and-death as primary stakes).

Distinct from:
- `repro-llm-invented-lore-artifacts` (LLM invents artifacts in low-magic settings — different root cause, different fix)
- `state-update-value-derivation-drift` (LLM writes wrong numeric in `state_updates` — same campaign, different bug class)
- `god-mode-directive-missing` (LLM ignores player directive — adjacent but distinct)
- `prompt-delivery-vs-prompt-content` (rule in prompt file vs rule delivered to LLM)

## When this skill applies

User says any of:
- "LLM keeps inventing supervillains / assassins / synthetic bio-agents / scryers despite god mode"
- "I told the LLM X, the LLM did Y, Y contradicts the campaign premise"
- "I asked multiple times not to do it and it keeps doing it"
- "even beyond god mode directives this [trope] shouldn't be railroaded"
- "the campaign got railroaded into a [trope] plot"

The LLM-symptom is a trope-class escalation in narrative foreshadowing or plot seed material. The user-typed prompt was *neutral* (e.g. *"a plotline later organically develops"*) but the LLM escalated to a forbidden trope class.

## Diagnostic — 5-query BQ forensic recipe

Run in order. Each query answers the next.

### Q1 — Confirm the campaign is in BQ at all

```sql
SELECT FORMAT_TIMESTAMP('%Y-%m-%dT%H:%M:%SZ', MIN(ingested_at)) AS first_ts,
       FORMAT_TIMESTAMP('%Y-%m-%dT%H:%M:%SZ', MAX(ingested_at)) AS last_ts,
       COUNT(*) AS row_total,
       COUNT(DISTINCT agent) AS agents,
       MAX(turn_index) AS max_turn
FROM `worldarchitecture-ai.llm_forensics.llm_payloads`
WHERE campaign_id = '<CID>'
```

If `row_total = 0`: bug is client-side. See the `repro` umbrella skill's `references/bq-llm-payload-truncation-pitfall.md` (Pitfall 3).

### Q2 — Find the user-typed prompt that triggered the escalation

Search for the *user prompt content* (not the trope token). Grep `request_json` with `LIKE '%<unique 4+ word phrase from user prompt>%'`.

```sql
SELECT FORMAT_TIMESTAMP('%Y-%m-%dT%H:%M:%SZ', ingested_at) AS ts,
       agent, turn_index,
       SUBSTR(request_json, 1, 2500) AS req_head
FROM `worldarchitecture-ai.llm_forensics.llm_payloads`
WHERE campaign_id = '<CID>'
  AND agent IN ('HeavyDialogAgent','StoryModeAgent','DialogAgent','GodModeAgent')
  AND request_json LIKE '%<unique phrase from user prompt>%'
ORDER BY ingested_at ASC
```

### Q3 — Pull the LLM output for that turn

```sql
SELECT FORMAT_TIMESTAMP('%Y-%m-%dT%H:%M:%SZ', ingested_at) AS ts,
       agent, turn_index,
       response_text
FROM `worldarchitecture-ai.llm_forensics.llm_payloads`
WHERE campaign_id = '<CID>'
  AND CAST(turn_index AS STRING) = '<TURN>'   -- turn_index is INT64, cast required
ORDER BY ingested_at ASC
```

### Q4 — Confirm the trope token does NOT exist in any served prompt file

```bash
cd ${HOME}/projects/worldarchitect.ai
grep -rln "supervillain\|thriller\|bio-agent\|bio-weapon\|assassin\|life.death\|medical/social" mvp_site/prompts/
```

Expected negative result (verified 2026-08-17):
- `master_directive.md` v2.2: **0 hits**.
- `narrative_system_instruction.md`: 20+ hits, ALL legitimizing the trope class.
- `narrative_lite_system_instruction.md`: same pattern.
- All other prompt files: **0 hits** on a bounding rule.

If zero files contain a bounding rule, every LLM escalation is in-bounds. That's the smoking gun.

### Q5 — Check sibling-campaign structural pattern

Search the last 30 days globally for the same trope tokens. ≥2 instances across different campaign_ids proves the bug is prompt-layer, not per-campaign.

```sql
SELECT campaign_id, FORMAT_TIMESTAMP('%Y-%m-%dT%H:%M:%SZ', ingested_at) AS ts,
       agent, turn_index,
       SUBSTR(response_text, 1, 400) AS snippet
FROM `worldarchitecture-ai.llm_forensics.llm_payloads`
WHERE agent = 'gemini_provider.stream'
  AND (LOWER(response_text) LIKE '%synthetic bio%'
       OR LOWER(response_text) LIKE '%bio-agent%'
       OR LOWER(response_text) LIKE '%silas vane%'
       OR LOWER(response_text) LIKE '%assassin%'
       OR LOWER(response_text) LIKE '%supervillain%')
  AND ingested_at > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY)
ORDER BY ingested_at DESC
LIMIT 25
```

## Durable fix shape (2 options)

### Option A — Quick rule (~30 min)

Add a new section to `mvp_site/prompts/narrative_system_instruction.md` immediately **before** line 873:

> **Trope Category Default — the narrative layer must not introduce `supervillain_primary`, `synthetic_bio_weapon`, `assassin_plot`, `magic_detection_default`, `mass_destruction_default`, or `life_death_primary` as unprompted foreshadowing or plot seed material. A player prompt that invites a "plotline later organically develops" must default to one of: medical mystery, social complication, factional politics, romance, professional rivalries, family dynamics. To unlock a forbidden category, the player must explicitly name it.**

Plus 6-test contract and CI lint.

### Option B — Declarative engine (matches user 2026-08-13 steering, ~2-3 days)

New `mvp_site/prompts/shared/forbidden_trope_anchors.md` mirrored from `npc_knowledge_boundaries.md`:
- Defaults to the 6 forbidden categories above.
- Lets the campaign opt OUT via `custom_campaign_state.allowed_tropes: list[str]`.
- When the LLM would introduce a forbidden category, it MUST surface a `trope_choice_block` in the planning block mirroring the `## Canonical-State Anchor` style from PR #8500.

Pair with new `scripts/check_prompt_trope_anchors.py` CI lint.

**Recommended: Option A then B.** Ship A immediately to fix the current bug class, layer B as the longer-term declarative version.

## Anti-pattern (codified)

DO NOT post a 2-or-3-way menu of fix shapes before running the BQ queries above. Output ONE diagnosis with the 5 evidence blocks (Q1 → Q5) before proposing any fix direction. User pushback on #8528 (*"Read the actual raw LLM request in BQ"*) directly targeted a clarifying menu the agent had posted.

## Verified worked example (2026-08-17)

- Campaign `hf6mdyTHGVXuPxuR8r9C`, turn 6, HeavyDialogAgent at 2026-08-17T00:24:35Z.
- User prompt: *"accompany the patient and give detailed handoff instructions. should be low DC. lets assume the patient is some powerful/rich person and a plotline later organically develops"*.
- LLM output (excerpt): *"If his cellular matrix dips below the 95% threshold, use a localized Antiseptic Barrier (Dispel Magic) to neutralize any latent **neuro-toxins**."*
- User god-mode correction 2 turns later.
- Sibling cluster in C0BDEAJH8PK: ≥7 repros across 2026-07-31 → 2026-08-17, same root-cause class.

## Reference

These files are owned by the `repro` umbrella skill (`~/.smartclaw/skills/repro/SKILL.md`) — load that umbrella first, then reference:

- `repro/references/bq-llm-payload-truncation-pitfall.md` — BQ output-format pitfalls (control chars, turn_index INT64 cast, PYTHONPATH pollution from `~/projects_other/hermes-agent`)
- `repro/references/repro-llm-invented-lore-artifacts-2026-07-18.md` — sibling bug class (artifact invention, different root cause)

Pattern references from worldarchitect.ai PRs:

- PR #8352 (canonical NPC status anchor) — pattern reference for canonical-state rule in served prompt
- PR #8498 (banned prompt entities / Factor G) — pattern reference for prompt-layer bounding rule
- PR #8500 (NPC peer autonomy anchor) — pattern reference for `## Canonical-State Anchor` planning-block style to mirror in `trope_choice_block`