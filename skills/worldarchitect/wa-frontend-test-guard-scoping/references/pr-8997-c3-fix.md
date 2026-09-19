# PR #8997 — C3 test guard scoping walkthrough

## The PR

`jleechanorg/worldarchitect.ai#8997` — `fix(mobile): wrap composer Send below dock + cap choices height on phones`

Branch: `fix/mobile-composer-send-wrap`
Worktree: `${HOME}/projects/worktree_ui_planningb`
Final head (after the fix + 5 follow-up commits by other agents): `6be07699aa`

## The bug class

A UI refactor (commit `0312e5b61e ui(composer): restyle action bar and choice disclosure (E1a)`) introduced a sibling `<button type="button" class="chev-btn">` next to each composer `choice-button`. The chevron legitimately needs `type="button"` to expand pros/cons without submitting the form. The existing test `C3: choice buttons carry no markup that would suppress submission` was a substring check on the entire HTML output:

```js
assert.ok(
  !html.includes('type="button"'),
  "an explicit type=button would change form-submission semantics",
);
```

The substring check now falsely tripped on the chevron. The test's *intent* (the choice-button itself must not suppress submission) was still satisfied; only the *scope* of the assertion was too broad.

## The diagnosis path

1. `gh pr checks 8997 --json name,state` — showed `Planning Choices Composer Placement` FAILURE
2. `gh run view <run-id> --job <job-id> --log-failed` — showed:
   ```
   # FAIL  C3: choice buttons carry no markup that would suppress submission
   #         an explicit type=button would change form-submission semantics
   ```
3. Local repro: `node --test mvp_site/frontend_v1/tests/planning_choices_composer.test.js` — same 10/11 pass, 1 fail (C3)
4. Source inspection: `mvp_site/frontend_v1/app.js:2824` and `2829` — confirmed the new `<button type="button" class="chev-btn">` is emitted by the `interactiveOnly` path of `parsePlanningBlocks`
5. Decision: scope the test (not the renderer) — the chevron legitimately needs `type="button"`; removing it would cause form-submission on chevron click (real bug)

## The fix

```js
test("C3: choice buttons carry no markup that would suppress submission", () => {
  // The composer moves choices into the input form, so the choice-button
  // itself MUST submit on click (the existing handleChoiceClick wires this
  // via the form's submit event). An explicit type="button" on the
  // choice-button would silently suppress submission. The chev-btn sibling
  // legitimately needs type="button" (it expands pros/cons without
  // submitting); that lives OUTSIDE the choice-button tag, so this
  // assertion scopes the guard to the choice-button element only.
  const html = parsePlanningBlocks(PLANNING_BLOCK, { interactiveOnly: true });
  const choiceButtonMatches = html.match(
    /<button[^>]*class="[^"]*choice-button[^"]*"[^>]*>/g,
  ) || [];
  assert.ok(
    choiceButtonMatches.length > 0,
    "interactiveOnly must emit at least one choice-button element",
  );
  for (const tag of choiceButtonMatches) {
    assert.ok(
      !/\s+type="(submit|button|reset)"/.test(tag),
      `choice-button must not suppress submission (saw type= in: ${tag})`,
    );
  }
  assert.ok(html.includes('data-action-behavior="submit"'), "submit behavior must survive");
});
```

## Verification

Local:
```bash
$ node --test mvp_site/frontend_v1/tests/planning_choices_composer.test.js
# ...
# 11 passed, 0 failed
```

Remote (after push of `5bab3e478d`):
```bash
$ gh pr checks 8997 --json name,state --jq '.[] | select(.name | contains("Planning")) | "\(.name) \(.state)"'
"Planning Choices Composer Placement SUCCESS"
```

## Commits

- `5a7bd7b2d5` — evidence commit (PNG before/after captures, unrelated to the fix)
- `5bab3e478d` — `claudem/minimax-M3: fix(test): scope C3 form-submission guard to choice-button only` (the fix)

## Postscript — divergence during the babysit loop

Between the first and second reply, 5 commits landed on the branch by other agents (Gemini + Claude Opus + a Gemini re-capture of the AFTER PNGs). PR head moved `5bab3e478d → 6be07699aa`. This is a recurring multi-agent phenomenon — see `pr-evidence-inbound-review` Pitfall 7 (verified same case) and the new "recurring divergence check" pitfall in `drive-pr-to-green` for the mitigation recipe.

## References

- `mvp_site/frontend_v1/tests/planning_choices_composer.test.js:229` — the test, post-fix
- `mvp_site/frontend_v1/app.js:2824-2830` — the chevron emission in `interactiveOnly` path
- `qa-test-failure-dismissal-anti-pattern` — the 4-check same-name dismissal rule that this fix did NOT use (the failure was a real regression, not a pre-existing flake)
