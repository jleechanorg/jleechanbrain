# Real-browser smoke test (stronger proof — use only when the synthetic POST is not enough)

The `wa-cloud-logging-diag` SKILL.md covers the **synthetic POST short-circuit** (POST `/api/client_diag` directly with the 5-event batch → 204 → Cloud Logging captured). That is the **default** smoke test for PR-preview instrumentation: it proves the events reach Cloud Logging without needing a real user, a real browser, or a real LLM call. ~5 seconds.

This reference covers the **real-browser smoke test** — only use when:

1. The user/operator explicitly asked for "real" proof (e.g. "drive it as jleechan@gmail.com", "no fake POSTs").
2. The PR added a `safeDiag` call whose `fields` payload is **derived from real backend state** that the synthetic POST cannot fake (e.g. `latency_ms` from a real Gemini streaming call, `story_length_after` from a real Firestore write).
3. A previous cron already used the synthetic POST and the operator wants stronger evidence before signing off the PR.

The real-browser path takes ~3 minutes vs ~5 seconds for the synthetic POST, costs real Cloud Run LLM compute, and depends on Aside CLI / Firebase auth being healthy.

## When to use which

| Need | Use |
|---|---|
| "Did the safeDiag events land?" (default) | Synthetic POST in `wa-cloud-logging-diag` SKILL.md |
| "Did they fire with REAL backend-derived fields (real LLM latency, real story length)?" | This reference |
| "Did they fire under a REAL Firebase-authenticated user session with real UID?" | This reference |

## Headless Aside CLI recipe (verified 2026-08-06 PR #8787, real-browser follow-up)

### Prerequisites

- `aside account list` shows `* u0 jleechan@gmail.com  signed in  profiles: Profile 0`. If not, `open -a "/Applications/Aside.app" && sleep 3`.
- `gcloud` auth active for `worldarchitecture-ai` project (the only project with these logs).
- Preview URL known (pull from the latest `github-actions[bot]` "Deployment Complete!" comment on the PR — the URL format is `https://mvp-site-app-s<N>-<hash>-uc.a.run.app`).
- The bundle hashes are NOT hardcoded — pull them fresh from `<preview>/` first.

### The flow (one REPL call — see Aside caveat below)

```js
// All steps MUST be in one aside repl invocation — see "Aside CLI caveats"
const PREVIEW = 'https://mvp-site-app-s8-i6xf2p72ka-uc.a.run.app';
const sleep = (ms) => new Promise(r => setTimeout(r, ms));

// 1. Open the preview as an authenticated user (Aside profile 0 = jleechan@gmail.com)
const page = await openTab(`${PREVIEW}/`);
await sleep(2500);

// 2. Install safeDiag hook IMMEDIATELY (see "Aside CLI caveats" — openTab wipes prior hooks)
await page.evaluate(() => {
  window.__diagFired = [];
  const orig = window.safeDiag;
  window.safeDiag = (name, level, fields) => {
    window.__diagFired.push({name, level, fields, ts: Date.now()});
    return orig ? orig(name, level, fields) : undefined;
  };
});

// 3. Drive the funnel (this is the WA-specific sequence)
await page.click('#go-to-new-campaign');     // → /new-campaign
await sleep(1000);
await page.click('#wizard-dragon-knight-campaign'); // pick a template
await sleep(200);
await page.click('#wizard-next');            // → step 2 (Launch)
await sleep(800);
await page.click('#launch-campaign');        // → /game/<id>
await sleep(10000);                          // wait for resumeCampaign + game.open

// 4. Submit the first turn (streaming interaction)
await page.locator('#user-input').first().fill('I cautiously approach the dragon shrine.');
await sleep(500);
await page.locator('button:has-text("Send")').first().click();

// 5. Poll until first_turn.outcome fires (LLM can take 20-60s)
for (let i = 0; i < 18; i++) {
  await sleep(5000);
  const state = await page.evaluate(() => ({
    loading: document.body.innerText.includes('Loading') ||
             document.body.innerText.includes('thinking'),
    funnel: (window.__diagFired || [])
      .filter(e => ['signup.complete','signin.success','game.open',
                     'first_turn.begin','first_turn.outcome'].includes(e.name))
      .map(e => e.name)
  }));
  if (!state.loading && state.funnel.includes('first_turn.outcome')) break;
}

// 6. Read the captured events
const captured = await page.evaluate(() => {
  const names = ['signup.complete','signin.success','game.open','first_turn.begin','first_turn.outcome'];
  return (window.__diagFired || [])
    .filter(e => names.includes(e.name))
    .map(e => ({name: e.name, fields: e.fields, ts: e.ts}));
});
console.log(JSON.stringify(captured, null, 2));
```

### Verifying via Cloud Logging

After the run, wait ~30 seconds for ingestion, then query for the 5 events tagged with the same `pr-number`:

```bash
PR_NUMBER=8787
PREVIEW_SERVICE=mvp-site-app-s8

for evt in signup.complete signin.success game.open first_turn.begin first_turn.outcome; do
  count=$(gcloud logging read \
    "resource.labels.service_name=\"${PREVIEW_SERVICE}\"
     AND jsonPayload.message=~\"cdiag_name=${evt}\"
     AND labels.pr-number=\"${PR_NUMBER}\"" \
    --limit=20 --project=worldarchitecture-ai --format='value(timestamp)' 2>&1 | wc -l | tr -d ' ')
  echo "  ${evt}: ${count}"
done
```

A real-browser run that lands 1× each of `signup.complete` and `signin.success`, ≥1× `game.open`, ≥1× `first_turn.begin`, and ≥1× `first_turn.outcome` is **PASSED**.

## Aside CLI caveats (verified 2026-08-06)

1. **`openTab` wipes JS state** — each `openTab()` returns a new `page` backed by a fresh JS execution context. Hooks installed via `page.evaluate()` in a previous REPL call are gone. Always re-install hooks AFTER `openTab()` within the SAME REPL eval block.
2. **`aside repl` is one-shot** — every `aside repl "..."` invocation is a fresh Node process. State (variables, page refs, `window.__diagFired`) from one invocation does NOT survive into the next. Multi-step flows must be in one eval.
3. **Aside daemon can flake on long page lifetimes** — after ~60s of REPL polling, the daemon occasionally returns "Aside daemon is not reachable — make sure Aside Browser is running, then retry." The daemon PID is usually still alive (`pgrep -fl "Aside Daemon"` shows it). Recovery: `sleep 5; aside account list` — it comes back within seconds.
4. **`aside repl` CLI stubs `listBrowserTabs`/`attachBrowserTab`/`attachActiveBrowserTab` as empty objects** — per existing memory. If you need multi-tab state, use the HTTP MCP at `http://127.0.0.1:8013/mcp` with `mcp-session-id` header, OR keep everything in one `openTab()` call.
5. **The `aside "..."` NL agent (no `repl`) requires credits** — got `Error 402 "Insufficient credits"` on first attempt. Use the REPL path for programmatic flows.

## Pitfalls specific to the real-browser path

- **Don't navigate to `/game/<id>` directly via `openTab` if you also want `game.open` to fire** — `game.open` is emitted inside `resumeCampaign` only when the campaign page is loaded through the wizard launch flow, not on a hard reload. The hook will catch events only if the funnel goes through `/new-campaign` → `wizard-next` → `launch-campaign`.
- **The "Loading..." spinner can stick after Cancel** — if the streaming interaction hangs, click `#cancel-interaction-btn` before re-submitting. Otherwise the next turn sits queued behind the cancelled one.
- **`first_turn.outcome` requires the full streaming completion** — the event fires in the regular AND streaming handlers on completion (`status` field comes from the response). If you click Send and then close the tab/REPL before the LLM stream finishes, you get `first_turn.begin` but never `first_turn.outcome`.
- **The `safeDiag` hook captures client-side only** — Cloud Logging is the source of truth. The hook helps debug what fired, but the verification gate is `gcloud logging read` on `cdiag_name=<event>` matching the expected counts.

## When this was last verified

- 2026-08-06 PR #8787 smoke test cron — drove the full funnel as `jleechan@gmail.com` (uid `vnLp2G3m21PJL6kxcuAqmWSOtm73`) via headless Aside CLI. Captured all 5 events in both the in-page hook AND Cloud Logging. `first_turn.outcome` payload: `campaign_id=rUI6fHv7VuKN8zjtwd9e, status=200, story_length_after=6, latency_ms=22545` (real Gemini streaming call, ~22s).
- Slack thread: `C0AH3RY3DK6/1785999999.099119` (the real-browser follow-up).
