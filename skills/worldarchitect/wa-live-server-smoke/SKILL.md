---
name: wa-live-server-smoke
version: 1.0.0
description: "WA server-side smoke via ./local.sh. Boot + wire + live."
tags: ["worldarchitect", "smoke-test", "local.sh", "verification", "evidence"]
triggers:
  - local.sh smoke
  - live server test wa
  - verify wa change live
  - wa server boot test
  - test it all using local.sh
changelog:
  - '1.0.0 (2026-08-20): Initial extraction from PR #9167 verification. Triple-smoke recipe (boot clean + wire-shape unit tests + live interaction round-trip). TESTING_AUTH_BYPASS short-circuit gotcha documented.'
---

# WA live-server smoke test (the triple-smoke recipe)

## When to fire this skill

Any time you change code under `mvp_site/` that touches the request/response wiring — provider config, LLM provider code, settings handling, code execution, prompt assembly, anything that flows through `main.py` → `world_logic.py` → `llm_service.py` → `llm_providers/*.py` — and the user says any of: "test it all using local.sh", "verify it works", "run it through the server", or simply "ship it" without explicit unit-test evidence. The skill is the **last-mile evidence** step the agent must complete before claiming the change works.

This skill is NOT for changes that are pure logic / pure data / pure prompt-text (no server wiring). For those, unit tests in `mvp_site/tests/` are sufficient. For UI-only changes, use `wa-visual-proof-playwright` instead.

## Why the triple-smoke recipe exists

`TESTING_AUTH_BYPASS=*** ` is the local-dev auth bypass for the running Flask server. It ALSO short-circuits inside `mvp_site/llm_providers/gemini_provider.py:1282` — the `_use_test_stub_client()` check returns True and the function never reaches the wire-builder. That means a live `curl` against the running server in TESTING_AUTH_BYPASS mode **does not exercise** the very code path you just changed.

This caused a real near-miss in PR #9167 (2026-08-20): the worker ran the full `./local.sh` smoke, the server returned 200 on a real campaign interaction, and the worker almost claimed "thinking_config wired through." The debug log line `"Thinking config attached: ..."` never fired because the stub short-circuited before the `types.GenerateContentConfig(...)` constructor. The unit tests in `mvp_site/tests/test_gemini_provider_thinking_config.py` — which patch `get_client` and disable the test stub via `monkeypatch.setenv("TESTING_AUTH_BYPASS", "false")` — were the ONLY thing that actually proved the wire shape.

So the rule is: **wire-shape claims require unit-test evidence; the live server is for boot-clean and end-to-end round-trip only.**

## The triple-smoke recipe (run all three)

### Step 1 — Boot clean with `./local.sh`

```bash
cd ${HOME}/projects/worldarchitect.ai/_wt/<your-branch>
nohup ./local.sh > /tmp/wa-smoke.log 2>&1 &
LOCAL_PID=$!
sleep 25   # Flask + frontend + warmup can take 20-30s on first boot
tail -50 /tmp/wa-smoke.log
```

**Pass criteria:**
- Log line `"Development server running: http://localhost:PORT"` appears.
- `lsof -nP -iTCP:PORT -sTCP:LISTEN` shows the Flask process bound to the port.
- A `curl http://127.0.0.1:PORT/` returns 200 (the homepage serves even unauthenticated).
- No Python traceback lines in the log.

**If port conflicts:** `lsof -nP -iTCP -sTCP:LISTEN | grep 80[8-9][0-9]` shows existing WA dev servers. `./local.sh` auto-picks a random port in 8081-8181 — wait for it to log its chosen port, then read the port from the log.

### Step 2 — Wire-shape via unit test with stub disabled

The unit test MUST disable TESTING_AUTH_BYPASS for the test process and patch `get_client` to capture the wire-shape kwargs. Pattern:

```python
# tests/test_<module>_wire.py
def _disable_test_stub(monkeypatch):
    monkeypatch.setenv("TESTING_AUTH_BYPASS", "false")

def _install_capturing_client(monkeypatch, provider_module, api_calls):
    class _CapturingModels:
        def generate_content(self, **kwargs):
            api_calls.append(kwargs)
            return SimpleNamespace(text='{"stub":true}', parts=[], candidates=[], ...)
    class _FakeClient:
        models = _CapturingModels()
    monkeypatch.setattr(provider_module, "get_client", lambda api_key=None: _FakeClient())

def test_<shape>(monkeypatch):
    from mvp_site.llm_providers import <module>
    api_calls = []
    _disable_test_stub(monkeypatch)
    _install_capturing_client(monkeypatch, <module>, api_calls)
    <module>.<fn_under_test>(...kwargs...)
    config = api_calls[0]["config"]
    assert config.<expected_field> == <expected_value>
```

Run: `TESTING_AUTH_BYPASS=true python3 -m pytest mvp_site/tests/test_<module>_wire.py -v` (the env var at the pytest invocation is harmless — `monkeypatch.setenv` inside the test overrides it).

**Pass criteria:** all wire-shape assertions green. The captured `GenerateContentConfig` (or whatever wire object) MUST contain the field the change is supposed to add.

### Step 3 — Live end-to-end round-trip

```bash
# Enable TESTING_AUTH_BYPASS at server boot so curl can hit authed routes
TESTING_AUTH_BYPASS=true ./local.sh > /tmp/wa-smoke2.log 2>&1 &
sleep 25

# Save settings that select the model under test
curl -fsSL -X POST http://127.0.0.1:PORT/api/settings \
  -H "X-Test-Bypass-Auth: true" \
  -H "X-Test-User-ID: smoke-user" \
  -H "X-Test-User-Email: [email protected]" \
  -H "Content-Type: application/json" \
  -d '{"llm_provider":"gemini","llm_model":"<model-under-test>"}'

# Hit the live interaction endpoint with a real campaign id
curl -fsSL -X POST http://127.0.0.1:PORT/api/campaigns/<existing-campaign-id>/interaction \
  -H "X-Test-Bypass-Auth: true" \
  -H "X-Test-User-ID: smoke-user" \
  -H "X-Test-User-Email: [email protected]" \
  -H "Content-Type: application/json" \
  -d '{"user_input":"<short prompt>","mode":"character","choice_index":-1}'
```

**Pass criteria:** HTTP 200 with a narrative payload containing at minimum `{"success": true, "narrative": ...}`. A real campaign takes 30-60s for the LLM round-trip — use `curl --max-time 90`.

**Don't expect the debug log line.** If the change is supposed to log `"<X> attached"`, the log will be silent in TESTING_AUTH_BYPASS mode because the stub short-circuits. That is NORMAL — the wire-shape unit test (Step 2) is the evidence, not the log.

### Cleanup

```bash
kill $LOCAL_PID
# or pkill -f "worldarchitect.ai.*<branch-name>"
lsof -nP -iTCP:PORT -sTCP:LISTEN   # confirm port is free
```

## Common pitfalls

### Port already in use

The WA dev environment often has 5-15 long-running servers from prior sessions. `./local.sh` auto-picks a free port — let it. Don't use `--force-default-port`; it tries to kill the running server on 8081 and may take down someone else's session.

### `vpython` not found

`vpython` is referenced in `mvp_site/CLAUDE.md` but on this machine `python3` (pointing at `~/.local/orch-venv/bin/python3`) is the actual interpreter. Always use plain `python3 -m pytest`, not `vpython`.

### `TESTING_AUTH_BYPASS` only honored if env var is set at server boot

`mvp_site/main.py:352` reads `TESTING_AUTH_BYPASS_MODE = os.getenv("TESTING_AUTH_BYPASS") == "true"` at module import time. If you start `./local.sh` without the env var and want to enable it later, the CORS allow-list will not include `X-Test-Bypass-Auth`. Restart the server with the env var set.

### TESTING_AUTH_BYPASS short-circuits the wire builder

Re-stated because it's the most important gotcha: in this mode `_use_test_stub_client()` returns True at `gemini_provider.py:1282` and the function never builds the wire config. Wire-shape assertions from the live server are impossible — only the unit test (Step 2) sees them.

### 60-90s real Gemini latency

A live interaction takes 30-60 seconds for the LLM round-trip plus ~10s of warmup. Set `curl --max-time 120` and don't assume the request is hung. The log will show `LATENCY_END: process_action_unified total=...s` when it's done.

### Real Firebase auth still loads

The server logs `"Loading service account from file: ${HOME}/serviceAccountKey.json"` even in TESTING_AUTH_BYPASS mode. That's fine — the bypass is for the user-auth layer, not the service-account Firestore layer.

### Default model vs the model under test

If your change only affects specific models, save settings with that model id BEFORE the live call — `POST /api/settings` is the user-settings round-trip. Without it, the server uses the user's stored model (whatever's in Firestore), not the model you want to test.

## Out of scope

- Browser-side visual proof (use `wa-visual-proof-playwright`).
- BQ telemetry checks (use `wa-llm-output-emission-false-green-watchdog`).
- Production deploy verification (use `wa-pr-preview-deploy-verification`).
- The actual PR-creation flow (use `workflow/always-pr-never-local-edit`).

## Reference

For the full transcript of the originating case (PR #9167, gemini thinking-level change), see `references/pr-9167-originating-case.md`.
