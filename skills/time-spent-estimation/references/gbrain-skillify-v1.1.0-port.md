# Cross-modal eval deferral — gbrain-skillify-v1.1.0 port rationale

The Skillify 11-item contract item #3 calls for cross-modal evaluation across
3 frontier models from 3 different providers. This skill defers that item for
the same reason `skillify` itself does in Hermes:

- The 3-provider eval wiring is not yet present in the Hermes gateway.
- Substituting with `/advice` (single-model adversarial review) is the
  documented Hermes-side substitute per `skillify/SKILL.md` Phase 3.
- This is a **procedural deferral**, not an "N/A" — the skill would
  benefit from cross-modal review before being marketed as production-grade.

## When to revisit

When Hermes gains a multi-provider eval adapter (or when the user explicitly
requests `/er` on a `time-spent-estimation` change), the substitution can be
upgraded to the full 3-provider eval.

## Status

- Item 3: **DEFERRED** (this port file is the audit trail)
- All other items: see `skillify/scripts/skillify_check.py` output