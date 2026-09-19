# Second-Opinion PR Review Checklist

Companion to `second-opinion-pr-review` SKILL.md. Run the steps in order. Each
step has copy-paste commands you can drop into a terminal. Fill in the table
at the end to formalize the verdict.

---

## Step 1 — Fetch the PR the right way

Use `gh pr view` with structured JSON, not just text:

```bash
gh pr view 8811 --repo OWNER/REPO \
  --json title,body,author,headRefName,baseRefName,state,additions,deletions,changedFiles,files,commits,reviews
```

Then the diff:

```bash
gh pr diff 8811 --repo OWNER/REPO
```

For very large diffs, get the file list first:

```bash
gh pr view 8811 --repo OWNER/REPO --json files \
  --jq '.files[] | "\(.path) +\(.additions) -\(.deletions)"'
```

---

## Step 2 — Verify the PR's claimed test counts

The PR body usually claims "23/23 PASS" or "5/5 E2E in 27s". Reproduce.

```bash
git fetch origin <branch>

# Stage just the changed files (so you can run the tests without a full checkout)
git checkout origin/<branch> -- path/to/file.py path/to/test_file.py

# Run the claimed test sets
python3 -m pytest mvp_site/tests/test_action_resolution.py -v 2>&1 | tail -30
python3 -m pytest mvp_site/tests/test_end2end/test_action_resolution_validation_e2e.py -v 2>&1 | tail -20

# Verify hash if it's a contract hash PR
grep '"sha256"' mvp_site/schemas/prompt_tool_contracts.json
sha256sum mvp_site/narrative_response_schema.py
```

Fill in:

| Claim in PR body | Local observed | Match? |
|------------------|----------------|--------|
| `23/23 PASSED in 0.31s` | `23 passed in 0.15s` | ✅ (timing can vary) |
| `5/5 PASSED in 27.88s` | `5 passed in 27.15s` | ✅ |
| `sha256: 153716f8...` | `153716f8ca75cd11ff...` | ✅ |
| `36+ ERROR events on production` | (cannot reproduce — producer data) | n/a |

Discrepancies in test counts are a real concern. Timing differences <2x are not.

---

## Step 3 — Verify "pre-existing on main" claims

This is the highest-leverage check. PR authors typically cite an ImportError or
symbol name; their citation is **often wrong**, the substance **may still be
correct**. Always reproduce.

```bash
# 1. Confirm the cited file on origin/main
git show origin/main:mvp_site/llm_service.py 2>/dev/null | grep -n 'CitedSymbol'

# 2. Reproduce the failure on origin/main
git checkout origin/main -- path/to/suspected_broken_module.py
PYTHONPATH=. python3 -m pytest --collect-only mvp_site/tests/test_offending_file.py 2>&1 | tail -20

# 3. Confirm the PR didn't touch the cited file
git diff origin/main..HEAD --name-only -- 'mvp_site/llm_service.py' 'mvp_site/llm_providers/'
# Empty = PR didn't touch them = PR can't be blamed.

# 4. Reset working tree
git reset --hard HEAD
```

**Pattern from 2026-08-07 PR #8811:**

- PR body: "ImportError on origin/main: `ProviderSelection` does not exist in `llm_service.py`"
- Reality: `ProviderSelection` DOES exist in `origin/main` (line 758).
- Actual error: `cannot import name 'apply_code_execution_system_instruction' from 'gemini_provider'`
- Cascade: that error masks a deeper `google-genai` API drift (`HARM_CATEGORY_HATE_SPEECH` removed).

Substance was right (failures are pre-existing) but the specific symbol cited
was wrong. Always read the **full traceback** to the real cause.

---

## Step 4 — Audit producer callers for the modified class

When the PR adds or reorders a parameter on a widely-used class, scan all
non-test callsites for positional-arg risk.

```bash
# Find production callsites only
grep -rn 'ClassName(' --include='*.py' \
  | grep -v 'test_' \
  | grep -v 'class_def_module_name' \
  | grep -v '.claude/worktrees' \
  | grep -v 'wt-' \
  | grep -v '.worktrees/'
```

For each callsite, check whether positional args past the new param could collide.
If every callsite uses kwargs, the positional-arg risk is theoretical and the
PR is safe.

**Template grep for the diff scope:**

```bash
git diff origin/main..HEAD --stat
# Each line should match the PR body's "Files changed" list.
# Extra lines = undeclared changes (unusual but possible).
```

---

## Step 5 — Cross-check CodeRabbit / automated reviewer findings

PRs often have 5-10 auto-generated suggestions. Don't accept or reject wholesale —
verify each:

| CodeRabbit finding | Verification |
|--------------------|--------------|
| "Constructor param ordering risk" | check callers all use kwargs |
| "Edge case X not tested" | check the test suite covers it; if not, propose a test |
| "Production callsite should pass X" | check the listed callsite actually does |
| "Tests are unit tests not e2e" | verify the layer claim in the PR body matches reality |
| "Anonymize PII in comments" | if real PII concern, flag; if conventional, ignore |

Fetch all reviews with:

```bash
gh pr view 8811 --repo OWNER/REPO --json reviews

# Or one specific reviewer
gh pr view 8811 --repo OWNER/REPO --json reviews \
  --jq '.reviews[] | select(.author.login == "coderabbitai") | .body'
```

---

## Step 6 — Spot-check edge cases

See `edge-case-spotters.md` for the narrow spotter set. Five-second probes:

- `field is None` — does the `field in dict` check catch it? (No.)
- Empty string `""` vs missing key — same behavior expected.
- List defaulting — is the same default object reused? (mutation hazard.)
- Constructor positional ordering — new param between old params = positional break.
- `to_dict()` round-trip — defaults should serialize identically.

---

## Step 7 — Write the verdict

Use the output shape from SKILL.md:

```markdown
## Verdict: [APPROVED | APPROVED_WITH_NOTES | CHANGES_REQUESTED]

### Findings
1. Backward compatibility — ✅ Safe / ⚠️ One issue / 🔴 Breaking
2. Logic correctness — ✅ Correct / ⚠️ Edge case / 🔴 Bug
3. Test quality — ✅ Strong / ⚠️ Adequate / 🔴 Insufficient
4. Documentation — ✅ Excellent / ⚠️ / 🔴 Missing
5. Risk assessment — ✅ / ⚠️ / 🔴
6. CI evidence — ✅ / ⚠️ / 🔴

### Per-finding bullets (with file:line)
- ...

### One-line summary
[2-3 sentences, the most important observation]

### Files modified by review
None — verification only.
```

---

## Reference example: 2026-08-07 PR #8811

Second-opinion review for `fix(action_resolution): context-aware validator
prevents noisy warnings on non-combat turns`. Sequence executed:

| Step | Tool / Output | Outcome |
|------|---------------|---------|
| 1. Fetch PR + diff | `gh pr view 8811 --json ...` and `gh pr diff 8811` | 6 files, 776+/10- |
| 2. Verify test counts | `pytest mvp_site/tests/test_action_resolution.py` | 23/23 passed in 0.15s ✅ |
| 2. Verify test counts (e2e) | `pytest .../test_action_resolution_validation_e2e.py` | 5/5 passed in 27.15s ✅ |
| 2. Verify hash | `sha256sum narrative_response_schema.py` vs contract | Match ✅ |
| 3. Verify CI claim | `git show origin/main:llm_service.py \| grep ProviderSelection` | Symbol DOES exist (line 758); PR body claim **inaccurate but substance correct** |
| 3. Reproduce | `pytest --collect-only test_world_logic.py` on origin/main | Reproduces — confirms pre-existing |
| 3. Confirm not introduced | `git diff origin/main..HEAD -- llm_service.py llm_providers/` | Empty output ✅ |
| 4. Audit callsites | `grep -rn NarrativeResponse\( ...` | All kwarg-style, safe ✅ |
| 5. CodeRabbit findings | `gh pr view 8811 --json reviews` | 9 findings; 3 actionable but theoretical, 6 noise |
| Output | Structured verdict | `APPROVED_WITH_NOTES` |

The review caught an inaccurate citation in the PR body without blocking the merge.
