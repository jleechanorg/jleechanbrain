---
name: testing-mcp-real-server-proof
version: 1.0.0
description: "Write no-mocks real-server tests for worldarchitect.ai."
tags: ["worldarchitect", "testing", "testing-mcp", "real-server", "no-mocks", "evidence"]
category: worldarchitect
triggers:
  - write a testing_mcp test
  - real-server proof
  - no-mocks test
  - prove the change works
  - verify with real server
  - testing_mcp dev_server
  - X-Test-Bypass-Auth
  - testing_mcp/lib/base_test
  - real Flask server round-trip
  - post/get round-trip
changelog:
  - "1.1.0 (2026-08-22): Added campaign-creation test recipe (POST /api/campaigns + GET /api/campaigns/<id>), plus 3 pitfalls from real run: (a) `from lib import ...` requires project root on sys.path (testing_mcp.dev_server transitive import), (b) `evidence_utils.create_evidence_bundle` requires `scenarios`/`steps`/`test_cases`/`frames` keys in results dict (not `test_passed`), (c) test scripts that capture campaign_id inside `test_*()` need to thread it back into `main()`'s results dict (the hardcoded fallback leaves orphan 'campaign not found' warnings)."
related_skills:
  - wa-model-registry-change
  - finish-the-job
  - drive-pr-to-green
  - hermes-deploy-pipeline
---

# testing_mcp Real-Server Proof

**The recipe for writing a `testing_mcp/` test script that proves a worldarchitect.ai change works against a REAL local Flask server with REAL HTTP, REAL HTML, and REAL Python module imports — no mocks, no fakes, no stubs.** This is the highest-fidelity evidence layer for `mvp_site/**` changes; use it whenever you need to prove a feature actually works end-to-end on the same code path the browser takes.

## When to use

- After making changes to `mvp_site/constants.py`, `mvp_site/main.py`, `mvp_site/llm_service.py`, or any production module that affects settings/registration/model selection.
- Before opening a PR that touches user-visible behavior (settings page, dropdowns, dice routing).
- When a unit test alone doesn't prove the change works (you need the real Flask route, the real HTML template render, the real Werkzeug integration).
- When the user says "test it" or "verify it works" and the answer needs to be more than "unit tests pass".

## What `testing_mcp/` is (and isn't)

`testing_mcp/` is a directory of scripts that:
- Connect to a REAL local Flask server (started by `local.sh`)
- Use REAL HTTP, REAL headers, REAL cookies
- Import REAL Python modules (no sys.path stubbing, no `unittest.mock` patches)
- Write artifacts to `/tmp/<test_name>_evidence/` for audit

`testing_mcp/` is NOT:
- NOT pytest unit tests (those live in `mvp_site/tests/` and may use mocks freely)
- NOT browser tests (those live in `testing_ui/` and use Playwright/Puppeteer)
- NOT smoke tests with SMOKE_TOKEN (per `testing_mcp/CLAUDE.md`, `SMOKE_TOKEN` triggers per-request mock LLM and is FORBIDDEN here)

**Hard rule from `testing_mcp/AGENTS.md`:** "NO MOCKS — `testing_mcp/` tests connect to real servers, real Firebase, real LLMs. If you introduce mocks here, the tests are invalid and will be rejected."

## The 6-layer proof shape

Every real-server proof should cover at least these 6 layers, in this order. Each layer adds confidence that a different class of breakage was caught.

### Layer 1 — Constants invariants (Python import)

Import the real module and assert all the model/code-exec/window invariants hold. This catches missing registrations BEFORE you even hit the network.

```python
from mvp_site import constants, dice_strategy
assert "gemini-3.6-flash-high" in constants.ALLOWED_GEMINI_MODELS
assert constants.GEMINI_MODEL_MAPPING.get("gemini-3.5-flash") == "gemini-3.6-flash"
assert "gemini-3.6-flash-high" in constants.MODELS_WITH_CODE_EXECUTION
assert constants.MODEL_CONTEXT_WINDOW_TOKENS["gemini-3.6-flash-high"] == 1_000_000
```

### Layer 2 — Dice strategy routing

Verify the dice-strategy decision function returns the right path for each model. This catches misclassification in `dice_strategy.get_dice_roll_strategy()`.

```python
from mvp_site.dice_strategy import get_dice_roll_strategy, DICE_STRATEGY_CODE_EXECUTION
assert get_dice_roll_strategy("gemini-3.6-flash", "gemini") == DICE_STRATEGY_CODE_EXECUTION
```

### Layer 3 — POST + GET round-trip through `/api/settings`

Hit the real Flask route, save the model, read it back. This catches missing Place 1 (ALLOWED_GEMINI_MODELS) registrations (server rejects with 400), Place 2 (GEMINI_MODEL_MAPPING) misconfigurations, and `check_token` / `@limiter.limit` decorator issues.

### Layer 4 — Legacy-redirect round-trip

POST a model that was removed from the dropdown (e.g. `gemini-3.5-flash`) and verify the server accepts it (status 200) AND that the redirect target exists in `GEMINI_MODEL_MAPPING`. Storage layer preserves the literal value (correct behavior per `wa-model-registry-change` "Legacy-redirect storage policy").

### Layer 5 — Served HTML dropdown reflects the change

GET `/settings` and grep the served HTML for `<option value="X">` entries. This catches missing Place 5 (settings.html `<option>`) and Place 6 (settings.js mapping) registrations — the HTML rendered by Flask must contain all the new options.

### Layer 6 — Optional: dice/streaming/agent pool layers

For dice-specific changes: run a real dice roll through `/interaction/stream` and verify the response contains dice results. For streaming changes: verify `streaming_evidence.json` has `chunk_count > 0` and the done payload shows `execution_path: "streaming"`. Skip these layers if your change doesn't affect dice/streaming.

## The X-Test-Bypass-Auth contract (CRITICAL — read before writing the HTTP client)

The local Flask server (started by `local.sh` with `TESTING_AUTH_BYPASS=true ALLOW_TEST_AUTH_BYPASS=true`) accepts a two-header auth bypass. Per `mvp_site/main.py:1838-1851`:

```python
if (
    request.headers.get(HEADER_TEST_BYPASS, "").lower() == "true"
    and (TESTING_AUTH_BYPASS_MODE or not is_preview)
    and not is_production
    and (
        (TESTING_AUTH_BYPASS_MODE and ALLOW_TEST_AUTH_BYPASS)
        or bool(app.config.get("TESTING"))
    )
):
    kwargs["user_id"] = request.headers.get(HEADER_TEST_USER_ID, "test-user-123")
    kwargs["user_email"] = request.headers.get("X-Test-User-Email", "test@example.com")
```

The header names (from `mvp_site/main.py:458-460`):

```python
HEADER_TEST_BYPASS = "X-Test-Bypass-Auth"   # must be exactly "true"
HEADER_TEST_USER_ID = "X-Test-User-ID"      # any unique test user id
HEADER_TEST_USER_EMAIL = "X-Test-User-Email"  # optional, defaults to test@example.com
```

**Common mistake:** trying `?test_mode=true&test_user_id=foo` query params. The server doesn't honor these on `/api/settings` (which uses `@check_token`). Use the headers above, NOT query params.

```python
req = urllib.request.Request(
    url=f"{base_url}/api/settings",
    method="POST",
    data=json.dumps({"gemini_model": "gemini-3.6-flash"}).encode("utf-8"),
    headers={
        "Content-Type": "application/json",
        "X-Test-Bypass-Auth": "true",
        "X-Test-User-ID": TEST_USER_ID,  # unique per test run
    },
)
```

## The Werkzeug reloader pitfall (verified 2026-08-13)

When `local.sh` launches Flask, it starts in debug/reloader mode by default. **Any file edit to `mvp_site/` triggers a reload, which drops the listening port for ~2-3 seconds while the worker restarts.** If your test script makes a request during that window, you get `ConnectionRefusedError` or `RemoteDisconnected`.

Mitigation patterns:
1. **Run the test AFTER all edits are committed and the server is settled.** Wait 5-10 seconds after the last edit before starting the test.
2. **Wrap HTTP calls in a retry loop with exponential backoff.** Useful for flaky CI environments but overkill for a single local run.
3. **Disable the reloader.** Set `FLASK_DEBUG=0` or use `gunicorn` for production-like runs. The `local.sh` launcher doesn't expose this knob directly; you'd need to invoke `gunicorn` directly.

For a single local run, the simplest pattern is: `sleep 10` after starting the server (or after the last edit), then run the test. Re-run the test once if it fails on `ConnectionRefusedError` — that's the reloader tripping.

## The vpython venv-symlink trick (verified 2026-08-13)

The `vpython` shim in `worldarchitect.ai` looks for `venv/bin/activate` in the directory you invoke it from. A worktree doesn't have its own venv — you have to symlink to the main checkout's venv:

```bash
cd ~/projects/worktree_<topic> && ln -s ~/projects/worldarchitect.ai/venv venv
./vpython testing_mcp/test_<topic>.py  # works
```

Without the symlink, `vpython` exits with: `Error: Virtual environment activate script not found at <worktree>/venv/bin/activate`.

## The base_url discovery pattern

`testing_mcp/dev_server.py` provides `get_base_url()` which computes the worktree-specific port (default 8081, but each worktree can override with `WORKTREE_PORT_OVERRIDE` env var). Use it instead of hardcoding `http://localhost:8081`:

```python
from testing_mcp.dev_server import get_base_url
base_url = get_base_url()
print(f"[run] base_url = {base_url}")
```

If you need a different port for some reason, set `WORKTREE_PORT_OVERRIDE` before invoking `local.sh`:
```bash
WORKTREE_PORT_OVERRIDE=8074 TESTING_AUTH_BYPASS=true ALLOW_TEST_AUTH_BYPASS=true \
  bash local.sh --no-log-stream --force-default-port
```

## The script template

```python
#!/usr/bin/env python3
"""
Verify <CHANGE DESCRIPTION> in worldarchitect.ai — no mocks, real Flask.

This script exercises the real local Flask server (via testing_mcp.dev_server)
and verifies the 6 layers:
  1. constants invariants (Python import)
  2. dice strategy routing (Python import)
  3. POST + GET /api/settings round-trip (real HTTP)
  4. legacy redirect round-trip (real HTTP)
  5. served /settings HTML contains new <option> entries (real HTTP)
  6. (optional) dice/streaming/agent pool layers
"""
from __future__ import annotations

import json
import sys
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))  # project root

from testing_mcp.dev_server import get_base_url


# Constants — adjust per change
NEW_MODELS = ("gemini-3.6-flash", "gemini-3.6-flash-high")
LEGACY_REMOVED = "gemini-3.5-flash"
TEST_USER_ID = "test-<change-name>-registration"


def _http(method: str, url: str, *, payload: dict | None = None) -> tuple[int, dict | str]:
    """Real HTTP against the local Flask server with auth bypass."""
    if payload is None:
        data_bytes = None
    else:
        data_bytes = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url=url,
        method=method,
        data=data_bytes,
        headers={
            "Content-Type": "application/json",
            "X-Test-Bypass-Auth": "true",
            "X-Test-User-ID": TEST_USER_ID,
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:  # noqa: S310
            raw = resp.read().decode("utf-8", errors="replace")
            try:
                return resp.status, json.loads(raw)
            except json.JSONDecodeError:
                return resp.status, raw
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", errors="replace") if e.fp else ""
        try:
            return e.code, json.loads(raw)
        except json.JSONDecodeError:
            return e.code, raw


def run() -> int:
    base_url = get_base_url()
    print(f"[run] base_url = {base_url}")
    errors: list[str] = []

    # --- Layer 1: constants invariants ---
    print("\n[1] Constants invariants:")
    from mvp_site import constants as c
    # Assert each invariant; append to errors on failure.

    # --- Layer 2: dice strategy routing ---
    print("\n[2] Dice strategy routing:")
    from mvp_site.dice_strategy import (
        get_dice_roll_strategy,
        DICE_STRATEGY_CODE_EXECUTION,
        DICE_STRATEGY_NATIVE_TWO_PHASE,
    )
    # Assert each model routes to the right strategy.

    # --- Layer 3: POST + GET round-trip ---
    print("\n[3] POST + GET /api/settings round-trip:")
    for m in NEW_MODELS:
        status_post, body_post = _http(
            "POST", f"{base_url}/api/settings", payload={"gemini_model": m}
        )
        if status_post != 200:
            errors.append(f"POST /api/settings for {m} returned {status_post} (expected 200)")
        status_get, body_get = _http("GET", f"{base_url}/api/settings")
        if isinstance(body_get, dict) and body_get.get("gemini_model") != m:
            errors.append(
                f"GET /api/settings for {m} returned gemini_model="
                f"{body_get.get('gemini_model')!r} (expected {m!r})"
            )

    # --- Layer 4: legacy redirect round-trip ---
    print("\n[4] Legacy redirect round-trip:")
    if LEGACY_REMOVED:
        status_post, _ = _http(
            "POST", f"{base_url}/api/settings", payload={"gemini_model": LEGACY_REMOVED}
        )
        if status_post == 200:
            # POST returns generic {"message": "Settings saved"}; verify via GET
            _, body_get = _http("GET", f"{base_url}/api/settings")
            # Storage layer preserves the literal value (correct). Just verify
            # the redirect target exists.
            target = c.GEMINI_MODEL_MAPPING.get(LEGACY_REMOVED)
            if target is None:
                errors.append(f"Legacy {LEGACY_REMOVED} has no redirect in GEMINI_MODEL_MAPPING")
        else:
            errors.append(f"POST /api/settings for {LEGACY_REMOVED} returned {status_post}")

    # --- Layer 5: served HTML dropdown ---
    print("\n[5] Served /settings HTML contains new <option> entries:")
    status_html, html_body = _http("GET", f"{base_url}/settings")
    if status_html != 200 or not isinstance(html_body, str):
        errors.append(f"GET /settings returned {status_html} (expected 200, string)")
    else:
        for m in NEW_MODELS:
            if f'value="{m}"' not in html_body:
                errors.append(f"settings HTML missing <option value=\"{m}\">")
        if LEGACY_REMOVED and f'value="{LEGACY_REMOVED}"' in html_body:
            errors.append(f"settings HTML still contains legacy <option value=\"{LEGACY_REMOVED}\">")

    print("\n" + "=" * 60)
    if errors:
        print(f"FAILED — {len(errors)} error(s):")
        for e in errors:
            print("  -", e)
        return 1
    print("PASSED — all layers verified")
    return 0


if __name__ == "__main__":
    sys.exit(run())
```

## How to run

```bash
# 1. Make sure you have a venv symlink in the worktree
cd ~/projects/worktree_<topic> && ln -sf ~/projects/worldarchitect.ai/venv venv

# 2. Start the local server (in a separate terminal or backgrounded)
cd ~/projects/worktree_<topic> && \
  TESTING_AUTH_BYPASS=true ALLOW_TEST_AUTH_BYPASS=true \
  bash local.sh --no-log-stream --force-default-port > /tmp/<topic>_server.log 2>&1 &

# 3. Wait for the server to settle (Werkzeug reloader needs ~30s)
sleep 30 && curl -fsS -m 5 "http://127.0.0.1:8081/api/constants/models" | head -c 100 && echo

# 4. Run the test
cd ~/projects/worktree_<topic> && \
  TESTING_AUTH_BYPASS=true ALLOW_TEST_AUTH_BYPASS=true \
  ./vpython testing_mcp/test_<topic>.py
```

If the test fails on `ConnectionRefusedError` or `RemoteDisconnected`, wait 10s and re-run — the Werkzeug reloader tripped mid-test.

## Pitfalls

- **Forgetting the venv symlink.** Worktrees don't have their own `venv/` directory. Symlink to the main checkout's venv: `ln -s ~/projects/worldarchitect.ai/venv venv`.
- **Using `?test_mode=true&test_user_id=foo` query params.** The server doesn't honor these on `/api/settings`. Use `X-Test-Bypass-Auth: true` + `X-Test-User-ID: <unique>` headers.
- **Setting `TESTING_AUTH_BYPASS=*** (literal `***`)** instead of `TESTING_AUTH_BYPASS=true`. The env-var comparison is `os.getenv(...) == "true"`, so `***` evaluates to False and bypass is disabled. Use the literal string `true`.
- **Calling the test while the Werkzeug reloader is restarting.** Wait 10s after any `mvp_site/` file edit. The reload takes ~2-3s and drops the listening port during that window.
- **Asserting that POST+GET returns the legacy redirect target.** The storage layer preserves the literal stored value by design — only the LLM-call path applies the redirect. Test that the redirect target exists in `GEMINI_MODEL_MAPPING`, not that the stored value changes.
- **Hardcoding `http://localhost:8081`.** Use `testing_mcp.dev_server.get_base_url()` instead. The worktree port can be overridden with `WORKTREE_PORT_OVERRIDE` env var.
- **Running the test while another worktree's local.sh is alive on the same port.** The dev_server picks the worktree port from the directory name. Two worktrees with similar names can collide. Check `lsof -ti:8081` before running.
- **Asserting that `/api/settings` POST echoes the saved value in the response body.** It doesn't — POST returns a generic `{"message": "Settings saved", "success": true}`; the saved value only appears on the next GET.
- **`from lib import ...` needs project root on `sys.path`** (added 2026-08-22). `testing_mcp/lib/__init__.py` transitively imports `testing_mcp.dev_server`, which is a top-level package import that ONLY resolves if the project root is on `sys.path`. The older `test_rest_api_character_placeholder_bug.py` template uses `sys.path.insert(0, str(Path(__file__).parent))` (just the testing_mcp dir) and that DOES NOT WORK for `from lib import evidence_utils` because `lib` is a subpackage of `testing_mcp`. **Fix: always include BOTH `sys.path.insert(0, str(Path(__file__).parent))` AND `sys.path.insert(0, str(Path(__file__).resolve().parent.parent))` in that order.** Symptom: `ModuleNotFoundError: No module named 'testing_mcp'` from `lib/base_test.py` line 75 (`from testing_mcp.dev_server import ...`).
- **`evidence_utils.create_evidence_bundle` rejects `{"test_passed": bool}`** (added 2026-08-22). It looks for one of `scenarios`, `steps`, `test_cases`, or `frames` in the results dict and raises `ValueError: Unrecognized result format. Could not find 'scenarios', 'steps', 'test_cases', or 'frames' in results keys: [...]` otherwise. **Fix:** the results dict passed to `create_evidence_bundle` MUST be shaped like:

  ```python
  results = {
      "test_name": WORK_NAME,
      "scenarios": [
          {
              "name": "scenario_one",
              "passed": bool,
              "errors": [],                    # list of error strings
              "campaign_id": "...",            # optional context
              "user_id": "...",                # optional context
          }
      ],
  }
  ```

  `passed` at the top level is NOT enough — it must be per-scenario. The top-level `test_passed` is auto-derived from `all(s["passed"] for s in scenarios)`.
- **Campaign-id leaks between test runs** (added 2026-08-22). If `test_<topic>()` captures `campaign_id` inside the function but `main()` builds the `results` dict from a hardcoded fallback (e.g. `"campaign_id": "placeholder"`), the bundle's auto-export step will try to download the wrong ID and fail with `Campaign <id> not found`. **Fix:** thread the live `campaign_id` from `test_<topic>()` back to `main()` via a module-level variable set at the top of the test function (`global CAMPAIGN_ID; CAMPAIGN_ID = result["campaign_id"]`), or return it from the test function. The hardcoded-fallback pattern looks safe but pollutes the evidence bundle with permanent warnings on every run.

## The campaign-creation test recipe (added 2026-08-22)

90% of `testing_mcp/` tests are "create a campaign, fetch its state, assert on the served state." The settings-page template (above) covers Layers 1-2; this recipe covers the **most common real-server test shape**: POST `/api/campaigns` + GET `/api/campaigns/<id>` + Scene-1 acceptance. Verified working pattern from `testing_mcp/test_wa_campaign_astarion_v2_creation.py` (commit `cf4f504226` on `worldarchitect.ai`):

```python
#!/usr/bin/env python3
"""Test campaign creation: POST /api/campaigns + GET state + Scene-1 acceptance."""
import argparse
import json
import os
import sys
from datetime import UTC, datetime
from pathlib import Path

import requests

sys.path.insert(0, str(Path(__file__).parent))
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))  # project root
from lib import evidence_utils
from lib.server_utils import DEFAULT_MCP_BASE_URL

BASE_URL = os.getenv("BASE_URL") or DEFAULT_MCP_BASE_URL
USER_ID = f"wa-test-{datetime.now(UTC).strftime('%Y%m%d%H%M%S')}"
WORK_NAME = "wa_test_topic"
CAMPAIGN_ID = None  # module-level; set by test_campaign_creation on success

EVIDENCE_DIR = evidence_utils.get_evidence_dir(WORK_NAME) / datetime.now(UTC).strftime(
    "%Y%m%d_%H%M%S"
)
EVIDENCE_DIR.mkdir(parents=True, exist_ok=True)


def log(msg: str) -> None:
    ts = datetime.now(UTC).isoformat()
    print(f"[{ts}] {msg}"); sys.stdout.flush()


def test_campaign_creation() -> bool:
    """Run the test body. Sets module-level CAMPAIGN_ID on success."""
    global CAMPAIGN_ID
    auth_headers = {}
    if os.getenv("TESTING_AUTH_BYPASS") != "true":
        log("⚠️ TESTING_AUTH_BYPASS not set"); return False
    auth_headers["X-Test-Bypass-Auth"] = "true"
    auth_headers["X-Test-User-ID"] = USER_ID

    payload = {"title": "...", "character": "...", "setting": "...",
               "description": "...", "selected_prompts": [], "custom_options": []}

    # Step 1: POST /api/campaigns
    log("Step 1: POST /api/campaigns")
    resp = requests.post(
        f"{BASE_URL}/api/campaigns",
        json=payload,
        headers={**auth_headers, "Content-Type": "application/json"},
        timeout=120,
    )
    resp.raise_for_status()
    cid = resp.json().get("campaign_id")
    if not cid:
        log(f"❌ No campaign_id in response: {resp.json()}"); return False
    CAMPAIGN_ID = cid
    log(f"✅ Campaign created: {cid}")

    # Step 2: GET /api/campaigns/<id>?story_limit=10
    log(f"Step 2: GET /api/campaigns/{cid}?story_limit=10")
    state = requests.get(
        f"{BASE_URL}/api/campaigns/{cid}?story_limit=10",
        headers=auth_headers, timeout=120,
    ).json()

    # Step 3: extract Scene 1 (first actor=gemini/agent/system entry with text)
    story = state.get("story", []) or []
    scene1 = ""
    for entry in story:
        if isinstance(entry, dict):
            if entry.get("actor") in ("gemini", "agent", "system") and entry.get("text"):
                scene1 = entry["text"]
                if entry.get("user_scene_number") == 1: break
    log(f"Scene 1: {len(scene1)} chars, preview: {scene1[:200]}...")

    # Step 4: acceptance checks — placeholder absent + substantial content
    placeholder = "[Character Creation Mode - Story begins after character is complete]"
    if placeholder in scene1:
        log(f"❌ Placeholder in Scene 1"); return False
    if len(scene1) < 100:
        log(f"❌ Scene 1 too short ({len(scene1)} chars)"); return False
    log("✅ PASS")
    return True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default=None)
    parser.add_argument("--user-id", default=None)
    args = parser.parse_args()

    global BASE_URL, USER_ID, CAMPAIGN_ID
    if args.base_url: BASE_URL = args.base_url
    if args.user_id: USER_ID = args.user_id

    log(f"Server: {BASE_URL}")
    log(f"User ID: {USER_ID}")

    provenance = evidence_utils.capture_provenance(BASE_URL)

    try:
        passed = test_campaign_creation()
        # CRITICAL: scenarios must include the live campaign_id, NOT a placeholder
        results = {
            "test_name": WORK_NAME,
            "scenarios": [
                {
                    "name": "campaign_creation",
                    "passed": passed,
                    "errors": [] if passed else ["acceptance failed"],
                    "campaign_id": CAMPAIGN_ID,    # threaded back from test_*()
                    "user_id": USER_ID,
                }
            ],
        }
        evidence_utils.create_evidence_bundle(
            EVIDENCE_DIR, test_name=WORK_NAME, provenance=provenance, results=results
        )
        log(f"Evidence bundle: {EVIDENCE_DIR}")
        sys.exit(0 if passed else 1)
    except Exception as e:
        log(f"❌ TEST ERROR: {e}"); import traceback; traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    main()
```

**Run:**
```bash
cd ~/projects/worldarchitect.ai && \
  TESTING_AUTH_BYPASS=true ALLOW_TEST_AUTH_BYPASS=true \
  bash local.sh --no-log-stream --force-default-port > /tmp/wa_server.log 2>&1 &
sleep 30 && curl -fsS -m 5 "http://127.0.0.1:8081/api/constants/models" | head -c 100 && echo && \
  TESTING_AUTH_BYPASS=true ./vpython testing_mcp/test_wa_campaign_astarion_v2_creation.py
```

## What to commit

- The script: `testing_mcp/test_<topic>.py` (the proof itself).
- The PR body should link to the script's output as the "real-server proof" section.
- Optional: capture the full output to `/tmp/<topic>_evidence/test_<topic>.log` for the PR's evidence bundle.

## Related skills

- **`wa-model-registry-change`** — uses this skill for the 6-layer proof after applying the 8-place model registration pattern.
- **`finish-the-job`** — the umbrella that drives the PR to green with this evidence.
- **`drive-pr-to-green`** — for iterating on CI/CR feedback after opening the PR.
