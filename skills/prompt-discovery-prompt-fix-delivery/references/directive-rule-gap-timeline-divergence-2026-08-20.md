# Directive-rule-gap (timeline-divergent entity-conflation) — verified 2026-08-20, jleechanorg/worldarchitect.ai #9163

The NEGATION of Phase 0 condition 5: when the LLM did NOT receive the rule — not because it was lost, but because the rule never existed in the served prompt.

## Bug class signature

When an alternate-timeline campaign re-routes canonical lore (e.g. the player claims a canonical artifact BEFORE its canonical owner — Frostmourne goes to Nocturne instead of Arthas), the served directives implicitly assume canonical-lore ordering and DO NOT explicitly mark the timeline divergence. The LLM collapses back to canonical lore across consecutive turns, conflating entities that the campaign has explicitly separated (e.g. conflating Prince Arthas Menethil with the Lich King).

Distinct from every existing sibling class:
- **Condition 5** (`LLM-already-received-the-rule`) — LLM had the rule but didn't apply it.
- **Condition 6** (`wrong-tier`) — LLM had the rule but picked the wrong tier.
- **Condition 7** (`prompt-teaches-non-canonical-schema`) — prompt teaches the wrong shape.
- **Factor F / G / H** — directive-loss / default-missing / lost-in-the-middle.
- **`npc-status-persistence-bug` sub-classes** — narrative-only state change with no structured write.

The directive-rule-gap class is **about absence, not misinterpretation**: the rule that should anchor the LLM's narrative against canonical-lore fallback simply does NOT exist in any prior `request_json`. Adding more content to `mvp_site/prompts/<file>.md` won't help — the served prompt's directive block is the right layer to fix, but the missing rule is a TIMELINE-DIVERGENCE anchor that lives in the prompt layer.

## Smoking-gun diagnostic — was the rule ever served?

`worldarchitecture-ai.llm_forensics.llm_payloads.request_json` is a stable 350KB-cap snapshot of the served prompt per turn. The directive list lives inside it as a JSON array of `{added, rule, id}` entries. Each `id` is a `directive_<8-hex>` token (e.g. `directive_7b809075`).

Query that extracts the directive-ID timeline across a bug window:

```sql
SELECT FORMAT_TIMESTAMP('%Y-%m-%dT%H:%M:%SZ', ingested_at) AS ts,
       agent, turn_index,
       ARRAY_TO_STRING(
         REGEXP_EXTRACT_ALL(CAST(request_json AS STRING), r'\\"id\\":\s*\\"(directive_[a-zA-Z0-9]{8})\\"'),
         '|') AS directive_ids,
       ARRAY_LENGTH(
         REGEXP_EXTRACT_ALL(CAST(request_json AS STRING), r'\\"id\\":\s*\\"(directive_[a-zA-Z0-9]{8})\\"')) AS n_directives
FROM `worldarchitecture-ai.llm_forensics.llm_payloads`
WHERE campaign_id = '<CID>'
  AND event_type = 'gameplay_streaming'
  AND agent = 'GodModeAgent'
  AND ingested_at BETWEEN TIMESTAMP('<BUG_START_TS>') AND TIMESTAMP('<USER_CORRECTION_TS>')
ORDER BY ingested_at ASC
```

**The signature:** if the rule the LLM claims to honor at the user's correction turn was FIRST ADDED at that turn itself (timestamp matches the user's correction ts), the bug is directive-rule-gap. The rule the user wrote was the rule the prompt layer was missing.

Verified on `ArYA47Fvx8HTYC8jpleO` turn 232 (2026-08-20T09:55:30Z):
- LLM emits `directives.drop = ["ID: directive_decouple_arthas_lk | ...Arthas is the Death Knight champion..."]` (WRONG initial decoupling)
- LLM emits `directives.add = ["ID: directive_arthas_mortal_status | ...Arthas is a mortal human...NOT a Death Knight..."]` (corrected rule after user's push-back)
- BQ `request_json` first-seen for `directive_7b809075` (the rule's id) = `2026-08-20T09:55:30Z` (the correction turn)
- BQ `request_json` first-seen for ANY prior Arthas-decoupling rule = NULL across 53 prior god-mode turns

Conclusion: served directives DID NOT contain any "Arthas ≠ Lich King" rule before the user forced one. The bug is directive-rule-gap.

## Companion pitfall — BQ CSV double-encoding

BQ `--format=csv` output adds another layer of escaping on top of JSON's `\"`. A JSON-escaped quote inside a `request_json` field becomes `\\"` in the CSV cell value, then `\\\\\"` when read by Python's `csv.reader` after un-CSV-decoding.

Naive regex `"rule":\s*"((?:[^"\\]|\\.)*?)"` returns 0 matches because the CSV escaping is doubled. The correct pattern for extracting rule text from a CSV-exported `request_json`:

```python
import csv, io, re
with open('rules.csv') as f:
    rows = list(csv.reader(io.StringIO(f.read())))
val = rows[1][2]  # the request_json column
if val.startswith('"') and val.endswith('"'):
    val = val[1:-1].replace('""', '"')  # un-CSV outer quoting
# Now val contains JSON with `\"` for inner quotes
rules = re.findall(r'\\"rule\\":\s*\\"((?:[^"\\\\]|\\\\.)*?)\\"', val)
# rules[i] is the i-th rule text (still JSON-escaped — de-escape per row)
```

Verified on `ArYA47Fvx8HTYC8jpleO` turn 222 — naive regex returned 0 rules, corrected regex returned 58 rules (18 mentioning Arthas / Lich King / Frostmourne). Without this fix, the diagnostic silently misses all served rules and the analyst concludes "no directives" when 58 are present.

## Meta-trap — the user's correction turn itself adds the rule

A common false positive: the LLM emits a directive via `directives.add` at the user's correction turn, and the analyst (reading `response_text` only) concludes "the LLM has the rule now" and assumes the bug is fixed. But that rule was ADDED at the correction turn — it was never in the prompt that produced the buggy narrative the user is complaining about.

**Always check the FIRST-SEEN timestamp** of any directive the LLM cites. If `first_seen_ts ≈ user_correction_ts`, the bug is directive-rule-gap. The fix lives in the prompt layer, not in the directive store.

## The 18 served directives that did NOT anchor the LLM (worked example)

Extracted from `request_json` at turn 222 (6 min before user's correction) on `ArYA47Fvx8HTYC8jpleO`. None of these explicitly state *"this timeline diverges from Warcraft III canon at the Frostmourne handoff"*:

| # | Excerpt |
|---|---|
| 12 | 3-Generation Power Lineage: Terenas/Antonidas/Uther G0; **Arthas/Jaina/Sylvanas G1**; Nocturne G2 |
| 13 | Mortal characters hard-capped at L12; Uther/Jaina represent this peak |
| 15 | Only Primordials (Archimonde, Kil'jaeden, **the Lich King**) may exceed L20 |
| 17 | Mortal cap L12; Legendary L13-20; Primordial L21-30 |
| 18 | Refer to Scourge leader solely as "Lich King" |
| 21 | `directive_finite_roster` — 3 Primordials + 4 Legendary Antagonists (**Arthas, Kel'Thuzad, Tichondrius, Mannoroth**) |

The LLM correctly classifies Lich King as Primordial/L25-30 and Arthas as G1/heroic — but when asked to narrate both, it falls back to **Warcraft III canonical lore** (Arthas → Frostmourne → Death Knight → becomes Lich King) because no directive explicitly forbids canonical-lore fallback.

## Cluster context (verified on `ArYA47Fvx8HTYC8jpleO`)

4 sibling repros in 24 hours, all sharing the same root:

- **#9147** Frostmourne/Raven's Needle (turn 223) — directive says Frostmourne is in Northrend; no rule for "Nocturne acquired Frostmourne via Malachar's intel"
- **#9149** Latency (38.7s avg LLM) — directive bloat grows 23→56 per turn, busting cache
- **#9162** Kel'Thuzad fabricated death (turn 231) — directive lists Kel'Thuzad as Legendary Antagonist; no rule for "Kel'Thuzad is dead at Hyjal in this timeline"
- **#9163** Arthas/Lich King conflation (turns 180-232) — same pattern: no explicit timeline-divergence anchor; LLM collapses to canonical lore

All 4 fixable with one cluster-root PR.

## Fix shape (4-component deliverable)

Per `references/prompt-fix-deliverable-shape-2026-07-18.md` (in the project-owned `repro` skill), ship on a fresh `feat/timeline-divergence-anchor-cluster-9163` worktree from `origin/main`:

1. **NEW: `### Timeline-Divergence Anchoring` section in `mvp_site/prompts/narrative_system_instruction.md`** — explicit rule: *"When a campaign explicitly diverges from Warcraft III / Star Wars / canonical lore (e.g. player claims a canonical artifact before its canonical owner), the served directives MUST contain an explicit timeline-divergence rule stating the new state and forbidding canonical-lore fallback. The LLM is forbidden from inferring canonical lore from prompt context when served directives establish a divergent state."*
2. **Mirror `### 9. Timeline-Divergence Anchoring` section in `mvp_site/prompts/planning_protocol.md` §"Canonical-State Anchor"** — when planning blocks reference canonical-lore entities, the planning layer must check the served directive list for explicit timeline-divergence markers.
3. **CI lint `scripts/check_timeline_divergence.py`** — scan `request_json` directive lists for canonical-lore entity references (Frostmourne, Arthas, Lich King, Anakin, Horus, etc.) and FLAG when ANY campaign has >5 lore-divergence-relevant entities but NO explicit timeline-divergence rule.
4. **Contract test `mvp_site/tests/test_timeline_divergence_anchor_9163.py`** — pin the rule across all 4 sibling scenarios.

## Why this is NOT a `prompt-discovery-prompt-fix-delivery` task (mostly)

The fix is content in `.md` prompt files + a contract test, which is the surface shape of a prompt-discovery task. But the diagnostic discipline is different:

- Phase 1 of this skill assumes "the rule was lost in transit; write it back to the prompt." Wrong here — the rule was never written.
- Phase 0 condition 5 (verify-the-rule-received) returns "the rule was not received." That triggers the new condition 8 branch below.
- The fix shape lives at the **timeline-divergence anchor layer** of the prompt, not at any of the 5-7 condition layers.

**However**, after the timeline-divergence anchor lands, individual sub-bugs that surface AS condition 5/6/7 failures on the same campaign CAN be addressed via this skill's normal two-pass shape. The cluster-root PR (steps 1-4 above) establishes the anchor layer; subsequent sibling repros become fixable through the existing skill flow.

## Decision tree

```
User reports "LLM forgot X is not Y in this campaign"
  ↓
Phase 0: BQ first — is the rule in request_json at the buggy turn?
  ├─ YES, present at buggy turn → condition 5 (narrative-ack-as-write / attention-fatigue)
  ├─ YES, present + wrong-tier picked → condition 6
  └─ NO, only present at user correction turn → directive-rule-gap (THIS REFERENCE)
        ↓
      Map directive IDs across full bug window. First-seen timestamp = smoking gun.
        ↓
      If ≥3 sibling repros on same campaign with same signature → cluster-root PR
        ↓
      Ship 4-component deliverable: timeline-divergence anchor section + planning_protocol mirror + CI lint + contract test
```

## Cross-reference

- `references/npc-status-persistence-bug.md` (project-owned `repro` skill) — sibling taxonomy (this is a NEW canonical-state-anchor sub-class distinct from all 7 listed there)
- `references/god-mode-directive-missing-subclasses.md` (project-owned) — Factor A through H doctrine (none apply; NEW class)
- `references/prompt-fix-deliverable-shape-2026-07-18.md` (project-owned) — 4-component deliverable template
- `references/bq-llm-payload-truncation-pitfall.md` (project-owned) — `request_json` 350KB-cap pitfall + `turn` vs `turn_index` column pitfall + scene-number-vs-turn_index mismatch
- `repro` skill (curator-managed thin pointer) → canonical at `${HOME}/projects/worldarchitect.ai/.claude/skills/repro-twin-clone-evidence/SKILL.md`
