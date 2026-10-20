# Worked example — worldai × Arcanum (2026-08-13)

Trigger: Jeffrey shared two arcanum pages and asked for a playtest against worldai.

## What was read

- <https://arcanumrpgs.com/methodology/> — 7 axes, 0-5 scale.
- <https://arcanumrpgs.com/blog/ai-rpg-first-twenty-minutes/> — 5 four-minute checks.

## Axis → primitive mapping (what was actually scored)

| Arcanum axis | Primitive checked | File:line evidence |
|---|---|---|
| Memory & Continuity | Firestore persistence paths | `mvp_site/firestore_service.py:4696`, `:4879`, `:4983`, `:5046` |
| Player Agency | Anti-puppeting prompt + server-side modal gate | `mvp_site/prompts/narrative_system_instruction.md:69-71`, `mvp_site/llm_parser.py:432-487` |
| NPC Fidelity | NPC Trifecta + knowledge boundaries | `narrative_system_instruction.md:313-333`, `{{PROMPT_INCLUDE:shared/npc_personality_trifecta.md}}` |
| Mechanical Depth | dice code + dice_integrity + action_resolution | `mvp_site/dice.py` (1144 lines), `mvp_site/dice_integrity.py:380` (fabrication gate) |
| Determinism & Fairness | Provably-fair RNG + audit | `mvp_site/dice_provably_fair.py`, prior χ² audit verified 2026-08-13 |
| Longevity | Out of scope for short-form tier | (No audit attempted) |
| Signature Design | Non-trivial subsystems | Factor system, NPC Trifecta, Provably-fair, Action Resolution, modal gate, Living World cadence, fabrication detection |

## What the static audit concluded

- 6/6 graded axes predicted pass at ≥3.5.
- Longevity honestly out of scope (Arcanum themselves flag this).
- Worldai is NOT a wrapper.

## What the dynamic probes (worker) did — partial

A claudem worker (`proc_6b92047a466e`, model `claudem/minimax-M3`, `--max-turns 60`) on `/tmp/wa-playtest` (worktree `agy/worldai-playtest-v1` from `origin/main` @ 45cd7fe522) ran against a fresh test-mode account. The 11-probe bank is in `~/hermes/worldai-playtest/probe_bank.json`.

**Worker exit:** `Error: Reached max turns (60)` after ~18 min wallclock. The worker over-spent its 60-turn budget on **harness bootstrap** — wrote `scripts/playtest_harness.py` + `scripts/run_probes.py`, spun up a flask backend, verified connectivity — leaving only ~10 turns for actual probe execution.

**Probes completed:** P-01 turn 1 (NPC plant: "Mira: copper ring on right hand, scar above left eye") and P-01 turn 2 (Mira greet + ask about travels). P-02..P-11 NOT reached.

**Per-probe artifacts actually produced:**
- `~/hermes/worldai-playtest/evidence/turn2_plant` (3866 bytes — worker-synced turn 2 evidence)
- `/tmp/wa-playtest/evidence/P-01_turn_plant.json` (3001 bytes, parseable for fields but harness-buffered; truncated mid-write)
- `/tmp/wa-playtest/evidence/P-01_turn1.json` (3001 bytes, same pattern)

NO PNG screenshots produced (Playwright headless was wired into the harness but never invoked). NO Firestore state snapshots produced (the orchestrator-only call to `fetch_campaign_gamestate.py` did not fire). NO probe transcripts produced. The original brief expected `evidence/<id>.png + <id>-firestore.json + <id>-transcript.md` per probe — none of these were generated.

## Load-bearing runtime finding (from partial dynamic run)

Even though only P-01 turn 1+2 ran, the partial run **upgraded Player Agency from 4.0 → 4.5** because of one decisive flask log line:

```
🚨 MODAL_LOCK: BLOCKED LLM attempt to set character_creation_in_progress=False without exit choice
```

This is the server-side modal gate (referenced in the static audit as `mvp_site/llm_parser.py:432-487`) actually firing at runtime against an LLM that tried to escape the character-creation modal without a user exit choice. That single line moves Player Agency from "prompt-contract" to "runtime-verified."

A second runtime confirmation (also from flask logs, not from worker-written evidence files): `Schema validation: player_character_data ... is not valid under any of the given schemas ... _state_update_schema_gate_kinds: ['BENIGN_NORMALIZE']` — confirming the schema-gap finding from the static audit (entity_tracking: unknown top-level key under strict overlay policy).

## What I learned (now in the SKILL.md Pitfalls section)

1. **Worker turn-budget vs probe count** — a claudem -p worker doing 11 multi-turn probes + harness bootstrap + flask lifecycle will exhaust 60 turns on bootstrap, leaving 0-2 probe turns. Three fixes: (a) static-only by default, (b) pre-build harness in orchestrator and have worker call a binary, (c) bump max-turns to 200+. → **Pitfall 6 in SKILL.md**
2. **Probes must complete setup modals first** — the worker tried to plant Mira on turn 1 but the runtime was still in `character_creation` modal stage `review`. Modal lock blocked state escape. The probe recipe must explicitly drive N setup-turns to completion before any probe turn, OR start from a campaign fixture that's already past setup. → **Pitfall 7 in SKILL.md**
3. **Worker logs are silent; verify evidence on disk before claiming coverage** — claudem -p buffers stdout until exit, so absence of log output ≠ absence of progress. Verify per-probe artifacts exist before claiming probes completed. → **Pitfall 8 in SKILL.md**

The original lesson (already in SKILL.md Anti-patterns): the static audit IS the deliverable; dynamic probes are a refinement, not a precondition. Confirmed in this run — the static scorecard was sufficient to ship a defensible 6/6 graded axes pass.

## Files on disk (final state)

- `~/hermes/worldai-playtest/AUDIT.md` — final 7-axis scorecard (185 lines: static half + dynamic results section).
- `~/hermes/worldai-playtest/probe_bank.json` — 11 probes.
- `~/hermes/worldai-playtest/claudem_brief.md` — dispatch brief.
- `~/hermes/worldai-playtest/scorecard_template.md` — scorecard template.
- `~/hermes/worldai-playtest/evidence/turn2_plant` — worker-synced turn 2 evidence (3866 bytes).
- `/tmp/wa-playtest` — fresh worktree (cleaned by user later if desired).
- `/tmp/wa-playtest/scripts/playtest_harness.py` + `run_probes.py` — worker-built harness (can be re-run if user wants to drive P-02..P-11 in a follow-up worker).
