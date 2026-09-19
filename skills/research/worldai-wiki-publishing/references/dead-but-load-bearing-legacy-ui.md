# Dead-but-load-bearing legacy UI patterns

Authored 2026-08-05 after Jeffrey asked "the campaign creation flow i think has two copies" (Slack thread C0AUXSVFSA2). Updated 2026-08-05 after the deeper "submit delegation" cousin was discovered. Applies any time an agent finds two UI implementations of the same flow and assumes one is safe to delete.

## The trap (the surface form)

The V1 frontend (`mvp_site/frontend_v1/`) contains both:

1. A **static legacy form** in `index.html:165-200`:
   ```html
   <div id="new-campaign-view" class="container mt-4">
     <h2 class="text-center">Start a New Campaign</h2>
     <form id="new-campaign-form" class="mt-3">
       <input id="campaign-title" value="My Epic Adventure" />
       <input id="character-input" placeholder="Random character (auto-generate)" />
       <input id="setting-input" />
       ...
     </form>
   </div>
   ```

2. A **dynamically-injected wizard** in `js/campaign-wizard.js` (`generateWizardHTML()`):
   ```javascript
   const wizardHTML = this.generateWizardHTML();
   originalForm.insertAdjacentHTML('afterend', wizardHTML);
   // Wizard uses IDs like #wizard-campaign-title, #wizard-description-input
   ```

An agent that grep-references the form (`<form id="new-campaign-form">`) and the wizard (`<div id="campaign-wizard">`) might conclude "two copies of the same UI — delete the legacy one." That's the wrong call.

## Why the legacy form is NOT safe to delete (prefill migration — the surface reason)

The wizard explicitly hides the form (`originalForm.style.display = 'none'` at `campaign-wizard.js:645`) but **still reads from it** for prefill migration:

```javascript
populateFromOriginalForm() {
  const originalForm = document.getElementById('new-campaign-form');
  if (!originalForm) return;

  const titleInput = originalForm.querySelector('#campaign-title');
  const promptInput = originalForm.querySelector('#campaign-prompt');
  const companionsInput = originalForm.querySelector('#generate-companions');

  if (titleInput?.value) {
    document.getElementById('wizard-campaign-title').value = titleInput.value;
  }
  // ...
}
```

This handles the rare path where a user types into the legacy form before the wizard bootstraps (slow page load, manual URL paste, etc.) and then clicks something that triggers `enableCampaignWizard()`. The wizard's `populateFromOriginalForm()` copies the typed values into the wizard inputs before showing the wizard.

The pattern is: **the legacy UI is hidden but the wizard still reads from it.** Deleting the legacy form silently breaks prefill migration.

## Why the legacy form is STILL not safe to delete (submit delegation — the deeper reason)

Even after the prefill concern is acknowledged, the legacy form is ALSO the actual submission mechanism. `campaign-wizard.js:launchCampaign()` (line 1684) calls `populateOriginalForm()` to copy wizard values into the hidden form fields, then dispatches `originalForm.dispatchEvent(new Event('submit'))` (line 1712). The real POST happens in `app.js:3742-3920` (the legacy `submit` handler), NOT in the wizard.

This is documented as a known bug in `docs/user-stories-ui/reviews/FIX_STATUS.md`:

> `attemptLaunch()` (line 1531) sets `setLaunchButtonsDisabled(true)` (line 1540), then calls `this.launchCampaign()` (line 1543).
> `launchCampaign()` (line 1706) calls `showDetailedSpinner()` ... and then just does `originalForm.dispatchEvent(new Event("submit"))` (line 1734) — it returns `undefined`, not a Promise.
> Back in `attemptLaunch`, the check `if (launchResult && typeof launchResult.then === 'function')` (line 1544) is therefore always false, so `attemptLaunch`'s own `.catch()` → `resetLaunchState()` path (lines 1545-1548) never fires for the real (async) failure.

The pattern is: **the modern UI dispatches DOM events on the legacy element; the legacy handler is the actual executor.** Deleting the legacy form breaks campaign launch end-to-end.

## 5-check diagnostic (use before any "delete this legacy UI" PR)

When you suspect a UI duplication, run these checks before drafting a delete PR:

```
1. Grep for every reader of the legacy UI:
   rg "getElementById\('new-campaign-form'\)|querySelector\('#campaign-title'" mvp_site/frontend_v1/js/
   # If the wizard (or any JS) still reads from the legacy IDs, the form is load-bearing

2. Check the hide mechanism:
   rg "style\.display\s*=\s*['\"]none['\"]" mvp_site/frontend_v1/js/
   # A `display:none` doesn't mean "deleted" — it means "hidden but in the DOM"

3. Check the wizard's lifecycle:
   rg "restoreOriginalForm|removeChild.*wizard|insertAdjacentHTML.*wizard" mvp_site/frontend_v1/js/
   # If there's a `restoreOriginalForm()` that unhides the legacy form, the legacy UI
   # is round-trippable and definitely load-bearing

4. Verify the prefill migration path:
   rg "populateFromOriginalForm|originalForm\.querySelector" mvp_site/frontend_v1/js/
   # This is the smoking gun — wizard reads legacy values to seed itself

5. Verify whether the modern UI dispatches DOM events on the legacy element:
   rg "originalForm\.dispatchEvent|legacyForm\.dispatchEvent|<legacy-id>\.dispatchEvent" mvp_site/frontend_v1/js/
   # If the wizard does `originalForm.dispatchEvent(new Event('submit'))`, the legacy
   # form's submit handler in app.js IS the actual executor — you cannot delete the legacy
   # form without rewriting BOTH submission AND error-handling paths in the wizard
```

Only after all 5 checks confirm the legacy UI has zero live readers AND zero migration paths AND zero delegated event handlers should you draft a "delete legacy UI" PR.

## Safe subset (verified 2026-08-05 for the HotD wiki PR)

If ONLY check #1-4 hit (prefill-only — legacy form is hidden, no events delegated), a 2-option PR scope applies:

- **Option A (small, ~30 lines):** Delete the legacy `<form id="new-campaign-form">` markup from `index.html` AND no-op `populateFromOriginalForm()` (return early before reading). Breaks the rare prefill path; saves ~30 lines + the dead markup in the bundle.

- **Option B (safer, ~150 lines):** Option A + add a Playwright test asserting the wizard loads correctly on a fresh `/new-campaign` route with no legacy form prefill. Test stands in for the legacy migration path; gives CI a regression guard.

## Full refactor (when check #5 ALSO hits — the real "delete legacy form" scope)

If the wizard dispatches events on the legacy form (the deeper cousin — applies to most real-world refactors of legacy UI), Option A/B above are NOT sufficient. A clean delete requires:

1. Refactor `launchCampaign()` to POST directly via `fetch('/api/campaigns', {...})` instead of `originalForm.dispatchEvent(new Event('submit'))`.
2. Move the legacy `app.js:3742-3920` submit-handler logic (POST + error handling + retry `confirm()`) into the wizard's `launchCampaign()`.
3. Wire `attemptLaunch()`'s `.catch()` so it actually fires (the current `if (launchResult && typeof launchResult.then === 'function')` check returns false because `dispatchEvent` returns `undefined`).
4. Update 3+ test files: `mvp_site/frontend_v1/tests/campaign_wizard_dragon_knight_submit.test.js`, `campaign_wizard_default_order.test.js`, `tests/campaign_wizard_mobile_scroll_harness.py`, plus any `testing_ui/` browser selector that targets `#new-campaign-form` (e.g. `test_smoke_theme_common.py:1028`, `byok_browser_base.py:2063`, `realistic/agent_pool/runner.py:343`).

**Estimated diff:** ~200 lines deleted, ~120 lines added, 3-5 test files updated. Verified pattern from 2026-08-05 wizard-remove-legacy-form scope. **Side benefit:** this refactor fixes the known bug in `docs/user-stories-ui/reviews/FIX_STATUS.md` (`attemptLaunch`'s dead `.catch()` path).

## What NOT to do

- Don't delete the legacy form **without** also no-op'ing `populateFromOriginalForm()` — otherwise every wizard.enable() call throws `Cannot read properties of null (reading 'querySelector')`.
- Don't delete `populateFromOriginalForm()` **without** removing the legacy form markup — otherwise the function silently no-ops and the prefill path dies without any signal.
- Don't delete the legacy form (or its submit handler) **without** refactoring `launchCampaign()` to POST directly — otherwise `dispatchEvent('submit')` fires into the void and campaign launch silently fails.
- Don't keep the legacy markup just to be "safe" — it's still in the bundle (~3KB) and bloats the HTML parse for every page load.
- Don't grep `<form>` and conclude duplication — grep the JS readers AND the event dispatchers, or you'll ship a regression.

## Pattern recognition for future agents

Same pattern exists for other "hidden but read" or "hidden but delegated" legacy UI in the WorldArchitect.AI codebase. When you see:

- Two visible UIs for the same flow (form + injected component, static + dynamic, vanilla + React)
- One of them has `display: none` set in JS
- The visible one reads from the hidden one's DOM IDs OR dispatches events on the hidden one

…that's a dead-but-load-bearing pattern, NOT a safe delete. The skill `worldai-wiki-publishing` Pitfall #18 + #19 (added 2026-08-05) point at this reference for the diagnostic procedure.