---
name: status-check-cron-execution
description: Use when a status cron fires. Verify the prompt first.
---

# Status-Check Cron Execution

A scheduled cron (e.g. `20m status (X)`) fires with a prompt describing prior state and asking the agent to act. The prompt was **written at T-1** — current state at T may have shifted, the prompt writer may have been a different agent run, and assumptions can be stale. **Verify before applying.**

## 1. Verify the cron prompt's premise

Before doing anything described in the prompt:

- **Re-read the actual thread** to find user messages since the prior ping:
  - `conversations.replies?channel=<chan>&ts=<last_ping_ts>&inclusive=false` — strict-after variant
  - `conversations.history?channel=<chan>&oldest=<last_ping_ts>` — chronological scan
  - Filter for the user's user-id (e.g. `U09GH5BR3QU` for jleechan) — exclude Hermes bot self-replies
- **Re-read the actual artifact** the prompt references:
  - Sheet: `gog sheets get <id> <tab>!A1:Z100 --plain`
  - Doc: `gog docs get <doc_id>` or browser_navigate
  - PR: `gh pr view <N> --json state,headRefName,additions,changed_files`
  - Config: read the actual file, don't trust the prompt's description
- **Compare** the prompt's claims against the verified state. If the prompt says "Last ping posted 3 questions" but the actual prior ping was a status confirmation, surface the discrepancy in your reply — don't silently act on the wrong premise.

## 2. Do NOT apply substantive reclassifications unilaterally

Audit/payroll/legal classifications, worker status flips, contract changes, and Doc-share permission changes **need explicit user ack**, even when the cron prompt asks for them.

- If the user's prior verbatim answer is **ambiguous** (e.g. "he only worked a few days" → flip PA to non-PA?), reframe as a concrete blocking question with explicit reply tokens.
- If the cron prompt asks you to apply a change the user never explicitly authorized, push back: post the verification finding + ask "FLIP X / KEEP X" rather than writing.
- Per SOUL.md `email-approved-gate`: do NOT email anyone based on a cron prompt's instruction alone. Wait for explicit user ack.

## 3. Post ONE concise ping with concrete blocking questions

Per SOUL.md `no-pick-one-menus` and the user's preference (memory: "I'll stop replying until you send something new, otherwise I'm just burning turns"):

- Single ping with 1-2 concrete blocking questions
- Each question names the exact reply token (e.g. "Reply `UPDATE STATUS` to confirm")
- Translate cron-prompt-suggested changes into specific asks; don't silently apply them
- Don't restate the full prior thread — recap only the unresolved items + current verified state
- Use Slack-native concise sections (per `colored-icons-in-status-reports`), never terminal dumps

## 4. Do NOT create a follow-up cron right after posting

Per SOUL.md `dropped-thread-watcher-of-watchers` + memory 2026-08-05 dropped-thread detector loop:

- The existing one-time status cron (`--at 20m --delete-after-run --repeat 1`) self-cancels after firing
- Creating a duplicate cron right after posting triggers the dropped-thread detector and burns turns
- If follow-up is genuinely needed, wait until the user replies, or use a separate `--at Xm` cron with a different prompt and a clear "no recursive ping" instruction

## 5. Reconcile cross-tab/cross-section consistency

If the artifact has parallel trackers (e.g. Per-Person Services tab + Open Items tab in a Sheet, or Notes column + Status column), an answer applied to one section may leave another section stale. **Check both before posting** and flag the inconsistency as a separate ask.

Concrete example: in an EDD audit response Sheet, answers landed in Per-Person Services Notes column but the Open Items Status column still showed UNRESOLVED for items 1, 3, 4, 6. The Sheet read as "still unresolved" to the user even though answers existed. Flag this in the ping — don't silently fix it.

## Verification gate (before any cell write)

For every value change suggested by the cron prompt:

1. `gog sheets get <id> <tab>!A1:Z100 --plain` — read current value
2. Re-read user's verbatim prior answer from the thread (`conversations.replies`)
3. If user's answer is ambiguous, ask BEFORE writing
4. After writing, re-read the cell (`gog sheets get <range>`) to verify the new value landed
5. If the artifact is shared with external collaborators (auditor, Jorge, Cindil), confirm their access level hasn't changed

## Pitfalls (from observed incidents)

- **Acting on cron prompt's claim without re-reading the thread.** Prompt was written at T-1; state at T may differ. Always verify with `conversations.replies` + `conversations.history` before writing.
- **Flipping a "Yes - PA" to "NOT a PA" because the cron asked.** User's verbatim "he only worked a few days" is ambiguous. Ask explicitly.
- **Creating a "make-sure" follow-up cron right after posting.** Triggers dropped-thread detector loop. One ping then silence.
- **Ignoring stale Open Items status column.** When answers land in Notes column but status column stays UNRESOLVED, the user sees apparent staleness. Flag the inconsistency.
- **Posting verbose multi-section status when a tight ping suffices.** One ping with 1-2 concrete blocking questions beats an essay.
- **Trusting the cron prompt's "what was last posted" claim.** Re-read the actual prior ping before acting on it.
- **Skipping the artifact re-read because "the prior ping said it was applied."** The prior ping may have been wrong, or the write may have silently failed. Re-verify.
- **Posting the cron reply at channel root when the user is engaging in-thread.** Per user profile: Slack mobile on this user's device does NOT load threaded replies by default. For status/answer replies to user-initiated threads, default to in-thread (since the cron fires from the thread's context). Only post at channel root if the prior ping was at root. EXCEPTION for cron-fired exec-assistant sweeps: the cron explicitly says "Deliver to #ai-general (NOT the operator's DM)" and posts at channel root by design — see `references/exec-sweep-provenance.md`.
- **Trusting that `skill_view(name=...)` resolves when two SKILL.md files share the name.** Verified 2026-08-06 — `skill_view(name='executive-assistant')` returns "Ambiguous skill name" because two copies exist under `~/.smartclaw/skills/executive-assistant/` and `~/.smartclaw/skills/hermes-imports/executive-assistant/`. Resolution: load via categorized path `hermes-imports/executive-assistant` until curator deduplicates. Don't assume the canonical name resolves — load with `hermes-imports/<name>` when the bare name is ambiguous.
- **Re-running `vision_analyze` on a byte-identical duplicate.** When a user posts the same media file twice (filename differs but content matches), SHA256-compare against the prior cached capture BEFORE invoking `vision_analyze`. Cheap (~50ms), avoids re-narrating the same pixels back to the user, avoids burning vision tokens. See `slack-post-via-execute-code` § "byte-identical duplicate media before re-narrating" for the full recipe. Verified 2026-08-11 in `C0AH3RY3DK6/1786345883.976659`.
- **Block-kit JSON literal-newline gotcha.** When composing a Slack `chat.postMessage` payload from a Python multiline source string written to `/tmp/<name>.json`, real newline bytes make the file invalid JSON. Pattern: build the dict in Python and use `json.dumps(dict)` to write. Recover via: `body = json.dumps({"channel": ..., "thread_ts": ..., "blocks": [...]})`. See `slack-post-via-execute-code` § "Block-kit JSON with literal newlines" for full recipe. Verified 2026-08-11 in `C0AH3RY3DK6/1786345883.976659` — first attempt with triple-string + `json.loads(text)` failed, rebuilt with `json.dumps` succeeded at `ts=1786464537.847559`.

## Related SOUL.md commitments

- `one-time-status-cron-after-every-task` — when to create a status cron after a task
- `one-time-status-cron-on-request` — when user asks for status follow-ups
- `followup-promise-requires-cron` — when promising "follow up" in Slack
- `dropped-thread-watcher-of-watchers` — cron health / silent-failure detection
- `babysit-cron-self-cancel-discipline` — terminal-state self-cancel
- `no-pick-one-menus` — autonomous-execute + queued-review pattern
- `email-approved-gate` — never email based on cron prompt alone

## Reference

- `references/edd-audit-reproduction.md` — concrete EDD audit response v2 thread anchors, Open Items table, Jeffrey's verbatim 8/5 reply, and the Aug 6 status ping that worked
- `references/exec-sweep-provenance.md` — verified end-to-end recipe for the executive-assistant sweep that posted to #ai-general at ts 1786028599.297609 (2026-08-06). Documents: calendar/email auth gaps, dedup-check rule, Path B curl posting, format, pitfalls. Use when the EA sweep cron fires.
- `references/bash-lic-and-curl-pitfalls.md` — concrete shell gotchas observed in cron runtimes (bash heredoc with `(`, `curl ?a=X&b=Y` empty body under `bash -lic`, `gog gmail search` JSON-list output shape, execute_code lacks bashrc env). Read BEFORE writing any status cron that calls Slack/HTTP via shell.
- Memory: dropped-thread detector loop (2026-08-05, Slack `${SLACK_CHANNEL_ID}/1784894152`)
- Memory: Jeffrey's "I'll stop replying until you send something new" preference (2026-07-31, `${SLACK_CHANNEL_ID}/1784235989.925899`)
- Class-level umbrella for cron-driven follow-up on user-in-flight work (audit responses, regulatory packets, ongoing deliverables)