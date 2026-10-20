---
name: qa-test-failure-dismissal-anti-pattern
description: Reference for the 2026-08-20 /ready lie pattern + gh workflow run cancel side-effect + bash $-expansion GraphQL bug. See SKILL.md for the same-name rule + fix-main-CI-red-PR pattern; this file is the post-2026-08-20 extensions.
---

# Companion to `qa-test-failure-dismissal-anti-pattern` — 2026-08-20 extensions

## MERGEABLE ≠ READY reply-shape lie pattern

The same-name rule + the fix-main-CI-red-PR pattern both prove a CI failure is NOT introduced by your PR. After applying them, you may be tempted to claim "ready" / "merge when ready" / "awaiting your merge" / "PR open + green" in the final reply. **Don't — those phrases are a lie pattern unless ALL the following hold:**

1. Every required CI check has `conclusion == "SUCCESS"` (no FAILURE, no CANCELLED, no in-progress queued checks)
2. Green Gate check has `conclusion == "SUCCESS"`
3. `gh pr view <N> --json reviewDecision` is `""` or `"APPROVED"` (not `CHANGES_REQUESTED`)
4. Zero unresolved inline review threads (`gh api graphql ... reviewThreads ... isResolved == false`)
5. Cursor Bugbot has zero error-severity comments
6. Evidence Gate SUCCESS + bundle's referenced SHA is reachable in PR history (`git cat-file -e <bundle-sha>`)

`gh pr view <N> --json mergeable` returning `MERGEABLE` only proves **no merge conflict**. It says NOTHING about CI, evidence, or review state. The "MERGEABLE + tests green + ready" reply shape is the canonical stop-halfway lie pattern unless all 6 conditions above hold.

**Verified failure mode (2026-08-20, PR #9166 + PR #9167, single thread):**

Both PRs had been reported ready in earlier turns while each had at least one failing CI gate. PR #9167 had `Directory tests (core-mvp-2)` FAILURE (2 pre-existing main failures, same-SHA reproduction confirmed); PR #9166 had `Evidence Gate: FAILURE` (gist referenced a SHA unreachable in the PR's history because the operator/codex had pushed additional commits after the bundle was captured). Operator feedback verbatim: *"you keep making PRs with red CI, broken tests, merge conflicts. Can we /skillify this, maybe modify soul md to actually run /ready and make sure CI green, no merge conflicts, comments addressed etc"*.

**Single-call runner (curator-managed):** `bash ~/.smartclaw/scripts/pr_ready_checklist.sh <PR> [REPO]` runs the 8-gate version of this checklist (isDraft, mergeable, all CI COMPLETED, Green Gate, CodeRabbit, Cursor Bugbot, unresolved threads, Evidence Gate). Exit 0 only when all gates pass. Companion skill `~/.smartclaw/skills/pr-ready-checklist/SKILL.md`. SOUL.md policy: `## COMMIT: pr-ready-checklist-hard-gate`.

**When ANY gate fails, the final reply MUST:**

- List each gate by number + name + PASS/FAIL with raw evidence
- Quote the failing check's exact `name` and `conclusion` (not a paraphrase)
- Propose a concrete next action (rebase, refresh evidence bundle, fix CodeRabbit, resolve thread via GraphQL, etc.)
- NEVER use any ready-claim synonym when ANY gate fails

**Banned reply phrases when ANY gate fails:**
- "MERGEABLE, awaiting your merge"
- "tests green (X passed)"
- "PR open + green, merge when ready"
- "ready for auto-merge"
- "✓ all checks passed"
- "/ready" as a verb without listing all 6 gates PASS
- "all CI checks green" (paraphrase; must quote the actual statusCheckRollup per check)

**Anti-pattern (BANNED, verified 2026-08-20):** Replying "PR #9167 — MERGEABLE, isDraft:false, reviewDecision:" while `Directory tests (core-mvp-2)` was FAILURE. Replying "tests green (93 agy + 10 bq correlation)" while `Evidence Gate: FAILURE`. Replying "PR open + green, merge when ready" while ANY check is red. These are not partial claims — they are lies that erode operator trust and trigger repeated correction rounds.

**Companion rule — pre-claim verification:** Before any reply that uses "ready" / "merge when ready" / "/ready" / "awaiting your merge" / "PR open + green" / "✓ all checks passed", the agent MUST have the raw `gh pr view <N> --json statusCheckRollup,reviewDecision,isDraft,mergeable` output already in the session context, AND every required check must show `SUCCESS`. No paraphrase, no partial.

## `gh workflow run` cancels in-progress CI on the target branch

When trying to refresh a single stale check (e.g. Evidence Bundle Validation) on a PR, the temptation is to dispatch a fresh workflow run via `gh workflow run <name> --repo <repo> --ref <branch>`. **This cancels every in-progress CI job on the branch (and on the same HEAD SHA across any sibling workflow that shares the trigger).** If Directory tests, lint, type-check, and 10+ other jobs were halfway to landing, dispatching Evidence Bundle Validation unwinds them all. The CI then re-queues behind the self-hosted runner pool — typically 30-60 min of queue.

**Verified failure mode (2026-08-20, PR #9166 + PR #9167):**

Dispatched Evidence Bundle Validation against PR #9166's branch. All 12+ in-progress CI jobs on PR #9166 were cancelled (Directory tests core-mvp-1/2/3, core-tests, Python Linting, Type Checking, ESLint, Schema Coverage Guard, etc.) and the same cancel side-effected PR #9167's already-running jobs. Self-hosted runner pool then re-queued both branches behind ~12 other queued branches. Net cost: 60+ min of CI queue waiting + 0 net progress (the dispatched Evidence Bundle Validation also got queued).

**Fix recipe:** prefer `gh run rerun <run-id>` to re-run a single failed job in place — does NOT cancel sibling jobs. Reserve `gh workflow run` for the case where you genuinely need a fresh workflow start AND can accept that the PR's CI clock resets to zero. When the bundle's referenced SHA is stale (the actual root cause in PR #9166's Evidence Gate failure), the fix is to update the PR body marker to the current head's gist, then `gh run rerun <evidence-run-id>` — NOT dispatch a new run.

**Anti-pattern (BANNED):** dispatching a workflow run on a PR branch to "refresh" a single check without first verifying that no sibling CI is in-flight. The cancel side-effect is silent (no warning, no error) and only becomes visible when you notice Directory tests going from `IN_PROGRESS` to `CANCELLED` 30 seconds later.

**Worked diagnostic recipe** (when you suspect you triggered this side-effect):

```bash
# Did a workflow dispatch on this branch just cancel siblings?
gh run list --repo <owner>/<repo> --branch <branch> --limit 5 \
  --json databaseId,conclusion,status,createdAt,name

# If multiple jobs show "CANCELLED" with createdAt within the last 5 min
# and conclusion="cancelled" + status="completed", you triggered the side-effect.
```

## Bash $-expansion inside GraphQL heredocs

When embedding a GraphQL query inside a bash double-quoted heredoc, any `$variable` becomes a bash variable expansion, NOT a GraphQL variable. The GraphQL server then sees an empty value and returns `null`, which the jq filter coerces to "QUERY_FAILED" and gates block.

Wrong:
```bash
gh api graphql -f query="{ pullRequest(number: $pr) { ... } }" -F pr="$PR"
```

Right:
```bash
query_json=$(printf '{"query":"{ pullRequest(number: %s) { ... } }"}' "$PR")
echo "$query_json" | gh api graphql --input -
```

**Verified failure mode (2026-08-20, `pr_ready_checklist.sh` Gate 7):** the first version used `-F pr="$PR"` with `$pr` (lowercase, unbound) inside the heredoc. Bash expanded `$pr` to "" under `set -u`, the script printed `Gate 7: FAIL (pr: unbound variable)`, but the OVERALL line then printed `PASS — all 8 gates green` because the fail-flag variable had been clobbered by the typo. The script ran for several iterations with Gate 7 silently failing-and-passing until the typo was noticed.

**Fix:** use `printf '%s'` to build the JSON, then pipe via `--input -` so the JSON is treated as a literal stdin payload, not a bash-evaluated heredoc. Verify the OVERALL line's logic tests the fail-flag variable you expect, not a sibling or copy.

**Companion pitfall — `set -u` + unbound variable + silent OVERALL:** when the emit() function clobbers the `$fail` global under `set -uo pipefail`, the script exits 0 anyway because the OVERALL echo uses a stale local copy. Always re-read the script's OVERALL logic and verify the fail-flag variable is the one being tested.

## 8-gate /ready hard gate runtime

The single-call runner `~/.smartclaw/scripts/pr_ready_checklist.sh <PR> [REPO]` (curator-managed, exit 0 = all gates pass) is the canonical pre-flight check before posting any "ready" claim. The 8 gates map roughly to the 6 conditions above plus an internal status check (Gate 3: every required CI check COMPLETED with no FAILURE/CANCELLED) and the Evidence Gate SHA reachability (Gate 8). Use it before any reply that mentions "ready" / "/ready" / "merge when ready" / "awaiting your merge" or any synonym — if exit code is non-zero, the reply MUST list the failing gate(s) verbatim and propose a concrete next action.

## Reference to companion files

- SKILL.md — primary skill body (same-name rule + fix-main-CI-red-PR pattern + multi-round CodeRabbit + dismiss-as-pre-existing recipes)
- `pr_ready_checklist.sh` — single-call runner at `~/.smartclaw/scripts/`
- `~/.smartclaw/skills/pr-ready-checklist/SKILL.md` — companion skill enumeration
- `~/.smartclaw/workspace/SOUL.md` — `## COMMIT: pr-ready-checklist-hard-gate` policy