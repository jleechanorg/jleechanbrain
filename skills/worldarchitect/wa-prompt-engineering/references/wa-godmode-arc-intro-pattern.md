# Jeffrey's God-Mode Arc-Introduction Pattern — Reference Input

This file documents how Jeffrey actually uses the WA god-mode surface to introduce arcs, based on a forensic sweep of `~/llm_wiki/wiki/sources/`, `~/roadmap/`, and session DB. It is the canonical empirical reference for any prompt-framework work that has to interact with `>>>god mode<<<`, `_god_mode_*` admin directives, or god-mode-only state fields like `custom_campaign_state.*`.

## Why this exists

The 2026-08-16 PR #8979 review thread (`@session:default/20260816_201635_823543eb`) surfaced Jeffrey's verbatim rules for god-mode arc injection:

- **"Not necessarily during these turns I can switch to god mode and inject"** — god mode is orthogonal to character-mode beats; never gate it behind a mode flag.
- **"It can advance the arc. The companion should remember the discussion it just shouldn't make us do stuff in the 'real' world like combat or progressing things physically"** — `companion_arcs.<name>.progress` and `phase` MAY advance from a god-mode injection; the prohibition is on combat / physical-world movement, not on narrative beats.

These two sentences are the canonical rule for god-mode ↔ arc interaction. Any framework that gets this wrong will fail the next PR.

## Jeffrey's arc-intro shape (verbatim categories)

Across 11+ campaign bibles + 3 god-mode system prompts + 7+ session reviews, god-mode arc-introductions collapse into 5 shapes:

### Shape 1 — Mid-session single invocation (most common)

Aizen BG3 god-campaign, line 5260 of `~/llm_wiki/wiki/sources/2026-08-04-aizen-god-campaign.md`:

> *"We are initiating a new grand strategy. Codename: Project NIHIL. The objective is the eventual acquisition of the portfolio of the divine entity Myrkul. Your primary task is to begin Phase One: you will use your arcane and strategic faculties to manufacture a pretext for war... Create and plant evidence that will paint him as an aggressor in the eyes of the other gods. You have full autonomy in the execution of this phase. **Begin.**"*

One sentence names the arc + goal + phase + autonomy mandate + activation trigger. No `{phase, hooks, callbacks}` schema. Arrives mid-conversation between two ordinary turns.

### Shape 2 — Iterative re-issue + regenerate (rarest, most expensive)

Sanguine Architecture (`2026-08-04-nocturne-bg3-campaign-god-of-murder-sanguine-architecture-god-mechanics-v1-v2.md`): **7 design passes** against Gemini inside one share thread before the canonical 3,422-word bible locked. Pattern: re-issue the prompt, ask regeneration at different fidelity, accept the version that matches. Use when a single pass would overshoot the LLM's attention window.

### Shape 3 — Bible seed with first-mission line (most common in seed prompts)

`2026-08-04-worldai-campaign-prompts.md` lines 14-101 (4 distinct campaigns in one file):

> *"Setting is baldurs gate after the events of baldurs gate 3. I am Nocturne, a 16 year old female mercenary... Youngest bastard daughter of a very powerful noble house... My main goals are to amass power and wealth. Think about sensible points in the narrative to offer me a time skip of one year. **Let me explicitly agree though before doing it.**... My first contract is to kidnap some peasants to sell as slaves to a criminal syndicate."*

One prompt = full seed. Pre-declares setting, tone, character class, archetype stack, level cap, **one concrete first action**. **No arc steps** in the seed itself — those emerge from play.

### Shape 4 — System-prompt-as-arc-rulebook (god-mode framework layer)

`2026-08-04-god-campaign-prompt-upgrade.md` lines 1-200: the entire god-mode *rulebook* (4 Layers, 5-Tier ranking, Causal Dissonance mechanic, Divine Reference Table, Interface & Telemetry) is authored as a system prompt **before** play begins. The arcs then come from `rulebook + Jeffrey's directives`, not from a separate arc spec.

### Shape 5 — In-PR review correction (operational layer)

PR #8979 review comments themselves (cited above). Jeffrey corrects the LLM's prompt-engineering directly via PR review, not via a separate `/arc` command. The fix lives in the prompt file as a rule, not in a runtime data structure.

## Cross-campaign constants Jeffrey never varies

These appear in **every** bible sampled (BG3 v3/v4/v5, Warcraft 3, Tyranny, Sanguine Architecture, Aevum Chronicler):

- **MBTI typing on every named NPC** — never optional.
- **Defining-moment trauma for every named NPC** — six-tier character architecture.
- **One concrete first-contract / first-mission sentence** in the seed prompt.
- **"Let me explicitly agree" gate on every time-skip** — the LLM proposes, the player disposes.
- **Freeform slot on every rank pivot** (Aevum Chronicler Layer 2: MOVE UP / LATERAL / OUT / FREEFORM).
- **Atlas / Bible over LLM improvisation** — `CANON-PRIORITY` is a user-locked rule (see Aevum Chronicler Layer 0).

## Recurring lexical anchors

Pattern-match on these tokens when a god-mode arc-intro is being parsed:

| Anchor | Meaning |
|---|---|
| "introduce" | declare new arc / quest / sub-arc |
| "begin" / "begin phase one" / "begin now" | activate an already-declared arc |
| "full autonomy" | LLM is free to improvise details |
| "Project [CODENAME]" | named strategy / arc |
| "let me explicitly agree" | time-skip / major-state-change gate |
| "remember what we discussed" | companion-arc continuity rule |
| "advance the arc" | `phase` / `progress` may change |
| "phase forward" | `phase` bump, not a new arc |
| "named moment" / "lore anchor" | canon-pin a specific event |
| "Year X of Y" / "the [event] is canon" | pin a timeline anchor |

## Empirical compliance signature (verified 2026-08-16 PR #8979)

When the prompt framework correctly handles a god-mode arc injection:

- ✅ `companion_arcs.<name>.progress` advances 1+ step on the next state update.
- ✅ `companion_arcs.<name>.phase` may bump (development → crisis → climax).
- ✅ `phase` advances **without** a `rest_taken` emission.
- ✅ `last_location` does not change.
- ✅ No `scene_event` / `time_sensitive_event` / Unforeseen Complication fires.
- ✅ God-mode injection is **accepted mid-scene** without a hostile transition.

When it fails (forbidden pattern):

- ❌ Transition that refuses `>>>god-mode<<<` input mid-dialog.
- ❌ Hard "no arc progression" rule that blocks `phase` advancement.
- ❌ Sanctuary gate that locks out god mode.
- ❌ Arc-intro that requires `{phase, hooks, callbacks}` schema from Jeffrey.

## Pitfall — raw `>>>God` tokens stripped during ingestion

When Gemini / ChatGPT transcripts are ingested into the llm-wiki source folder, the literal `>>>god-mode<<<` / `>>>God` toggle tokens are **stripped or rewritten** by the LLM curator. Therefore `grep -E '>>>God|godmode'` against `~/llm_wiki/wiki/sources/*-god-*` returns zero matches even though the underlying transcripts contain them.

**Fix when mining god-mode history:**

1. **Raw chat exports first** — search the 13K-line files like `2026-08-04-aizen-god-campaign.md` for `god.?mode`, `godmode`, `enter god`, `switch.*god`, `change.*god`, `turn.?on.?god`, `god.?mode.?on`, `god.?mode.?off` (case-insensitive). Line 5260 of that file is the canonical single-invocation arc-intro.
2. **Wiki summaries second** — they capture the *result* of god-mode (faction changes, NPC loyalty deltas) but not the literal directives.
3. **Session DB third** — the most faithful verbatim quotes (like PR #8979 review comments) come from `session_search(query='"god mode" arc introduce')` against the Hermes session DB. The raw tokens survive there because the messages are stored un-curated.
4. **Roadmap fourth** — `~/roadmap/<date>-slack-thread-roadmap.md` captures PR-review threads with the verbatim PR comments and rule patches.

## Implication for prompt frameworks

| Rule | Rationale |
|---|---|
| Honor freeform prose as the canonical arc-intro shape. | Shapes 1, 3 are dominant. |
| Default to single-invocation arcs with one in-flight directive. | Shape 1 is most common; Shape 2 is the cap. |
| Keep phase/hook/callback generation on the LLM side. | Jeffrey does not author them (no example in 11+ bibles). |
| Pattern-match on the lexical anchors above. | Tokens are stable across campaigns. |
| Respect "let me explicitly agree" gates on time-skips / rank transitions. | Cross-campaign invariant. |
| Never forbid `companion_arcs.progress` / `phase` from a god-mode injection. | PR #8979 corrected this rule. |
| Never require arc pre-declaration in the bible before play begins. | Arcs are introduced mid-play, not pre-scripted. |
| Treat god-mode as orthogonal to character-mode beats. | PR #8979 verbatim rule. |

## Cross-references

- `wa-prompt-only-sanctuary-dialog-opportunities` — the PR #8979 sister skill; rest-anchored dialog contract.
- `wa-planning-block-choice-contracts` — UI choice layer that pairs with these god-mode arcs.
- `campaign-design-rpg-bible` rules #2 (no-endings), #11 (no-hardcoded-engine-presets).
- `mvp_site/prompts/living_world_instruction.md` — the file that receives the god-mode-arc progression contract.
- Session: `@session:default/20260816_201635_823543eb` — the canonical PR-review thread that codified these rules.