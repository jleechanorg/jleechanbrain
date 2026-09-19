# Case 3: PR #8923 (2026-08-15) — the "deploy mismatch" trap (declared RED without re-checking the current URL)

## Summary

PR #8923 (feat/add-gemini-3-7-flash-as-default) added `gemini-3.7-flash` to the allowed models list and changed `DEFAULT_GEMINI_MODEL` from `gemini-3-flash-preview` to `gemini-3.6-flash`. The PR commit was pushed (`0cd0174744`, `9503454589`, `ae3ccdda8f` on branch `feat/add-gemini-3-7-flash-as-default`). The Deploy PR Preview (Rotating Pool) workflow ran `31852578017` and reported success at 2026-08-15T00:28:23Z, landing on `https://mvp-site-app-s6-i6xf2p72ka-uc.a.run.app` (the most recent `github-actions[bot]` URL).

The /es evidence worker running the stickier /es cron (job `aj3payswkic`) captured screenshots against the OLDER URL `https://wa-pr-8923-preview-340e15ba.run.app` (the previous Cloud Run revision, based on commit `340e15ba` — a deployment that pre-dates the fix). The screenshots showed the OLD `settings.js` (4 options, default `gemini-3-flash-preview`). The worker concluded "deploy mismatch" and posted a `:red_circle:` verdict claiming the PR's deployed bundle is stale.

The verdict was wrong. The current cycle's deploy had already landed on `mvp-site-app-s6-i6xf2p72ka-uc.a.run.app` and serves the new code. A 5-second `curl -ksS https://mvp-site-app-s6-i6xf2p72ka-uc.a.run.app/js/settings.js | grep -E 'DEFAULT_GEMINI_MODEL|gemini-3.7-flash'` would have returned:

```
const DEFAULT_GEMINI_MODEL = "gemini-3.6-flash"; // Gemini 3.6 Flash (Jul 2026) — default workhorse
  ...
'gemini-3.7-flash': 'gemini-3.7-flash', // Gemini 3.7 Flash (Aug 2026) — stable, code exec + JSON
```

— which is GREEN. The worker tested the wrong URL.

## The bug class

This is the **inverse of P11**: P11 says "don't declare PASS without grepping the current preview URL". P13 says "don't declare RED without re-grepping the current preview URL either". Both are forms of the same bug: **reporting on a URL without checking the actual URL the system is on RIGHT NOW**.

The mechanism:
1. The worker copies a URL from a previous cycle's evidence (worker logs, prior cron output, or a comment that was tagged "preview URL" but is now stale).
2. The pool rotates slots — the previous deploy's URL is replaced by a new one. The old URL may be 404, or may still serve the previous bundle if the slot is reused.
3. The worker screenshots the old URL → gets the old bundle → declares "deploy mismatch".
4. The actual current URL serves the new code. The worker never tested it.

## Why this is more dangerous than P11

P11 ("declared PASS without grep") fails quietly — the user opens the URL, sees the bug, and complains. P13 ("declared RED without re-grepping") is **false alarm** — the system is healthy, the worker is reporting a blocker that doesn't exist, and the user wastes cycles (or the cron babysits a no-op) chasing a phantom bug. P13 also tends to **lock in the worker's hypothesis** — once `:red_circle: deploy mismatch` is in the thread, the next worker repeats the same test against the same stale URL and re-confirms the same wrong conclusion.

## Recipe (Phase 2.6 — live-URL re-resolution before any RED claim)

Before posting any failure claim about a PR preview deploy:

1. **Resolve the LIVE preview URL from the most recent `github-actions[bot]` comment, NOT from any cached URL in worker logs, prior cron output, or the worktree's prior-turn state.**

   ```bash
   PREVIEW=$(gh api "repos/$REPO/issues/$PR/comments?per_page=20" \
     --jq '.[] | select(.user.login == "github-actions[bot]") | .body' \
     | grep -oE 'https://mvp-site-app-s[0-9]+-[a-z0-9-]+-uc\.a\.run\.app' \
     | head -1)
   ```

   If the `s<N>` form is missing, fall back to the most recent `github-actions[bot]` comment that mentions "Preview App" (may use a custom URL pattern). **Never use the URL from the previous cycle's evidence file** — that's the URL the prior worker tested, which is exactly the URL the prior worker was wrong about.

2. **Cross-check the URL against the most recent successful deploy run.**

   ```bash
   gh run list --repo $REPO --branch $BRANCH --limit 5 \
     --json databaseId,name,conclusion,headSha,createdAt \
     | jq '[.[] | select(.name | contains("Deploy PR Preview")) | {id, conclusion, sha: .headSha, ts: .createdAt}]'
   ```

   The URL above should match a deploy whose `headSha` equals the PR's current HEAD. If the URLs disagree, the most recent deploy is the source of truth (the comment URL may lag).

3. **Run the bundle-content grep against the LIVE URL, not the cached URL.**

   ```bash
   curl -ksS "$PREVIEW/js/settings.js" | grep -E "DEFAULT_GEMINI_MODEL|gemini-3\.7-flash"
   ```

   If the grep returns the expected new strings, the deploy is GREEN — the prior cycle's "deploy mismatch" verdict is wrong. Post the corrected verdict with the live URL and the grep output as proof. Do NOT post `:red_circle:` based on the prior cycle's screenshot.

4. **If the live URL also lacks the new strings**, then run Phase 2 / 3 / 4 of the standard recipe to confirm the genuine stale-bundle bug. The P13 recipe is **not a replacement** for the standard bundle-grep + byte-count + Cloud Logging evidence — it is a pre-flight that the URL you're testing is actually the current one.

## Concrete verification recipe (the 5-second check the worker should have done)

```bash
# Get the live URL from the latest bot comment
PREVIEW=$(gh api "repos/jleechanorg/worldarchitect.ai/issues/8923/comments" \
  --jq '.[] | select(.user.login == "github-actions[bot]") | .body' \
  | grep -oE 'https://mvp-site-app-s[0-9]+-[a-z0-9-]+-uc\.a\.run\.app' \
  | head -1)

# Probe for the new code
curl -ksS "$PREVIEW/js/settings.js" | grep -E "DEFAULT_GEMINI_MODEL|gemini-3\.7-flash"

# If the grep returns the expected strings, the deploy is GREEN.
# If NOT, the bug is real — run the full Phase 2 / 3 / 4 recipe.
```

This is the same 5-second check that would have proven GREEN in this case. Without it, the worker ships a false :red_circle: claim and the user has to manually re-verify.

## Lesson

**The "current preview URL" is a moving target.** The rotating pool writes new images to `s<N>` slots every PR deploy. The URL embedded in a worker log from cycle N is the URL the cycle N worker tested — it is NOT the URL the cycle N+1 worker should test. Before any RED claim, re-resolve the URL from the live `github-actions[bot]` comment and re-run the bundle-grep against the live URL. The cost of the 5-second `curl + grep` is paid for many times over by the cost of a false :red_circle: claim.

The lesson symmetrically extends to "preview is serving the latest build" (P11) — both directions of the bundle-grep are forms of the same bug, and the Phase 2.6 pre-flight protects both.

## How to avoid this class of bug going forward

1. **Always re-resolve the live preview URL before any RED claim.** See Phase 2.6 above.
2. **Never trust a URL from a prior cycle's evidence file.** That URL is by definition the URL the prior cycle tested, which is the URL the prior cycle was wrong about.
3. **The 5-second `curl + grep` is the cheapest verification in the recipe.** If you find yourself about to post a `:red_circle:` without having run it in the current cycle, stop and run it. The cost of the curl is ~5 seconds; the cost of a false RED is a confused user + a wasted cron babysit.
4. **If the live URL is the same as the cached URL**, the bug may be pool-wide (rotating pool shares one image — see P9 refinement). Switch to the multi-slot MD5 check (`for slot in s1 s2 s3 s4 s5 s6 s7 s8 s9 s10; do ...`) to confirm.
5. **If multiple bot comments list different URLs** (old and new), the newer one wins. Verify by `gh run list` which run ID each bot comment corresponds to — the URL with the matching `head_sha` is the live one.
