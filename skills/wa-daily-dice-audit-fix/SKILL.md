---
name: wa-daily-dice-audit-fix
description: "Use when the GCP cron `wa-daily-dice-audit` exits 1. Diagnoses the two recurring integrity-failure bug classes (compound concatenated notation like `2d10+10+4d6`, and non-dice content like `fp_calc` leaking into the `notation` field) and ships a fix PR that drives the cron to PASS on the next run."
tags: [worldarchitect, dice, audit, cron, gcp, worldai, daily-dice-audit, integrity-failure]
---

# wa-daily-dice-audit-fix

The GCP cron `wa-daily-dice-audit` (Cloud Run job in project `worldarchitect-ai`, target `mvp-site-app-stable-i6xf2p72ka-uc.a.run.app`) has been failing intermittently since 2026-06 with two recurring integrity-failure bug classes. This skill captures the diagnosis and fix recipe.

## When to use

- Email subject `[GCP Cron] Daily Dice Audit - FAIL (daily-dice-audit-YYYY-MM-DD)`
- Slack message: `[GCP Cron] Daily Dice Audit - FAIL` in `#worldai` or `#worldai-bugs`
- Cloud Run job `wa-daily-dice-audit-XXXXXX` exit 1
- GCS evidence at `gs://wa-test-evidence/daily-dice-audit/YYYY-MM-DD/{summary.json,scenario_results_checkpoint.json,test_output.log}`

## Diagnosis — 3 bug classes

The audit logic at `scripts/audit_helpers.py:111` (`_build_audit_warnings`) emits `[Integrity Failure]` for any roll whose `notation` field is rejected by `_parse_dice_notation`. Three bug classes recur:

### Class A — Compound concatenated notation
- Symptom: `notation: '2d10+10+4d6'` (model glues two dice rolls into one field)
- Side effect: `d10 impossible values [16, 16]` because the audit routes the roll to the d10 bucket (first die) while the `result` field contains d6 faces
- First-occurrence example: `rhaenrya house dragon` (`f1SUHCwB6kgh0VjCBBaF`) sequences 60 and 70
- Daily instances: 2026-08-11, 2026-08-12, 2026-08-13

### Class B — Non-dice content in notation
- Symptom: `notation: 'fp_calc...'` (literal non-dice text leaks into the field)
- Example: `Overlord shy lich` (`JQeI1Aq5YGnAuuuGIlDK`) sequence 312
- Source: typically `dice_audit_events` (authoritative), occasionally `text_pattern` (prose-derived)

### Class C (incidental) — Brand-new campaigns with zero dice rolls
- `quick-start-dragon-knight-*` campaigns created on the audit day
- Correctly returns PASS via the existing `MIN_ENTRIES_FOR_BRAND_NEW = 5` skip in `audit_dice_rolls.py:1183`
- NOT a bug. Must NOT regress.

## Prior attempts that didn't land

The following commits/branches addressed the same problem but **never merged to origin/main**:
- `06265db0cd fix(dice): [agento] implement compound dice notation parser and fix audit false positives`
- `86d18420ac claude/sonnet: fix(dice): address codex blocker — split audit predicate, update test expectations`
- `bfd3dbe37f gemini/3.6-flash: Support compound dice damage notation, e.g. Divine Smite (rev-euebc)`
- `fix/dice-parser-permissive-rewrite-r1`, `fix/dice-notation-data-fix`, `fix/dice-notation-contract-anti-examples`, `fix/dice-composite-notation-prompt-schema`, `fix/audit-ignore-multi-dice-totals`

Verify none merged via:
```
git -C ~/projects/worldarchitect.ai log --oneline origin/main -- mvp_site/action_resolution_utils.py | head -10
git -C ~/projects/worldarchitect.ai log --oneline origin/main | grep -iE "compound.*notation|fix.dice" | head -10
```

## Fix recipe (proven 2026-08-13, landed in PR #8863)

Six files, +278 / -12 LOC, 3 commits, 247/247 dice tests passing.

### 1. Extend `_parse_dice_notation` for compound notation

In `mvp_site/action_resolution_utils.py`, the parser already has a "modifier followed by `d`" branch. Replace the loose character-class check with a recursive parser call so the tail must parse as a complete dice expression:

```python
# In _parse_dice_notation, replace:
if not _is_pure_compound_notation(text[modifier_end:]):
    return None
# With:
if _parse_dice_notation(text[modifier_end:]) is None:
    return None
```

This rejects malformed suffixes like `1d20+5+1d6+` (trailing `+`), `1d20+5+1d6kh` (incomplete kh), `1d20+5_+1d6` (underscore).

### 2. Audit predicate: bucket non-dice content as "unknown notation"

In `scripts/audit_helpers.py` (`_build_audit_warnings`), the predicate guards:

```python
if not re.search(r"\d*d\d+", normalized):
    # Pure non-dice notation (no d<N> at all) — bucket as "unknown
    # notation" for ALL sources. "Unparseable dice notation" means
    # "we tried to parse this as dice and couldn't"; if the notation
    # isn't dice at all, the label is misleading and would cascade to
    # a false [Integrity Failure] (cron exit 1) for the user's actual
    # case (fp_calc leaking into the notation field of an authoritative
    # dice_audit_events record). The by_die_type bucket records it as
    # "unknown" so the prompt-fix pipeline catches non-dice content
    # via a separate audit.
    continue
```

**Critical:** do NOT emit "unparseable dice notation" for non-dice content even when the source is authoritative. The `by_die_type` bucket still catches it as "unknown" for the prompt-fix pipeline.

### 3. Audit routing: compound notation → `by_die_type["compound"]`

In `scripts/audit_dice_rolls.py` (`audit_campaign_dice`, ~line 1253), add a guard before the `re.search(r"d(\d+)", notation)` routing:

```python
# Compound notation (multiple d<N> terms, e.g. 2d10+10+4d6) doesn't
# belong to any single-die bucket — the stacked result field may mix
# faces from multiple dice. Route to a dedicated "compound" bucket so
# per-die bounds checks (which would falsely flag d6 faces as
# "impossible values for d10") are skipped.
if isinstance(notation, str) and _is_compound_notation(notation):
    by_die_type["compound"].append(roll)
    continue
```

### 4. `_is_compound_notation` helper

Add to `scripts/audit_dice_rolls.py` (lazy import to avoid circular):

```python
def _is_compound_notation(text: str) -> bool:
    """Delegate to parser; require 2+ d<N> terms to distinguish from
    a single-die with stacked flat modifiers."""
    if not text:
        return False
    normalized = text.strip().lower()
    if not normalized:
        return False
    if len(re.findall(r"\d*d\d+", normalized)) < 2:
        return False
    from mvp_site.action_resolution_utils import _parse_dice_notation
    return _parse_dice_notation(normalized) is not None
```

### 5. Tests

- `mvp_site/tests/test_action_resolution_utils.py`:
  - 2 new tests cover compound-notation acceptance and non-dice-prefix rejection
  - 1 existing test (issue #7371 composite-with-annotations) updated to reflect new contract — pure compound accepted, annotated composite still rejected
- `mvp_site/tests/test_audit_dice_rolls.py`:
  - 1 test covers audit predicate guard (Bugbot round-2 case: `fp_calc` from `dice_audit_events` must NOT emit "unparseable dice notation")
  - 1 test covers `_is_compound_notation` helper (compound + malformed + underscore + trailing `+` + incomplete kh)
  - 1 test covers brand-new-campaign regression guard (`MIN_ENTRIES_FOR_BRAND_NEW` unchanged at 5)
- `mvp_site/tests/test_fix_dice_notation_concat.py`:
  - 1 test updated to use annotated concat fixtures (parens, prose) since pure compound is now accepted by the parser

### 6. Pre-existing failure to NOT touch

`mvp_site/tests/test_dice_server_field_security.py::TestLLMServiceSecurityIntegration::test_end_to_end_with_malicious_llm_response` AND `mvp_site/tests/test_narrative_response_schema.py` both fail identically on origin/main (verified: same SHA, same assertion, same fixture). NOT caused by this fix — call out in PR body and link to verification.

## Verification (dry-run against today's failing rolls)

```python
from mvp_site.action_resolution_utils import _parse_dice_notation
from scripts.audit_dice_rolls import _is_compound_notation
from scripts.audit_helpers import _build_audit_warnings
from collections import defaultdict

# Class A
parse_dice_notation("2d10+10+4d6")  # → _DiceNotation(count=2, sides=10, modifier_terms=(10,))
_is_compound_notation("2d10+10+4d6")  # → True

# Class B
warnings = _build_audit_warnings(
    [{"notation": "fp_calc", "sequence_id": 312, "source": "dice_audit_events"}],
    {"dice_audit_events": 1},
    defaultdict(list, {"unknown": [{"notation": "fp_calc", "sequence_id": 312, "source": "dice_audit_events"}]}),
    campaign_id="test",
)
assert not any("unparseable dice notation" in w.lower() for w in warnings)  # Cron exit 0
```

## Code review feedback (CodeRabbit + Bugbot)

- **P1 (Bugbot round-1)**: Compound notation routing was added but NOT wired into `audit_campaign_dice`. Hook `_is_compound_notation` into the per-roll routing loop.
- **P1 (Bugbot round-2)**: Do NOT emit "unparseable dice notation" for non-dice content even from authoritative sources. The label is semantically wrong ("we tried to parse this as dice and couldn't" — but we never tried because the notation isn't dice at all). Bucket as "unknown notation" for ALL sources.
- **P2**: `_is_pure_compound_notation` accepted malformed suffixes. Use recursive parser call instead of loose character-class check.
- **Major**: Remove underscore from allowed character class in `_is_compound_notation`. Documented dice alphabet excludes it.
- **Critical**: Move local imports (inside test methods) to module-level import group.

## Pre-flight checklist

- [ ] Branch from `origin/main` (verify `git log origin/main -- mvp_site/action_resolution_utils.py` doesn't already have a compound-notation fix that would conflict)
- [ ] Run `pytest mvp_site/tests/test_audit_dice_rolls.py mvp_site/tests/test_action_resolution_utils.py mvp_site/tests/test_dice_provably_fair.py mvp_site/tests/test_dice_integrity_helpers.py mvp_site/tests/test_fix_dice_notation_concat.py mvp_site/tests/test_dice_compound_notation.py mvp_site/tests/test_dice_logging.py mvp_site/tests/test_dice_prompt_advantage_disadvantage.py` — must be 247/247 PASS
- [ ] Dry-run against today's actual GCS evidence rolls (download `test_output.log`, run the audit, verify zero `[Integrity Failure]` for Class A + B)
- [ ] Verify `test_dice_server_field_security::test_end_to_end_with_malicious_llm_response` AND `test_narrative_response_schema.py` fail identically on origin/main BEFORE the PR (per `same-test-name-rule`)
- [ ] Commit subject prefixed with `claude/<model>:` per `.cursor/rules/env-preferences.mdc`
- [ ] PR body links to GCS evidence + 3-day failure timeline + pre-existing failure verification
- [ ] Open PR; wait for CodeRabbit re-review + Bugbot re-review after each push

## Post-merge verification

- Next GCP cron run (~04:00 UTC / 21:00 PT) should produce a `summary.json` with `"status": "PASS"` and empty `errors` arrays for `rhaenrya house dragon` and `Overlord shy lich`
- Email subject should be `[GCP Cron] Daily Dice Audit - PASS (daily-dice-audit-YYYY-MM-DD)`
- If cron still FAILs, the next-day GCS evidence at `gs://wa-test-evidence/daily-dice-audit/YYYY-MM-DD/summary.json` will reveal which bug class is still firing (compound notation in `unparseable dice notation` lines, or non-dice content in `unparseable dice notation` lines, or a new class altogether)
