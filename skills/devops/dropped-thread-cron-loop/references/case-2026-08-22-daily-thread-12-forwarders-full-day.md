# Case: 12 forwarders into one daily-thread across a full day (2026-08-22)

## Symptom

Same daily-thread `${SLACK_CHANNEL_ID}/1787386595.347729` received **12
per-thread forwarders** from MCP Agent Mail (`U0A4G7LDJ4R`) across
roughly 6 hours (mid-morning through evening PT). The 3-forwarder case
in `case-2026-08-22-daily-thread-per-thread-forwarders.md` was the
morning slice; this case is the full-day extension.

## Forwarder log

| # | Cited thread | Channel | Underlying state | Class |
|---|---|---|---|---|
| 1 | `C0AH3RY3DK6/p1787218494789569` | #worldai | PR #9242/#9243 OPEN+MERGEABLE | done / no-op |
| 2 | `C0AH3RY3DK6/p1787205681983699` | #worldai | PR #9150 OPEN+MERGEABLE | done / no-op |
| 3 | `C0AH3RY3DK6/p1787242310815029` | #worldai | PR #9203 OPEN+MERGEABLE | done / no-op |
| 4 | `C0AH3RY3DK6/p1787242833516949` | #worldai | PR #9101 OPEN+MERGEABLE (11/11 threads resolved, 3rd duplicate cron probe same day) | done / no-op |
| 5 | `C0AH3RY3DK6/p1787261209775249` | #worldai | PR #9206 **MERGED** 2026-08-22T20:59:16Z by ${GITHUB_USER} | done / shipped |
| 6 | (duplicate of 5) | #worldai | PR #9206 still MERGED | done / shipped (duplicate) |
| 7 | `C0AH3RY3DK6/p1787264020542439` | #worldai | PR #9098 MERGED on main 2026-08-21T05:23:44Z, interpretation-2 fix in commit 530d4f92a8 | done / shipped |
| 8 | `C0AJ3SD5C79/p1787427880161399` | #jleechanbrain | gws banned on Mac + /linux, gog upgraded v0.10.0→v0.37.0, /google command bans gws, 12 skill files rewritten | done / shipped (OAuth re-consent pending operator browser paste — separate work item) |
| 9 | (duplicate of 8) | #jleechanbrain | same | done / shipped (duplicate) |
| 10 | `C0AJ3SD5C79/p1787427895844229` | #jleechanbrain | cited goal "Read analysis + double check + research fresh" done; "Should we just use gog?" answered with cost math + 4-step recipe; 3 implementation moves queued pending operator "do it" | done / awaiting decision |
| 11 | (duplicate of 10) | #jleechanbrain | same | done / awaiting decision (duplicate) |
| 12 | `C0AH3RY3DK6/p1787294865360509` | #worldai | original "Just do it directly" done (PR #835 opened, wiki refreshed for hanji's 4/4 campaigns); mid-thread pivot "add unit tests + /ready + merge approved once /ready AND /web-advice approved" in flight — P1/P2 fixed, 19/19 tests pass, head e0f7aa9125, /ready Gate 4 blocked on CodeRabbit not posting APPROVED | done / shipped + live sub-task |

## Patterns observed

### 1. Cross-channel forwarders into one daily-thread

The daily-thread `${SLACK_CHANNEL_ID}/1787386595.347729` (operator direct
channel `#all-jleechan-ai`) is a single transport for forwarders
pointing at MANY different channels. The 12 forwarders above pointed
at 2 distinct channels (`#worldai` and `#jleechanbrain`). The 5-step
recipe still works — extract the URL → read underlying thread via
`conversations_replies` → classify → reply in underlying thread →
update daily-thread key. No code change needed; just be aware the
underlying state lives in N different channels.

### 2. Forwarder cites a MERGED PR (cases 5, 7)

When the cited thread's PR is already MERGED, the cron probe is
echoing a goal that shipped before the cron started pinging. Verify
with `gh pr view <N> --json state,mergedAt,mergedBy` — if
`state=MERGED`, that's a `done / shipped` ack, not
`awaiting decision`. Note any post-merge follow-up asks the operator
posted in-thread (they are separate work items, not this cron probe).

### 3. Forwarder cites a thread with a live in-flight sub-task (case 12)

When the cited thread contains BOTH (a) the original cron probe's
goal, already done, AND (b) a mid-thread pivot from the operator to a
new sub-task that is still in flight, the cron probe echoes (a). The
correct ack is `done / shipped` for (a) with a one-line flag that
(b) is a separate work item awaiting operator decision. Do NOT
bundle (b) into the cron ack — that conflates the probe with a live
dispatch state and confuses the forensic ledger.

### 4. Per-THREAD cooldown confirmed broken for forwarders

12 forwarders today, 5 unique underlying threads, ~2.4x duplicates on
average. The per-THREAD cooldown in
`~/.smartclaw/scripts/dropped-thread-followup.sh` does not suppress MCP
Agent Mail forwarders whose cited thread already has `gave_up:true`.
This is a confirmed production bug; see the cron-side-fix bead in
`case-2026-08-22-daily-thread-per-thread-forwarders.md`.

### 5. JSON-mutation pitfall: jq quoting conflict (worked example)

When bumping the daily-thread key's `reason_extra` with embedded
double-quotes (e.g. citing an operator message verbatim), `jq` fails
with a syntax error:

```bash
# BROKEN — embedded quotes clash with jq string literal
jq '.nudged["${SLACK_CHANNEL_ID}_1787386595.347729"].reason_extra += " | Cited goal \"Obviously still not working\" IS done"' \
  ~/.smartclaw/logs/dropped-thread-state.json
# jq: error: syntax error, unexpected IDENT, expecting end of file
```

**Fix: use python3 heredoc instead.** Python's `json` module
handles the quoting for you:

```bash
python3 - <<'PYEOF'
import json
state_path = "${HOME}/.smartclaw/logs/dropped-thread-state.json"
extra = (" | Twelfth per-thread forwarder — DIFFERENT THREAD in #worldai. "
         "Cited goal 'Just do it directly' IS done. ...")
with open(state_path) as f:
    state = json.load(f)
state["nudged"]["${SLACK_CHANNEL_ID}_1787386595.347729"]["count"] = 12
state["nudged"]["${SLACK_CHANNEL_ID}_1787386595.347729"]["reason_extra"] += extra
with open(state_path, "w") as f:
    json.dump(state, f, indent=2)
PYEOF
```

This worked 12 times in a row during the 2026-08-22 batch. Use the
heredoc form (not `python3 -c "..."`) so you avoid shell-quoting
issues with `f-strings` or backslashes inside the JSON string.

**Note on `execute_code`:** `execute_code` runs in the session's
active Python venv — if that venv is stale or missing
(`${HOME}/projects_other/hermes-agent/.venv/bin/python3` was
missing in this session), the call fails with
`No such file or directory`. Fall back to `terminal` +
`python3 - <<'PYEOF'`, which uses system Python directly and avoids
the venv trap.

### 6. `slack-never-hand-post-your-own-reply` works under high-volume

12 in-thread acks posted via the gateway path all landed in the
correct underlying threads (verified by `ts`/`thread_ts` pair on
each ack). No "thread reply landed in channel root" regressions
observed. The `slack-cross-workspace-fallback-xoxp` recipe was NOT
needed this batch — `conversations_replies` worked cross-channel
fine via the built-in MCP tool, and the gateway auto-threaded the
model-output reply into the underlying thread.

## Daily-thread state after the 12-forwarder batch

```json
{
  "${SLACK_CHANNEL_ID}_1787386595.347729": {
    "last": "2026-08-22T21:46:32Z",
    "count": 12,
    "gave_up": true,
    "reason": "Daily-batch escalation forwarding per-thread escalation C0AH3RY3DK6/p1787218494.789569 (already gave_up:true in underlying thread); cited work verified-complete (PR #9242/#9243 OPEN+MERGEABLE, blocked by pre-existing origin/main CI debt — same-name+SHA+zero-overlap rule confirmed in earlier session @session:default/20260821_230200_bab07200). No new work; one tight closed-proof reply posted to underlying thread; future per-thread forwarders from this daily-thread skip silently.",
    "reason_extra": " <12 forwarders, ~3500 chars, full forensic ledger of which cited threads got which class>..."
  }
}
```

## Triage class distribution

- `done / no-op`: 3 (forwarders 1–4)
- `done / shipped`: 4 (forwarders 5, 6, 7, 8 + 9 duplicate)
- `done / awaiting decision`: 2 (forwarders 10, 11 + 12's original goal)
- `live in-flight sub-task` (separate from cron probe): 1 (forwarder 12 — PR #835 /ready gate)

The 5-step recipe applies uniformly across all classes. The only
class-specific variation is the ack template's action-needed line.

## Related

- `references/case-2026-08-22-daily-thread-per-thread-forwarders.md`
  — first 3-forwarder case (same day, morning slice).
- `references/case-2026-08-21-mcp-agent-mail-daily-escalations.md`
  — first observed variant (single batch, table-reply anti-pattern).
- `slack-never-hand-post-your-own-reply` — gateway auto-threads; do
  not hand-post your own reply.
- `mcp-mail-ack-format` — single-message ack format for MCP Agent
  Mail probes.
