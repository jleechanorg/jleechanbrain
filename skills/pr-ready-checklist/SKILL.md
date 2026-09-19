---
name: pr-ready-checklist
description: Run the 8-gate /ready checklist on any PR before claiming "ready", "merge when ready", "/ready", "awaiting your merge", "PR open + green", or any synonym. Use when about to post a ready-claim reply about a PR by number. Encodes the SOUL.md `pr-ready-checklist-hard-gate` policy.
version: 1.0.0
tags: [pr, ready, gate, ci, evidence, code-review]
---

# pr-ready-checklist

The 8-gate hard gate that fires BEFORE any "ready" claim about a PR. Every gate has a single `gh pr view` or `gh api` command that returns PASS/FAIL. If any gate fails, the agent MUST report the failing gate by number + name, quote the raw evidence, and propose a concrete next action — NOT claim ready.

## When to load

Load this skill BEFORE posting any reply that:
- Names a PR by number and uses the words "ready", "/ready", "merge when ready", "awaiting your merge", "green awaiting your merge", "PR open + green", "ready for auto-merge", "tests green", or any synonym
- OR runs `/ready`, `/green <PR>`, `drive-pr-to-green`, or any "drive to merge" workflow
- OR is the final reply in a thread where the previous turn opened/closed/modified a PR

## The 8 gates (all must PASS for a "ready" claim)

| # | Gate | Command | Pass condition |
|---|------|---------|----------------|
| 1 | isDraft false | `gh pr view <N> --json isDraft -q .isDraft` | output == `false` |
| 2 | mergeable MERGEABLE | `gh pr view <N> --json mergeable -q .mergeable` | output == `MERGEABLE` |
| 3 | All CI checks pass | `gh pr view <N> --json statusCheckRollup --jq '.statusCheckRollup[] \| select(.conclusion == "FAILURE" or .conclusion == "CANCELLED")'` | empty array |
| 4 | Green Gate passed | `gh pr view <N> --json statusCheckRollup --jq '.statusCheckRollup[] \| select(.name == "Green Gate") \| .conclusion'` | output == `"SUCCESS"` |
| 5 | CodeRabbit reviewDecision clear | `gh pr view <N> --json reviewDecision -q .reviewDecision` | output is `""` or `"APPROVED"` |
| 6 | Cursor Bugbot clean | `gh api repos/<owner>/<repo>/issues/<N>/comments --jq '[.[] \| select(.user.login == "cursor[bot]" and (.body \| test("error"; "i")))] \| length'` | output == `0` |
| 7 | No unresolved threads | `gh api graphql -f query='{ repository(owner: "<owner>", name: "<repo>") { pullRequest(number: <N>) { reviewThreads(first: 100) { nodes { isResolved } } } } }' --jq '[.data.repository.pullRequest.reviewThreads.nodes[] \| select(.isResolved == false)] \| length'` | output == `0` (allow if CodeRabbit is APPROVED) |
| 8 | Evidence Gate (mvp_site/** only) | `gh pr view <N> --json statusCheckRollup --jq '.statusCheckRollup[] \| select(.name == "Evidence Gate") \| .conclusion'` | output == `"SUCCESS"` AND, if a gist SHA is referenced in the PR body, `git cat-file -t <sha>` returns `commit` |

## The single-call runner

To avoid hand-running each gate, source the helper:

```bash
bash ~/.smartclaw/scripts/pr_ready_checklist.sh <PR_NUMBER> <OWNER/REPO>
```

Output is one line per gate:

```
Gate 1 isDraft false: PASS (false)
Gate 2 mergeable MERGEABLE: PASS (MERGEABLE)
Gate 3 CI checks: FAIL (Directory tests (core-mvp-2) FAILURE, import-validation CANCELLED)
Gate 4 Green Gate: PASS (SUCCESS)
Gate 5 CodeRabbit reviewDecision: PASS ("")
Gate 6 Cursor Bugbot: PASS (0 error-severity comments)
Gate 7 Unresolved threads: PASS (0 unresolved)
Gate 8 Evidence Gate: PASS (SUCCESS)

OVERALL: FAIL — 1 gate(s) failing
```

Exit code: `0` = all gates pass, `1` = at least one gate fails.

## Failure-path reply shape (REQUIRED when any gate fails)

1. **Number the failing gates** — "Gate 3 FAIL", "Gate 8 FAIL", etc.
2. **Quote the raw evidence** — the check name + conclusion, not a paraphrase.
3. **Name the fix path** — "wait for #N to merge, then clean-rebase this PR (3-commit replay)" OR "refresh evidence bundle against current head SHA" OR "fix CodeRabbit issues 1+3+5".
4. **NEVER use ready-claim synonyms** — no "ready", no "merge when ready", no "awaiting your merge", no "PR open + green", no "/ready", no "tests green", no "✓ all gates green". Instead use phrases like "blocked on Gate 3", "not ready — Gate X FAIL", "fix path: ...".

## Worked examples

### PASS path (all 8 gates green)

Reply shape:
> ✅ PR #9167 — `/ready` PASS (all 8 gates).
>
> - Gate 1 isDraft false: PASS
> - Gate 2 mergeable MERGEABLE: PASS
> - Gate 3 CI checks: PASS (27 SUCCESS, 0 FAILURE)
> - Gate 4 Green Gate: PASS
> - Gate 5 CodeRabbit reviewDecision: PASS (APPROVED)
> - Gate 6 Cursor Bugbot: PASS
> - Gate 7 Unresolved threads: PASS (0 unresolved)
> - Gate 8 Evidence Gate: PASS (SUCCESS, gist SHA 82776e03 reachable)
>
> Skeptic-cron will pick up the merge on its next run. Merge when ready.

### FAIL path (gate 3 fails)

Reply shape:
> ❌ PR #9167 — `/ready` FAIL (Gate 3 FAIL).
>
> - Gate 1 isDraft false: PASS
> - Gate 2 mergeable MERGEABLE: PASS
> - Gate 3 CI checks: **FAIL** — `Directory tests (core-mvp-2)` FAILURE on `test_api_routes.py:560` + `test_divine_prompts_setting_agnostic.py` (24 sub-failures). Same-name rule reproduction on `origin/main @ 3a6a5c9174` confirms pre-existing on main (NOT a PR regression).
> - Gate 4 Green Gate: PASS
> - Gate 5 CodeRabbit reviewDecision: PASS
> - Gate 6 Cursor Bugbot: PASS
> - Gate 7 Unresolved threads: PASS
> - Gate 8 Evidence Gate: PASS (N/A for non-`mvp_site/**` change... actually yes, this PR touches `mvp_site/llm_providers/gemini_provider.py`, so Gate 8 is REQUIRED)
>
> **Fix path:** wait for PR #9204 to merge to origin/main (it fixes both pre-existing failures), then clean-rebase this PR (3-commit replay onto origin/main @ post-#9204 tip), force-push with `--force-with-lease`, watch CI re-run. Expected: all 8 gates green.
>
> Will rebroadcast when Gate 3 turns green.

## Anti-patterns (BANNED reply shapes)

- ❌ "PR #9167 — `MERGEABLE`, `isDraft:false`, `reviewDecision:""`, branch `feat/gemini-thinking-low-medium` @ `aa21480d9b`. Skeptic-cron will pick it up on next run. Merge when ready." (when Gate 3 is FAILURE — lies about ready)
- ❌ "tests green (93 agy + 10 bq correlation)" (when Evidence Gate is FAILURE — partial claim, doesn't surface the FAILURE)
- ❌ "all CI checks green" (paraphrase; must quote the actual `statusCheckRollup` per check)
- ❌ "✓ all tests passed" (only addresses Gate 3, skips the other 7)
- ❌ Any ready-claim that doesn't list all 8 gates with PASS/FAIL per gate

## Companion files

- SOUL.md `## COMMIT: pr-ready-checklist-hard-gate` — the trigger policy that loads this skill
- `~/.smartclaw/scripts/pr_ready_checklist.sh` — the single-call runner
- `~/.smartclaw/tests/test_pr_ready_checklist_gate.py` — the contract test (8-gate enumeration)
- `~/.smartclaw/skills/workflow/drive-pr-to-green/SKILL.md` — the full drive-to-merge workflow this gate enforces at the end

## Origin

Added 2026-08-20 in response to operator feedback: "you keep making PRs with red CI, broken tests, merge conflicts. Can we /skillify this, maybe modify soul md to actually run /ready and make sure CI green, no merge conflicts, comments addressed etc". The "MERGEABLE + ready" reply shape was used twice in one thread (PR #9166 + #9167) while each PR had at least one failing CI gate — the operator correctly flagged this as a lie pattern. This skill + SOUL.md commit + script + test close the gap.