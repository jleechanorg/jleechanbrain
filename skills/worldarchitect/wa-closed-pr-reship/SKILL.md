---
name: wa-closed-pr-reship
description: "Use when re-shipping a closed PR on a fresh branch."
version: 1.1.0
author: claude/MiniMax-M3
license: MIT
tags: [worldarchitect, pr, replay, cherry-pick, closed-pr, re-ship, same-test-name-rule, ci-gates, scope-creep, duplicate-pr, evidence-bundle]
metadata:
  hermes:
    tags: [worldarchitect, pr, replay, cherry-pick, closed-pr, re-ship, ci-gates, scope-creep, duplicate-pr, evidence-bundle]
    related_skills:
      - wa-daily-dice-audit-fix
      - wa-cloud-logging-diag
      - finish-the-job
---

## When to use

- Closed-but-not-merged PR exists with cherry-pick-able commits that the team wants to re-ship
- `gh pr list --state closed --search "<topic>"` returns matches that were never merged
- The original PR's base branch is significantly diverged from current `origin/main`
- The current skill that originally documented the fix is user-owned (cannot be auto-patched)

Trigger phrases:
- "re-ship that closed PR"
- "re-cherry-pick #N"
- "the old PR was never merged, try again"
- "circle back on the closed fix"

# Re-shipping closed-but-not-merged PRs (verified 2026-08-20)

When a PR was closed without merging (typical reasons: failed CI, code review CHANGES_REQUESTED, scope drift, supersession by a different fix), the temptation is to cherry-pick the original commits onto a fresh branch off current `origin/main`. This works for simple fixes but fails for non-trivial ones because origin/main has moved past the original PR's base.

Four recurring traps emerge. All four were hit on 2026-08-20 when re-shipping PRs #8863 (dice audit) and #9088 (level-up Dockerfile).

## Trap 1 — Parser implementation drift

The skill recipe for the original PR specifies a specific parser (e.g. `_parse_dice_notation` from `mvp_site.action_resolution_utils`). A post-PR refactor in origin/main may have swapped the file to use a stricter parser (e.g. `_parse_bounded_dice_notation` from `mvp_site.dice`). The cherry-pick applies the same intent but lands on codepath that handles fewer inputs.

**Concrete example (PR #8863, 2026-08-20):** The skill's `_is_compound_notation` helper uses `_parse_dice_notation`. The cherry-pick landed on top of a refactor that swapped the file to use `_parse_bounded_dice_notation`. The test fixture `assertTrue(_is_compound_notation("2d20kh1+13+1d10"))` fails because `_parse_bounded_dice_notation` returns `None` for `kh1` selector compound notation.

**Fix**: stick to the original skill's exact parser. If the file has drifted, either:
- Revert the file to the original recipe's parser (preferred — preserves the documented contract)
- Or update the test fixture to match the new parser's narrower contract (only if the new contract is genuinely an improvement and the original taste is preserved)

## Trap 2 — Two test files exist

The repo has BOTH `tests/<file>.py` (repo-root level) AND `mvp_site/tests/<file>.py` (package level). The original skill recipe only mentions the package-level file. Test failures can land in the OTHER file.

**Concrete example (PR #8863, 2026-08-20):** `tests/test_audit_dice_rolls.py` (163 lines on origin/main) has a regression test `test_audit_helpers_still_warns_on_genuinely_unparseable_notation` that the cherry-pick's audit_helpers.py change broke. The package-level `mvp_site/tests/test_audit_dice_rolls.py` was patched by the cherry-pick but the repo-root file was NOT.

**Fix**: always run BOTH test files:

```bash
pytest mvp_site/tests/test_audit_dice_rolls.py tests/test_audit_dice_rolls.py -v
```

If failures appear in the repo-root file, your cherry-pick didn't cover both layers.

## Trap 3 — Reverse-direction `same-test-name-rule`

The original skill's "Pre-existing failure to NOT touch" section assumes the pre-existing tests preserve the OLD contract. **When the new fix changes the documented contract**, the pre-existing tests that assert the OLD contract are now wrong. The fix is to update them as part of the PR — but this must be captured explicitly in the PR body so the reviewer doesn't dismiss the change as "test game."

**Concrete example (PR #8863, 2026-08-20):** The round-2 Bugbot fix explicitly says "non-dice content (`fp_calc`) must NOT emit 'unparseable dice notation'". The pre-existing test `tests/test_audit_dice_rolls.py::test_audit_helpers_still_warns_on_genuinely_unparseable_notation` asserts the OPPOSITE. On origin/main, this test PASSES (old contract). On PR HEAD, it FAILS (new contract).

**Fix (per `same-test-name-rule` in SOUL.md):** when the SAME test name passes on origin/main but fails on PR HEAD, the CHANGE is the source of the regression. The test is now wrong (asserts the old contract). Update the test to assert the new contract, and record the contract change in the PR body under a `## Contract changes` subsection that links to the original Bugbot/reviewer feedback.

**Anti-pattern: dismissing the test as "pre-existing on origin/main, not this PR's fault."** This is the dismiss-as-pre-existing trap. The dismissal is INVALID when the change is the documented intent of the fix.

## Trap 4 — CI gate accrual on re-shipped PRs

When a closed PR is re-shipped, the code is the same but the PR body is small (cherry-pick commits only). However, the cherry-pick itself is `+250/-255` lines bigger than what triggered the original review. The Design Doc Grep Gate's threshold (>50 non-test delta lines) will trip and demand a `## Tenets` section. The Evidence Gate (added 2026-08-20) requires a gist URL of an `/es` evidence bundle. Both gates will fail without explicit body additions.

**Concrete example (PRs #8863 and #9088, 2026-08-20):**
- PR #9201 (level-up Dockerfile +1 example): Evidence Gate FAIL — "PR body does not reference a gist evidence bundle"
- PR #9202 (dice audit, 272 non-test delta lines): Design Doc Grep Gate FAIL — "PR has 272 non-test delta lines (>50) but lacks a Tenets / Design Decision section"

**Fix**: pre-emptively add both sections to the PR body BEFORE opening:

```markdown
## Tenets

- **Skill**: <link to the class-level skill that governs this fix>
- **Bead**: <bead ID>
- **Closed PR**: <#N> — re-shipped on a fresh branch from current origin/main
- **Today's evidence**: <GCS evidence path>

## Evidence

- **Gist**: <gist URL with test output>
- **Commit**: <cherry-pick head SHA>
- **Tests**: N/N passed
```

Use `gh gist create /tmp/test-results.txt --public --desc "PR #N regression test evidence"` to make the gist.

## Cherry-pick command (use this, not the original skill's bare recipe)

```bash
git fetch origin
git worktree add -b fix/<branch-name>-YYYY-MM-DD -- /tmp/wa-worktrees/wt-fix origin/main
cd /tmp/wa-worktrees/wt-fix
git cherry-pick -x <sha1> <sha2> <sha3>

# Apply trap-1 fix: verify parser is the original recipe's, not a refactored one
# Apply trap-2 fix: run BOTH test files
pytest mvp_site/tests/<file>.py tests/<file>.py -v

# Apply trap-3 fix: update pre-existing tests that assert the OLD contract
# Add a `## Contract changes` subsection to the PR body

# Apply trap-4 fix: pre-emptively add Tenets + Evidence sections to the PR body
gh gist create /tmp/test-results.txt --public --desc "..."
gh pr create --base main --head fix/<branch-name>-YYYY-MM-DD \
  --title "..." \
  --body "<with Tenets + Evidence + Contract changes sections>"
```

## Skill ownership caveat

If the original skill that governs the fix is user-owned (not curator-managed), you cannot patch it directly. Recommend the user run `hermes curator adopt <skill-name>` to enable autonomous updates. Meanwhile, capture the lesson in this umbrella skill (which IS curator-managed) and reference the original skill from here.

## Related skills

- `wa-daily-dice-audit-fix` (user-owned — see caveat above) — the original recipe this umbrella's traps emerged from
- `wa-cloud-logging-diag` (user-owned) — Failure Mode #2 covers the level-up Dockerfile pattern (PR #9088)
- `finish-the-job` — gates the merge discipline this skill supports
- `same-test-name-rule` (commitment in SOUL.md) — the rule trap 3 formalizes
