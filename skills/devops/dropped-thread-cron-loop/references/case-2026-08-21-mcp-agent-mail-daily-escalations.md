# Case: MCP Agent Mail daily-thread per-thread escalation mentions

**Date:** 2026-08-21
**Channel:** `#all-jleechan-ai` (`${SLACK_CHANNEL_ID}`) — daily-thread `1787346748.378459`
**Bot:** `U0A4G7LDJ4R` (`mcp_agent_mail`)
**Signal template:** `@U09GH5BR3QU [Dropped-thread escalation] Gave up after 3 nudges with no resolution — needs your review: <slack-permalink>`

## What happened

Four sequential per-thread escalation mentions landed in the daily-thread
channel within minutes. Each cited a different prior thread, each
pinged Jeffrey directly via `@U09GH5BR3QU`, and each had a "Gave up
after 3 nudges" framing — but every underlying thread was already
verified-complete in a prior session:

| Cited thread | Original ask | Verified-complete state |
|---|---|---|
| `${SLACK_CHANNEL_ID}/p1787211026.599319` | Set Claude Code `outputStyle: Concise` | `~/.claude/settings.json:376` set, verified |
| `C0AH3RY3DK6/p1787180544209829` | /web-advice harness: rich-context + 10 file attachments + LLM-driven Share button | Merged via [PR #833](https://github.com/jleechanorg/jleechanbrain/pull/833), 5/5 contract tests pass |
| `${SLACK_CHANNEL_ID}/p1787222330.239339` | Google Docs testimonial for AO | Doc live, body verified clean via `/mobilebasic` URL |
| `${SLACK_CHANNEL_ID}/p1787248634248549` | Fediverse account fanout (Bluesky + 4 services + Nostr) | Credentials + keypair saved, scripts ready; bot-detection wall blocks automation (not fixable) |

## Root cause

This is the same cron-loop root cause covered in the parent SKILL.md
(the script's `_agent_answered_since_last_user()` checks channel-root
view, missing in-thread replies) — but it surfaces through a SECOND
channel:

1. The dropped-thread-followup cron re-pings the underlying thread with
   `[Dropped-thread followup]` every ~30 min
2. **Separately**, the MCP Agent Mail bot posts per-thread
   `@U09GH5BR3QU [Dropped-thread escalation]` mentions into the
   daily-thread channel — one per stale thread — turning the daily
   channel into an operator-facing escalation feed

The second channel is the noisier one because each mention explicitly
@tags the operator with "needs your review" framing, even though the
underlying work is verified-complete and the cron is firing on a
thread whose work was already done.

## Right response shape

For each per-thread escalation mention in the daily thread:

1. **Do NOT re-do the work.** It's already verified-complete.
2. **Do NOT file a new bead.** Filing "PR already merged" or
   "credential already saved" as a new task is bead cruft.
3. **Post one tight reply in-thread** (the cited thread, not the
   daily-thread channel) confirming: state, proof (commit SHA, file
   path, test result), and any residual human action required.
4. **Don't reply to every escalation individually in the daily-thread
   channel itself** — that's noise. The user already saw the @mention;
   they need to see "closed — proof" via the in-thread reply.

The reply shape that worked in this session:

```
**Dropped-thread escalation closed:**
- Doc: [link] — title set, body verified
- Form: [link] — paste paragraph + LinkedIn URL
- Cleanup: [Drive link] — 30s manual sweep
- Skill updated: path/to/references/<topic>.md

**Proof:** [verified via /mobilebasic / grep / pytest]
🧠 Memories used: [source: ..., effect: ...]
```

Three lines + proof, no re-explanation.

## Why a separate reference, not a SKILL.md patch

The parent SKILL.md covers the cron-side bug and the daily-batch
triage table. This case adds the MCP-Agent-Mail-as-second-channel
pattern — useful for the NEXT session that sees an
`@U09GH5BR3QU [Dropped-thread escalation]` mention to recognize it as
the same loop, not a new incident.

## Anti-pattern to avoid

❌ Replying in the daily-thread channel itself ("All 4 escalations
closed, here's a table…"). This adds another reply to the very feed
that's supposed to be quiet. The right surface is each underlying
thread.

❌ Treating "Gave up after 3 nudges" as a meaningful failure signal.
The cron gives up mechanically when its detector misses in-thread
replies — it has no judgment about whether the work is done.

❌ Asking the user "what do you want me to do about this?" — the work
is done; the cron is wrong. State the state, surface the durable
fix (bead `rev-d63nu`), move on.

## Durable fix

Same as parent SKILL.md: patch `_agent_answered_since_last_user()` to
read `conversations.replies` (thread view), not `conversations.history`
(channel-root view). Until that lands, the operator-channel mentions
will keep firing.
