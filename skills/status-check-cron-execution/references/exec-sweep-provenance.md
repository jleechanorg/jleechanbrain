# EA-Sweep Provenance & Posting Recipe — 2026-08-06

A reference card for the executive-assistant sweep that documents the verified
working path as of 2026-08-06 (the briefing posted successfully to #ai-general
at ts 1786028599.297609). Use when the cron fires for `ea-sweep-hourly` and the
agent needs the exact recipe end-to-end.

## Trigger

Cron `clawchief:ea-sweep-hourly` (job_id `2f942031797e`) fires every 4h. The
instruction it carries: "Executive assistant sweep. Use the executive-assistant
skill. Deliver the resulting briefing to #ai-general (NOT the operator's DM)."

## Skill-resolution gotcha (verified 2026-08-06)

`skill_view(name='executive-assistant')` returns an **Ambiguous skill name**
error because two SKILL.md files exist with the same name:

- `${HOME}/.smartclaw/skills/executive-assistant/SKILL.md` — local-curated
  canonical copy (writable via `skill_manage` after `hermes curator adopt`)
- `${HOME}/.smartclaw/skills/hermes-imports/executive-assistant/SKILL.md`
  — hub-imported mirror under `hermes-imports/`

The error message itself recommends: "Pass the full relative path instead of
the bare name (e.g., 'category/skill-name'), or rename one of the colliding
skills so each name is unique." Resolution: load via the categorized path
`hermes-imports/executive-assistant` until the curator deduplicates the two
copies. Both files contain identical content as of 2026-08-06, so loading
either works for execution purposes.

## Verified end-to-end recipe (2026-08-06 sweep)

### 1. Calendar — only `jleechan@gmail.com` has auth

```bash
gog calendar events --all -a jleechan@gmail.com --days=1 --max=50 --json --results-only
```

The other accounts all fail:

- `m@gon.to` — `No auth for calendar m@gon.to.`
- `jeffrey@worldarchitect.ai` — `No auth for calendar jeffrey@worldarchitect.ai.`
- `jleechan@worldarchitect.ai` — `oauth2: cannot fetch token: 401 Unauthorized`
  (`unauthorized_client`).
- `jleechan@agent-orchestrator.com` — `No auth for calendar`.

If a future sweep needs work-calendar events, re-auth
`jleechan@worldarchitect.ai` via
`gog auth add jleechan@worldarchitect.ai --services calendar`. As of
2026-08-06, this is the known gap; the briefing works around it by sourcing
work/meeting context from Slack threads instead.

### 2. Email — search the same account

```bash
gog gmail search "is:starred newer_than:7d" -a jleechan@gmail.com --max 30 --json --results-only
gog gmail search "is:unread newer_than:1d" -a jleechan@gmail.com --max 30 --json --results-only
gog gmail search "is:important newer_than:2d" -a jleechan@gmail.com --max 30 --json --results-only
```

Result counts seen on 2026-08-06: 0 starred/7d, ~10 unread/1d, 4 important/2d.
Filter the important list to actual high-signal items (recruiters, finance,
legal, urgent-subject lines) and tag each with "[offer to draft reply]".

### 3. Slack action items — scan the operator-direct channels

For the sweep, the channels that matter are:

- `${SLACK_CHANNEL_ID}` (`#all-jleechan-ai`) — operator-direct, all-open threads
- `C0AJQ5M0A0Y` (`#ai-general`) — home channel; previous briefings land here
- `C0AH3RY3DK6` (`#worldai`) — worldarchitect.ai work threads
- `C0ALSKLU9KM` (`#agent-orchestrator`) — AO progress reports
- `C0AMM2B4319` (`#life`) — personal/life reminders + open life asks

For each, pull last 20 with `oldest=<8h ago>`. Filter to threads where the
operator posted and the bot hasn't closed the loop.

### 4. Dedup check — last briefing in #ai-general

```bash
curl -fsS -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
  "https://slack.com/api/conversations.history?channel=C0AJQ5M0A0Y&oldest=<ts_8h_ago>&limit=20"
```

Look for a "Cronjob Response: clawchief:ea-sweep-hourly" message from the bot
within the last 30 min. If present, abort — don't double-post.

### 5. Compose and post — Path B curl, top-level, NOT thread

Jeffrey's mobile Slack client does NOT load threaded replies by default. The
default for the exec-sweep is top-level post in #ai-general — this is the
correct channel per the cron's instruction ("Deliver to #ai-general (NOT the
operator's DM)") AND the correct root-vs-thread choice for visibility on
mobile.

```python
import subprocess, json
token = subprocess.run(["bash", "-lic", "echo -n $SLACK_BOT_TOKEN"],
                       capture_output=True, text=True, timeout=15).stdout.strip()
payload = json.dumps({"channel": "C0AJQ5M0A0Y", "text": briefing})
cmd = ('curl -fsS -X POST "https://slack.com/api/chat.postMessage" '
       '-H "Authorization: Bearer ${tok}" -H "Content-Type: application/json" -d @-')
r = subprocess.run(cmd.replace("${tok}", token), shell=True,
                   capture_output=True, text=True, timeout=15, input=payload)
assert r.stdout.startswith('{"ok":true')
```

Verify immediately with `conversations.history?oldest=<just-posted-ts>` — the
new message should be the most recent row.

## Briefing format (what to actually write)

Use the format that posted successfully on 2026-08-06:

```
*Executive Assistant Sweep — <weekday> <Mon> <day>, <year> <HH:MM> PDT*

*Now / Today (PT)*
• HH:MM — event
• HH:MM — event

*Tonight / Upcoming*
• HH:MM — event

*Email — flagged/important (last 24–48h)*
• *Sender* — Subject — one-line summary [offer to draft reply / pull full content]

*Slack — open threads needing you*
• *#channel* — short description [PR-NNN status if applicable]

*Life*
• *#life* — open asks [date]

*Deploys / system*
• PR #N — state

Anything you want me to act on — <2-4 concrete offers>?
```

Total length should stay under ~3.5 KB. Slack chat.postMessage will refuse
over 40 KB and warn at 12 KB; the 3.5 KB format gives headroom for verification
echo + trailing duplicate-detection responses.

## Pitfalls observed (and how to dodge them)

- **Don't post twice.** The `clawchief:ea-sweep-hourly` cron runs every 4h.
  Always dedup-check the last "Executive Assistant Sweep" bot message in
  #ai-general before posting. If `last_briefing_ts` is within 30 min of
  `now`, abort with `[SILENT]` per the cron delivery contract.
- **Don't post in-thread.** Mobile client visibility is at channel root. Only
  post in-thread if the previous briefing was in-thread AND the operator is
  actively engaging there.
- **Don't post to operator DM.** The cron instruction explicitly says
  `#ai-general` (`C0AJQ5M0A0Y`), not `$JLEECHAN_DM_CHANNEL`. The skill's
  default template posts to operator DM; the cron override wins.
- **Don't trust the calendar auth across accounts.** Only `jleechan@gmail.com`
  works. Other accounts need re-auth or service-account setup before they'll
  surface work-calendar events.
- **Don't use markdown headers (`#`).** Slack chat.postMessage renders `#` as
  literal text, not as a heading. Use `*bold*` for section headers — that's
  what Slack mobile renders cleanly.
- **Avoid emoji shortcodes that vary by skin-tone.** Slack renders
  `:spiral_calendar_pad:` on desktop but iOS may show fallback. Stick to safe
  shortcodes (`:clipboard:`, `:email:`, `:pushpin:`,
  `:large_green_circle:`, `:large_yellow_circle:`, `:red_circle:`,
  `:warning:`, `:alarm_clock:`, `:necktie:`, `:spiral_calendar_pad:`,
  `:hourglass:`, `:black_square_button:`).
- **Post ONE briefing per sweep.** Compose the full text, then send via a
  single `chat.postMessage`. Per `slack-thread-routing-investigation` and the
  dropped-thread re-fire loop memory (verified 2026-08-05 PR #8801):
  intermediate tool calls that emit visible text get serialized as separate
  `chat.postMessage` calls by the gateway, which both duplicates the briefing
  and restarts the dropped-thread cooldown. Batch all reads first, then ONE
  Path B curl with bot token, then one verify.

## Source-of-truth anchor for this session

Briefing at ts `1786028599.297609` in `C0AJQ5M0A0Y` (#ai-general). Verify
with `conversations.history?channel=C0AJQ5M0A0Y&oldest=1786028000&limit=3` —
the most recent row is the sweep.

## Verified 2026-08-13 re-run (delta brief)

Same cron (`clawchief:ea-sweep-hourly` variant) fired 2026-08-13 12:03 PDT and
posted successfully to `C0AJQ5M0A0Y` at ts `1786647821.913699`. Confirmation
that the recipe above still works end-to-end as of 2026-08-13 — same gog auth
list (`jleechan@gmail.com` OAuth + `jleechan@worldarchitect.ai` service-account),
same calendar flag shape (`gog calendar events primary -a jleechan@gmail.com
--from <PT> --to <PT> --json --results-only`), same Path B curl pattern.

Delta details vs 2026-08-06 anchor:
- Dedup window passed: prior bot brief in `${SLACK_CHANNEL_ID}` (operator DM) was
  `1786403716` (~68h prior, well past 30-min window). Brief warranted.
- Slack channel routing: cron prompt explicitly named `#ai-general` (not DM)
  — followed cron, overrode skill default.
- Email enrichment: `is:starred` query returned 9 stale items (Cindil
  ClearSkin + Tattoo invites from late July, Gary Lue dev handoff,
  MentorCruise calendar-access re-auth x2, etc.) — added explicit "may
  need re-auth / confirm-decline" annotations for actionables rather than
  just listing them.
- Deploys section: `launchctl print gui/$(id -u) | grep -E
  '(dropped-thread|ao-notifier|auto-push|ea-sweep)'` confirmed all critical
  launchd jobs enabled; `df -h /` showed 55Gi free of 926Gi (16% used) — fine.
- Load avg 4.82/6.74/7.26 — slightly elevated but stable. Not flagged as
  actionable in the brief.

Format note: the brief used `:emoji:` shortcodes which Slack rendered as
unicode (`:spiral_calendar_pad:` → 🗓️, `:alarm_clock:` → ⏰, `:handshake:`
→ 🤝, `:large_yellow_circle:` → 🟡). Emoji rendering worked on the macOS
desktop Slack client but iOS may still fall back to shortcodes per the
2026-08-06 pitfall — keep this in mind if a future sweep must target iOS
specifically.