# `is:saved` Slack triage — the "Saved for later" backlog

Session reference: 2026-08-18 (Jeffrey asked "go through all our slack reminders and see what's still unresolved/important").

## What `is:saved` actually is

It's the **Slack right-click → "Save for later"** feature, NOT the `/remind` Reminders app. Searchable via `search.messages` with `query: 'is:saved'`. The operator's workspace (`T09FXQ4LCQP`) returned **619 items** — all from 2026, none before. Distribution is heavily `#worldai` (25%) + `#all-jleechan-ai` (27%) + `#ai-general` (11%).

**Don't confuse with:**
- `reminders.list` API → returns the `/remind` Scheduled Reminders app (always returned 0 for this user).
- `conversations_mark` → marks a single message as read.
- `stars.list` → starred items (separate filter `is:starred`).

## Aside REPL cursor pagination — broken

**Verified (2026-08-18, 5+ retries):** `client.search.messages({..., cursor: r.messages.paging.pages})` returns **`An API error occurred: internal_error`** from Aside's REPL on every page-2+ attempt. The cursor is structurally valid (page 1 returns a real cursor token, total=619) — Aside's WebClient proxy corrupts it.

**Workaround that actually works: date-range partitioning.**

```js
// Aside REPL — works reliably
const r = await client.search.messages({
  query: 'is:saved after:2026-07-14 before:2026-08-19',
  count: 100, sort: 'timestamp', sort_dir: 'desc'
});
console.log('total:', r.messages?.total);   // 84 for that window
console.log(JSON.stringify(r.messages.matches.map(m => ({
  ts: m.ts, user: m.user||m.username,
  channel: m.channel?.name, channel_id: m.channel?.id,
  thread_ts: m.thread_ts,
  text: (m.text||'').slice(0, 200)
}))));
```

**Dedup across windows:** each match carries a stable `ts` (message id); union by ts set works even when date filters overlap.

**Hard cap:** Slack's `search.messages` caps at `count: 100` per call. With cursor pagination broken in Aside, partition dates until each window returns ≤ 100, then union.

**Coverage:** with cursor broken, you cannot get the full N if any single window exceeds 100. In our session: 619 total → 597 unique fetched (96.4%) → 22 missing from a 100-cap window that was hard to slice narrower without overlap. Document the missing count and stop; do NOT pretend full coverage.

## Aside REPL filesystem access — none

**Verified:** `require('fs')` throws `External modules are not available in the REPL`. Likewise `require('node:fs')`, `require('path')`, etc.

**Workarounds:**
1. **Shell redirect from terminal**: `aside repl "console.log(JSON.stringify(arr))" 2>&1 > /tmp/file.json` captures stdout. Use `2>&1` to also catch Aside's `[ok | Nms]` and `[error | Nms]` markers — they end up at the END of the file (so a JSON array line at the start is parseable with `json.loads(lines[0])` if the array is single-line).
2. **`localStorage.setItem('hermes:saved', JSON.stringify(arr))`** + read back. Works but localStorage is per-origin and lost when Aside clears site data.
3. **Print in chunks** via `console.log(JSON.stringify(slim.slice(0,30)))` + repeated calls. Slow.

The shell-redirect path is the most reliable for > 5 KB payloads.

## Categorization heuristic (FINISHED / REVISIT / HUMAN)

After collecting all `is:saved` matches, classify each into one of three buckets:

| Bucket | Definition | Action |
|---|---|---|
| **HUMAN** | Needs operator decision/input. | Lead the triage reply with these; they are the highest-value items. |
| **FINISHED** | Clearly already handled (referenced PR is open + recent; one-shot research already executed; current message itself). | Mention briefly; do not action. |
| **REVISIT** | Actionable but not blocking. Includes all recent (≤ 30d) items not otherwise classified, and recent work items. | Top-N table by recency. |
| **(silent) ARCHIVED** | > 60d old. Default bucket; rarely surfaced. | Don't enumerate — just count. |

**HUMAN signal patterns (verbatim from this session):**
- PA EDD / 1099 / tax filing content (any reference to a specific state agency + filing).
- "Missing X field" / "did X emit Y" with explicit repro request — likely a live production bug.
- Audit packet asks (Jorge / auditor / Sheet) — usually blocking on operator review.

**FINISHED signal patterns:**
- Message references an open PR that exists (verify via `gh pr view N --json state`).
- One-shot research sweep with explicit "last month / last week / all of it" — already executed in past sessions.
- The current message itself.

**REVISIT signal patterns:**
- `/af this PR N` → just dispatch, low risk.
- `Make a X / add Y` → worker-dispatchable.
- `Find me X from Y` → research/delegation.
- Anything recent (≤ 7d) in `#worldai` / `#voyage` / `#life` with no PR linkage.

## Pipeline (reusable)

```bash
# 1. Page 1 — get total + cursor
aside repl "const c=await slack.getClient('T09FXQ4LCQP'); const r=await c.search.messages({query:'is:saved',count:100,sort:'timestamp',sort_dir:'desc'}); console.log(r.messages.total);"

# 2. Date-partitioned fetches (one per window, ≤ 100 per window)
for w in "2026-07-14:2026-08-19:w2" "2026-07-01:2026-07-14:w3" ...; do
  IFS=':' read -r a b l <<< "$w"
  aside repl "const c=await slack.getClient('T09FXQ4LCQP'); const r=await c.search.messages({query:'is:saved after:$a before:$b',count:100,sort:'timestamp',sort_dir:'desc'}); console.log('total:', r.messages?.total); console.log(JSON.stringify(r.messages.matches.map(m=>({ts:m.ts,user:m.user||m.username,channel:m.channel?.name,channel_id:m.channel?.id,thread_ts:m.thread_ts,text:(m.text||'').slice(0,200)}))));" \
    2>&1 > /tmp/saved-$l.json
  sleep 1
done

# 3. Union by ts + classify (Python)
python3 - <<'PY'
import json, glob
all_items, seen = [], set()
for f in sorted(glob.glob('/tmp/saved-*.json')):
    content = open(f).read()
    import re
    arr_line = [l for l in content.split('\n') if l.startswith('[')][0]
    for m in json.loads(arr_line):
        if m['ts'] not in seen:
            seen.add(m['ts']); all_items.append(m)
all_items.sort(key=lambda x: float(x['ts']), reverse=True)
print(f'Unique: {len(all_items)}')
PY
```

## Output format for the in-thread triage reply

Pattern that worked in this session:

1. **Headline**: total saved items + coverage % + recency distribution.
2. **HUMAN section first**: blocking-on-operator items with concrete next actions.
3. **FINISHED section**: brief mention + reason it's done.
4. **REVISIT top-10 table**: age, channel, item, action — by recency.
5. **Pattern signals**: which channels dominate, what's likely-stale, what's a real recurring ask.
6. **Durable artifact paths**: save triage to `~/.smartclaw/cron/briefings/slack-saved-triage/<timestamp>-{triage,saved-raw}.json` so next run can diff.
7. **Closing question**: pick-A-B-C-D menu for what to do next (NOT a blocking question — operator can ignore).

## Pitfalls

- **Don't claim full coverage when cursor pagination is broken.** State the actual unique-count and the missing count separately.
- **Don't dump all 597 items in the reply.** Lead with 2 HUMAN + top 10 REVISIT. The full set lives in the JSON artifact.
- **Aside's REPL `console.log` is the only output channel.** Each REPL call costs a daemon roundtrip (~500ms-2s); budget ~30 calls for a full triage.
- **The Slack user_id filter matters**: 82% of saved items are operator-saved (`U09GH5BR3QU`); 18% are things the operator reacted/starred. Don't filter on `user == operator` unless the user specifically asks for "my own saves."
- **`is:saved` is case-sensitive in some workspaces** — `is:Starred` does NOT work, only `is:starred`. `is:saved` works as both lower and mixed case in current Slack API.
