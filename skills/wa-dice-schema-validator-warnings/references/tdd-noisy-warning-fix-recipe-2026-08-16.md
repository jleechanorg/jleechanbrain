# TDD recipe for noisy warning fix (2026-08-16)

Full TDD red→green→refactor recipe for fixing the 3 cosmetic warnings (G, J, M) in `_warn_on_unclean_action_resolution_dice`. Mirrors the PR #8930 fix pattern (`notation_modifier != 0` gate).

**Source PR**: https://github.com/jleechanorg/worldarchitect.ai/pull/8930 (the merged Class D fix that this recipe mirrors)
**Source file**: `mvp_site/narrative_response_schema.py` lines 3469-3646
**Test file**: `mvp_site/tests/test_narrative_response_schema.py` (existing 179 tests) + new `mvp_site/tests/test_dice_schema_warnings_noise_cleanup.py`

## Branch setup

```bash
cd ${HOME}/projects/worldarchitect.ai
git fetch origin main
git worktree add ${HOME}/projects/wt-dice-noise-cleanup -b fix/dice-schema-warnings-noise-cleanup origin/main
cd ${HOME}/projects/wt-dice-noise-cleanup
git status --short  # MUST be empty
```

Don't push onto shared/non-owned branches. Verify with `git log --oneline origin/main..HEAD` — must show only fix commits.

## Step 1 (RED) — write failing tests

Create `mvp_site/tests/test_dice_schema_warnings_noise_cleanup.py`:

```python
"""TDD tests for Class G/J/M noisy validator warnings.

These gates verify that natural dice notation emitted by the LLM
(concatenated, keep-drop, exploding) does not trigger the
"_warn_on_unclean_action_resolution_dice" validator's cosmetic warnings,
while real drift warnings still fire.
"""

from __future__ import annotations

from mvp_site.narrative_response_schema import NarrativeResponse


def _build(roll_dict: dict) -> NarrativeResponse:
    """Build a NarrativeResponse with a single dice roll under test."""
    return NarrativeResponse(
        narrative="A test roll.",
        action_resolution={"mechanics": {"rolls": [roll_dict]}},
    )


def test_concatenated_notation_no_warning_1d20_plus_2d6():
    """1d20+2d6 is legitimate; missing raw rolls[] count should NOT warn."""
    nr = _build({
        "notation": "1d20+2d6",
        "result": 18,
        "total": 21,
        # No rolls[] — model omitted face values
    })
    warnings = nr.debug_info.get("_server_system_warnings", [])
    assert not any("raw rolls[] count does not match" in w for w in warnings), \
        f"Expected no count mismatch warning for 1d20+2d6, got: {warnings}"


def test_keep_highest_no_warning_4d6kh1():
    """4d6kh1 is legitimate; should not warn on raw rolls[] count."""
    nr = _build({
        "notation": "4d6kh1",
        "result": 6,
        "total": 6,
        "rolls": [6, 3, 2, 1],  # 4 faces for 4d6, keep highest
    })
    warnings = nr.debug_info.get("_server_system_warnings", [])
    assert not any("raw rolls[] count does not match" in w for w in warnings), \
        f"Expected no count warning for 4d6kh1, got: {warnings}"


def test_keep_lowest_no_warning_2d20kl1():
    """2d20kl1 (disadvantage) is legitimate; should not warn."""
    nr = _build({
        "notation": "2d20kl1",
        "result": 4,
        "total": 4,
        "rolls": [12, 4],
    })
    warnings = nr.debug_info.get("_server_system_warnings", [])
    assert not any("raw rolls[] count does not match" in w for w in warnings), \
        f"Expected no count warning for 2d20kl1, got: {warnings}"


def test_exploding_dice_no_warning_3d6_reroll_1():
    """3d6! exploding notation; rolls[] has more entries than num_dice."""
    nr = _build({
        "notation": "3d6!",
        "result": 18,
        "total": 18,
        "rolls": [6, 6, 6, 2, 1],  # 5 faces: 3 rolled + 1 explode + 1 final
    })
    warnings = nr.debug_info.get("_server_system_warnings", [])
    assert not any("raw rolls[] count does not match" in w for w in warnings), \
        f"Expected no count warning for 3d6!, got: {warnings}"


def test_result_total_present_suppresses_missing_raw_rolls():
    """When result and total are both present, missing raw rolls[] is OK."""
    nr = _build({
        "notation": "1d100",
        "result": 51,
        "total": 51,
        # No rolls[]
    })
    warnings = nr.debug_info.get("_server_system_warnings", [])
    assert not any("missing raw rolls[] face values" in w for w in warnings), \
        f"Expected no missing-rolls warning for 1d100 with result+total, got: {warnings}"


# --- Control tests: real drift MUST still warn ---------------------


def test_real_drift_still_warns_result_out_of_range():
    """Control: out-of-range result MUST still warn."""
    nr = _build({
        "notation": "1d20",
        "result": 25,  # impossible: 1d20 max is 20
        "total": 25,
    })
    warnings = nr.debug_info.get("_server_system_warnings", [])
    assert any("out-of-range result" in w for w in warnings), \
        f"Expected out-of-range warning, got: {warnings}"


def test_real_drift_still_warns_missing_total():
    """Control: missing total MUST still warn."""
    nr = _build({
        "notation": "1d20",
        "result": 15,
        # No total
    })
    warnings = nr.debug_info.get("_server_system_warnings", [])
    assert any("missing required total" in w for w in warnings), \
        f"Expected missing-total warning, got: {warnings}"


def test_real_drift_still_warns_modifier_disagrees():
    """Control: explicit modifier=0 with notation=1d20+5 MUST still warn."""
    nr = _build({
        "notation": "1d20+5",
        "modifier": 0,  # explicit user opt-in
        "result": 15,
        "total": 20,
    })
    warnings = nr.debug_info.get("_server_system_warnings", [])
    assert any("modifier disagrees with notation" in w for w in warnings), \
        f"Expected modifier-disagrees warning, got: {warnings}"
```

Run the tests — expect 3 to fail on the cosmetic gates (G, J, M) and 3 to pass (the controls + the 1d20+2d6 control which only triggers warning site 3617):

```bash
cd ${HOME}/projects/wt-dice-noise-cleanup
./run_tests.sh test_dice_schema_warnings_noise_cleanup
```

**Expected RED**:
- `test_concatenated_notation_no_warning_1d20_plus_2d6` — fails (G + M)
- `test_keep_highest_no_warning_4d6kh1` — fails (M)
- `test_keep_lowest_no_warning_2d20kl1` — fails (M)
- `test_exploding_dice_no_warning_3d6_reroll_1` — fails (M)
- `test_result_total_present_suppresses_missing_raw_rolls` — fails (J)
- 3 controls pass

## Step 2 (GREEN) — minimal production fix

In `mvp_site/narrative_response_schema.py`, add 2 helper functions near the top of `_warn_on_unclean_action_resolution_dice` (line 3469):

```python
def _is_concatenated_notation(notation: str | None) -> bool:
    """True for '1d20+2d6', '2d6+1d4', '1d20-1d4' — multi-die-set strings.

    The validator's _parse_action_resolution_dice_notation returns
    die_type=None for concatenated notation, which currently triggers
    the unparseable-notation warning. This helper identifies the
    pattern so we can suppress the cosmetic warning.
    """
    if not isinstance(notation, str):
        return False
    import re
    return bool(re.search(r"(\d+d\d+)\s*([+\-])\s*(\d+d\d+)", notation))


def _has_keep_drop_modifier(notation: str | None) -> bool:
    """True for '4d6kh1', '2d20kl1', '1d20!', '3d6r1' — keep/drop/explode/reroll.

    These notations intentionally have a different rolls[] count than
    num_dice because the modifier drops or rerolls face values.
    """
    if not isinstance(notation, str):
        return False
    return bool(re.search(r"k[hl]\d+|kr\d+|!|r\d+", notation, re.IGNORECASE))
```

Apply 4 surgical patches:

### Patch 1 — Class G (line 3514)

Gate the unparseable-notation warning on `not _is_concatenated_notation(notation)`:

```python
if die_type is None:
    if isinstance(notation, str) and notation.strip() and not _is_concatenated_notation(notation):
        warning_message = (
            "Dice schema warning: action_resolution.mechanics.rolls"
            f"[{index}] has unparseable notation {notation!r}; "
            "raw dice fields cannot be fully verified."
        )
        _log_thresholded_warning(...)
        self._add_server_system_warning(warning_message)
    if not raw_roll_values:
        warning_message = (
            "Dice schema warning: action_resolution.mechanics.rolls"
            f"[{index}] for {notation!r} is missing raw rolls[] face values."
        )
        _log_thresholded_warning(...)
        self._add_server_system_warning(warning_message)
    continue
```

### Patch 2 — Class J (line 3525)

Inside the unparseable branch, gate the missing-raw-rolls warning on result+total:

```python
    if not raw_roll_values and not (roll.get("result") and roll.get("total")):
        warning_message = (
            "Dice schema warning: action_resolution.mechanics.rolls"
            f"[{index}] for {notation!r} is missing raw rolls[] face values."
        )
        _log_thresholded_warning(...)
        self._add_server_system_warning(warning_message)
```

### Patch 3 — Class J (line 3578)

In the parseable branch, same gate:

```python
    if not raw_roll_values and not (roll.get("result") and roll.get("total")):
        warning_message = (
            "Dice schema warning: action_resolution.mechanics.rolls"
            f"[{index}] for {notation!r} is missing raw rolls[] face values."
        )
        _log_thresholded_warning(...)
        self._add_server_system_warning(warning_message)
```

### Patch 4 — Class M (line 3617)

Gate the count-mismatch warning on concatenate/keep-drop:

```python
    if (
        len(raw_roll_values) != num_dice
        and not _is_concatenated_notation(notation)
        and not _has_keep_drop_modifier(notation)
    ):
        warning_message = (
            "Dice schema warning: action_resolution.mechanics.rolls"
            f"[{index}] raw rolls[] count does not match {notation!r}; "
            f"expected {num_dice}, got {len(raw_roll_values)}."
        )
        _log_thresholded_warning(...)
        self._add_server_system_warning(warning_message)
```

Re-run tests — expect all 8 to pass:

```bash
cd ${HOME}/projects/wt-dice-noise-cleanup
./run_tests.sh test_dice_schema_warnings_noise_cleanup
```

## Step 3 (REFACTOR) — verify existing tests still pass

```bash
cd ${HOME}/projects/wt-dice-noise-cleanup
./run_tests.sh test_narrative_response_schema
```

All 179+ existing tests must pass. The 11 existing warning tests (especially `test_dice_notation_contract_anti_examples_for_concatenated_and_freetext` at line 2201 and `test_action_resolution_dice_zero_modifier_stays_explicit` at line 2438) verify the contracts that the gates preserve.

If `test_dice_notation_contract_anti_examples_for_concatenated_and_freetext` fails, the gate is too permissive — read the test carefully and tighten the concatenation regex.

## Step 4 — lint + format

```bash
cd ${HOME}/projects/wt-dice-noise-cleanup
# Format only touched files (per AGENTS.md: never run pre-commit run -a)
python3 -m ruff format mvp_site/narrative_response_schema.py mvp_site/tests/test_dice_schema_warnings_noise_cleanup.py
python3 -m ruff check --fix mvp_site/narrative_response_schema.py mvp_site/tests/test_dice_schema_warnings_noise_cleanup.py
```

## Step 5 — commit + push + open PR

```bash
cd ${HOME}/projects/wt-dice-noise-cleanup
git add mvp_site/narrative_response_schema.py mvp_site/tests/test_dice_schema_warnings_noise_cleanup.py
git status --short  # MUST show only the two touched files

git commit -m "$(cat <<'EOF'
fix(dice): suppress schema warning noise for concatenated/keep-drop notation

The `_warn_on_unclean_action_resolution_dice` validator was firing on
benign natural dice notation (1d20+2d6, 4d6kh1, 3d6!, etc.), treating
LLM-natural roll output as schema violations. The user's campaign
showed warnings on every combat turn.

This mirrors the PR #8930 pattern (notation_modifier != 0 gate) for
the three cosmetic warnings:
- unparseable notation (3514): gate on _is_concatenated_notation
- missing raw rolls[] (3525, 3578): gate on result+total present
- raw rolls[] count mismatch (3617): gate on concatenated/keep-drop

Real-drift warnings (out-of-range, missing total, modifier disagrees,
result/total mismatch, non-integer raw rolls) still fire.

TDD: 8 new tests in test_dice_schema_warnings_noise_cleanup.py; 3 red
control tests confirm drift warnings still fire. All 179+ existing
tests in test_narrative_response_schema.py still pass.

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"

git push -u origin fix/dice-schema-warnings-noise-cleanup
```

Open PR:

```bash
gh pr create --repo jleechanorg/worldarchitect.ai \
  --base main \
  --title "fix(dice): suppress schema warning noise for concatenated/keep-drop notation (rev-nrd0p)" \
  --body-file <(cat <<'PR_BODY'
## What

Suppress noise warnings in `_warn_on_unclean_action_resolution_dice` for legitimate natural dice notation the LLM emits (`1d20+2d6`, `4d6kh1`, `3d6!`, etc.). Real schema-drift warnings still fire.

## Bug

User reports on `mvp-site-app-s1` campaign `7HHDMPe0wNLBDTfymzfT`: "Dice schema warning: action_resolution.mechanics.rolls[...]" banner fires on every combat turn. PR #8930 (Class D, missing-modifier) already merged but 3 other cosmetic warnings still trigger on benign input.

| Warning | Line | Old behavior | New behavior |
|---|---|---|---|
| unparseable notation | 3514 | always | gate on `_is_concatenated_notation` |
| missing raw rolls[] (1) | 3525 | always | gate on `result`+`total` present |
| missing raw rolls[] (2) | 3578 | always | gate on `result`+`total` present |
| raw rolls[] count mismatch | 3617 | always | gate on concat/keep-drop |

The 7 real-drift warnings still fire.

## TDD

8 new tests in `mvp_site/tests/test_dice_schema_warnings_noise_cleanup.py`:
- 5 RED-then-GREEN: concatenated notation, keep-highest, keep-lowest, exploding dice, result+total suppression
- 3 control (already-GREEN): real drift still warns

All 179 existing tests in `test_narrative_response_schema.py` still pass.

## Coordinate

PR #8951 (`feat/rev-6g6d4-pr8945-followup-fixes`) is in flight and touches the same file for `response_json_schema`. The two fixes are orthogonal — this PR only modifies the validator's gate predicates and adds a new test file. If both PRs land, merge #8951 first, then rebase this one.

## Bead

`rev-nrd0p` (tracker: `${HOME}/projects/worldarchitect.ai/.beads/issues.jsonl`)

## Files

- `mvp_site/narrative_response_schema.py` — 4 surgical patches + 2 helper functions
- `mvp_site/tests/test_dice_schema_warnings_noise_cleanup.py` — 8 tests

PR_BODY
)
```

## Step 6 — drive to green

```bash
for i in {1..20}; do
  sleep 30
  STATUS=$(gh pr view <PR_NUMBER> --json statusCheckRollup -q '[.statusCheckRollup[] | "\(.name)=\(.conclusion // .state)"]' | tr '\n' ' ')
  echo "[$i] $STATUS"
  echo "$STATUS" | grep -qE "FAILURE" && break
done
```

If CodeRabbit leaves CHANGES_REQUESTED, fix per the same TDD discipline. If Green Gate fails on unresolved threads, run `bash ~/.smartclaw/lib/resolve_review_threads.sh <PR_NUMBER>`.

**Do NOT run `gh pr merge` yourself** — skeptic-cron.yml handles auto-merge once the user types `MERGE APPROVED` in the live message.

## Anti-patterns

- **Don't write the production code first.** TDD means RED tests BEFORE the fix. If you write the patch first, you can't tell whether the tests actually exercise the bug.
- **Don't add server-owned fallback prompts.** Root-cause-first skill applies — the canonical fix is to make the validator smarter, not to suppress noise in the LLM prompt.
- **Don't loosen the 7 real-drift warnings.** The 3 cosmetic gates are the only changes.
- **Don't push onto PR #8951's branch.** Coordinate via `references/coordinate-with-pr-8951-2026-08-16.md`.
- **Don't skip the existing test suite check.** 179 existing tests must still pass; if any fail, the gate is too permissive.

## Cross-references

- Site inventory: `references/validator-warning-inventory-2026-08-16.md`
- PR #8951 coordination: `references/coordinate-with-pr-8951-2026-08-16.md`
- PR #8930 (the merged Class D fix that this mirrors): https://github.com/jleechanorg/worldarchitect.ai/pull/8930
- Source file: `mvp_site/narrative_response_schema.py` lines 3469-3646
- Tests: `mvp_site/tests/test_narrative_response_schema.py` line 2201, 2438, 2345
- Root-cause-first skill: `~/.claude/skills/root-cause-first/SKILL.md`
- Drive to green skill: `~/.smartclaw/skills/workflow/drive-pr-to-green/SKILL.md`
