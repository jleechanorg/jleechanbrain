# Worked example: worldarchitect.ai #9116 (campaign 0P8IwPXOpW79z3yy6XDc)

Verified 2026-08-19 on `jleechanorg/worldarchitect.ai`. Issue filed via `/repro` workflow (Gate 1 = `gh-safe-publish issue create` → #9116; Gate 2 = `br create` → `rev-e4pek`). No live LLM turn required — static-evidence gate satisfied.

## Symptom

User pasted a screenshot from `https://mvp-site-app-dev-i6xf2p72ka-uc.a.run.app/game/0P8IwPXOpW79z3yy6XDc` showing the game-page header with two simultaneous edit dialogs side-by-side:

- Yellow-bordered input (active): `...e warcraft 3 (failed req no planning b|)` (cursor at end)
- Purple-bordered input (stale): `nocturne warcraft 3`
- Each with its own ✓ / ✗ button pair

User reported: "sometimes edit campaign title shows two edit dialogs".

## Root cause

`mvp_site/frontend_v1/app.js:3947` (game-page `resumeCampaign()`) instantiates a new `InlineEditor(gameTitleElement, ...)` without:

1. Checking whether `gameTitleElement._inlineEditor` is already set
2. Calling `destroy()` on the prior instance

`mvp_site/frontend_v1/js/inline-editor.js:46` (`init()`) unconditionally attaches a `click` listener:

```js
init() {
  this.element.classList.add('inline-editable');
  this.element.addEventListener('click', this.boundStartEdit);
  this.element.addEventListener('mouseenter', this.boundHandleMouseEnter);
  this.element.addEventListener('mouseleave', this.boundHandleMouseLeave);
}
```

`InlineEditor` does have a working `destroy()` method (`inline-editor.js:310-320`), it's just never called by `resumeCampaign()`.

## Why "sometimes"

`resumeCampaign()` is called from 3 places:

- `mvp_site/frontend_v1/app.js:1419` — initial / retry path
- `mvp_site/frontend_v1/app.js:4072` — error retry path
- `mvp_site/frontend_v1/app.js:5823` — `handleRouteChange()` re-entry (back-navigation from dashboard)

Fresh page load → 1 invocation → 1 listener → 1 dialog. Dashboard → game-page round-trip → 2 invocations on same `#game-title` → 2 listeners → 2 dialogs visible.

## Compare-correct-pattern (dashboard)

The dashboard path at `mvp_site/frontend_v1/app.js:3673-3697` correctly tracks the instance per element:

```js
const editor = new InlineEditor(titleEl, {
  maxLength: 100,
  minLength: 1,
  placeholder: "Enter campaign title...",
  saveFn: async (newTitle) => { /* PATCH */ },
  onError: (error) => { ... },
});
titleEl._inlineEditor = editor;  // ← tracks the instance per element
```

The game-page path at line 3947 is missing both the track step and the destroy-on-replace step. Side-by-side comparison is the diagnostic signal.

## Fix shape (recommended, not yet shipped)

1. `inline-editor.js` — add `InlineEditor.attachOrReplace(element, opts)` static helper that calls `destroy()` on any prior `element._inlineEditor` before instantiating a new one.
2. `app.js:3942-3964` — switch to the helper.
3. Add `tests/test_game_title_editor_no_duplicate.test.js` — vm-sandbox test: instantiate twice, assert `querySelectorAll('.inline-edit-container').length === 1` AND only one click listener on the element.
4. Add UI test: dashboard → game round-trip → click → screenshot → assert one dialog.

## Files involved

- `mvp_site/frontend_v1/js/inline-editor.js` — widget class (lines 12-321)
- `mvp_site/frontend_v1/app.js:3942-3964` — unguarded instantiation site (game-page path)
- `mvp_site/frontend_v1/app.js:3673-3697` — correct guarded pattern (dashboard, for comparison)
- `mvp_site/frontend_v1/app.js:1419, 4072, 5823` — re-runnable call sites
- `mvp_site/frontend_v1/index.html:305` — `<h2 id="game-title">` target element
- `mvp_site/frontend_v1/css/inline-editor.css` — `.inline-edit-container`, `.inline-edit-input`, `.inline-edit-buttons` styles

## Sibling signal

Sibling repro on same campaign_id (`0P8IwPXOpW79z3yy6XDc`): #9114 (PR #9045 dice/code_execution prompt). 2nd repro on this campaign. NOT a 3-sibling cluster trigger yet — the cluster-signal rule applies to canonical-state-anchor bugs, not to DOM-lifecycle bugs (per `references/static-evidence-sufficient-no-live-turn.md` cluster math).