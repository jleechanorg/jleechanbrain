# Slack upload window-scan failure (2026-08-06, PR #8781)

**Incident location:** `jleechanorg/worldarchitect.ai#8781` thread `C0AH3RY3DK6/p1785953173.319919`

**Session context:** Playwright headless captured two PNGs (BEFORE `before_local_v2.png`, AFTER `after_local_v2.png`) on `localhost:8082`. Agent used the 3-stage `files.completeUploadExternal` recipe from `evidence-attach-to-slack`.

**Stage 1 + Stage 2 succeeded:**
```json
{"ok":true,"upload_url":"https://files.slack.com/upload/v1/...","file_id":"F0BND6N6GV8"}
```

**Stage 3 succeeded:**
```json
{"ok":true,"files":[{"id":"F0BND6N6GV8",...,"title":"BEFORE: ..."},{"id":"F0BNB7MMKQE",...,"title":"AFTER: ..."}]}
```

Agent's reply: "📎 Evidence attached to this thread: BEFORE / AFTER PNGs" + Side-by-side table. Agent said nothing about verifying the upload.

## First verification — WRONG (open-ended recent-30)

```bash
curl -fsS "https://slack.com/api/conversations.replies?channel=C0AH3RY3DK6&ts=1785953173.319919&limit=30"
```

Returned messages with `ts` values `1785992790..1785993663` — all recent activity from parallel workers, babysit-cron fires, and a follow-up user message. **No file-share messages in that window.** Agent reported: "the files are NOT in the thread."

User reply (verbatim): "show me PR url and why arent you attaching media to this slack thread? CHeck your skills and /history you've done this before see whats wrong"

## Second verification — CORRECT (time-windowed)

```bash
UPLOAD_TS="1785990850.842849"
curl -fsS "https://slack.com/api/conversations.replies?channel=C0AH3RY3DK6&ts=1785953173.319919&limit=200&oldest=1785990845.000000&latest=1785990855.999999"
```

Returned the file-share message at `ts=1785990850.842849` with `files: [F0BND6N6GV8, F0BNB7MMKQE]`. **The files WERE attached.** The initial verification had scanned the wrong time window.

## Damage from the first wrong scan

1. Hallucinated the failure ("files failed to land") when no failure occurred.
2. User had to intervene to flag the misread.
3. Trust in subsequent Slack-upload claims was reduced.
4. The correction required an extra turn and the user had to invoke `/harness` / `/learn`-style self-correction mechanics.

## Fix encoded in skill `artifact-readback-verify`

After every `files.completeUploadExternal` Stage 3 `ok:true`:

```bash
UPLOAD_TS="<stage-1-file-creation-ts or stage-3 share ts>"
LOWER=$(( ${UPLOAD_TS%.*} - 5 ))
UPPER=$(( ${UPLOAD_TS%.*} + 5 ))
curl -fsS "https://slack.com/api/conversations.replies?channel=<chan>&ts=<thread>&limit=200&oldest=${LOWER}.000000&latest=${UPPER}.999999" \
  -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
| jq '[.messages[] | select(.files != null) | {ts, file_ids: [.files[].id]}]'
```

Then grep for the Stage 1 file_id in the response before claiming "uploaded."

## Why the open-ended fetch fails structurally

`conversations.replies?limit=N` returns the most recent N messages — it does NOT return "the messages around the upload." A long-lived Slack thread accumulates dozens of messages during a multi-second upload window (CI polling outputs, babysit cron completions, follow-ups from other agents). The file-share `ts=1785990850.842849` was 60+ messages earlier than the conversation tail at `ts=1785993663.623949`. `limit=30` returned only the tail and missed the upload entirely.

## Other system boundaries affected by the same anti-pattern

- `git push`: open-ended `git log` will lose the new commit in a busy repo; use `git ls-remote origin <branch>` and compare SHAs.
- `gh pr comment`: open-ended `gh api repos/<owner>/<repo>/issues/<N>/comments?per_page=10` will lose your bot's comment if 10+ comments exist; use a semantic filter `select(.user.login == "<your-bot>")`.
- `hermes cronjob create`: open-ended `hermes cronjob list` will list 36 existing jobs and miss yours; grep by job_id or by name.
- `MCP file.create`: open-ended `mcp__filesystem__read_text_file <dir>` will return everything else; prefer filtering by the exact filename you just wrote.

Every write that crosses a system boundary needs a readback scoped to the artifact, not scoped to "the universe."
