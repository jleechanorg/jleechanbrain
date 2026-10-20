---
name: life-channel-digest
description: "Post a personal-life digest to the #life Slack channel."
---

# Life-channel digest

Post a single concise top-level message to the `#life` Slack channel
(channel ID `C0AMM2B4319`) summarizing the user's unread Gmail + the
next 24h of calendar. This is a recurring cron-friendly recipe, not
a one-off.

## When to use

- Cron job asks "post a digest to #life" / "life digest" / "personal-life summary"
- The user asks for a #life ping / life summary / personal morning update
- A scheduled job needs a re-runnable recipe for fetching Gmail + Calendar and posting a top-3 / next-4 digest

## When NOT to use

- **Morning DM briefing** → use `executive-assistant` (different destination, different format)
- **Read-only #life check** (find existing reminders, list pending items) → that is a different operation; do not post

## Format (user-locked)

Top-level channel post (NOT in a thread — see P1):

```
📬 *Life digest — <Day> <Mon> <DD>, <YYYY> <HH:MM> PT*

*Important unread emails (top 3):*
• *<subject>* — <sender> — <HH:MM> PT. <one-line context>.
• *<subject>* — <sender> — <one-line context>.
• *<subject>* — <sender> — <one-line context>.

*Upcoming calendar (next 24h):*
• *<Day> HH:MM PT* — <event> [optional @location]
• *<Day> HH:MM PT* — <event>
• *<Day> HH:MM PT* — <event>
• *<Day> HH:MM PT* — <event>

*Action needed:*
• <concrete next action tied to a time-sensitive item>
• <concrete next action>
• <concrete next action>
```

The "Action needed" block must be tied to a time-sensitive email or upcoming
event from the digest itself, not generic nag items. Omit only when literally
nothing is time-sensitive.

## Recipe (3 steps)

### Step 1 — Fetch unread email

Use the `gog` CLI (already installed at `/opt/homebrew/bin/gog`). Do NOT
reach for `gws` or `~/.smartclaw/skills/productivity/google-workspace/scripts/google_api.py`
on this machine — the gws path is not authenticated and the
`google_api.py` script's token (`~/.smartclaw/google_token.json`) does not
exist.

```bash
gog gmail search "is:unread" --max 25 --json
```

Filter to IMPORTANT-flagged threads plus any CATEGORY_PERSONAL entries.
Drop CATEGORY_PROMOTIONS and CATEGORY_UPDATES by default — those are
noise. Return top 3.

### Step 2 — Fetch calendar (next 24h, strictly upcoming)

```bash
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
END=$(date -u -v+24H +"%Y-%m-%dT%H:%M:%SZ")
gog calendar events --from "$NOW" --to "$END" --json
```

`gog calendar events --from/--to` is a TIME-WINDOW filter only — it
does NOT drop events whose start is in the past. You MUST post-filter
in Python. See `references/calendar-filter-recipe.md` for the full
filter (handles past recurrings, all-day entries, timezone coercion).

### Step 3 — Compose + post

Build the JSON payload in Python and post via Slack `chat.postMessage`.
Channel: `C0AMM2B4319` (#life). Bot identity: hermes
(`SLACK_BOT_TOKEN`).

**NEVER inline a multi-line string containing `@` inside
`python3 -c "..."` — bash will eat the email address (see P2).**
Use a heredoc-piped-to-stdin pattern. Full template and JSON
verification in `references/slack-post-template.md`.

## Pitfalls

### P1 — Post at channel root, NOT in a thread

Verified 2026-08-11 — Slack mobile on this user's device does NOT
load threaded replies by default. They see only channel-root posts.
A digest / status / answer post from a cron is a NEW message → post
at channel root with NO `thread_ts` field. If you accidentally post
in a thread, the user will only see "3) I think i started this
already" or nothing at all on mobile.

### P2 — Bash heredoc + email address in a `python3 -c "..."` payload

When you build the Slack JSON payload via `python3 -c "..."` inline
in a shell command, an `@` in the email address (e.g.
`tickets@tickets.mlb.com`) can get eaten — bash will try to interpret
the surrounding line as a command. Symptom: `tickets@...: command
not found` appears in stderr and the rendered Slack message shows a
blank where the email should be.

**Fix:** Write the Python to a temp file or pipe a heredoc to
`python3` via stdin, NEVER inline a multi-line string with `@` inside
`python3 -c "..."`. The cleanest pattern is single-quoted heredoc
tag (`<<'PY'`) which prevents bash from interpolating `$variables`
inside the Python body. See `references/slack-post-template.md` for
the working template.

### P3 — `gog calendar events` returns past recurring events

`gog` does not collapse recurring-event masters; you'll see entries
whose `start.dateTime` is in 2018 or 2024 because they are still
"active" recurring series. The Python filter in Step 2 is mandatory
— do not trust the `--from/--to` window alone.

### P4 — `gws` and `google_api.py` are NOT the active path

> **2026-08-22 update:** `gws` is BANNED for personal Workspace calls (SOUL.md `## COMMIT: gws-banned-for-personal-workspace`). Use `gog` directly instead.

On this machine, neither `gws` nor the `google_api.py` wrapper in the
`google-workspace` skill is authenticated. The `google_token.json`
file does not exist. Use `gog` (keychain-backed) for ALL Gmail and
Calendar operations until a real Google OAuth setup is completed.
The `google-workspace` skill's setup steps in Step 1/2/3 are the
right recipe when you do want to set it up — but do not pretend they
work today.

### P5 — Slack rich-text rendering

Slack's `chat.postMessage` with plain text (no `blocks`) renders the
text as a single rich-text block. Backticks in body become inline
code, asterisks become bold, `<mailto:...>` becomes a clickable
link. Email addresses without `<>` brackets render as literal text.
If you want a clickable email, wrap as `<mailto:user@host|user@host>`.

### P6 — Channel ID drift

`#life` channel ID is `C0AMM2B4319` as of 2026-08-11, verified by
posting a real digest (ts `1786464149.641949`). If the post fails
with `channel_not_found`, verify the channel ID with
`slack_thread_lib.sh` or the Slack MCP `conversations_list` API
before assuming the channel was renamed. Do NOT guess from
`~/.smartclaw/config.yaml` `SLACK_HOME_CHANNEL` — that is `#ai-general`
(`C0AJQ5M0A0Y`), a different channel.

### P7 — Hermes `execute_code` sandbox does NOT inherit shell env vars

Verified 2026-08-13. When building the Slack payload inside the
`hermes_tools.execute_code()` Python sandbox, `os.environ["SLACK_BOT_TOKEN"]`
raises `KeyError` even though `bash -lic 'echo ${#SLACK_BOT_TOKEN}'`
returns 58. The sandbox has its own minimal env that does NOT inherit
the cron / launchd shell environment that sources `~/.bashrc`.

**Fix:** Do all Slack posting from a `bash -lic '...'` block, NOT
from `execute_code`. Pattern:

```bash
bash -lic 'source ~/.bashrc 2>/dev/null || true
DIGEST=$(cat /tmp/digest_text.txt)
curl -fsS -X POST https://slack.com/api/chat.postMessage \
  -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
  -H "Content-Type: application/json; charset=utf-8" \
  --data-binary @<(python3 -c "import json,sys; print(json.dumps({\"channel\":\"C0AMM2B4319\",\"text\":sys.stdin.read()}))" <<<"$DIGEST")'
```

Or simpler: build the payload as JSON with `python3 <<'PY' > /tmp/payload.json`
(no token references), then `curl --data-binary @/tmp/payload.json`
with `Authorization: Bearer ${SLACK_BOT_TOKEN}` in the same
bash block. The token expansion happens inside the bash block that
HAS sourced `~/.bashrc`. See `references/slack-post-template.md`
for the canonical shell-script template (use `write_file` to drop
the script to `/tmp/post_digest.sh` then `bash /tmp/post_digest.sh`).

### P8 — Hermes regex sanitizer strips secret-shaped strings from `execute_code`

Verified 2026-08-13. Even when the token IS in the sandbox env,
an f-string like `f"Authorization: Bearer {os.environ['SLACK_BOT_TOKEN']}"`
gets corrupted by the sanitizer regex — the token substring is
replaced with `***` and the resulting header is malformed, so the
resulting Slack API call returns auth failure.

**Fix:** Don't try to assemble the Authorization header inside
`execute_code` at all. Generate only the safe JSON payload (no
secrets) inside `execute_code`, write to `/tmp/payload.json`, then
hand off to a bash block for the curl call. This is the same fix
as P7 — keep secrets out of `execute_code` entirely.

### P9 — Auto-system emails are not "important unread" for a personal digest

Verified 2026-08-13. The Gmail inbox has a high volume of
self-generated automation email that shows up as `is:unread` but
should NOT count in the "top 3 important unread" — specifically:

- *WorldArchitect Reports* (`jleechan@gmail.com` self-sent): daily
  GCP cost, daily GH Actions cost. Auto-cron output.
- *"WorldArchitect.AI Deploy Bot"* (`jleechan@gmail.com`): deploy
  success/failure notifications.
- *GitHub storage quota* (`noreply@github.com`): "you used 90% of
  Actions storage" — also fine to skip unless ACTION is required
  (rare).

**Fix:** In Step 1's filter, add a `from-domain` / `from-address`
skip list before the IMPORTANT/CATEGORY_PERSONAL filter:

```python
SKIP_SENDERS = {
    "jleechan@gmail.com",                  # self-sent / cron reports
    "WorldArchitect Reports <jleechan@gmail.com>",
    '"WorldArchitect.AI Deploy Bot" <jleechan@gmail.com>',
}
important = [t for t in threads
             if t.get("from") not in SKIP_SENDERS
             and not (is_promo or (is_updates and not imp))]
```

Self-drafts (`from: jleechan@gmail.com`) CAN be important if the
user is mid-flight on an email draft — judgment call. The skill
recommends including self-drafts when `IMPORTANT` is set, which
matches the 2026-08-13 digest (Jeffrey's "Vision life success"
self-draft made the top 3).

### P10 — Friday has no events — say so, don't fabricate

Verified 2026-08-13. The 24h window crosses midnight into the next
day (Thu 16:01 UTC → Fri 16:01 UTC), but if the next day is empty
the digest only shows today. The "Action needed" block should
still be populated from today's events. Do not pad with empty
"tomorrow" rows.

### P11 — `gog gmail search` does NOT support inline pipe-to-python

Verified 2026-08-13. The combined form
`gog gmail search ... --json | python3 -c "..."` fails with
`json.decoder.JSONDecodeError: Expecting value` because the curl-
side stderr ("fetched 25 threads...") interleaves on stderr and
sometimes stdout buffering introduces a leading non-JSON byte
when piped. Even with `2>/dev/null` the pipe can lose data when
the child writes a tiny JSON buffer faster than Python reads.

**Fix:** Always redirect to a temp file first, then read from the
file with a separate Python call:

```bash
gog gmail search "is:unread" --max 25 --json > /tmp/gmail.json 2>/tmp/gmail.err
ls -la /tmp/gmail.json /tmp/gmail.err   # confirm size > 0
python3 -c "import json; d=json.load(open('/tmp/gmail.json')); ..."
```

Same pattern for `gog calendar events --json > /tmp/cal.json`.
Don't trust pipes for `--json` output from `gog`.

## Verification

After posting, confirm:

```bash
curl -fsS -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
  "https://slack.com/api/conversations.replies?channel=C0AMM2B4319&ts=<ts>&limit=1"
```

Expect `ok: true` and the `text` field containing the digest you
posted. If the text is truncated or fields are missing, the JSON
payload was malformed (usually a stray bash escape from P2).

## Changelog

- 2026-08-11 — initial version. Verified end-to-end digest posted to
  #life at ts `1786464149.641949` (Tue Aug 11 09:00 PT). Captured
  P1 (mobile thread visibility), P2 (bash heredoc + email @-eaten),
  P3 (past recurring events), P4 (gws path not active), P5
  (rich-text rendering), P6 (channel ID drift).
- 2026-08-13 — second-run patch. Verified digest posted at ts
  `1786636916.998259`. Added P7 (execute_code sandbox env gap —
  `SLACK_BOT_TOKEN` not in sandbox env, must bash-source),
  P8 (sandbox regex strips secret-shaped strings), P9
  (auto-system emails are not "important unread" — skip
  WorldArchitect Reports / Deploy Bot / self-cron output), P10
  (don't fabricate "tomorrow" rows when next day is empty), P11
  (`gog --json` piped to python drops bytes — redirect to file
  first). Wrote `references/slack-post-template.md` (full
  multi-file bash script that survives every P2/P7/P8/P11 trap)
  and `references/calendar-filter-recipe.md` (the post-filter
  block that Step 2 has always required but was previously only
  referenced, never written).
