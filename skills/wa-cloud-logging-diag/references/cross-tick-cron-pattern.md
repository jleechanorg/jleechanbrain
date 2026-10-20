# Cross-tick cron pattern (3rd+ tick on the same thread)

If your cron is the 3rd+ invocation on the same `thread_ts`, you are inheriting prior cron context. Read it before posting.

## Step 1: Resolve the channel (thread_ts alone is not enough)

The thread may live in a side channel, not the obvious one. Verified 2026-08-06: thread `1785990587.321239` lives in `C0AUXSVFSA2`, NOT in the obvious `C0AH3RY3DK6` (`#worldai`).

```bash
THREAD_TS=1785990587.321239

# Best: search.messages (one call, returns the channel)
CHANNEL=$(curl -fsS -H "Authorization: Bearer $SLACK_USER_TOKEN" \
  "https://slack.com/api/search.messages?query=$THREAD_TS&count=1" | jq -r '.messages.matches[0].channel.id // empty')

# Fallback: try candidate channels in order
for try_chan in C0AH3RY3DK6 C0AJQ5M0A0Y C0AUXSVFSA2 ${SLACK_CHANNEL_ID}; do
  result=$(curl -fsS -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
    "https://slack.com/api/conversations.replies?channel=$try_chan&ts=$THREAD_TS&limit=1" | jq -r '.ok // false')
  if [ "$result" = "true" ]; then
    CHANNEL=$try_chan
    break
  fi
done
```

Do NOT post before the channel is known. A misrouted `chat.postMessage` becomes a top-level channel post, which the dropped-thread cron will then nudge you about.

## Step 2: Read the last 5 messages before posting

```bash
curl -fsS -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
  "https://slack.com/api/conversations.replies?channel=$CHANNEL&ts=$THREAD_TS&limit=5" | jq '.messages[] | {ts, user, text: .text[0:200]}'
```

## Step 3: Decide what to do based on prior ticks

| Prior-tick pattern | Your action |
|---|---|
| Two or more `:red_circle:` posts on the same verification step | The prior assumption (URL/hash/identifier) is stale. **Re-derive every input from the live source** before posting your own verdict. |
| A prior `:large_green_circle: PASSED` post by a different bot identity | Verification is already done. Post a short "no action needed" ack and self-cancel. Do not re-verify and re-post green. |
| **Operator has acknowledged completion** (e.g. `:tada: PR #N — Deliverable 3 CAPTURED. All 3 deliverables complete.`) AND multiple agent identities have already posted `:large_green_circle: PASSED` excerpts | **Silent self-cancel — no Slack post at all.** The cron delivery channel is the operator's DM; reply there with the PASSED factual summary and self-cancel. Posting another `:large_green_circle:` on Slack is duplicate noise on a thread the operator already closed. Verify-internal (your own Cloud Logging query) is fine if you want belt-and-suspenders proof, but do not re-post the JSON excerpt a third time. |
| A user-pinged message in the thread (e.g. "did this land?") | Your reply should answer THAT specific question, not re-run the full verification. |
| Multiple `:large_yellow_circle: queue wait` polls with no state change | Collapse to one yellow reply per state transition, not per tick. The user has been burned by over-posting — see "burning turns" pitfall below. |
| Static-bundle grep returns 0 events BUT Cloud Logging shows the events firing from the same deployed commit | **Report GREEN with a non-blocking bundle-anomaly note.** The end-to-end evidence (Cloud Logging) is the deliverable, not the static-bundle string check. The bundle mismatch is real (build pipeline / rotated asset / different code path emits the event) but does not affect the pass/fail verdict. See SKILL.md pitfall "Bundle-vs-Cloud-Logging mismatch is real and non-blocking". |

## The "burning turns" pitfall

Verified 2026-07-31, Slack `${SLACK_CHANNEL_ID}/1784235989.925899`. User verbatim: *"I'll stop replying until you send something new, otherwise I'm just burning turns."*

Applied to cron design: if your cron is scheduled "every 10 min for 24h," that's 144 crons. Budget is **1-3 substantive replies**, not 144.

When the cron resolves to a green terminal state, post **ONE** final reply and self-cancel.
When it resolves to a multi-tick waiting state, post at most **ONE** `:large_yellow_circle:` per state transition (e.g. queued → in_progress → completed), NOT one per tick.

## Worked example: PR #8787 smoke test cron (2026-08-06)

The cron prompt specified:
- Watch run `31072371181` (originally queued)
- Bundle-check `auth.433593ec.js` (hardcoded)
- Smoke test as jleechan@gmail.com
- Post to thread `1785990587.321239`

What actually happened across 3 cron ticks:

| Tick | What the cron did | Result |
|---|---|---|
| #1 (partial-stack proof) | Resolved channel as `C0AH3RY3DK6`, posted `:large_green_circle: PASSED` (used synthetic POST short-circuit from `wa-cloud-logging-diag` SKILL.md) | Green. |
| #2 (this session's first poll) | Tried `auth.433593ec.js`, got 0 matches, posted `:red_circle: FAILED` | **WRONG** — the deploy was rotated; the live hash is `auth.438addf6.js`. |
| #3 (this session) | Read prior 5 messages, saw two `:red_circle:` posts with the same hardcoded hash, re-derived hash from `curl -fsS <preview>/ \\| grep -oE 'src="[^"]*auth[^"]*\\.js"'` → got `auth.438addf6.js`, ran Cloud Logging query, posted `:large_green_circle: PASSED` with full JSON excerpt | Green. |
| #4 (this session, 2nd poll) | Static-bundle grep on `auth.438addf6.js` + `app.a26f55f9.js` still returned 0 events even though source files at commit `0a9d234` contain them. **The two prior `:large_green_circle: PASSED` posts (from `U0AEZC7RX1Q` hermes + `U0A4G7LDJ4R` mcp_agent_mail) on the smoke-test thread should have triggered silent self-cancel** per the table row above. Instead, posted a third PASS with the JSON excerpt and a non-blocking "Bundle anomaly" note. **Judgment lesson**: when the deliverable proof is Cloud Logging and the static-bundle check is a sanity-only pre-flight, the bundle mismatch is FYI for the worker, not a fail. | Green (with bundle-anomaly note). The cron should have self-cancelled per the "Operator has acknowledged completion" rule — the prior PASS posts and the operator's celebration would have triggered silent self-cancel had that been read first. |

The fix in #3 was not new code — it was reading the prior tick's mistake and re-deriving the input. The "skill" half is the wa-cloud-logging-diag SKILL.md recipe. The "judgment" half is "don't trust the prompt's hardcoded value when two prior ticks already burned on it."

## Cross-tick inheritance checklist

Before posting any reply on the 2nd+ cron tick:

- [ ] Read the prior 5 messages via `conversations.replies` on the resolved channel.
- [ ] If prior ticks had `:red_circle:`, identify the failing assumption (URL, hash, run id, project id) and re-derive it from a live source.
- [ ] If the verification was already `:large_green_circle: PASSED` by a prior tick, post a short ack and self-cancel — do not re-verify.
- [ ] If the user asked a new question in-thread, answer it — do not re-run the same verification.
- [ ] If multiple ticks have posted yellow `:large_yellow_circle:` polls with no state change, collapse to one final reply.
