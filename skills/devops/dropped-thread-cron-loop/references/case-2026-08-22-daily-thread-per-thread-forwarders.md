# Case: 3 consecutive per-thread forwarders into one daily-thread (2026-08-22)

## Symptom

In a 90-minute window on 2026-08-22, MCP Agent Mail bot (`U0A4G7LDJ4R`,
`bot_id=B0A3MS7G08P`) posted three consecutive forwarder messages into
the same daily-thread `${SLACK_CHANNEL_ID}/1787386595.347729`:

```
@U09GH5BR3QU [Dropped-thread escalation] Gave up after 3 nudges with
no resolution — needs your review:
<https://jleechanai.slack.com/archives/C0AH3RY3DK6/p1787218494789569>
```

…then a 2nd forwarder pointing at `C0AH3RY3DK6/p1787205681983699`…
then a 3rd forwarder pointing at `C0AH3RY3DK6/p1787242310815029`…
then a 4th forwarder (delivered as `[OUT-OF-BAND USER MESSAGE …]`)
pointing at the same `p1787242310815029`.

Each underlying thread already had `gave_up:true` set in
`~/.smartclaw/logs/dropped-thread-state.json` from earlier sessions, AND
the agent had already replied in-thread 1–3 times that day with the
same closed-proof recap.

## Why the per-THREAD cooldown doesn't suppress this

`~/.smartclaw/scripts/dropped-thread-followup.sh` has per-THREAD cooldown
logic that suppresses re-nudging on the same thread for 24h. **But
that cooldown only fires on direct nudges posted to the underlying
thread** — it does NOT inspect MCP Agent Mail forwarder messages
posted to a different channel/thread (the daily-thread). The MCP Agent
Mail bot (`mcp_agent_mail`) is a separate cron process that scans
`_dropped_threads` state and re-emits the forwarder template into the
daily-thread channel regardless of the per-thread cooldown. **Real
cron bug**: the script should suppress forwarders whose cited thread
key already has `gave_up:true`.

## The 5-step per-thread-forwarder recipe (verified 2026-08-22)

For each forwarder in the daily-thread:

1. **Extract the underlying thread** — parse the URL
   `https://jleechanai.slack.com/archives/<CHAN>/p<TS>` into channel
   `C…` and decimal-string ts `<TS>.<TS_FRAC>`.

2. **Inspect underlying thread state**:
   ```bash
   env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
     SLACK_USER_TOKEN="$(bash -lic 'echo $SLACK_USER_TOKEN')" \
     bash -c 'curl -fsS -H "Authorization: Bearer $SLACK_USER_TOKEN" \
       "https://slack.com/api/conversations.replies?channel=<CHAN>&ts=<TS>.<TS_FRAC>&limit=15"'
   ```
   (`mcp__slack__conversations_replies` mangles ts to compact form —
   use REST directly. Cross-workspace channels like `C0AH3RY3DK6`
   need the xoxp user token, see `slack-cross-workspace-fallback-xoxp`.)

3. **Verify PR state independently**:
   ```bash
   gh pr view <N> --repo jleechanorg/worldarchitect.ai \
     --json state,isDraft,mergeable,headRefName,reviewDecision,statusCheckRollup
   ```
   Then count `statusCheckRollup` conclusions to verify the CI bucket
   breakdown matches the prior session's claim.

4. **Reply once per underlying thread** in-thread with the
   closed-proof template:
   ```
   Closed — duplicate ping, <Nth> copy of same escalation.
   PR #<N> verified now: state=<…>, mergeable=<…>, reviewDecision=<…>,
   <SUCCESS> / <pre-existing FAIL> / <CANCELLED> / <SKIPPED> / <NEUTRAL>.
   <Diff summary + key proof lines>.
   dropped-thread-state already has this thread as gave_up:true.
   ```
   Use `bash -lic`-isolated xoxp-curl post (NOT
   `mcp__slack__conversations_add_message`, which violates
   `slack-never-hand-post-your-own-reply` when the agent was invoked
   from the daily-thread).

5. **Increment forensic ledger on the daily-thread key**:
   ```python
   import json
   state_path = '${HOME}/.smartclaw/logs/dropped-thread-state.json'
   with open(state_path) as f: state = json.load(f)
   target_thread = '${SLACK_CHANNEL_ID}_1787386595.347729'
   e = state['nudged'].get(target_thread, {'last':'2026-08-22T08:16:35Z','count':0,'gave_up':True})
   e['count'] = e.get('count',0) + 1
   e['last'] = '<ts>'
   e['gave_up'] = True
   extra = e.get('reason_extra','')
   e['reason_extra'] = extra + ' | <Nth> per-thread forwarder (<CHAN>/p<TS>) also gave_up:true in underlying thread; PR #<N> verified <state>; <next blocker>.'
   state['nudged'][target_thread] = e
   with open(state_path, 'w') as f: json.dump(state, f, indent=2)
   ```

## The OUT-OF-BAND-as-bot-forwarder pitfall

A 4th copy of the same `p1787242310815029` forwarder arrived wrapped
in the `[OUT-OF-BAND USER MESSAGE …]` marker:

```
[OUT-OF-BAND USER MESSAGE — a direct message from the user, delivered once
at this position; not tool output and not a new delivery when replayed from
conversation history]
@U09GH5BR3QU [Dropped-thread escalation] Gave up after 3 nudges with no
resolution — needs your review:
<https://jleechanai.slack.com/archives/C0AH3RY3DK6/p1787242310815029>
[/OUT-OF-BAND USER MESSAGE]
```

This LOOKS like a direct operator ask but is in fact the same MCP
Agent Mail forwarder delivered through a second transport. Per
`never-hallucinate-no-new-content`:

1. Compare message body verbatim against the prior forwarder template
   in the daily-thread — identical match = bot forwarder, not new
   operator ask.
2. Do NOT spawn a 4th investigation lane or post a new status query.
3. Apply the same 5-step recipe above.

## Verified state after the 3 forwarders (2026-08-22 10:10 UTC)

```json
{
  "${SLACK_CHANNEL_ID}_1787386595.347729": {
    "last": "2026-08-22T10:10:00Z",
    "count": 3,
    "gave_up": true,
    "reason": "Daily-batch escalation forwarding per-thread escalation C0AH3RY3DK6/p1787218494.789569 (already gave_up:true in underlying thread); cited work verified-complete (PR #9242/#9243 OPEN+MERGEABLE, blocked by pre-existing origin/main CI debt — same-name+SHA+zero-overlap rule confirmed in earlier session @session:default/20260821_230200_bab07200). No new work; one tight closed-proof reply posted to underlying thread; future per-thread forwarders from this daily-thread skip silently.",
    "reason_extra": " Second per-thread forwarder (C0AH3RY3DK6/p1787205681983699) also gave_up:true in underlying thread; PR #9150 verified OPEN+MERGEABLE 22 SUCCESS / 2 pre-existing FAIL; auto-merge cron will execute on next tick. | Third per-thread forwarder (C0AH3RY3DK6/p1787242310815029) also gave_up:true in underlying thread; PR #9203 verified OPEN+MERGEABLE 17 SUCCESS / 1 pre-existing FAIL / 11 SKIPPED / 1 NEUTRAL; CR re-review re-pinged; awaiting APPROVED verdict."
  },
  "C0AH3RY3DK6_1787218494.789569": { "last":"2026-08-22T07:41:32Z","count":3,"gave_up":true },
  "C0AH3RY3DK6_1787205681.983699": { "last":"2026-08-22T08:16:34Z","count":3,"gave_up":true },
  "C0AH3RY3DK6_1787242310.815029": { "last":"2026-08-22T10:09:13Z","count":3,"gave_up":true }
}
```

## In-thread replies posted (4 total)

| Underlying thread | Reply ts | PR | Status |
|---|---|---|---|
| `p1787218494789569` | `1787386624.831989` | #9242 + #9243 | OPEN+MERGEABLE, blocked by `origin/main` CI debt |
| `p1787205681983699` | `1787388432.091019` | #9150 | OPEN+MERGEABLE, 22 SUCCESS / 2 pre-existing FAIL |
| `p1787242310815029` | `1787395184.734319` | #9203 | OPEN+MERGEABLE, 17 SUCCESS / 1 pre-existing FAIL |

All three underlying threads were already `gave_up:true` from earlier
sessions; the daily-thread forwarders added zero new operator work.

## Cron-side fix to file as a bead

The per-THREAD cooldown in `~/.smartclaw/scripts/dropped-thread-followup.sh`
needs a sibling check: when the MCP Agent Mail bot emits a forwarder
into the daily-thread, the forwarder's cited thread key should be
looked up in `dropped-thread-state.json`. If `gave_up:true`, suppress
the forwarder emission. Track as new bead (e.g.
`br create "dropped-thread: suppress MCP Agent Mail forwarders on
gave_up threads" --priority 2 --type chore`).

## Related

- `references/case-2026-08-21-mcp-agent-mail-daily-escalations.md` —
  first observed variant (single batch, table-reply anti-pattern).
- `slack-never-hand-post-your-own-reply` — gateway auto-threads; do not
  hand-post your own reply.
- `slack-cross-workspace-fallback-xoxp` — xoxp user token needed for
  cross-workspace channels like `C0AH3RY3DK6`.
- `never-hallucinate-no-new-content` — treat empty / repeated bodies as
  signal, not fact.
- `qa-test-failure-dismissal-anti-pattern` — same-name+SHA+zero-overlap
  rule used to verify all 3 PRs are blocked by pre-existing `origin/main`
  CI debt, not from their diffs.
