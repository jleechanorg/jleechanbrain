---
name: second-opinion-pr-review
description: "Use when user asks for a second opinion on a PR."
related_skills: [github-code-review, requesting-code-review]
---

# Second-Opinion PR Review

Independent verification of a PR's claims — the PR body's evidence, risk
assessment, and CI-failure assertions — not just the PR's code diff. This
goes beyond the standard `github-code-review` skill when the PR contains
self-validating sections the author wrote about their own work.

**Decision matrix:**

- `APPROVED` — every category ✅, no open followups.
- `APPROVED_WITH_NOTES` — one or more ⚠️, PR mergeable as-is (followups land in separate PR).
- `CHANGES_REQUESTED` — any 🔴. Block merge.

**When to use:**

- User says "second opinion", "audit the PR", "check the PR body's claims",
  "verify the evidence is real", "independently review".
- PR body contains any of `## Evidence`, `## CI Evidence` with specific test
  names + pass counts; `## Pre-existing failures` claiming failures are inherited
  from base; `## Risk` with specific named concerns; `## Followup` listing future
  work in this PR's blast radius.
- PR modifies a constructor signature on a class with >10 callsites.
- PR bumps a `prompt_tool_contracts.json`-style hash manifest.

**Skip for:** routine small PRs (<100 lines, no constructor changes, no CI
claims). Use the standard `github-code-review` skill for that.

## The 5 verification checks (independent of the standard diff review)

### A. Verify "pre-existing on origin/main" claims locally

The PR author often cites an ImportError or symbol name. Their citation may be
**wrong** even when the substance is right. Always reproduce.

```bash
# 1. Check out the base branch state into working tree (without changing HEAD)
git checkout origin/main -- path/to/suspected_file.py
PYTHONPATH=. python3 -m pytest --collect-only mvp_site/tests/test_world_logic.py 2>&1 | tail -20

# 2. Confirm the cited symbol actually exists on origin/main
git show origin/main:mvp_site/llm_service.py 2>/dev/null | grep -n 'CitedSymbol'

# 3. Check the PR didn't touch the files blamed for the failure
git diff origin/main..HEAD --name-only -- 'mvp_site/llm_service.py' 'mvp_site/llm_providers/'
# Empty = PR didn't touch them = PR can't be blamed.

# 4. Reset working tree cleanly
git reset --hard HEAD
```

**Pitfall:** imports cascade — read the full traceback to the real cause. In
the 2026-08-07 PR #8811 review, the PR body claimed `ProviderSelection` was
missing. Reality: it existed (line 758). The actual error was a different
symbol in `gemini_provider`, masked by a deeper `google-genai` API drift.

### B. Run the PR's claimed test counts

The PR body usually claims "23/23 PASS" or "5/5 E2E in 27s". Reproduce.

```bash
git fetch origin <branch>
git checkout origin/<branch> -- path/to/changed_files   # only stage what you need
python3 -m pytest mvp_site/tests/test_action_resolution.py -v 2>&1 | tail -30
python3 -m pytest mvp_site/tests/test_end2end/ -v 2>&1 | tail -20
git reset --hard HEAD
```

Compare counts to the PR body line-by-line. Discrepancies are a red flag —
either the PR body is stale or the local env differs. Timing differences
(<2x) are not concerning.

### C. Verify contract hashes when present

```bash
grep '"sha256"' mvp_site/schemas/prompt_tool_contracts.json
sha256sum mvp_site/narrative_response_schema.py
```

Mismatch = hash commit wrong or contract gate will fail in CI.

### D. Audit producer callers for the modified class

When the PR adds/reorders a parameter on a widely-used class, scan all
non-test callsites for positional-arg risk:

```bash
grep -rn 'ClassName(' --include='*.py' \
  | grep -v 'test_' \
  | grep -v 'class_def_module' \
  | grep -v '.claude/worktrees' \
  | grep -v 'wt-' \
  | grep -v '.worktrees/'
```

For each callsite, check whether positional args past the new param could collide.
If every callsite uses kwargs, the positional-arg risk is theoretical and the
PR is safe.

### E. Cross-check CodeRabbit / automated reviewer findings

Fetch via `gh pr view N --json reviews`. Don't accept/reject wholesale —
verify each:

- "Constructor param ordering risk" → check callers all use kwargs.
- "Edge case X not tested" → check the test suite; if not, propose a test.
- "Production callsite should pass X" → check the callsite actually does.

## Output shape

```markdown
## Verdict: [APPROVED | APPROVED_WITH_NOTES | CHANGES_REQUESTED]

### Findings (numbered, by category)
1. Backward compatibility — ✅ Safe / ⚠️ One issue / 🔴 Breaking
2. Logic correctness — ✅ Correct / ⚠️ Edge case / 🔴 Bug
3. Test quality — ✅ Strong / ⚠️ Adequate / 🔴 Insufficient
4. Documentation — ✅ Excellent / ⚠️ / 🔴 Missing
5. Risk assessment — ✅ / ⚠️ / 🔴
6. CI evidence — ✅ / ⚠️ / 🔴

### Per-finding bullets (with file:line)
- cite evidence, name the specific followup for ⚠️ issues.

### One-line summary
[2-3 sentences, the most important observation]

### Files modified by review
None — verification only.
```

## Edge cases worth 5 seconds of thought

| Edge case | Why it matters |
|-----------|----------------|
| `field is None` when LLM emits null | `field for field in required_fields if field not in validated` doesn't catch `field = None`. |
| Empty string `""` vs missing key | Should behave the same; check both paths. |
| List defaulting (`audit_flags=[]`) | Mutation hazards if the same default object is reused across instances. |
| Constructor positional ordering | New param between old params = silent breakage for positional callers. |
| `to_dict()` round-trip | Defaults should serialize identically to fresh construction. |

## Pitfalls

1. **Don't echo the PR's framing.** If the PR says "this is pre-existing",
   verify it. Don't rephrase as your own finding without verifying.
2. **Don't trust reviewer counts from the PR body.** A `5/5 PASSED` claim is a
   data point to verify, not a fact to accept.
3. **The cited symbol is often the wrong one.** Read the full traceback.
4. **Edge case `: None` is the most commonly missed edge case in validators.**
   A new validator that fixes a missing-fields warning but leaves `value=None`
   unhandled is a half-fix.
5. **Constructor param between existing params = silent positional break.**
   Always check callers.
6. **Keep verdicts short.** ~30 lines max. The user wants a binary decision +
   cited evidence, not an essay. If your verdict needs a TL;DR, the bullets
   are too long.
7. **Reset the working tree cleanly at the end.** Future sessions start from
   `git status`; a dirty tree blocks them.

## Reference example: 2026-08-07 PR #8811

Second-opinion review for `fix(action_resolution): context-aware validator
prevents noisy warnings on non-combat turns` on jleechanorg/worldarchitect.ai.

| Step | Tool / Output | Outcome |
|------|---------------|---------|
| 1. Fetch PR + diff | `gh pr view 8811 --json ...` | 6 files, 776+/10- |
| 2. Verify test counts | `pytest mvp_site/tests/test_action_resolution.py` | 23/23 passed in 0.15s ✅ |
| 2. Verify test counts (e2e) | `pytest .../test_action_resolution_validation_e2e.py` | 5/5 passed in 27.15s ✅ |
| 2. Verify hash | `sha256sum narrative_response_schema.py` vs contract | Match ✅ |
| 3. Verify CI claim | `git show origin/main:llm_service.py \| grep ProviderSelection` | Symbol DOES exist (line 758); PR body claim **inaccurate but substance correct** |
| 3. Reproduce | `pytest --collect-only test_world_logic.py` on origin/main | Reproduces — confirms pre-existing |
| 3. Confirm not introduced | `git diff origin/main..HEAD -- llm_service.py llm_providers/` | Empty output ✅ |
| 4. Audit callsites | `grep -rn NarrativeResponse\( ...` | All kwarg-style, safe ✅ |
| 5. CodeRabbit findings | `gh pr view 8811 --json reviews` | 9 findings; 3 actionable but theoretical, 6 noise |
| Output | Structured verdict | `APPROVED_WITH_NOTES` |

The review caught an inaccurate citation in the PR body (substance right,
symbol wrong) without blocking the merge — the right outcome.

## Pointers

- `references/second-opinion-checklist.md` — full verification recipes, copy-paste commands, and audit checklists.
- `references/edge-case-spotters.md` — narrow set of edge cases worth a 5-second probe for validators / constructors / serializers.
