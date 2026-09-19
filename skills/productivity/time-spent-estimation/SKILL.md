---
name: time-spent-estimation
description: "Estimate time-spent from local Slack, calendar, email logs."
---

# Time-spent estimation from local data

Estimate the user's time-spent across the past N days by mining **already-existing local sources** — no new tracking installs required. The data is already on disk; this skill is a methodology + reusable queries that turn it into a per-day, per-source, per-channel breakdown.

## When to use

- User says: "how did I spend my time", "where does my day go", "time tracking retrospective", "what did I do last week", "show me my hours by channel", "am I spending too much time in meetings", "how much time on coding vs Slack vs email", "review my week"
- User wants a per-day or per-channel breakdown
- User wants to compare sources (Slack vs calendar vs email volume)
- NOT for: installing a new tracker like ActivityWatch/WakaTime (different ask — recommend tools separately), NOT for forward-looking forecasts, NOT for billing/billable-hours tracking

## Why this approach

Most time-tracking tools ask the user to **add a new step** (start a timer, install an agent, tag an entry). The user already has rich telemetry on their Mac — they just don't have a methodology to read it. This skill turns existing logs into estimates without changing workflow.

The signals:

| Source | What's in it | File / DB |
|---|---|---|
| Slack/Hermes session log | Every agent turn, source=slack has chat_id/thread_id/started_at | `~/.smartclaw/state.db` (table `sessions`, `messages`) |
| Calendar | Past + future events | `gog calendar events --days N` (account-flagged) |
| Gmail | Inbound + outbound message timestamps | `gog gmail search "newer_than:Nd" -j` |
| Claude Code history | Per-session jsonl transcripts | `~/.claude/projects/-Users-jleechan/*.jsonl` |
| EA briefings | Pre-summarized daily activity | `~/.smartclaw/memory/briefings/YYYY-MM-DD/` |
| Beads / `br` | Open/closed issues | `br list --status open --json` |

## Methodology

### Step 1 — Run the canonical queries

All five core queries live in `scripts/queries.sh` (see linked files below). The math:

- **Slack active user-hours** = `sum(per session: max(messages.timestamp) - min(messages.timestamp WHERE role='user'))` for sessions where `source='slack'` AND the session span is < 2 hours (long idle gaps are excluded). This is "engaged time in thread" — NOT wall-clock session lifetime.
- **Calendar meeting time** = `sum(end - start)` for events with `start.dateTime` AND duration < 24h. **Filter multi-day carry-forward events** (anything where end-start > 24h, e.g. "Trip to Dublin Jun 19 → Aug 23").
- **Email volume** = `count` from `gog gmail search "newer_than:Nd"`. Multiply by ~2-3 min/message for reading+reply time budget.
- **Code editor time** = inferred from `git log` density + Claude session count + commit cadence. Real measurement requires WakaTime (not installed).

### Step 2 — Get the time-window right

Default = last 14 days. Adjust to last 7 if user asks about "this week".

### Step 3 — Present the data, NOT a verdict

The user wants visibility, not judgment. Format the response as a clean table with per-source and per-day breakdown. Include the explicit caveats (see Pitfalls). Do NOT say "you spend too much time in Slack" — show the data and let them decide.

### Step 4 — Offer the next step

End with 1-3 concrete options, e.g.:
- Install a real tracker (ActivityWatch + WakaTime + Timewarrior)
- Daily/weekly digest cron that surfaces this automatically
- Pull historical calendar for retrospective meeting analysis

## Pitfalls

- **Gmail precondition check failures**: `gws gmail +triage` returns `Precondition check failed` when OAuth scopes are missing. Use `gog` (not `gws`) — different auth, different scopes. If `gog` also fails, the calendar/gmail account isn't enrolled yet — say so, don't fabricate.
- **Calendar junk carry-forward**: Multi-week events ("Trip to Dublin Jun 19 → Aug 23") show up as 1562-hour "meetings" if you naively sum. Filter on duration > 24h. The EA briefing skill already filters these (P91/P92); mirror that logic.
- **Session `ended_at` is unreliable**: For live/recent Hermes sessions, the `ended_at` column may be unset or default to garbage (e.g., `started_at + 1 day`). Do NOT use `ended_at - started_at` for time-on-task. Use message timestamps: `max(messages.timestamp) - min(messages.timestamp WHERE role='user')` per session.
- **"Session wall-clock" overstates engagement**: A Slack thread sitting idle for 90 min still adds 90 min to naive span. Cap gaps at 2h before summing, or report both numbers (raw span vs. capped span).
- **07-31 / similar spikes are compaction events**: One-day spikes of 40k+ user messages are typically Hermes session-compaction, not real activity. Filter by checking `message_count` distribution per day before quoting.
- **Work-calendar auth**: The work account (`jleechan@worldarchitect.ai`) is often unauthorized (401). Default to `jleechan@gmail.com` for personal calendar; don't waste time on the work cal unless explicitly asked.
- **Two executive-assistant skills exist**: `skill_view` fails with "ambiguous" — load the local one explicitly via `~/.smartclaw/skills/executive-assistant/SKILL.md` if you need it.
- **Web search is Firecrawl-gated and may not be configured**: If `web_search` errors with Firecrawl auth, fall back to local knowledge for tool recommendations; do not block on the web call.
- **Slack channel IDs ≠ human names**: `display_name` in `sessions` table sometimes shows the raw channel ID (e.g. `C0AH3RY3DK6`) instead of the readable name. Cross-reference via `chat_id` lookup if needed.

## Output format (template)

```
# Time-spent estimate — last 14d (YYYY-MM-DD → YYYY-MM-DD)

## Per-day breakdown

| Date | Slack active | Meetings | Email msgs | Notes |
|---|---|---|---|---|
| ... | | | | |

## Per-channel breakdown (Slack)

| Channel | Purpose | Sessions | Engaged time |
|---|---|---|---|

## Caveats
- Session wall-clock overstates engagement by ~30-40% (idle gaps in threads).
- Editor/IDE coding time inferred from commit density, not measured.
- Email time estimated at ~3 min/message (reading + reply budget).
```

## Linked files

- `scripts/queries.sh` — the 5 core SQLite + gog queries (canonical, copy-paste-runnable)
- `references/sources.md` — what each local source contains, schema notes, and known quirks
- `references/tool-recommendations.md` — when the user asks "and what tools should I install?", here are the open-source options ranked for this setup
