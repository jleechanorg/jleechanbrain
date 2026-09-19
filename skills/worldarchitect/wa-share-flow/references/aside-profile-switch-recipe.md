# Aside profile-switch recipe (verified 2026-08-18)

The exact dance for switching active Aside profiles mid-session. Captured separately from `wa-share-flow` because it generalizes beyond WA work to any cross-account browser automation.

## The two-flag trap

Aside CLI exposes both:

```bash
# A. Per-invocation flag
aside --account u0 "open https://example.com"

# B. Global default (sticky)
aside account use u0
```

**Only flag B actually switches the daemon's active profile.** Flag A only affects the AI-agent prompt's context — the `openTab` calls inside `aside repl` still open on whatever profile was active when the daemon started or when `aside account use` was last called.

Verified 2026-08-18:

```bash
$ aside account status
* u1  jleechan@worldarchitect.ai  signed in  profiles: Profile 1
  provider: google

$ aside --account u0 repl "const p = await openTab('https://mvp-site-app-dev-i6xf2p72ka-uc.a.run.app/'); ..." 
# Page opened, but firebase.auth().currentUser was STILL jleechantest@gmail.com (u1).
# Because `--account u0` only set the AI-agent prompt's account, not the daemon's default.

$ aside account use u0
Using account u0 (jleechan@gmail.com).

$ aside repl "const p = await openTab('https://mvp-site-app-dev-i6xf2p72ka-uc.a.run.app/'); ..." 
# Page opened, firebase.auth().currentUser correctly = jleechan@gmail.com (u0).
```

## The 4-second rehydration wait

After `aside account use <id>`, the page opened by `openTab` shows the new account's auth state immediately. **But `firebase.auth().currentUser` reads `null` for the first ~4 seconds** while the Firebase Auth client rehydrates from the new cookie jar.

If you query `currentUser` too early, `getIdToken()` throws `Cannot read properties of null`.

**Fix**: wait 4s extra after page load before reading `currentUser`:

```js
const p = await openTab('https://mvp-site-app-dev-i6xf2p72ka-uc.a.run.app/');
await new Promise(r => setTimeout(r, 12000));  // standard page load
await new Promise(r => setTimeout(r, 4000));   // EXTRA for Firebase Auth rehydrate

const u = window.firebase.auth().currentUser;  // NOW safe to read
```

The 4s is empirical — could be lower on a faster machine, but 4s is reliably enough on the dev server.

## Why this matters for cross-account WA work

WA's API endpoints (`/api/campaigns`, `/api/campaigns/<id>/share-token`) all require a Firebase Bearer token. If you grab the token under the wrong account:

- The campaign list will return 0 results (or the wrong user's campaigns).
- The share-token mint will succeed but the audit log will show the wrong UID.
- For campaigns owned by a different user, you'll silently mint a token on their campaign from your account — which works (Pitfall 4 in parent SKILL.md: token ≠ ownership), but produces misleading metadata.

## Recipe for safe cross-account work

```bash
# 1. Confirm current state
aside account status

# 2. Switch globally
aside account use <id>        # u0 / u1 / etc

# 3. Always do a fresh openTab to get a page handle under the new account
#    (a stale page handle from before the switch still reads the old cookie jar)

# 4. Always wait 12s + 4s after openTab before reading firebase.auth().currentUser
```

## Verification

Run this once after any profile switch:

```js
const p = await openTab('about:blank');
const checkP = await openTab('https://mvp-site-app-dev-i6xf2p72ka-uc.a.run.app/');
await new Promise(r => setTimeout(r, 12000));
await new Promise(r => setTimeout(r, 4000));
const u = window.firebase.auth().currentUser;
console.log('ACTIVE_UID:', u.uid, 'EMAIL:', u.email);
```

Output should match the account you switched to. If it doesn't, you forgot to call `aside account use` first.
