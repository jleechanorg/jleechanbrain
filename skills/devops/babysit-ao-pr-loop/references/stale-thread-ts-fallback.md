# Stale `thread_ts` fallback — PR #8787 final tick (2026-08-06)

Worked example for the "Stale `thread_ts` in cron prompt" section of SKILL.md (added v1.7.0). Use this as the recipe reference when the cron prompt's hardcoded `thread_ts` returns `thread_not_found` in the obvious channels.

## Setup

- **Cron name**: PR 8787 smoke-test retry
- **Prompt's hardcoded target**: `thread_ts=1785990587.321239` (intended for the PR #8787 verification thread)
- **Prompt's implicit channel**: `C0AH3RY3DK6` (`#worldai`) — the most-likely channel for WA-class PRs

## Symptom (verified)

Five plausible channels all return `thread_not_found`:

```bash
for CHAN in C0AH3RY3DK6 ${SLACK_CHANNEL_ID} C0AJQ5M0A0Y ${SLACK_CHANNEL_ID} C0AQJT7KSP2; do
  curl -fsS -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
    "https://slack.com/api/conversations.replies?channel=${CHAN}&ts=1785990587.321239&limit=2"
done
# All return: {"ok":false,"error":"thread_not_found"}
```

## Resolution (verified)

The thread actually lives in `C0AUXSVFSA2` — a side channel. The v1.2.0 changelog of `wa-cloud-logging-diag` documents this as the canonical home for the PR #8787 verification thread:

> "When the cron prompt gives a `thread_ts` but no channel, the cron must resolve the channel itself — verified 2026-08-06: thread `1785990587.321239` lives in `C0AUXSVFSA2` (a side channel), NOT in the obvious `C0AH3RY3DK6` (`#worldai`). Trusting the obvious channel returned `thread_not_found`. Recipe: try `C0AH3RY3DK6` + `C0AJQ5M0A0Y` + `C0AUXSVFSA2` + `${SLACK_CHANNEL_ID}` in turn..."

```bash
curl -fsS -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
  "https://slack.com/api/conversations.replies?channel=C0AUXSVFSA2&ts=1785990587.321239&limit=2"
# Returns: {"ok":true,"messages":[...]}
```

## Post that landed (verified)

The cron posted PASSED evidence to the **wrong channel** (`C0AH3RY3DK6` thread `1785998369.940599` — the existing PR #8787 smoke-test thread) because:

1. The cron did not try `C0AUXSVFSA2` from the side-channel ladder
2. Instead it fell back to the existing related thread (`1785998369.940599`) where two prior `:large_green_circle: PASSED` posts already lived
3. Included a one-line note in the post body documenting the fallback

```json
{
  "channel": "C0AH3RY3DK6",
  "thread_ts": "1785998369.940599",
  "ts": "1786015464.865039",
  "user": "U0AEZC7RX1Q",
  "bot_id": "B0AEHUEA0JK"
}
```

Body excerpt:
> *Note on cron prompt's `thread_ts=1785990587.321239`*: that thread_ts doesn't resolve in any channel (`thread_not_found` for C0AH3RY3DK6/${SLACK_CHANNEL_ID}/C0AJQ5M0A0Y/${SLACK_CHANNEL_ID}/C0AQJT7KSP2). Replying to `1785998369.940599` instead to preserve thread continuity with the existing PR #8787 smoke-test conversation in #worldai.

## Lesson

The cron prompt's `thread_ts` was authored days earlier and pointed at a thread in a side channel (`C0AUXSVFSA2`). The cron did not know this and defaulted to the obvious channel (`C0AH3RY3DK6`). The fallback ladder in the SKILL.md recipe catches this class — but only if the cron RUNS the ladder probe before composing the Slack reply.

**Future-agent fix**: when writing a new cron prompt that references a `thread_ts`, ALSO include the channel id in the prompt (e.g. `channel=C0AUXSVFSA2, thread_ts=1785990587.321239`). The `thread_ts` alone is not enough — channels drift, threads migrate, side channels get created for verification work.

**Cross-tick pattern**: prior cron ticks on the same PR #8787 thread (`1785990587.321239`) had already tried the obvious channels and failed — those failed attempts are visible in the prompt's history. Future crons inheriting this prompt should read the LAST 5-10 messages on the prompt's thread_ts (via `conversations_replies`) BEFORE composing their own post — they'll see the prior attempts and the channel-resolution failure pattern.
