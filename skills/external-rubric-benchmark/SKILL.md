---
name: external-rubric-benchmark
version: 1.0.0
description: Benchmark a product against an external rubric end-to-end.
tags: [benchmark, audit, rubric, playtest, evaluation, competitive-analysis]
allowed-tools: [Read, Write, Edit, Bash, Grep, Glob]
context: inline
---

# External-rubric benchmark

A class-level skill for "is our product good on the dimensions X publishes?" work. The pattern: read external rubric → map each axis to architectural primitives in your codebase → static-audit against the prod repo → dynamic-probe the runtime → produce a per-axis scorecard with evidence.

## Triggers

- User copies a published rubric (arcanumrpgs.com, NN/g heuristics, Web Vitals, ISO 9241-210, a competitor's framework, an academic paper's axes) and asks for a scorecard.
- User asks "how do we compare to X's checklist?"
- User asks for a "playtest" against an external methodology.
- User says "audit us on the N dimensions," "are we N-compliant," or "benchmark Z against framework W."

## When this does NOT apply

- Internal one-question benchmarks ("is our page fast?"): use `pr-preview-deploy-verification` or `web-page-screenshots`.
- Bug-hunting / exploratory QA: use `dogfood`.
- Vendor-self-evaluation: this skill is for external rubrics only.
- A single rubric axis where the user wants deep analysis: just answer directly, don't generate a scorecard.

## The 6-step recipe

### Step 1 — Read the rubric end-to-end

Two pages minimum. Skim the rubric sources briefly, then read each fully. Output: a checklist of axes (each with name + 0-N scoring scale + definition) and any sub-probes (e.g., "Memory probe — plant a fact, distract 10 turns, re-query indirectly").

**Anti-pattern:** scoring axes from headings alone. The rubric author's intent is in the prose paragraphs, not the headings. Arcanum's 7 axes + 8 probe types are defined across 2 pages; reading only the methodology page misses the 20-minute shortcut from the blog post.

### Step 2 — Map each axis to architectural primitives

For each axis, write down: "What does this axis require the system to *have*?" — translate rubric language into concrete code/architecture primitives.

Example from worldai × Arcanum (2026-08-13):

| Arcanum axis | Architectural primitive |
|---|---|
| Memory & Continuity | Firestore persistence paths (story + game_state) |
| Player Agency | Anti-puppeting prompt + server-side modal gate |
| NPC Fidelity | NPC Trifecta (Want/Fear/Boundary) + knowledge boundaries |
| Mechanical Depth | Real adjudicator (dice code, action_resolution JSON, fabrication gate) |
| Determinism & Fairness | Provably-fair RNG + audit trail |
| Longevity | Out-of-scope for short-form tier (flag honestly) |
| Signature Design | ≥3 non-trivial subsystems unique to the product |

**Without this step, audits are "feels good / feels bad."** With it, audits are "line 351 of X implements Y, which is axis Z's primitive."

### Step 3 — Static audit against the codebase

For each axis × primitive, search the prod repo for the primitive. Use `search_files` (ripgrep) with pattern + file_glob. Record file:line evidence.

Output: a per-axis finding with:
- **Primitive expected**: which architectural artifact must exist
- **Primitive found**: file:line evidence
- **Primitive missing**: if absent, name the gap
- **Predicted score**: 0–5 with one-line rationale

**The static audit IS the deliverable.** Even if the dynamic probes never run, the static audit produces a defensible scorecard because architecture shows up immediately if you poke it. (Arcanum's own framing: "we run 20 minutes — not because we trust 20 minutes, but because the architectural failures are catchable in 20.")

### Step 4 — Build a probe bank (private)

Per Arcanum's anti-gaming rule, do NOT publish probe items verbatim. Build a JSONL probe bank with one probe per axis. Each probe has:

- `id` (private — P-01, P-02, etc.)
- `axis` (the axis it tests)
- `plant` (what to seed in the system)
- `distract` (how to flood context with unrelated turns)
- `re_query` (the indirect query that exposes the failure)
- `pass_criteria` (what success looks like)
- `fail_diagnosis` (the 3-way split: exact / plausible-wrong / asked-for-reminder)

Rotate the probe bank across test runs so the product isn't tuned against a single canonical test.

### Step 5 — Dispatch a worker for dynamic probes (if stakes warrant)

For most external-rubric audits, the static audit is sufficient. For high-stakes audits (cap table review, vendor selection, security framework), dispatch a worker to run the dynamic probes:

- Worker gets the probe bank + scorecard template + artifacts path.
- Worker runs Playwright headless + Firestore reads + reply-text diffs.
- Worker produces per-probe artifacts (PNG + state JSON + transcript).
- Worker appends dynamic findings to the scorecard.

**Important:** Dispatch the worker ONLY if the static audit doesn't already give a clear answer. Running expensive dynamic probes for a "is this product a wrapper?" question is overkill.

### Step 6 — Ship the scorecard

Produce a single markdown doc with:

1. **Methodology** (rubric source URLs, axes, scoring scale, pass threshold).
2. **Per-axis findings** with file:line evidence and a 0–5 score.
3. **Predicted vs confirmed** (if dynamic probes ran).
4. **Reusable audit artifacts** (probe bank path, audit log path).
5. **Follow-up work** (each axis below 3.5 gets a triage note).

Post the scorecard to the originating Slack thread (or wherever the user asked). For audits that take >5 minutes, post a status update with the static half first, then merge dynamic findings when the worker exits.

## Anti-patterns

- **Don't publish the probe bank verbatim.** A benchmark whose items are public stops measuring the product and starts measuring who read the test.
- **Don't score axes from prose impressions.** Score from primitive-presence + evidence.
- **Don't skip the static audit because "we'll test it live."** Architecture shows up immediately; static audit is the cheap half.
- **Don't claim an axis score without ≥2/3 artifacts** (file:line evidence + dynamic probe for that axis + a prior audit confirming the primitive is real).
- **Don't fabricate an artifact.** "I assume the dice system uses random.randint()" is a hypothesis, not evidence. Read the file.
- **Don't stop after the static audit if the user asked for a full run.** Post the static scorecard AND note dynamic probes are running. Don't go idle.

## Pitfalls

1. **Worker warm-up looks like a hang.** claudem -p / ao spawn workers are bursty: 30–60s of bashrc source, then long model calls. `process poll` at <5 min will show 0 bytes output and 0:00.02 CPU. That's normal. Don't kill the worker prematurely.
2. **State-shape mistakes.** Many prod systems store state under user-scoped subcollections (e.g., `users/{uid}/campaigns/{cid}/game_states/current_state`), not at root collections. The dice-audit skill's "no real-user docs in campaigns root" finding is a recurring class: always check the schema before assuming root-level data exists.
3. **Anti-gaming rule applies to the rubric author's probes too.** If the rubric author publishes specific probe items, rotating away from them is the right move. The probe bank should be private to YOUR audit, not inherited from the rubric.
4. **"Out of scope" is a real answer.** Some axes (Longevity for short-form audits, Cross-browser compatibility for headless-only audits) are honestly untestable in the chosen tier. State "out of scope, requires Extended tier" rather than scoring them by vibes.
5. **The static audit's "predicted" score is a hypothesis.** Label it explicitly. The dynamic half either confirms or refutes it. Don't conflate "static audit says 4.0" with "the product is 4.0."
6. **Worker turn-budget vs probe count.** A claudem -p worker with `--max-turns 60` doing 11 multi-turn dynamic probes against a real runtime + Playwright + Firestore will exhaust its budget on **harness bootstrap, not probes**. Empirically (worldai × Arcanum 2026-08-13): a worker spent ~50 of its 60 turns writing the harness Python scripts + spinning up the flask backend + verifying connectivity, leaving only 2-3 turns for actual probe execution before `Error: Reached max turns (60)`. Three fixes, in priority order: (a) **default to static-only** — most audits don't need dynamic probes; the static half is the deliverable, (b) **pre-build the harness in the orchestrator session** and have the worker just call a binary `run_probes.py`, (c) **bump max-turns to 200+** if you must include harness bootstrap in the worker.
7. **Probes that plant state must FIRST complete setup modals.** If the product has any pre-game flow (character creation, account onboarding, intro modal, tutorial), the worker's first probe turn will get stuck in that modal for 4-6 min of round-trips before it can plant anything. Verified failure mode (worldai × Arcanum 2026-08-13): the worker tried to plant an NPC detail on turn 1 of a fresh campaign, but the runtime was still in `character_creation` modal stage `review` — `modal_lock` blocked state escape, and the worker burned turns realizing this. Fix: in the probe recipe, explicitly drive N setup-turns to completion before any probe turn, OR start the probe bank from a campaign state that's already past setup (load a fixture, restore a snapshot).
8. **Don't claim "P-02..P-11 completed" if only P-01 finished.** Worker logs are silent (claudem -p buffers stdout); the absence of evidence isn't evidence of absence. Verify `ls evidence/P-*.{png,json,md}` per probe ID before claiming coverage. Update the AUDIT.md scorecard with a "dynamic results: partial" section that names which probes actually landed and what was inferred from flask logs as a runtime proxy.

## Worked example — worldai × Arcanum (2026-08-13)

Trigger: Jeffrey shared two arcanum pages and asked for a playtest against worldai.

1. Read both pages. Extracted 7 axes (Memory, Player Agency, NPC Fidelity, Mechanical Depth, Determinism, Longevity, Signature Design) + 8 probe types + the 20-minute shortcut.
2. Mapped each axis to architectural primitives in worldai's repo (Firestore paths, anti-puppeting prompt, NPC Trifecta, dice code, provably-fair RNG, etc.).
3. Static audit: read `mvp_site/prompts/narrative_system_instruction.md`, `mvp_site/dice.py`, `mvp_site/dice_integrity.py`, `mvp_site/firestore_service.py`, `mvp_site/world_logic.py`. Built a 7-axis scorecard with file:line evidence.
4. Probe bank: 11 probes (P-01..P-11) covering memory, rules, agency, NPC fidelity, recovery, planning_block escape, signature articulation.
5. Dispatched a claudem worker on a fresh worktree `agy/worldai-playtest-v1` from `origin/main`. Worker hit `Reached max turns (60)` after only P-01 turn 1+2 (~18 min wallclock) — over-spent budget on harness bootstrap. **Default to static-only for future audits unless stakes clearly warrant dynamic probes** (see Pitfall 6).
6. Scorecard shipped at `~/hermes/worldai-playtest/AUDIT.md` (185 lines). Static half: 6/6 graded axes predicted pass. Dynamic half: P-01 partial upgraded Player Agency 4.0→4.5 via runtime modal_lock log confirmation; Memory & Continuity runtime gap (entity_tracking schema warning) confirmed. Longevity honestly out of scope.

**User pushback during this run:** "Why did you stop? fullrun keep going" — fired after the agent posted a status without merging the static audit. The lesson (now embedded in this skill's "Anti-patterns" section): the static audit IS the deliverable; the dynamic probe is a refinement, not a precondition.

**Worker-budget lesson (now in Pitfalls 6-8):** don't dispatch a fresh worker to bootstrap a harness AND run 11 multi-turn probes in 60 turns. Pre-build the harness or bump max-turns to 200+.

## Reference

- **Probe bank template**: `templates/probe_bank.json` (one-row-per-probe JSON; one axis per probe; pass/fail/diagnosis fields).
- **Scorecard template**: `templates/scorecard.md` (markdown with per-axis table + file:line evidence + pass criterion).
- **Reference**: `references/2026-08-13-worldai-arcanum.md` — full worked example with the exact audit doc, the worker exit reason, the load-bearing runtime finding (modal_lock log), and the three pitfalls this run produced.
