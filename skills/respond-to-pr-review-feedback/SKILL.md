---
name: respond-to-pr-review-feedback
description: "Fix PR review-bot feedback. Use for review P1 fixes."
version: 1.1.0
author: Hermes Agent
license: MIT
platforms: [linux, macos]
metadata:
  hermes:
    tags: [GitHub, Pull-Requests, Code-Review, GraphQL, Force-Push]
    related_skills: [github-pr-workflow, github-code-review, drive-pr-to-green]
changelog:
  - "1.1.0 (2026-08-23): New 'Iterating until reviewer APPROVED' section + reference doc `coderabbit-iterate-to-approved-2026-08-23.md`. Adds the multi-cycle recipe (max 3 cycles, /advice + /web-advice loop, cherry-pick replay for PR-head history bloat, stop-condition menu). Two new pitfalls: 'iterate until approved' is reviewer-state not operator-merge; CR lag after push can exceed 30 min. Anchored on jleechanorg/worldarchitect.ai PR #9132 (5 MAJOR + 2 nitpicks + 2 test nits on a 19-commit PR head)."
---

# Respond to PR Review Feedback

End-to-end recipe for an agent (or subagent) that **fixes** review-bot or
human review feedback on an open PR and ships the fix as a single
amended-or-fixup commit, force-pushed via `--force-with-lease`, with all
originally-unresolved threads resolved and replied to.

The class of task is the complement of `github-code-review`: this skill
is the **PR-author** side, not the reviewer side. `drive-pr-to-green`
covers the broader loop (drive to MERGEABLE / merged); this skill is
specifically the **single-cycle review-feedback fixup** that often
precedes it.

## When to use

- Review bot (`chatgpt-codex-connector`, `coderabbitai`, `bugbot`,
  `claude-code-review[bot]`) flagged P1/P2 issues on an open PR.
- A human reviewer posted inline review comments that need addressing.
- An operator asks: "fix the review feedback on PR #N", "resolve the
  chatgpt-codex-connector P1s", "address the review bot threads on PR #N".

## When NOT to use

- The PR is closed / the branch is stale → use `wa-closed-pr-reship`.
- The reviewer requested a major refactor that warrants its own branch
  and new PR → use `github-issue-to-pr`.
- The PR is healthy and just needs a merge → use `drive-pr-to-green`.
- The reviewer requires multi-vendor second opinion (Gemini / Grok / ChatGPT /
  Perplexity panel) and CR stays `COMMENTED` across cycles → use the
  **Iterating until reviewer APPROVED** recipe below; the single-cycle flow
  is too narrow for the multi-cycle pattern.

## Iterating until reviewer APPROVED (added 2026-08-23, PR #9132)

The single-cycle recipe above handles the common case (one round of fixup).
Some PRs need **multi-cycle iteration** to flip the reviewer from
`COMMENTED` to `APPROVED`. Recognise the pattern: when the reviewer
(CodeRabbit, Bugbot, chatgpt-codex-connector, or a human) leaves 5+ items
spanning MAJOR + nitpick tiers, a single amend is rarely enough — CR will
often re-review and either (a) surface new sub-issues on the same lines,
(b) keep the prior blocking comments open until they're explicitly
acknowledged, or (c) require a second-opinion pass from the operator's
chosen reviewer panel (`/advice` + `/web-advice`).

### Multi-cycle protocol (max 3 cycles, then surface to operator)

| Step | Action | Why |
|---|---|---|
| 1. Inventory review state | `gh pr view <N> --json latestReviews --jq '.latestReviews[0] \| {state, body, commit}'` | Get the exact review state, not the prior summary. `latestReviews[0].state` is the source of truth — older `COMMENTED` reviews linger in the API even after a fix push. |
| 2. Triage each comment | Mark each as `MAJOR` (functional correctness, security, data integrity) vs `nitpick` (style, dedupe, formatting) vs `skip-with-reason` (already addressed in earlier commit on the PR head, or out-of-scope). | Drives whether the cycle fixes it now or escalates. |
| 3. Apply MAJOR + low-cost nitpicks | All MAJOR + the cheapest nitpicks. Skip the rest with one-line reason. | Minimises the diff the reviewer re-reads next round. |
| 4. `/advice` 3-reviewer second opinion | Build a brief (Decision + Artifact ≤150 lines) for `delegate_task` → `agy --print` → `codex`. Synthesise verdict table. | Catches issues the agent + CR missed; cheap (in-session). |
| 5. `/web-advice` vendor panel (best-effort) | Per `~/.smartclaw/skills/review/web-advice/SKILL.md` §1 — real browser sessions on real vendor sites only. **Honest probe accounting:** expect 0-2 of 4 (Gemini + Grok usually UP, ChatGPT + Perplexity Cloudflare-walled). Report `2-of-4` not `4-of-4` when only 2 panels land. | Operator's red-line: vendor panels without probed share URLs are fabrication. |
| 6. Push to PR head branch | `git push --force-with-lease` (never `--force`). If PR head has >5 commits, prefer cherry-pick replay (see below) over force-push. | `--force-with-lease` is the only safe form. |
| 7. Wait for CI + re-trigger reviewer | CI ~10-15 min for worldarchitect.ai. Re-trigger CR via `gh pr comment <N> -b "@coderabbitai review"` if silent >30 min. | CR auto-reviews on push, but the auto-trigger has been observed to lag. |
| 8. Re-inventory | If `latestReviews[0].state == APPROVED`, done. If still `COMMENTED` with new content, goto step 2. | Hard cap at 3 cycles total. |

### PR-head replay decision (cherry-pick vs force-push)

When the PR head has accumulated commits over multiple iteration cycles
(common: 5-20 commits on a long-lived review PR), do NOT replay the entire
history on the next iteration cycle. The history bloat confuses the
reviewer's incremental review and produces spurious comments on earlier
commits. The recipe:

1. Create a fresh worktree from `origin/main`:
   `git worktree add /tmp/wt-<N>-cycle-<C> -b fix/<N>-cycle-<C> origin/main`
2. Cherry-pick ONLY the load-bearing fix commits from the current PR head
   onto this fresh worktree. Skip merge commits, fixup commits, and
   "chore: trigger CI" no-ops.
3. Push the clean replay:
   `git push --force-with-lease origin fix/<N>-cycle-<C>:fix/<original-branch>`
4. Verify PR head SHA updated:
   `gh pr view <N> --json headRefOid -q .headRefOid` MUST equal local HEAD.

This keeps the PR head history linear (one commit per iteration cycle)
and dodges the "reviewer keeps commenting on old commits" feedback loop.

### Stop conditions

- **3 full cycles without APPROVED** → surface to operator with menu:
  "CodeRabbit stayed `COMMENTED` after 3 cycles. The remaining <N> threads
  are: <list>. Recommend: (1) merge as-is (CR is advisory, not a gate),
  (2) reply to each thread manually, (3) close PR and reopen from clean
  branch." Do NOT auto-merge despite operator's original "iterate until
  approved" phrasing — that goal was reviewer-state, not operator's
  `MERGE APPROVED`.
- **`/web-advice` <2-of-4 vendors land** → post honest partial report
  (the skill already enforces this; reference it inline so the
  operator-facing reply cites the transport-ladder failure log).

### Worked example anchor

PR #9132 (jleechanorg/worldarchitect.ai) — CodeRabbit left 5 MAJOR + 2
nitpicks + 2 test-divine-prompt nits on a 19-commit PR head. Worker
dispatched on `fix/pr9132-coderabbit-feedback` (fresh from `origin/main`),
cherry-picked load-bearing fixes onto the PR head, ran `/advice` 3-reviewer
fanout, ran `/web-advice` (expecting 0-2 of 4 vendors given the
2026-08-17→19 0-of-4 streak + 2026-08-21 2-of-4 partial recovery). Full
recipe + transport-ladder reality at `references/coderabbit-iterate-to-approved-2026-08-23.md`.

## Non-negotiables

1. **NEVER** `git push --force`. **ALWAYS** `git push --force-with-lease`.
   `--force` will silently overwrite pushes that landed on the remote
   while you were working (e.g. the reviewer pushed a follow-up commit
   to your branch). `--force-with-lease` refuses to overwrite remote
   commits you did not see. The cost of `--force` is silent data loss.
2. **NEVER** poll CI after pushing. CI is for the operator to watch
   asynchronously. Push → exit with branch + new SHA + PR URL.
3. **NEVER** touch unrelated worktrees. If you're asked to fix PR #N,
   only operate in the worktree/branch for PR #N.
4. **NEVER** commit `.beads/issues.jsonl` from a feature branch —
   `br --no-auto-flush` is already on in the canonical worktree.
5. **ALWAYS** reply to each unresolved thread with a one-line "Fixed in
   `<SHA>` — <what changed>" comment BEFORE marking it resolved. The
   reply stays in the thread audit log even after resolution; the
   resolve flag alone is invisible to humans reading the diff later.
6. **ALWAYS** add or update tests that pin the corrected behavior.
   The reviewer will not trust "Fixed in <SHA>" without a test that
   fails on the old code and passes on the new.

## Step 1 — Inventory

```bash
# Confirm you're on the right branch and worktree
cd <worktree-for-this-PR>
git rev-parse --abbrev-ref HEAD
git status -sb   # must say "up to date with origin/<branch>"

# Confirm the PR head SHA matches
gh pr view <PR_NUMBER> --json headRefOid --jq '.headRefOid'
```

Stop immediately if the PR head SHA does not match local HEAD or if the
worktree is dirty. Re-run `./run_tests.sh` only if the working tree is
clean — you don't want to validate mixed code.

## Step 2 — Discover Unresolved Review Threads

GitHub's REST API does not expose review threads (it surfaces flat
review comments instead). Use GraphQL via `gh api graphql` — this is
the canonical way to find `isResolved: false` threads with their
`threadId` for the resolve mutation.

```bash
gh api graphql -f query='
query($owner:String!, $name:String!, $num:Int!) {
  repository(owner:$owner, name:$name) {
    pullRequest(number:$num) {
      reviewThreads(first:50) {
        nodes {
          id
          isResolved
          comments(first:1) {
            nodes {
              databaseId
              path
              line
              body
            }
          }
        }
      }
    }
  }
}' -f owner=<org> -f name=<repo> -F num=<PR_NUMBER>
```

Save the list of `id`s with `isResolved: false`. Each `id` is the
`threadId` for Step 8. The `databaseId` is the underlying review
comment ID (useful for sanity-checking).

**Don't have `gh`?** Use `gh api` with an explicit token: `gh api -H
"Authorization: Bearer $GITHUB_TOKEN" graphql -f query=...`. The
REST fallback (`/repos/.../pulls/<N>/comments`) gives flat comments
but not thread IDs — you cannot resolve threads without the GraphQL
thread ID.

## Step 3 — Fix Locally

Apply each P1/P2 fix using `read_file` + `patch`/`write_file`. Keep
the diff minimal: only what addresses the review feedback. Don't
opportunistically refactor unrelated code.

### Sub-count invariants (the silent killer)

Review-bot formulas commonly double-count a sub-count (e.g.
`cached_tokens` is a sub-count of `prompt_tokens`; per `bq_logging.py`
schemas). When fixing a pricing/billing/aggregation formula flagged by
review, **always check the schema definition** for the sub-count
invariant — don't trust the formula or your own reading. The corrected
formula is typically `(parent - sub) * parent_rate + sub * sub_rate`.

Defensive coding: clamp `sub = min(sub, parent)` so a malformed row
cannot produce a negative billed value. Add a test for the clamp.

### Placeholder rates (the silent killer #2)

When you must add a row to a rate/limit/feature table before the
upstream publishes official numbers, mark it clearly with a comment
block AND emit a one-shot stderr warning when the row is hit. Otherwise
operators will treat the placeholder as the real number. Use a
module-level `_seen` set on the warn function to dedup across many
rows per report.

### Firestore composite-index traps (the silent killer #3)

When the worker code uses a Firestore compound query like
`.where("field_a", "==", x).where("field_b", ">=", cutoff)`, the
deployment's `deployment/firebase/firestore.indexes.json` must define
a composite index on `(field_a, field_b)` — or Firestore raises at
runtime. The production pattern is almost always to wrap the query in
a `try/except Exception: pass` for resilience, which **silently
swallows the index error and leaves the count at 0**. Symptom: report
shows $0 cost / zero turns / zero users, no obvious error in logs.

**Fix-shape pattern (proven on PR #9250):**

1. **Store raw material, not pre-baked aggregates.** When the same
   Firestore stream must support multiple time windows (1-week,
   4-week, custom), do ONE query at the most-permissive cutoff and
   store the raw rows (e.g. `user_actor_timestamps: list[int]`) on the
   parent dict. Then filter by window in Python at the call site.
   This works for any cutoff without re-querying Firestore and dodges
   the composite-index requirement entirely.
2. **Replace compound query with single-field + Python filter.** Use
   `.where("actor", "==", "user")` (existing single-field auto-index)
   and filter timestamps in Python. Cheaper than provisioning a new
   index and safer than hoping operators redeployed
   `firestore.indexes.json` before the report runs.
3. **Add a code comment explaining why the compound index is
   deferred**, so the next agent doesn't "fix" it back. Include:
   the index name, which `firestore.indexes.json` entry would need to
   be added, and the deploy-the-index prerequisite for operators.
4. **Test guard.** Assert that the report's top-N output changes when
   you swap `one_week_ago` for `four_weeks_ago`. If both windows
   produce identical sums, the fix is wrong — you're still using a
   pre-baked aggregate.

When you DO need a composite index (e.g. server-side aggregation
counts are non-negotiable), add it to
`deployment/firebase/firestore.indexes.json` AND mention in the PR
body that operators must `firebase deploy --only firestore:indexes`
before the report will stop zeroing out. Don't silently assume the
index exists in production.

## Step 4 — Add / Update Tests

The test must **fail on the old code and pass on the new code**. Bare
asserts of "the new behavior happens" are insufficient — write the test
to assert the *previous wrong value* does NOT appear, e.g.:

```python
# OLD formula gave 44%; NEW must give 80%
assert "80%" in text
assert "44%" not in text  # regression guard
```

Use `Path(__file__).resolve().parent.parent / "module.py"` for any
`importlib.util.spec_from_file_location` target so tests work in CI
checkouts, not just on the author's machine. Absolute paths in test
files are a P1 code-review flag waiting to happen.

## Step 5 — Run Tests

Use the canonical repo's venv, NOT the worktree's venv (worktrees
typically don't have one):

```bash
cd ${HOME}/projects/<canonical-repo>
.venv/bin/python -m pytest \
  /path/to/worktree/scripts/tests/test_<file>.py -v 2>&1 | tail -15
```

All tests must pass before you push. If any fail, the fix is wrong —
debug, don't push.

## Step 6 — Amend vs Fixup Commit

| Situation | Use |
|-----------|-----|
| Review feedback was on the ONLY commit on the branch | `git commit --amend` (cleanest history) |
| Branch has multiple commits and fix is for the head only | `git commit --amend` (amend the head) |
| Branch has multiple commits and fix should target a specific earlier commit | `git commit --fixup=<sha>` then `git rebase -i --autosquash <base>` |
| Branch has merged commits from main that complicate the base | `git rebase` interactively first |

For P1 review feedback on a single-commit PR (the common case),
amend. The new subject should be `claudem/<model>: fix(<scope>):
<one-line description>` and the body should list each fix with
`file:line` references and the tests that pin it.

```bash
git add <files>
git commit --amend -m '<new subject>' -m '<body listing 3 fixes with file:line refs>'
```

## Step 7 — Force-with-Lease Push

```bash
git push --force-with-lease origin <branch-name>
```

`--force-with-lease` will refuse if the remote branch moved since your
last `fetch`. If it refuses: `git fetch origin <branch>`, rebase if
needed, retry. Do NOT fall back to plain `--force`.

Verify with:

```bash
gh pr view <PR_NUMBER> --json headRefOid --jq '.headRefOid'
# must equal your local HEAD SHA
```

## Step 8 — Reply + Resolve Each Thread

For each thread ID from Step 2, post a reply AND mark resolved. The
reply is the audit trail; the resolve flag is the UI state. Both are
needed.

### Reply to a thread

```bash
gh api graphql -f query='
mutation($threadId: ID!, $body: String!) {
  addPullRequestReviewThreadReply(input: {pullRequestReviewThreadId: $threadId, body: $body}) {
    comment { id body }
  }
}' \
  -f threadId=<PRRT_...> \
  -f body="Fixed in <SHA> — <one-line description of fix and test that pins it>"
```

The mutation accepts replies on already-resolved threads too, so if
you accidentally resolve before replying, just run the reply mutation
afterwards.

### Resolve a thread

```bash
gh api graphql -f query='
mutation($id:ID!) {
  resolveReviewThread(input:{threadId:$id}) {
    thread { id isResolved }
  }
}' -f id=<PRRT_...>
```

### Verify all resolved

```bash
gh api graphql -f query='
query($owner:String!, $name:String!, $num:Int!) {
  repository(owner:$owner, name:$name) {
    pullRequest(number:$num) {
      reviewThreads(first:50) { nodes { id isResolved } }
    }
  }
}' -f owner=<org> -f name=<repo> -F num=<PR_NUMBER>
```

## Step 9 — Exit

Print, don't poll:

```
branch: <branch>
new sha: <full SHA>
pr url:  https://github.com/<org>/<repo>/pull/<N>
threads: <N> resolved, <N> replied
```

No `gh pr checks --watch`. No CI polling. Operator (or
`drive-pr-to-green`) watches CI separately.

## Pitfalls

- **Plain `git push --force` silently overwrites concurrent pushes.**
  Always `--force-with-lease`. If a reviewer pushed a follow-up
  commit to your branch while you were working, `--force-with-lease`
  refuses, you `git fetch`, rebase, and retry. `--force` would have
  silently deleted their commit.
- **`gh api` REST cannot resolve threads.** Only GraphQL. If GraphQL
  fails, post a top-level PR comment with `gh pr comment N --body
  "Fixed in <SHA> — <list>"` and leave the threads unresolved — the
  operator will resolve manually.
- **Reply THEN resolve, not the other way.** The reply stays in the
  audit log even after resolution. If you resolve first and then
  forget to reply, the thread disappears without a paper trail. (If
  you forget, the mutation still works — replies are accepted on
  resolved threads.)
- **The new test must fail on the OLD code.** A test that asserts the
  new behavior is also true on the old code is a regression
  enabler. Always include a `not in text` guard against the
  pre-fix value when fixing a formula.
- **Amending a commit that already has a different message is fine
  but loses any prior body.** If the original commit had a useful
  body explaining *why*, copy the gist into the new message before
  amending. Future archeology depends on it.
- **Sub-count formulas.** Whenever a review flags a formula that
  sums/bills a parent and its sub-count, grep the schema definition
  for `sub-count` / `part of` / `subset of` comments. The corrected
  formula is almost always `(parent - sub) * parent_rate + sub *
  sub_rate`, not `(parent + sub) * something`.
- **Placeholder rates need warnings, not just comments.** Operators
  reading the daily report don't read source code — they see a
  number. Emit a stderr warning whenever the placeholder row is
  hit so the number is visibly suspect.
- **Test fixtures must mirror the production slice.** When the code
  under test slices its output (e.g. top-N, paginated, rate-limited),
  the test fixture must rank its fake data so the assertions land
  inside the slice. Asserting the SUM of "expected" values across all
  25 fixtures when the function only returns 10 will fail with an
  off-by-magnitude mismatch that has nothing to do with the bug.
  Symptom: `AssertionError: 91 != 70`. Fix: build the expected value
  with the same ranking + slice logic the production function uses
  (or use a smaller N that doesn't trigger slicing).
- **When the parent task says "resolve threads, no need to reply",
  that's a valid override.** The default rule is reply-then-resolve
  (Non-negotiable #5). But a parent orchestrator may explicitly
  authorize thread resolution without per-thread replies (e.g. to
  unblock `/ready` faster). Follow the parent's override. The
  resolve mutation alone is enough to clear the blocker; the
  audit-trail comment can be added later by `gh pr comment`.
- **No CI polling, ever.** The user is async. You push, you report
  SHA + URL, you exit. `drive-pr-to-green` or the operator owns the
  CI loop.
- **"Iterate until approved" is reviewer-state, not operator-merge**
  (added 2026-08-23, PR #9132). When the operator phrases the goal as
  *"iterate until [reviewer] approves"*, the end-state is the
  reviewer's APPROVED — NOT `MERGE APPROVED`. The two are different
  gates. Surface the reviewer-APPROVED result and stop; do NOT chain
  it into `gh pr merge` even when both look "obvious next steps" —
  the operator will type `MERGE APPROVED` explicitly when ready.
- **CR lag after push can exceed 30 min** (added 2026-08-23, PR
  #9132). CR auto-reviews on push, but the trigger has been observed
  to lag >30 min on worldarchitect.ai. Don't conclude "CR is silent,
  ship it" within the first 30 min of a push — re-trigger with
  `gh pr comment <N> -b "@coderabbitai review"` if you have already
  waited that long. Cap at 3 cycles regardless of trigger behaviour.
