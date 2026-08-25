# RED evidence — Slack thread-misroute via `send_message` tool

**Claim under test:** LLM-initiated Slack posts from `send_message` land at CHANNEL ROOT instead of the active thread, because (D1) the tool schema documents thread targeting as Telegram/Discord-only, and (D2) the tool never reads `HERMES_SESSION_THREAD_ID`.

**System state during RED:** live prod gateway `ai.smartclaw.prod`, single instance, restarted 2026-08-16 22:18:35 PDT. SOUL.md mitigation **removed** (sha256 `1774be6e6928c4640129255776cd9e01cfdc9a9292acdeefd9133e4138aaa660`, 0 occurrences of `slack-send-tool-must-carry-thread-ts`). Real Slack workspace `jleechan AI` (T09FXQ4LCQP), real channel C0AUXSVFSA2. No mocks, no stubs.

## Stimulus (real Slack, posted as jleechan via SLACK_USER_TOKEN)

Thread root `1786943962.177919` @ 2026-08-17T05:19:22Z:
> [rg RED test - ignore] Two steps: (1) run `sleep 15` with the terminal tool. (2) Then use your send_message tool to post a progress narration to Slack with the exact text 'RED_MARKER_A1 progress narration'. Treat step 2 as a follow-up progress update for this thread.

Gateway intake (raw log line, `~/.smartclaw/logs/gateway.log`):
```
2026-08-16 22:19:23,362 INFO gateway.run: inbound message: platform=slack user=U09GH5BR3QU chat=C0AUXSVFSA2 msg='[rg RED test - ignore] Two steps: (1)
2026-08-16 22:19:57,717 INFO gateway.run: response ready: platform=slack chat=C0AUXSVFSA2 time=34.4s api_calls=4 response=113 chars
```

## Observed result — FAIL (bug reproduced)

Slack Web API `conversations.history` raw fields for the marker message:
```json
{"ts": "1786943996.160129", "user": "U0AEZC7RX1Q", "bot": "B0AEHUEA0JK",
 "thread_ts": "<ABSENT=CHANNEL ROOT>", "text": "RED_MARKER_A1 progress narration"}
```
- `thread_ts` **absent** ⇒ posted at channel root.
- Expected `thread_ts = 1786943962.177919` (the active thread root).
- Posted by the hermes bot identity (`U0AEZC7RX1Q` / `B0AEHUEA0JK`), i.e. the gateway agent's own tool call — not a human and not the gateway reply path (the gateway reply landed correctly in-thread at `1786943998.034029`).

## Decisive corroboration — the LLM believed it threaded

Hermes's own in-thread final message (`1786943998.034029`), verbatim:
> `'Sleep 15 ran (exit 0), then posted the marker text to the thread (msg ts 1786943996.160129). Both steps complete.'`

The agent asserts it posted **to the thread**, and cites the exact ts that Slack reports at channel root. This rules out the competing hypothesis "the LLM deliberately chose channel root": intent was to thread; the tool dropped it. The failure is in the tool contract, not agent whim.

## Static defect evidence (independent of this run)

Captured in `static-defect-evidence.txt`:
- **D1 schema gap** — `tools/send_message_tool.py` `target` description: `'platform:chat_id:thread_id' for Telegram topics and Discord threads`; Slack examples are bare-channel only (`slack:#engineering`).
- **D2 session-var gap** — `grep -c HERMES_SESSION_THREAD_ID tools/send_message_tool.py` = **0**. Vars it does read: `HERMES_SESSION_PLATFORM`, `HERMES_SESSION_USER_ID`, `HERMES_CRON_AUTO_DELIVER_THREAD_ID`. The var **is** exported (`gateway/session_context.py:13`) and **is** consumed by `terminal_tool.py`, `cronjob_tools.py`, `kanban_tools.py`.
- **Capability exists** — `_SLACK_THREAD_TARGET_RE` (line 34) + `resolve_send_target` (lines 551-554) accept `slack:<chan>:<thread_ts>`.

## Reproduction steps

1. Remove the `slack-send-tool-must-carry-thread-ts` COMMIT block from `~/.smartclaw/workspace/SOUL.md`; `launchctl kickstart -k gui/$UID/ai.smartclaw.prod`; confirm `✓ slack connected`.
2. Post the stimulus above as a new channel message (becomes thread root) in C0AUXSVFSA2.
3. After ~40s, `conversations.history` on the channel; locate the marker text; read its `thread_ts`.
4. FAIL condition (observed): `thread_ts` absent.

## Raw artifacts
- `red-slack-raw.txt` — unedited Slack API output (history scan + thread dump + agent's self-claim)
- `red-verdict.txt` — verdict line + SOUL.md sha
- `static-defect-evidence.txt` — code-level defect proof
- `soul-fix-block.md` — the exact mitigation text removed for RED (restored in GREEN)
