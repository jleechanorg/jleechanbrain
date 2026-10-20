---
name: slack-saved-later-triage
description: Use when triaging Slack saved/later reminders into buckets.
version: 1.0.0
tags: ["slack", "triage", "saved-later", "aside", "false-green-guard"]
related_skills: ["aside-browser-default", "memory-search", "executive-assistant", "wa-llm-output-emission-false-green-watchdog"]
---

# Slack "Saved for later" Triage

The Slack **Saved for later** queue (`app.slack.com/client/<team>/later`) is distinct from Inbox, Mentions, and Starred — it's the user's personal "deal with this later" parking lot. It accumulates over years without auto-cleanup (verified: 597 items in one user's queue spanning 2026-01 → 2026-08). Most users never triage it.

This skill produces a 4-bucket classification so the operator can decide what to act on, what to close, and what to archive.

## When to fire

- Operator asks to triage the Slack saved/later list
- Operator shares a URL of the form `app.slack.com/client/<team_id>/later`
- Operator asks "what's still unresolved" in saved items specifically
- The queue has >50 items (smaller queues rarely need triage)
- Operator asks to "clear the rest" of the saved queue (implies scoring + ranking first)

## Recipe (5 steps)

### Step 1 — Aside auth check

```bash
aside account list   # should show "* u0  jleechan@gmail.com  signed in"
```

If not signed in, see `aside-browser-default` "Aside is not running" section.

### Step 2 — Fetch via date-range partitioning (NOT cursor pagination)

Aside's `slack` REPL global + `client.search.messages` is the canonical path. **Cursor pagination hits `internal_error` reproducibly** (verified 2026-08-18, 5 retries). Always use date-range partitioning:

```js
const client = await slack.getClient('T09FXQ4LCQP');
const WINDOWS = [
  { after: '2026-07-14', before: '2026-08-19' },   // recent week (page-1 territory)
  { after: '2026-07-01', before: '2026-07-14' },   // monthly back
  { after: '2026-06-01', before: '2026-06-30' },
  { after: '2026-05-01', before: '2026-05-31' },
  // ... walk backward to first save
];
let allMatches = [];
for (const w of WINDOWS) {
  await new Promise(r => setTimeout(r, 800));   // rate-limit courtesy
  const r = await client.search.messages({
    query: `is:saved after:${w.after} before:${w.before}`,
    count: 100, sort: 'timestamp', sort_dir: 'desc'
  });
  if (r.ok) allMatches.push(...r.messages.matches);
}
```

Sub-window any window where `r.messages.total > 100` (Slack's hard cap per page). For monthly windows that exceed 100, split by week or by half-month.

### Step 3 — Slim + dedupe

```js
const slim = allMatches.map(m => ({
  ts: m.ts,
  user: m.user || m.username,
  channel: m.channel?.name,
  channel_id: m.channel?.id,
  thread_ts: m.thread_ts,
  text: (m.text || '').slice(0, 240)
}));
const seen = new Set();
const dedup = slim.filter(m => seen.has(m.ts) ? false : (seen.add(m.ts), true));
```

### Step 4 — Categorize into 4 buckets

| Bucket | Meaning | Trigger patterns |
|---|---|---|
| **FINISHED** | Already handled; just confirm/close | Operator self-references, recent worker confirmations, PR refs to merged PRs |
| **HUMAN** | Blocking on operator decision/action | Personal items needing MFA/forms, security alerts, blocked deps on others, "needs me" / "TODO:" |
| **REVISIT** | Actionable next 7 days | Recent work items, PR follow-ups, design asks, prompt compaction, `/af` directives |
| **ARCHIVED** | >60d old, stale, low signal | Anything past the recency threshold that didn't match above |

Pattern-match on the text + cross-reference with PR state via `gh pr view`. The biggest FINISHED win: many saved items reference a PR that's already merged — verify with `gh pr view <N> --json state,mergedAt` before classifying as REVISIT.

### Step 5 — Score within REVISIT (when ≥20 items)

```python
priority_channels = {
  'worldai-bugs': 5, 'worldai-alerts': 5,
  'worldai': 4, 'jleechanbrain': 4, 'agent-orchestrator': 4,
  'voyage': 3, 'novel': 3, 'mcp-mail': 3,
  'life': 2, 'all-jleechan-ai': 2, 'ai-general': 2,
}
urgent_keywords = ['/af', '/fullrun', '/finish', '/harness', 'p0', 'p1',
                   'urgent', 'asap', 'blocker', 'critical', 'must',
                   'broken', 'failure', 'audit', 'cron', 'launchd']

def score(m):
  s = priority_channels.get(m['channel'], 1) * 3
  for kw in urgent_keywords:
    if kw in m['text'].lower(): s += 2
  if re.search(r'#\d{3,5}', m['text']) or 'github.com' in m['text'].lower(): s += 3
  days = (now - datetime.fromtimestamp(float(m['ts']))).days
  if days > 30: s -= 2
  if days > 90: s -= 3
  if m.get('user', '').startswith('B'): s -= 5   # bot-generated saves
  return s
```

Score ≥6 = keep. Score <6 = clearable. Output the top 10–15 by score.

## Output format (Slack reply)

```text
:clipboard: Slack "Saved for later" triage — <YYYY-MM-DD HH:MM PT>

Got <captured>/<total> saved items via `search.messages` API (Aside cursor
pagination hits Slack's internal_error on page 2+, so I switched to
date-range partitioning).

:large_blue_circle: By recency: 10 today · 13 this week · 51 this month · ...

:rotating_light: HUMAN (needs you — <N> items)
- <item> — <note>

:large_green_circle: FINISHED (already handled — <N>)
- <item> — <note>

:large_yellow_circle: REVISIT top 10 (next-7-day actionable — <N> total)
| Age | Channel | Item | Action |

:gear: Pattern signals
- channel distribution, recurring themes, channel-priority surprises

:card_file_box: Artifacts saved
- <path-to-triage.json>
- <path-to-raw-saved.json>
```

## Pitfalls

- **Aside cursor pagination hits `internal_error`** — always use date windows. Verified 2026-08-18, 5 retries, all failed. See `aside-browser-default` "Pitfalls" section for the full error transcript.
- **Slack API hard-caps at 100/page for any date window** — sub-window tighter if `total > 100`.
- **Bot-saved items pollute the queue** — cron saves (e.g. `life:mizraim-register-pa-daily-9am`) end up here. Filter or score low.
- **`m.ts` is the message timestamp, NOT the save-time** — older messages re-saved have recent `ts`. Look at message text for true age signal.
- **Match text is truncated to ~280 chars** — fetch full text via `conversations.replies` or `conversations.history` if you need more.
- **Cross-reference PR state before classifying** — many saved items point at merged PRs. Use `gh pr view <N> --json state,mergedAt` to verify; saves a false REVISIT.
- **Don't classify a recent "operator-said-X" item as REVISIT if X is already done** — check the latest reply in the thread (Aside `conversations.replies`) to see if the worker/agent already acted on it.
- **597/619 captured is normal** — Slack's date filter + page cap leaves a small remainder. Don't chase the last 4%.

## Cross-references

- `aside-browser-default` — Slack REPL global + cursor-pagination pitfall
- `memory-search` — cross-check items against 9-store memory before classifying FINISHED
- `executive-assistant` — daily sweep that surfaces stale saved items
- `wa-llm-output-emission-false-green-watchdog` — for any "missing X" warning that surfaces as a saved reminder
