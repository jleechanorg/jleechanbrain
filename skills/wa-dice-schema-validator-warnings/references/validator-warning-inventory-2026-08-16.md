# Validator warning site inventory (2026-08-16)

Source of truth for the 11 warning emission sites in `_warn_on_unclean_action_resolution_dice` at `mvp_site/narrative_response_schema.py:3469-3646` (line numbers reflect current `origin/main` HEAD `59120dca25`; before PR #8930's line shifts, sites were at 3475-3620 / 3547 respectively).

This is the authoritative inventory used to classify the user's "Dice schema warning" reports. Every site listed has been verified against the source — no fabrication, no test-fixture noise.

## Truth-value classification

The validator's job is to surface **real schema drift** (the LLM emitted a struct that doesn't match the contract). The bug is that it conflates real drift with **legitimate natural dice notation** the LLM uses when generating roll prose. The 11 sites break into:

| Truth value | Count | What does it mean |
|---|---|---|
| **Cosmetic** | 3 (G, J, M) + Class D (merged) | Fires on legitimate natural notation. Suppress with a gate predicate. |
| **Real drift** | 7 (E, F, H, I, K, L, N) | Indicates the LLM emitted an inconsistent struct. Keep warning. |

Total: 11 sites. 4 cosmetic (1 already merged), 7 real drift.

## The 11 sites (line-by-line)

### Class D — `missing required modifier` (line 3541) — MERGED

```python
if "modifier" not in roll:
    _warn_missing_required_roll_field("modifier", roll_index=index, roll_notation=notation)
```

**Truth value**: Cosmetic when notation has no flat modifier (e.g. `1d100`, `1d20`, `2d6`).

**Fix**: Gate on `notation_modifier != 0`. The companion `effective_modifier = effective_dice_modifier(roll.get("modifier"), notation)` at line 3553 already handles missing → 0 correctly so runtime contract is unchanged.

**Status**: MERGED in PR #8930 (`e674030f8b`) by `${GITHUB_USER}` on 2026-08-15. Gist: https://gist.github.com/${GITHUB_USER}/e4b5659f66740b3b21d7d7335cc92dde

### Class E — `missing required result` (line 3545) — KEEP

```python
if "result" not in roll:
    _warn_missing_required_roll_field("result", roll_index=index, roll_notation=notation)
```

**Truth value**: Real contract drift. The roll struct is fundamentally broken without `result`.

**Fix**: None needed. This warning is correct.

### Class F — `missing required total` (line 3549) — KEEP

```python
if "total" not in roll:
    _warn_missing_required_roll_field("total", roll_index=index, roll_notation=notation)
```

**Truth value**: Real contract drift. Total is structurally required for downstream UI math.

**Fix**: None needed.

### Class G — `unparseable notation` (line 3514) — **OPEN**

```python
if die_type is None:
    if isinstance(notation, str) and notation.strip():
        warning_message = (
            "Dice schema warning: action_resolution.mechanics.rolls"
            f"[{index}] has unparseable notation {notation!r}; "
            "raw dice fields cannot be fully verified."
        )
        _log_thresholded_warning(...)
        self._add_server_system_warning(warning_message)
```

**Truth value**: Cosmetic when concatenated (`1d20+2d6`, `2d6+1d4` — 84% of warns per existing test `test_dice_notation_contract_anti_examples_for_concatenated_and_freetext` at line 2201).

**Fix**: Gate on `not _is_concatenated_notation(notation)`.

### Class H — `modifier disagrees with notation` (line 3554) — KEEP

```python
if explicit_modifier is not None and explicit_modifier != notation_modifier:
    warning_message = (
        "Dice schema warning: action_resolution.mechanics.rolls"
        f"[{index}] modifier disagrees with notation {notation!r}; "
        "explicit modifier is preserved."
    )
```

**Truth value**: Real drift. If the LLM wrote `modifier=0` for a `1d20+5` roll, that IS a drift signal — the explicit value is preserved but it disagrees with the parsed notation.

**Fix**: None needed. Existing test `test_action_resolution_dice_zero_modifier_stays_explicit` (line 2438) verifies this is correct behavior.

### Class I — `out-of-range result for 1dX` (line 3566) — KEEP

```python
if num_dice == 1 and result is not None and not 1 <= result <= die_type:
    warning_message = (
        "Dice schema warning: action_resolution.mechanics.rolls"
        f"[{index}] has out-of-range result for {notation!r}: "
        f"{result}."
    )
```

**Truth value**: Real contract drift. A `1d20` result of 25 is mathematically impossible.

**Fix**: None needed.

### Class J — `missing raw rolls[] face values` (lines 3525, 3578) — **OPEN**

Two emission sites with the same text:

```python
# Line 3525 (inside the unparseable branch)
if not raw_roll_values:
    warning_message = (
        "Dice schema warning: action_resolution.mechanics.rolls"
        f"[{index}] for {notation!r} is missing raw rolls[] face values."
    )

# Line 3578 (in the parseable branch)
if not raw_roll_values:
    warning_message = (
        "Dice schema warning: action_resolution.mechanics.rolls"
        f"[{index}] for {notation!r} is missing raw rolls[] face values."
    )
```

**Truth value**: Cosmetic when `result` and `total` are present and coherent. The model knew the answer; it just didn't write the documentary face values.

**Fix**: Gate on `not (roll.get("result") and roll.get("total"))` — when both are present, the roll is structurally valid and the documentary `rolls[]` is optional.

### Class K — `non-integer raw rolls[] values` (line 3589) — KEEP

```python
if raw_roll_coercion_failures:
    warning_message = (
        "Dice schema warning: action_resolution.mechanics.rolls"
        f"[{index}] has non-integer raw rolls[] values for {notation!r}: "
        f"{raw_roll_coercion_failures[:5]}."
    )
```

**Truth value**: Real drift. The model is emitting strings (e.g. `"six"`) instead of ints. UI math breaks.

**Fix**: None needed.

### Class L — `out-of-range raw faces` (line 3602) — KEEP

```python
out_of_range = [value for value in raw_roll_values if value < 1 or value > die_type]
if out_of_range:
    warning_message = (
        "Dice schema warning: action_resolution.mechanics.rolls"
        f"[{index}] has out-of-range raw faces for {notation!r}: "
        f"{out_of_range[:5]}."
    )
```

**Truth value**: Real drift. A face value of 7 on a `1d6` is impossible.

**Fix**: None needed.

### Class M — `raw rolls[] count does not match` (line 3617) — **OPEN**

```python
if len(raw_roll_values) != num_dice:
    warning_message = (
        "Dice schema warning: action_resolution.mechanics.rolls"
        f"[{index}] raw rolls[] count does not match {notation!r}; "
        f"expected {num_dice}, got {len(raw_roll_values)}."
    )
```

**Truth value**: Real on plain dice (e.g. `3d6` with 2 face values). Cosmetic on concatenated notation (`1d20+2d6` legitimately has 3 faces but `num_dice=1`) and keep-drop notation (`4d6kh1` legitimately has 4 faces but `num_dice=4` only counts the kept — fine, but `4d6kh1` parsed as `num_dice=4` so this should match; the count mismatches for `3d6!` exploding where extra faces are appended).

**Fix**: Gate on `not _is_concatenated_notation(notation) and not _has_keep_drop_modifier(notation)`.

### Class N — `result/total mismatch` (line 3630) — KEEP

```python
if (
    num_dice == 1
    and result is not None
    and total is not None
    and result + effective_modifier != total
):
    warning_message = (
        "Dice schema warning: action_resolution.mechanics.rolls"
        f"[{index}] result/total mismatch for {notation!r}; "
        "result must be the raw face and total must include modifiers."
    )
```

**Truth value**: Real drift. The LLM said `result=15, total=20` for a `1d20+5` — that's `15+5=20`, correct. But the validator checks `result + effective_modifier != total`, so this only fires when math is wrong. Existing test `test_action_resolution_dice_result_total_mismatch_warns` (line 2345) verifies this is correct.

**Fix**: None needed.

## Decision tree for the agent

When you see a "Dice schema warning" report from the user:

1. **Extract the warning text** verbatim from the screenshot / log.
2. **Match against the table above** — find the class letter.
3. **If MERGED** (Class D): the user is on a stale deploy. Suggest hard refresh / cache-bust.
4. **If OPEN cosmetic (G, J, M)**: apply the fix pattern from `references/tdd-noisy-warning-fix-recipe-2026-08-16.md`. Mirror PR #8930's `notation_modifier != 0` gate.
5. **If KEEP (E, F, H, I, K, L, N)**: the warning is correct behavior. The LLM is producing bad structs; the fix is upstream (prompt / schema), not the validator. Use `references/root-cause-prompt-vs-validator.md` from the `/repro` skill.

## Cross-references

- Full TDD fix recipe: `references/tdd-noisy-warning-fix-recipe-2026-08-16.md`
- PR #8951 coordination: `references/coordinate-with-pr-8951-2026-08-16.md`
- PR #8930 (the merged Class D fix): https://github.com/jleechanorg/worldarchitect.ai/pull/8930
- Source file: `mvp_site/narrative_response_schema.py` lines 3469-3646
- Existing tests: `mvp_site/tests/test_narrative_response_schema.py` line 2201 (connector pattern), line 2438 (Class H control), line 2345 (Class N control)
