---
name: pr-preview-deploy-verification
description: Confirm a preview deploy shipped code, not just CI green.
version: 1.4.0
changelog:
  - "1.4.0 (2026-08-18): Add P13 (CSS static-asset staleness — the entire Phase 2/2.5/3 recipe was JS-bundle-focused; CSS files (`*.css`, plain and content-hashed) can be equally stale, served with `Last-Modified: <old date>` despite a fresh deploy, and Phase 2's `grep -cE '<expected-string>'` does not catch CSS regressions because CSS does not carry the function/string markers the recipe greps for). Add Phase 2.7 (CSS-specific byte-count vs source + `Last-Modified` header sanity + selector/rule-presence grep) parallel to Phase 3 for JS. Add P14 (user posts UI screenshot as inbound evidence during a PR review cycle → that screenshot IS a deployment-verification signal: load this skill proactively, do not wait for the user to file a bug report 30+ min later). Cross-ref `pr-evidence-inbound-review` Pitfall 11. Verified 2026-08-18 on PR #9042 (avatar.css + style.css served with `Last-Modified: Sat, 04 Jul 2026 18:53:10 GMT`, repo HEAD 4994e53c50 dated Aug 18 — 45-day staleness surfaced by user screenshot, not by Phase 2)."
  - "1.3.0 (2026-08-12): Add P11 (the 'I declared PASSED without a bundle grep' trap — posting 'preview is serving the latest build' based on the bot comment URL alone is the same fabrication pattern as P3, and the parent turn's PASS claim from earlier today on PR #8808 was exactly this bug), P12 (login-overlay hides wizard DOM — prefill URLs routed to `/new-campaign` land on the Google sign-in screen when unauthenticated, so visual screenshots show only the login card even though the wizard DOM is rendered behind it; always probe via DOM query for the wizard input values, never via screenshot alone), P9 refinement (shared pool image: `s2`/`s6`/`s8` all serve identical MD5 `9ccb03eea2b0da9341bbac6820378975` on 2026-08-12 — the rotating pool shares one image, so a stale bundle found in one slot is stale in every slot), and case-study addendum for PR #8808 (stale `applyUrlParams` on `/new-campaign?title=...&character=...` share-link URL — agent's prior turn told Jeffrey 'preview server is serving the latest build including all fixes' without ever grepping the bundle). Verified 2026-08-12 on PR #8808."
  - "1.2.0 (2026-08-09): Add P9 (wrong-service-URL: `mvp-site-app-dev` is NOT a PR preview slot — the rotating pool writes to `s5`/`s6`/`s3`, never `dev`), P10 (runtime EMFILE recovery when verification pipelines exhaust fds — kill chromium subprocesses, serialize probes, never compound shell), Phase 2.5 (line-shift evidence: when a function is missing in the bundle, compare anchor line numbers in source vs bundle to quantify how many lines were stripped), and case-study addendum for PR #8790 (stale `applyUrlParams` on URL Param Epic Quest preview at HEAD `913a306`). Verified 2026-08-09."
  - "1.1.0 (2026-08-06): Reconcile Phase 2 'HARD GATE' wording with `wa-cloud-logging-diag` v1.5.0 evidence. The static-bundle string grep is a PRE-FLIGHT signal, not the gating step. When the served bundle lacks an expected string BUT Cloud Logging shows all events firing from the same revision with matching `labels.commit-sha` and `labels.pr-number`, the deliverable is GREEN — Phase 4 end-to-end evidence is the gating signal. When bundle content vs Cloud Logging disagree, report GREEN with the bundle mismatch as an investigation note (build pipeline / Docker layer cache), never RED. P3 also clarified: the no-bundle-check-fabrication rule applies when Phase 2 is the ONLY evidence; when Phase 4 evidence exists and matches, the skill explicitly allows the post. Verified on 2026-08-06 PR #8787 smoke-test cron."
  - "1.0.0 (2026-08-06): Initial extract from PR #8787 stale-bundle incident."
related_skills:
  - wa-cloud-logging-diag
  - pr-evidence-inbound-review
---

# PR Preview Deploy Verification

> **This skill handles Phase 2 + Phase 3 (bundle + byte-count checks). For Phase 4 (Cloud Logging end-to-end evidence — the HARD gate), see `wa-cloud-logging-diag`.** When the served bundle lacks an expected string BUT Cloud Logging shows the events firing from the same revision with matching `labels.commit-sha` / `labels.pr-number`, the deliverable is GREEN, not RED — Phase 4 evidence overrides Phase 2 pre-flight. Verified 2026-08-06 PR #8787.

When you need to confirm a Cloud Run PR preview deploy actually ships the PR's changes — not just that the deploy job reported success — run this verification gate. The deploy job can succeed while the build container produces a stale bundle (cache-bust failure, source-copy step skipping files). To rule out a stale bundle, combine this skill's bundle-layer checks with `wa-cloud-logging-diag`'s end-to-end evidence.

## When to use this skill

Trigger conditions (any one):
- User or cron asks for a smoke test or end-to-end test of a PR preview deploy
- A cron tick waits for a Deploy PR Preview workflow to complete then needs to verify the PR code shipped
- A PR modifies bundled frontend assets (auth.js, app.js, bundle.min.js, hashed *.abc123.js) and you need confidence the served bundle contains those changes before merging
- Earlier PASS reports are suspected to be fabricated (no bundle-layer verification, only CI green was checked)

## Recipe (5 phases)

### Phase 1 — Discover the deploy run

`gh api` is the only reliable entry point. If a known run ID returns 404, list runs on the branch and filter for the deploy workflow:

```
gh api 'repos/{owner}/{repo}/actions/runs?branch={branch}&per_page=20' \
  --jq '[.workflow_runs[] | select(.name | contains("Deploy PR Preview")) | {id, status, conclusion, head_sha, created_at, updated_at}]'
```

For the latest completed deploy, capture: `id`, `head_sha`, `preview_url` (from the most recent `github-actions[bot]` comment on the PR), `created_at`, `updated_at`. Do not stop on `status=success` — proceed to Phase 2.

### Phase 2 — Verify the served bundle (PRE-FLIGHT signal, NOT a hard gate)

Deploy job success + image tag matching `head_sha` is **not sufficient on its own** — the build container can copy stale source into the bundle despite a logged cache-bust step. Always grep the served bundles, AND always pair with Phase 4 (Cloud Logging) end-to-end evidence. The hard gate is Phase 4 (revision labels + event presence), not Phase 2 alone.

```
PREVIEW=https://mvp-site-app-s8-i6xf2p72ka-uc.a.run.app   # from Phase 1
# Fetch index.html and enumerate every .js reference (handle nested /js/ subdir)
curl -fsS "$PREVIEW/" | grep -oE 'src="/[^"]*\.js"' | sort -u

# For each script, grep for each expected string. Expected count >= 1 per string.
for f in $(curl -fsS "$PREVIEW/" | grep -oE 'src="/frontend_v1/(auth|app)\.[a-f0-9]+\.js"' | grep -oE 'auth\.[a-f0-9]+\.js|app\.[a-f0-9]+\.js'); do
  cnt=$(curl -fsS "$PREVIEW/frontend_v1/$f" | grep -cE 'signup.complete|signin.success|game.open|first_turn.begin|first_turn.outcome')
  echo "$cnt  $f"
done
```

Bundle-layer interpretation rules (per `wa-cloud-logging-diag` v1.5.0 evidence):
- **All 5 strings present in at least one bundle each + Phase 4 events fire** → GREEN, normal.
- **Bundle lacks a string BUT Phase 4 shows the events firing from the same revision with matching `labels.commit-sha` and `labels.pr-number`** → still GREEN; report the bundle mismatch as an investigation note (Docker layer cache, build pipeline drift) for the worker. Do NOT post `:red_circle:` in this case.
- **Bundle lacks a string AND Phase 4 shows no events** → RED, genuine stale-bundle bug. Investigate `mvp_site/Dockerfile` `COPY` step and open a build-pipeline PR.
- **SHA256 of served bundle matches SHA256 of `origin/main`'s source file at the same path** → strongest stale-bundle signal (byte-for-byte). Phase 4 still wins for the delivery verdict; cite the SHA evidence in the report as an investigation note.

NEVER hardcode the bundle hash (`auth.433593ec.js`) — the hash changes every PR deploy. Always derive hashes from the live `index.html` (`curl -fsS "$PREVIEW/" | grep -oE 'src="/frontend_v1/(auth|app)\.[a-f0-9]+\.js"'`).

A served bundle smaller than source (e.g. source 80,076 B vs served 79,034 B) is the smoking gun for a stale bundle. The build container copied a previous version. The byte delta approximates the lines added by the feature commit.

### Phase 2.5 — Line-shift evidence (when byte-count diff is ambiguous)

When a served bundle lacks a specific function but you don't know which commit the bundle was actually built from, **compare the line numbers of shared anchor lines** between source and served bundle. The line delta tells you exactly how many lines were stripped.

```
# Pick an anchor that exists in BOTH source and served bundle (a stable comment,
# an unrelated function, or even the next non-stripped line in the same file).
# Example from PR #8790: comment "// Only do cleanup if not skipped (prevents race
# condition with forceCleanRecreation)" is on line 629 in served bundle and line
# 707 in PR HEAD source. Delta = 78 lines = exactly the size of `applyUrlParams`
# + its 2 call sites in setupWizard() + forceCleanRecreation().

$ curl -fsS "$PREVIEW/frontend_v1/js/campaign-wizard.${HASH}.js" > /tmp/served.js
$ gh api "repos/$REPO/contents/mvp_site/frontend_v1/js/campaign-wizard.js?ref=$HEAD_SHA" \
    --jq '.content' | base64 -d > /tmp/source.js
$ grep -n "applyUrlParams\|setupWizard\|forceCleanRecreation" /tmp/served.js /tmp/source.js
```

When line numbers shift by N between source and served, the served bundle is missing N lines worth of code from the area before the anchor. This is the strongest stale-bundle signal you can get without a SHA256 — and it's how PR #8790 was proven to have not been built from HEAD `913a306` (verified 2026-08-09).

Use this BEFORE assuming the bundle is from a recent but different commit. If the shift is small (e.g. <10 lines), the bundle might be from a near-ancestor commit. If the shift is large (e.g. 50+ lines) AND matches the size of the missing function block, the bundle is from a commit BEFORE the feature landed — same stale-bucket bug class as Phase 3 byte-count diff, but with a specific line-number witness.

### Phase 2.7 — CSS static-asset staleness (parallel to Phase 3 for JS)

The Phase 2 / 2.5 / 3 recipe is JS-bundle-focused (`auth.<hash>.js`, `app.<hash>.js`, etc.) and assumes the bug surface is hashed JS. **CSS files (`*.css`, both plain and content-hashed) can be equally stale** and CSS regressions are exactly the bug class that produces user-visible UI defects (avatar cut off, layout broken, theme not applied). The Phase 2 grep for "expected function string" does not catch CSS regressions because CSS does not carry function/string markers the same way. Add this check before declaring "preview is serving the latest build":

```bash
PREVIEW=https://mvp-site-app-s8-i6xf2p72ka-uc.a.run.app   # from Phase 1
HEAD_SHA=4994e53c50dfad212f070117c8964de8820db51e       # from PR head

# 1. Last-Modified header sanity — should be within hours of the deploy,
#    not days/weeks. `Last-Modified` is the canonical truth for served
#    asset freshness; the deploy CI's reported SHA is not.
for asset in frontend_v1/css/avatar.css frontend_v1/style.css; do
  lm=$(curl -fsSI -H 'Cache-Control: no-cache' "$PREVIEW/$asset" \
       | awk -F': ' 'tolower($1)=="last-modified"{print $2}' | tr -d '\r')
  printf "%-40s %s\n" "$asset" "$lm"
done

# 2. Byte-count vs source at the SAME HEAD SHA — served must be >= source
#    (served can be larger if minified; the rule is "served < source" = smoke gun).
for asset in frontend_v1/css/avatar.css frontend_v1/style.css; do
  src=$(gh api "repos/jleechanorg/worldarchitect.ai/contents/$asset?ref=$HEAD_SHA" \
        --jq '.size')
  served=$(curl -fsSI -H 'Cache-Control: no-cache' "$PREVIEW/$asset" \
           | awk -F': ' 'tolower($1)=="content-length"{print $2}' | tr -d '\r')
  printf "%-40s source=%s served=%s\n" "$asset" "$src" "$served"
done

# 3. Selector/rule-presence grep — does the served CSS contain the rule
#    the PR was supposed to add? (Pick a selector unique to the PR's diff.)
for asset in frontend_v1/css/avatar.css frontend_v1/style.css; do
  curl -fsS -H 'Cache-Control: no-cache' "$PREVIEW/$asset" \
    | grep -cE 'overflow-clip-margin|object-position: center 15%' \
    | xargs -I{} echo "$asset expected-rule count: {}"
done
```

**Decision rules (per Phase 2 / 3 conventions):**
- **`Last-Modified` > 24h before the deploy CI's reported deploy time** → strong staleness signal; the build container served an old image. Investigate Cloud Build cache + Dockerfile `COPY` step.
- **`served < source` for a CSS file at the same `head_sha`** → smoking gun, the build container copied an older version.
- **Selector grep returns 0 for a selector the PR added** → confirmed CSS regression from stale bundle, not a code bug.
- **All three checks pass** → CSS layer is fresh; if UI is still broken, the bug is in the served HTML/JS, not the CSS.

`cache-control: public, max-age=300, must-revalidate` on CSS is a 5-minute edge cache — `Last-Modified` proves the *origin* is stale, not just the edge. Always pair the `Last-Modified` check with `Cache-Control: no-cache` on the curl to bypass the edge.

NEVER hardcode a CSS path that the PR did not touch — pick the asset the PR's diff actually modified. For worldarchitect.ai specifically, `frontend_v1/css/avatar.css` and `frontend_v1/style.css` are the two highest-churn files in UI PRs.

### Phase 3 — Compare bundle byte-count vs source byte-count

If the source repo on the same `head_sha` is reachable via `gh api`:

```
# Source size
gh api "repos/{owner}/{repo}/contents/{path}?ref={head_sha}" --jq '.size'

# Served size
curl -fsSI "$PREVIEW/frontend_v1/{bundle}.{hash}.js" | grep -i content-length
```

A served bundle smaller than source (e.g. source 80,076 B vs served 79,034 B) is the smoking gun for a stale bundle. The build container copied a previous version. The byte delta approximates the lines added by the feature commit.

### Phase 4 — Capture Cloud Logging evidence (the HARD gate, run after Phase 2)

Exercise the events via headless Chrome (or via the synthetic `/api/client_diag` POST shortcut in `wa-cloud-logging-diag`) and capture Cloud Logging entries. Filter by Cloud Run `revision_name` so you scope to THIS PR's deploy only, not the shared `service_name`:

```
PREVIEW='https://mvp-site-app-s8-i6xf2p72ka-uc.a.run.app'
REVISION=$(gcloud logging read "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"mvp-site-app-s8\" AND labels.pr-number=\"<PR_NUM>\"" --limit=1 --project=worldarchitecture-ai --format='value(resource.labels.revision_name)' --freshness=2h | head -1)
echo "Revision: $REVISION"
gcloud logging read "resource.type=\"cloud_run_revision\" AND resource.labels.revision_name=\"${REVISION}\" AND jsonPayload.message:\"cdiag_name=\" AND (jsonPayload.message:\"signup.complete\" OR jsonPayload.message:\"signin.success\" OR jsonPayload.message:\"game.open\" OR jsonPayload.message:\"first_turn.begin\" OR jsonPayload.message:\"first_turn.outcome\")" \
  --limit=50 --project=worldarchitecture-ai --format=json --freshness=2h
```

Note: `safeDiag()` events log to `jsonPayload.message="[client_diag] cdiag_name=<evt>"`, NOT `jsonPayload.event_name`. The `jsonPayload.event_name=~"..."` shape returns 0 results and the `jsonPayload.event_name=~"cdiag_name=<evt>"` shape fails with a SYNTAX ERROR (gcloud's filter parser tokenizes the inner `=`). Use the `jsonPayload.message:"cdiag_name=<evt>"` colon-prefix form (no `=~`, no inner quotes). See `~/.smartclaw/skills/wa-cloud-logging-diag/` for the canonical WA project id (`worldarchitecture-ai`, NOT `worldarchitect-ai-prod`), session-id truncation, and synthetic-POST shortcut.

PASS condition (the HARD gate): all 5 expected event names appear in rows from `revision_name=REVISION` with `labels.commit-sha=PR_HEAD_SHA` and `labels.pr-number=PR_NUM`. Even when Phase 2 bundle grep returned 0 hits, Phase 4 PASS makes the deliverable GREEN.

### Phase 5 — Post evidence to thread + self-cancel

Post the verification result with **exact** byte-counts and grep counts (the numbers, not "looks good"). If launched via hermes cron, use `--at <duration> --delete-after-run --repeat 1` (one-time, never `--every`). Include the created cron job ID in the report.

## Pitfalls

### P1 — Trusting deploy job success

Deploy job reporting `status=success` + `image_tag=head_sha` does NOT mean the bundle is current. The Cloud Build `Created` log line and the Cloud Run `revision has been deployed` log line are both necessary but not sufficient. Always run Phase 2.

### P2 — Retrigger commits do not fix the bundle

A `chore(ci): retrigger pr-preview` commit on top of the feature commit can trigger a fresh deploy job — but if the build container cache-bust step is broken, the new job still produces a stale bundle. Retrigger is not verified. The 2026-08-06 PR #8787 incident is the canonical case study: see `references/stale-bundle-bug-case-study.md`.

### P3 — Skipping the bundle check + skipping Phase 4 is fabrication

If you post PASSED or smoke test PASSED while skipping BOTH Phase 2 (bundle grep) AND Phase 4 (Cloud Logging evidence), you have fabricated the result. This violates `proof-before-claim` (SOUL.md). The cron framework `--delete-after-run` flag is not an excuse to skip verification — it is the opposite, it means there will be no second chance to correct yourself.

If only Phase 2 passes and Phase 4 returns no events, post FAILED with the byte-counts and the empty-Cloud-Logging evidence (do not post a green PASS on bundle-only). If Phase 2 fails (bundle lacks a string) but Phase 4 shows events, post PASSED — the bundle content is a pre-flight signal, not the gate. Never post PASSED on bundle-only without Phase 4 corroboration.

### P4 — Thread routing when the channel is unexpected

The thread `ts` may be in a different channel than expected (e.g. #voyage `C0AUXSVFSA2` instead of #worldai `C0AH3RY3DK6`). `conversations.replies?channel=<expected>&ts=<thread>` returns `thread_not_found`. Recovery: `conversations.list` to enumerate channels, then probe each with `conversations.replies?channel=<c>&ts=<thread>` until one returns `ok:true`.

### P5 — Cache headers can mask staleness

Cloud Run serves `Cache-Control: public, max-age=31536000, immutable` for hashed bundles. A `curl` with default headers may return a stale cached body if you have previously hit the same URL. Pass `-H 'Cache-Control: no-cache'` (or `Pragma: no-cache`) on every verification curl, or use `curl --etag-compare ...` if the server emits ETags.

### P6 — `gh api` GraphQL rate-limit silent fallthrough

`gh pr view <N> --json ...` returns `GraphQL: API rate limit already exceeded` and exits 1. Fall back to REST: `gh api repos/{owner}/{repo}/pulls/{N}` and parse JSON manually. Check both REST and GraphQL buckets before assuming a request is not working.

### P7 — `bash -c 'source ~/.bashrc'` does not source bashrc in non-interactive shells

`bash -c '...' ` strips `.bashrc` because the shell is non-interactive. `SLACK_BOT_TOKEN` (and most other env vars) live in `~/.bashrc`, so a one-liner like `bash -c 'source ~/.bashrc; curl ... -H "Authorization: Bearer $SLACK_BOT_TOKEN"'` returns `invalid_auth` (token is empty at curl time). Use `bash -lc '...' ` (the `-l` flag triggers `.bash_profile` → `.bashrc` sourcing). Verified 2026-08-06 PR #8787: a `bash -c` Slack post reported `{"ok":false,"error":"invalid_auth"}`; switching to `bash -lc` resolved it. The `claude-code-claudem` skill's `bash -lic 'claudem -p "..."'` pattern uses this for the same reason. When the lib helper `~/.smartclaw/scripts/lib-slack-post.sh` is sourced inside `bash -lc` (login shell), it correctly finds `SLACK_BOT_TOKEN` via `bash -c 'source ~/.bashrc 2>/dev/null; echo -n "${SLACK_BOT_TOKEN:-}"'` (the helper itself sources bashrc explicitly) — but if you call `curl` directly inside your `bash -c`, do the same.

### P8 — `gcloud logging read` writes status/progress to STDERR — redirect before JSON-parsing

`gcloud logging read ... --format=json` prints the JSON array to STDOUT but prints rate-limit warnings, deprecation notices, and progress text to STDERR (e.g. `WARNING: ...`). When piping to `python3 -c 'import sys,json; ...'` without `2>/dev/null`, the json.loads fails with "Expecting value: line 1 column N" because the first byte of the combined stream is not `[`. Always redirect stderr before piping to a JSON parser: `gcloud logging read ... 2>/dev/null > /tmp/log.json; python3 -c 'json.load(open("/tmp/log.json"))...'`. Verified 2026-08-06 PR #8787 ticket — caught the parser error after one wasted tool call.

### P9 — Wrong service URL: `mvp-site-app-dev` is NOT a PR preview slot

The Cloud Run service naming convention encodes the deploy lane:
- `mvp-site-app-dev-…run.app` — **stable `dev` environment**, deployed from `main` (or whatever branch the dev lane tracks). NOT touched by PR preview workflow runs.
- `mvp-site-app-s<N>-…run.app` (where N is 1-9) — **rotating pool slots**, written to by the `Deploy PR Preview (Rotating Pool)` workflow. Each PR deploy gets a slot; once the slot is reused, the previous PR's image is replaced.
- `mvp-site-app-prod-…run.app` (if it exists) — production.

When the AI Terminal or any automation emits a "GCP Preview URL" for a PR, it MUST come from a `s<N>` slot, NOT `dev`. If you see `dev` in the URL, the URL is wrong — the deploy did NOT touch that service. Verified 2026-08-09 PR #8790: an AI Terminal post linked `mvp-site-app-dev-i6xf2p72ka-uc.a.run.app` but the PR's "Deploy PR Preview (Rotating Pool)" run wrote to `mvp-site-app-s5-…run.app` per the gh-actions bot comment.

**Recovery:** always resolve the active preview URL from the most recent `github-actions[bot]` comment on the PR:

```
gh api "repos/$REPO/issues/$PR/comments?per_page=10" \
  --jq '.[] | select(.user.login == "github-actions[bot]") | .body' \
  | grep -oE 'https://mvp-site-app-s[0-9]+-[a-z0-9-]+-uc\.a\.run\.app' \
  | head -1
```

If no `s<N>` URL is found in the bot comments, the PR was never deployed to a preview slot — fall back to `dev` only after explicitly warning the user that the bundle will not reflect the PR's commits.

### P10 — Runtime EMFILE: verification pipelines can exhaust file descriptors

When Phase 2 + Phase 3 + line-shift + Cloud Logging all run in one session, the cumulative `curl + grep + lsof + base64 + gcloud + chromium headless --remote-debugging-pipe` operations can hit the per-process fd limit (default `ulimit -n = 256` on macOS). Symptom: every subsequent `terminal`/`execute_code`/`write_file`/`read_file`/`browser_*` call returns `OSError: [Errno 24] Too many open files`, even for one-line commands like `echo hi`. The runtime is wedged until fd pressure clears.

**Recovery recipe:**
1. Stop issuing new tool calls immediately. Do not retry — each new call may further exhaust fds.
2. From a separate terminal OUTSIDE the agent: `pkill -9 -f chromium; pkill -9 -f chrome; sleep 2; lsof -nP -c chromium | wc -l` should drop to 0.
3. If still EMFILE, kill the agent session and start a new one. The fd pressure is per-session.
4. When resuming: serialize probes (one exec per tool call, no compound shell), avoid `lsof` (it opens many fds), prefer `curl ... | python3 -c '...'` over `curl + grep + jq + wc` chains, and never run `browser_navigate` followed by `browser_vision` in the same turn if a headless Chromium was opened — each `browser_vision` adds a screenshot pipe fd.

**Prevention:** if a smoke-test cron will run >10 tool calls, fork the verification into a `delegate_task` worker with its own fd budget. The parent session is then insulated from the worker's fd pressure.

Verified 2026-08-09 PR #8790 verification session: hit `EMFILE` after 12 verification calls, lost ability to post the result to Slack, had to surface the verdict inline in the assistant reply instead.

### P11 — "Preview is serving the latest build" is a PASS claim that requires Phase 2 evidence

Phrases like *"the preview server is serving the latest build including all fixes"*, *"app-sN has the fix"*, or *"the deploy went through"* are all **delivery verdicts** that must be backed by at least one of: (a) a bundle-content grep returning the new function/string with non-zero count, (b) a served-vs-source byte-count diff that matches the expected delta, or (c) Phase 4 Cloud Logging events from the matched `revision_name` with matching `labels.commit-sha` and `labels.pr-number`. **The github-actions[bot] comment that posted the preview URL is NOT evidence** — it is a deploy job that reported `success`, which the existing P1 / P3 pitfalls already say is necessary but not sufficient.

The 2026-08-12 PR #8808 incident is the canonical example: the agent told Jeffrey *"the preview server is serving the latest build including all fixes: <https://mvp-site-app-s2-i6xf2p72ka-uc.a.run.app>"* in the same Slack thread as today's correction (C0AH3RY3DK6/ts=1786415501). That claim was wrong. The bundle MD5 `9ccb03eea2b0da9341bbac6820378975` was identical on `s2`, `s6`, and `s8`, and the deployed `campaign-wizard.9ccb03ee.js` contained **zero** references to `applyUrlParams`, `window.location.search`, or `URLSearchParams` — the exact function PR #8808 added 108 lines to introduce. Jeffrey noticed the bug visually on mobile 4 hours later; the correction was forced by his screenshot post, not by Phase 2 verification.

**Concrete test before posting any "preview has the fix" line:**

```
# 1) Resolve the live bundle hash from index.html — never hardcode
HASH=$(curl -fsS "$PREVIEW/" | grep -oE 'campaign-wizard\.[a-f0-9]+\.js' | head -1 | cut -d. -f2)

# 2) Grep for the feature marker — must be >= 1, never 0
curl -fsS "$PREVIEW/frontend_v1/js/campaign-wizard.$HASH.js" \
  | grep -cE 'applyUrlParams|window\.location\.search|URLSearchParams'

# 3) If the count is 0, the deploy did NOT land. Do NOT post PASS.
#    Post :red_circle: with the byte-count + grep evidence and ask
#    the user whether to retrigger the deploy workflow.
```

If you cannot run that grep (no `curl`, no preview URL, restricted environment), **do not post the PASS claim**. Post "preview verification deferred — no bundle-layer evidence yet" and ask the user to run the grep, or dispatch a claudem worker to do it. The cost of admitting "I haven't verified" is one extra turn; the cost of a fabricated PASS is a 4-hour debug loop with a confused user.

### P12 — Login-overlay hides the wizard DOM; screenshot is not verification

`/new-campaign` and `/shared/<token>` URLs hit an auth gate on first visit when the user is unauthenticated: the SPA renders the Google sign-in card on top of the page, and the wizard DOM exists **behind** the overlay (try `document.querySelector('#wizard-campaign-title')` from the console — the input is there, just hidden). A Playwright screenshot at 390x844 of an unauthenticated session will show ONLY the login card with "Continue with Google". This is **not** proof that the prefill fix is broken.

The correct verification path for prefill URLs:

```
# DOM probe is the source of truth — not the screenshot
page.goto(URL, wait_until="networkidle")
# Sign in via Firebase auth OR via cookie injection OR via test-only token
# THEN visit the wizard URL — params should now populate inputs.
page.wait_for_timeout(2000)
title = page.eval_on_selector("#wizard-campaign-title", "el => el.value")
assert title == EXPECTED, f"prefill failed: got {title!r}"
```

If you cannot sign in headlessly (no Firebase creds, no test token), the **fallback** is to confirm the fix landed via bundle-layer grep (Phase 2 — `applyUrlParams` presence in `campaign-wizard.<hash>.js`) and report the DOM-level prefill verification as a follow-up requiring a real browser session. **Never claim "the bug is real, prefill doesn't work" based on a screenshot of the login screen alone.** That is the same fabrication pattern as P11, just inverted: a screenshot of the login card proves nothing about prefill behavior.

Verified 2026-08-12 PR #8808: the mobile 390x844 screenshot showed only the "Continue with Google" card with NO wizard visible, and the DOM query for `#wizard-campaign-title` returned `value="My Epic Adventure"` (the placeholder, not the prefill). The user-facing screenshot alone would have been ambiguous — the DOM probe was what proved the input was empty of prefill values.

### P13 — CSS static assets can be stale too (verified 2026-08-18, PR #9042)

The Phase 2 / 2.5 / 3 recipe is JS-bundle-focused. CSS files (`*.css`, both plain and content-hashed) can be equally stale, served with `Last-Modified: <old date>` despite a fresh deploy reported by the GH Actions bot. The Phase 2 string-grep does not catch CSS regressions because CSS does not carry function/string markers the recipe greps for. PR #9042 was the canonical case: the user posted a screenshot 30+ minutes after the deploy showing the avatar cut off — the served `avatar.css` and `style.css` both had `Last-Modified: Sat, 04 Jul 2026 18:53:10 GMT`, were 778 B and 19 453 B smaller than the repo HEAD versions respectively, and lacked the `overflow-clip-margin: 56px` rule the PR added. The user had to file the bug visually before the staleness was caught.

Detection rule: when an inbound UI screenshot shows a defect that the PR's source code claims to fix, **do not trust the deployed bundle**. Run Phase 2.7 (`Last-Modified` header + byte-count vs source at the same `head_sha` + selector-presence grep) before declaring the source code has the regression. Stale CSS / JS bundles are the single most common false-positive "the PR didn't fix it" report in the WA project.

### P14 — Inbound UI screenshot during a PR review cycle IS a deployment-verification signal

The original trigger surface for this skill was a smoke-test cron, a babysit tick, or a manual `/green` request. PR #9042 surfaced a new trigger that the skill did not previously catalog: **the user posts a screenshot of the deployed UI during an inbound-evidence review (per `pr-evidence-inbound-review`) and asks "why is X still wrong?"** That screenshot is a deploy-verification artifact in disguise — if it shows the PR's documented fix NOT applied, the deploy is stale and the source code is fine. Load this skill proactively when:

1. User posts a Slack message with an inbound UI screenshot AND the PR body claims a specific UI change (e.g. "avatar no longer clipped", "submit-triggered collapse", "iOS zoom removed").
2. User asks "why is the image still cutoff" / "why is the layout still broken" / "this doesn't look like the fix" / any "the PR's claim doesn't match what I see" framing.
3. Inbound-evidence review (`pr-evidence-inbound-review`) finds the PR body already references the same SHA the user's media is tagged with — Step 7 confirms body-has-evidence, but Step 7 does NOT confirm the deployed bundle matches the source.

Do not wait for the user to file a separate bug report 30+ minutes later. Run Phase 2 + Phase 2.7 in the SAME turn as the inbound-evidence review when any of the above triggers fire. The cost of catching staleness in the same turn is one extra `curl` + `gh api` call; the cost of missing it is a confused user debugging "the fix" for half an hour before realizing the deploy never landed. Cross-ref `pr-evidence-inbound-review` Pitfall 11 (added 2026-08-18) for the inbound-side discipline.

### P9 (refinement, 2026-08-12) — The rotating pool shares ONE image, not per-slot

When you find a stale bundle in one slot (say `s8`), check the other live slots **before declaring the bug slot-specific**. If `s2`, `s6`, and `s8` all serve identical bundle MD5s, the build pipeline produced one image and the rotating pool wrote it to all three slots — the bug is pool-wide, not slot-specific, and "redeploy to s8" will not fix it. Recovery: investigate the build container / Cloud Build cache layer (Dockerfile `COPY` step, layer-cache key) at the workflow level, not at any individual slot. Verification:

```
# After finding a stale bundle at $PREVIEW, scan sibling slots
for slot in s1 s2 s3 s4 s5 s6 s7 s8 s9 s10; do
  host="https://mvp-site-app-$slot-i6xf2p72ka-uc.a.run.app"
  hash=$(curl -fsS --max-time 12 "$host/" 2>/dev/null \
         | grep -oE 'campaign-wizard\.[a-f0-9]+\.js' | head -1)
  [ -n "$hash" ] && echo "$slot: $hash"
done
# If all hashes match, it's one stale image — escalate to build pipeline, not the slot.
```

Verified 2026-08-12 PR #8808: `s2`/`s6`/`s8` all served `campaign-wizard.9ccb03ee.js` with identical MD5 `9ccb03eea2b0da9341bbac6820378975` (verified byte-for-byte via `md5`). `s10` served a different hash (`a8cf6e95.js`) and `worldarchitect.ai` production served yet another (`7e28a7f8.js`) — so the share is partial, not absolute, and per-slot checks are still worth running.

## Verification script

Reusable bundle verification script: `scripts/verify-bundle.py` (runs Phase 2 + Phase 3 checks against a preview URL and expected strings; return-code semantics aligned with the gating model above):
- exit 0: every expected string found in at least one bundle.
- exit 1: at least one expected string NOT found (PRE-FLIGHT signal — not a hard failure; Phase 4 may still PASS).
- exit 2: source/served size mismatch (suspicious — investigate if Phase 4 also fails; cite as investigation note if Phase 4 passes).
- exit 3: 4xx/5xx from the preview URL (network or deploy unhealthy).

Invoke as:

```
python3 scripts/verify-bundle.py \
  https://mvp-site-app-s8-i6xf2p72ka-uc.a.run.app \
  signup.complete signin.success game.open first_turn.begin first_turn.outcome \
  --source-check jleechanorg/worldarchitect.ai mvp_site/frontend_v1/auth.js 0a9d234ab
```

The script's exit code is a pre-flight signal, not the smoke-test verdict. The verdict is determined by Phase 4 (Cloud Logging events with matching revision labels). On exit 1, do not panic — proceed to Phase 4 and let the end-to-end evidence decide.

## Case study

Full reproduction transcript of the 2026-08-06 stale-bundle incident (PR #8787) — including the byte-count diff, the `safeDiag()` event list, the previous-tick fabricated PASS messages, and the corrected PASSED-with-note post — is in `references/stale-bundle-bug-case-study.md`. Read it before declaring a smoke test PASS without running Phase 4. The case study demonstrates the case where Phase 2 fails (served `auth.433593ec.js` lacks the 5 safeDiag calls even though the source blob `2a3b9478` at HEAD `0a9d234` contains them) and Phase 4 still passes (all 5 events captured in Cloud Logging from revision `mvp-site-app-s8-04177-rgd` with `labels.commit-sha=0a9d234`, `labels.pr-number=8787`). Verdict: GREEN with the bundle mismatch cited as an investigation note for the worker (Docker layer cache / build pipeline).

CSS-staleness reproduction (2026-08-18, PR #9042 — avatar.css + style.css served 45 days stale despite fresh `deploy-preview` SUCCESS) is in `references/2026-08-18-pr-9042-stale-css-case-study.md`. Read it before declaring "preview is serving the latest build" on any PR that touches CSS, layout, theme, or visual CSS contract.
