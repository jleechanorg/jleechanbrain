# <Product> × <Rubric> Scorecard

**Rubric source**: <URL>
**Worktree**: <branch> from origin/main @ <SHA>
**Probe bank (private)**: <path>
**Status**: <static audit complete | dynamic probes complete | both complete>

## Methodology

<Rubric source URLs, axes, scoring scale, pass threshold.>

## Per-axis findings

| # | Axis | Score | Evidence | Pass? |
|---|---|---|---|---|
| 1 | <axis name> | <0-5> | evidence/<file>:<line> | ✅ / ⚠️ / ❌ |
| 2 | <axis name> | <0-5> | <evidence> | <emoji> |
| ... | ... | ... | ... | ... |

### Axis 1 — <name>

**Primitive expected:** <architectural artifact>
**Primitive found:** <file>:<line> evidence.
**Primitive missing:** <gap if any>
**Predicted score:** <0-5> with one-line rationale.

<Repeat per axis.>

## Pass criterion

≥6/7 axes at ≥3.5, no axis <2.0. **Result: PASS / FAIL.**

## Dynamic probe results

(If dynamic probes ran — per-probe PNG + state JSON + transcript + conclusion.)

| Probe | Axis | Result | Evidence |
|---|---|---|---|
| P-01 | memory | exact recall | evidence/P-01.png + evidence/P-01-firestore.json |
| ... | ... | ... | ... |

## Follow-up work

- <Axis> <3.5 → triage ticket <issue-link>.
- <Specific gap> → <fix suggestion>.
- <Longevity / out-of-scope axis> → <Extended tier required>.

## Provenance

- Audit doc: <path>
- Probe bank: <path>
- Worktree: <branch> @ <SHA>
- Worker session: <proc-id> (if dynamic probes ran)
