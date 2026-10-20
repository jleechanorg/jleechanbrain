# Limitations & Corrections Catalog

Long-form catalog of the limitations the script surfaces in `payload["limitations"]`,
plus the corrections applied. Keep this list in sync with `scripts/pull_time_signals.py`.

## Session wall-clock overstates engaged time

A Slack session sitting idle for 90 minutes still counts in the `first_user_msg → last_msg`
span. We apply a **35% idle correction** (`× 0.65`) when reporting
`headline_hours.slack_active_idle_corrected`. Without the correction, the headline
number is ~50% higher than actual focused work.

## `ended_at` column is unreliable

Hermes DB `sessions.ended_at` is often `started_at + 86400` (default 1-day window).
Not a real session duration. We compute span from `MIN(timestamp) → MAX(timestamp)`
in `messages` for the session, with a hard **120-min/session cap** so a session that
runs across two days doesn't inflate the total.

## Gmail volume ≠ time spent

`gog gmail search` returns message counts, not reading/sending duration. The
2.5 min/msg heuristic covers: read (1 min), reply or delete (1.5 min). For a
high-reply user this underestimates; for a digest-only user it overestimates.

## Editor/IDE coding time is inferred

No WakaTime running yet. We assume ~30h/14d based on commit cadence in
`jleechanorg/*` repos. Real number for a heavy-PR day (08-05/08-06) is closer
to 8-10h; for a light day it's <1h.

## Calendar events are forward-looking

Default `gog calendar events --days 14` shows the next 14 days. Historical
meeting time requires a `--past` flag or a different range. Multi-day carry-
forward junk ("Trip to Dublin" running Jun 19 → Aug 23) inflates totals — we
filter events with duration > 8h into `junk_events` (counted, not summed).

## Cron / subagent time is heuristic

Hermes DB has source=`cron`, source=`subagent`, source=`cli`, source=`slack` rows
in `sessions`. Cron + subagent count is included in `per_day_minutes` and
inflates the headline. The `cron_overhead_estimate = 10h/14d` is a heuristic
based on prior session density; not measured.

## Slack channel `chat_id` is sometimes NULL

For sessions where `chat_id` is NULL (CLI / cron / subagent without a Slack
context), the channel breakdown groups them under `"null"`. This is ~430 of 742
sessions in 14d — most of the activity is not Slack channel-attributed.