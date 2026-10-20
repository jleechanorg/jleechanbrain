# Case — 2026-08-18 wa-daily-dice-audit cron FAIL (audit-event-source LLM prose leaks)

## Summary

`wa-daily-dice-audit-2026-08-18` Cloud Run job exited 1. Email subject `[GCP Cron] Daily Dice Audit - FAIL`. **6/10 campaigns failed.** Root cause: LLM-side prose contaminated two structured source fields, both of which the cron treats as authoritative.

## What's actually broken (audit-side)

The cron at `scripts/audit_helpers.py:_build_audit_warnings` rejects any roll whose `notation` field fails `_parse_dice_notation`. Today's failures clustered into two audit-side bug classes (NOT the same as the existing `wa-daily-dice-audit-fix` Class A/B/D catalog — both are new variants):

### Bug 1 — `FP_CALC...` non-dice content (audit-event source contamination)

Three campaigns (`LPJW5VT77Pxxvp5dRHdU`, `Mz4s5zy30noDnSgScPJH`, `JCQU5YSOk1DgZVm1wLHV`) at sequence 275 emit rolls with `notation: 'FP_CALC...'` — the literal code-execution stderr tag from the Python dice tool's failure path leaked into the structured `notation` field of `dice_audit_events` (which is the **authoritative** source). The audit rejects it as "unparseable dice notation" and emits `[Integrity Failure]`.

This is NOT a parser bug — `FP_CALC...` correctly fails to parse. The bug is upstream: the dice tool's failure path is writing its stderr tag into the structured field instead of leaving `notation=null` and routing the failure to a separate `error` field.

### Bug 2 — `4x 1d20+7` count prefix (LLM-side prose in structured source)

Same three campaigns at sequence 293 emit rolls with `notation: '4x 1d20+7'` and `4x 1d8+4` — the LLM narrating a "<count>x <dice>" multiplier prefix in prose, which the structured field captured verbatim. `_parse_dice_notation('4x 1d20+7') == None` and `_is_compound_notation('4x 1d20+7') == False` (the regex `\d+d\d+` only finds 1 term). The audit rejects these as unparseable, then cascades into:

- `d8 has 4 impossible values; sample=[0, 9, 0, 9]` — because `4x 1d8+4` was routed to the d8 bucket, but the `result` field contained stacked faces from 4 separate rolls, producing values outside [1,8].

### Bug 3 — `HALCYON DAYS` d20 chi-square 407.15 vs threshold 46.00 (NOT an audit bug)

Real statistical anomaly on campaign `JmSYWVwlcuQNTtd6eFg1`. Split by `by_source` in `summary.json`: 104 of 135 rolls are `action_resolution_rolls` (model-reported, not provably fair). This is a model-side fabrication rate finding (see `wa-dice-integrity-audit` Step 6 provenance split), NOT an audit-pipeline bug.

## What the `wa-daily-dice-audit-fix` skill claimed vs reality

Verified 2026-08-18 by running `git log --oneline origin/main --grep="compound" -i` and `_is_compound_notation('2d10+10+4d6')`:

| Skill claim | Reality on origin/main as of 2026-08-18 |
|---|---|
| Class A (compound) is OPEN, never merged | ✅ CLOSED by PR #8881 (`10b1462b6d`, 2026-08-14) — audit routes compound to `by_die_type["compound"]` |
| 3 bug classes total (A, B, C) | 5 bug classes — today's failures added Class D (`4x <dice>` prefix) and Class E (real chi-square breach on non-provable-fair source) |
| Class B fix recipe: "bucket as unknown notation" | Still correct, still NOT merged. Apply it AND it also catches Class D (`4x 1d20+7` matches the `\d*d\d+` regex's "no leading digit before d" check incorrectly — see "Caveat" below). |

**Caveat on the Class B recipe catching Class D:** the recipe's `re.search(r"\d*d\d+", normalized)` guard does NOT catch `4x 1d20+7` because the string CONTAINS `\d*d\d+` (the `1d20` substring). The recipe needs to additionally reject strings with leading non-dice characters before the first `\d*d` token — i.e. the `4x ` prefix is the problem, not the embedded `1d20`. A precise guard:

```python
# Reject when notation has a leading token that is NOT a dice expression
# (e.g. "4x ", "FP_CALC", "x3 ") before the first \d*d\d+ match.
import re
m = re.search(r"\d*d\d+", normalized)
if not m or normalized[:m.start()].strip() not in ("", "+", "-"):
    # Pure non-dice notation OR leading-count-prefix — bucket as "unknown"
    continue
```

This single guard buckets both Class B (`FP_CALC...` — leading token is `FP_CALC`, not a dice operator) and Class D (`4x 1d20+7` — leading token is `4x `, not empty or `+/-`).

## Recommended fix (one PR, two bug classes)

File: `scripts/audit_helpers.py`, function `_build_audit_warnings`. Add the precise guard above. Plus 2 new tests in `mvp_site/tests/test_audit_dice_rolls.py`:

1. `test_class_b_fp_calc_from_dice_audit_events_does_not_emit_integrity_failure` — assert no `[Integrity Failure]` line for `notation='FP_CALC...'` from source `dice_audit_events`. Verify the roll is bucketed under `by_die_type['unknown']` instead.
2. `test_class_d_4x_count_prefix_bucketed_as_unknown` — assert `notation='4x 1d20+7'` from source `dice_audit_events` is bucketed under `by_die_type['unknown']` and does NOT trigger "d8 has impossible values" or "d20 chi-square" cascades.

Plus a regression guard for the existing Class A (`_is_compound_notation` returns True for compound notation — must NOT regress). Plus the existing 247/247 dice tests must still pass.

## Verification (dry-run against today's GCS evidence)

```python
# In a fresh worktree from origin/main
from mvp_site.action_resolution_utils import _parse_dice_notation
from scripts.audit_dice_rolls import _is_compound_notation
from scripts.audit_helpers import _build_audit_warnings
from collections import defaultdict

# Class A (regression check)
assert _is_compound_notation("2d10+10+4d6")  # must stay True
# Class B
assert _parse_dice_notation("FP_CALC...") is None  # must stay None
# Class D
assert not _is_compound_notation("4x 1d20+7")  # must stay False
# Class D + new guard
import re
m = re.search(r"\d*d\d+", "4x 1d20+7".lower())
assert "4x "[:m.start()].strip() not in ("", "+", "-")  # prefix guard fires
```

After the fix, the next cron run (~04:00 UTC / 21:00 PT) should produce a `summary.json` with `"status": "PASS"` for the 3 noctune campaigns. The chi-square breach on `HALCYON DAYS` will remain — that's a model-side problem, separate bead.

## Lessons captured

1. **Always verify a loaded skill's "Status on origin/main" field via `git log` before trusting it.** The `wa-daily-dice-audit-fix` skill was 4 days stale on Class A status, costing the diagnostic cycle ~10 minutes of believing an already-solved bug was open.
2. **The audit-side `4x <dice>` count prefix is a NEW bug class** that neither the skill catalog nor the `_is_compound_notation` regex catch. The fix is a leading-token guard, not a parser extension.
3. **Chi-square breaches on `action_resolution_rolls` source are not audit bugs** — split by `by_source` before assuming the audit pipeline is wrong.
4. **The dice tool's failure path writes stderr tags into the structured `notation` field.** This is an upstream bug in the dice tool, not the audit. Same family as #9021/#9057 (LLM prose contaminating structured source fields) — the fix is upstream (the dice tool's failure path needs to leave `notation=null` and route to a separate `error` field), not a parser bandaid.

## Cross-references

- `wa-daily-dice-audit-fix` (user-owned, blocked from auto-patch — needs `hermes curator adopt wa-daily-dice-audit-fix`) — the cron-side recipe
- `wa-dice-integrity-audit` — Step 6 provenance split for the `HALCYON DAYS` chi-square breach
- `wa-narrative-schema-required-fields-contract` — Layer 2 served-prompt contract test pattern
- SOUL.md `## COMMIT: wa-llm-output-emission-false-green-watchdog` — the 3-layer framework
