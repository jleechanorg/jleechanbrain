---
name: time-spent-estimation
version: 1.0.0
description: |
  Estimate user time spent across all available sources (Slack/Hermes sessions, Gmail, calendar,
  Claude Code history, EA briefings, beads backlog). Aggregate to per-source hours and per-day
  breakdown. Honest about coverage gaps. Suggests OS tools for active tracking.
triggers:
  - "time spent"
  - "how did I spend my time"
  - "time estimate"
  - "track time"
  - "estimate time"
  - "/time-spent"
  - "where did my time go"
allowed-tools:
  - Bash
  - Read
context: inline
---

# Time-Spent Estimation

## Contract

This skill **aggregates** time-spent signals from local sources; it does NOT
install tracking software, NOR make ungrounded claims. Every report must include:
1. Sources table with `status: ok | BLOCKED` for each (never silent drops).
2. Headline hours (≥ 3 sources) with idle-correction surfaced.
3. Per-day breakdown for the window.
4. Limitations list (≥ 5 entries, every estimate must have one).
5. Next-actions menu (A/B/C, never open-ended).

Violating this contract is a SOUL.md `proof-before-claim` failure.

Recurring workflow for "how did I spend my time across all sources." Pulls live data from
local sources (no web), aggregates, and reports with honest coverage limits.

## When to use

User asks for a time-spent / time-tracking estimate across their work surface. Use the
shapes "time spent", "where did my time go", "estimate time", "track time", "/time-spent",
"how did I spend my time."

**Out of scope:** active real-time tracking (delegate to OS tools — ActivityWatch/WakaTime/Timewarrior);
historical time entry beyond 14d (data volume + noise); HR/billing categorization.

## Sources (in priority order)

| # | Source | Path / Tool | What you get | Coverage |
|---|--------|-------------|--------------|----------|
| 1 | **Hermes Slack sessions** | `~/.smartclaw/state.db` SQLite, `sessions` + `messages` tables | Wall-clock session span, per-channel split, per-day-per-hour density | Last 14d |
| 2 | **Hermes history** (`/history`) | Same DB | Cross-check; type breakdown (cli/slack/cron/subagent) | Last 14d |
| 3 | **Calendar (Gmail account)** | `gog calendar events --days 14` | Real meeting time; junk-filter multi-day carry-forwards | Forward + past 14d |
| 4 | **Gmail activity** | `gog gmail search` | Inbound volume; reply budget via message counts | Last 7–14d |
| 5 | **Claude Code history** | `~/.claude/projects/-Users-jleechan-*/` JSONL | Editor session count, file touch signal | Last 14d |
| 6 | **EA briefings** | `~/.smartclaw/memory/briefings/YYYY-MM-DD/` | Pre-summarized daily work blocks | Most recent days only |
| 7 | **Beads backlog** | `br list --priority 0..1 --status open` | Work in flight (hours-implied, NOT measured) | Current state |

## Phases

### Phase 1 — Identify sources (3 quick checks)

Before pulling data, run these in parallel:

```bash
ls -la ~/.smartclaw/state.db              # Hermes SQLite?
which gog && gog auth status          # Google auth?
ls ~/.claude/projects/-Users-jleechan- | wc -l   # Claude history?
```

If a source is missing, mark it `BLOCKED` in the final report (don't silently drop).

### Phase 2 — Pull data (parallel)

The shipped script `scripts/pull_time_signals.py` runs the canonical queries and writes
JSON to `~/.smartclaw/var/time-spent/<ts>.json`. Run it; do not re-derive the SQL inline.

```bash
python3 ~/.smartclaw/skills/time-spent-estimation/scripts/pull_time_signals.py \
  --days 14 \
  --out ~/.smartclaw/var/time-spent/
```

What it pulls:
- Hermes SQLite: per-session span, per-channel time, per-day-per-hour density
- Calendar events: from `gog calendar events --days 14` (forward)
- Gmail: from `gog gmail search` (count only — duration inferred)
- Claude history: file count + last-modified
- Briefings: list `~/.smartclaw/memory/briefings/` for the date range
- Beads: `br list --priority 0..1 --status open --json` for in-flight work

### Phase 3 — Aggregate + report

The script outputs structured JSON. You (the agent) compose the human-facing report:

1. **Sources table** (status: ✅ / ⚠️ / BLOCKED)
2. **Headline table** (per-activity hours + per-day avg)
3. **Per-day breakdown** (last 7–14d)
4. **Channel breakdown** (Slack only)
5. **Honest limitations** — at least 3, every estimate must have one
6. **Next actions** — A/B/C menu (install tools / enable digest / historical pull)

### Phase 4 — Caveats to always surface

- **Session wall-clock overstates engaged time.** A session sitting idle for 90 min still
  counts in the span. Apply a 30–40% idle-correction when reporting focused-work hours.
- **`ended_at` in Hermes DB is unreliable** (often `started_at + 1d` default; not real duration).
  Compute span from `first_user_msg → last_msg` in `messages` table.
- **Gmail volume ≠ time spent.** Counts inbound, not send/reply duration. Default 2–3 min/msg.
- **Calendar junk filter required.** Multi-day "Trip to Dublin"-style carry-forward events
  inflate totals. Drop any event whose `DTSTART;DTEND - DTSTART > 8h` unless explicitly
  marked as a workday block.
- **Editor/IDE coding time is inferred**, not measured (no WakaTime yet). Real number is
  likely 40–60h/14d based on commit cadence in `jleechanorg/*`.

### Phase 5 — Recommended OS tools (recommend only if asked)

When user asks "what tool should I install," shortlist:

1. **ActivityWatch** (`brew install --cask activitywatch`) — passive keystroke/app/window
2. **WakaTime** (`brew install wakatime-cli`) — editor heartbeat per repo
3. **Timewarrior** (`brew install timewarrior`) — tag-driven CLI tracker
4. **Toggl Track CLI** (`brew install toggl-cli`) — billable-style manual entries

All local, all free, no sudo. AW + WakaTime + Timewarrior covers passive + editor + tag layers.

## Output Format

The script's JSON schema (`scripts/pull_time_signals.py --schema`):

```json
{
  "window_days": 14,
  "sources": {
    "hermes_sqlite": {"status": "ok", "sessions": 6795, "user_msgs": 53488},
    "calendar":       {"status": "ok", "events": 10, "real_hours": 20.0},
    "gmail":          {"status": "ok", "messages_14d": 200, "avg_per_day": 28},
    "claude_history": {"status": "ok", "files": 45, "lines": 6846},
    "briefings":      {"status": "ok", "dirs_in_range": 5},
    "beads":          {"status": "ok", "open_p0_p1": 16}
  },
  "by_day":       [{"date": "2026-08-04", "user_msgs": 74, "sessions": 39, "est_minutes": 780}, ...],
  "by_channel":   [{"channel": "#worldai", "sessions": 70, "est_minutes": 1320}, ...],
  "headline_hours": {"slack_active": 391, "calendar": 20, "email": 8.5, "code": 30, "cron": 10}
}
```

The agent's report renders this into Slack-friendly markdown with the limitations section.

## Anti-Patterns

- ❌ **Claiming "skill created" before the file exists on disk.** (Prior bug 2026-08-11 —
  replied "Skill created" then dropped the thread without writing `SKILL.md`. Audit detector:
  `ls ~/.smartclaw/skills/<skill>/SKILL.md` MUST return a non-empty file before the claim.)
- ❌ **Reporting "Slack sessions = focused work" without idle correction.** Always apply
  the 30–40% idle factor or surface the over-count.
- ❌ **Dropping "BLOCKED" sources silently.** If `gog`/`gws` auth is missing (note: `gws` is BANNED for personal Workspace calls per SOUL.md ## COMMIT: gws-banned-for-personal-workspace, so only `gog` matters here), mark it
  `BLOCKED` and tell the user what would unlock it.
- ❌ **Pulling only forward calendar and calling it "historical."** Forward events are
  future projections, not retrospective. Re-run with `--past` for historical.
- ❌ **Using the `ended_at` column from Hermes DB.** It's a default `started_at + 1d`,
  not real duration. Always compute span from messages.
- ❌ **Writing skills to `~/.agents/skills/`** (orphaned staging path; not a resolver
  source). Use `~/.smartclaw/skills/<name>/`.

## Files

- `SKILL.md` — this file
- `scripts/pull_time_signals.py` — deterministic data puller
- `tests/test_pull_time_signals.py` — schema + happy-path + edge cases
- `references/limitations-and-corrections.md` — long-form limitations catalog