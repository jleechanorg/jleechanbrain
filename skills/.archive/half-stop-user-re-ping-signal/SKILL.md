---
name: half-stop-user-re-ping-signal
description: "Detect when user re-sends their own prior message verbatim."
tags: ["autonomy", "anti-stop-halfway", "detection", "slack"]
category: workflow
---

# Half-Stop: User Re-Ping Signal

**The detection signal: when the user re-sends a message whose body is identical (or near-identical) to a message the agent posted 5–30 minutes earlier, the agent stopped at status, not at action.**

The user is not asking a new question. The user is saying: *"I read your status. Now actually do it."*

## Why this signal exists

The `finish-the-job` skill already covers the abstract "don't stop halfway" contract. But the *detection* problem is concrete: when the agent posts a status reply and the user replies, the agent has to recognize "this is not a new task — this is a 'you said you'd do X, go do X' ping." Without a sharp signal, the agent risks:

1. Treating the re-ping as a new question and answering it again (making the loop worse).
2. Re-confirming the prior status without acting (the exact failure mode).
3. Asking "do you want me to do X?" — which is the violation `no-pick-one-menus` forbids.

## Detection heuristics (run in the same turn as the user's message)

Run these checks BEFORE forming a response:

```bash
# 1. Pull the Slack thread's last 5 messages
mcp__slack__conversations_history(channel_id=<chan>, limit=5)
# or curl fallback:
curl -fsS -G "https://slack.com/api/conversations.history" \
  --data-urlencode "channel=<chan>" --data-urlencode "limit=5" \
  -H "Authorization: Bearer <SLACK_BOT_TOKEN>"
```

Look for:

| Signal | What's happening |
|---|---|
| The latest message body is **identical** to the agent's prior message (within ±1 sentence) | The user is re-sending the agent's status. **Stop, then act.** |
| The latest message body is **identical** to the user's prior message (their own re-ping) | The user is impatient, not asking a new question. **Stop, then act.** |
| The latest message starts with "Repeat received", "moving to action", "go", "do it", "ship it", "now", "actually do it" | Likely a re-ping signal. Verify with the above checks. |
| The latest message body is empty or contains only the user's name prefix | Likely a Slack rendering artifact or `never-hallucinate-no-new-content` applies. Re-fetch with `conversations_replies`. |

If ANY signal fires, the agent is in a half-stop situation. Apply the recipe below.

## Recipe (the 4-arm self-audit)

Before posting the next reply, run this audit:

1. **What did the prior message promise to do?** — Read the agent's prior message in the thread. Did it end with "Dispatching", "Spawning", "Will do X", "Will report back"? If yes, the user is asking "where's X?"
2. **Did the agent actually dispatch / execute / push?** — Check `~/bin/ao session ls`, `gh pr view`, `git log --since=10m`, `tmux ls`. If the work isn't running, the agent stopped at status.
3. **Is the user blocked on a single concrete next step?** — If the agent needs the user to type a one-line command, surface that as the ONE-LINE BLOCKER. If the agent needs nothing (the agent can do the next step), act.
4. **What is the next concrete action that CLOSES the prior promise?** — Name it explicitly. Dispatch / push / spawn / run-test-and-paste-output. Do NOT post another status reply.

If the audit returns "I should have done X and didn't," the right response is **act on X in this same turn**, then post a single concise confirmation with proof.

## Correct response shape

```
<one-line: confirming what's about to happen>
<tool calls: dispatch / push / run-test>
<output: proof — job ID, PR URL, run ID, captured log>
<one-line: end-state declaration OR next-checkpoint ETA>
```

Banned shapes:

- "Want me to do X?" — violation of `no-pick-one-menus`. The user already asked by re-pinging.
- "I already said X." — argument, not action. The user knows; they want execution.
- "Status: still working on..." — third status reply. The pattern is now a loop; break it.
- Long explanation of WHY the agent stopped at status — the user doesn't care, and explaining is another form of delay.

## Worked example (2026-08-05, PR #8787)

**Context:** PR #8787 (`fix/funnel-diag-5-events`) was open with 3 Directory tests failing on self-hosted runners. The agent at 23:09 UTC posted a status reply that included "Dispatching AO worker now — three deliverables" but actually did NOT dispatch. The user, ~50 minutes later, re-sent the *same* message verbatim.

**Detection:**
- `conversations_history` showed the user's latest message (ts `1785990587.321239`) had the same body as the agent's own 23:09 UTC status reply.
- The user was not asking a new question; they were pushing the agent past the half-stop.

**Action taken:**
- Verified PR #8787 status via `gh pr view` + `git log` (not from memory).
- Verified the failing tests were infra (same-name rule on 22 unrelated branches).
- Detached stale worktree `worldarchitect-195` (BRANCH_CHECKED_OUT_ELSEWHERE).
- Spawned worker `worldarchitect-203` via `ao spawn --project worldarchitect --harness claude-code --branch fix/funnel-diag-5-events`.
- Wrote the full brief to `~/.ao/data/worktrees/worldarchitect/worldarchitect-203/AO-TASK-BRIEF.md` (because `ao send` rejects >4 KB messages with `MESSAGE_TOO_LONG`).
- Sent a short steering message via `ao send --session worldarchitect-203 --message "Read .../AO-TASK-BRIEF.md ..."`.
- Posted the dispatch confirmation in the thread with `thread_ts` for status continuity.
- Armed a 20-min status cron (`hermes cron create "20m" --name 'PR8787 status (20m)' --deliver 'slack:<chan>' --repeat 1`).

**What this avoided:** another 50-min loop of "Status?" / "Working on it" / "Status?" / "Working on it" until the dropped-thread-followup cron fired.

## What this signal does NOT mean

- The user asking a reasonable follow-up question (e.g., "what's the ETA?" after a real execution reply) is NOT a re-ping signal. Answer the question.
- The user correcting a substantive judgment call (e.g., "don't dispatch, do X inline") is NOT a re-ping; it's a direction change. Apply the user's correction.
- The user pinging just to keep the conversation alive (e.g., "still there?") is NOT a re-ping; it's a liveness check. Reply with the latest status briefly.

The signal is specifically: **the user's latest message body matches the agent's prior message body verbatim**, or **the user's latest message is empty/ambiguous and the agent's own prior message is the most recent substantive content in the thread.**

## Companion reference

- `~/.smartclaw/skills/finish-the-job/SKILL.md` — the abstract "don't stop halfway" contract
- `~/.smartclaw/skills/ao-dispatch-mechanics/SKILL.md` — the spawn flow that fixes the half-stop (after detection)
- `~/.smartclaw/skills/claude-code-claudem/SKILL.md` — alternative dispatch path when `ao` is unavailable
