#!/usr/bin/env bash
# dropped-thread-watcher-of-watchers.sh
# 2026-07-04: a launchd-meta-watchdog to detect silent death of
# ai.smartclaw.schedule.dropped-thread-followup.
#
# Why: 2026-07-03 15:22 PT → 2026-07-04 00:18 PT (~9h gap) the dropped-thread cron
# silently stopped firing. launchctl print showed "state = not running, last exit code = 0".
# The c9h gap caused a user message in #all-jleechan-ai (${SLACK_CHANNEL_ID}) to go unanswered
# for ~22 min before a manual redrive caught it. Without this watcher, a recurrence
# would re-blind the channel for up to StartInterval (4h, now 30m) per silent death.
#
# Contract: every 15 min, verify that:
#  1. ai.smartclaw.schedule.dropped-thread-followup is loaded in launchd
#  2. Its log file was touched within (60m × lookback multiplier) — default 90m
#  3. If either fails, post a single Slack alert to HERMES_OPS_SLACK_CHANNEL with
#     the failure reason and the suggested `launchctl` recovery commands.
#
# Trigger: launchd plist ai.smartclaw.schedule.dropped-thread-watcher.plist (every 900s).
# Idempotent — uses a watchdog state file at $HERMES_HOME/state/dropped-thread-watcher.state
# to suppress duplicate alerts within a 6h window.

set -uo pipefail

HERMES_HOME="${HERMES_HOME:-${HOME}/.smartclaw}"
WATCH_LABEL="ai.smartclaw.schedule.dropped-thread-followup"
STATE_FILE="$HERMES_HOME/state/dropped-thread-watcher.state"
COOLDOWN_SECONDS="${WATCH_COOLDOWN_SECONDS:-21600}"   # 6h
LOG_MAX_AGE_SECONDS="${WATCH_LOG_MAX_AGE:-5400}"        # 90 min (1.5x of new StartInterval=1800s)
LOG_PATH="$HERMES_HOME/logs/dropped-thread-followup.log"

# Use the umbrella ops channel from launchd-env-wrapper.sh plumbing.
HERMES_OPS_SLACK_CHANNEL="${HERMES_OPS_SLACK_CHANNEL:-${SLACK_CHANNEL_ID}}"
SLACK_TOKEN="${SLACK_BOT_TOKEN:-${SLACK_BOT_TOKEN:-}}"
: "${STATE_DIR:=$(dirname "$STATE_FILE")}"
mkdir -p "$STATE_DIR"

now=$(date +%s)

# 1. Is the watcher plist loaded?
launchd_status=""
if launchctl print "gui/$(id -u)/$WATCH_LABEL" >/dev/null 2>&1; then
  launchd_status="loaded"
else
  launchd_status="NOT_LOADED"
fi

# 2. Log mtime check
log_mtime=0
if [ -f "$LOG_PATH" ]; then
  log_mtime=$(stat -f "%m" "$LOG_PATH" 2>/dev/null || echo 0)
fi
log_age=$(( now - log_mtime ))
log_status="ok"
if [ "$log_mtime" -eq 0 ]; then
  log_status="LOG_MISSING"
elif [ "$log_age" -gt "$LOG_MAX_AGE_SECONDS" ]; then
  log_status="LOG_STALE_${log_age}s"
fi

# Decide whether to alert
needs_alert=0
reason=""
if [ "$launchd_status" != "loaded" ]; then
  needs_alert=1
  reason="launchd job NOT loaded (state=$launchd_status)"
elif [ "$log_status" != "ok" ]; then
  needs_alert=1
  reason="log $log_status (max_age=${LOG_MAX_AGE_SECONDS}s)"
fi

if [ "$needs_alert" -eq 0 ]; then
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ok launchd=$launchd_status log_age=${log_age}s"
  exit 0
fi

# Cooldown — only alert once per COOLDOWN_SECONDS to avoid Slack spam
last_alert=0
if [ -f "$STATE_FILE" ]; then
  last_alert=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
fi
since_last=$(( now - last_alert ))
if [ "$since_last" -lt "$COOLDOWN_SECONDS" ] && [ "$last_alert" -gt 0 ]; then
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] SILENT (alert suppressed, ${since_last}s < ${COOLDOWN_SECONDS}s cooldown) reason=$reason"
  exit 0
fi

# Build the message
recovery_cmd="launchctl unload -w ~/Library/LaunchAgents/${WATCH_LABEL}.plist 2>/dev/null; launchctl load -w ~/Library/LaunchAgents/${WATCH_LABEL}.plist"
msg=":rotating_light: *dropped-thread-followup watcher-of-watchers ALERT* — $reason. Recovery: \`$recovery_cmd\` . Last log mtime: ${log_mtime} (${log_age}s ago). Now: $(date -u +%Y-%m-%dT%H:%M:%SZ)."

# Post to Slack (3-stage file upload not needed for plain text — use chat.postMessage)
if [ -n "$SLACK_TOKEN" ]; then
  body=$(printf '{"channel":"%s","text":%s}' "$HERMES_OPS_SLACK_CHANNEL" "$(printf '%s' "$msg" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')")
  curl -sS --max-time 10 -X POST "https://slack.com/api/chat.postMessage"     -H "Authorization: Bearer $SLACK_TOKEN"     -H "Content-Type: application/json; charset=utf-8"     -d "$body" >/dev/null 2>&1
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ALERTED: $reason"
else
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ALERT (no slack token): $reason" >&2
fi

# Stamp state for cooldown
echo "$now" > "$STATE_FILE"
exit 1
