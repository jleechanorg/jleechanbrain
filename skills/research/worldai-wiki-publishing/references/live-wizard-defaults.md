# Live Wizard Defaults — V1 Flask, Verified 2026-08-05

Source of truth: Playwright probe against the local Flask server in `TESTING_AUTH_BYPASS=true` mode (`http://localhost:8081/?test_mode=true&test_user_id=test-user-123`). Wizard code path: `mvp_site/frontend_v1/js/campaign-wizard.js`.

## Checkbox state at boot (Step 1, before any user interaction)

| Wizard DOM id | User-facing label | `is_checked()` | Wizard code path |
|---|---|---|---|
| `#prompt-narrative` | Narrative (Jeff's Narrative Flair) | True | wizard.js: `selectedPrompts` array |
| `#prompt-mechanics` | Mechanics (Jeff's Mechanical Precision) | True | wizard.js: `selectedPrompts` array |
| `#generate-companions` | Generate starting Companions | True | wizard.js: `customOptions` array |
| `#use-default-world` | Use Default Fantasy World (Celestial Wars/Assiah setting) | True | wizard.js: `customOptions` array |
| `#edit-narrative` | (sub-toggle, hidden) | True | Edit-modal sub-control |
| `#edit-mechanics` | (sub-toggle, hidden) | False | Edit-modal sub-control |
| `#edit-companions` | (sub-toggle, hidden) | False | Edit-modal sub-control |
| `#edit-default-world` | (sub-toggle, hidden) | False | Edit-modal sub-control |
| `#spicyModeSwitch` | Spicy mode | False | unrelated |

The 4 main user-facing checkboxes are ALL checked. The hidden edit-modal sub-toggles show a different (inverted) state because they only represent "will this toggle move when the user clicks the Edit chip" — not the live campaign config.

## Form field defaults

| Field | Initial value | Notes |
|---|---|---|
| `#wizard-campaign-title` | `My Epic Adventure` | Hardcoded default; only "Dragon Knight" preset uses a different seed. |
| `#wizard-character-input` | empty | Placeholder text: "Leave blank for a randomly generated character". |
| `#wizard-setting-input` | empty | Placeholder text: "Leave blank for a randomly generated world". |
| `#wizard-description-input` | empty | Hidden behind a "▶ Expand" toggle; field is collapsed by default. |

## Step 2 review screen text

After filling the form and clicking Next, the Step 2 review screen displays (verified live):

- **Title:** `<your title>` (editable inline)
- **Character:** `<your character>` (editable inline; "Auto-generated" if blank)
- **Description:** `<first 50ish chars of bible>` + "..." banner (truncated in display but full text stored in campaign config — verified via `document.getElementById('wizard-description-input').value` length)
- **AI Personalities:** `Narrative` — ONLY Narrative. Mechanics/Companions are stored but NOT displayed.
- **Options:** `None selected` — the default Step 2 readout, even when Mechanics/Companions are checked.

The "Options: None selected" is misleading: it implies no options are enabled, but Mechanics is actually stored in the campaign config and used by the AI DM. Don't use the Step 2 review text as evidence that a checkbox "carried through" — it doesn't surface Mechanics state.

## Selecting the right selectors in Playwright

The 4 main checkboxes all share `name="selectedPrompts"` (Narrative, Mechanics) or `name="customOptions"` (Companions, Default-World). They DO NOT have unique `name` attributes — only unique `id`s. Use the `#id` selector, never `input[name='mechanics']` (returns wrong element).

```python
# Correct selectors (from this verification)
page.locator("#prompt-narrative").is_checked()  # True
page.locator("#prompt-mechanics").is_checked()  # True
page.locator("#generate-companions").is_checked()  # True
page.locator("#use-default-world").is_checked()  # True
```

The `.first` trick is needed for any selector with multiple matches (e.g. `label:has-text('Mechanics')` matches both the main checkbox label AND the edit-modal sub-toggle).

## Why the defaults are dangerous to guess

The wizard names the checkboxes in ways that suggest they should default to OFF:

- "Generate starting Companions" — sounds like an opt-in
- "Use Default Fantasy World" — sounds like an opt-in (and most user-friendly setups prefer the default OFF)

But both default to ON. Same for "Mechanics" and "Narrative". The convention in this wizard is "all ON, user opts out of what they don't want" — opposite of the standard "all OFF, user opts in" mental model. Don't infer defaults from checkbox names; probe live.

## Common prose traps (verified wrong in PR #7 commits before live probe)

| Prose suggestion | Reality | Source |
|---|---|---|
| "Mechanics unchecked by default — CHECK THIS" | Already checked | wizard.js + Playwright probe 2026-08-05 |
| "Use Default Fantasy World unchecked — leave it" | Already checked — must UNCHECK | wizard.js + Playwright probe 2026-08-05 |
| "Generate starting Companions unchecked — optional" | Already checked — must UNCHECK for tighter cast | wizard.js + Playwright probe 2026-08-05 |
| "Step 2 review shows AI Personalities: Narrative, Mechanics, Companions" | Only Narrative is shown | Step 2 live capture 2026-08-05 |

These four "intuitive" defaults were committed to PR #7 in the original `0875e38` create, then "corrected" to the wrong-but-opposite defaults in the live-test comments, then finally inverted to the live-truth values in `a80f846`. The probe caught what prose could not.

## What the user actually sees when filling the form

The `Character` field has placeholder text "Leave blank for a randomly generated character". This **directly contradicts** the wiki's instruction to "**don't leave blank** for this template" — a first-time player reading the placeholder might think leaving it blank is fine. The wiki must explicitly override the placeholder, e.g.:

> The wizard's placeholder text says "Leave blank for a randomly generated character" — for THIS template, do NOT leave it blank. If you do, the AI generates a generic character and you lose the dragon-claim opening that the bible sets up.

This is a documented UI/wikil contradiction worth flagging in the wiki itself.

## What "Custom Campaign" radio actually does

The radio `#campaign-type-custom` is selected by default at boot. Selecting `#campaign-type-dragon-knight` swaps the wizard into the built-in "Dragon Knight Campaign" preset (different form, different starting content). For player-shareable templates targeting a specific setting, always leave Custom selected — never switch to Dragon Knight.

## Where to look in the wizard code

```
mvp_site/frontend_v1/js/campaign-wizard.js
├── Line ~773: <label for="wizard-campaign-title">
├── Line ~777: id="wizard-campaign-title"
├── Line ~807: <label for="wizard-description-input">Campaign description prompt</label>
├── Line ~814: id="wizard-description-input"
├── Line ~978: e.target.matches('#wizard-campaign-title') event hook
├── Line ~1049: const titleInput = document.getElementById('wizard-campaign-title');
├── Line ~1669: title: document.getElementById('wizard-campaign-title')?.value || ''
├── Line ~2427: titleInput.value || getDefaultTitle(...)
```

These are the canonical IDs for all wizard form fields. They are the same in static `index.html` AND in the JS-rendered live DOM (the wizard code reads/writes via `getElementById` against these IDs after page load). The static `index.html` is partially stale (missing some IDs) but the IDs that DO appear are correct.

## Side-by-side: live IDs vs static html IDs

| Static `index.html` (verbatim) | Live DOM (rendered) | Verdict |
|---|---|---|
| (no static `#wizard-campaign-title`) | `#wizard-campaign-title` | JS-built |
| (no static `#wizard-character-input`) | `#wizard-character-input` | JS-built |
| (no static `#wizard-description-input`) | `#wizard-description-input` | JS-built |
| `id="use-default-world"` (some templates) | `#use-default-world` | matches |
| `id="prompt-mechanics"` (some templates) | `#prompt-mechanics` | matches |
| `id="generate-companions"` (some templates) | `#generate-companions` | matches |

Use **user-facing labels** in any wiki walkthrough (they are stable); reference **live IDs only in the test script** (they're stable for this wizard version, but the static html drifted out of sync — see table).