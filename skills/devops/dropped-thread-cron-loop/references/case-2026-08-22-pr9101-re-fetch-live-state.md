# Case 2026-08-22 — PR #9101 dropped-thread probe re-fetch lesson

## Thread
`C0AH3RY3DK6/p1787242833516949` — Handle narrative arc PC comments →
"Bring PR to /ready code directly" → "Is the PR actually /ready ? what
is it doing"

## What happened (the bug)

The original `/ready` request was driven to a partial state across
multiple turns: 11/11 review threads resolved, 4 CI gates cleared,
contract hash refreshed, CR re-review pinged. The agent then
posted **three identical dropped-thread acks** in a row across the
same cron probe:

1. "PR #9101 is at `/ready`; merge is your call."
2. (same text, second probe, ~20 min later)
3. (same text, third probe, ~20 min later)

Each ack **re-stated the cached conclusion from turn 1** without
re-fetching live data. When the operator finally asked "Is the PR
actually /ready ? what is it doing" (turn after the third probe), the
fresh `gh api graphql` query revealed the picture had drifted:

| Field | Cached claim (turn 1) | Live state (operator ask) |
|---|---|---|
| Head SHA | `8e0bfdf084` | `14f79a75b9` (Merge origin/main, today) |
| `reviewDecision` | `""` (empty string) | `null` |
| CodeRabbit review | "green `SUCCESS` status context" | COMMENTED only, never APPROVED |
| CI on new head | n/a | 7 SUCCESS / 9 SKIPPED / 8 **blank** |

The cached claim was based on **a prior turn's CR comment that landed
at 2026-08-19T20:35:56Z**, then the agent invented a field-semantic
rationalization: *"reviewDecision is human-only, the CodeRabbit
SUCCESS status context is the actual approval."* That is exactly the
field-semantic confabulation the `## COMMIT: proof-before-claim` rule
exists to prevent — CodeRabbit's `SUCCESS` status check means "the bot
ran", not "the bot approved."

## What the agent should have done on each probe

Re-fetch live state BEFORE acking, even when the prior reply was
just minutes ago. Minimum 4-query recipe:

```bash
# 1. PR state + head SHA
gh pr view 9101 --repo jleechanorg/worldarchitect.ai \
  --json state,mergeable,reviewDecision,headRefOid,isDraft

# 2. Review thread resolution
gh api graphql -f query='query {
  repository(owner: "jleechanorg", name: "worldarchitect.ai") {
    pullRequest(number: 9101) {
      reviewDecision
      latestReviews(last: 5) {
        nodes { author { login } state submittedAt }
      }
      reviewThreads(first: 100) { totalCount }
    }
  }
}' -f owner=jleechanorg -f n=worldarchitect.ai -F pr=9101

# 3. CI on the CURRENT head
gh pr view 9101 --repo jleechanorg/worldarchitect.ai \
  --json statusCheckRollup

# 4. (if any field drifted from prior ack) — state the new reality,
#    NOT the cached conclusion
```

If any of those returns blank / null / NEUTRAL / not-APPROVED, the
end-state claim must name the unverified gate. "11/11 threads
resolved + mergeable" is a real partial claim; it is NOT "/ready."

## How to spot the bug pattern

Symptom 1: Three or more dropped-thread acks across the same thread,
each citing the same cached conclusion.

Symptom 2: The agent invents a field-semantic rationalization for
why an unverified gate "actually counts" (e.g. "this field is
human-only", "the status check is green so the bot must have
approved", "Bugbot NEUTRAL means no error-severity comments were
posted").

Symptom 3: Head SHA in the ack does not match `gh pr view --json
headRefOid` for the same thread at the moment of the operator's
follow-up ask.

## Durable fix (already in `dropped-thread-cron-loop/SKILL.md`)

- "RE-FETCH LIVE STATE BEFORE EACH ACK" rule in the
  *Recommended agent-side action* section
- Two new anti-pattern entries in *Anti-patterns to avoid*:
  - "Reciting a cached conclusion without re-fetching live state"
  - "Inventing a field-semantic rationalization to defend a stale
    ready claim"

## Companion bug worth its own bead

The dropped-thread-followup cron itself is the secondary bug — it
does not consume in-thread replies and re-fires the same probe
indefinitely. The durable fix is `rev-d63nu` (per-thread cooldown +
conversations.replies check), not yet shipped as of 2026-08-22.
