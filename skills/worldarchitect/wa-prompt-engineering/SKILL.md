---
name: wa-prompt-engineering
description: "WA prompt audit, edit, compress. Arc scaffolding gaps."
tags: worldarchitect, prompts, audit, compression, sampling, root-cause, arc
related_skills:
  - wa-planning-block-choice-contracts
  - wa-prompt-only-sanctuary-dialog-opportunities
  - wa-llm-output-emission-false-green-watchdog
metadata:
  hermes:
    related_skills:
      - wa-planning-block-choice-contracts
---

# WorldArchitect.AI Prompt Engineering

Class-level umbrella for engineering work on `mvp_site/prompts/`. Three signals fire this skill:

1. User reports *"the LLM doesn't follow [arc / quest / scaffolding] rules even though some exist"*
2. User says *"the prompts are large, can we compress some"*
3. User asks for a new protagonist / main-character arc / named-entity scaffolding layer

Skip if the work is on the **UI choice-contract layer** (`planning_block.choices` injection, modal-skip carve-outs, `level_up_review`-shaped opt-ins) — that's `wa-planning-block-choice-contracts`. Skip if the work is on a **specific rest-anchored dialog rule** — that's `wa-prompt-only-sanctuary-dialog-opportunities`.

## The sovereignty rule

Before any prompt or prompt-adjacent change, ask **three questions in series**:

1. **Is the concept already declared?** Run the four-category inventory framework (see `references/wa-four-category-prompt-framework.md`). If the rule exists in DECLARATION form, the failure is structural (token-budget decay / cadence-only-fire) not the prompt's fault.
2. **Could a player-or-campaign declarative rule replace a hardcoded engine rule?** User-locked 2026-08-14: *"I dont want this hardcoded, i want the engine to be good enough to let a player declare these rules."* If the change you're proposing is "the engine should ship a preset", refactor it as "engine exposes a primitive + the campaign declares the rule".
3. **Does the rule respect no-endings?** Per `campaign-design-rpg-bible` rule #2 (locked 2026-08-17), no race-to-end, no Canonical Ending, no Final Verdict. New narrative scaffolding that nudges toward a closed-form story is forbidden.

## Multi-PR roadmap etiquette (added 2026-08-18)

When a user proposes a multi-PR roadmap:

- Treat each PR as **independently scopeable + rollbackable** from `origin/main`.
- When the user drops one PR mid-flight, **acknowledge the drop and re-plan, do not push it back**. User explicitly dropped PR2 (parse-assertion) on 2026-08-18 — the right move was to defer, not to negotiate.
- When the user adds a new deliverable mid-flight (e.g. *"I need main-character arcs too"* and *"compress the prompts"*), expand the active PR's scope instead of opening a new one **iff** the additions share the same root file or are ≤300 LOC combined.
- Default proposal format: each PR lists file-by-file diff + LOC budget + test LOC budget + verification cmd + risk label (low/medium/high). On user approval, dispatch via `bash -lic 'claudem -p "<task>"' --max-turns <N>` from a clean `git worktree add -b feat/<slug> origin/main`.

## Audit-first methodology (3 parallel lanes)

When the user reports any symptom on the LLM-obeys-prompt axis — before proposing a fix, run all three lanes in parallel via `delegate_task` (3 leaf subagents). Output is the **evidence base**; patch recipes without it are speculative.

### Lane 1 — Population identification (BigQuery first, Firestore fallback)

Primary: `worldarchitecture-ai.llm_forensics.llm_payloads` with `ROW_NUMBER() OVER (PARTITION BY campaign_id ORDER BY ingested_at)` to pick representative turn slots. Save query at `scripts/sample_wa_compliance_turns.sql`. Fallback: Firestore via `wa-prod-data-query`. Save literal parenthetical campaign titles — they are the user's own diagnostic language. Output: `/tmp/wa_<concept>_over_<threshold>.json`.

### Lane 2 — Prompt surface inventory + four-category classification

```bash
grep -rn -iE "<concept>|<related-concept>" mvp_site/prompts/ mvp_site/agent_prompts.py \
  mvp_site/narrative_response_schema.py | rg -v 'arcana|archmage|archives'
```

Classify each match as DECLARATION / HANDLER / OPT-IN / NOT DECLARED. See `references/wa-four-category-prompt-framework.md`. The recurring false-green: rule is DECLARATION-only or NOT DECLARED at all. For the canonical arc/quest/companion-arc map, see `references/wa-arc-quest-companion-prompt-surface-inventory.md`. Output: `/tmp/wa_<concept>_prompt_surface.md`.

### Lane 3 — Prior art / past proposals

Run `/history` (session_search), `/ms` (memory-search 9-store fan-out via `skill_view(name='memory-search')`), `/wiki-search` in parallel. Classify hits as SKILL/DOC, WIP PROPOSAL, CAMPAIGN EVIDENCE, USER DIRECTIVE. Output: `/tmp/wa_<concept>_history_hits.json`.

### Empirical compliance sampling (added 2026-08-18)

For any LLM-obeys-prompt question, sample 6 turns (`1, 5, 15, 30, 60, 100`) per flagship abandoned campaign and run regex checks against `response_text`:

| Check | Regex | Purpose |
|---|---|---|
| A | `companion_arc_event\|companion_arcs` | LLM advancing companion arcs? |
| B | `arc_milestones` + first `phase` | LLM updating primary arcs? |
| C | `scene_event.*?quest_offered\|quest_offered` | LLM offering quests? |
| D | `active_mysteries\|mystery_template` | LLM seeding mysteries? |
| E | choice count via `(?<=\[)(?:[^,]*?"id":[^,]*?,){2,}` | LLM emitting ≥3 choices? |
| F | last `"id": "(custom_action\|__custom_action__\|freeform)"` | LLM offering Freeform escape? |
| G | `len(narrative)` field | Story length per turn |
| H | `len(response_text)` | Token budget consumed |

Empirical false-green signature: **A,B,C,D all 0%, F under 5%**. The 4-category audit is the *why*; the empirical sample is the *proof*. Recipe at `scripts/wa_compliance_sampler.py`.

### Empirical structural root-cause (added 2026-08-18)

Three invariants to verify the cadence failure mode is structural:

1. **Served-prompt size**: pull one median-turn row from BQ; check the truncation footer (`TRUNCATED request_json original_bytes=<N> limit_bytes=350000`). If N > 350K the prompt is being clipped. Query at `scripts/wa_prompt_size_probe.sql`.
2. **Contract position in stack**: `grep -c "<concept>" <(bq_query_first_350K)`. If 0, the contract is below byte 350K (= past the recency window).
3. **Cadence gate**: read `mvp_site/agent_prompts.py:build_*_instruction()` methods. Find the conditional that returns `""` and verify whether the cadence reminder fires on non-trigger turns.

Verified worked example (2026-08-18, Nocturne BG3 campaign): **0/401 turns emitted `companion_arc_event`** despite a 61KB contract being present because (a) file landed at byte ~700K of 1,022K (bottom 25%) and (b) cadence reminder gated to LW trigger turns only.

## Prompt compression profile (added 2026-08-18)

When the user reports "the prompts are large", run a four-step profile:

**Step 1 — Size distribution.** Top-5 files are typically **~49% of total bytes** (~430KB of 909KB). Target that list. Recipe at `scripts/wa_prompt_size_profile.sh`.

**Step 2 — Duplication fingerprinting.** 80-char normalized whitespace fingerprints across all prompts. Typical real pairs:
- `mechanics_system_instruction.md` ~99% duplicate of `_code_execution.md` (only dice strategy differs).
- `game_state_examples.md` has a 150-char fragment that's also in `game_state_mechanics_appendix.md`.

Use a shared leaf + `{{PROMPT_INCLUDE:...}}` to dedupe. Recipe at `scripts/wa_prompt_dedup.py`.

**Step 3 — Rule vs reference classification.** For each top-5 file: count rule lines (`MUST|MANDATORY|🚨|CRITICAL|HARD INVARIANT|REQUIRED|🚫|⚠️`) vs code/example lines (inside fenced blocks — most are long JSON examples). The typical pattern: **35–46% of the top-5 files is JSON example content the LLM rarely echoes verbatim**. Server-side schema validators enforce shape. Reference data the LLM doesn't echo verbatim is a compression candidate.

**Step 4 — Include chain analysis.** `{{PROMPT_INCLUDE:path}}` handling is at `mvp_site/agent_prompts.py:807-853`. Check which `shared/*` files have **zero** `{{PROMPT_INCLUDE}}` references — orphaned/dead-code candidates. **Verify by grepping `agent_prompts.py` first** — some are referenced via conditional path, not `{{PROMPT_INCLUDE:...}}` placeholder. Recipe at `scripts/wa_prompt_includes.py`.

### Compression decision matrix

| Action | Bytes saved | Difficulty | Risk |
|---|---:|---|---|
| Collapse `mechanics_system_instruction.md` ↔ `_code_execution.md` (99% duplicate) via `{{PROMPT_INCLUDE:shared/dice_code_execution.md}}` | ~4KB + halves cache-key space | low | low |
| Delete orphaned `shared/banned_names_instruction.md` + `shared/rag_output_contract.md` (only if verified dead) | ~750B | low | low |
| Extract JSON examples in `game_state_instruction.md` L1570-L2050 → `shared/state_updates_examples.md`, first-turn-only | ~30KB | medium | medium |
| Extract per-action JSON in `faction_minigame_instruction.md` (46% of file) → `shared/faction_action_examples.md` | ~30KB | medium | medium |
| Extract 3x-duplicated `companion_arc_event` JSON in `living_world_instruction.md` → `shared/companion_arc_event_example.md` | ~3KB | low | low |

**Cache-fragmentation priority:** the biggest prompt-cache win is **reducing distinct prompt-prefix variants**, not raw byte reduction. A 99% duplicate file pair produces two prompt-cache keys; collapsing to one halves the variant space.

## Orthogonal prompt-injection vs agent-subclass (added 2026-08-19)

When the user says *"[X] shouldn't be its own agent — it should just always include the instructions in every time-progressing agent"*, the right move is a PROMPT_TYPE + REQUIRED_PROMPT_ORDER change across N agents, NOT a new routing target. Concrete pattern (verified 2026-08-19 on DeferredRewardsAgent in `mvp_site/agents.py:2667-2780`):

**Decision rule.** A new agent subclass is the wrong shape when the only thing it adds over its parent is one extra `PROMPT_TYPE_*` in `REQUIRED_PROMPT_ORDER`. Subclasses are for *new LLM behavior under a different mode*; orthogonal prompt-injection is for *the same behavior visible to every active agent*.

**Five-step recipe (verified):**

1. **Identify the parent → child inheritance that is really just a prompt-set diff.** `class DeferredRewardsAgent(RewardsAgent):` — only `REQUIRED_PROMPT_ORDER` changed (added `PROMPT_TYPE_DEFERRED_REWARDS`). Same `MODE`, same routing, same LLM contract.
2. **Enumerate the time-advancing agents that should carry the prompt.** Use `_MODE_ADVANCES_TIME_CACHE` (`agents.py:5271-5286`) as the canonical filter. Time-advancing agents per the cache: StoryMode, Dialog, HeavyDialog, Combat, CampaignUpgrade, Faction, Spicy. Non-time-advancing (GodMode, Planning, Info, CharacterCreation, LevelUp, Rewards) opt out.
3. **Add the PROMPT_TYPE to every targeted agent's `REQUIRED_PROMPT_ORDER`.** Each tuple is the source of truth for loading order — obey `mvp_site/prompts/AGENTS.md` Hard rule 4 (one rule, one authoritative file). If the prompt file already exists (`mvp_site/prompts/<feature>_instruction.md`), just add it to the order tuple. No body edits.
4. **Delete the subclass and its routing references.** Remove from `ALL_AGENT_CLASSES`, remove `_semantic_<feature>` resolver, remove `<FEATURE>` mode branch from `_resolve_explicit_mode`, remove `_MODE_ADVANCES_TIME_CACHE` entry for the mode (keep the PROMPT_TYPE constant — it's still referenced by the agents that load it).
5. **Delete the cadence gate.** When the prompt moves from "load every N turns" to "load always", drop `should_include_*()` from `agent_prompts.py` and remove the `turn_number % N == 0` check.

**Pitfall: don't delete the prompt body.** The prompt file stays; only its gating logic dies. The LLM needs the contract on every turn, not every Nth.

**Pitfall: don't add to non-time-advancing agents.** Loading a prompt into GodMode/Planning/Info dilutes the served prompt of agents that should be terse. Filter by `_MODE_ADVANCES_TIME_CACHE` membership — that is the canonical set.

**Concrete cost shape (measured 2026-08-19, `deferred_rewards_instruction.md`):** 201 lines / 8,366 bytes / **~1,962 tokens (cl100k_base)**. Always-loading across 7 time-advancing agents adds **~13,734 tokens/turn total** to the served prompt. For comparison, `rewards_system_instruction.md` (722 lines) is 7,014 tokens. If the always-on cost feels too high, use the §"Prompt compression profile" below + consider gating the long-form version to a subset (Story + Spicy only, where missed-rewards is most likely) and always-loading a short ~300-token dedup summary across the rest.

**Behavioral verification: do normal agents follow the rule?** Mixed signal — `mvp_site/tests/test_prompts.py:201-212` pins prompt-presence but not behavior. The recurring false-green: deferred XP double-emit (issue #8088) shows the LLM does NOT reliably follow the dedup rule when it's only loaded intermittently. Always-loading should help, but the worker MUST add a behavioral test that fires through the full stack with a real LLM (`testing_mcp/`) and asserts no double-emit. Prompt-presence is supporting evidence, not proof.

## Routing-resolver priority ordering (added 2026-08-19)

The `_ROUTING_RESOLVERS` tuple at `mvp_site/agents.py:5165-5183` is the canonical priority chain. When the user says *"combat should be higher priority than rewards"* or *"X sometimes triggers when it should be Y"*, the work is re-ordering this tuple + tightening the guard conditions on the resolver that wins too eagerly.

**The 4 invariants:**

1. **The tuple order is the priority order.** First non-None resolver wins. The docstring at `agents.py:5198-5220` MUST match the tuple order — out-of-sync docs are a recurring false-green.
2. **Modal-locks (level-up, character-creation, god-mode) win over state-based agents.** They appear first in the tuple because a modal owns the planning block; routing around them corrupts the modal flow (PR #8489 regression class).
3. **State-based agents (combat, rewards) check `matches_game_state()` BEFORE the classifier runs.** If `in_combat=true`, CombatAgent wins without asking the classifier — that's why it's at position 10, before `_resolve_semantic_classification` (position 11).
4. **The fallback (`_resolve_*_fallback`) runs LAST.** It exists to catch classifier-misfires, NOT to override state-based wins. If a fallback is overriding a higher-priority state, the fix is *tighten the fallback's guard condition*, not delete the fallback (genuine state-based rewards still need it).

**The 3 standard changes when promoting an agent above another:**

1. **Split the resolver.** If a generic `_resolve_semantic_intent` handles both combat and rewards, split out `_resolve_semantic_combat` so its position in the chain is explicit and testable. Don't rely on internal branching order.
2. **Add a stale-flag guard.** Resolvers that match on `rewards_pending` (or any other state flag) can pick up stale data from prior turns. Add: "if `X.matches_game_state()` is True OR classifier returns MODE_X with confidence > 0.6, return None" so the chain falls through to the dedicated X resolver.
3. **Tighten `matches_game_state()` for the demoted agent.** E.g. `RewardsAgent.matches_game_state()` should require `rewards_pending.source != "deferred"` so the deferred-rewards sweep doesn't block fresh combat initiation.

**Concrete fix shape for "combat higher than rewards" (verified 2026-08-19):**

| Position (before) | Resolver | Position (after) |
|---|---|---|
| 10 | `_resolve_combat_state` | 10 (unchanged — already wins over rewards at position 12) |
| 11 | `_resolve_semantic_classification` | 11 (unchanged) |
| — | — | 12. `_resolve_semantic_combat` (NEW — split from `_resolve_semantic_intent`) |
| 12 | `_resolve_rewards` | 13 (demoted) |
| 15 | `_resolve_semantic_intent` | 15 (unchanged — handles combat initiation if no state match) |

**Pitfall: don't remove `_resolve_rewards_fallback`.** It is still needed for genuine state-based rewards when the classifier misfires. Tighten its guard condition to require `not CombatAgent.matches_game_state()` so combat-active states are never overridden.

**Contract tests to add (minimum 3):**
1. `test_<X>_priority_over_stale_<Y>_pending`: stale Y-flag in state + fresh user input "I do X" → X wins.
2. `test_<X>_priority_over_semantic_<Y>`: ambiguous classifier → MODE_X with high confidence wins over MODE_Y.
3. `test_<Y>_fallback_does_not_override_active_<X>`: X-active state → Y fallback returns None.

**Pre-existing-PR check.** Before designing the resolver change, run `gh pr list --search "<X> in:title,body"` and check for prior attempts. The 2026-08-19 combat-priority work hit PR #8319 ("8022 combat agent not activating") and issues #8022, #8899 — three prior attempts. Read them for context; do NOT cherry-pick (your branch is from `origin/main`); just absorb the lessons (e.g. #8319 found classifier-anchor mismatches that the new guard logic should also handle).

## PC arc / protagonist-arc pattern (added 2026-08-18)

When the user says *"I need main character arcs for myself"* or *"add an arc for the player"*:

**Reuse the companion_arcs contract 1-for-1.** The shape `{arc_type, phase, progress, callbacks, history}` works for a single PC as-is. The 8 arc types + 4 phases + 6 event_types are generic enough to cover a protagonist arc.

Differences from companion:
- **Storage**: single key. `custom_campaign_state.pc_arc = {arc_type, phase, progress, callbacks, history}`.
- **Output**: `pc_arc_event` mirrors `companion_arc_event`, **minus** `companion_dialogue` (LLM doesn't voice the PC) **plus** `pc_internal_monologue` (1-sentence voice line drawn from known personality seeds).
- **Anti-mandate**: mirror `shared/no_forced_ruler_progression.md` — no forced "destined hero" / prophecy / inherited rival arc unless player has accepted.

Patch surface:
1. **NEW** `mvp_site/prompts/player_character_arcs.md` (~6.5 KB) — full contract.
2. **NEW** `mvp_site/prompts/injection/pc_arc_cadence.md` (~1.2 KB) — cadence reminder.
3. `mvp_site/prompts/master_directive.md` — add new file to loading hierarchy.
4. `mvp_site/agent_prompts.py` — mirror `arc_context` injection for PC arc on LW trigger turns + unconditional cadence (per the lift pattern in §Audit-first methodology).
5. `mvp_site/game_state.py:2383-2403` — init `custom_campaign_state.pc_arc = {}` + `next_pc_arc_turn` counter.
6. `mvp_site/tests/test_prompts.py` — TDD contract tests (~30 lines).

LOC: ~245, similar to the companion_arcs patch surface from PR #8979.

## Server-computed candidate scope prevents LLM invention (added 2026-08-19)

When the user reports *"the LLM invents [enemies / factions / units / NPCs / items / locations] that don't exist in the world"* — a class of bug that recurs across companion_arcs, faction_roster, npc_data, item catalogs, and named-entity prompts — the fix is **NOT** a stronger "do not invent" instruction. The structural fix is to make invention **impossible**, not just discouraged.

**Pattern (verified 2026-08-19 brainstorming session, design at `projects/worldarchitect.ai/docs/plans/2026-08-19-archmage-mode-living-world-design.md`):**

1. **Server-computed candidate set.** A pure-Python function reads canonical state (e.g. `faction_roster[]`, `npc_data[]`, `item_catalog[]`) and returns the filtered list of valid IDs the LLM is allowed to act on. Filter criteria depend on context:
   - **Proximity** — entities in the same `in_game_location` as the player, or within N hex hops.
   - **Relevance** — entities named in recent `world_events[]` or referenced in the player's last M actions.
   - **Soon-to-be-discovered** — entities with `pending_event.estimated_discovery_turn <= current_turn + N`.

   The selector is **pure data filtering on canonical state** — no regex, no keyword matching, no semantic classifier, no LLM in the loop. This is ZFC-compliant because the server is just reading and filtering, not making a judgment call. Compare with `mvp_site/living_world_contract.py:strip_lw_fields_from_mapping` and `is_cooldown_turn()` (lines 46-58) — same pattern, same ZFC status. The project AGENTS.md already accepts that shape.

2. **Expose the candidate set as a tool result.** New tool `world_sim_list_candidate_factions({campaign_id, in_game_location})` returns the filtered IDs as JSON. The LLM may only call downstream tools (`world_sim_propose_action`, `narrate_event`, etc.) for IDs in this set.

3. **Server-side validation rejects off-list IDs.** If the LLM emits a tool call referencing a faction / NPC / item not in the candidate set, the tool router returns `{error: "ID not in candidate set"}` and writes nothing. The LLM learns on the next turn (or, with structured output + schema validation, never emits off-list IDs in the first place).

4. **Strict JSON schema for the LLM call.** Pair the tool-set restriction with `response_json_schema` (NOT bare mime type — bare mime type allowed the `FinishReason.TOO_MANY_TOOL_CALLS` infinite-loop signature we caught on PR #8673). The schema's `enum` field is the candidate ID list.

**Why this beats prompt-only fixes:**

| Approach | LLM invents? | Server validates? | Structural? |
|---|---|---|---|
| Stronger "do not invent" prompt | Sometimes | No | No |
| Regex-blocklist of "X is forbidden" | Sometimes | Yes, but false-positives | No |
| Parse-assertion post-hoc check | Sometimes caught | Yes, but late | No |
| **Server-computed candidate scope** | **Structurally impossible** | **Yes, at emit time** | **Yes** |

User-locked 2026-08-19 (campaign `ArYA47Fvx8HTYC8jpleO`): *"It should be acting like I am playing the 1999 archmage game and all factions and characters must follow the same physics aka rules of the universe versus the LLM invents whatever is narratively interesting which doesn't feel real."* The candidate-scope pattern is the answer to this exact complaint.

**Reuse existing FACTION_TOOLS — do not invent a parallel `validator.py` / `deterministic_rules.py`.** `mvp_site/faction/tools.py` already exposes 5 tool-calling definitions + `execute_faction_tool()` router, mirroring `mvp_site/dice.py` (the canonical pattern in this repo). New behavior that fits "LLM decides X, server computes Y, server writes state" should ADD tools to the same shape, not introduce a parallel `validator.py` / `deterministic_rules.py` set. Operator lock 2026-08-19: *"Lets also use /cs and make sure we refactor/reuse the existing faction management code. I believe it does tool calling for calculations and not code execution, we should reuse/refactor that."* When in doubt, mirror `mvp_site/dice.py`'s shape: `DICE_ROLL_TOOLS` list + `execute_dice_tool()` handler.

**Multi-PR clustering on this pattern (verified 2026-08-19, operator preference).** When the brainstorming protocol proposes N parallel PRs (e.g. 3 PRs: stale-events fix + tick engine + prompt-roster contract), the operator may collapse to 1 PR mid-flight (*"lets put all 3 PRs into one"*). Treat this as a normal flow-control signal, not a contradiction: update the design doc's rollout section to the 1-PR shape immediately, keep all the audit gates, no need to re-pitch the split. The user knows the operational cost; respect the call.

## Pitfalls

- **Don't bypass the audit when the user asks for a single fix.** Even for "just add a planning_block opt-in for new goals", start with the prompt surface inventory for the concept class.
- **Don't propose a fix without the empirical sample.** Compliance data is the only thing that disambiguates "LLM ignores the rule" from "LLM has no rule to ignore".
- **Don't move obligation rules to a 99%-duplicate file pair.** Always make the compression goal explicit.
- **Don't trust the `PROMPT_INCLUDE` chain map blindly.** Grep the Python surface first before declaring a shared file orphaned.
- **Don't mistake `arcana` for `arc`.** Grep noise filter must include `arcana|archmage|archives` exclusions.
- **Don't promote an LLM-side rule to a server-side rule without the parse-assertion cost.** User explicitly rejected the parse-assertion layer on 2026-08-18.
- **Don't `grep >>>God` against `~/llm_wiki/wiki/sources/*-god-*`** and conclude "no god-mode history". LLM ingestion strips the literal `>>>god-mode<<<` tokens. For verbatim arc-intros, mine raw chat exports (line 5260 of `2026-08-04-aizen-god-campaign.md` is canonical), session DB PR-review threads (`@session:default/20260816_201635_823543eb`), then roadmap threads. See `references/wa-godmode-arc-intro-pattern.md`.
- **Don't refuse `>>>god-mode<<<` input mid-scene.** PR #8979 corrected this: god mode is orthogonal to character-mode beats. `companion_arcs.<name>.progress` and `phase` MAY advance from a god-mode injection; only combat / physical-world movement is forbidden. See `references/wa-godmode-arc-intro-pattern.md`.
- **Don't invent a new "validator" module when the existing FACTION_TOOLS / DICE_ROLL_TOOLS pattern fits.** Add new tool definitions to the existing `mvp_site/faction/tools.py` (or a sibling with the same shape) and route through `execute_faction_tool()`. Server-side validation belongs in the tool's branch, not a separate `validator.py` that regex-checks LLM output.
- **Don't ship a half-migration with a "SUPERSEDED" stub.** When rewriting a stat block / XP table / god-mechanics contract, the new authoritative values must REPLACE the legacy values — never coexist with a "do not use this table" annotation. Verified 2026-08-19: PR #8511 (Mythic Tier XP framework, L26 = 655,000) was closed-not-merged because it left the legacy exponential L26 = 501,050 table in place with a `> **SUPERSEDED**` callout. The LLM will pattern-match the first concrete number it sees, which is whichever table sits higher in the file. Delete the legacy block outright; if archaeology is required, move it to `world_reference/` with a date stamp, not the canonical prompt.
- **Don't assume `/X-standards` slash commands exist just because the user says "run /X-standards".** WorldArchitect.AI's `.claude/commands/` has 80+ command files (see `.claude/commands/CLAUDE.md` for the canonical index), but the user often uses these names as verbal aliases for higher-level concepts, not literal slash commands. Before pivoting on a user-typed `/X-standards`, run the **four-location lookup** in this priority order:
  1. **Global user-scope** — `~/.claude/commands/` and `~/.claude/skills/` (e.g. `/document-standards` lives at `~/.claude/commands/document-standards.md` with the rubric at `~/.claude/skills/document-standards/SKILL.md`). User-scope commands are the FIRST place to look — the user types these names because they exist in their global toolkit, not the repo.
  2. **Repo-local** — `.claude/commands/` and `.claude/skills/` inside the active repo.
  3. **Hermes-side overlay** — `~/.smartclaw/skills/` (Hermes-curated wrappers that forward to the canonical Claude skill).
  4. **Hub-installed** — `ls ~/.agents/skills/` and any `skills.external_dirs` (last resort, often deprecated).

  If the command is only found at (1) or (3), the right move is to **load both the dispatcher `.md` and the rubric `SKILL.md`** before suggesting the user "did not name a real command." Locked 2026-08-19: user invoked `/document-standards` on `mvp_site/prompts/divine/` and the agent searched only `.claude/commands/` (repo-local), found nothing, and invented a 4-option clarification menu. The command actually exists at `~/.claude/commands/document-standards.md` with a 5-lane rubric at `~/.claude/skills/document-standards/SKILL.md`. The user pointed this out explicitly: *"read it form ~/.claude and add a reminder soul Md or an appropriate file to always check there"*.

  **Companion rule (verified 2026-08-19, SOUL.md `## COMMIT: document-standards-check-on-prose-revision`):** when the user finds a missing-from-repo cmdlet that lives globally, add a SOUL.md `## COMMIT:` referencing the exact global path AND the canonical-skill path. The SOUL.md COMMIT is the durable fix — next-session agents already know to look there before asking. The agent must run `bash -c 'find ~/.claude ${HOME}/.claude -maxdepth 5 -iname "<name>*" 2>/dev/null'` BEFORE asking the user "what did you mean by X?"
- **Don't carry version suffixes (`V3`, `V13`, `v2`, `HUD v13.0`) in prompt body text or headings.** The user explicitly removed all versioning on 2026-08-19 ("Remove all the versioning and references to old version"). Versioning in prompt text is a recurring antipattern when the prompt has been through multiple PRs (#8488 V2→V3, #8511, #8564 compaction) — the body accumulates `V3.18`, `V3.13`, `V3.2`, `V3.3` annotations that have no contractual meaning. Random suffix anchoring increases LLM confusion and contradicts the "one source of truth" rule. If versioning is needed for prompt-cache stability, use a single version tag at the top of the file (`<!-- contract version: 4 -->`) and reference it in `prompt_tool_contracts.json` — never inline `V3.13` next to a rule.
- **Don't ship a prompt that has accumulated an action-tier combat system (AT-0/1/2/3 ladder, per-dawn menu, god-hunt chain, Atelier/archetype section) without the user explicitly asking for it.** Verified 2026-08-19 on `divine_leverage_system.md` round 2: the round-1 PR #9151 shipped the full action-tier system inherited from #8488 (V2→V3), expanded with dawn-menu templates, AT-3 cap formulas, god-hunt chains, and per-archetype optimization examples. The operator rejected the entire compartment mid-session: *"Whats this AT-3 stuff? I am not sure about this action tier stuff"*. The user wants free-form action resolution (LLM describes action, canonical Tier table resolves cost and effect), NOT a per-dawn menu. The pattern generalizes: any combat-action prompt that has accumulated a dense action-tier economy over multiple PRs is at risk of being wholesale-rejected. Detect early — `grep -E "AT-[0-3]|dawn menu|Atelier|god-hunt"` — and propose the simplification BEFORE the user asks. See `references/wa-prompt-divine-simplify-2026-08-19.md` for the full conversion table and the verified deletion recipe.
- **Don't default to `HIDDEN` for everything the player owns.** The user's 2026-08-19 visibility rule: **DHP/DAC/DAIR/F are VISIBLE** (player's own stats), **D per-faction / PS are HIDDEN** (others' perception). The old `divine_leverage_system.md` marked DHP/DAC/DAIR/F as HIDDEN with the rationale "lowest stat-block at L21+" — that's wrong. The single rule: "Things the player IS aware of are visible (quantifiable). Things the player is NOT aware of — primarily reputation / how others perceive them — are hidden (narrated but not quantified)." The Tier table MUST mark each column **visible** or **hidden** explicitly; the visibility flag is part of the contract.
- **Don't ship a "consolidated L26 stat block" alongside a separate Tier table.** When the user sends a Tier table with N tiers × M columns, the SINGLE canonical home is the Tier table. Don't ship a separate "L26 stat block" plus a Tier table — that's two sources of truth for the same data. Collapse them. The Tier table is the generalization of the L26 stat block pattern.
- **Don't absorb follow-up feedback into a NEW PR when the follow-up is a same-file rewrite.** Verified 2026-08-19 on PR #9151: round 1 de-framed deception + ported Mythic Tier + consolidated L26 + dropped version suffixes (1 PR). Round 2 dropped AT-3 + canonical Tier table + 300-line target (force-pushed a 2nd commit to the same branch, added PR comment). The right move is **round-trip on the same branch** — the reviewer sees the diff against round 1's HEAD, not against origin/main. Splitting into 2 PRs would have produced a "draft PR that supersedes the previous PR" pattern, which is the stop-halfway anti-pattern. Use `scope-split-on-redirect` (SOUL.md) when the feedback is a COMPLETELY DIFFERENT concern (e.g. "also fix the dice audit" on a PR about divine prompts).
- **Don't ignore the user's "should be like N lines" target.** When the user says "should be like 300 lines", the contract test pins `<= N + 50` (small margin = 350), NOT `<= N * 2` (= 600, too lenient). The user wants short, canonical prompts; the test is the proof. See `references/wa-prompt-divine-simplify-2026-08-19.md` for the verified 981→300-line decision matrix.

## Migrating a long-stale prompt (added 2026-08-19)

When the user wants to **rewrite a divine/cosmic-tier prompt** that has accumulated decade-long contradictions (multiple "V3.X" annotations, legacy XP tables, "Superseded" callouts, frame naming that's too thematic for the contract), the work is **NOT** a wholesale rewrite — it's a **migration with strict qualifying rules**. Verified failure pattern from PR #8511 (Mythic Tier XP framework, 254 files / 6322+ / 71241-, never merged): the worker tried to land everything in one branch and the diff was too large to review.

**Four qualifying rules for "this prompt migration is in scope":**

1. **The user's request names a specific symptom.** Examples: *"the LLM still says L26 is 501,050 XP"*, *"the prompt is all about deception, not the actual mechanics"*, *"L26 doesn't have a stat block"*. If the user names no symptom, the migration is speculation — go back to the audit-first methodology.
2. **The migration outcome is single-source-of-truth.** ONE canonical XP table (not two with annotations), ONE framing (deception-to-stewardship, not "and sometimes also"). The previous PR's left-behind artifacts must be **deleted** (or moved to `world_reference/<date>-<topic>.md` for archaeology), never annotated as "do not use".
3. **The diff is bounded to <300 LOC across ≤3 prompt files plus 1 contract test.** Anything larger is a re-architecture, not a migration. Reference points: PR #8511 hit 3916 LOC across 19 files — too large, never merged. PR #8564 (compact divine prompts) hit +174/-360 across 3 files — merged. The 254-file delta in #8511 came from a rebase-induced test-fixture rewrite, not the migration itself.
4. **Backwards-compat is preserved via `progression_overrides`**, not via a parallel table. When the new framework differs from legacy (e.g. flat +50,000 XP vs exponential 1.15^(N-25)), the per-campaign override path (`custom_campaign_state.progression_overrides`, god mode `directives.add`) is the migration seam, not a comment in the prompt.

**Five-step migration recipe (verified 2026-08-19):**

1. **Identify the single source of truth.** The new XP / stat / framing must have ONE canonical location. Promulgate a `## WorldAI Mythic Tier XP Framework` (or equivalent) section with the formula + worked examples table. Worked examples MUST include the boundary case the user named (L26 in the canonical case).
2. **Delete the legacy table.** Use `sed -i '/^  26  *501,050/,/^  50  /d' <file>` (or equivalent range-delete) to remove the contradictory block. If archaeology is required, write the legacy values to `world_reference/legacy-<feature>-<date>.md` with a date stamp and a one-line "superseded by <PR-link>" footer.
3. **Clean version annotations.** Strip `V3.18`, `V3.13`, `V3.2`, `V3.3`, `V13.0`, `HUD v13.0`. If versioning is needed for prompt-cache, set `<!-- contract version: N -->` at the top of the file and reference in `prompt_tool_contracts.json`. Body text should never carry version suffixes.
4. **Rewrite the framing.** If the user says *"X is too much about Y"* (e.g. *"all about deception"*), rewrite the central tension in the new frame. The new frame must be PRESENT, not just "de-emphasized" — diminishing the old frame just leaves two competing frames.
5. **Add a contract test.** Single small test (~30 lines), fast (no-LLM, no-network), pins the canonical values (L26 = 655,000 XP, no `deception` substring in prompt, no `V3.X` suffix). The test is the migration proof.

**Pre-PR closed-PR audit.** Before dispatching, run `gh pr list --search "divine OR leverage OR myth OR deception in:title" --state all --limit 30` and read the bodies of any closed-but-not-merged PR that touches the same file. The lessons are usually explicit in the body — PR #8511's body literally says "was closed-not-merged because it left the legacy exponential table as a 'SUPERSEDED' stub" — and the worker that wants to succeed must NOT recreate the same mistake.

Concretely bounded scope for the 2026-08-19 divine-truth-26 work: 1 prompt file (`mvp_site/prompts/divine/divine_leverage_system.md`), +300/-200 LOC, 1 contract test file (`mvp_site/tests/test_divine_mythic_tier_8511.py` reused or rewritten). No new world_reference/ design docs unless the user explicitly asks for one. No companion-arc changes. No propagated changes to `master_directive.md` / `narrative_system_instruction.md` / `game_state_instruction.md` — those are separate contracts.

**User posture for "rewrite two prompts" tasks (verified 2026-08-19).** When the user lists multiple orthogonal asks for a prompt rewrite (e.g. *"rewrite both files"* + *"consolidate stats into one block"* + *"drop version suffixes"* + *"delete legacy table"*), they want ONE PR that does all of them — they are NOT a 4-item clarification menu. The right move is to (a) acknowledge the four asks in the brief, (b) restate them as four numbered sub-tasks in the worker's task spec, and (c) ship a single PR that sweeps all four. Splitting into 4 PRs mid-flight because "each is independently scopeable" is wrong — the user's intent is a coordinated rewrite, not a stack. The bounded-scope rule still applies (≤3 prompt files + 1 contract test), but the four asks are cooperative, not additive.

## Simplify-to-target-line-count (added 2026-08-19)

When the user says *"the prompt is too long, should be like N lines"* and provides a numerical target, the work is **deletion-driven simplification with a line-count gate**, not a refactor. The verified recipe from PR #9151 round 2 (operator thread `C0AH3RY3DK6/p1787198080.185779`):

**The 5-step recipe:**

1. **Run the 5-lane `/document-standards` rubric on the current branch HEAD.** Truth & contract, Economy, Readability, Thermo-style audit, Output. Capture findings in the PR body, not just the diff.
2. **Build a deletion decision matrix.** For each section in the file, mark KEEP / DROP / COLLAPSE. The matrix is the audit. Total target = N lines.
3. **Apply the visibility-rule asymmetry** (NEW canonical rule): "Things the player IS aware of are visible (quantifiable). Things the player is NOT aware of — primarily reputation / how others perceive them — are hidden (narrated but not quantified)." DHP/DAC/DAIR/F → visible. D per-faction / PS → hidden. Don't mark player's own stats as HIDDEN.
4. **Replace scattered stat blocks with a single canonical Tier table.** N tiers × M columns, with visibility flags per column. One source of truth.
5. **Pin the line-count in the contract test.** `assert len(text.splitlines()) <= N + 50`. Small margin, not 2×.

**The verification pattern** (already in `references/wa-prompt-divine-simplify-2026-08-19.md`): three contract test additions — (a) prompt drops the deleted-sub-system vocabulary, (b) Tier table is present with N rows, (c) file length is at most N + 50 lines.

**The round-trip pattern**: when the user sends follow-up feedback mid-PR that requires a same-file rewrite (e.g. *"drop AT-3, add the Tier table, simplify to 300 lines"*), force-push a 2nd commit on the SAME branch and add a PR comment. Do NOT open a new PR — the reviewer sees the diff against the previous round's HEAD, not against origin/main. Splitting into 2 PRs produces a "draft PR that supersedes the previous PR" pattern, which is the stop-halfway anti-pattern.

**The "drop the action-tier system" anti-pattern** (verified 2026-08-19): action-tier combat systems (AT-0/1/2/3 ladder, per-dawn menu, god-hunt chain, Atelier/archetype section) accumulate over multiple PRs and become the user's primary complaint. Detection: `grep -E "AT-[0-3]|dawn menu|Atelier|god-hunt"` on the prompt. The fix is to **delete the entire compartment** and replace with free-form action resolution (LLM describes action, canonical Tier table resolves cost and effect). Do NOT ship the action-tier system without the user explicitly asking for it.

See `references/wa-prompt-divine-simplify-2026-08-19.md` for the full 981→300-line decision matrix, the visibility-rule asymmetry table, the round-2 brief template, and the contract test template.

## Contract field removal with silent-compat (added 2026-08-19)

When the user says *"remove [field] from [prompt/choice/payload]"* — for a contract field like `risk_level`, `cooldown`, `deprecated_flag` — the work is **field removal with silent-compat**, not schema tightening. The inverse of the migration recipe above. Verified pattern from PR #9150 (`feat/planning-block-narrative-only`, dropped `risk_level` from planning block per user directive C0AH3RY3DK6/p1787205681.983699).

**The 4-lane pre-fix audit** (run BEFORE writing the patch):

1. **CSS audit** — if the field drives a CSS class (e.g. `risk-low`/`risk-medium`), grep all `.css`/`.scss` for the selector. If nothing matches, the class is dead code and the only "visual" change is the DOM emission. Removing the JS emitter is the structural fix; no CSS work needed.
2. **JS audit** — every `class="…<field>"` emitter must be enumerated. Mirror changes in legacy test fixtures (`frontend_v1/js/test_planning_block_parsing.js` is the canonical gotcha — it ships in the bundle and silent diverge causes test-vs-prod drift).
3. **Prompt audit** — `grep -rn "<field>" mvp_site/prompts/`. **Classify each match by surface** (planning block vs dialog vs faction vs ceremony vs god-mode). The user-scoped directive is one surface; the grep finds many. Stay in scope.
4. **Schema audit** — is the field in the JSON schema? If yes, default silent-compat: keep `Optional`, no enum tightening. Hard-delete breaks older payloads.

**The 5-step removal recipe:**

1. **Remove from LLM prompt contract** — strip the field from worked examples + schema declaration sentence. LLM stops emitting because the contract doesn't reference it.
2. **Stop emitting from JS/frontend** — remove the JS that writes the field/class/attribute. Mirror in legacy test fixtures.
3. **Keep schema silent-compat** — leave the field optional, no enum tightening. Older payloads still parse; the LLM may still emit; the frontend just doesn't render.
4. **Add a single contract test** — ~50-150 LOC, three tests: (a) prompt surface has no `<field>` word, (b) JS render has no `<field>` class, (c) schema accepts older payloads without `<field>`.
5. **Document pre-existing failures** — adjacent test battery; same-name pre-existing failures get the `qa-test-failure-dismissal-anti-pattern` treatment.

**Don'ts (verified failure modes from this PR class):**

- **Don't delete the schema field.** Older payloads + LLM may still emit it. Silent-compat is correct; hard-reject breaks history.
- **Don't touch other surfaces.** User scoped to one surface (e.g. "planning block"). Other surfaces (dialog, faction, ceremony, god-mode) are separate decisions.
- **Don't write a CSS "neutralizer" rule** like `.risk-* { all: initial }`. The class is dead code; deleting the JS emitter is the right fix.
- **Don't add a "name-it" upgrade** (e.g. don't rename `risk_level` to `danger_class`). The user wants the field removed, not refactored.
- **Don't include a CI poll loop in the dispatcher brief.** If the worker is told to "wait for CI green", it will idle for 20+ min. The brief should say "PR open + tests green = end-state; exit with PR URL." Verified 2026-08-19: PR #9150's worker ran `sleep 60/90/120/180` × 7 polling GitHub check-runs after the work was done; killed manually after 20 min of idle.

**Reference PR** — [#9150](https://github.com/jleechanorg/worldarchitect.ai/pull/9150) `feat/planning-block-narrative-only`, commit `550b28c270`, 5 files / +156/-38 LOC, 248 tests green. Path-scoped template: `_wt/feat-planning-block-narrative-only/_task.md` (the dispatch brief that drove the work).

## Cross-references

- `wa-planning-block-choice-contracts` — sister skill, UI choice-contract layer; 5-step TDD recipe.
- `wa-prompt-only-sanctuary-dialog-opportunities` — sister skill, rest-anchored dialog rules; 4-shaped rule pattern.
- `wa-llm-output-emission-false-green-watchdog` — sister skill, narrative-schema-required-fields contract tests.
- `wa-daily-dice-audit-fix` — sister skill, dice-notation audit infrastructure.
- `~/.smartclaw/skills/campaign-design-rpg-bible/SKILL.md` rule #2 (no-endings, 3-option carousel + Freeform) and rule #11 (no-hardcoded-engine-presets).
- `mvp_site/prompts/AGENTS.md` Hard rules 1-9 (prompt content contract).
- `mvp_site/agent_prompts.py:807-853` — the `{{PROMPT_INCLUDE:...}}` resolver.
- `mvp_site/agent_prompts.py:2701-2790` — the LW/companion-cadence inject path; the structural-gap evidence.

## Reference files (this umbrella)

- `references/wa-field-removal-silent-compat.md` — session detail for the contract field removal pattern (PR #9150, `risk_level` from planning block): 4-lane audit findings, 5-step recipe with LOC/time, 3-test template, and the CI-poll-loop trap.
- `references/wa-four-category-prompt-framework.md` — DECLARATION / HANDLER / OPT-IN / NOT DECLARED with detection rules.
- `references/wa-arc-quest-companion-prompt-surface-inventory.md` — the 47-file / 8-gap patch-surface map (canonical summary of `/tmp/wa_prompt_arc_surface.md`).
- `references/wa-prompt-compression-profile.md` — the canonical compression decision matrix (savings × ease × risk).
- `references/wa-prompt-bq-audit-recipe.md` — BigQuery audit recipe for "how often does X happen" questions: 3 forced steps (bypass shadowed `bq` CLI via REST + gcloud bearer, 1-capturing-group limit on `REGEXP_EXTRACT`, RE2 not supporting `{n,m}?` lazy quantifiers), canonical UC log-line patterns, full working SQL.
- `references/wa-prompt-mechanic-rebalance-pattern.md` — the 5-step prompt + server-cooldown dual-edit pattern for rebalancing WA game mechanics that fire too often (UC, complications, world events): BQ audit → prompt contract change (eligibility gate / cadence / new field) → extend `is_cooldown_turn()` → wire BOTH write paths (`world_logic.py` + `llm_parser.py`) → TDD. Verified on PR `feat/uc-streak-gate-lw-tone-24h-cd14` (2026-08-21).
- `references/wa-godmode-arc-intro-pattern.md` — Jeffrey's empirical god-mode arc-intro patterns: 5 verbatim shapes, lexical anchors, cross-campaign invariants, raw-token-stripping pitfall, and the canonical PR #8979 rule ("god-mode is orthogonal to character-mode beats; never refuse `>>>god-mode<<<` input mid-scene").
- `scripts/wa_compliance_sampler.py` — empirical sampling recipe (6 turns × 6 constructs).
- `scripts/wa_prompt_dedup.py` — 80-char fingerprint cross-file dedup.
- `scripts/wa_prompt_includes.py` — `{{PROMPT_INCLUDE:...}}` chain map + orphan detector.
- `scripts/wa_prompt_size_profile.sh` — top-25 file byte distribution.
- `scripts/wa_prompt_token_cost.py` — single-prompt cl100k_base token cost with `--times N` multiplier (orthogonal-prompt-injection cost projection across N agents).
- `scripts/sample_wa_compliance_turns.sql` — BigQuery ROW_NUMBER() query for sampling.
- `scripts/wa_prompt_size_probe.sql` — BigQuery truncation-footer probe for served-prompt size.
- `scripts/wa_uc_lw_audit_query.sql` — reproducible 30d audit for Unforeseen Complication and Living World tone (3-part query with all BQ gotchas commented inline). Use in any PR body that quotes UC / LW numbers.
