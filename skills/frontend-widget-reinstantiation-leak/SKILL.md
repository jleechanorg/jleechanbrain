---
name: frontend-widget-reinstantiation-leak
description: Listener leak when widget reinstantiated.
version: 1.0.0
author: hermes
license: MIT
metadata:
  hermes:
    tags: [frontend, bug-class, listener-leak, dom-lifecycle]
    related_skills: [repro]
---

# Frontend widget re-instantiation leak

## When to use

Trigger on any of: "shows two dialogs" / "shows N dialogs" / "clicking X opens multiple modals" / "popup appears twice" / "the editor appears twice" / "inline editor stacked" — when the symptom is intermittent and correlates with route change / page resume / retry.

Do NOT use for: "LLM forgot X" (use `/repro` Step 0.77 BQ diagnostic), "campaign state wrong" (use `/repro` + canonical-state-anchor workflow), "deploy failed" (use `wa-cloud-run-deploy-failure-debug`).

## Signal signature

User reports "sometimes editing X shows N dialogs" / "clicking X opens multiple modals" / "the popup appears twice". **Intermittent** — only manifests after the widget has been re-instantiated against the same DOM element.

Visible evidence: N stacked copies of the same widget (different border colors hint at different instance ages), each with its own state and lifecycle. Newest takes focus; older ones are visible artifacts because their `cancel()` / `completeEdit()` was never called.

## Root cause (generic)

Widget constructor does unconditional listener attach in `init()`:

```js
class InlineEditor {
  init() {
    this.element.classList.add('inline-editable');
    this.element.addEventListener('click', this.boundStartEdit);  // ← always attaches
    ...
  }
}
```

Instantiated in a re-runnable code path WITHOUT an idempotency guard:

```js
function resumeCampaign() {
  const el = document.getElementById("game-title");
  new InlineEditor(el, { ... });  // ← no destroy() of prior, no guard
}
```

Each invocation: another `click` listener attaches + another `widgetContainer` reference held invisible. On next click, **all** N listeners fire synchronously, each calls `startEdit()`, each inserts its own `.widget-container` next to `el`. N stacked widgets visible.

## Diagnostic recipe (3 steps, <2 min)

1. **Find the widget class.** `rg -n "class .*Editor|class .*Modal|class .*Picker|class .*Tooltip" mvp_site/frontend_v1/` — pick the one matching the symptom.
2. **Find every instantiation.** `rg -n "new <WidgetClass>" mvp_site/frontend_v1/ -g '*.js'`. For each, check whether it guards on `el._widgetInstance` AND calls `destroy()` on the prior one.
3. **Find the re-runnable call path.** Callers of the unguarded site are typically `handleRouteChange`, `resumeCampaign`, retry/poll/init. N invocations of this code path = N widgets visible.

The dashboard pattern is usually correct; the re-runnable path is usually broken. Compare them side-by-side to find the missing pieces.

## Fix shape (4-component, universal)

1. **Widget class** — add a static helper `WidgetClass.attachOrReplace(element, opts)` that calls `destroy()` on any prior `_widgetInstance` before instantiating a new one.
2. **Unguarded instantiation site** — switch to the helper. Add the guard pattern from the correct path (e.g. dashboard version).
3. **vm-sandbox unit test** — instantiate the widget twice against the same element, assert `querySelectorAll('.widget-container').length === 1` AND `getEventListeners(element).click.length === 1`.
4. **UI test** — simulate the user round-trip (navigate away → back → click → screenshot), assert exactly one widget visible.

## When NOT to use

- This is a **frontend DOM lifecycle** bug, not a campaign-state or LLM-emission bug. `/repro` off-ramps non-campaign-state bugs but the symptom overlap with "edit dialog" is real — verify it's DOM-leak before filing a campaign-state issue.
- If the symptom is "the LLM forgot X" or "a key in campaign A did X wrong", this skill doesn't apply. Use the `/repro` workflow + Step 0.77 BQ diagnostic.

## References

- `references/worked-example-worldarchitect-9116.md` — full reproduction on `jleechanorg/worldarchitect.ai` #9116 (campaign `0P8IwPXOpW79z3yy6XDc`): InlineEditor attached in `resumeCampaign()` leaks across `handleRouteChange()` round-trips.