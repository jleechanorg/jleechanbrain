# PR #9132 streaming-test pitfalls (added 2026-08-22)

Two related failure modes encountered while running the 8-gate `/ready` checklist on PR [#9132](https://github.com/jleechanorg/worldarchitect.ai/pull/9132). Both surface the kind of same-name-rule misfire that wastes diagnostic time when not caught early.

## Pitfall 1 — Reproduction-in-the-wrong-worktree

**What I did:** Ran the same-name-rule Step 3 check from `${HOME}/projects/worldarchitect.ai`, thinking it was a clean main checkout. Concluded "pre-existing on origin/main" because pytest returned 6/6 PASS for `test_streaming_latency_anchoring.py`.

**What I missed:** That parent dir was on detached HEAD `3b645439fd` (the OLD PR tip pre-rebase), not on `origin/main` HEAD `528ddd5147`. The `git rev-parse HEAD` and `git rev-parse origin/main` were different — `git status --short -sb` showed `## HEAD (no branch)` but I didn't notice. The test file was byte-identical between the old PR tip and origin/main, so the test results matched; but the test passing on the old PR tip doesn't prove it passes on actual `origin/main`.

**Cost:** ~1 extra diagnostic round before I caught the error and re-ran from a fresh `/tmp/check-origin-main` worktree (which showed the same 5/6 fail on actual origin/main).

**Hard rule now:** always create a dedicated `git worktree add /tmp/check-origin-main origin/main` for the same-name check. Never reuse the parent checkout, even if it "looks clean". The 30-second setup cost is the price of not lying to the user.

**Detection recipe when you're unsure which worktree you're on:**

```bash
cd <worktree>
git symbolic-ref HEAD 2>/dev/null || echo "detached"
git rev-parse HEAD
git rev-parse origin/main
# If HEAD ≠ origin/main, you're on the wrong worktree
```

## Pitfall 2 — `is_god_mode_command mock regression`

**Symptom signature:**

```
FAILED test_streaming_latency_anchoring.py::TestStreamingLatencyAnchoring::test_done_payload_has_time_to_first_chunk_seconds
  StopIteration at line 74: next(e for e in events if e.type == "done")
  Captured stderr: STREAMING_EMPTY_RESPONSE: chunk_count=1, raw_length=18
```

The streaming-path mock returns `iter(['{"narrative":"ok"}'])` (a single chunk), but the test never sees a `done` event because the mock-prepared `MagicMock()` returns a truthy attribute for any property — when the code reads `prepared.is_god_mode_command`, it gets a truthy `MagicMock` child, takes the god-mode streaming branch, and emits an empty chunk envelope. The `_run_done_payload` generator yields no `done` event, and `next(...)` raises `StopIteration`.

**Affected files in PR #9132:**

| File | `prepared.is_god_mode_command = False` set in `_build_prepared`? | Result |
|---|---|---|
| `mvp_site/tests/test_streaming_latency_regression_uxwn.py` | YES (added in commit `47b91d47df`) | 4/4 pass |
| `mvp_site/tests/test_streaming_latency_anchoring.py` | NO (pre-existing) | 1/6 pass — 5 fail |
| `mvp_site/tests/test_streaming_latency_anchoring.py` on origin/main HEAD | NO (pre-existing) | 1/6 pass — same 5 fail |

**Diagnosis recipe when you see `STREAMING_EMPTY_RESPONSE` in a streaming test:**

1. Check the test file's `_build_prepared()` (or equivalent mock-builder). Does it set `prepared.is_god_mode_command = False`?
2. Compare against a passing sibling test file in the same PR. If the passing one has the line and the failing one doesn't, the fix is to add the line — NOT to fix the upstream streaming path.
3. Do NOT change `llm_service.py` to be more lenient about missing `is_god_mode_command` — that hides the regression for production callers and changes real behavior.

**The subtle trap:** this regression class IS pre-existing on `origin/main` in a specific sense (the same 5 tests fail on main, so the same-name rule validly dismisses them). But gate 3 of the `/ready` checklist is still RED on PR #9132 because gate 3 doesn't care who broke the test — the PR cannot be marked ready until those 5 tests are green, period. The right path is a separate fix-PR that adds the mock line to the missing test file (or fixes the streaming path so the mock doesn't need to set it).

**Anti-pattern (BANNED):** marking a PR as `/ready` while gate 3 is red, on the grounds that "the failing tests are pre-existing on main". The same-name rule is a verification outcome; it does NOT unlock the gate. Gates are gates.

## Worked transcript (PR #9132, 2026-08-22)

```
$ gh pr view 9132 --repo jleechanorg/worldarchitect.ai --json mergeable,mergeStateStatus
{"mergeable": "MERGEABLE", "mergeStateStatus": "UNSTABLE"}

$ bash ~/.smartclaw/scripts/pr_ready_checklist.sh 9132 jleechanorg/worldarchitect.ai
Gate 1 isDraft false: PASS (false)
Gate 2 mergeable MERGEABLE: PASS (MERGEABLE)
Gate 3 CI checks: FAIL (FAIL=Directory tests (core-mvp-1) (FAILURE); FAIL=Directory tests (core-mvp-3) (FAILURE))
Gate 4 Green Gate: PASS (SUCCESS)
Gate 5 CodeRabbit reviewDecision: PASS ("")
Gate 6 Cursor Bugbot: PASS (0 error-severity comments)
Gate 7 Unresolved threads: FAIL (7 unresolved (reviewer feedback not addressed))
Gate 8 Evidence Gate: FAIL (Evidence Gate=, (no gist SHA found in PR body))

OVERALL: FAIL — at least one gate failing

# Get failing test names per shard
$ gh api repos/jleechanorg/worldarchitect.ai/actions/jobs/96989745650/logs | grep -E 'FAILED|ERROR'
  ERROR: test_done_payload_has_time_to_first_chunk_seconds
  ERROR: test_handler_entry_anchor_widens_time_to_first_chunk
  FAILED (errors=5)

$ gh api repos/jleechanorg/worldarchitect.ai/actions/jobs/96989745668/logs | grep -E 'FAIL:'
  FAIL: test_absent_user_id_raises_value_error (test_rag_activation.py line 805)

# Same-name check: test_streaming_latency_anchoring.py
$ git worktree add /tmp/check-origin-main origin/main
$ cd /tmp/check-origin-main && ln -s ${HOME}/projects/worldarchitect.ai/venv venv
$ ./vpython -m pytest mvp_site/tests/test_streaming_latency_anchoring.py
  FAILED 5, PASSED 1   # Same as PR tip — valid pre-existing dismissal

# Same-name check: test_rag_activation.py
$ ./vpython -m pytest mvp_site/tests/test_rag_activation.py::TestPrepareStoryContinuationMissingUserId
  PASSED 2             # Different from PR tip — NOT pre-existing

# Root cause of test_rag_activation.py failure:
$ git diff origin/main..origin/fix/action-resolution-warning-agent-exempt-9114 -- mvp_site/llm_service.py \
  | grep -E '^[+-].*user_id|missing_user_id|test_user_anonymous'
  -    user_id_from_state = user_id
  +    user_id_from_state = user_id or current_game_state.user_id
  -        raise ValueError("user_id is required ...")
  +        user_id_from_state = "test_user_anonymous"
  +        raise ValueError("user_id is required ...")

# Conclusion: PR #9132 introduced a fallback to "test_user_anonymous" instead of raising
# ValueError when user_id is absent. CodeRabbit Gate 6 (mvp_site/llm_service.py:7929)
# already flagged this exact concern; PR didn't fix it.
```

**Outcome:** honest FAIL report to user, did NOT mark `/ready`. Notified user that Gate 3 has two distinct sub-causes (one pre-existing, one PR-introduced) and Gate 7 has 7 unresolved CodeRabbit threads that block anyway. User can now decide whether to (a) fix the user_id regression in PR #9132 itself, (b) dispatch a separate fix-PR for the streaming test mock, or (c) address the 7 CodeRabbit threads. No code was pushed on this unblock turn.
