# Reddit old-submit-form DOM pitfalls — copy-paste recipes

Three traps that don't appear on the new Reddit React form. Hit all three in one r/SoloDevelopment session on 2026-08-25; baking the recipes here so the next session doesn't re-derive them.

## Pitfall 1 — Title is a `<TEXTAREA>`, not `<INPUT>`

Common selectors miss it. Correct selector:

```js
document.querySelector('textarea[name="title"]')
```

Must `focus()` + `click()` first, then set value via the native `HTMLTextAreaElement.prototype.value` setter and dispatch `input` + `change` events. Without focus, the title value reverts to empty even though `.value` reports the right length.

**Working recipe:**

```js
const titleTA = document.querySelector('textarea[name="title"]');
titleTA.focus();
titleTA.click();
const setter = Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value').set;
setter.call(titleTA, TITLE);
titleTA.dispatchEvent(new Event('input', { bubbles: true }));
titleTA.dispatchEvent(new Event('change', { bubbles: true }));
titleTA.dispatchEvent(new Event('blur', { bubbles: true }));
```

## Pitfall 2 — The "text" / "link" tabs are decorative `<li>` elements, not real toggles

Clicking them does nothing. To actually switch modes, **navigate** to:

| Mode | URL |
|---|---|
| Text | `https://old.reddit.com/r/<sub>/submit?selftext=true` (URL field hidden, body textarea visible) |
| Link | `https://old.reddit.com/r/<sub>/submit` (URL required, body hidden) |
| Image | `https://old.reddit.com/r/<sub>/submit?image=true` (image upload required, body hidden) |

The `text` / `link` `<li>` tabs in the DOM are decorative — they highlight the active mode but don't actually switch it. Always navigate instead of clicking.

## Pitfall 3 — Two submit-looking buttons exist; only one is the real submit

| Button | text | Purpose |
|---|---|---|
| `<button>save</button>` | `save` | Save as draft. Stays `disabled: true` even when the form is valid. **Ignore.** |
| `<button name="submit" type="submit">submit</button>` | `submit` | The real submit. Check this one's `disabled` state, not the save button's. |

The save button's presence in the DOM doesn't mean the form is invalid. Verify the submit button's `disabled` state.

## Pitfall 4 — Image upload in text mode is impossible

Reddit's old submit form forces text / link / image as exclusive `kind` values. If the draft is text+image, you must either:

1. **Drop the image and ship text-only** — best for text-friendly subs like r/SoloDevelopment
2. **Switch to image mode and lose the body text** — useful only if the body is short and the image is the centerpiece
3. **Post text-only first, then add the image as a comment reply** — fallback when both text and image are load-bearing

The image is staged to the file input `input#image[type="file"]` (id=`image`, accept=`image/*,video/quicktime,video/mp4`), but the form silently ignores it in text mode.

## Cross-pitfall detection snippet

Before claiming the form is "filled", run:

```js
const titleTA = document.querySelector('textarea[name="title"]');
const bodyTA = document.querySelector('textarea[name="text"]');
const submitBtn = Array.from(document.querySelectorAll('button[name="submit"], button[type="submit"]'))
  .find(b => b.innerText.toLowerCase() === 'submit');
return {
  titleLen: titleTA?.value.length || 0,
  bodyLen: bodyTA?.value.length || 0,
  submitDisabled: submitBtn?.disabled,
  mode: document.querySelector('input#url')?.offsetParent !== null ? 'link' : 'text'
};
```

All four values must be non-zero/non-disabled before claiming the form is ready.

## Why this matters

Every "draft a Reddit post" session starts by re-deriving these. Hit-and-miss takes 5–10 tool calls. Baking them here drops the staging loop to 3 calls (navigate to text mode → fill both fields with focus first → verify via the snippet above).