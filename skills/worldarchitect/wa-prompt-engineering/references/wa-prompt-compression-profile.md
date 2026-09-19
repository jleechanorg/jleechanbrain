# WA Prompt Compression Profile

**Source:** Generated 2026-08-18 from `/tmp/wa_prompt_compression_profile.md` (16,896 B). This file is the canonical durable reference.

## When to use

Use this profile when the user reports:
- *"The prompts are large, can we compress some"*
- *"Why is response latency so high?"* (often correlates with served-prompt size)
- *"We're hitting token limits on long campaigns"*
- *"Cache hit rate is low — different prompts per turn"*

Do NOT use for prompt-content correctness (use the inventory in `references/wa-arc-quest-companion-prompt-surface-inventory.md`) or for UI choice-contract work (use `wa-planning-block-choice-contracts`).

## The four-step profile

### Step 1 — Size distribution

```bash
cd ~/projects/worldarchitect.ai
for f in mvp_site/prompts/*.md mvp_site/prompts/{shared,multiverse,divine,injection}/*.md; do
  printf "%8d %5d %s\n" "$(wc -c <"$f")" "$(wc -l <"$f")" "$f"
done | sort -rn | head -25
```

Top-5 files are typically **~49% of total bytes** (~430KB of 909KB total across 47 files). Target that list first. Recipe: `scripts/wa_prompt_size_profile.sh`.

### Step 2 — Duplication fingerprinting

80-char normalized whitespace fingerprints across all prompts. Most noise is harmless (`{{PROMPT_INCLUDE:...}}` pointers within the same shared/ file). Real duplication candidates:

- **`mechanics_system_instruction.md` ↔ `_code_execution.md`** — ~99% overlap, only the dice-strategy block differs. Halves the cache-key space when collapsed.
- **`game_state_examples.md` ↔ `game_state_mechanics_appendix.md`** — single 150-char fragment (Hit-Dice edge case example). Tiny but real.

Recipe: `scripts/wa_prompt_dedup.py`.

### Step 3 — Rule vs reference classification

For each top-5 file, count:

- **Rule lines**: contain `MUST|MANDATORY|🚨|CRITICAL|HARD INVARIANT|REQUIRED|🚫|⚠️`
- **Code/example lines**: inside fenced code blocks (most are long JSON examples)
- **Table rows**: lines matching pipe-table shape

The typical WA pattern across the top-5:

| File | total lines | rule lines | code/example | table |
|---|---|---|---|---|
| `game_state_instruction.md` | 2622 | 159 (6%) | **928 (35%)** | 84 (3%) |
| `faction_minigame_instruction.md` | 2263 | 84 (4%) | **1046 (46%)** | 118 (5%) |
| `narrative_system_instruction.md` | 1509 | 78 (5%) | 289 (19%) | 59 (4%) |
| `living_world_instruction.md` | 1072 | 24 (2%) | **283 (26%)** | 31 (3%) |
| `level_up_instruction.md` | 695 | 51 (7%) | 58 (8%) | 13 (2%) |

35–46% of the top-5 files is JSON example content the LLM rarely echoes verbatim. Server-side schema validators enforce shape. Reference data the LLM doesn't echo verbatim is a compression candidate.

**Important nuance**: `living_world_instruction.md` shows 2% rule lines via the keyword detector, but most of that file IS rules expressed in declarative prose ("must", "do not", "will"). The keyword detector undercounts. Don't use it as a sole compression signal — read sections before trimming.

### Step 4 — Include chain analysis

`{{PROMPT_INCLUDE:path}}` handling lives at `mvp_site/agent_prompts.py:807-853`. Cycle detection is in place. Path traversal is blocked.

| Shared file | Size | Included by | Mode |
|---|---|---|---|
| `dice_code_execution.md` | 7.2KB | `mechanics_system_instruction_code_execution.md`, `dice_system_instruction_code_execution.md` | normal |
| `dice_notation_contract.md` | 5.2KB | `dice_system_instruction.md`, `dice_system_instruction_code_execution.md`, `game_state_instruction.md` | normal |
| `mechanics_combat_roll_display_rules.md` | 1.1KB | `mechanics_system_instruction.md`, `shared/dice_code_execution.md` | chain (1 hop) |
| `mechanics_leveling_protocol_intro.md` | 3.6KB | `mechanics_system_instruction.md`, `mechanics_system_instruction_code_execution.md` | normal |
| `mechanics_leveling_rewards_body.md` | 25.1KB | `mechanics_system_instruction.md`, `mechanics_system_instruction_code_execution.md` | normal |
| `skill_selection_rules.md` | 2.4KB | `character_creation_instruction.md`, `character_creation_conclude_instruction.md` | normal |
| `user_directive_supremacy.md` | 3.5KB | `character_creation_instruction.md`, `character_creation_conclude_instruction.md` | normal |
| `banned_names_instruction.md` | 0.5KB | **none** | **orphaned / dead code** |
| `rag_output_contract.md` | 0.3KB | **none** | **orphaned / dead code** |

**Pitfall:** "orphaned" only means no `{{PROMPT_INCLUDE:}}` reference. The file may still be loaded via conditional path in `agent_prompts.py`. Verify before deletion. Recipe: `scripts/wa_prompt_includes.py`.

## Compression decision matrix

Ranked by savings × ease (positive values are bytes saved, negative are a budget hit):

| # | Action | Est. bytes | Difficulty | Risk | Cache impact |
|---|---|---:|---|---|---|
| 1 | Collapse `mechanics_system_instruction.md` ↔ `_code_execution.md` (99% duplicate) via `{{PROMPT_INCLUDE:shared/dice_code_execution.md}}` | ~4KB | low | low | halves cache-key space for that path (largest win) |
| 2 | Delete orphaned `shared/banned_names_instruction.md` + `shared/rag_output_contract.md` | ~750B | low | low | none |
| 3 | Extract JSON examples in `game_state_instruction.md` L1570-L2050 → `shared/state_updates_examples.md` (first-turn-only loading) | ~30KB | medium | medium | smaller prefix on subsequent turns (cache win) |
| 4 | Extract per-action JSON in `faction_minigame_instruction.md` (46% of file) → `shared/faction_action_examples.md` | ~30KB | medium | medium | smaller prefix on subsequent turns |
| 5 | Extract 3x-duplicated `companion_arc_event` JSON in `living_world_instruction.md` → `shared/companion_arc_event_example.md` | ~3KB | low | low | none |

**Cache-fragmentation priority** — the biggest prompt-cache win is NOT raw byte reduction; it's **reducing distinct prompt-prefix variants**. A 99% duplicate file pair produces two prompt-cache keys; collapsing to one halves the variant space. Run `scripts/wa_prompt_dedup.py` first to identify the pairs.

## Worked example (2026-08-18 candidate PR)

If you're bundling a new prompt feature (e.g. PC arc rule, ~150 lines / ~7KB) with compression, item #1 + #5 together:

- New feature adds ~7KB
- Compression removes ~7KB
- Net: ~0KB on prompts surface, BUT cache-key space halved on the mechanics path

That's a clean PR: no regression on prompt bytes, measurable cache improvement, and the new feature lands.

## Anti-patterns

- **Don't measure only line count.** A 100-line file with all rules is more critical than a 1000-line file with 46% JSON examples. Always classify before counting.
- **Don't trust orphan detection without follow-up grep.** Some shared files are loaded via `agent_prompts.py` conditional import, not `{{PROMPT_INCLUDE:...}}` placeholders. Verify in Python before deletion.
- **Don't inline shared leaves into parents.** Inlining re-bloats the parents and breaks cache-locality. Keep the shared/ subdirectory.
- **Don't compress rules just to hit a byte target.** If the prompt content is rule-dense (like `level_up_instruction.md` at 7% rule density), leave it alone.
- **Don't compress without verifying the served prompt.** After every compression PR, run `python3 -c "from mvp_site.agent_prompts import _load_instruction_file; p = _load_instruction_file('<file>'); assert '<must_contain>' in p; print('OK')"` to confirm the cached contract survives.

## Pitfall: token-budget decay threshold

The canonical "lost in the middle" threshold is ~40K tokens (~160K chars). Nocturne BG3's median served prompt was **~280K tokens (~1MB)**, ~7× over. So:

- If median served prompt > 160K chars for a campaign, expect token-budget decay regardless of which files contain the rule.
- The fix is recency (lift cadence to top of prompt) + frequency (fire cadence on every turn), not more prompt content.

Verified in `/tmp/wa_arc_root_cause.md` (2026-08-18 investigation).

## Cross-references

- `references/wa-arc-quest-companion-prompt-surface-inventory.md` — the canonical map of prompt content; use this when you need to find WHERE a rule lives.
- `scripts/wa_prompt_dedup.py` — run fingerprint cross-file dedup.
- `scripts/wa_prompt_includes.py` — orphan detection + include chain map.
- `scripts/wa_prompt_size_profile.sh` — top-25 file byte distribution.
- `~/.smartclaw/skills/wa-planning-block-choice-contracts/SKILL.md` — the UI choice-contract sister skill; tier-1 sister for any planning_block-related compression.
- `mvp_site/prompts/AGENTS.md` Hard rules 1-9 — must be respected when compressing.
