---
description: Evidence Review — runs /evidence_review then /es, synthesizes both results
type: orchestration
execution_mode: immediate
---

# /er — Evidence Review (with Evidence Standards)

Runs both `/evidence_review` AND `/es` on the same target so a single command covers bundle structure/integrity/measurement **and** claim-to-evidence standards compliance.

**Usage**: `/er [subject or path]`

## Action

Execute these steps in order:

### Step 1 — Evidence Review

1. Resolve the skill path:
   - Use `~/.claude/skills/evidence-review/SKILL.md` when it exists.
   - Otherwise use `.claude/skills/evidence-review.md`.
   - If neither path exists, stop and report that the evidence-review skill is missing.
2. Load the selected `SKILL.md` content into this command context as the active evidence-review rules.
3. Invoke the evidence-review dispatcher against `$ARGUMENTS` using those loaded rules. **Run inline** (not as a delegated async command) — load the skill, execute the review steps in-process, and collect the verdict before proceeding to Step 2.

### Step 2 — Evidence Standards (/es)

4. Run `/es` against the same `$ARGUMENTS`:
   - Read `~/.claude/skills/evidence-standards/SKILL.md` — general cross-project standards.
   - Read `.claude/skills/evidence-standards.md` — project-specific standards (if present).
   - Evaluate the evidence against both standards layers.

### Step 3 — Synthesis

5. Combine both results into a single verdict:
   - **Evidence Review findings** (bundle integrity, test coverage, claim-to-artifact mapping)
   - **Evidence Standards findings** (class compliance, media requirements, claim floor, authenticity)
   - **Overall verdict rules** (deterministic — identical inputs produce identical verdicts):
     - PASS: no step FAIL or INCONCLUSIVE, and at least one step returns PASS (WARN does not count as PASS; it is a distinct outcome)
     - WARN: no step FAIL or INCONCLUSIVE, no step PASS, at least one step WARN — document caveats from all WARN steps
     - FAIL: any step FAIL
     - INCONCLUSIVE: any step INCONCLUSIVE and no step FAIL → treated as FAIL for harness gates
6. For each claim, explicitly state what the evidence **proves** and what it **does NOT prove**.

## Why both?

`/evidence_review` checks the *bundle* (files exist, structure correct, no circular citations).
`/es` checks the *claims* (evidence actually proves what's claimed, not just asserted).
Running only one misses real gaps — e.g., a well-structured bundle with weak or fabricated evidence passes `/evidence_review` but fails `/es`.

**Caveats**: The "proves vs does NOT prove" reconfirmation is mandatory — do not skip it even if both steps individually pass.
