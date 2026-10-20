# 2026-08-17 — `dropped-thread-followup` cron re-firing despite multiple in-thread replies

## Symptom

- Thread: `C0AH3RY3DK6/1786914648.772089` (worktree_ui_planningb OPTION B design review)
- Cron: `ai.smartclaw.schedule.dropped-thread-followup` (launchd, 4h interval)
- Three separate "this thread has gone cold, please reply" followups landed in
  slack within a few hours of each other; each one fired even after a long,
  detailed, in-thread reply had already been posted by the agent within the
  same session.

## Cost

- Operator asked in chat "did you ignore my dropped-thread followup?"
- Agent replied twice assuming the third followup was a duplicate; it wasn't.
- Three separate copies of the same status landed in-thread, breaking into
  multi-message sequences the user already read once.

## Root cause

The agent (this session) acted on a `memory_search` result that was **wrong**:

> "the cron's dedupe key is actor, not content, so author-mismatched replies
> never suppress the next fire. Posting as the same identity the cron uses
> breaks the loop."

That memory described a *different* deduplication logic in a *different* system.
For this cron, that's not how it works at all. The cron's actual suppression
mechanism is the in-script state file at
`~/.smartclaw/logs/dropped-thread-state.json`, with per-(channel, thread) entries
that look like:

```json
{
  "C0AH3RY3DK6_1786914648.772089": {
    "last": "2026-08-17T23:52:13Z",
    "count": 3,
    "gave_up": false
  }
}
```

`nudge_gave_up()` (line 343 of `scripts/dropped-thread-followup.sh`) reads
`gave_up` on every tick; if true, it short-circuits the thread before any
post-classification, LLM nudge, or Slack write. Nothing else on the path
inspects Slack message history in a way that would suppress a re-fire.

So the agent's first pivot (repost as `U0A4G7LDJ4R` instead of the default
`U0AEZC7RX1Q`) had zero effect on the cron. The agent then replied a third
time in-thread with a markdown table including "Memories used: [..]" — also
no effect. Each reply landed on Slack, the user saw a fresh followup fire
~20 minutes later, and the agent's confidence in its own diagnosis stayed
spuriously high because the wrong memory confirmed the wrong hypothesis.

## What actually worked

Reading `scripts/dropped-thread-followup.sh` directly (specifically lines
48, 343, 360-371, 406-419) showed the real mechanism: `mark_gave_up`. Once
the agent invoked

```bash
jq --arg k "C0AH3RY3DK6_1786914648.772089" --arg v "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  '.nudged[$k] = ((.nudged[$k] // {last:null,count:0,gave_up:false})
                  | .gave_up = true | .last = $v)' \
  ~/.smartclaw/logs/dropped-thread-state.json \
  > /tmp/state-updated.json && mv /tmp/state-updated.json \
  ~/.smartclaw/logs/dropped-thread-state.json
```

the very next tick skipped the thread.

## Lesson (extends the existing 1a pitfall)

- **The same skill (`slack-cron-report-health`) covers two classes of cron
  misbehavior.** Section 1a is about cron `last exit code != 0` being
  misread as cosmetic. This case is the mirror: cron `last exit code = 0`
  being misread as "silenced everything I posted in Slack." Both look
  healthy at the layer an LLM agent naturally inspects (Slack message
  history; `launchctl print` last-exit field). Neither proves anything
  about the suppression mechanism this specific cron actually uses.

- **Citation laundering is dangerous when the citation confirms the wrong
  hypothesis.** `🧠 Memories used: [memory_search ...]` feels rigorous
  even when the memory itself is wrong. The audit detector doesn't catch
  wrong-direction citations, only fabricated ones. The fix is to read the
  script before citing a memory about how the script behaves.

- **Default action when a memory says "X doesn't work" or "X uses mechanism
  Y":** open the script (or config, or whatever owns the asserted
  mechanism) and grep for it. If the grep returns 0 hits in 60 seconds,
  the memory is wrong and you should delete or rewrite it, not cite it.

## What changed in the skill

- `slack-cron-report-health` SKILL.md pitfall list gains one bullet:
  "Posting a thread reply does NOT suppress the dropped-thread cron
  ... `mark_gave_up` is the only durable way to silence a thread you're
  sure is closed." With cross-reference to the dedicated recipe in
  `dropped-messages`.

## Transcript pointer

Slack thread: `C0AH3RY3DK6/1786914648.772089`

Key message timestamps (proves the cron kept firing despite 3 in-thread
replies under 2 different Slack author identities):

| ts                  | author         | role |
|---------------------|----------------|------|
| 1787032252.122909   | U0A4G7LDJ4R    | cron followup #1 |
| 1787032294.278899   | U0AEZC7RX1Q    | agent reply (Hermes identity) |
| 1787034078.738429   | U0A4G7LDJ4R    | cron followup #2 — re-fire #1 |
| 1787034104.845589   | U0A4G7LDJ4R    | agent reply (MCP-mail identity, "match cron's identity" pivot) |
| 1787035905.367969   | U0A4G7LDJ4R    | cron followup #3 — re-fire #2 — confirms identity hypothesis was wrong |
| (no further re-fires after mark_gave_up) |  |  |
