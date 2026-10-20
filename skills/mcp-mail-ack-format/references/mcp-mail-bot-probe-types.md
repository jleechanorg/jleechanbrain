# MCP Mail bot probe types — catalog

The MCP Agent Mail bot (`U0A4G7LDJ4R`) sends probes in several formats. Knowing which kind you got is the first step in writing a correct ack.

## 1. Dropped-thread followup (the recursive loop class)

**Trigger:** operator posted in a thread and didn't get a bot reply within the watcher's quiet window (~30 min by default). Watcher classifies the thread as cold and posts a followup.

**Shape:**
```
<@U0AEZC7RX1Q> [Dropped-thread followup] This thread appears to have gone cold.
Original request: "<operator's last message or agent's last message>"
Please provide a status update on the requested action, or confirm if work is complete.
If you admitted to not executing something, please do so now and either complete the work or explain the blocker.
```

**Ack format:**
```
Ack: <channel>/<thread_ts> — <completed|blocked|no-op|gave_up:true> — action needed: <yes|no>
```

**Where the probe lands:** in the original thread the operator posted in. The session-context `thread:` header is the hint; always re-fetch `conversations.replies` to verify.

## 2. Dropped-thread escalation

**Trigger:** a dropped-thread followup was itself ignored. Watcher escalates to Jeffrey (`U09GH5BR3QU`) for direct review.

**Shape:**
```
<@U09GH5BR3QU> [Dropped-thread escalation] Gave up after 3 nudges with no resolution — needs your review: <slack-permalink>
```

**Ack format:** N/A — this is for the operator (Jeffrey), not the agent. The agent only acks in the underlying thread.

## 3. Session-complete

**Trigger:** an AO worker dispatched by `ao spawn` finishes and posts its final summary. MCP Mail bot relays it to the operator's home channel.

**Shape:** starts with the worker's session ID and per-item summary, e.g.:
```
MCP Agent Mail session-complete
<aopr-XXXXX>: 5 workers tracked
- #109 dice nat-1/nat-20 → PR #8800 merged
- #106 PR #8488 → ...
```

**Ack format:**
```
Ack: <session-id> — merged|green|blocked|action-needed|no-op|no-work — action needed: <yes|no>
```

## 4. Coding-wave dispatch ack

**Trigger:** AO spawns a coding wave (batch of workers). MCP Mail bot posts a dispatch ack that the wave policy was received.

**Shape:** starts with `:gear: N-worker ack received` and tracks per-item state.

**Ack format:** `Ack: <dispatch-id> — completed|acked|action-needed — action needed: <yes|no>`

## 5. Coding-wave update / re-check verified

**Trigger:** operator or watcher polls the wave's progress. Bot reports per-item status (PR URLs, merge states).

**Shape:** starts with `:hourglass: Backlog status` or `:white_check_mark: Coding-wave update verified` and lists each worker's current state.

**Ack format:** `Ack: wave-<batch-id> — <per-item-state> — action needed: <yes|no>`

## 6. Backlog status (idle polling)

**Trigger:** MCP Mail bot's periodic backlog poll (e.g. every 30 min when no active waves).

**Shape:** ":hourglass: Backlog status — <idle|step-back>" with wave summaries.

**Ack format:** `Ack: backlog-<poll-id> — idle — action needed: no`

## Common pitfalls

- **Recursive probe on prior ack body** — see `recursive-probe-fix-2026-08-14.md`. Bot quotes the prior ack as the new "Original request" when the regex skip fails.
- **Misroute from session header** — the session-context `thread:` field is a HINT not authoritative. Always re-fetch `conversations.replies` to find where the probe actually landed.
- **Wrong channel** — probes can land in the daily-thread header (`${SLACK_CHANNEL_ID}/1786596160.718939`-style) rather than the original parked thread. The daily-thread is itself a probe-reply target during the bot's daily cycle.
- **Wrong Slack identity** — `mcp__slack__conversations_add_message` posts under hermes bot; Path B `SLACK_USER_TOKEN` (xoxp) posts under `U09GH5BR3QU`. Per `prefer-builtin-slack-mcp` and `slack-cross-workspace-fallback-xoxp`.

## How to identify the probe type when unsure

Re-fetch the message body via `conversations.replies(channel=<chan>, ts=<thread_ts>, limit=1)`. The first ~80 chars usually contain the kind marker (`[Dropped-thread followup]`, `session-complete`, `Coding-wave`, `Backlog status`, etc.).