# Coordinate with PR #8951 (2026-08-16)

PR #8951 (`feat/rev-6g6d4-pr8945-followup-fixes`) was in flight on 2026-08-16 and touches the same file (`mvp_site/narrative_response_schema.py`) as the dice-warning noise-cleanup work. This reference captures the coordination discipline so future sessions don't collide.

## PR #8951 at a glance

- **Title**: `feat(dice): enable code execution for Gemini models with response_json_schema (rev-6g6d4, rev-37zkv, rev-xph5o)`
- **Branch**: `feat/rev-6g6d4-pr8945-followup-fixes`
- **Base**: `main`
- **Author**: `${GITHUB_USER}`
- **Files touched** (10):
  - `docs/research/gemini-3.7-flash-code-execution-tool-call-loop.md`
  - `mvp_site/dice_strategy.py`
  - `mvp_site/llm_providers/gemini_provider.py`
  - `mvp_site/llm_service.py`
  - **`mvp_site/narrative_response_schema.py`** ← shared with the noise-cleanup PR
  - `mvp_site/schemas/prompt_tool_contracts.json`
  - `mvp_site/tests/test_centralized_model_selection.py`
  - `mvp_site/tests/test_code_execution_evidence.py`
  - `testing_mcp/dice/test_chi_square_gemini_seeded.py`
  - `testing_ui/capture_fresh_account_default_proof.py`
- **What it does**: Adds `response_json_schema` for Gemini Flash models to prevent infinite tool-call loops in JSON mode. Enables code execution by default for all Gemini models except `gemini-3.5-flash-lite`.

## Why they collide

Both PRs touch `mvp_site/narrative_response_schema.py`:
- **PR #8951** modifies the schema definition for `response_json_schema` support (specifically the `NARRATIVE_RESPONSE_JSON_SCHEMA` dict with `additionalProperties: True` on dynamic sub-objects).
- **Noise-cleanup PR** modifies `_warn_on_unclean_action_resolution_dice` (lines 3469-3646) to gate the 3 cosmetic warnings (G, J, M).

These don't overlap functionally — different methods, different purposes. But they touch the same file, which means a merge conflict is possible if both PRs are rebased on the same `origin/main` SHA.

## Why they don't conflict

The PR #8951 changes are concentrated in the schema-definition region (response_json_schema dict literal). The noise-cleanup changes are concentrated in the validator function. Line ranges per the inventory at 2026-08-16:

- PR #8951 likely edits: `NARRATIVE_RESPONSE_JSON_SCHEMA` literal (somewhere in the top half of the file)
- Noise-cleanup edits: `_warn_on_unclean_action_resolution_dice` (lines 3469-3646) + 2 helper functions added near the top of the file

If both PRs add new helper functions near the same top of the file, MERGE CONFLICT IS POSSIBLE. Resolution: PR #8951 first, then rebase noise-cleanup on top of #8951's HEAD.

## Coordination recipe

### When you see PR #8951 still open

1. **Check status**: `gh pr view 8951 --json state,mergeable,reviewDecision,statusCheckRollup`
2. **If PR #8951 is open and pending**: don't block. Both PRs are orthogonal. Either can merge first.
3. **If PR #8951 already merged**: rebase your noise-cleanup branch on top of `origin/main` and resolve any conflicts. Most likely conflict location: any new helper functions near the top of `narrative_response_schema.py` (just define both helpers in different spots or merge them into one).
4. **If PR #8951 is closed without merging**: the noise-cleanup branch can proceed independently.

### Workflow

```bash
# 1. Check PR #8951 status
gh pr view 8951 --json state,mergeable,reviewDecision 2>&1 | head -10

# 2. If #8951 is MERGED, rebase
cd ${HOME}/projects/wt-dice-noise-cleanup
git fetch origin
git rebase origin/main
# Resolve any conflicts (rare; only if both PRs add code at the same line)

# 3. If #8951 is OPEN, no action needed — both PRs are orthogonal
# 4. Verify no collision
git log --oneline origin/main..HEAD  # MUST show only noise-cleanup commits
```

### What NOT to do

- **Don't push onto PR #8951's branch.** It's `feat/rev-6g6d4-pr8945-followup-fixes` — owned by `${GITHUB_USER}`. Pushing onto it would push the noise-cleanup commits onto someone else's PR.
- **Don't wait for PR #8951 to merge** before opening the noise-cleanup PR. They're orthogonal; both can be reviewed in parallel.
- **Don't merge PR #8951 yourself** even if you have access. skeptic-cron.yml handles auto-merge once the user types `MERGE APPROVED`.

## Cross-references

- PR #8951: https://github.com/jleechanorg/worldarchitect.ai/pull/8951
- PR #8930 (the merged Class D fix that this recipe mirrors): https://github.com/jleechanorg/worldarchitect.ai/pull/8930
- Source file: `mvp_site/narrative_response_schema.py`
- SOUL.md `pr-clean-branch-from-main-no-history-bloat` — clean branch from origin/main, no shared history
- SOUL.md `never-push-onto-someone-elses-pr-head` — three-gate check before force-push
