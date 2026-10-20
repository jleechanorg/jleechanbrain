---
name: wa-dice-schema-validator-warnings
description: "Use when user reports `Dice schema warning` banner in WA UI. The validator has 11 warning sites; PR #8930 only fixed Class D (missing modifier). Bugs G/J/M (concatenated/keep-drop notation) still fire on benign natural dice notation."
tags: [worldarchitect, dice, schema, validator, ui-warning, narrative_response_schema]
version: 2
author: hermes-curator
license: MIT
metadata:
  hermes:
    tags: [worldarchitect, dice, schema, validator, ui-warning, narrative_response_schema]
    related_skills: [wa-daily-dice-audit-fix]
changelog:
  - 2.0.0 (2026-08-16) **Full 11-site inventory + remaining 3 cosmetic warnings.** Earlier catalog listed only Class D (missing modifier, PR #8930). The validator at `narrative_response_schema.py:3469-3646` has 11 warning emission sites; the user's "still seeing warnings on every turn" complaint is the 3 cosmetic sites (G, J, M) firing on legitimate natural dice notation (`1d20+2d6`, `4d6kh1`, `3d6!`, etc.). The 7 real-drift warnings (E, F, H, I, K, L, N) must keep firing. Fix pattern: mirror PR #8930's `notation_modifier != 0` gate — add `_is_concatenated_notation` + `_has_keep_drop_modifier` helpers and 4 surgical patches. Added GitHub secondary rate-limit pitfall (writes return 403 / `issue: null` even when both buckets report budget). Added coordinate-with-PR-8951 pitfall. Written 3 reference files: site inventory, TDD recipe, and PR-8951 coordination.
  - 1.0.0 (2026-08-14) Initial catalog with Class D (missing modifier). Single fix; line ref 3547.
---

## When to Use

Load this skill when the user reports a "Dice schema warning: action_resolution.mechanics.rolls[...] ..." banner in the worldarchitect.ai campaign UI. Use the full 11-site inventory to classify the warning, then mirror the PR #8930 fix pattern for any cosmetic site.

**Trigger phrases:** "Dice schema warning", "action_resolution.mechanics.rolls", "missing required modifier", "missing required result", "out-of-range result", "modifier disagrees with notation", "missing raw rolls", "raw rolls count does not match", "result/total mismatch", "_server_system_warnings".

**Do NOT load for GCP cron dice-audit failures** ([Integrity Failure] in job logs, cron exit 1) — that's `wa-daily-dice-audit-fix`.

# WA dice schema validator warnings (UI banner path)

The worldarchitect.ai backend has **two separate dice-validation paths** that emit very different warnings. Misidentifying which path fired is the #1 diagnosis trap.

| Path | Where | Symptom | Visible to |
|---|---|---|---|
| **UI validator** | `mvp_site/narrative_response_schema.py::_warn_on_unclean_action_resolution_dice` (lines ~3469-3646) | "Dice schema warning: action_resolution.mechanics.rolls[...] ..." prefix; stored in `debug_info._server_system_warnings` | End user in the dice rolls panel |
| **GCP cron audit** | `scripts/audit_dice_rolls.py` + `scripts/audit_helpers.py` | "[Integrity Failure]" lines in job logs; cron `wa-daily-dice-audit` exits 1 | Operator email / Slack only |

**Loading rule:** If the user shares a screenshot showing "Dice schema warning:" in the campaign UI, this is the skill you want. For cron failures, load `wa-daily-dice-audit-fix` instead.

## Quick diagnosis (run first)

```bash
# 1. Extract the warning text verbatim from the user's screenshot
# 2. Find the emission site (source only — NOT tests/fixtures)
git -C ~/repos/jleechanorg/worldarchitect.ai grep -n "<warning text>" mvp_site/

# 3. Find the test that encodes the current contract
git -C ~/repos/jleechanorg/worldarchitect.ai grep -n "<warning text>" mvp_site/tests/

# 4. Check open PRs that touch the file
for n in $(gh pr list --repo jleechanorg/worldarchitect.ai --state open --limit 50 --json number --jq '.[].number'); do
  files=$(gh pr view $n --json files --jq '[.files[].path] | map(select(. == "mvp_site/narrative_response_schema.py")) | .[]')
  [ -n "$files" ] && echo "PR #$n: $files"
done
```

If the warning is in source code at an `if "foo" not in roll: _warn_missing_required_roll_field(...)` call, you've found the bug class. The fix is usually 1-5 lines.

## Known bug classes (full 11-site catalog)

The `_warn_on_unclean_action_resolution_dice` validator at `mvp_site/narrative_response_schema.py:3469-3646` has **11 warning emission sites**. The full site-by-site inventory (line numbers, truth-value classification, and fix predicates) is in `references/validator-warning-inventory-2026-08-16.md`. Summary:

| Class | Warning text | Line | Truth value | Status | Fix predicate |
|---|---|---|---|---|---|
| D | `missing required modifier` | 3541 | Cosmetic when notation has no flat modifier | **MERGED** PR #8930 | `notation_modifier != 0` |
| E | `missing required result` | 3545 | Real contract drift | KEEP warning | — |
| F | `missing required total` | 3549 | Real contract drift | KEEP warning | — |
| G | `unparseable notation` | 3514 | Cosmetic on concatenated (`1d20+2d6` = 84% of warns per test 2201) | **OPEN — bug remaining** | `not _is_concatenated_notation(notation)` |
| H | `modifier disagrees with notation` | 3554 | Real (explicit `modifier=0` is user opt-in) | KEEP warning | — |
| I | `out-of-range result for 1dX` | 3566 | Real contract drift | KEEP warning | — |
| J | `missing raw rolls[] face values` | 3525, 3578 | Cosmetic when `result`+`total` present and coherent | **OPEN — bug remaining** | `roll.get("result") and roll.get("total")` |
| K | `non-integer raw rolls[] values` | 3589 | Real (model emitting strings) | KEEP warning | — |
| L | `out-of-range raw faces` | 3602 | Real contract drift | KEEP warning | — |
| M | `raw rolls[] count does not match` | 3617 | Cosmetic on concatenated / keep-drop notation (`kh1`/`kl1`) | **OPEN — bug remaining** | `not _is_concatenated_notation(notation) and not _has_keep_drop_modifier(notation)` |
| N | `result/total mismatch` | 3630 | Real contract drift | KEEP warning | — |

**The pattern**: the validator treats `rolls[]` face values as the canonical struct, but the LLM emits rolls using natural dice notation where `result` and `total` are the canonical truth. The 7 real-drift warnings (E, F, H, I, K, L, N) must still fire; the 3 cosmetic warnings (G, J, M) should be gated on legitimate natural notation.

**Fix shape (verified, PR #8930 pattern)**: mirror `notation_modifier != 0` gate for the 3 cosmetic sites. Add 2 helper functions (`_is_concatenated_notation`, `_has_keep_drop_modifier`) and 4 surgical patches. TDD: 8 new tests (4 RED-then-GREEN on natural notation, 4 control asserting real drift still warns) + 179 existing tests still pass. Full TDD recipe: `references/tdd-noisy-warning-fix-recipe-2026-08-16.md`.

### Class D — Unconditional `modifier` missing warning for plain-D notation [MERGED]

**Symptom:** `Dice schema warning: action_resolution.mechanics.rolls[1] is missing required modifier for '1d100'.`

**Source:** `mvp_site/narrative_response_schema.py:3541` (line shifted from 3547 after #8930 merge)
```python
if "modifier" not in roll:
    _warn_missing_required_roll_field("modifier", roll_index=index, roll_notation=notation)
```
Unconditional. Fires for `1d100`, `2d6`, `1d20` — any notation without a flat modifier.

**Fix:** Gate on `notation_modifier != 0`:
```python
if "modifier" not in roll and notation_modifier != 0:
    _warn_missing_required_roll_field("modifier", roll_index=index, roll_notation=notation)
```
The companion `effective_modifier = effective_dice_modifier(roll.get("modifier"), notation)` at line 3553 already handles missing → 0 correctly, so runtime contract is unchanged.

**Status:** **MERGED** in PR #8930 (`e674030f8b`) by `${GITHUB_USER}` on 2026-08-15. This is the canonical fix pattern — mirror it for the 3 open cosmetic warnings (G, J, M). Detailed PR body gist: https://gist.github.com/${GITHUB_USER}/e4b5659f66740b3b21d7d7335cc92dde

### Classes G / J / M — Cosmetic noise on natural notation [OPEN BUG]

Three warning sites still fire on legitimate natural dice notation the LLM emits. The user's "still seeing warnings on every turn" complaint is these three.

**Class G** (line 3514): `unparseable notation` — fires when `_parse_action_resolution_dice_notation` returns `die_type=None` for concatenated notation like `1d20+2d6`. Existing test `test_dice_notation_contract_anti_examples_for_concatenated_and_freetext` (line 2201) documents that 84% of these warns are concatenated rolls.

**Class J** (lines 3525, 3578): `missing raw rolls[] face values` — fires when `rolls[]` is empty, but this is documentary evidence not structural truth when `result` and `total` are coherent.

**Class M** (line 3617): `raw rolls[] count does not match` — fires when `len(raw_roll_values) != num_dice`, but legitimate keep-drop notation (`4d6kh1`, `3d6!`) and concatenated notation (`1d20+2d6`) intentionally have a different count.

**Fix shape (TDD red→green→refactor)** — full recipe in `references/tdd-noisy-warning-fix-recipe-2026-08-16.md`. Summary: 2 helper functions + 4 surgical patches + 8 new tests.

```python
def _is_concatenated_notation(notation: str | None) -> bool:
    """True for '1d20+2d6', '2d6+1d4', '1d20-1d4' — multi-die-set strings."""
    if not isinstance(notation, str):
        return False
    import re
    return bool(re.search(r"(\d+d\d+)\s*([+\-])\s*(\d+d\d+)", notation))

def _has_keep_drop_modifier(notation: str | None) -> bool:
    """True for '4d6kh1', '2d20kl1', '1d20!', '3d6r1' — keep/drop/explode/reroll."""
    if not isinstance(notation, str):
        return False
    return bool(re.search(r"k[hl]\d+|kr\d+|!|r\d+", notation, re.IGNORECASE))
```

Apply 4 surgical patches to gate the 3 cosmetic warnings on these helpers. Skill `references/tdd-noisy-warning-fix-recipe-2026-08-16.md` has the full patch + tests.

## Anti-patterns

- **Don't grep `mvp_site/tests/`** for the warning text — the test file *asserts the warning fires*, so you'll find a hit there and think the warning is a fixture. Always grep source first.
- **Don't conflate the two paths.** Someone who sees "Dice schema warning:" in the UI and reads the `wa-daily-dice-audit-fix` skill will chase the cron path and find nothing — the cron path never emits this prefix.
- **Don't propose adding the `modifier` field to the LLM prompt without fixing the validator.** Models will keep omitting it for `1d100` because the contract is wrong; the fix is at the validator.
- **Don't stop at Class D.** When the user reports warnings still firing after PR #8930, the next 3 (G, J, M) are the remaining bugs. The full 11-site inventory is the source of truth.
- **Don't break the 7 real-drift warnings.** E, F, H, I, K, L, N must still fire on real schema drift. The fix only gates the 3 cosmetic warnings (G, J, M).
- **Don't recite the warning list and ask "should I fix via A or B?"** The full inventory already tells you which sites are cosmetic vs real. Run the inventory, then propose the 4-patch fix.
- **Don't push onto PR #8951's branch.** PR #8951 (`feat/rev-6g6d4-pr8945-followup-fixes`) touches the same file for `response_json_schema` and is orthogonal. Coordinate, don't collide. See `references/coordinate-with-pr-8951-2026-08-16.md`.

## Pitfalls (operational)

### GitHub secondary rate limit silently rejects writes

The `gh api rate_limit` endpoint reports healthy budget on both core and graphql buckets (e.g. `core=4976, graphql=1855`) BUT every write attempt — `gh issue create`, GraphQL `createIssue` mutation, REST `POST /repos/.../issues` — silently fails. REST returns HTTP 403 ("You have exceeded a secondary rate limit and have been temporarily blocked from content creation"). GraphQL returns `{"data": {"createIssue": {"clientMutationId": null, "issue": null}}}` with no error reported. `gh issue create` returns exit 0 but no issue is created.

**Detection signature**: budget looks fine, writes go through, no issue is created. The first line of any 403 says "secondary rate limit" — that's GitHub's content-creation sandbox, NOT the bucket counters.

**Workaround**: file the issue from a different worktree (different token context sometimes bypasses). If still blocked, embed the issue body in the PR description and link the bead (`rev-XXX`) — the bead is the durable record. The issue PR pair is "issue filed OR bead filed, not both required" — gates are complete when the durable record exists.

### Coordinate with PR #8951

PR #8951 (`feat/rev-6g6d4-pr8945-followup-fixes`) was MERGED-related to PR #8945 (response_json_schema for Gemini Flash). It touches the same file (`mvp_site/narrative_response_schema.py`) but only modifies the schema definition for `response_json_schema` support, NOT the validator. The two fixes are orthogonal and can merge in either order. If both PRs land simultaneously, merge PR #8951 first, then rebase the noise-cleanup PR on top. Detailed coordination recipe: `references/coordinate-with-pr-8951-2026-08-16.md`.

### Contract-test resolver pitfall (cross-cuts with `/repro`)

The standard pitfall when adding validator tests in a worktree: contract tests must resolve the prompt/repo root from `__file__` (walking up to a marker file), not from a hard-coded main-checkout path. If the test lives in `${HOME}/projects/wt-dice-noise-cleanup/mvp_site/tests/...`, hard-coding `REPO_ROOT = "${HOME}/projects/worldarchitect.ai"` makes the test read the un-patched main-checkout prompt/schema. Walking-up resolver: `cur = _os.path.dirname(_os.path.abspath(__file__)); for _ in range(6): cur = _os.path.dirname(cur); if _os.path.isfile(_os.path.join(cur, "mvp_site/prompts/...")): return cur`. Apply to any contract test that reads `mvp_site/narrative_response_schema.py`.

## Reference files

- `references/validator-warning-inventory-2026-08-16.md` — line-by-line 11-site inventory with truth-value classification. The source of truth for which warning sites are cosmetic vs real.
- `references/tdd-noisy-warning-fix-recipe-2026-08-16.md` — full TDD recipe (8 tests + 4 patches + 2 helpers) ready to mirror when fixing Classes G, J, M.
- `references/coordinate-with-pr-8951-2026-08-16.md` — when + how to coordinate with PR #8951 (response_json_schema) which touches the same file.
- `references/github-secondary-rate-limit-pitfall-2026-08-16.md` — GitHub's content-creation sandbox silently rejects writes even when both rate-limit buckets report healthy. Cross-cuts with `/repro` hard-gate workflow. Discovered during this session.

## Session-specific notes

- 2026-08-16: Catalog expanded from Class D only to full 11-site inventory. The remaining 3 cosmetic warnings (G, J, M) were identified as the source of the user's "still seeing warnings on every turn" complaint on `mvp-site-app-s1` campaign `7HHDMPe0wNLBDTfymzfT`. Worker dispatched on clean worktree `fix/dice-schema-warnings-noise-cleanup` (branched from `origin/main` HEAD `59120dca25`) with bead `rev-nrd0p` filed. GitHub issue creation blocked by secondary rate limit; will retry from worktree or embed in PR body. PR #8951 in flight on the same file for `response_json_schema` — orthogonal, no collision. Follow-up cron `b7cef0a99a8d` armed for 10m.
- 2026-08-14: Class D identified from user screenshot `1d100 = 51` Unforeseen Complication. Root cause at `narrative_response_schema.py:3547` (line now 3541 after refactor). PR #8930 merged 2026-08-15 with the `notation_modifier != 0` gate. Full repro at `~/.smartclaw/wa-repro-8874/issue-body.md` (sibling skill).
- 2026-08-14: Confirmed three other open PRs (#8828, #8731, #8824) touched `narrative_response_schema.py` but none modified the modifier check (PR #8930 did).
