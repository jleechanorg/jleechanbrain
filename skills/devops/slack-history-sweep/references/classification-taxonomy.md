# 5-bucket classification taxonomy — keyword lists

Heuristic keyword lists for classifying Slack threads into one of 5
buckets. The lists are intentionally explicit (vs. embedding an LLM
call) so the classifier runs in <1s on 200 messages and is reproducible.

## Filter order — apply BEFORE the keyword classifier

1. **Filter by `UserID`.** Drop messages where
   `UserID in {<hermes_bot>, <mcp_agent_mail>, <incoming-webhook>,
   <any_other_bot>}`. These are automated/cron messages, not user asks.
   `OTHER` bucket.
2. **Filter by bot-nonce keywords.** Even if `UserID == <jleechan>`,
   the message may be a nonce / test ping. Drop if any of:
   `["test ping", "FRESH-START", "verify ", "inbound test",
   "outbound test", "incoming-webhook", "real-hermes-", "bypass-r",
   "mcp-final-", "xoxb-", "self-correction", "ack-test-", "fresh check"]`
   `OTHER` bucket.
3. **Filter by cron / auto keywords.** Drop if any of:
   `["cronjob response", "cron backup", "ao progress report",
   "executive assistant sweep", "dropped-thread escalations",
   "cron armed", "session automatically reset", "no home channel is set",
   "ai terminal:", "heartbeat_ok", "spiral_calendar_pad:",
   "monitor merged"]`
   `OTHER` bucket.
4. **Filter by meta-directive keywords.** Drop if message is asking
   Hermes to do work, not reporting a bug/feature:
   `["run /roadmap", "pick top 10", "use /history /ms", "use /history /ms /wiki-search",
   "read this skill should we install", "make a plan", "look at all the campaigns",
   "evaluate my", "compare to upstream", "look at the bashrc"]`
   → `OTHER` (or `UNRESOLVED_SLACK_THREAD` if the directive itself
   needs a response).
5. **Only after these filters** apply the 5-bucket classifier below.

## 5-bucket keyword lists

### BUG_FIX — bug being reported or fixed

Strong signals (any one matches):
- "run /repro", "/repro ", "run /repro the", "/repro this",
  "/repro why", "/repro scene", "/repro investigate"
- "/rg fix", "/af on this", "/ready", "/green", "/er"
- "fix ci", "fix this", "fix the", "fix pr", "fix comments",
  "fix this report", "fix the css", "fix this css", "fix issue"
- "why are all these checks skipped", "why missing",
  "why did auto level up fail", "why did the level",
  "why did the campaign", "why did the game", "why did it",
  "why did i", "why did we", "why are all", "why are these"
- "is this still needed", "is this fixed yet", "is this still"
- "doesn't make sense", "doesnt make sense",
  "output formatting messed", "latency seems worse",
  "feels like latency", "feels worse", "never completes",
  "never resolve", "never resolves", "calculating outcomes",
  "calculating outcomes...", "can't load", "cant load",
  "cant scroll", "scrolling lags", "css broke", "css messed up",
  "next button css"
- "is broken", "is failing", "are failing", "failed",
  "error ", "error:", "exception", "stack trace", "traceback"
- "merge conflict", "conflict ", "investigate and see if",
  "investigate and root cause", "investigate and fix fullrun",
  "investigate this email", "investigate workers whats",
  "investigate why", "investigate readonly run",
  "investigate and dont code", "investigate without coding"
- "this is still wrong", "this isnt working", "this is broken",
  "this opened again"
- "i dont see ", "i cant see", "i don't see", "i can't see"
- "make sure this pr", "make sure these",
  "make sure all tests", "make sure these prs"
- "auto-deploy is failing", "auto deploy is still failing",
  "auto deploy seems broken", "prod deploy seems broken"
- "why is it stuck", "why is my god mode", "why does god mode"
- "is this truly needed", "is this truly fixed", "fix this email"

### FEATURE_REQUEST — user wanting new capability

Strong signals:
- "let's make a ", "lets make a ", "make a skill", "make an mcp",
  "make a generic prompt"
- "move ", "add a ", "add an ", "add support",
  "add the ability", "add a button", "add a feature",
  "add a generic", "add a planning", "add a setting",
  "add a new", "add some "
- "let's design", "lets design", "let's add", "lets add",
  "let's upgrade", "lets upgrade", "let's remove", "lets remove"
- "switch ", "change to ", "wanna make", "wanna add",
  "i wanna ", "i want a ", "i want to "
- "make sure we add", "make sure we have",
  "feature request"
- "if we didnt yet", "prompt only change", "prompt only framework",
  "campaign goal", "campaign arcs", "quest", "quests",
  "subarcs", "goal criteria", "planning block option"
- "lets upgrade", "investigate model upgrades",
  "if cost is similar", "cost vs quality", "benchmark"
- "let's ensure", "lets ensure"
- "if not lets use", "use /super to code",
  "read through the 100", "look at all the campaigns",
  "lets try to make", "make a generic prompt",
  "ensure companion", "ensure main"
- "make a feature", "add new", "new feature"

### UNRESOLVED_SLACK_THREAD — still pending

Triggers (any one matches):
- Message is from `<jleechan>` AND no replies (`reply_count == 0`).
- Message is from `<jleechan>` AND short text < 100 chars AND contains
  any of: `["status", "keep going", "continue", "what's the status",
  "whats the status", "still not fixed", "this progress report still"]`.
- Message is from `<jleechan>` AND mentions "Status on" or
  "Investigate this" or "keep going" (likely a nudge on an existing
  thread).

### INCIDENT — deploy failure / outage

Strict signals (any one matches):
- "urgent infra", "infra finding", "sev1", "sev2",
  "outage", "host becoming unresponsive",
  "load average just spiked", "load spike is new and severe",
  "deploy failure", "deploy is failing", "deploy failed",
  "deploy broken", "deploy seems broken",
  "dev is down", "prod deploy",
  "gunicorn down", "server is down", "site is down"

### OTHER — everything else

Default bucket. Includes:
- Bot/cron messages (filtered out above)
- Meta-directives (filtered out above)
- Bot nonces (filtered out above)
- Short acknowledgements ("ok", "thanks", "👍")
- Status pings, "still not fixed" follow-ups
- AI Terminal worker status posts (PR/af reports)
- Live health-check pings ("LIVE-CHECK-...", "LIVE-HEALTH-...",
  "LIVE-CONVERSATION-...")

## Status signal heuristic

After classification, attach a `status_signal` per thread:

| Bucket | status_signal |
|---|---|
| BUG_FIX | `finished` if text contains any of `["merged", "shipped", "fixed", "/ready", "/green", "green gate", "ci green", "merged clean", "ready to merge", "/er passed"]`; else `in_progress` |
| FEATURE_REQUEST | `pending` |
| UNRESOLVED_SLACK_THREAD | `pending` |
| INCIDENT | `needs_decision` |
| OTHER | `finished` |

## Validation

Spot-check top-3 per bucket after classification. If top-3 in
`BUG_FIX` looks like directives (e.g. "Run /roadmap"), the
meta-directive filter failed — add the missing phrase and re-run. If
top-3 in `FEATURE_REQUEST` looks like bug reports ("doesnt make
sense"), the BUG_FIX keywords are missing the right phrase — add it.

The heuristic is approximate by design. For high-stakes audits (e.g.
compliance reviews), escalate to a per-message LLM call after the
heuristic filters.
