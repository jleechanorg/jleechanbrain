# Chain-walking fix recipe

**Issue**: `runner/dispatcher.py:VerifierDispatcher.run_one` calls `_cli.invoke_reviewer(reviewer, model, prompt)` exactly once. No fallback on rate-limit. The daemon side (`daemon/src/er_runner.rs:230-253`) DOES walk the queue, but the GHA side (which runs `skeptic_gate_cli.py`) does not.

**Symptom**: PR hangs on the `/er` Evidence Gate when the head reviewer (claudem, codex, etc.) is rate-limited. The factory never says "I'm waiting on quota" — it just sits.

**Fix**: Wrap the `_cli.invoke_reviewer` call in a chain-walk loop over `skeptic_reviewer_priority()`.

## Files to modify

1. `runner/dispatcher.py:VerifierDispatcher.run_one` (lines ~91-180) — wrap the call in a chain-walk loop
2. `runner/skeptic_gate_cli.py` — change priority[0]/priority[-1] to use the full list (the dispatcher will pick)
3. New: `tests/test_dispatcher_reviewer_chain_walk.py` — 4 new tests

## Test pattern

```python
def test_chain_walk_falls_back_on_rate_limit(monkeypatch):
    """Premium (claudem) returns rate-limit error; cursor-agent returns valid."""
    # Stub _cli.invoke_reviewer: claudem -> rate-limit, agy -> rate-limit, cursor-agent -> valid
    # Assert: result.reviewer == "cursor-agent", reason contains "fallback_used"
```

## The 4 tests

1. `test_chain_walk_falls_back_on_rate_limit` — premium=claudem returns rate-limit, cursor-agent returns valid → `result.reviewer == "cursor-agent"`, reason contains `fallback_used`.
2. `test_chain_walk_records_fallback_from` — same setup, reason must contain `fallback_from=claudem`.
3. `test_chain_walk_exhausts_all_returns_last_error` — all 3 vendors return rate-limit → `result.verdict == None`, reason contains `all reviewers exhausted`.
4. `test_chain_walk_preserves_provenance_check` — the new fallback path must still call `bind_reviewer_identity` / `verify_provenance` (existing security checks must not be bypassed).

## Discipline points

- Branch from `origin/main`, NOT from `fix/jleechan-w0r4-reap-idle-worker-sessions`
- One commit, message prefix `claudem/minimax-M3:` per env-preferences.mdc
- Daemon on `jeff-ubuntu` also needs `cargo build --release && systemctl restart ai.dark-factory.daemon`
- < 500 lines added, only the 7 files listed (parity readers + dispatcher + 4 new tests)
- Push via `git push origin HEAD:refs/heads/feat/reviewer-fallback-on-quota` and open PR with `gh pr create --base main`

## Existing parity test (already in working tree)

- `tests/test_reviewer_priority_parity.py` (42 lines) — verifies runner-side and daemon-side priority readers agree on the JSON's order. Don't recreate; adopt as-is.
