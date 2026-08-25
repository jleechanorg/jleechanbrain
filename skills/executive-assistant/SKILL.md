---
name: executive-assistant
description: "Run the executive assistant sweep for Jeffrey: check today's calendar, scan Gmail for flagged/important emails, review Slack action items, post a concise briefing to Jeffrey's DM (${SLACK_CHANNEL_ID}). Use when a cron or direct request triggers the executive assistant sweep."
---

# Executive Assistant Sweep

Produce a concise briefing covering schedule, email, and Slack, then post it to the operator's DM channel.

## Goal

Give the operator one message that covers everything they need to be aware of right now — without fluff. Actionable items get explicit prompts ("Want me to draft a reply?").

## Setup — variables MUST be resolved before any command runs

This skill is templated; the `{{...}}` placeholders are NOT auto-substituted. Resolve them FIRST via `bash -lc 'source ~/.bashrc && env | grep -iE "EMAIL|JLEE|HERMES"'` (see `references/env-and-channels.md` for the canonical mapping). At minimum:

| Placeholder | Real value | Source |
|---|---|---|
| `{{OWNER_NAME}}` / operator | Jeffrey Lee-Chan (`jleechan`, Slack `U09GH5BR3QU`) | user identity |
| `{{ASSISTANT_EMAIL}}` | `jleechan@gmail.com` | `EMAIL_USER` env |
| `$JLEECHAN_DM_CHANNEL` | `${SLACK_CHANNEL_ID}` | `~/.bashrc` (verified 2026-07-04) |
| `SLACK_BOT_TOKEN` | `xoxb-...AjyN` | `~/.bashrc` (loaded via launchd-env-wrapper) |
| Local timezone | America/Los_Angeles (PDT) | OS default |

If a placeholder cannot be resolved, the workflow is broken — DO NOT substitute a guess; either fix the setup or stop and report.

**Reference:** See `references/env-and-channels.md` for the canonical env-var mapping, Slack channel IDs, Gmail search recipes, local probe commands, and observed cron cadence (verified 2026-07-04).

## Workflow

### 1. Calendar — what's happening today

**Tool: `gog` (NOT `gws`).** `gws` is OAuth-authenticated only as the worldarchitecture-ai Firebase service account by default — it CANNOT read personal Gmail or Calendar (returns `Precondition check failed`). Use `gog`, which has `jleechan@gmail.com` OAuth tokens in keychain.

**Hard-default to `jleechan@gmail.com` (the OAuth-user account).** Do NOT enumerate or attempt the service-account `jleechan@worldarchitect.ai` — it 401s on Calendar/Gmail and only adds noise. Skill script (added 2026-08-19 per user directive "always use that one"):

1. Hard-code `-a jleechan@gmail.com` on every `gog calendar` and `gog gmail` call. Skipping the account-discovery step is a deliberate choice: `gog auth list` shows the OAuth user is always `default`, and the service-account row is firestore-admin work — never the personal sweep.
2. If `jleechan@gmail.com` itself errors (rare — token expired, keychain prompt), surface ONE concise line in the briefing's `System` section (`gog auth refresh needed`) and continue with whatever did succeed. Do NOT silently fall back to the service account.
3. Carry forward `transparency: transparent` placeholder events (recurring personal reminders, all-day placeholders) as **context**, not as Now-list items. Skip past-time events from the Now section (e.g. a 09:00 event observed at 10:45).

Pitfall (legacy, do NOT do): do not call `gog auth list` on every sweep and narrate the secondary account's 401 — that diagnostic was removed 2026-08-19. The user explicitly directed the sweep to "always use `jleechan@gmail.com`" and stop mentioning the service-account row.

```bash
# Primary calendar, next 24h (use PT timezone offsets to avoid day-boundary drift)
NOW_PT=$(date '+%Y-%m-%dT%H:%M:%S%z' | sed 's/\(..\)$/:\1/')
NEXT_PT=$(date -v+24H '+%Y-%m-%dT%H:%M:%S%z' | sed 's/\(..\)$/:\1/')
gog calendar events primary -a jleechan@gmail.com \
  --from "$NOW_PT" --to "$NEXT_PT" --json
```

- `--from/--to` accept ISO 8601 with timezone offset. UTC ranges work but pull in day-prior events — pass `-0700` PT to keep results in local-day boundaries.
- `gog calendar events` takes the calendarId positionally (`primary`, an email, or `all`). There is NO `--all` flag.
- The actual flags are `--from/--to`, NOT `--days=1`. There is no `--max-results` flag on `gog calendar events`.
- See `references/gog-cli-commands.md` for the full verified cheat sheet (auth, flags, gotchas).

- Pull events from multiple calendars as needed. Loop the command per calendar.
- Include family/household events as context (not as action items)
- Group into sections: **Now / Today** (imminent), **Tonight**, **Upcoming** (next 2 days if unusual)
- Format: `HH:MM — event name` in local time (America/Los_Angeles)

### 2. Gmail — flagged and important messages

**Tool: `gog` (NOT `gws`, NOT `himalaya`).** The `himalaya` skill is IMAP-based and unauthenticated on this machine; `gog` is the canonical OAuth CLI for personal Gmail.

```bash
# Tier 1 — explicitly starred (most-signal first)
gog gmail search "is:starred" -a jleechan@gmail.com --max 20 --json --results-only

# Tier 2 — unread in last 24h, filter for human/actionable senders
gog gmail search "is:unread newer_than:2d -from:github.com -from:stripe.com -from:anthropic.com" \
  -a jleechan@gmail.com --max 30 --json --results-only

# Tier 3 — IMPORTANT-marked by Gmail
gog gmail search "is:unread is:important" -a jleechan@gmail.com --json --results-only
```

- `gog gmail search` takes the query as a positional arg. There is NO `--query` flag.
- For full message body: `gog gmail messages get <messageId> -a jleechan@gmail.com --plain` (positional messageId; `get` is a subcommand of `messages`).
gog gmail search "is:unread newer_than:1d -from:jleechan -from:noreply -from:no-reply -from:donotreply -from:support -from:notifications -from:auto-confirm -from:alerts -from:bot" \
  -a jleechan@gmail.com --max 30 --json --results-only
```

The negative `from:` filter is critical — without it the result is dominated by automated deploy/recovery/digest emails. For each actionable item include: sender, subject, one-line summary, and offer to draft a reply.

**Account fallback: same `gog auth list` recipe as Step 1** (oauth-user accounts only). For Gmail, `--account jleechan@gmail.com` is the reliable path; service-account accounts may also work for Mail since it does not require user-context OAuth.

### 3. Slack — action items needing Jeffrey

**Prefer the Slack MCP tools** (`mcp__slack__conversations_history`, `mcp__slack__conversations_replies`) over curl fallbacks — they're faster, surface threads automatically, and respect bot auth boundaries.

Channels to monitor (canonical mapping in `references/env-and-channels.md`):

| Channel | ID | Why |
|---|---|---|
| `#worldai` | `C0AH3RY3DK6` | Primary product + AO babysit threads |
| `#worldai-bugs` | `C0BDEAJH8PK` | Long-running bug investigations |
| `#ai-slack-test` | `${SLACK_CHANNEL_ID}` | agento respawn-cap escalations |
| `#all-jleechan-ai` | `${SLACK_CHANNEL_ID}` | Direct operator-Hermes line |
| `#jleechanbrain` | `C0AJ3SD5C79` | Harness / SOUL.md / skill work |
| `#ralph-status` | `C0AGX2Q0EA3` | Ralph pipeline status |
| `#life` | (TBD) | Recurring personal reminders |

For each channel:
1. `conversations_history(channel_id, limit=10)` — top-level messages only
2. For any thread with Jeffrey as the last unanswered author, `conversations_replies(channel_id, thread_ts=<ts>)` to read bot replies and assess whether the issue is still open
3. Do **not** list every message — only items needing action

### 4. Deploys / system status

Local probes (run in parallel):
```bash
uptime                                   # load average
df -h / | head -3                        # disk
ps aux | grep -E '(hermes|agy|claude|cmux)' | grep -v grep | wc -l
launchctl print gui/$(id -u) | grep -E '(dropped-thread|ao-notifier|auto-push-llm-wiki)'
```

Cross-reference with `#worldai` for any deploy SUCCESS/FAILED emails in Gmail (last 24h).

### 5. Life / personal reminders

Check the `#life` channel and any recurring calendar entries flagged `task:` prefix. Note any that are firing without a stop-condition (e.g. Cindil protein shake 2x/daily, car registration hourly).

### 6. Compose and post briefing

Post to {{OWNER_NAME}}'s DM channel (`$JLEECHAN_DM_CHANNEL`).

**Format:**

```
:spiral_calendar_pad: **Now / Today**
- HH:MM — event
- HH:MM — event

:email: **Email** (if anything flagged)
- Sender — Subject — one-line summary [offer to draft reply / pull full content]

:pushpin: **Slack action items** (if any)
- #channel — summary of what needs attention

:large_green_circle: **Deploys / system**
- status line

:necktie: **Tonight**
- HH:MM — event

Anything you want me to act on?
```

- Omit sections that have nothing to report
- Keep each line to one line
- Always end with an open offer to take action

### 6a. Post path: prefer Slack MCP over curl

In cron runtimes, `mcp__slack__conversations_add_message` is the **canonical** post path for the DM briefing — use it FIRST. Fall back to curl with `$SLACK_BOT_TOKEN` only if the MCP tool errors out. Bot identity posting to user's own DM channel is the live, working path (verified 2026-07-04 — the prior "xoxp DEAD" warnings were intermittent and the bot-token path kept working for the DM). After posting, capture the returned `MsgID` from the MCP result; for curl, capture from the JSON `ts` field.

### 6b. Slack response JSON can have raw control chars

When parsing `conversations.history` / `conversations.replies` responses via `json.loads(raw, strict=False)` you may STILL hit `Invalid control character` (this happened 2026-07-04). Workaround: regex out the `"ts":"…"` and `"text":"…"` markers from the raw bytes directly — don't try to fully parse the JSON. Example:

```python
import re
raw = open('/tmp/dmhist.json').read()
tss = re.findall(r'"ts":"([^"]+)"', raw)   # ok
bodies = re.findall(r'"text":"(.{0,180}?)"', raw)  # truncated string peek
```

This is sufficient for dedupe (compare `ts` against `time.time()`).

### 6c. Cron-armed follow-up: `--delete-after-run` does NOT exist

SOUL.md `one-time-status-cron-after-every-task` specifies `hermes cron create "20m" … --delete-after-run`. Verified 2026-07-04: that flag is **not** recognized by the live CLI (`hermes cron create --help` lists only `--name`, `--deliver`, `--repeat`, `--skill`, `--script`, `--no-agent`, `--workdir`). The actual one-shot behavior comes from the schedule string itself: pass `"20m"` (or `"10m"`) as the positional `schedule` argument and `--repeat 1`. The cron will fire once and then sit idle — that is the canonical one-shot form. Do **not** invent flags or source them from SOUL.md without re-verifying against `hermes cron create --help`.

## Reference files

- `references/gog-cli-commands.md` — verified `gog` CLI cheat sheet (auth, flags, common mistakes, decision matrix vs `gws`/`himalaya`). **Read this first** if `gog` returns `unknown flag` errors — many older drafts reference flags that no longer exist on `gog` v0.10.0.

> **Curator note:** A near-duplicate `executive-assistant` exists at `hermes-imports/executive-assistant/` with stale CLI commands (`--days=1`, `--all` flag, references to `himalaya`). That copy should be either refreshed from this one or marked superseded.

## Safety rules

- Never post the briefing twice for the same effective sweep window (check if a briefing was already posted in the last 30 minutes before sending)
- If calendar access fails, still post what's available and note the failure
- If Gmail access fails, skip that section silently unless it was explicitly requested
- Stay silent on errors that don't affect the briefing content

### Dedup discipline (concrete protocol)

"Same sweep run" needs a concrete check — the skill-level guidance is necessary but not sufficient. Before composing or posting a brief, do this three-step dedup and **stay SILENT on step 3 even if all your data sources return new content**:

1. **Resolve the canonical DM channel.** Read `$JLEECHAN_DM_CHANNEL` from the environment (or `~/.bashrc`). Default: `${SLACK_CHANNEL_ID}`. Do **NOT** post the brief to `#life`, `#ai-general`, or any other channel — those are wrong channels for the EA sweep output.
2. **Check DM-channel recent history.** `mcp__slack__conversations_history(channel_id=${SLACK_CHANNEL_ID}, limit=5)` (or `conversations_replies` if the previous brief lived in a thread). Find the most recent `hermes` bot message row (look for `BotName=hermes` or `UserID=U0AEZC7RX1Q`). Record its `ts` — that is the authoritative "last brief" timestamp, not any local cron-prompt self-narration.
3. **Compare timestamps.** If `(now − last_brief_ts) < 30 min`, output `[SILENT]` as the final cron reply. Do NOT post. The cron delivery model will not deliver anything, which is the correct behavior — re-posting within 30 min spams the DM and dilutes the signal of the canonical brief.
4. **Compare content, not just time.** Even if the 30-min window has elapsed, if the prior brief covered the same calendar events (today's full set, no events starting in the gap), same flagged email set (no new senders in the gap), and same Slack state (no new operator asks since the prior brief), prefer DELTA-style update ("delta since 10:30 PDT: no change") over full re-brief. Full re-brief is reserved for when there's been material change OR when the gap exceeds 30 min AND a fresh sweep is genuinely warranted.
5. **What "material change" means.** New calendar event starting within the next 2h, new IMPORTANT-marked email from a human sender, new operator top-level ask in a monitored Slack channel, or any of: deploy failure, system-status red, on-call ping. None of these in the gap → safe to stay SILENT or send a 2-line delta.

**Pitfall:** The cron-prompt may include phrases like "Briefing delivered successfully" from a prior tick — that is NARRATION, not a Slack artifact. Only an actual `MsgID` from `conversations_history` proves a brief landed. Trust the Slack history query, not the cron prompt's self-report.

**Pitfall:** The 30-min window is per-effective-sweep, not per-calendar-day. An hourly cron (`ea-sweep-hourly`) firing 6 times after a real brief lands will dedup-stay-silent 5 of those 6 ticks. That's correct behavior, not a bug.

See `references/ea-dedup-protocol.md` for the full evidence trail, pitfalls, and a worked example of a dedup hit.

### Templating defaults (resolved)

The `{{OWNER_NAME}}` / `{{ASSISTANT_EMAIL}}` / `{{PERSONAL_EMAIL}}` / `{{PRIMARY_WORK_EMAIL}}` / `{{SECONDARY_CALENDAR_EMAIL_*}}` placeholders exist so this skill is reusable for other owners. Resolved defaults for the active Hermes instance:

| Placeholder | Resolved value |
|---|---|
| `{{OWNER_NAME}}` | `Jeffrey` |
| `{{ASSISTANT_EMAIL}}` | `jleechan@gmail.com` |
| `{{PERSONAL_EMAIL}}` | `jleechan@gmail.com` |
| `{{PRIMARY_WORK_EMAIL}}` | `jleechanreclaim@gmail.com` |
| `{{SECONDARY_CALENDAR_EMAIL_1}}` | `jleechan@snapchat.com` |
| `{{SECONDARY_CALENDAR_EMAIL_2}}` | `cindilashley@gmail.com` |
| `{{SECONDARY_CALENDAR_EMAIL_3}}` | _(unbound — do not assume)_ |
| `$JLEECHAN_DM_CHANNEL` | `${SLACK_CHANNEL_ID}` |

If a future owner runs this skill, rebind these values before first use.

## Pitfalls (cumulative — read all before each sweep)

- **P39 — Skill placeholders are never substituted in cron env.** The body uses `{{OWNER_NAME}}`, `{{ASSISTANT_EMAIL}}`, `{{PERSONAL_EMAIL}}`, `{{PRIMARY_WORK_EMAIL}}`, `{{SECONDARY_CALENDAR_EMAIL_*}}`. Cron runtimes do NOT resolve them. Hardcode the resolved values:
  - Owner: `Jeffrey Lee-Chan` (handle: `jleechan`); DM channel: `${SLACK_CHANNEL_ID}`; Slack user: `U09GH5BR3QU`; bot identity: `U0AEZC7RX1Q` (`hermes`).
  - Primary calendar/gmail account: `jleechan@gmail.com`. Read-only public-facing account; no other personal/work accounts are wired through `gog` today (verified 2026-07-04).
  - If new accounts are added, update both this pitfall AND `references/jleechan-config.md`.
- **P38 — `hermes cron create` flag mismatch.** See §6c. Use `--repeat 1` + a single-token schedule (`"20m"`), NOT `--delete-after-run` or `--keep-after-run` or `--every`.
- **P37 — Slack API JSON parsing.** See §6b. Regex out `ts` and truncated `text` from raw bytes when `json.loads(strict=False)` still fails.
- **P36 (carry-over from prior) — Verify active CLI before citing it.** Already covered in prior sweeps; do not regress.
- **Keep each bullet to one line.** The format template below is the canonical structure; copy it verbatim rather than improvising.

## Briefing format (canonical, copy verbatim)

```
:spiral_calendar_pad: *Mid-day brief — Sat Jul 4, 12:43 PDT*
<one-line subtitle: status-only vs full vs delta>

:alarm_clock: *Now / Today* (imminent, PDT)
- HH:MM–HH:MM — event
- HH:MM–HH:MM — event

:e-mail: *Email* (since last brief)
- :red_circle: *Sender* — Subject — one-line summary [needs reply | FYI]
- :white_check_mark: (or "no new actionable items")

:pushpin: *Slack action items*
- :red_circle: *#channel* — thread ts: context, last bot update HH:MM, current state
- :large_yellow_circle: *#channel* — ...
- :large_green_circle: *#channel* — resolved items since last brief

:large_green_circle: *Deploys / system*
- load avg X / Y / Z (vs baseline)
- disk X Gi free of Y Gi (Z% used)
- N agy/claude/cmux processes; gateway up; critical launchd jobs enabled
- any deploy SUCCESS/FAILED from last 12h

:handshake: *Tonight*
- HH:MM — event
- HH:MM — event

*Want me to:*
- action item 1
- action item 2
- action item 3
```

## Pitfalls

- **Don't substitute placeholders with guesses.** If `JLEECHAN_DM_CHANNEL` isn't resolved, stop and fix the env, don't post to a different channel.
- **Don't double-post when nothing changed.** A 42-min delta brief is still acceptable; an 8-min delta brief is not. Default to silence when the prior brief covers everything.
- **Don't recurse the cron loop.** This cron is a status update, not an action — DO NOT spawn child cron jobs, AO workers, or write-goal specs from here. Operator-initiated "act on this" comes from a separate message, not from the brief.
- **Filter out automated digests.** Gmail search MUST exclude `noreply/auto-confirm/donotreply/alerts/support/bot` senders or the brief drowns in deploy reports, recovery alerts, and digest newsletters.
- **The DM channel is for the operator only.** Never post the briefing to a public channel — it contains personal calendar events, email content, and household reminders.
