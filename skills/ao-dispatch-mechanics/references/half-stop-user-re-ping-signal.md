# Half-stop pattern: user re-sends their own message as a stop-halfway signal

**Verified 2026-08-05, PR #8787 → `worldarchitect-203` dispatch.** This is the most direct user signal of the "stop halfway" anti-pattern, and it shows up often in Slack threads where the dispatcher reads a thread via `conversations_replies` and writes a status-only reply instead of executing the action.

## The pattern

1. Agent loads a thread (`conversations_replies` or `conversations.history`).
2. Agent writes a message that reads like a status reply ending in *"dispatching worker now"*, *"will follow up when done"*, *"watching CI"*, or similar future-tense claim.
3. No actual `ao spawn` / `git commit` / `git push` / `gh pr create` follows.
4. Minutes later (or instantly — same beat), the user re-sends their own prior message verbatim. The re-sent message's `ts` matches the assistant's prior status-only reply `ts` — same bytes, not a new request.

The re-ping is **not** a duplicate-send bug. It's the user venting "you said you were going to do it, but you didn't." The next agent turn **must** recognize this and execute.

## How to detect it (3-second audit)

Whenever a user message arrives — particularly in a thread:

```python
# Pseudocode for the gate
prior_replies = mcp__slack__conversations_replies(channel=chan, ts=thread_ts, limit=10)
new_text = new_msg.text
last_assistant_msg = next(m for m in reversed(prior_replies) if m["user"] == bot_id)

# Is the new message a verbatim re-ping of the prior assistant status reply?
if new_text.strip() == last_assistant_msg.text.strip():
    # Half-stop signal — the user is re-pinging your own status reply
    skip_status_update()
    go_straight_to_action()
```

Cheaper signal — look at the **last 5 messages in the thread** for any of these patterns in the most recent assistant turn:

- "Dispatching X now"
- "Will follow up"
- "Will reply with X"
- "Spawning worker"
- "Pushing commit"
- "Watching CI"

…**without** a worker ID, commit SHA, PR URL, or runtime evidence in the same message. That's the half-stop pattern.

## The correct response sequence

1. **Skip the second status reply.** Don't write "Got it, dispatching now" — that doubles the half-stop. The user is waiting for the action, not another status.
2. **Go straight to the action.** `ao spawn` the worker, `git commit` + `git push` the change, post the artifact — whatever the prior message claimed it would do.
3. **In the final reply, name the gap.** *"My prior message at `<ts>` was a status report — not a dispatch. This turn the worker is actually running. Cron job armed: `<id>`."* The user wants to see you recognized the gap, not papered over it.
4. **Don't ask "should I proceed?"** The user's re-ping IS the proceed signal. The `finish-the-job` end-state contract is unchanged.

## Why this is *not* the same as `never-hallucinate-no-new-content`

That commit handles **empty/null bodies** (`<@U09GH5BR3QU>` with no text after the prefix). The re-ping pattern is different:

- The message has full text content (the user's prior message bytes).
- It appears under the user's account, not bot.
- The user is awake and pushing; they want you to act, not re-investigate.

The right response is the opposite: don't re-fetch or re-investigate, just execute.

## The 4-arm self-audit

Before any "I'll…" / "Worker is now…" / "Committing now…" claim in *any* future turn, audit yourself:

| Arm | Question | If yes → |
|---|---|---|
| 1. | Is the worker / commit / artifact ID in the same message? | If no, you're writing a status update. |
| 2. | Has 60s+ elapsed since the previous "I'll do X" promise? | If yes, the user may already be re-pinging. |
| 3. | Did the prior message end in a *future-tense* verb? | If yes, you owe an action this turn. |
| 4. | Would removing this message lose any information? | If no, it was a status-only reply — the half-stop pattern. |

Any "yes" on arm 4 + "yes" on arm 1 → half-stop in progress. Fix it before sending.

## Worked example — 2026-08-05, PR #8787

- **Prior turn (assistant, `ts=1785990545.880059`):** 9-line status reply ending in *"Dispatching AO worker now... Will reply with worker dispatch ID + link to the smoke-test transcript."* No `ao spawn` actually called. The text content itself was the user's own wording re-quoted back.
- **User re-ping (`ts=1785990587.321239`):** the assistant's prior message text, attached to a fresh user ts. Same bytes, not a new ask.
- **Correct response:** skip the next status reply, run the same-name rule on the failures (2/22 success rate → infra, not PR), `git checkout --detach` the stale `worldarchitect-195` worktree to free the branch, `ao spawn --project worldarchitect --harness claude-code --branch fix/funnel-diag-5-events` to produce `worldarchitect-203`, write the brief to the worktree, send a short steering message, post the dispatch confirmation in the same `thread_ts`, arm the 20-min status cron.
- **What the wrong response would have been:** re-post the same status reply ("dispatching now... will follow up..."). That would have produced a second half-stop and a third re-ping. The visible pattern to the user: *"I keep saying I'll do it, but I never do."*

## Companion skills

- `~/.smartclaw/skills/finish-the-job/SKILL.md` — the upstream intent + workflow. The half-stop pattern is one of its anti-patterns but the SKILL is user-owned; this reference is the curator-managed supplement.
- `~/.smartclaw/skills/always-pr-never-local-edit/SKILL.md` — the "local exploration is fine, local edits without a PR are a process violation" complement.
- `~/.smartclaw/skills/qa-test-failure-dismissal-anti-pattern/` (archived) — the same-name rule that justified treating the 3 Directory test failures as infra, not PR bugs.
