# CSS token contract test pattern + worldarchitect.ai bootstrap pitfalls

Verified 2026-08-18 on `jleechanorg/worldarchitect.ai` PR [#9055](https://github.com/jleechanorg/worldarchitect.ai/pull/9055) ("Planning block and custom action text too small — make it same size as narrative text"). The bug class was a CSS variable token deliberately set to `12.8px` (a 20% shrink from body 16px) on a now-stale rationale. Resetting the token is a one-line fix; the durable part is **pinning the contract so the token cannot silently drift back** to a compact value on the next edit.

This file covers two related things:

1. The CSS-token contract test pattern (applies to ANY `:root { --foo: X }` token whose drift would regress a UX contract).
2. Bootstrap pitfalls specific to capturing visual evidence for `worldarchitect.ai` UI fixes — the gaps in `wa-visual-proof-playwright` that this session had to rediscover.

## Part 1 — CSS token contract test pattern

### The contract shape

For a CSS token like `:root { --composer-choice-font: 1rem }` where downstream rules use `var(--composer-choice-font, <fallback>)`, the contract has THREE values that must stay in lockstep:

1. The token value.
2. Every `var(...)` fallback — if the token is removed/shadowed, the fallback value silently takes over.
3. The comment that documents WHY the value is what it is (so future editors cannot claim ignorance when reverting).

A single test that pins all three turns a silent regression into a loud one.

### The test (Node 22 `node --test`, no jsdom needed)

```javascript
// mvp_site/frontend_v1/tests/planning_block_text_size.test.js
"use strict";
const { test } = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");

const STYLES_PATH = path.join(__dirname, "..", "styles", "planning-blocks.css");

test("--composer-choice-font token equals 1rem", () => {
  const css = fs.readFileSync(STYLES_PATH, "utf8");
  const tokenMatch = css.match(/--composer-choice-font\s*:\s*([^;]+);/);
  assert.ok(tokenMatch, "must define --composer-choice-font");
  assert.strictEqual(
    tokenMatch[1].trim(), "1rem",
    `token must equal '1rem' to match narrative body font-size;`
  );
});

test("all var(--composer-choice-font, <fallback>) values are 1rem", () => {
  const css = fs.readFileSync(STYLES_PATH, "utf8");
  const re = /var\(\s*--composer-choice-font\s*,\s*([^)]+)\)/g;
  const fallbacks = [...css.matchAll(re)].map(m => m[1].trim());
  assert.ok(fallbacks.length > 0, "expected at least one var(...) reference");
  for (const fb of fallbacks) {
    assert.strictEqual(fb, "1rem",
      `Fallback must be '1rem' (NOT ${fb}). A compact fallback re-introduces the bug.`);
  }
});

test("comment documents the rationale", () => {
  const css = fs.readFileSync(STYLES_PATH, "utf8");
  // The token block must document WHY it is 1rem, not just declare it.
  const hasRationale = /same size as narrative/i.test(css);
  assert.ok(hasRationale, "comments must document the rationale");
});
```

### Why this works

- **Fail-loud on the bad value.** A revert to `12.8px` makes the first test fail with a message naming the operator's rule.
- **Fail-loud on a hidden fallback drift.** If someone replaces the fallback with `0.8rem` to "make the placeholder smaller," the second test fires.
- **Fail-loud on rationale removal.** If someone deletes the comment block on cleanup, the third test fires — preserving the institutional memory that this value exists for a reason.

### Mutation-tested (verified by `git stash` round-trip)

```bash
git stash -- mvp_site/frontend_v1/styles/planning-blocks.css
node --test mvp_site/frontend_v1/tests/planning_block_text_size.test.js
# Expected: 0 pass / 3 fail on origin/main, 3 pass / 0 fail on fix branch
git stash pop
```

### Where to put it

- `mvp_site/frontend_v1/tests/<token-name>.test.js` — same directory as the CSS file. The test reads from disk via `fs.readFileSync`, no build pipeline needed.
- Run as part of CI; runs in ~40ms because it's regex-only.

## Part 2 — worldarchitect.ai bootstrap pitfalls for visual evidence

These are the four non-obvious gotchas hit on PR #9055. They are not in `wa-visual-proof-playwright` (the user-owned skill) because the session that wrote it predated these discoveries.

### Pitfall 1 — `X-Test-Bypass-Auth: true` header is REQUIRED

`mvp_site/main.py:1893-1899` explicitly requires this header for the `?test_mode=true&test_user_id=...` bypass to fire. Without it, the page silently redirects to `/login` (or wherever auth lands). The capture succeeds but shows the login wall or campaigns dashboard, not the game view.

```python
ctx = await browser.new_context(viewport={"width": 1400, "height": 1100})
await ctx.set_extra_http_headers({"X-Test-Bypass-Auth": "true"})   # <-- required
```

**Symptom of forgetting it**: `choice_buttons: []` in the diagnostic probe, screenshot shows the login/dashboard. Easy to miss because no error fires.

### Pitfall 2 — `test_user_id` must OWN the campaign

The bypass is auth-only. It does NOT bypass ownership checks. If production campaign `Mz4s5zy30noDnSgScPJH` belongs to user `test-test-level-up-organic-...`, navigating to `/game/Mz4...` with `test_user_id=jleechan` returns the dashboard or 404, NOT the campaign. The diagnostic probe will show zero `.choice-button` elements even though the page renders.

**Fix**: copy the source campaign into the bypass user via Firestore BEFORE capturing:

```python
import os
os.environ.setdefault('GOOGLE_APPLICATION_CREDENTIALS', os.path.expanduser('~/serviceAccountKey.json'))
os.environ.setdefault('WORLDAI_GOOGLE_APPLICATION_CREDENTIALS', os.path.expanduser('~/serviceAccountKey.json'))
os.environ.setdefault('WORLDAI_DEV_MODE', 'true')

import firebase_admin
from firebase_admin import credentials, firestore
if not firebase_admin._apps:
    firebase_admin.initialize_app(credentials.Certificate(os.path.expanduser('~/serviceAccountKey.json')))
db = firestore.client()

SRC_USER, SRC_CID = "test-test-level-up-organic-1782799763-single-organic-level-up", "7BBhG3o0bZYllRhrNJHQ"
DST_USER, DST_CID = "jleechan", "font-test-<short-id>"
src = db.collection('users').document(SRC_USER).collection('campaigns').document(SRC_CID)
dst = db.collection('users').document(DST_USER).collection('campaigns').document(DST_CID)
dst.set(src.get().to_dict())
for sub in ('story', 'game_states'):
    for d in src.collection(sub).stream():
        dst.collection(sub).document(d.id).set(d.to_dict())
```

**Clean up afterwards** — delete the test campaign so `jleechan` stays clean for future runs.

### Pitfall 3 — Fresh worktree has no `venv/`

`run_test_server.sh` hardcodes `venv/bin/activate`. A fresh worktree under `.worktrees/<branch>` (or `/tmp/wa-<branch>`) does NOT have a `venv/`.

**Fix**:

```bash
git worktree add /tmp/wa-fix origin/main -b fix/<slug>
cd /tmp/wa-fix
ln -s ${HOME}/projects/worldarchitect.ai/venv venv   # <-- required
./run_test_server.sh start
```

The symlink works because `run_test_server.sh` only sources `venv/bin/activate` — actual Python modules resolve through the symlinked directory.

### Pitfall 5 — CORS preflight on `/api/*` only whitelists `X-Test-Bypass-Auth` (added PR #9070, 2026-08-18)

Pitfall 1 says to send `X-Test-Bypass-Auth: true`. That alone is not enough — the server's CORS config (`mvp_site/main.py:353-365`) **only** whitelists that single header in `Access-Control-Allow-Headers`:

```python
cors_allow_headers = ["Content-Type", "Authorization", "X-Forwarded-For"]
TESTING_AUTH_BYPASS_MODE = os.getenv("TESTING_AUTH_BYPASS") == "true"
if TESTING_AUTH_BYPASS_MODE:
    cors_allow_headers.extend(
        ["X-Test-Bypass-Auth", "X-Test-User-ID", "X-Test-User-Email"]
    )
```

But the catch is the **ORDER of initialization**: the `if TESTING_AUTH_BYPASS_MODE` check runs at module import. If `run_local_server.sh` launches Flask via a subshell that does NOT export `TESTING_AUTH_BYPASS=*** before sourcing the python entry point, `cors_allow_headers` is frozen with only the first three headers. The OPTIONS preflight then returns `Access-Control-Allow-Headers: content-type` and rejects every `X-Test-*` request.

**Two failure modes that look identical** (both 401 the API call, both time out the navigation, both leave the capture at the dashboard):

- `TESTING_AUTH_BYPASS=*** not set when `cors_allow_headers` was initialized — server silently doesn't extend the whitelist.
- Set, but the Playwright capture also sends `X-Test-User-ID` / `X-Test-User-Email` — OPTIONS preflight on `/api/*` rejects the unwhitelisted request headers (the whitelist is for the response, not the request).

**The trap**: the server log shows `TESTING_AUTH_BYPASS=true` in the flask process env (`ps eww -p $(pgrep -f "mvp_site.main serve" | head -1) | tr ' ' '\n' | grep TESTING_AUTH_BYPASS`), so you assume the whitelist is in effect. But the variable was read at module import — and `cors_allow_headers` was already finalized by then.

**Fix — two-part**:

1. **Export the env vars BEFORE launching the server.** They must be set in the SAME shell that sources `run_local_server.sh` AND that the script's Python entry point inherits. Verified launch sequence on PR #9070 (port 8081, the script's default after `--force-default-port`):

```bash
cd /tmp/<worktree>
rm -f feat_<branch>/*.pid 2>/dev/null   # clean up pidfiles from prior crashed runs
export TESTING_AUTH_BYPASS=true ALLOW_TEST_AUTH_BYPASS=true WORLDAI_DEV_MODE=true
bash run_local_server.sh --no-log-stream --force-default-port
```

Note: just `bash run_local_server.sh` (no inline export) is NOT enough. The script's own env handling reads `TESTING_AUTH_BYPASS` late (after `cors_allow_headers` is already frozen). The inline `export` in the same shell as the `bash` invocation is what propagates it.

2. **Send ONLY `X-Test-Bypass-Auth: true` from Playwright.** User identity is read server-side from the `test_user_id` query param (`main.py:1629: request.args.get("uid") or request.args.get("test_user_id") or ""`), not from headers. Strip the `X-Test-User-ID` / `X-Test-User-Email` from `set_extra_http_headers`:

```python
ctx.set_extra_http_headers({"X-Test-Bypass-Auth": "true"})   # ONLY this one
# X-Test-User-ID and X-Test-User-Email break OPTIONS preflight on /api/*.
# User identity comes from the test_user_id query parameter.
```

**Verification recipe** — run BEFORE the capture loop:

```bash
# 1. Confirm env is in the flask process
ps eww -p $(pgrep -f "mvp_site.main serve" | head -1) | tr ' ' '\n' | grep "^TESTING_AUTH_BYPASS="
# Expected: TESTING_AUTH_BYPASS=true

# 2. Confirm CORS preflight actually whitelists the header on /api/*
curl -sS -X OPTIONS "http://localhost:<PORT>/api/campaigns/quick-start" \
  -H "Origin: http://localhost:<PORT>" \
  -H "Access-Control-Request-Method: POST" \
  -H "Access-Control-Request-Headers: x-test-bypass-auth,content-type" \
  -i | grep -E "^Access-Control-Allow-Headers"
# Expected: Access-Control-Allow-Headers: content-type, x-test-bypass-auth
# If you see ONLY "content-type" — the env didn't propagate before module import.
# Fix: kill the flask process, re-export the env in the same shell, re-launch.
```

If step 2 fails, do NOT proceed to capture — every subsequent `/api/*` call will 401, the Quick Start click won't navigate to `/game/<id>`, and you'll waste 180 seconds on `wait_for_url("**/game/*")` timeout before realizing.

**Symptom-vs-cause map** (saves the next debugging round):

| What you see | Real cause | Fix |
|---|---|---|
| Console log: `🔴 fetchApi: HTTP error 401 UNAUTHORIZED for /api/campaigns/quick-start` | CORS preflight rejected the request header | Strip extra `X-Test-*` headers, OR re-export env before launch |
| Capture times out on `page.wait_for_url("**/game/*")` at 180s | Same as above — API never returned a campaign ID | Same fix |
| `before_meta.json` shows `borderLeftWidth: 0px` on `after.png` capture too | Capture ran but injected synthetic HTML — the live planning block never rendered because Quick Start didn't navigate | Same fix; verify with `vision_analyze` that the screenshot shows the real planning block (not just the injected HTML) |
| Flask env shows `TESTING_AUTH_BYPASS=true` BUT OPTIONS preflight returns only `content-type` | Module-import timing — `cors_allow_headers` finalized before env was read | Kill flask, re-export env in the launching shell, re-launch |

**Why this is not in `wa-visual-proof-playwright`**: that user-owned skill predates this specific CORS-env-timing combination. The session that originally captured PR #9070 evidence ran with env already exported (via `~/.bashrc`'s `export TESTING_AUTH_BYPASS=*** line), so it worked the first time and was never re-verified. This is the same class of "worked once, never re-verified" pattern that makes bootstrap recipes rot.

### Pitfall 4 — `git stash` is cleaner than bytes-around-swap for multi-line CSS changes

The existing `wa-visual-proof-playwright` recipe uses `git show origin/main:path > on-disk-file` (single-file byte swap) which round-trips cleanly for ONE file. For a fix that adds context comments + changes the token value + updates all six fallbacks (as PR #9055 did), `git stash` is faster and less error-prone:

```bash
git add mvp_site/frontend_v1/styles/<file>.css
git stash --keep-index                                          # stash only the staged change
venv/bin/python capture.py before                               # capture baseline
git stash pop                                                   # restore fix
venv/bin/python capture.py after                                # capture fix
```

The `git diff` between captures is the inverse of the staged change, so what-you-saw-before is exactly what-the-stash-reverted-to.

## Part 3 — Computed-style probe is the canonical proof for CSS contracts

A screenshot is evidence of pixels. A font-size claim ("choice text matches narrative text") is a claim about computed styles, not pixels. Pixel-level rendering is too subtle to reliably discriminate "16px" vs "12.8px" by eye — the human eye is great at catching 4px+ differences and terrible at catching 3.2px differences.

**For any CSS-token-size fix, the computed-style probe is the proof.** Embed it in the capture script:

```python
diag = await page.evaluate("""
    () => {
        const r = {};
        for (const [k, sel] of Object.entries({
            narrative_p:    "#story-content p",
            in_story_btn:    ".planning-block-choices .choice-button",
            composer_btn:    ".composer-choices .choice-button",
            placeholder:     "#user-input",
        })) {
            const el = document.querySelector(sel);
            if (el) {
                const cs = getComputedStyle(el);
                r[k] = {
                    fontSize: cs.fontSize,
                    lineHeight: cs.lineHeight,
                };
            }
        }
        r.token = getComputedStyle(document.documentElement)
            .getPropertyValue('--composer-choice-font').trim();
        return r;
    }
""")
print(f"[{label}] computed:", json.dumps(diag, indent=2))
```

Then the PR body becomes a verifiable table:

| Selector | Before | After |
|---|---|---|
| `.composer-choices .choice-button` | `12.8px` | `1rem` (16px) |
| `.ctitle` | `12.8px` | `1rem` (16px) |
| `#user-input` (placeholder) | `0.8rem` (~12.8px) | `1rem` (16px) |
| `#story-content p` (narrative) | `16px` (unchanged) | `16px` |

The PNG screenshots then become the human-readable version of the same proof. The computed-style table is the machine-checkable version.
