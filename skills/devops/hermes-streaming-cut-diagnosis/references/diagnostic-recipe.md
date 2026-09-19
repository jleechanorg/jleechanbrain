# Diagnostic Recipe — single-message Slack reply

A copy-paste shell block tuned to produce a Slack-ready diagnosis in one user reply, no separate shell needed. Use this when the user shares a `slack.com/archives/.../p<ts>` link and the symptom is a streaming cut.

## Step 1 — gather facts (parallel calls)

```bash
# a. Confirm the gateway is alive (not a gateway-down scenario)
curl -s --max-time 3 http://localhost:8643/health
launchctl list | grep hermes | grep -v grep | head -3

# b. Record deployed Hermes version + commit
hermes version | head -3

# c. Pull prior incidents from local state (roadmap + state.db)
grep -h "response interrupted" ${HOME}/roadmap/2026-08-1*.md 2>/dev/null | head -10

# d. List upstream issues that match
curl -fsSL "https://api.github.com/search/issues?q=repo:NousResearch/hermes-agent+mid-stream+OR+'partial+stub'+OR+'continuation+prompt'" \
  | python3 -c "import json,sys; d=json.load(sys.stdin); [print(f'[{i[\"number\"]}] {i[\"state\"]:8} cmts:{i[\"comments\"]} {i[\"created_at\"][:10]} {i[\"title\"][:100]}') for i in d.get('items',[])[:10]]"
```

## Step 2 — shape the reply

Use the template:

> **It's not Anthropic, it's not your gateway, and it's not Anthropic cutting you off.** This is an open Hermes Agent bug in the streaming-continuation path.
>
> **Symptom:** Slack turns ending with `[response interrupted by a tool result]`.
>
> **Root cause (verified 2026-08-19 against deployed `Hermes Agent v0.20.0`):** when a streamed response ends as a `partial_stub` (SSE cut without a clean `finish_reason`, e.g. from a Slack WebSocket churn or a new user turn mid-tool-call), Hermes's `_get_continuation_prompt(is_partial_stub=True)` re-prompts the model **without re-asserting that tool calls remain available**. The model interprets that as "I'm now in a text-only session" and emits a single-line stub.
>
> **Upstream tracking:**
> - Issue [#74990](https://github.com/NousResearch/hermes-agent/issues/74990) — bug report (open, 2 comments, 2026-07-30)
> - PR [#75004](https://github.com/NousResearch/hermes-agent/issues/75004) — one-line fix (open, 1 comment) — prompts the change to "You may still use tool calls if needed — all tools remain available."
>
> **You don't need to do anything.** I checked: [paste 1-line gateway health + Hermes version output]. When you type `continue` (or any new message), the original task resumes correctly. This was confirmed in production 2026-08-19 in this same channel.
>
> If you want the cut to be invisible today, say "apply local patch" — I'll apply the upstream #75004 prompt change to our deployed venv (one-line, easily reversible). Otherwise, waiting for `pip install --upgrade hermes-agent` after #75004 merges will resolve it for everyone.

## Step 3 — what to NEVER write

- ❌ "It's Anthropic's stop_reason hitting interrupted." — wrong; SSE signals correctly.
- ❌ "Restart the gateway." — pointless; the gateway is alive and the bug is in the agent loop.
- ❌ "Switch providers as a workaround." — provider-agnostic; doesn't help and breaks cache.
- ❌ "Don't do X, just do Y" without citing the upstream issue.

## Step 4 — if user provides a `slack.com/archives/...` link

The Slack URL shape is `https://<workspace>.slack.com/archives/<channel>/p<ts_no_dot>`.

Extract:
- `channel` from URL path (e.g., `C0AUXSVFSA2`)
- `ts_no_dot` from URL trailing segment, then `ts = ts_no_dot[:<split_point>] + '.' + ts_no_dot[<split_point>:]` to recover the Slack timestamp

```bash
# Example: extract ts from https://jleechanai.slack.com/archives/C0AUXSVFSA2/p1787116801599009
#   ts_no_dot = 1787116801599009 → ts = 1787116801.599009
# Then:
mcp__slack__conversations_replies channel_id=C0AUXSVFSA2 thread_ts=1786685852.433199 limit=50
# (the link's <thread_ts> is the parent; p1787116801599009 is a specific message under it)
```

Pull the exact `response interrupted` line for the reply:
- The literal text in message body for hermes bot (`U0AEZC7RX1Q`) — pass it to the user as proof
- The time delta between the user's last prompt before the cut and the cut message — usually <30s, which distinguishes this bug from a generic hang

## Step 5 — commit the evidence trail

After the reply, log this to `${HOME}/roadmap/2026-08-19-XXXX-slack-thread-roadmap.md` (one row):

```
[<ts>]    hermes    [response interrupted] (upstream #74990 confirmed)
[<ts>]    user      continue
[<ts>]    hermes    On it — [task continues from prior partial stub]
```

This keeps the roadmap audit trail consistent with the `[response interrupted]` markers from 2026-08-17 / 2026-08-18 so future sessions can join the pattern.
