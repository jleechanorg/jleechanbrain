---
name: slack-history-sweep
description: Sweep N Slack channels, classify threads, write JSON.
when_to_use: "Use when user asks to pull history from N >= 3 channels with a date window. Triggers: 'sweep slack history', 'audit last N days', 'classify slack threads', 'top N bug fixes from slack'."
tags: [slack, audit, history, threads, classification, sweep, multi-channel, mcp]
---

# Slack History Sweep — multi-channel batch fetch + classify

**Class:** batch data extraction + LLM-light classification. **Output:** JSON deliverable on disk (e.g. `/tmp/slack-<window>-sweep.json`).

## Inputs

| **channels** | list of channel IDs (with optional name labels) |
| **window_start** / **window_end** | ISO-8601 UTC timestamps |
| **classification_scheme** | default: 5 buckets (BUG_FIX / FEATURE_REQUEST / UNRESOLVED_SLACK_THREAD / INCIDENT / OTHER) |
| **output_path** | default: `/tmp/slack-<window>-sweep.json` |
| **limit_per_channel** | default: 200 messages per channel |

## Pipeline (deterministic; classification heuristic is keyword-based)

### Step 1 — Pre-flight bot membership probe (sequential, limit=1)

Before sweeping, verify the bot is a member of each channel. There's no explicit "is bot in channel" MCP call, but a cheap `conversations_history(channel_id=X, limit=1)` probe surfaces `not_in_channel` errors immediately. Record the outcome per channel; do NOT fan out `limit=200` calls on channels that will all fail.

```python
# Sequential, single call per turn (NOT parallel — the probe itself may
# saturate the MCP server if N is large)
for ch in CHANNELS:
    try:
        conversations_history(channel_id=ch, limit=1)
        channels_ok.append(ch)
    except NotInChannel:
        channels_skip.append((ch, "not_in_channel"))
```

### Step 2 — Batch fetch with size limit

For channels that passed the probe, fetch full `limit=200` history in **parallel batches of ≤ 6 channels**. Larger batches hit the MCP server's in-flight queue and trigger the "unreachable after 3 consecutive failures" cascade.

```python
# Parallel batches, ≤ 6 channels per batch
for batch in chunks(channels_ok, 6):
    results = await asyncio.gather(*[
        conversations_history(channel_id=ch, limit=200)
        for ch in batch
    ])
```

### Step 3 — Handle the four possible fetch outcomes per channel

| Outcome | What it means | What to do |
|---|---|---|
| **Full inline CSV** | Response < ~100 KB. Returned inline in tool result. | Parse `result` field as CSV directly. |
| **Persisted-output file** | Response > ~100 KB. Returned inline but tool wraps with `<persisted-output>` + path to `/var/folders/j0/.../hermes-results/call_<id>.txt`. | `read_file` the path, parse `{"result":"...CSV..."}` as JSON, then CSV. |
| **Inline preview only** | Response returned inline but truncated to ~1500-char preview without persisting the rest. | Use what you can see from the preview, document the limitation in the deliverable's `channels_in_scope[].status`. |
| **`not_in_channel` error** | Bot user is NOT a member of that channel. | Document as `status: not_in_channel` in the deliverable; skip. |

**Critical insight:** the boundary between "persisted to file" and "inline preview only" is NOT user-controlled. Always check both the inline content AND the `persisted-output` path. If neither is available, treat as preview-only.

### Step 4 — Recover from the parallel-call cascade

If the batch fetch trips `"MCP server 'slack' is unreachable after 3 consecutive failures"`:

1. **Do NOT retry the failed calls immediately** — the auto-retry counter is on the server side.
2. **Wait 30s** (`terminal(command="sleep 30 && echo done")`).
3. **Retry the failed channels ONE AT A TIME** in subsequent turns.

**Why this happens:** N parallel `conversations_history` calls (each returning up to 200 messages = 30K+ chars per call) saturates the MCP server's in-flight call queue. The server then trips its own retry counter for any subsequent calls in the same batch. Fix: fewer concurrent calls, longer waits.

**Recommended batch size:** ≤ 6 channels per parallel batch. For 14 channels, do 2 batches of 7 with a 5–10s sleep between, OR a single batch of 14 and accept that the last 3–4 will fail and need a sequential retry pass.

### Step 5 — Group messages by thread

For each channel, build a `thread_ts → messages[]` map. Top-level messages have `MsgID == ThreadTs`; replies have `MsgID != ThreadTs`. Cut off anything outside `[window_start, window_end]` at this step.

### Step 6 — Classify each thread

Apply the 5-bucket taxonomy. See `references/classification-taxonomy.md` for the heuristic details and keyword lists.

### Step 7 — Build deliverable

Write `/tmp/slack-<window>-sweep.json` with:

```json
{
  "generated_at": "<ISO-8601 UTC>",
  "window_start": "<ISO-8601 UTC>",
  "window_end": "<ISO-8601 UTC>",
  "channels_in_scope": [
    {"channel_id": "<id>", "channel_name": "<name>", "status": "fetched_full"},
    {"channel_id": "<id>", "channel_name": "<name>", "status": "fetched_inline_preview_only", "note": "..."},
    {"channel_id": "<id>", "channel_name": "<name>", "status": "not_in_channel", "note": "..."}
  ],
  "summary_counts": {"BUG_FIX": N, "FEATURE_REQUEST": N, "UNRESOLVED_SLACK_THREAD": N, "INCIDENT": N, "OTHER": N},
  "notes": ["..."],
  "threads": [
    {
      "channel_id": "<id>",
      "channel_name": "<name>",
      "thread_ts": "<ts>",
      "title_snippet": "<first 200 chars of parent message>",
      "classification": "<one of 5 buckets>",
      "key_entities": ["PR#1234", "issue#5678", "file.py:42", "MAX_TOKENS"],
      "last_bot_msg_summary": "<last bot reply, if any>",
      "last_user_msg_summary": "<last user reply, if any>",
      "status_signal": "finished | in_progress | pending | needs_decision",
      "parent_time": "<ISO-8601>",
      "reply_count": N,
      "last_reply_time": "<ISO-8601 or null>",
      "source": "fetched_full | inline_preview"
    }
  ]
}
```

### Step 8 — Print summary

Print totals per bucket + top-3 from each bucket. The user uses this as the headline output; the JSON file is the durable artifact.

## 5-bucket classification taxonomy

The default scheme covers the user's recurring ask shape ("top 10 bug fixes / top 10 feature requests / top 10 unresolved threads"):

| Bucket | Definition | Signals |
|---|---|---|
| **BUG_FIX** | Production bug being reported/fixed; mentions error sigs, repro steps, fix PRs. | "run /repro", "/repro ", "bug", "/rg fix", "merge approved", "/af on this", "fix ci", "fix this", "why are", "why is", "why did", "doesnt", "doesn't", "failing", "missing", "regression", "is this still needed", "is this fixed yet", "investigate and fix" |
| **FEATURE_REQUEST** | User wanting a new capability; not a bug. | "let's make a", "lets make a", "make a skill", "move ", "add a ", "add an ", "add support", "add the ability", "let's design", "lets design", "let's add", "lets add", "let's upgrade", "lets upgrade", "switch ", "wanna", "i wanna", "make sure we add", "prompt only change", "feature request" |
| **UNRESOLVED_SLACK_THREAD** | Still pending — last message < 24h ago or open question with no PR/fix yet, OR has user ask awaiting response. | User directives with no replies, short "Status" / "keep going" / "continue" nudges from the user. |
| **INCIDENT** | Deploy failure, sev, outage. | "urgent infra", "infra finding", "sev1", "sev2", "outage", "host becoming unresponsive", "load average just spiked", "deploy failure", "dev is down", "prod deploy", "server is down" |
| **OTHER** | Chatter, ack, status ping, bot/automated messages, cron reports. | Anything that doesn't match the above, OR is from a non-user bot identity (hermes / mcp_agent_mail / incoming-webhook). |

**Anti-meta-directive filter:** user messages that are META-DIRECTIVES (asking Hermes to do the work) are usually `OTHER` or `UNRESOLVED_SLACK_THREAD`, NOT `BUG_FIX`/`FEATURE_REQUEST`. Detect with phrases like:
- "Run /roadmap for last 2 weeks..."
- "Use /history /ms /wiki-search..."
- "Read this skill should we install..."
- "Make a plan..."
- "Look at all the campaigns..."

The bug/feature the user is asking about is downstream of the directive, not the directive itself.

## Pitfalls (verified)

- **Parallel-call cascade.** Verified — N parallel `conversations_history` calls saturate the MCP server and trigger "unreachable after 3 consecutive failures." Recovery: ≤ 6 channels per batch + 30s sleep + sequential retry for failures.
- **Bot not in channel ≠ fetch failure.** Verified — `not_in_channel` is a permanent condition until someone joins the bot to the channel. Do NOT retry; document as `status: not_in_channel`.
- **Inline-preview responses are NOT persisted to a file.** Verified — when MCP returns inline but the content exceeds the inline limit, the response is truncated without a `<persisted-output>` path. Treat as preview-only; document as `status: fetched_inline_preview_only`.
- **Cron/automated messages dominate the count.** Verified — daily cron reports, dropped-thread escalations, executive-assistant sweeps, AO progress reports, hermes bot self-messages, mcp_agent_mail bot messages. Filter these out FIRST via `UserID != <jleechan_user_id>` before applying the bug/feature classification heuristic, or every cron report gets mis-classified as `OTHER` but pollutes the `BUG_FIX` count if it contains error keywords.
- **Bot nonce messages** ("test ping XXXX", "FRESH-START XXXX", "verify bot identity", "ack-test-NNNN", "incoming-webhook :wave:") are user-test traffic, NOT user asks. Filter via keyword lists: `["test ping", "FRESH-START", "verify ", "inbound test", "outbound test", "incoming-webhook", "real-hermes-", "bypass-r", "mcp-final-", "xoxb-", "self-correction"]` → `OTHER`.
- **The "Run /roadmap" message** is a META-directive, not a bug or feature. Classify as `OTHER` or `UNRESOLVED_SLACK_THREAD` depending on whether the directive itself needs a reply.
- **Heuristic mis-classification is normal.** A keyword-based classifier will mis-categorize ~10–15% of edge cases. Always spot-check top-3 per bucket after classification; if they look wrong, refine the keyword lists and re-run. The deliverable should document the heuristic limits.
- **Do NOT fabricate missing data.** If a channel is preview-only and the relevant thread is NOT in the preview, do NOT make up entities or reply summaries. Leave `last_bot_msg_summary` and `last_user_msg_summary` as empty strings and document the gap.

## Cross-references

- `roadmap` SKILL.md Step 2 — the single-channel sweep pipeline that this skill extends
- `slack-thread-routing-investigation` SKILL.md — covers the `not_in_channel` failure mode at the message-SEND layer (different mechanism, similar outcome)
- `slack-cron-report-health` SKILL.md — covers cron jobs whose posts go missing; the pre-flight probe here can detect that
- `dropped-messages` SKILL.md — covers single dropped-message recovery, not multi-channel sweep
- `references/verified-session-2026-08-19.md` — worked example: 14 channels, 9 fetched, 5 `not_in_channel`, 3 `fetched_inline_preview_only`, 233 threads classified
- `references/classification-taxonomy.md` — detailed heuristic keyword lists per bucket
- `references/saved-for-later-is-saved-search.md` — adjacent but distinct: triaging `is:saved` "Save for later" backlog via `search.messages`; covers the Aside-REPL cursor-pagination break and date-partition workaround that this umbrella's pipeline does not.
- `templates/sweep.py` — starter Python script for the sweep + classify pipeline

## Verified instance — 2026-08-19

This skill was created from the lessons of sweeping 14 channels in parallel on 2026-08-19. The MCP server hit the parallel-call cascade after the first batch; 3 of the 14 channels returned `not_in_channel`; 3 returned inline preview only. The deliverable `/tmp/slack-14d-sweep.json` (160 KB, 233 threads classified) was produced using this pipeline. Counts: BUG_FIX: 45, FEATURE_REQUEST: 44, UNRESOLVED_SLACK_THREAD: 56, INCIDENT: 0, OTHER: 88.
