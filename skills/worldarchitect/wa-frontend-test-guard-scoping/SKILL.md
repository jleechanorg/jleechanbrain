---
name: wa-frontend-test-guard-scoping
version: 1.0.0
description: "Scope substring test guards to the element they protect."
author: Hermes Agent
license: MIT
tags: [wa, frontend, test, ci, false-positive, regex-scoping]
related_skills: [drive-pr-to-green, wa-visual-proof-playwright, qa-test-failure-dismissal-anti-pattern]
metadata:
  hermes:
    tags: [wa, frontend, test, ci, false-positive, regex-scoping]
    triggers:
      - "test fails after adding a sibling button type=button"
      - "substring guard falsely trips on chevron"
      - "C3 choice buttons carry no markup that would suppress submission"
---

# WA frontend test-guard scoping

## The recurring trap

WA frontend tests in `mvp_site/frontend_v1/tests/` and `testing_mcp/` use substring guards to lock in rendered-HTML invariants:

```js
assert.ok(!html.includes('type="button"'), "an explicit type=button would change form-submission semantics");
assert.ok(!html.includes('class="composer-card"'), "...");  // similar pattern
assert.ok(!html.includes('disabled='), "...");  // similar pattern
```

These work until a UI refactor adds a **sibling element** that legitimately needs the previously-banned attribute:

- A `<button type="button" class="chev-btn">` for chevron pros/cons disclosure, sitting next to the form's `<button class="choice-button">` (the actual submit button the guard was protecting).
- A `<button type="button" class="icon-btn">` for a side action, sitting next to the form's primary submit.
- An `<input type="reset">` for a "Clear" button, sitting next to a save-form's submit.

The substring guard trips because the *attribute* is now present — but the guard's **intent** (the submit button must not suppress submission) is still satisfied. The new sibling element legitimately needs the attribute; the guard was protecting a *different element*.

## The anti-pattern: rewrite the assertion

The first instinct is to rewrite the assertion:

```js
// WRONG — destroys the guard
assert.ok(!html.includes('type="button"') || html.includes('data-disclosure="true"'),
  "type=button is allowed on disclosure elements only");
```

This is fragile: every new sibling element that needs `type="button"` adds another exception clause. Eventually the guard is meaningless.

## The right fix: scope the regex to the protected element

```js
// RIGHT — scope to the element the guard protects
const choiceButtonMatches = html.match(
  /<button[^>]*class="[^"]*choice-button[^"]*"[^>]*>/g,
) || [];
assert.ok(choiceButtonMatches.length > 0, "interactiveOnly must emit at least one choice-button");
for (const tag of choiceButtonMatches) {
  assert.ok(
    !/\s+type="(submit|button|reset)"/.test(tag),
    `choice-button must not suppress submission (saw type= in: ${tag})`,
  );
}
```

The regex `<button[^>]*class="[^"]*choice-button[^"]*"[^>]*>` matches only `<button>` elements whose `class` attribute includes `choice-button`. Any sibling `<button>` (chev-btn, icon-btn, etc.) is excluded. The guard's intent (the submit button must not suppress submission) is preserved verbatim; the false-positive on the sibling element is gone.

## When to use this fix vs. restructure the renderer

Two paths diverge:

| Approach | When to pick |
|---|---|
| **Scope the test regex (this skill)** | The new sibling element legitimately needs the attribute. The test's stated intent (protect a specific element from suppressing submission) is correct; only the *scope* of the assertion was too broad. |
| **Restructure the renderer** | The new sibling element SHOULDN'T need the attribute (e.g. it should be a `<span>` with a click handler that calls `preventDefault()` instead of a `<button type="button">`). Restructure when the sibling element is *wrong*, not when the test is wrong. |

For PR #8997 the path was clear: chev-btn legitimately needs `type="button"` because it expands pros/cons without submitting the form. Removing `type="button"` from the chevron would cause form-submission on chevron click — a real bug. So the test was wrong (over-scoped), not the renderer.

## Verification (mandatory before pushing)

Run the failing test locally to confirm both that the new scoping fixes the false-positive AND that the guard's intent is preserved:

```bash
# Local repro
node --test mvp_site/frontend_v1/tests/<file>.test.js
# Confirm: <N> passed, 0 failed
```

Then push, re-run CI, confirm the gate flips to SUCCESS on the new head SHA:

```bash
gh pr checks <N> --json name,state --jq '.[] | select(.name | contains("<gate>")) | "\(.name) \(.state)"'
```

If the gate is still red, the scope was too narrow (you accidentally narrowed it past the protected element) or the renderer genuinely needs the restructure path.

## Pair-with-comment rule

Every test-guard scoping fix MUST include a comment in the test body explaining:

1. **What element the guard scopes to** (the regex pattern, in prose).
2. **Why siblings are excluded** (what legitimate need they have for the attribute).

Example comment block:

```js
// The composer moves choices into the input form, so the choice-button
// itself MUST submit on click (the existing handleChoiceClick wires this
// via the form's submit event). An explicit type="button" on the
// choice-button would silently suppress submission. The chev-btn sibling
// legitimately needs type="button" (it expands pros/cons without
// submitting); that lives OUTSIDE the choice-button tag, so this
// assertion scopes the guard to the choice-button element only.
```

Without the comment, the next agent (or LLM) re-loosening the guard to fix a future false-positive is the expected failure mode.

## Pitfall: don't pair this with same-test-name dismissal

Per `qa-test-failure-dismissal-anti-pattern`, a "pre-existing on main" dismissal requires FOUR same-name checks. If the test was green before this PR and is failing because this PR added the sibling element, the failure IS this PR's regression — not pre-existing. Apply the scope-the-regex fix, not a dismissal.

## Provenance

Verified on PR #8997 (commit `0312e5b61e ui(composer): restyle action bar and choice disclosure (E1a)` introduced chevron; CI test `C3: choice buttons carry no markup that would suppress submission` started failing on substring match against the new chev-btn). Fix landed as commit `5bab3e478d claudem/minimax-M3: fix(test): scope C3 form-submission guard to choice-button only`. Local verify: 11/11 pass in `node --test mvp_site/frontend_v1/tests/planning_choices_composer.test.js`. For the full diagnosis walkthrough (raw log lines, exact regex applied, post-fix local + remote verification, multi-agent divergence during babysit), see `references/pr-8997-c3-fix.md`.
