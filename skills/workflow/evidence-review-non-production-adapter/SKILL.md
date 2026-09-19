---
name: evidence-review-non-production-adapter
description: "Adapt /er checks for docs/skill/test-only diffs."
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [macos, linux]
metadata:
  hermes:
    tags: [evidence-review, er, non-production, docs, skills, contract-tests, adapter]
    related_skills: [evidence-review, evidence-standards, requesting-code-review, audit-response-packet-review, drive-pr-to-green]
---

# Evidence Review — Non-Production Adapter

The canonical `/er` skill (`evidence-review`) defines 8 mandatory pre-PASS checks tuned for **production-tier** candidates: BigQuery record resolution, real-LLM callstack verification, bundle SHA256 integrity, public-URL hosting, terminal/Browser GIF+MP4, etc. None of those apply to a candidate whose diff is a `SKILL.md` rewrite, a contract test, a docs edit, or a tools-only refactor.

This skill is the adapter: when `/er` fires on a non-production candidate, swap out the inapplicable checks and substitute the ones that actually matter for that class of work.

## When this fires

| Trigger | Adapted candidate |
|---|---|
| `/er` on a PR whose diff touches only `.md`, `.claude/commands/*`, `.claude/skills/**/SKILL.md`, `tests/test_*.py` contract-style, scripts that wrap other tools, or CI lint | Use this adapter |
| `/er` on `mvp_site/**`, `world_logic.py`, `agents.py`, prompts, schema, runtime config | **Do not** use this adapter — use the canonical /er table as-is |
| `/er` on a "mixed" diff (some production, some non-production) | Apply canonical /er to the production slice and this adapter to the non-production slice, then synthesize |

## Tier classification (first thing to determine)

Read the diff via `git diff --stat HEAD` and `git diff --name-only HEAD` and classify every changed file into one of:

- **Behavioral production code** (`mvp_site/*.py`, `world_logic.py`, `agents.py`, prompts, schema, runtime config) — canonical /er applies
- **Test code only** (`tests/test_*.py` that doesn't touch production) — adapter applies
- **Skill/command markdown** (`.claude/skills/**`, `.claude/commands/*.md`) — adapter applies
- **Docs / README / CLAUDE.md / AGENTS.md** — adapter applies
- **Tooling scripts** (`scripts/*.sh`, `*.sh` outside production code paths) — adapter applies
- **Beads / metadata** (`.beads/issues.jsonl`, `.beads/beads.db`) — adapter applies (treat as non-behavioral)

If **every** changed file falls in the non-behavioral bucket, the canonical /er's verdict ceiling is no longer "PRODUCTION requires PASS" — per the `/green` two-tier rule, the candidate qualifies for **PARTIAL with explicit waiver** as the ceiling.

## Adapted mandatory-check table

For each canonical /er check, here's what stays, what drops, and what replaces it:

| # | Canonical /er check | Non-production behavior |
|---|---|---|
| 1 | Bundle integrity (`checksums.sha256`) | **Drop** — there is no evidence bundle. The candidate IS the source tree. |
| 2 | Verification report ceiling (`verification_report.json`) | **Replace** with **Contract test adequacy** — verify the candidate ships at least one `tests/test_*.py` (or equivalent) that exercises the new claim. Re-run the test live. Record pass count. If a contract test exists, run it and capture the output. If it doesn't exist for a non-trivial claim, that's a PARTIAL ceiling. |
| 3 | Scope note consistency | **Keep** — same logic. If a scope note in CLAUDE.md or the repo's `.claude/skills/evidence-standards.md` excludes the candidate's domain, narrow to in-scope claims. |
| 4 | Video artifacts (Terminal GIF+MP4 / Browser UI GIF+MP4) | **Drop** for docs/skill-only changes (no UI behavior delta). **Keep** for tests that exercise a UI flow. For contract tests, "video" is not required — pass count + test source is sufficient. |
| 5 | Public-URL hosting check | **Drop** — no media assets. |
| 6 | Self-contained / clean-computer reproducibility | **Replace** with **Contract test reproducibility** — run the test from a clean checkout via `python3 -m pytest tests/<file>.py -v` (or equivalent), record pass count + exit code. Document the exact command in the verdict. |
| 7 | Anti-Fabrication & Telemetry Verification (Gates A–G) | **Adapt**: drop BQ record resolution (no LLM telemetry), drop Traceback Code Alignment (no live traceback), drop GREEN payload shape verification (no GREEN payload). **Keep**: Checksum Recomputation if any evidence file is included, is_test Telemetry Verification if any test handle is cited, Harness/Provenance disambiguation (label test-harness evidence as such), Branch/Commit Containment. |
| 8 | Branch & Commit Containment | **Keep** — same logic. `git branch -r --contains <sha>` if the candidate references a SHA. |

## Adapted "proves vs does NOT prove" — mandatory split

The canonical /er requires an explicit "Proves vs Does NOT Prove" split. For non-production candidates, frame it as:

**Proves** — each STRONG-artifact-backed claim, with the literal file:line or test name and the raw observation (e.g., "Aside-MCP first, verified by regex `aside-mcp` matching at byte offset 721 < 882 (Aside CLI) in `.claude/commands/browser.md`").

**Does NOT Prove** — explicitly enumerate:
- **Real E2E not run** — name it. The contract test only verifies text, not runtime. State which live probe is the parent session's responsibility.
- **Layer-2 evidence absent** — name the gap. If a claim would normally require Layer 2 (real-LLM, real-BQ) but the change is non-production, state that Layer-2 evidence is not required per `evidence-standards` Exception 1.
- **Set-completeness blind spots** — if a claim involves a curated list (e.g., "fingerprint-sensitive sites: LinkedIn, banks, Cloudflare"), the contract test verifies the names are present, not that the set is complete. Name that.
- **Frontmatter/body drift** — if the YAML `description` and the body disagree (because the body was rewritten but the description wasn't), flag as a non-blocking recommendation, not a blocker.

## Verdict template (non-production candidates)

Use this exact shape. Adjust category names to match the candidate's territory, but keep the structure:

```text
## Evidence Review Verdict

**Subject**: <one-line description of the candidate>
**Bundle**: <path to source tree or diff>
**Overall**: PASS | PARTIAL | FAIL | INCONCLUSIVE
**Confidence**: HIGH | MEDIUM | LOW

### What This Evidence Proves vs. Does NOT Prove
**Proves**:
- <each STRONG claim with literal file:line + raw observation>

**Does NOT Prove**:
- <real E2E not run, layer-2 gap, set-completeness blind spots, frontmatter drift>

### Claim Map
| # | Claim | Artifact | Quality | Notes |
|---|-------|----------|---------|-------|
| 1 | ...   | file:line | STRONG  | ... |
| 2 | ...   | (none)   | MISSING | ... |

### Mandatory Checks (adapted)
- [x] Bundle integrity: N/A — source-tree diff, not a published bundle
- [x] Contract test adequacy: tests/test_<X>.py, 18/18 PASS
- [x] Scope note consistency: change is unambiguous, in scope
- [x] Video artifacts: N/A — docs/skill-only change, Exception 1
- [x] Public-URL hosting: N/A
- [x] Contract test reproducibility: exact command + exit code captured
- [x] Anti-Fabrication (adapted): no LLM telemetry, no traceback, no GREEN payload; Harness/Provenance labeling correct
- [x] Branch & Commit Containment: SHA verified against branch

### Violations
<none or list>

### Non-blocking findings
1. <recommendations>

### Accepted Exceptions
- Exception 1 (non-production, no evidence required) — applies.
- <other exceptions>

ER_VERDICT: PASS | NOT APPROVED
```

## Pitfalls

1. **Don't accept the candidate's own "Risks" section at face value.** The bead description or PR body often lists risks the parent says it will handle (e.g., "the parent Hermes session will perform the sensitive local verification"). That's a delegation, not a waiver. The /er verdict must reflect the evidence the parent already presented in the chat — re-run live probes where possible, never rely on the candidate's word.

2. **Don't fail the verdict just because the candidate lacks Layer-2 evidence.** Layer 2 (real-LLM, real-BQ) is for production claims. A docs/skill/test candidate has no Layer-2 surface — the absence is correct, not a defect. PARTIAL/PASS judgment is based on the adapted checks, not on the canonical production-tier bar.

3. **Don't promote a candidate to PASS just because "tests pass."** Tests passing proves the test ran and asserted what it was written to assert. It does NOT prove:
   - The test covers the right claims
   - The test is not tautological (asserts something the candidate trivially satisfies)
   - The recipe the test protects actually works at runtime

   For non-trivial claims, open the test source and verify the regex/substring choices are non-trivial (anchored, context-bound, would catch the claimed regressions). If the test is too weak to catch a regression that would matter, that's PARTIAL.

4. **Don't overlook contradictions that the candidate claims to have resolved.** The whole reason a non-production change happens is often to fix a contradiction. Verify the contradiction is actually gone: grep for the old phrase, grep for the new phrase, confirm the old phrase has zero matches and the new phrase has the expected matches.

5. **Don't treat bare-substring checks as defects.** Tests like `assert kw in text` for `"never"` or `"/tmp"` are slightly weaker than regex-anchored matches. For non-production contract tests, this is acceptable. Flag as a non-blocking recommendation, not as a PARTIAL trigger.

6. **Don't miss in-flight edits during /er.** A reference session observed a file changing mid-review (the SKILL.md gained a `trap 'rm -f "$TMP_COOKIES"' EXIT` clause between the first read and the test run). Always re-read files at the time of writing the verdict, and call out the in-flight state in the report.

7. **Frontmatter `description` field is part of the contract.** If the candidate rewrites a SKILL.md body to encode a new routing order but leaves the `description:` field unchanged, that's a contract drift — the description still encodes the old priority. Not a blocker (the body is the operational contract), but flag in non-blocking findings.

## Reference: 2026-08-09 /er on browser command/skill candidate

The first concrete application of this adapter reviewed the `/browser` command + `browser-control` skill + `tests/test_browser_command_contract.py` candidate in `jleechanorg/claude-commands`. The verdict was PASS with 18/18 contract tests passing; the adapted check table documented:

- All 8 mandatory checks adapted (5 N/A, 2 replaced with contract-test-equivalent, 1 kept)
- 14 STRONG claims backed by file:line + raw regex matches
- 6 explicit "Does NOT Prove" items (real cookie E2E not run, no Layer-2 telemetry, curated-list set-completeness, bare-substring test weakness, frontmatter drift, in-flight edit during review)

The verdict was accepted without changes — the adapted table gave the parent session enough information to know exactly which live probes were still owed.

## Pointers

- `references/adapted-check-table-2026-08-09.md` — the full adapted table from the first concrete application, with the literal verdict structure and all 14 STRONG claims. Load when you need a worked example.

## Cross-references

- Canonical /er (user-scope): `~/.claude/skills/evidence-review/SKILL.md` — out of scope to edit; cite by reference.
- Canonical /es (user-scope): `~/.claude/skills/evidence-standards/SKILL.md` — Exception 1 (non-production) and the layer-label rule are the load-bearing policies that justify this adapter.
- `audit-response-packet-review` (this skill's closest cousin) — same shape: claims + cross-check against source + verdict. The skill's "Phase 2 — Cross-check summary claims vs. row data" is the same pattern as "verify each claim against raw worktree contents" here.
- `requesting-code-review` — pre-commit verification of diffs; this adapter is the post-commit counterpart for evidence review of docs/skill-only diffs.
- `drive-pr-to-green` — when /er returns PASS for a non-production candidate, this skill covers the rest of the green-up flow (force-push, CI watch, skeptic gate, auto-merge handoff).