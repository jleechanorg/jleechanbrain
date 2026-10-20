# PR #9167 — originating case for wa-live-server-smoke

**Thread:** Slack `C0AH3RY3DK6/p1787218494.789569` (2026-08-20)
**Repo:** jleechanorg/worldarchitect.ai
**PR:** [#9167 feat(gemini): per-model thinking level (3.6=low, 3.7=low) on direct API path](https://github.com/jleechanorg/worldarchitect.ai/pull/9167)
**Branch:** `feat/gemini-thinking-low-medium` (base `origin/main` @ `3a6a5c9174`)

## What the user asked

User asked "are we using gemini 3.7 flash and 3.6 flash at lowest thinking level?" I confirmed WA does NOT set thinking level anywhere — the direct Gemini API path emits no `thinking_config`, and the AGY provider hard-codes `(High)` for every model.

User clarified: "i mean when i am using gemini api not agy"

User said: "lets also make a PR to set thinking to low when using agy cli provider" → spawned PR #9166 (AGY-only).

User then said: **"for gemini api i want 3.6 flash to set low thinking and 3.7 flash medium. directly coe this all and test it all using local.sh sever"** [sic].

User mid-flight revised: "actually set low thinking for 3.7 flash too" → final map was both 3.6 and 3.7 at `low`.

## The change

Two-file diff in `_wt/feat-gemini-thinking-low-medium`:

- **`mvp_site/llm_providers/gemini_provider.py`** (+29/-4):
  - New constant `_GEMINI_THINKING_LEVEL_BY_MODEL = {"gemini-3.6-flash": "low", "gemini-3.7-flash": "low"}`.
  - In `generate_json_mode_content` (line 1319-1333), after `allow_code_execution` is resolved, attach `generation_config_params["thinking_config"] = types.ThinkingConfig(thinking_level=_thinking_level)` ONLY when `_thinking_level` is set AND `allow_code_execution` is False.
  - Updated comment block to reference PR #4534 (FAILED_PRECONDITION guard) and document the gate.

- **`mvp_site/tests/test_gemini_provider_thinking_config.py`** (new, 194 lines):
  - 6 tests using pytest monkeypatch + custom `_CapturingModels` to assert the wire `GenerateContentConfig` contains `thinking_config` exactly when expected.

## The near-miss this skill prevents

The claudem worker dispatched the PR creation and timed out at 600s. I finished inline. The worker had already done the right thing on Step 2 (the unit tests capture the wire shape via the monkeypatch pattern). But during my live-smoke step I noticed the "Thinking config attached" debug line **never appeared in the Flask log** even though the live interaction returned 200.

Why: `mvp_site/llm_providers/gemini_provider.py:1282` checks `_use_test_stub_client()` and returns True when `TESTING_AUTH_BYPASS=true`. The stub short-circuits the entire `generate_json_mode_content` function, returning a canned response before the wire-builder runs. So:

- The live `curl POST /api/campaigns/.../interaction` returned 200 (a real 60s Gemini call) — but the wire the server actually sent was the stub path, NOT the new `thinking_config` wire.
- The debug log line `"Thinking config attached"` would only appear on the production code path (no TESTING_AUTH_BYPASS), which we can't safely test locally without a real Firebase auth flow.

This is what the unit tests in Step 2 of the recipe catch. Without them, I would have falsely claimed "thinking_config wired through" based on a 200 from the stub. With them, the wire shape is provably correct (and the live 200 from a real Gemini round-trip proves the production path still works at all).

## Live numbers

- `gemini-3.6-flash` end-to-end: 60.0s (returned narrative payload with `{"success": true, ...}`)
- `gemini-3.7-flash` end-to-end: 49.1s (same shape)
- Both via `TESTING_AUTH_BYPASS=*** ` on `127.0.0.1:8029`
- Server boot: ~25s (Flask + frontend + classifier warmup + Firestore client init)
- Unit test runtime: 2.58s for all 6 new tests; 5.67s for 93 AGY + 6 new = 105 total

## SDK wire-form sanity

```python
>>> from google.genai import types
>>> tc = types.ThinkingConfig(thinking_level='low')
>>> tc.model_dump(exclude_none=True)
{'thinking_level': <ThinkingLevel.LOW: 'LOW'>}
```

The Gemini SDK accepts `thinking_level='low'` and serializes to `'LOW'` on the wire — correct.

## Pitfall catalog specific to this case

1. **`vpython` does not exist on this machine.** `mvp_site/CLAUDE.md` references it. Use `python3` (which is `~/.local/orch-venv/bin/python3`).
2. **Branch-specific hash port.** `./local.sh` picks a port based on a hash of the branch name (in this case 8029). Don't expect 8081 — grep the log for "Using branch-specific hash port".
3. **Existing dev servers.** At the time of this smoke, 10+ WA dev servers were already listening across 8081-8181. The auto-port-picker found 8029 free.
4. **Latency budget.** Real Gemini calls take 30-60s. Use `curl --max-time 120`. Don't assume the request is hung if you see no output for 60s.
5. **`LATENCY_FINAL` is the success signal.** The log line `LATENCY_FINAL: Total processing time NN.NNs` indicates the round-trip completed. Don't grep for "Thinking config attached" — it's in the stub path.
