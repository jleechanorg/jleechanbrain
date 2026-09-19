# Server-Generated System Warnings Banner — Noise Suppression

## When to use this reference

A user reports a user-visible **System Warnings** banner on the WorldAI player
page and asks to remove one specific entry (e.g. *"This should not be a system
warning, remove the warning"*). The warning text is server-generated — NOT
LLM-emitted — and the bug class is **noise suppression**, not directive scope.

If the user is instead reporting *"the LLM ignored my directive / keeps doing
forbidden X"*, go back to the parent `wa-directive-scope-factor-i-diag` skill —
that is the right class.

## What the warning actually is

The yellow "System Warnings" box on the player page is rendered by
`mvp_site/frontend_v1/app.js` (around line 1735) from
`fullData.debug_info._server_system_warnings[]`. That array is populated by
`_append_server_warning(structured_response, "<warning text>")` calls inside
`mvp_site/llm_service.py`. The render path filters for debug mode in some places
but always renders in god-mode responses.

## Diagnostic recipe (60-second check)

```bash
# 1. Find the warning source — grep the literal text the user reported
rg "<warning text>" mvp_site/ -l

# 2. Confirm it is _append_server_warning, not raw text in the prompt
rg "_append_server_warning.*<warning text>" mvp_site/llm_service.py

# 3. Check for any data-fix / merge logic at the same call site that MUST stay
#    (e.g. setattr(structured_response, FIELD_GOD_MODE_RESPONSE, merged) — that
#    move IS the fix; removing it would silently drop LLM content)
```

## Fix shape (surgical, three rules)

1. **Remove ONLY the `_append_server_warning(...)` call** that pushes the
   user-visible text. Do not touch the data-fix / merge logic that runs
   immediately before or after — that is what makes the warning accurate.
2. **Keep the `logging_util.warning(...)` line** (server-side log via Cloud
   Logging) — operators still want to see the correction in telemetry, just not
   in the player UI.
3. **Invert the test assertion** that asserts the warning IS in
   `_server_system_warnings`. The merge result assertion stays the same — the
   data preservation contract is unchanged, only the user-visible channel is
   silenced.

## Scope discipline (do NOT expand)

- Do not touch other `_append_server_warning(...)` call sites in
  `mvp_site/llm_service.py` — they push different warnings (dice-integrity,
  planning-block fallback, schema-gate, etc.) that are unrelated.
- Do not touch frontend `app.js` `serverWarnings.forEach(...)` rendering.
- Do not touch `_merge_server_system_warnings_for_streaming_persistence` in
  `mvp_site/llm_parser.py` — streaming persistence must continue.
- Do not introduce a new env flag or config setting. This is unconditional.
- Do not touch `narrative_response_schema.py` schema-validation warnings —
  those are a different render path.

## Worked example — `GOD_MODE_CORRECTION` (2026-08-19, user Slack 2026-08-19)

**Symptom (player page, nocturne warcraft 3):** yellow box showing
*"GOD_MODE_CORRECTION: cleared non-empty narrative field; GodMode output belongs
in god_mode_response."*

**Source:** `mvp_site/llm_service.py::_correct_god_mode_narrative_field(...)`,
lines ~1954-2000. Inside, after silently redirecting LLM `narrative` content
into `god_mode_response` (the defensive merge — MUST stay), the function
called:

```python
_append_server_warning(
    structured_response,
    "GOD_MODE_CORRECTION: cleared non-empty narrative field; "
    "GodMode output belongs in god_mode_response.",
)
```

That is the only thing to remove. The lines just above (the
`setattr(structured_response, FIELD_GOD_MODE_RESPONSE, merged)` + `structured_response.narrative = ""`)
are the actual data-fix and must remain.

**Test to invert:** `mvp_site/tests/test_llm_service_context.py::test_god_mode_narrative_correction_*`
(the one that asserts `"GOD_MODE_CORRECTION" in _server_system_warnings`).
Replace with assertion that the merge result
(`structured.god_mode_response == "<expected merged text>"`) is unchanged AND
`"GOD_MODE_CORRECTION"` is NOT in `_server_system_warnings`.

**Worktree pattern:** `git worktree add -b fix/<slug> origin/main` (clean
branch), `claudem -p "<brief>" --max-turns 120`, local commit only, do not push
— user reviews PRs before merge.

## Pitfalls

- **Don't load `wa-directive-scope-factor-i-diag` for this class.** The user
  complaint is "remove the noisy banner," not "the LLM ignored my directive."
  Different mechanism entirely.
- **Don't remove the merge logic.** The warning is *describing* a correction
  that already happened. Removing the warning silences the announcement; removing
  the merge silently drops LLM content — data loss.
- **Don't add a config flag.** The user wants this gone unconditionally. A flag
  adds config drift and a future audit failure.
- **Don't run the full test suite locally.** Per `mvp_site/CLAUDE.md`, run only
  the touched test file: `./run_tests.sh mvp_site/tests/test_llm_service_context.py`.

## Cross-references

- Parent skill: `~/.smartclaw/skills/worldarchitect/wa-directive-scope-factor-i-diag/SKILL.md`
- Render site: `mvp_site/frontend_v1/app.js` around line 1735
  (`serverWarnings.forEach` push into `mergedSystemWarnings`).
- Call-site inventory (do not blanket-remove): `mvp_site/llm_service.py` lines
  1990, 3030, 6245, 6328, 8441.
- Streaming mirror: `mvp_site/llm_parser.py::_merge_server_system_warnings_for_streaming_persistence`
  (around line 639) — DO NOT touch.
