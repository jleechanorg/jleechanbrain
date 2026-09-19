# Layer 3 — frontend render-time fallback (`app.js:2663-2668`)

Session-specific detail for `wa-planning-block-choice-contracts` SKILL.md. Captures the third layer that the original 2026-08-06 PR #8803 contract recipe missed: the frontend's own fallback button when the backend did not inject `custom_action`.

## Why this layer exists

The backend layers (1 = `llm_parser.py` injection, 2 = `world_logic.py` reorder) can both decide NOT to emit a `__custom_action__` choice in a given response:

- Layer 1 skips it when `_planning_block_owns_modal()` returns True (level-up / character-creation / god-mode active).
- Layer 2 reorders it but doesn't add it; if the data didn't include it, layer 2 won't either.

If neither layer emits `custom_action`, the user would see only LLM-supplied narrative choices with no freeform affordance. The frontend defends against this by ALWAYS appending a fallback `<button class="custom-action-button">` at the end of the rendered list, with `data-action-behavior="focus"` — clicking it just calls `userInputEl.focus()`, no submit.

## The contract invariants (verified 2026-08-16)

1. **The fallback button IS a label, not a peer choice.** `data-action-behavior="focus"` means the click handler returns after focusing the input (line 2408-2414). It never submits. Plan any UI treatment of this control accordingly — number it, and you mis-label it; hide it, and you remove a freeform escape hatch.

2. **`renderedCustomAction` flag must remain accurate.** Set true at line 2581-2583 when the backend already injected `custom_action` / `__custom_action__` into the choices list. The fallback at line 2661-2669 only emits if this flag is still false. This is the duplication gate — without it, modal flows would render two freeform affordances.

3. **The data contract is correct.** No changes needed to layer 1 or layer 2. The button is rendered FROM the set of choices, not as a separate concept. The C3 design (label-on-field) preserves this: the backend still emits a single `__custom_action__` choice, the frontend just renders it in a different location.

## Verified code shape (line 2663-2668, verbatim)

```js
html +=
  '<button class="choice-button risk-low custom-action-button" ' +
  'data-choice-id="__custom_action__" ' +
  'data-choice-text="" ' +
  'data-action-behavior="focus" ' +
  'data-switch-to-story="false" ' +
  'title="Type your own custom decision">Custom Action: decide whatever you want to do</button>';
```

## The C3 visual-relocation design (2026-08-16)

User explored three options for the custom_action treatment in a Slack design discussion:

- **C1**: separate row, numbered (peer choice). REJECTED: violates `_inject_custom_action` "always last" invariant and adds a 4th peer to a 3-choice modal.
- **C2**: collapse into the 3 numbered choices. REJECTED: hides freeform; breaks player agency.
- **C3**: keep the affordance but tie it to the input field as a label (dashed/italic + ↓ "type below" cue). ACCEPTED.

The C3 implementation lives in layer 3 only:
- Skip the fallback button at line 2661-2669 when `safeKey` is `custom_action` / `__custom_action__`.
- Render a separate `<label class="custom-action-hint">` next to the `<textarea id="user-input">` (index.html line 363).
- Wire label click → `userInputEl.focus()` (same one-liner as the button's `actionBehavior === "focus"` branch).

The `renderedCustomAction` flag still owns the suppression — if the backend already injected `custom_action`, the label-on-field is also suppressed, otherwise the user sees two freeform affordances.

## Test plan (to add when implementing C3)

Append to `mvp_site/tests/test_planning_block_choices_format.py` (or a new `test_planning_block_custom_action_render.py`):

```python
import pytest
from mvp_site.frontend_v1.app import _render_planning_block_choices  # adjust import

def test_custom_action_rendered_as_label_when_mm3_choice():
    """When the LLM emits exactly the canonical [a, b, c] peer set and the backend
    injects __custom_action__, the rendered HTML has ONE custom-action affordance
    (the label-on-field), not a fallback button + the label."""
    block = {
        "choices": [
            {"id": "a", "text": "A", "description": "do A"},
            {"id": "b", "text": "B", "description": "do B"},
            {"id": "c", "text": "C", "description": "do C"},
            {"id": "__custom_action__", "text": "Custom Action", "description": "..."},
        ],
    }
    html = _render_planning_block_choices(block)
    assert html.count('class="choice-button") == 3, "exactly 3 peer choices"
    assert 'class="custom-action-hint"' in html, "label-on-field rendered"
    assert 'data-choice-id="__custom_action__"' not in html, "no double-render"

def test_fallback_label_emitted_when_backend_skipped_injection():
    """When the backend emits no custom_action in the choices list, the rendered
    HTML still contains the label-on-field (the fallback's new home)."""
    block = {
        "choices": [
            {"id": "a", "text": "A", "description": "do A"},
            {"id": "b", "text": "B", "description": "do B"},
        ],
    }
    html = _render_planning_block_choices(block)
    assert 'class="custom-action-hint"' in html, "fallback label-on-field rendered"
```

## Reference

- Original layer 1+2 contract: `references/continue-story-and-4layer-contract.md` (PR #8803, 2026-08-06).
- Branch under design: `feat/planning-block-custom-action-presentation` (no PR yet as of 2026-08-16).
- Design discussion: Slack thread `C0AH3RY3DK6/p1786915509.965259` (2026-08-16, C3 option accepted).

---

# Cross-layer coordination rule (added 2026-08-19)

The previous sections describe layer 3 as a fallback for the custom-action affordance. The same coordination pattern applies to ANY layer-3 surface that interacts with another state dimension the user perceives as a single UI concept. The expanded rule:

> **Every layer-3 surface MUST coordinate with (a) layer 1's contract flag to suppress duplicates, (b) layer 2's modal-skip path to avoid corrupting modal flows, AND (c) any other layer-3 state surface that the user perceives as the SAME UI concept.**

Verified failure mode (2026-08-19, Slack C0BDEAJH8PK/p1787125293.103429): the composer has two layer-3 state surfaces that the user perceives as one:

| Layer-3 surface | What it toggles | Where |
|---|---|---|
| Peek-strip | Whole `.composer-choices` show/hide via `.is-collapsed` | `#composer-choices-peek` click → `setComposerChoicesCollapsed()` (`app.js:2572`) |
| Per-row chevron | Single `.choice-row` Pros/Cons expand via `.open` | `.chev-btn` click → `toggleChoiceDetail()` (`app.js:2414`) |

Neither surface coordinates with the other. Result: peek-strip copy says "Tap to collapse" while a row is in `.open` state; the `.composer-choices` `max-height: 148px; overflow-y: auto` mobile cap (`planning-blocks.css:621-627`) does not re-grow when one row inside grows taller (snap re-fires only on row-count changes via `ResizeObserver`, not on `.open` toggles). User sees: expanded detail overflows the scroll container, overlapping the Debug Info disclosure and input row above.

**Coordination checklist (use when designing or auditing ANY layer-3 fallback):**

1. **What backend guarantee is layer 3 enforcing when the backend skips it?** Identify the layer-1 contract first. If the backend already guarantees the affordance, the frontend fallback must SUPPRESS itself (e.g. `renderedCustomAction` flag).
2. **What modal flow owns the surface?** Layer 2's `inject_modal_finish_choice_if_needed` reorganizes the list around modal state. Layer 3 MUST consult the same modal state before emitting anything that would corrupt the modal flow (PR #8489 regression class).
3. **What two state surfaces does the user perceive as one?** If layer 3 toggles a surface that another layer 3 toggle (or layer 2 state) also affects, both must coordinate via a shared flag or CSS rule (e.g. `is-collapsed`, `:has(.open)`).
4. **What is the resize/reflow trigger?** If layer 3 emits DOM that changes the height of its container, the container's CSS `max-height` cap (if any) MUST be re-snapped on the trigger event. Without a re-snap, the new content overflows silently or overlaps other layers.
5. **What does the user see in the OFF path?** If layer 3 has an "always last" / "always first" invariant, layer 2's reorder carve-out must include a matching carve-out.

**Anti-patterns:**

- **Treating layer 3 as a pure render concern.** Layer 3 can make backend guarantees (e.g. when CDN lags behind deploy, layer 3 is the user's only safety net). Treat it as code that interacts with layers 1 and 2.
- **Reading layer 3 in isolation.** Always check what layer 1 guarantees and what layer 2 reorganizes before touching layer 3.
- **Hardcoding layer 3 to "always emit" without checking layer 1.** Will produces duplicates when the backend catches up.
- **Hardcoding layer 3 to "never emit" without checking layer 1.** Will drop the affordance on older clients / feature-flagged rollouts that lack the layer-1 guarantee.
