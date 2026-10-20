# Transport-ladder failure log — 2026-08-19c (worldarchitect.ai `ArYA47Fvx8HTYC8jpleO` root-cause review)

**Task:** /web-advice second-opinion dispatch on a worldarchitect.ai user's
report of slow iPhone load (iOS 26.6 Chrome) on campaign
`ArYA47Fvx8HTYC8jpleO`, GCP logs `mvp-site-app-dev` GET
`/api/campaigns/ArYA47Fvx8HTYC8jpleO?story_limit=50` returning 200-559KB
payloads, `TypeError: Load_failed` at 0-1ms latency on iOS Safari,
`player_character_data.equipment.backpack` containing duplicate items
(Frostmourne 3× at bonus=2/+3/+4, Backpack listed twice). Hypothesis:
equipment-write code does append-without-dedupe.

**Probe time:** 2026-08-19T22:53Z – 2026-08-19T22:54Z (host: macOS 15.5,
Aside CLI 1.26.818.x)

## Ladder state — verbatim

| Rung | State | Verbatim evidence |
|---|---|---|
| 1 (Aside daemon) | UP | e2e_smoke: "2 account(s) signed in" |
| 2 (Aside browser window) | UP but UNSAFE | e2e_smoke: "8 tab(s) currently open". `listBrowserTabs()` returns Promise of 8 tabs (operator-relevant work: 2× Gemini, 2× TaxDome, 1× EDD, 1× mvp-site game session, 1× Morgan Stanley login, 1× Google search). Per skill §1b: window-full → STOP. |
| 3 (Chrome CDP :9222) | DOWN | `lsof -nP :9222` → empty. `curl -fsS -m 5 http://127.0.0.1:9222/json/version` → HTTP 404. Identical to 2026-08-17 / 2026-08-18 / 2026-08-19a baselines. |
| 4 (browserclaw chromium --headless) | DOWN (silent-hang shape, 4b) | Cookie decrypt PASS: `browserclaw cookies decrypt --db "...Chrome/Default/Cookies" --domain-filter "%google.com%"` → 90 cookies including `__Secure-1PSID`, `__Secure-3PSID`, `OSID`, `__Secure-OSID`. Headless inject HUNG: `browserclaw cookies inject --cookies <json> --goto https://gemini.google.com/app --browser-channel chromium --headless --wait-after-load 15000 --screenshot /tmp/<v>.png --print-text 3000` → exit 143 (SIGTERM at 90s), stdout=0 bytes, stderr=0 bytes, screenshot file=0 bytes, page text=NONE. Same fingerprint-fail mode as 2026-08-17 baseline. e2e_smoke rung-4 reports UP (cookie-DB presence, ~917K) — false-confidence; empirical probe shows the inject actually fails. |

## What was NOT done (intentional, per skill)

- Did NOT bounce Chrome (`killall`, `osascript quit`) to flip rung 3 green.
  Skill pitfall explicit: operator-action cost > agent-time saved.
- Did NOT call `openTab()` in the only Aside window. Window contains 8
  unrelated operator tabs (incl. active mvp-site game session at
  `mvp-site-app-s6-i6xf2p72ka-uc.a.run.app/game/Mz4s5zy30noDnSgScPJH`);
  hijacking would corrupt operator state.
- Did NOT substitute Gemini-Vertex-AI bearer-token call as a "second
  opinion". `gcloud auth print-access-token` returns a valid bearer; the
  Vertex `gemini-2.5-flash:generateContent` endpoint is reachable per
  `gemini-vertex-fallback` skill. Per §1: provider APIs are banned
  substitutes even with disclosure. STOP.

## New lessons from this session

### 1. `listBrowserTabs()` returns Promise, not array

Bare call:

```js
listBrowserTabs().map(...)   // TypeError: ... is not a function
```

Working call:

```js
const tabs = await listBrowserTabs();
console.log("count:", tabs.length);
tabs.forEach((t, i) => console.log(i, t.url, t.targetId));
```

Proto is `Promise` (not Array). Property access on each tab
(`t.url`, `t.targetId`, `t.title`) — not method calls. Caught when the
contract example in §2 of the skill failed on first invocation. Patched
into SKILL.md §2.

### 2. `e2e_smoke.sh` rung-4 false UP

The smoke script's rung-4 check verifies Chrome Cookies SQLite file is
present and ≥ some byte threshold (~896K). It does NOT verify the
headless chromium path actually navigates and lands on the vendor site.
The 2026-08-19c probe found:

- `e2e_smoke` reported: "3 of 4 rungs UP"
- Empirical rung-4 inject: silent-hang, exit 143, zero diagnostics,
  zero screenshot, zero page text

Net effective ladder state for vendor probing: **0 of 4 usable**, not
3 of 4. The smoke probe is necessary but not sufficient. Patched into
SKILL.md §5 with explicit "always run the empirical rung-4 probe"
caveat.

### 3. `browserclaw cookies inject` arg-types trap

- `--cookies <path>` — path to JSON
- `--goto <url>` — URL
- `--browser-channel <chrome|chromium>` — channel name
- `--wait-after-load <seconds>` — int
- `--screenshot <path>` — path
- `--print-text <int>` — int (character count), **NOT a path**

Passing a path to `--print-text` returns
`argument --print-text: invalid int value` and the inject never runs.
Quick check: `--print-text 100000 --screenshot /tmp/$(date +%s).png`.

Patched into SKILL.md pitfalls. (Note: this was already partially
captured in the 2026-08-19 pitfall row — confirmed reproduction
2026-08-19c.)

### 4. Silent-hang ≠ success

Exit-code 0 + zero stdout + zero screenshot file does NOT mean the
inject worked. It means the headless chromium process didn't return
(anti-bot hold). Always `ls -la /tmp/<v>.png` after `INJECT_EXIT=0`;
missing file = rung 4 silent-hang, treat as DOWN. Kill the process with
`pkill -f playwright_chromiumdev` before starting the next probe or
you'll accumulate zombie chromium helpers. Patched into SKILL.md
pitfalls.

## Question 4 from the dispatch — compaction vs equipment bloat

The dispatch asked: "Capture the BQ-cache-hit and Story_context_compacted
relationship: long-context compaction is triggering on every turn
(210K -> 95K, 95K -> 95K, 211K -> 95K) — is this an unrelated cause of
slowness or downstream of the equipment bloat?"

**Not verified on a live vendor probe (transport ladder DOWN).**

Code-side read of `mvp_site/game_state.py:700-764` (equipment.backpack
list normalization, no dedupe by item name) + `mvp_site/world_logic.py:1290-1370`
(loot/applied rewards to player_character_data) + `mvp_site/rewards_engine.py:1460-1620`
(loot_items str-stripped list, no dedupe):

**Hypothesis A (downstream of equipment bloat) — more parsimonious:**
Equipment duplication (Frostmourne × 3 + Backpack × 2 ≈ 5 extra
entries) bloats the serialized `player_character_data` that gets
re-injected into the prompt each turn. The 559KB GET payload is
consistent with 5–10× payload bloat from ~5 duplicate items each
carrying nested stats. Once prompt size crosses a threshold,
compaction fires; next turn the bloat is still there, so compaction
fires again even though "net" context looks unchanged.

**Hypothesis B (unrelated upstream cause):** Compaction keyed on turn
index / time-since-last-compact / stale flag — independent of payload
size. The 95K→95K stable plateau especially suggests a keyed trigger
rather than a size trigger.

**Discriminator (not run):** Instrument one turn with
`len(json.dumps(player_character_data))` before and after compaction.
If A is true, post-compact token count drops by ~the size of the
duplicated equipment entries. If B is true, compaction reduces an
unrelated region (system prompt, scene memory, tool results) and
equipment size is unchanged.

**Frame for the operator:** This is a code-side read, not a vendor
consensus. Treat as "unverified correlation, propose falsification
test."

## Final report shape

The agent correctly STOPPED per §1 and emitted:

1. e2e_smoke output (verbatim)
2. Per-rung state table (UP/DOWN with detail)
3. For each DOWN rung: exact failed probe + observed error + last-good date
4. Per-site cookie-inject attempt result (URL, page title, body excerpt)
   for any headless fallback attempt
5. Single concrete next action: "open a fresh, empty Aside window
   (Cmd-N) and leave it idle"
6. NO multi-option menu

Did NOT produce the 250-word root-cause review as a vendor consensus
(no vendor probe ran). Flagged the compaction-vs-bloat question as
unverified, with a falsification test the operator can run.
