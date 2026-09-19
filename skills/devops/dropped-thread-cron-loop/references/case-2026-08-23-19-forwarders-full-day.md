# Dropped-thread daily-batch — 19 forwarders in one daily-thread (2026-08-22 → 2026-08-23)

## Trigger

`${SLACK_CHANNEL_ID}/1787386595.347729` (daily-thread, `#all-jleechan-ai`)
accumulated **19 per-thread forwarders** from MCP Agent Mail bot
(`U0A4G7LDJ4R` / `B0A3MS7G08P`) across ~30 hours
(2026-08-22T07:41Z → 2026-08-23T02:59Z). Each forwarder points at a
**different underlying thread** spanning 3 channels: `#worldai`
(`C0AH3RY3DK6`), `#jleechanbrain` (`C0AJ3SD5C79`), and `#all-jleechan-ai`
itself (the operator's personal channel).

## Class distribution

| # | Cited thread | Channel | Class | Underlying state |
|---|---|---|---|---|
| 1 | `C0AH3RY3DK6/p1787218494789569` | #worldai | done / shipped | PR #9242 + #9243 OPEN+MERGEABLE, pre-existing origin/main CI debt |
| 2 | `C0AH3RY3DK6/p1787205681983699` | #worldai | done / shipped | PR #9150 OPEN+MERGEABLE, 22S/2 pre-existing FAIL |
| 3 | `C0AH3RY3DK6/p1787242310815029` | #worldai | done / shipped | PR #9203 OPEN+MERGEABLE, 17S/1 pre-existing FAIL |
| 4 | `C0AH3RY3DK6/p1787242833516949` | #worldai | done / shipped | PR #9101 OPEN+MERGEABLE, head=8e0bfdf084, 11/11 review threads resolved |
| 5 | `C0AH3RY3DK6/p1787261209775249` | #worldai | done / merged | PR #9206 MERGED 2026-08-22T20:59:16Z by ${GITHUB_USER} |
| 6 | same as #5 | (duplicate) | done / merged | Same thread, same template |
| 7 | `C0AH3RY3DK6/p1787264020542439` | #worldai | done / merged | PR #9098 MERGED 2026-08-21T05:23:44Z by ${GITHUB_USER} (god-mode narrative placeholder) |
| 8 | `C0AJ3SD5C79/p1787427880161399` | #jleechanbrain | done / shipped (with separate OAuth handoff) | gws banned, gog upgraded v0.10.0→v0.37.0, 12 skills rewritten; OAuth re-consent pending operator browser paste |
| 9 | same as #8 | (duplicate) | done / shipped | Same thread, same template |
| 10 | `C0AJ3SD5C79/p1787427895844229` | #jleechanbrain | done / awaiting decision | "Read the analysis then double check it and research fresh" done; "Should we just use gog?" answered; 3 implementation moves queued pending Jeffrey explicit "do it" |
| 11 | same as #10 | (duplicate) | done / awaiting decision | Same thread, same template |
| 12 | `C0AH3RY3DK6/p1787294865360509` | #worldai | done / shipped + in-flight sub-task | PR #835 OPEN+MERGEABLE, hanji wiki refresh done; sub-task "add unit tests + fix PR comments + /ready + merge approved once /ready AND /web-advice approved" — P1/P2 fixed, 19/19 tests pass, blocked on CodeRabbit not posting APPROVED |
| 13 | `C0AH3RY3DK6/p1787296665156669` | #worldai | done / no-op (synthetic) | Thread root is dark-factory E2E alert test `Verdict: VERIFIED`, NOT a real user goal |
| 14 | `C0AH3RY3DK6/p1787297316799179` | #worldai | done / no-op (synthetic) | Same synthetic-probe class as #13, different host timestamp |
| 15 | same as #14 | (duplicate) | done / no-op (synthetic) | Same thread, same template |
| 16 | `C0AH3RY3DK6/p1787296781666669` | #worldai | done / awaiting decision | "Should we delete Design Doc Grep Gates?" answered with 3-option table; cron `a590507718f7` armed 24h, will post 1 reminder then self-cancel |
| 17 | `${SLACK_CHANNEL_ID}/p1787447685478169` | #all-jleechan-ai | done / no-op + harness bug surfaced | "Check cmux what are my terminals doing" done (16 ws / 51 surfaces / 6 healthy / 4 risky / 22 read-errors); 3rd in-thread ack surfaced real `_is_automated_report` script bug |
| 18 | `C0AH3RY3DK6/p1787341025098629` | #worldai | done / shipped | PR #9270 OPEN+MERGEABLE, agentic-hosting-hygiene Tier-1 fully shipped, 21/21 CI pass, 17/17 tests pass; mid-stream SPA regression caught + fixed in `3903625d3c` |

## New lessons (added 2026-08-23)

### Lesson 1 — `_is_automated_report` self-quoting recursion

The deeper mechanism behind the recursive probe loop is named in
forwarder #17. `~/.smartclaw/scripts/dropped-thread-followup.sh` defines
`_is_automated_report()` in **two copies** (around lines 720 and 1396
as of 2026-08-23). Neither copy recognizes the
`Ack: <thread-id> ... action needed: <yes|no>` format that
`mcp-mail-ack-format` documents. Result: agent `Ack:` replies get
treated as fresh human messages, the watcher concludes "still cold,"
fires another probe. Each probe nests the prior `Ack:` as the new
"Original request:" → recursion confirmed at depth 3+ on the
synthetic-probe threads (#13/#14/#15).

The fix is script-side, not agent-side:

```bash
# Add to BOTH _is_automated_report copies
if re.match(r'^Ack:\s+\S+\s+.*action needed:\s+(yes|no)\b', t, re.IGNORECASE):
    return True
if re.match(r'^Ack-of-ack:\s+\S+', t, re.IGNORECASE):
    return True
```

Surface as a `~/.smartclaw/` self-mod requiring operator opt-in
(no `/a` / `/finish` / `/af` triggered → use `harness-postmortem`
or explicit `patch the cron` opt-in). Do NOT auto-fix inline;
`hermes-deploy-pipeline` requires staging-repo PR + `deploy.sh`.

### Lesson 2 — Synthetic-probe `done / no-op` class is a real pattern

When the underlying thread root is an automated E2E health probe
(`UserID=U0BC138QXUJ hermes_pc`, body text starts `Dark Factory
Automated E2E Alert Test`, contains `Verdict: VERIFIED` + `Timestamp:`
+ `Host: jeff-ubuntu`), there is **no human ask**. Triage:
1. Confirm root `UserID` is `U0BC138QXUJ` (not `U09GH5BR3QU`)
2. Confirm body contains `Verdict: VERIFIED` AND `Automated E2E Alert Test`
   AND `Timestamp:`
3. Reply with `done / no-op` ack + synthetic-probe classification
4. Do NOT file a new work item, do NOT dispatch
5. Surface the cron-side fix as `patch the cron` opt-in

A regex-only short-circuit for `Automated E2E Alert Test` /
`Verdict: VERIFIED` is a useful companion fix to the Ack-skip-rule
above. Both can ship in the same `~/.smartclaw/scripts/dropped-thread-followup.sh`
patch.

### Lesson 3 — Cross-channel hops reach `#all-jleechan-ai` itself

Forwarder #17 cited the operator's personal channel
(`#all-jleechan-ai` / `${SLACK_CHANNEL_ID}`) — the daily-thread sits in the
same channel as the underlying cited thread. Recipe is unchanged:
extract URL → read underlying thread → classify → reply in underlying
thread → update daily-thread key. The cross-channel-into-self variant
is invisible to the recipe but worth noting: the operator's personal
channel is the highest-signal channel, so a per-thread forwarder
landing there is by definition worth reading, not auto-skipping.

### Lesson 4 — `done / merged` is its own class (verified)

PR #9206 (mobile UX, mergedAt=2026-08-22T20:59:16Z by ${GITHUB_USER})
and PR #9098 (god-mode narrative placeholder, mergedAt=2026-08-21T05:23:44Z
by ${GITHUB_USER}) both landed in this batch as `done / merged`. Stronger
than `done / shipped` (which means OPEN+MERGEABLE; merge is pending
operator `/green` or skeptic-cron). Reply with `state: merged —
action needed: no` and the `mergedAt` + `mergedBy` proof line.

### Lesson 5 — In-flight sub-tasks are SEPARATE work items

Forwarder #12 (`C0AH3RY3DK6/p1787294865360509`) cited a thread where
the original goal ("Just do it directly" → PR #835) is `done / shipped`
BUT a mid-thread pivot from Jeffrey ("add unit tests + fix PR comments
+ /ready + merge approved once /ready AND /web-advice approved") is
**in flight** — worker done, P1/P2 fixed, 19/19 tests pass, blocked on
CodeRabbit not posting APPROVED. The cron probe echoes the original
goal (which IS done); the in-flight sub-task is a separate live work
item that requires operator pick (skip CR / push again / run
/web-advice / wait). Ack the probe, surface the sub-task as
`awaiting decision`, do NOT bundle them into one ack.

## Forensic-ledger format

The daily-thread key `${SLACK_CHANNEL_ID}_1787386595.347729` in
`~/.smartclaw/logs/dropped-thread-state.json` ended the day with:
- `count = 18` (bumped on each forwarder ack)
- `gave_up = true` (set after first forwarder to skip future ones
  silently — see SKILL.md step 5)
- `reason_extra` = 3210+ chars documenting each forwarder's cited
  thread, triage class, and proof line, separated by ` | `

This is the ONLY way to recover the forwarder history later. The
state-file JSON is operator-visible via `cat ~/.smartclaw/logs/dropped-thread-state.json`
or the operator's daily-thread audit script.

## OUT-OF-BAND duplicate-forwarder pattern

This session saw 4 OUT-OF-BAND duplicate forwarders (forwarders #6
duplicate of #5, #9 duplicate of #8, #11 duplicate of #10, #15
duplicate of #14, #18 from OUT-OF-BAND duplicate of #18 from prior
turn). Each was handled with the recipe:

1. Verify body matches the prior forwarder template verbatim
   (same URL, same wording, same `@<U09GH5BR3QU>` mention)
2. Bump `count` by 1, append single-line `DUPLICATE of Nth` to
   `reason_extra`
3. Reply in underlying thread with SAME 5-step recipe (no fresh
   investigation, no PR re-check if already verified this session)
4. Keep reply SHORT — state underlying state unchanged, one-line
   summary + bumped counter
5. Include the `mcp-mail-ack-format` Ack line for forensic consistency

`never-hallucinate-no-new-content` is the governing skill — the
OUT-OF-BAND duplicate is the SAME bot forwarder via a SECOND
transport, NOT a new operator ask.
