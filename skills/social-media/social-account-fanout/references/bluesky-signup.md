# Bluesky Signup (verified 2026-08-20)

Working recipe for driving `bsky.app/signup` end-to-end via Aside REPL.
Captured during Slack session `${SLACK_CHANNEL_ID}/p1787248634.248549`.

## URL

- Entry point: `https://bsky.app/` — click the "Create account" button on the
  Discover page.
- Direct: `https://bsky.app/` (no direct `/signup` URL — the signup is a
  modal that opens from the home page).
- Step-3 (captcha) URL: `https://bsky.social/gate/signup?handle=<handle>.bsky.social&state=<state>&colorScheme=dim`
  (rendered inside `<iframe id="captcha-iframe">`)

## 3-step wizard shape

| Step | Fields | Submit button | Notes |
|---|---|---|---|
| 1 of 3 | Email, Password, Birth date (`<input type=date>`) | "Next" | Birth date defaults to today — explicitly fill `1990-01-01` |
| 2 of 3 | Handle (subdomain combobox) | "Next" (disabled until availability check) | Suggested handles listed as `option` elements in a `listbox` |
| 3 of 3 | hCaptcha in `bsky.social/gate/signup` iframe | (none — captcha drives submission) | sitekey `e75b29e9-404c-48a4-b89f-7abf6bbd17b1` |

## Working Aside REPL recipe (single call, modal survives)

```js
const p = await openTab('https://bsky.app/');
await p.waitForTimeout(5000);
// Step 1 — open modal + fill
await p.locator('button:has-text("Create account")').click();
await p.waitForTimeout(4000);
await p.locator('input[placeholder*="email" i]').first().fill('jleechan+bluesky@gmail.com');
await p.locator('input[type=password]').first().fill('GENERATED_PASSWORD');
await p.locator('input[type=date]').first().fill('1990-01-01');
await p.locator('button:has-text("Next")').click();
await p.waitForTimeout(5000);
// Step 2 — handle (check availability, then Next)
await p.locator('input[placeholder*="bsky.social" i]').first().fill('jleechan');
await p.waitForTimeout(3500);
// If "is not available" appears, pick a suggestion from the listbox:
const suggestions = await p.locator('option:has-text("Available")').allTextContents();
console.log('SUGGESTIONS:', JSON.stringify(suggestions));
// e.g. ['jleechan90.bsky.social Available', 'jleechanbluesky.bsky.social Available', ...]
await p.locator('input[placeholder*="bsky.social" i]').first().fill('jleechan90');
await p.waitForTimeout(3500);
const nextBtn = p.locator('button:has-text("Next")').first();
if (await nextBtn.isEnabled()) await nextBtn.click();
await p.waitForTimeout(6000);
// Step 3 — captcha. PAUSE here. Ask the user to click.
const captchaFrame = p.frameLocator('#captcha-iframe');
const innerHtml = await captchaFrame.locator('body').innerHTML();
console.log('CAPTCHA_REACHED:', innerHtml.includes('hcaptcha'));
```

## Pitfalls observed (cross-ref `aside-automation-pitfalls`)

- #25: `getByRole({ name: /next/i })` does NOT work — use `button:has-text("Next")`.
- #26: `:not([disabled])` selector does NOT work — use `await nextBtn.isEnabled()`.
- #27: The whole wizard MUST be one `aside repl` call. Re-opening the URL
  closes the modal and loses all input. Each fresh `aside repl` starts a
  blank JS context; do NOT split across calls.
- #28: Aside NL agent cannot write to `/tmp/...` for screenshots — its
  sandbox rejects absolute paths outside the session workspace. Use the
  session workspace dir or drive the screenshot from `aside repl` instead.
- #29: hCaptcha final step requires the user's click in the visible Aside
  window. Don't try to solve it from the agent.

## Email verification (Step 3.5)

After hCaptcha passes, Bluesky sends a verification email to
`jleechan+bluesky@gmail.com`. The verification link looks like:
`https://bsky.app/verify?token=<token>`.

Fetch via:
```bash
gog gmail users threads list --user=me --q="from:bsky.app to:jleechan+bluesky@gmail.com newer_than:1d" --format=json
# (was `gws gmail users threads list` — `gws` is BANNED for personal Workspace calls; use `gog` per SOUL.md ## COMMIT: gws-banned-for-personal-workspace)
```

Then `gog gmail users threads get --user=me --id=<thread-id> --format=json`
to get the full body, extract the `verify?token=...` URL, and click it in
Aside (same `aside repl` flow as any other URL).

## Post-signup state

- Settings page: `https://bsky.app/settings` — shows email verification
  status, app passwords, and moderation settings.
- App passwords (for CLI / third-party clients): Settings → Privacy and
  Security → App Passwords. Generate one per tool (don't reuse your
  login password in third-party tools).

## Login credentials recap

After completion, print to user ONCE and store in
`~/.config/fediverse/credentials.json`:

```json
{
  "bluesky": {
    "handle": "jleechan90.bsky.social",
    "email": "jleechan+bluesky@gmail.com",
    "password": "GENERATED_PASSWORD",
    "instance": "bsky.social"
  }
}
```

The user MUST move these into their password manager — the JSON file on disk
is plaintext and not backed up by the agent.
