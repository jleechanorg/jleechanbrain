---
name: mcp-mail-ack-format
description: Use when replying to any MCP Agent Mail bot probe in Slack.
category: hermes-imports
version: 1
author: claudem/minimax-M3
license: MIT
metadata:
  hermes:
    tags: [slack, mcp-mail, dropped-thread, ack-format, regex-pitfall]
    related_skills: [dropped-messages, finish-the-job, slack-thread-routing-investigation]
---

## When to Use

Load this skill when ANY of the following fires:

- A Slack message arrives from `U0A4G7LDJ4R` (MCP Agent Mail bot) — any kind: dropped-thread followup, session-complete, coding-wave dispatch ack, dropped-thread escalation, backlog status
- You are about to post an "Ack: ... — action needed: ..." reply in a Slack thread the MCP Mail bot monitors
- You observe a recursive probe pattern where the bot quotes a prior ack body as the new "Original request"
- You are debugging why `scripts/dropped-thread-followup.sh`'s `_is_automated_report` skip-rule is failing to catch your acks

DO NOT use this skill for:
- Replying to a human-typed message — just reply normally, do not start with `Ack:`
- Replying in a thread where you're executing work — don't mark `action needed: no` if you intend to continue

---

# MCP Agent Mail ack format

When the MCP Agent Mail bot (`U0A4G7LDJ4R`) sends any kind of probe — dropped-thread followup, session-complete, coding-wave dispatch ack, dropped-thread escalation — the operator and watcher both rely on a strict ack format to keep the bot's downstream consumer from re-probing the ack itself.

## Canonical ack format (mcp-mail-ack)

Every reply to an MCP Mail bot message MUST start with this line:

```
Ack: <task-id-or-thread-ref> — <state> — action needed: <yes|no>
```

- `<task-id-or-thread-ref>` — the message ID, channel/thread reference, or PR/session identifier the bot is asking about (e.g. `1786688859.989389`, `${SLACK_CHANNEL_ID}/1786504119694449`, `PR #8867`)
- `<state>` — short status word: `completed`, `blocked`, `merged`, `green`, `no-op`, `gave_up:true`, etc.
- `<action needed>` — `yes` if operator must do something, `no` if not

Followed by 1–3 paragraphs of supporting context (state files, commit SHAs, test results).

## Why this exact format matters

The dropped-thread watcher (`scripts/dropped-thread-followup.sh`) has a skip-rule in `_is_automated_report` that detects acks in this format and treats them as automated reports — so the watcher won't re-nudge the same thread. Two regex pitfalls to know:

### Pitfall 1: multi-paragraph acks

The regex operates on the FIRST LINE of the message. Real acks always have a header line followed by `\n\n` and supporting prose. The prior fix `commit 39251146e2` failed because its regex required everything on one line — every multi-paragraph ack slipped through the skip-rule and triggered re-nudges.

**Fix in `scripts/dropped-thread-followup.sh` (both copies of `_is_automated_report`, lines ~720 and ~1396):**

```python
head = t.split("\n", 1)[0]
if re.search(r"^ack(?:-of-ack)?:.*?—\s+action needed:\s*(yes|no)\b", head):
    return True
```

### Pitfall 2: backtick-quoted ts (no slash)

The prior fix required `\S+/\S+` (channel/ts slash notation). Real acks use backtick-quoted ts without channel prefix: ``Ack: foo `1786688859.989389` — no-op — action needed: no``. The slash separator is too restrictive.

**The corrected regex accepts any id format:** `^ack(?:-of-ack)?:.*?—\s+action needed:\s*(yes|no)\b`.

### Pitfall 3: duplicate probe on idle-but-already-acked thread (window-shift race)

Even after a correctly-formatted in-thread ack lands, the dropped-thread watcher (`scripts/dropped-thread-followup.sh`) can fire a SECOND probe on the same thread ~30 minutes later if the thread is still idle from a watcher perspective. The watcher doesn't track "this thread was already ack'd with action-needed: no" — it only checks "is this thread idle in the lookback window?" The two questions collapse to the same answer on threads where the user is the slow side (e.g. analysis delivered, awaiting user's call on decisions).

**Observed pattern** (2026-09-16, thread `C0AH3RY3DK6/1789419420.924459`):
- Probe `1789536826.462219` → ack `1789536851.253439` (in-thread ✅)
- 30 min later: probe `1789538646.568919` (duplicate) → ack `1789538658.389499` (in-thread ✅)

**Repro recipe:** any thread where (a) the agent delivered analysis / a draft, (b) `action needed: no (gated on user)` is the truthful state, (c) the user hasn't replied yet. The notifier's window-shift fires before the regex skip-rule catches up.

**Correct response:** post a SECOND ack in the correct thread using the canonical format. Do NOT escalate, do NOT change state, do NOT spawn workers. Re-fetch `conversations.replies` after posting to verify the ack landed in-thread (the post-then-verify dance is the only way to catch the silent-thread-ts drop per `slack-thread-routing-investigation`).

**Bead candidate:** `dropped-thread-followup.sh` should treat threads whose last bot message carries `action-needed: no (gated on user)` as already-handled without re-firing for N hours. This is the third instance of the same triple-probe pattern in the ack log (2026-06-09, 2026-06-11, 2026-09-16 — thread `1781069650.080759` and thread `1789419420.924459`).

## The recursive probe loop

When the regex skips fail, the MCP Mail bot's downstream consumer treats your ack as a fresh human ask and fires a new probe that quotes your ack body as the new "Original request". Each cycle reproduces:

```
probe(1786685007) → ack(1786685207) → probe(1786686966) → ack(1786687002)
              → probe(1786688859) → ack(1786688884) → probe(...)
```

**Always post in the correct thread** (per SOUL.md `## COMMIT: slack-reply-inherit-thread-ts` — re-fetch via `conversations.replies` / `conversations.history`, the session-context `thread:` field is a HINT not authoritative). Posting the ack to the wrong thread can re-trigger the loop.

## Required actions after every MCP Mail bot reply

1. **Re-fetch the thread** to verify where the probe actually landed (`conversations.replies` or `conversations.history` via Slack MCP, or Path B curl with `SLACK_USER_TOKEN` if MCP unreachable).
2. **Post the ack** in the verified correct thread using the canonical format. Use `mcp__slack__conversations_add_message` (Path A) if available, else fall back to Path B curl per `slack-cross-workspace-fallback-xoxp`.
3. **Log the ack** to `~/.smartclaw/memory/mcp-mail-ack-log.md` with the format shown below.
4. **If the regex pitfall reproduces** (recursive probe quoting your prior ack), don't just ack the probe — read `scripts/dropped-thread-followup.sh` around the `_is_automated_report` definitions and verify the regex handles multi-paragraph acks + backtick-quoted ts. See `references/recursive-probe-fix-2026-08-14.md` for the worked example.

### Ack log entry format

```
## YYYY-MM-DD HH:MM UTC
- **Message ID:** <ts> (<channel>/<thread_ts>)
- **Source:** MCP Agent Mail (U0A4G7LDJ4R) <kind>
- **Original request:** <quoted text>
- **Status:** COMPLETED. <one-line summary>
- **State:** completed | blocked | merged | green
- **Action needed:** yes | no
- **Ack-ts:** <ISO> (slack ts=<slack_ts>, posted via <path>)
```

## When NOT to use this format

- Replying to a human-typed message: don't start with `Ack: ...`. Just reply normally.
- Replying in a thread where you're executing work, not closing a probe: don't mark `action needed: no` if you intend to continue work — that signals the bot (and watcher) to stop.

## References

- `references/recursive-probe-fix-2026-08-14.md` — full PR #818 walkthrough: regex pitfall, the 4-test regression suite, the worktree-from-main commit pattern
- `references/mcp-mail-bot-probe-types.md` — catalog of probe message shapes (dropped-thread followup, session-complete, coding-wave dispatch ack, dropped-thread escalation, backlog status)
- `references/duplicate-probe-idle-thread-2026-09-16.md` — duplicate-probe variant (different from recursive): bot re-fires on already-acked idle thread ~30min after first ack; correct response = second canonical ack + log with `DUPLICATE` prefix; bead candidate for watcher to track `last_bot_ack_ts` per-thread