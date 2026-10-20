# ddf-PR-9092-outage — originating incident for Class F

**Date:** 2026-08-18
**Originating Slack thread:** `C0AH3RY3DK6/p1787112356.555659`
**Originating PR:** [jleechanorg/worldarchitect.ai#9092](https://github.com/jleechanorg/worldarchitect.ai/pull/9092)
**User's verbatim prescription:** *"the factory shouldnt stop on codex quota? It should fallback to another cli."*

## What this document is

The walk-through of the first observed `Class F` failure (codex review quota cascading into `re-roll held` / `infra_failure`) that this skill's Class F section was built from. The next time you see a message that looks like *"gate is stuck on codex quota"*, read this — it's the exact pattern, the exact sequence, and the exact fix.

## The failure pattern

### The setup

PR #9092's intent was a small, scoped change: switch the default model in `worldarchitect.ai` settings back to `gemini-3-flash-preview` and label it as the best speed/quality tradeoff. The work itself was trivial — 3 commits on a branch off `origin/main`, all tests pass, CI green.

### The sequence

| Time | Action | Resulting state |
|---|---|---|
| t=0 | User: "Make a PR and fullrun bring it to /ready using /af to switch the default model in settings back to gemini 3 flash and say its the best speed/quality tradeoff" | PR #9092 created, factory-labeled. |
| t=+5m | Daemon adopted bead `dark-factory-4pjg`, posted `/er FAIL missing canonical Evidence gist line with matching head SHA`. | First `/er` failure — worker only pasted pytest output, didn't upload a gist. |
| t=+5m | Daemon spawned re-roll session `wa-3516` (REROLL_ADOPTED_SESSION_SPAWNED). | Re-roll in progress; daemon merged `origin/main` into branch (commit `3149b94773`). |
| t=+25m | Status cron `45075a684299` fired. PR #9092 still OPEN, factory-labeled, daemon in `DISPATCHED`. | No follow-up `ER_RUNNER_POSTED` on attempt 2. Re-roll session `wa-3516` quietly stalled. |
| t=+30m | User: "Also make it the default its currently not" — agent dispatched worker `proc_de9c662999ff` to add `<option value="gemini-3-flash-preview" selected>`. | Worker hit max-turns (20) but **commit `e82873982` was already pushed**. PR head now `e828739826985057a4a83219493dd5c6fd1c4a85`. |
| t=+50m | Daemon emitted `/er FAIL evidence gist head is stale (3149b947, PR head e8287398)`. | Second `/er` failure — root cause: the evidence gist was at `3149b94773`, PR HEAD advanced to `e828739826`. |
| t=+50m | Daemon spawned re-roll session, then **parked with `PARKED_HUMAN_HELD reason: re-roll held. Reason: an AO session is already active on adopted branch`**. | **Class C2** (or Class F — the cause is at the gate level, not the dispatcher level). |
| t=+55m | Operator unblock: created fresh gist at head `e828739826`, updated PR body, posted `/er` comment. | Daemon's next tick re-evaluates. |
| t=+60m | Status cron `6fce3d3320a1` armed (final-status check +20min). | Daemon will report `/er PASS` or `READY` on next intake. |
| t=+50m (parallel) | Operator's status message included an explicit offer for `MERGE APPROVED` to bypass the gate. | User did not pick this path; the Slack thread continued with the gate watch. |
| t=+12h | Codex code-review quota remained hot. The re-roll session kept failing — every gate attempt returned `outcome="error"` with stderr matching `/(rate.?limit|quota exceeded|429|too many requests)/i`. | **Class F fully visible.** The runner's `_execute_gate` fallback to `["agy","claude"]` (line 1152-1156) was attempting agy, but agy's own quota was also exhausted. The loop converged on `infra_failure`. The PR was effectively parked. |
| t=+12h | User: "The factory shouldnt stop on codex quota? It should fallback to another cli" | This is the message that triggered this skill's Class F section to be written. |

## The mismatch between current behavior and user's expectation

**Current behavior** (in `runner/handler_dispatch.py:_execute_gate`):
- Tries the first entry of `backend_priority` (e.g. `codex`).
- If `_is_gate_infra_failure(result)` returns True (which it does for `outcome="error"`), it falls back to a hardcoded `["agy","claude"]` chain.
- Stops after the first non-infra result, OR after the chain is exhausted.

**Problem**: The fallback chain is **hardcoded** to `agy → claude` — it does NOT walk the actual `backend_priority` queue. If the user's diagram specifies `backend_priority="codex"` (a single string), the fallback is the same regardless of what other backends are installed. If both `codex` and `agy` are rate-limited (the PR #9092 case), the chain converges on `infra_failure` and the PR is parked.

**User's expectation** (verbatim): *"the factory shouldnt stop on codex quota? It should fallback to another cli."* — the runner should walk the full `backend_priority` chain on quota, not just stop at the hardcoded agy/claude list.

**The fix** (separate PR, not yet landed at time of writing):
1. `runner/handler_dispatch.py`: add `_detect_rate_limit(proc)` helper.
2. `_is_gate_infra_failure`: extend to return `True` when `rate_limited=="true"`.
3. `_execute_gate` (line 1152-1156): replace hardcoded `["agy","claude"]` with a walk through the actual `backend_priority` queue.
4. `pipelines/slim/two_node.dot`: change `backend_priority="codex"` to `backend_priority="codex,minimax,agy,claude-sonnet"`.
5. `tests/test_cli_fallbacks.py`: add 4 tests covering the rate-limit path.

## Why this is a class, not a one-off

Codex code-review quota is rate-limited daily. The pattern will recur every PR that lands near the quota boundary. The Class F decoder section in `references/refusal-cause-decoder.md` and the Class F detail section in `SKILL.md` are the canonical operator-side handling; the run-side fix is a separate workstream.

## Cross-reference

- `SKILL.md` — Class F detail section (this skill)
- `references/refusal-cause-decoder.md` — Class F decoder entry
- PR #9092 Slack thread: `C0AH3RY3DK6/p1787112356.555659`
- `runner/handler_dispatch.py` lines 1119-1171 — current single-fallback chain
- `tests/test_cli_fallbacks.py` — test surface (currently 0 cover rate-limit)
- `pipelines/slim/two_node.dot:49` — single-string `backend_priority="codex"`
