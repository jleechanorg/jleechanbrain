---
name: wa-model-registry-change
version: 1.1.0
description: "Add/remove Gemini models in worldarchitect.ai settings."
tags: ["worldarchitect", "settings", "gemini", "model-registry", "code-execution", "agy"]
category: worldarchitect
triggers:
  - add model to settings
  - remove model from dropdown
  - register new gemini model
  - swap default llm
  - X is a code execution model
  - code_execution + json single-pass
  - add to ALLOWED_GEMINI_MODELS
  - update GEMINI_MODEL_MAPPING
  - update MODELS_WITH_CODE_EXECUTION
changelog:
  - "1.1.0 (2026-08-18): Added two class-level pitfalls from PR #9092: (1) HTML `<option selected>` is mandatory for visual default-marking — a label-only change does NOT make a model visually default, the user will reply 'also make it the default its currently not'. (2) `_DEFAULT_GEMINI_MODEL_FALLBACK` env-override pattern via `WORLDAI_DEFAULT_GEMINI_MODEL` and `_SUPPORTED_GEMINI_DEFAULT_OVERRIDES` frozenset — always grep the fallback on origin/main before assuming 'what is the production default'."
  - "1.0.0 (2026-08-13): Initial — verified on the gemini-3.5-flash → 3.6-flash + 3.6-flash-high swap (PR +7 files, +405/-13 LOC). Captures the 8-place registration pattern and the legacy-redirect storage policy."
related_skills:
  - testing-mcp-real-server-proof
  - finish-the-job
  - drive-pr-to-green
---

# WA Model Registry Change

**The recipe for changing which LLM models a user can select in the worldarchitect.ai settings dropdown.** A model entry isn't just one file — it's an 8-place registration. Skip a place and the dropdown breaks, the dice strategy degrades silently, the AGY CLI picks the wrong label, or a user with a stored setting gets bricked.

## When to use

- User says "add X to settings", "remove Y from the dropdown", "register the new model", "swap the default", "X is a code execution model", "X supports code_execution + JSON single-pass", or any change to `ALLOWED_GEMINI_MODELS`, `GEMINI_MODEL_MAPPING`, `MODELS_WITH_CODE_EXECUTION`.
- Adding a new model variant (e.g. `-high`, `-lite`, `-preview`).
- Removing a model that has been deprecated upstream.
- Re-classifying a model from native-two-phase dice to code-execution dice (or vice versa).

## The 8-place registration pattern

When you add/remove/rename a Gemini model, ALL of these places must change in lockstep. Verified 2026-08-13 on the `gemini-3.5-flash → 3.6-flash + 3.6-flash-high` swap (branch `feat/remove-3-5-flash-keep-3-6-flash-codes-exec`, 7 files, +405/-13 LOC).

### Place 1 — `mvp_site/constants.py` `ALLOWED_GEMINI_MODELS`

The canonical "which models may the user pick from the dropdown" list. The default model entry is always included implicitly (read from `DEFAULT_GEMINI_MODEL` separately).

```python
ALLOWED_GEMINI_MODELS = [
    DEFAULT_GEMINI_MODEL,  # always present (canonical default)
    "gemini-3-flash-preview",  # current default
    "gemini-3.6-flash",
    "gemini-3.6-flash-high",  # new variant
]
```

### Place 2 — `mvp_site/constants.py` `GEMINI_MODEL_MAPPING`

Maps user preference string → upstream SDK identifier. New models pass through to themselves; legacy models redirect to their replacement (so stored user settings don't break). See "Legacy-redirect storage policy" below.

```python
GEMINI_MODEL_MAPPING = {
    "gemini-3-flash-preview": "gemini-3-flash-preview",  # pass-through
    "gemini-3.6-flash": "gemini-3.6-flash",              # pass-through
    "gemini-3.6-flash-high": "gemini-3.6-flash-high",    # pass-through
    # Legacy auto-redirect (keep here even when removed from dropdown)
    "gemini-3.5-flash": "gemini-3.6-flash",              # removed, auto-redirected
}
```

### Place 3 — `mvp_site/constants.py` `MODELS_WITH_CODE_EXECUTION`

The allowlist for the single-pass `code_execution + JSON` dice strategy. Models NOT in this set use the legacy native two-phase dice path. Add a model here ONLY when you've verified end-to-end that the model's structured-JSON + code_execution call doesn't terminate with `TOO_MANY_TOOL_CALLS` before final JSON on real gameplay. Verified models (2026-08): `gemini-3-flash-preview`, `gemini-3.0-flash`, `gemini-3.6-flash`, `gemini-3.6-flash-high`. NOT verified (still native two-phase): `gemini-3.5-flash-lite` (terminates with TOO_MANY_TOOL_CALLS on real calls).

```python
MODELS_WITH_CODE_EXECUTION: set[str] = {
    "gemini-3-flash-preview",
    "gemini-3.0-flash",
    "gemini-3.6-flash",         # Jul 2026 — same single-pass contract as 3.x
    "gemini-3.6-flash-high",    # Aug 2026 — higher-throughput variant of 3.6
    # gemini-3.5-flash-lite NOT here — terminates with TOO_MANY_TOOL_CALLS
}
```

### Place 4 — `mvp_site/constants.py` `MODEL_CONTEXT_WINDOW_TOKENS` + `MODEL_MAX_OUTPUT_TOKENS`

Two dicts that gate prompt-budget decisions. New models MUST be in both — if a model is missing from `MODEL_CONTEXT_WINDOW_TOKENS`, the budget logic raises `KeyError` and the LLM call dies. Use the model's docs for the exact value (1M is the standard for Gemini 3.x family, 65K for output).

```python
MODEL_CONTEXT_WINDOW_TOKENS = {
    ...
    "gemini-3.6-flash":      1_000_000,
    "gemini-3.6-flash-high": 1_000_000,
}
MODEL_MAX_OUTPUT_TOKENS = {
    ...
    "gemini-3.6-flash":      65_536,
    "gemini-3.6-flash-high": 65_536,
}
```

### Place 5 — `mvp_site/templates/settings.html` `<option>` entries

The actual dropdown. Each `<option>` value must match a key in `GEMINI_MODEL_MAPPING`. To remove a model, delete the `<option>`. To add, append a new `<option>` BEFORE the legacy `gemini-2.0-flash` entry (UI ordering — newest first, legacy last).

```html
<select id="geminiModel" class="form-select" name="geminiModel">
    <option value="gemini-3-flash-preview">Gemini 3 Flash (default - best value)</option>
    <option value="gemini-3.6-flash">Gemini 3.6 Flash (better coding + token efficiency)</option>
    <option value="gemini-3.6-flash-high">Gemini 3.6 Flash High (high-throughput variant)</option>
    <option value="gemini-2.0-flash">Gemini 2.0 Flash (legacy)</option>
</select>
```

### Place 6 — `mvp_site/frontend_v1/js/settings.js` `GEMINI_MODEL_MAPPING` (client-side mirror)

Mirrors the backend mapping so the client can normalize legacy values to their current model name before submitting.

```js
const GEMINI_MODEL_MAPPING = {
  "gemini-3-flash-preview":   "gemini-3-flash-preview",
  "gemini-3.6-flash":         "gemini-3.6-flash",
  "gemini-3.6-flash-high":    "gemini-3.6-flash-high",
  "gemini-3.5-flash":         "gemini-3.6-flash",  // legacy redirect
};
```

### Place 7 — `mvp_site/llm_providers/agy_provider.py` `_AGY_MODEL_ALIASES`

The AGY CLI subprocess (cost-effective real-LLM runs since PR #7971) maps app SDK IDs to AGY's display labels. If the new model is supported by AGY (most Gemini variants are), add an entry; otherwise leave it out and AGY falls through to the Gemini SDK.

```python
_AGY_MODEL_ALIASES = {
    "gemini-3-flash-preview": "Gemini 3.5 Flash (High)",
    "gemini-3.5-flash-lite":  "Gemini 3.5 Flash (High)",
    "gemini-3.5-flash":       "Gemini 3.5 Flash (High)",
    "gemini-3.6-flash":       "Gemini 3.6 Flash (High)",
    "gemini-3.6-flash-high":  "Gemini 3.6 Flash (High)",  # new entry
    "gemini-3.6-pro":         "Gemini 3.6 Pro (High)",
}
```

### Place 8 — `mvp_site/tests/test_centralized_model_selection.py` (test split)

When you change the dice-strategy classification of a model (Place 3), the existing test class will assert the wrong strategy. Split it: keep native-two-phase models in the existing class, create a new class for code-execution models with `TESTING_USE_CODE_EXECUTION_STRATEGY=true`.

```python
class TestGemini36FlashCodeExecutionRegistration(unittest.TestCase):
    CODE_EXEC_MODELS = ("gemini-3.6-flash", "gemini-3.6-flash-high")

    def setUp(self):
        super().setUp()
        self.orig_force = os.environ.get("TESTING_USE_CODE_EXECUTION_STRATEGY")
        os.environ["TESTING_USE_CODE_EXECUTION_STRATEGY"] = "true"

    def tearDown(self):
        # restore (don't leak env var into other tests)
        ...

    def test_code_exec_models_in_mods_with_code_execution(self):
        for m in self.CODE_EXEC_MODELS:
            self.assertIn(m, constants.MODELS_WITH_CODE_EXECUTION)
            self.assertEqual(
                dice_strategy.get_dice_roll_strategy(m, constants.LLM_PROVIDER_GEMINI),
                dice_strategy.DICE_STRATEGY_CODE_EXECUTION,
            )
```

The "no mocks" real-server proof lives in `testing_mcp/` — see the `testing-mcp-real-server-proof` skill for the recipe.

## Legacy-redirect storage policy (CRITICAL — read before removing a model)

When a model is removed from the dropdown, **do NOT delete it from `GEMINI_MODEL_MAPPING`** — keep it as a redirect to the closest replacement. Reason: users may have the removed value persisted in Firestore from a prior session. The redirect happens at LLM-call time in `mvp_site/llm_service.py:4894`:

```python
# Check for legacy mapping
if user_preferred_model in constants.GEMINI_MODEL_MAPPING:
    user_preferred_model = constants.GEMINI_MODEL_MAPPING[user_preferred_model]
```

Storage policy: keep the literal stored value (no destructive migration on POST). The redirect is applied at LLM-call time. This means:
- POST `/api/settings {"gemini_model": "gemini-3.5-flash"}` → returns 200, stores literal `"gemini-3.5-flash"`.
- GET `/api/settings` → returns `gemini_model: "gemini-3.5-flash"` (the literal, not the redirect).
- Next LLM call → applies mapping, uses `gemini-3.6-flash`.

This is correct behavior. **Do not** test that POST+GET must return the redirect target — the storage layer preserves the original value by design. Test only that the redirect target exists in `GEMINI_MODEL_MAPPING`.

## Why "verify it's a code execution model" before adding to `MODELS_WITH_CODE_EXECUTION`

`MODELS_WITH_CODE_EXECUTION` is gated by empirical evidence: when the LLM is called with `tools=[{"code_execution": {}}]` + `response_mime_type="application/json"` + a structured prompt, does it return final JSON without exceeding the tool-call limit? If yes, add to the allowlist. If the model terminates with `TOO_MANY_TOOL_CALLS` before final JSON (the case for `gemini-3.5-flash-lite` in 2026-08 testing), leave it on native two-phase. A wrong classification silently degrades dice rolls to native two-phase OR causes dice calls to spin and fail.

When in doubt, leave the new model on native two-phase until you have real gameplay evidence. The cost of being wrong is high (silent dice degradation); the cost of being conservative is small (slightly higher latency for that model until you verify).

## Worktree + commit discipline

Per `.cursor/rules/pr-branch-from-main.mdc`: branch from `origin/main`, never from a dirty main checkout. Verify `git log --oneline origin/main..HEAD` shows only your intended commits before push.

Per `.cursor/rules/env-preferences.mdc`: commit subject prefix `claude/<model-id>:` or `claudem/minimax-M3:` (or your CLI's prefix). For claudem-routed work: `claudem/minimax-M3: feat(settings): ...`.

## Pitfalls

- **Skipping Place 4** (`MODEL_CONTEXT_WINDOW_TOKENS`). If the new model isn't in this dict, the budget check raises `KeyError` and the LLM call dies. Always add the new model to BOTH `MODEL_CONTEXT_WINDOW_TOKENS` AND `MODEL_MAX_OUTPUT_TOKENS`.
- **Skipping Place 7** (agy alias). If the new model isn't in `_AGY_MODEL_ALIASES`, AGY CLI subprocess falls through to the Gemini SDK (more expensive per-token). For models that AGY supports, always add the alias.
- **Deleting the legacy entry from `GEMINI_MODEL_MAPPING` when removing a model from the dropdown.** This bricks users with the value persisted in Firestore. Keep the legacy entry as a redirect to the closest replacement.
- **Adding to `MODELS_WITH_CODE_EXECUTION` based on Google's docs alone.** The "supports code execution" claim is necessary but not sufficient for the single-pass `code_execution + JSON` dice path. You need gameplay-level evidence that the model returns final JSON without TOO_MANY_TOOL_CALLS.
- **Forgetting to update the test class split** in `test_centralized_model_selection.py`. When you change a model's dice-strategy classification, the existing test class asserts the wrong strategy. Split into two classes with different `TESTING_USE_CODE_EXECUTION_STRATEGY` env-var settings.
- **Putting `DEFAULT_GEMINI_MODEL` in the dropdown HTML/JS as a hardcoded string**. It's read from a separate env var (`WORLDAI_DEFAULT_GEMINI_MODEL`, defaults to `gemini-3-flash-preview`) and may change. The dropdown shows the default model as a separate `<option>` but should not assume a specific value — use `DEFAULT_GEMINI_MODEL` from the constants module on the server side, and `DEFAULT_GEMINI_MODEL` constant on the client side.

## HTML `<option selected>` is mandatory for visual default-marking (verified 2026-08-18, PR #9092)

When the user says "switch the default model back to X" or "make X the default", there are TWO independent pieces:

1. **Backend default** — `_DEFAULT_GEMINI_MODEL_FALLBACK` in `mvp_site/constants.py` (already canonical: `gemini-3-flash-preview` as of PR #8974). Sets `DEFAULT_GEMINI_MODEL` via the env-override indirection.
2. **HTML `<option selected>`** — the dropdown entry that the browser pre-selects before JS hydrates.

A label-only change (e.g. "best value" → "best speed/quality tradeoff") does NOT make a model visually default. If the entry lacks `selected`, the browser shows the **first listed `<option>`** as default — typically `gemini-3.7-flash` or whichever appears first in the source — even though the backend default is `gemini-3-flash-preview`. The user will reply "also make it the default its currently not" because the UI lies about the canonical default.

**Recipe when "make X the default" includes a label or wording change**:

```html
- <option value="gemini-3-flash-preview">Gemini 3 Flash (default - best value)</option>
+ <option value="gemini-3-flash-preview" selected>Gemini 3 Flash (default - best speed/quality tradeoff)</option>
```

**Regression test (add to `mvp_site/tests/test_settings_template.py`)**:

```python
def test_gemini_3_flash_preview_is_marked_selected_in_dropdown():
    template = Path("mvp_site/templates/settings.html").read_text(encoding="utf-8")
    assert '<option value="gemini-3-flash-preview" selected>' in template, (
        "settings.html must mark the default model with `selected` so the dropdown "
        "visually matches DEFAULT_GEMINI_MODEL — otherwise users see the first "
        "listed option as default and the UI lies."
    )
```

**Symptom**: user says "also make it the default its currently not" after a label-only PR. Fix is one word in one file; do not interpret it as a `constants.py` change.

## `_DEFAULT_GEMINI_MODEL_FALLBACK` env-override pattern (verified 2026-08-18, PR #9092)

`DEFAULT_GEMINI_MODEL` is computed from an env var, not hardcoded:

```python
_DEFAULT_GEMINI_MODEL_FALLBACK = "gemini-3-flash-preview"
_SUPPORTED_GEMINI_DEFAULT_OVERRIDES = frozenset({
    "gemini-3.7-flash", "gemini-3.6-flash",
    "gemini-3-flash-preview", "gemini-3.5-flash-lite",
})
_requested_default_gemini_model = os.getenv("WORLDAI_DEFAULT_GEMINI_MODEL")
DEFAULT_GEMINI_MODEL = (
    _requested_default_gemini_model
    if _requested_default_gemini_model in _SUPPORTED_GEMINI_DEFAULT_OVERRIDES
    else _DEFAULT_GEMINI_MODEL_FALLBACK
)
```

Implications when reasoning about "what is the production default":

- The fallback (`_DEFAULT_GEMINI_MODEL_FALLBACK`) is **always** what `DEFAULT_GEMINI_MODEL` resolves to in production unless `WORLDAI_DEFAULT_GEMINI_MODEL` is set in the launchd env or Cloud Run revision env vars.
- A previous PR that flipped the default (e.g. PR #8923 → `gemini-3.6-flash`) was reverted by PR #8974 and the fallback was restored to `gemini-3-flash-preview`. **Do not assume** the current default is what an old PR set — read `_DEFAULT_GEMINI_MODEL_FALLBACK` on `origin/main` first.
- A launcher exporting `WORLDAI_DEFAULT_GEMINI_MODEL=gemini-3.6-flash-high` (retired identifier) used to silently re-introduce 3.6-flash-high. The `_SUPPORTED_GEMINI_DEFAULT_OVERRIDES` frozenset is the safety net — keep retired identifiers OUT of this set.
- The JEFF-side convention is: **always** start a "make X the default" task by `grep -n "_DEFAULT_GEMINI_MODEL_FALLBACK\|_SUPPORTED_GEMINI_DEFAULT_OVERRIDES" mvp_site/constants.py` to confirm the canonical state before writing any PR.

## Recipe checklist (use for every model registry change)

```
□ Place 1: mvp_site/constants.py — ALLOWED_GEMINI_MODELS
□ Place 2: mvp_site/constants.py — GEMINI_MODEL_MAPPING (with legacy redirect if removing)
□ Place 3: mvp_site/constants.py — MODELS_WITH_CODE_EXECUTION (only if verified code-exec)
□ Place 4: mvp_site/constants.py — MODEL_CONTEXT_WINDOW_TOKENS + MODEL_MAX_OUTPUT_TOKENS
□ Place 5: mvp_site/templates/settings.html — <option> entry (newest first, legacy last)
□ Place 6: mvp_site/frontend_v1/js/settings.js — GEMINI_MODEL_MAPPING mirror
□ Place 7: mvp_site/llm_providers/agy_provider.py — _AGY_MODEL_ALIASES (if AGY supports)
□ Place 8: mvp_site/tests/test_centralized_model_selection.py — split class if dice strategy changed
□ mvp_site/tests/test_agy_provider.py — assert agy alias (if Place 7 added)
□ testing_mcp/test_<change>_registration.py — 6-layer real-server proof (no mocks)
□ Branch from origin/main, single commit, claudem/minimax-M3 prefix, push, gh pr create
□ PR body: 6 layers pass + legacy redirect proof + dice strategy assertion
```

## Related skills

- **`testing-mcp-real-server-proof`** — the 6-layer no-mocks verification pattern. Use AFTER applying the 8-place registration, BEFORE opening the PR.
- **`finish-the-job`** — the umbrella that drives the PR to green.
- **`drive-pr-to-green`** — for iterating on CI/CR feedback after opening the PR.
- **`gh-rate-limit-resilience`** — if `gh pr create` hits the dual-bucket or secondary rate-limit, schedule a one-time cron retry.
