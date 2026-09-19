# Case PR #9132 — validator pre-check (Layer 7 root-cause)

**Date:** 2026-08-20
**Repository:** jleechanorg/worldarchitect.ai
**PR:** [#9132](https://github.com/jleechanorg/worldarchitect.ai/pull/9132)
**HEAD (post-expansion):** `28177a99530b30679d984d28c2dde88835b11c14`
**Branch:** `fix/action-resolution-warning-agent-exempt-9114`
**Status (verified end-of-session):** `state=OPEN, merged_at=null, mergeable=MERGEABLE`

## Trigger

User reported "Missing action_resolution field (required for player actions)" UI banner firing on every Dialog/HeavyDialog/Faction turn. PR #9132's first commit (9651626f80) introduced:

1. Agent-level `@property requires_action_resolution -> False` on DialogAgent and FactionManagementAgent
2. Stale-warning prune in `add_action_resolution_to_response` (action_resolution_utils.py:962)
3. Symmetric prune in `_merge_server_system_warnings_for_streaming_persistence` (llm_parser.py:639)

Which silenced the symptom. Then the user pivot:

> "I think we should see if dice were rolled or someting happened and if action resolution is truly missing then warn. How does warning logic even work"

> "ok just directly fix root cause in that PR expand its scope"

The directive is clear: don't just patch the symptom, move the check into the validator itself.

## Wrong diagnosis (mine) — verify-before-diagnosing anti-pattern

Before the user pivot, I posted a Slack diagnosis claiming:
> Layer A — *prompt-contract gap (root cause)*: DialogAgent loads `narrative_lite.md` — *zero mention of `action_resolution` field*. LLM legitimately emits `None` (no schema in its system prompt).

This was incorrect. **Verified by `grep -n action_resolution mvp_site/prompts/narrative_lite_system_instruction.md`:**
```
24:   - Combat: Attack roll + damage ...
28:3. **Audit** in `action_resolution` JSON field:
40:`action_resolution` is required for ALL player actions ...
44:✅ **TRIGGERS action_resolution:**
49:❌ **Does NOT trigger action_resolution:**
78:**NEVER show dice rolls in narrative text.** ...
```

Six matches — the prompt DOES anchor action_resolution. The user's instinct ("check if dice were rolled, then warn if truly missing") was the right root cause all along. My Layer-A framing was a hallucination of evidence.

Saved as pitfall "Verify file content before diagnosing it as missing" in the umbrella SKILL.md.

## Right fix — validator pre-check

In `mvp_site/narrative_response_schema.py:_validate_action_resolution` (line 3498+):

```python
if action_resolution is None:
    # Pre-check: only warn if ar is genuinely missing — not if
    # downstream code will deterministically rebuild it from sibling state.
    dice_audit = getattr(self, "dice_audit_events", None) or []
    code_exec_used = bool(self.debug_info.get("code_execution_used"))
    truly_missing = not dice_audit and not code_exec_used

    # Only fire warning when ar is genuinely missing.
    if not is_exempt and truly_missing:
        # ... existing warning append block (lines 3526-3540) ...
    return {}
```

Single conditional change: `if not is_exempt:` → `if not is_exempt and truly_missing:`.

`dice_audit_events` is set on line 2692 BEFORE the validator runs (see `__init__` body), so the check sees real values. `code_execution_used` is set post-validator by `llm_parser._enrich_streaming_structured_fields` so it is rarely populated at validator time — when it IS populated, the check covers it; when not, the post-hoc prune in `add_action_resolution_to_response` covers it (belt-and-suspenders).

## Worker dispatch

Dispatched via `bash -lic 'claudem -p "$(cat /tmp/pr9132_expand_task.txt)" --max-turns 120 --allowedTools ...'` on the existing worktree `${HOME}/.worktrees/worldarchitect.ai/fix-ar-warning-agent-exempt` (branch already exists from PR #9132's earlier session; HEAD was `c8c22af42e`).

Worker did:
1. `git fetch origin main` — confirmed origin moved c8c22af42e → 5883467a75
2. `git rebase origin/main` — clean (no conflicts despite 13 commits behind)
3. Wrote 1 new commit `28177a9953` on top of the PR's 2 prior commits
4. RED→GREEN verification: 259 tests pass on PR branch
5. `git push --force-with-lease` (NEVER `--force`)
6. Updated PR body via `gh pr edit 9132 --body ...`

## Files changed vs origin/main (full PR scope, post-expansion)

```
mvp_site/action_resolution_utils.py              | 23 +++++++
mvp_site/agents.py                               | 25 ++++++++
mvp_site/llm_parser.py                           | 35 ++++++++++-
mvp_site/narrative_response_schema.py            | 25 +++++++-   (NEW commit)
mvp_site/tests/test_action_resolution_utils.py   | 60 ++++++++++++++++++
mvp_site/tests/test_narrative_response_schema.py | 78 ++++++++++++++++++++++++   (NEW commit)
6 files changed, 243 insertions(+), 3 deletions(-)
```

Net of THIS commit vs c8c22af42e: 4 files, +122 / -15 LOC.

## git log origin/main..HEAD

```
28177a9953 claudem/minimax-M3: fix(action_resolution): validator pre-check suppresses warning when dice_audit_events populated (issue #9114 root-cause)
bb6b63837c test(action_resolution): restore narrative + outcome_band assertions (#9132)
ba702eb735 claude/claude-sonnet-4.5: fix(action_resolution): suppress warning for non-player-action agents + prune stale recovery (#9114)
```

## RED→GREEN proof (worker output, then re-verified locally)

```
RED on origin/main:
  FAILED test_validate_action_resolution_no_warning_when_dice_audit_events_present
  AssertionError: True is not false : Validator should NOT warn when dice_audit_events populated
GREEN on PR branch (28177a9953):
  259 passed in 2.55s
    mvp_site/tests/test_narrative_response_schema.py  183 passed
    mvp_site/tests/test_action_resolution_utils.py     76 passed
```

Local re-verification:
```
$ cd ${HOME}/.worktrees/worldarchitect.ai/fix-ar-warning-agent-exempt
$ ./vpython -m pytest mvp_site/tests/test_narrative_response_schema.py mvp_site/tests/test_action_resolution_utils.py
==================== 259 passed, 2 warnings in 2.71s ========================
```

## Push confirmation

```
git push --force-with-lease
remote: GitHub found 61 vulnerabilities on jleechanorg/worldarchitect.ai's default branch (informational)
 + c8c22af42e...28177a9953 fix/action-resolution-warning-agent-exempt-9114 -> fix/action-resolution-warning-agent-exempt-9114 (forced update)
```

Old SHA `c8c22af42e` → new SHA `28177a9953`. Branch head after push: `28177a9953`.

## PR state (final)

```
gh pr view 9132 --json 'state,mergeable,reviewDecision,headRefOid,additions,deletions'
{
  "additions": 243, "deletions": 3,
  "headRefOid": "28177a99530b30679d984d28c2dde88835b11c14",
  "mergeable": "MERGEABLE",
  "reviewDecision": "",
  "state": "OPEN"
}
```

`mergeStateStatus: UNSTABLE` was from path-detection GH Actions settling after the force-push (deploy-preview / Detect Changed Paths / limit-pr-runs); all gating checks (Green Gate, Design Doc Grep Gates, CodeRabbit) PASSED.

## Decision rule preserved

Post-hoc prune code in action_resolution_utils.py:962+ and llm_parser.py:639+ was kept (not deleted) as belt-and-suspenders for the `code_execution_used` path that is set POST-validator and therefore invisible to the validator pre-check. Both docstrings updated to explain the dual-path coverage.

## Three lessons encoded into umbrella SKILL.md (v1.10.0)

1. **Validate-when-truly-missing pre-check pattern** (Layer 7 canonical recipe) — when a validator warns on missing-X and a sibling state field can deterministically rebuild X, check sibling state IN the validator before appending the warning. Make post-hoc prune code belt-and-suspenders, not the primary fix.

2. **Verify file content before diagnosing it as missing** (new pitfall) — when the diagnosis is "prompt X is missing anchor Y," grep FIRST before stating the conclusion in any user-facing reply. Five-second grep prevents an entire paragraph of wrong attribution.

3. **Layer-top commit on existing PR branch is the default for "expand the scope" requests** (new workflow pitfall) — one new commit on top, NEVER a new PR, NEVER a squash. Worker sequence: clean worktree → check origin/main divergence → rebase if >10 behind → implement + test + commit → force-with-lease (NEVER `--force`) → verify log matches expected history. Verified on this session with origin/main 13 commits behind.

## Cross-references

- `references/case-pr-9132-agent-exempt-validator-recovery-2026-08-19.md` (Layer 7 v1) — prior session's diagnosis of the recovery-masked warning; this commit promotes the work from "symptom suppress" to "root-cause gate."
- Pitfalls entries in the umbrella SKILL.md "Pitfalls (don't skip)" section.
- `wa-narrative-schema-required-fields-contract` (companion skill) — served-prompt contract tests that should pair with this validator change.
