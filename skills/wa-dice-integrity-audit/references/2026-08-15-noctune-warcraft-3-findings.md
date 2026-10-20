# noctune Warcraft 3 — provenance-split dice audit (2026-08-15)

**Campaign:** `7HHDMPe0wNLBDTfymzfT` (Jeffrey Lee-Chan, UID
`vnLp2G3m21PJL6kxcuAqmWSOtm73`, `jleechan@gmail.com`)
**Service:** `mvp-site-app-dev-i6xf2p72ka-uc.a.run.app`
**Project:** `worldarchitecture-ai` (Firestore)
**Created:** 2026-08-03 07:25 UTC  |  **Last played:** 2026-08-16 01:18 UTC
**Story entries:** 102 (51 user + 51 gemini)

## Headline

Chi-squared over all d20 rolls: **FAIL-uniform** (χ²=83.09, df=19, critical
30.14, mean=12.85). But this single number hides the actual story:

| Subset | n | mean | χ² | verdict |
|---|---|---|---|---|
| `rng_verified=True` (server RNG path) | 11 | **7.64** | 16.27 | **PASS** (uniform) |
| `rng_verified=False` (caught fabrication) | 0 | — | — | — |
| `rng_verified=unset` (no telemetry) | 23 | **15.39** | 63.09 | **FAIL** (severely skewed) |

The two populations are not from the same distribution. The server's
RNG is producing fair dice; the model is producing roll outcomes in
prose that are heavily skewed toward 13-19.

## Raw face distributions

### Server-RNG rolls (n=11, all facets of [1,20])
```
1: 1, 3: 1, 4: 1, 5: 1, 6: 1, 7: 1, 8: 2, 12: 1, 15: 2
```
Mean 7.64, median 7, stdev 4.65 — looks like a fair d20.

### Unverified/narrative rolls (n=23, every roll ≥13)
```
13: 2, 14: 6, 15: 5, 16: 4, 17: 4, 18: 1, 19: 1
```
Mean 15.39, median 15 — **zero rolls of 12 or below**, which has
binomial probability <1e-6 under fair dice. Strong evidence of model
fabrication.

### All d20 combined (n=34)
```
1: 1, 3: 1, 4: 1, 5: 1, 6: 1, 7: 1, 8: 2, 12: 1, 13: 2, 14: 6, 15: 5, 16: 4, 17: 4, 18: 1, 19: 1
```
χ²=44.82, df=19 → FAIL at α=0.05 AND α=0.01. (Note: this is fewer
than the headline 66 because not all d20 rolls had structured
provenance in `action_resolution.mechanics.rolls`. The headline-66
includes `legacy dice_rolls[]` entries that lack `debug_info`.)

## Telemetry coverage across all 102 docs

| field | True | False | unset |
|---|---|---|---|
| `dice_strategy` | 1 (`code_execution`) | 0 | 101 |
| `dice_seed_verified` | 9 | 4 | 89 |
| `rng_verified` | 9 | 4 | 89 |
| `code_execution_used` | 9 | 4 | 89 |
| `code_contains_rng` | 9 | 4 | 89 |
| `executable_code_parts` | 9 (`1`) | 4 (`0`) | 89 |

**89 of 102 docs (87%) have no `debug_info` telemetry at all.** These
break down as:
- 51 user-input turns (no dice expected — model never sees a dice
  request from these turns)
- ~38 gemini turns where the model produced a roll without invoking
  the dice tool (rolled in prose, attached to `action_resolution.
  mechanics.rolls[]` without calling the Python RNG)

**9 of 102 docs (~9%) went through the server's provably-fair RNG.**
4 of 102 had `rng_verified=False` (server detected model fabricated
even when it tried to call the tool).

## System-prompt size

30 of 102 docs had `system_instruction_char_count` in the 200-500K
bin; 21 were >500K. **All 51 docs with measurable system-prompt size
were >200K.** This is consistent with Pitfall #9 — system prompts
that large inflate fabrication rate because the model drops
"use code_execution for dice" instructions under context pressure.

## Interpretation

The user's intuition ("do my dice rolls look accurate?") is correct
and the answer is "yes, the *server's* dice are accurate, but the
*model's* dice are heavily biased high." The user has been seeing
high rolls consistently because ~68% of d20 outcomes on this
campaign came from the model's own fabrication, not from the
provably-fair server RNG.

## Recommended fix (not yet shipped)

Two-line summary: the `agent_prompts.py` system instructions
should mandate `roll_dice` function calls for any roll whose
outcome the model narrates, with a post-generation validator that
flags any `action_resolution.mechanics.rolls[]` entry whose
parent doc has `debug_info.code_execution_used != True`.

Open a PR on `jleechanorg/worldarchitect.ai` from a clean worktree
on `origin/main`:
1. `mvp_site/agent_prompts.py` — find the dice-roll instruction
   block, move it from the tail of the system prompt to a
   deterministic, hard-to-drop position.
2. `mvp_site/dice_integrity.py` (or `main.py`) — add a
   post-roll validator: if `mechanics.rolls[]` non-empty AND
   `debug_info.code_execution_used != True`, set a flag and
   either re-roll via the server or surface a UI warning.
3. `mvp_site/tests/test_dice_integrity_validator.py` — RED→GREEN
   pinning the validator exists and fires correctly.

## Artifacts on disk

- `/tmp/jleechan_dice.json` — 68 parsed rolls (all 102 story docs)
- `/tmp/extract_one_campaign.py` — single-campaign extractor with
  provenance tagging
- `/tmp/audit_subsets.py` — provenance split + per-subset χ²

## Why this is the second reference file in the skill

`references/2026-08-13-hanji-stevens-findings.md` documents the
*first* chi-squared run, where `dice_strategy` was sparsely
populated and `rng_verified` was discovered late. This file is
the *worked example* of Step 6 — splitting by provenance — which
turns "your dice are biased" into "your dice are biased in *this
specific way* and the fix targets that specific cause."