---
name: prompt-trope-injection-class
description: Use when a forbidden trope recurs across 3+ sessions.
tags:
  - worldarchitect
  - prompt-fix
  - bug-class
  - sibling-class
  - trope-injection
allowed-tools:
  - read_file
  - search_files
  - patch
  - write_file
  - terminal
---

# Prompt-Trope-Injection Class (Sibling Bug Class)

## What this skill covers

A **sibling class** of the canonical "LLM improvises because prompt is too terse" bug (see `llm-narration-format-clarifier`). The canonical class assumes the rule is *in* the prompt but underspecified; this class assumes the rule is *not in* the prompt at all. The user-facing symptom is the same ("LLM ignores my directive") but the mechanism is different and the fix shape differs.

## When this skill applies

Trigger when ALL of the following hold:

1. User reports a *recurring* directive (issued 3+ times across sibling sessions) that the LLM keeps violating.
2. The forbidden trope is one of: supervillains, assassination plots, life/death stakes as primary driver, magic detection, scryers, NPC-merging, NPC-self-deification, or any other "X keeps happening despite my correction."
3. Static-evidence grep returns **0 hits** for the trope vocabulary in `mvp_site/prompts/*.md`.

If grep returns ANY hit, route to the canonical `llm-narration-format-clarifier` skill (rule is there but vague — add a worked example). If grep returns 0 hits, you are in trope-injection territory — load this skill.

## Diagnostic recipe (3 steps)

### Step 1 — Static-evidence grep

```bash
cd ${HOME}/projects/worldarchitect.ai
grep -rin '<forbidden_vocabulary>' mvp_site/prompts/ \
  --include='*.md' --include='*.py' \
  --exclude-dir=__pycache__
```

Vocabulary patterns to grep (case-insensitive, OR-joined):
`supervillain|thriller|bio-weapon|synthetic bio|assassin|assassination|life/death|"life and death"|scryer|magic detection|primary villain|god-self|deify|self-deification|merger|split personality`

**0 hits = trope injection confirmed.**

### Step 2 — Sibling cluster scan

Pull `conversations_history` from the user's home channel. Search for `/repro` posts that mention the same trope vocabulary or describe the same pattern ("LLM keeps doing X despite my correction"). The cluster trigger fires at **3+ siblings**. Below 3, file a per-scene gh issue + bead and wait.

### Step 3 — Reference-frame confirmation

Compare against recent canonical-state-anchor fixes:
- PR #8352 — canonical NPC status anchor (handled NPC status persistence)
- PR #8498 — banned prompt entities (Factor G, handled hardcoded entity drift)
- PR #8500 — NPC peer-autonomy anchor (handled NPC dispatch authority)

If the user's symptom fits one of those classes, route there instead. Trope injection is the catch-all for everything else where the rule is in god-mode text but absent from the prompt layer.

## Two fix-shape options

The user MUST choose between these. Do not silently ship Option A; the user has steered Option B direction on 2026-08-13 ("engine should let players declare rules").

### Option A — minimal rule in `master_directive.md`

Add a `## Forbidden Trope Anchors` section with:
- Default-suppressed trope list
- Worked example per trope (fresh, not a mirror — the section doesn't exist yet)
- Negative guard ("never introduce X unless campaign explicitly opts in")

Plus the canonical 4-component durable fix shape:
| Component | Location | Example for "no supervillain" |
|---|---|---|
| Rule section | `master_directive.md` | `## Forbidden Trope Anchors` with default-suppressed list |
| Mirror | `narrative_system_instruction.md` | forbid the trope in narrative-emission prose |
| Test file | `mvp_site/tests/test_<file>_forbidden_tropes.py` | 6-test contract pinning the rule's presence |
| CI lint | `scripts/check_<file>_forbidden_tropes.py` | AST/lint check preventing future drift |

~80 lines, ~30 min.

### Option B — declarative engine schema

Add `custom_campaign_state.forbidden_tropes: list[str]` schema. Default = `["supervillain", "synthetic_bio_weapon", "assassin_plot", "life_death_primary"]`. The LLM reads the schema on every turn and respects it. ~2-3 weeks, aligns with the user's "engine should let players declare rules" steering.

This is a larger refactor — fits the combat-agent PR cluster (#8901-8906 declarative attribute schemas) that opened 2026-08-13.

## Verified worked example (2026-08-17)

- User report: `mvp-site-app-stable-i6xf2p72ka-uc.a.run.app`, "synthetic bio-agent poisoning railroaded into supervillain plot despite god-mode corrections"
- Grep result: 0 hits across `master_directive.md` v2.2, `shared/mechanics_leveling_rewards_body.md`, `shared/ai_generated_mystery_and_internal_drive_plot_arc.md`
- Sibling cluster in C0BDEAJH8PK (7 siblings):
  - `1785489080` synergistic DC
  - `1785722523` scryers/magic detection
  - `1786427778` god-self declaration
  - `1786428506` LLM confused trial
  - `1786429549` Luthor/Waller primary
  - `1786438686` Envoy/Sovereign merge
  - `1786929185` synthetic bio-agent
- User steering reference: 2026-08-13 thread `1786692813` "engine should let players declare rules". Option B aligns.

## Pitfalls

1. **Do not route to canonical `llm-narration-format-clarifier` without first confirming rule absence.** Confirm via Step 1 grep before applying the canonical worked-example recipe. Adding a worked example to a rule that doesn't exist is a no-op.

2. **Sibling cluster is the trigger, not the symptom.** A single repro can look like a Factor-family bug. Only when 3+ siblings accumulate on the same trope-vocabulary does the cluster trigger fire for the prompt-layer fix PR. Below 3, file a per-scene gh issue + bead and wait.

3. **Slack thread channel-root, not thread-only.** User has Slack mobile that doesn't load threads by default — the fix-decision reply (Option A vs B) must post at channel root for the user to see it on mobile. Same rule as `dropped-messages` skill.

4. **REST fallback for `gh issue create`.** GraphQL rate limit on jleechanorg/worldarchitect.ai exhausted 2026-08-17 (graphql=0, core=4970 fresh). Use `urllib.request` REST POST until the budget refills — see the worldarchitect skill's gh-rate-limit-rest-fallback pattern.

5. **Memory is at the cap on busy sessions.** When consolidating memory during a /repro on a trope-injection cluster, the trope-vocabulary list + sibling-cluster ID list is the highest-value content. Drop one-shot session-detail entries (e.g. one-off share-page hydration recipes) first.

6. **The canonical worked-example "mirror the existing line byte-similar" rule does NOT apply for Option A's first edit.** There is no existing line to mirror — the section doesn't exist yet. Use the canonical recipe's three structural pieces (instruction + worked example + negative guard) but the worked example is *fresh*, not a mirror.

7. **Option B is not free.** Adding `custom_campaign_state.forbidden_tropes` is a schema change that touches every agent's prompt-rendering path. Validate with a contract test that the schema field round-trips through Firestore AND that the LLM receives it on every turn (cache-stable — see `wa-llm-cache-churn-diag`).

## Related skills

- `llm-narration-format-clarifier` (sibling umbrella) — canonical "terse rule → LLM improvises" class. Load first when grep Step 1 finds the rule. Load THIS skill first when grep Step 1 returns 0 hits.
- `prompt-discovery-prompt-fix-delivery` — Phase 0 condition 5 "verify-the-rule-received" gate. NOT applicable to trope injection — the rule was never in the prompt to receive. Skip Phase 0 condition 5; jump to Phase 1 with the Option A/B fork.
- `repro` skill — cluster-trigger recipe, Gate 0 rate-limit check, Gate 1 + Gate 2 file gh issue + br bead.
- `wa-directive-scope-factor-i-diag` — Factor I, the 9th sibling of the Factor family. Adjacent but distinct from trope injection (Factor I is about scope-of-directive, trope injection is about absence-of-rule).
- `always-pr-never-local-edit` — worktree + GH issue + branch + PR + push, every time.

## Reference

- Verified worked example: 2026-08-17, C0BDEAJH8PK/1786929185.500759, 7+ sibling repros in the same channel. Campaign URL: `mvp-site-app-stable-i6xf2p72ka-uc.a.run.app`.
- Related PR cluster (combat-agent declarative schemas, 2026-08-13): issues #8901-#8906 on jleechanorg/worldarchitect.ai. The Option B fix shape extends this cluster.