---
description: /launchd-autonomy-report — scan the last 48h for left/right-shift violations, plus cross-channel Slack search (Signal E) and memory cross-reference (Signal F), and post a single Slack digest ONLY on violations. Quiet on success. Also exposes the underlying detector script for ad-hoc use.
type: orchestration
execution_mode: immediate
---

# /launchd-autonomy-report

**Daily detector that scores Hermes against Jeffrey's left/right-shift autonomy tenet** (from 2026-06-27 thread ${SLACK_CHANNEL_ID}, msg `1782598553.950269`):

1. **Left shift** — spend more time UPFRONT on planning + setup. Mid-task interruptions to ask the user questions or do validation are bad.
2. **Right shift** — spend more time at the END validating output (UI, captioned video/gif of landing page or any user-facing surface).
3. **AVOID** — interrupting the user in the MIDDLE for things that should have been done at the planning stage or the validation stage.

## What it scans (last 48h)

| Signal | Failure mode | Direction |
|---|---|---|
| **A** | Mid-task clarifying question after `/a` or `/fullrun` (or natural-language variant) | LEFT-SHIFT FAIL |
| **B** | UI / landing-page / wizard / form change finished WITHOUT visual proof (`MEDIA:` + `/er`) | RIGHT-SHIFT FAIL |
| **C** | SOUL.md `## COMMIT: a-fullrun-evidence-stack` missing on staging OR prod tree | TENET ENFORCEMENT FAIL |
| **D** | "want me to X?" / "should I X?" follow-up posted after a hands-off directive | MID-TASK FAIL |
| **E** | Slack search matching cross-channel autonomy keywords (e.g. "want me to", "hands off") | CROSS-CHANNEL FAIL |
| **F** | /ms (memory_search) cross-reference to check prior autonomy/left/right-shift violations | MEMORY CONTEXT FAIL |

## Usage

```
/launchd-autonomy-report            # scan last 48h (default)
/launchd-autonomy-report --dry-run  # scan + log but suppress Slack post
/launchd-autonomy-report --48h      # scan last 48h (default)
/launchd-autonomy-report --7d       # look back 7 days
/launchd-autonomy-report --channel C0XXX  # alert to a different channel
```

The detector is also run automatically by the launchd job:

```
ai.smartclaw.schedule.autonomy-report   ← fires daily at 09:00 PT (Mon–Fri)
```

## When invoked

1. **Load the skill (this file).** Bash 4+ on macOS (`/opt/homebrew/bin/bash`).
2. **Run the detector script:**
   ```bash
   /opt/homebrew/bin/bash ~/.smartclaw/scripts/autonomy-report.sh
   ```
   Defaults: `AUTONOMY_LOOKBACK_HOURS=48`, `AUTONOMY_DRY_RUN=0`, `AUTONOMY_ALERT_CHANNEL=C0AJQ5M0A0Y` (=#ai-general).
3. **Respect the quiet-on-success contract** — the script posts ONE Slack digest ONLY when violations are found. A clean run exits 0 with no stdout/Slack output. Same pattern as `slack-5b-leak-detector.sh`.
4. **Read the state log** for trend tracking: `~/.smartclaw/var/autonomy-report.state.jsonl`.
5. **Each violation in the digest has a one-line remediation** — A → front-load planning into the brief BEFORE `ao spawn`; B → use the `a-fullrun-evidence-stack` COMMIT contract; C → commit + push + Stage 4.5 sync (re-run `deploy.sh`); D → never post "want me to X?" after an /a or /fullrun; E → bot token missing search:read scope OR check keywords; F → verify memory search configuration or review fallback files.

## Equivalent phrases that auto-fire this command

- "daily /launchd autonomy report"
- "build a /launchd job that checks autonomy"
- "score hermes on the left/right-shift tenet"
- "tenet violation detector"
- "autonomy report run"

## Related

- `~/.smartclaw/scripts/autonomy-report.sh` — the detector (this is what the slash command runs)
- `~/.smartclaw/launchd/ai.smartclaw.schedule.autonomy-report.plist.template` — the daily 09:00 PT launchd job
- `~/.smartclaw/.claude/commands/a.md` + `/fullrun` — the hands-off directives this detector enforces
- `~/.smartclaw/workspace/SOUL.md` `## COMMIT: a-fullrun-evidence-stack` — the contract this detector verifies
- `~/.smartclaw/scripts/slack_5b_leak_detector.sh` — adjacent precedent (same quiet-on-success + same channel list)

## Provenance

Built 2026-06-27 in response to Jeffrey's request: *"ok lets test some things to ensure its more automous now and lets design and build a daily /launchd autonomy report to ensures hermes is following my left/right shift tenet"*. Promotion pattern matches `slack-5b-leak-detector` (passive daily detector, single Slack alert on violation).