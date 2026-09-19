# Transport-ladder-failure-log-2026-08-19

Third-consecutive-day verification of the same /web-advice transport-ladder fingerprint on the same macOS 15.5 Chrome 151 baseline.

**Session:** Slack thread `C0BDEAJH8PK/p1787172968.325109` (Jeffrey → Hermes → "Why is it 200KB? I thought we use pagination?")
**Task dispatch:** /web-advice 4-rung probe as second-opinion on the mvp-site-app-dev `ArYA47Fvx8HTYC8jpleO` rendering-lag root cause.
**Worker:** `deleg_0dc7c883` (claude/minimax-M3 leaf subagent).

## Outcome

**0 of 4 rungs reachable. Agent correctly STOPPED per §1.**

| Rung | Probe | Result | Compared to baseline |
|---|---|---|---|
| 3 (CDP :9222) | `lsof -nP :9222` + `curl -fsS -m 5 http://127.0.0.1:9222/json/version` | DOWN — `lsof` empty, `curl` returns HTTP 404 (port-bind missing). | Identical to 2026-08-17 + 2026-08-18 baselines. |
| 4a (visible) | `browserclaw cookies inject --print-text 100000 --screenshot /tmp/gemini_page.png --cookies <...> --goto https://gemini.google.com/app` | Not the failure shape seen today. | n/a |
| 4b (silent-hang) | Same `browserclaw cookies inject` command — exit 0 + zero stdout + zero screenshot file. With `timeout 60` killed at 60s; without, hangs until 180s tool exit-124. Cookie JSON validated correctly (90 Google cookies including `__Secure-1PSID`/`OSID`). | DOWN — anti-bot held the chromium process silently. | **NEW shape** — 2026-08-17 only saw the visible "Just a moment..." / "Sign in" outcome, not the silent-hang-without-output shape. |
| Aside | `which aside` confirmed binary at `${HOME}/.local/bin/aside`; no live-tab probe attempted because CDP was already down. | skipped (would require operator browser pre-population) | n/a |

## Key signals that were correctly acted on

1. **Arg-type trap hit first run.** Worker ran `browserclaw cookies inject --print-text /tmp/gemini_page.txt` and got `argument --print-text: invalid int value`. Fixed to `--print-text 100000 --screenshot /tmp/gemini_page.png`. **Worth capturing in SKILL.md pitfalls** (done).
2. **Silent-hang ≠ success recognized.** Worker noted "exit 0 + zero stdout + zero screenshot file... the command may have exited before printing diagnostics" and then escalated to running without `timeout` wrapper — which hit the 180s tool timeout. **Worth capturing in SKILL.md pitfalls** (done; see "browserclaw silent-hang ≠ success").
3. **§1 STOP honored.** Worker did NOT synthesize a fake vendor consensus. Did NOT substitute web_search / web_extract. Did NOT escalate to a provider API. Posted the ladder-down report and proposed ONLY the operator-action unblocker (Chrome Remote Debugger Connect click + open vendor sites in operator's browser for Aside pre-population).
4. **Source diagnosis was already solid without /web-advice.** The agent's read of `mvp_site/firestore_service.py:1119-1188` (`_inventory_item_signature` is whole-item `json.dumps` → near-duplicates with field differences slip past) was correct, had a clear fix surface, and did not depend on the vendor panel for confirmation.

## Why this is the third confirmation that matters

The 2026-08-17 baseline was "first sighting." The 2026-08-18 baseline was "second day, same fingerprint, helps confirm operator-action-only." The 2026-08-19 run is the third consecutive day — that converts the observation from "transient" to "durable baseline." Every future /web-advice invocation should treat this as the floor state until the operator flips Chrome Remote Debugger Connect or the browserclaw team ships a fingerprint that passes Cloudflare.

## New pitfall captured (2026-08-19)

**`browserclaw cookies inject` arg types trap.** `--print-text` takes an INTEGER (character count), NOT a path. Passing a path returns `argument --print-text: invalid int value`. Quick check before running: `--print-text 100000 --screenshot /tmp/$(date +%s).png`.

**`browserclaw` silent-hang ≠ success.** Exit-code 0 + zero stdout + zero screenshot file does NOT mean the inject worked — it means the headless chromium process didn't return. Always verify with `ls -la /tmp/<v>.png` after `INJECT_EXIT=0`; missing file = rung 4 silent-hang, treat as DOWN. Kill the process with `pkill -f playwright_chromiumdev` before starting the next probe.

## What WOULD unblock /web-advice on this machine

1. Operator clicks **Connect** on the Chrome Remote Debugger extension (flips rung 3 green).
2. Operator opens chatgpt.com / gemini.google.com / grok.com / perplexity.ai in their own browser (flips rungs 1-2 via Aside cookie scrape).
3. Alternative: launch a SEPARATE Chrome with `--user-data-dir=/tmp/something-new` + `--remote-debugging-port=N` — gets CDP, but does NOT inherit operator cookies, so will not log into Google / ChatGPT / Grok.

Without one of these three, /web-advice is permanently DOWN on this Mac until upstream fixes (Chrome Remote Debugger extension auth, browserclaw anti-bot fingerprint).
