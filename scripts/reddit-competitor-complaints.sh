#!/bin/bash
# reddit-competitor-complaints.sh — daily 8:00 AM PT launchd job.
# Searches Reddit via headless browser for top complaint / alternative threads
# about AI Dungeon, Friends & Fables, and Voyage, then posts a top-10 digest
# to the user's originating Slack thread (with home-channel fallback).
#
# Why headless browser: every public search engine rate-limits this MacBook's
# IP within 2-4 queries. Playwright Chromium gets a real browser fingerprint
# and side-steps the curl-level rate limit. The first 1-3 queries of the day
# typically succeed; later ones back off and rotate.
#
# Cron registration (this is the raw-launchd sibling, not an LLM-cron job):
#   Label: ai.smartclaw.schedule.reddit-competitor-complaints
#   Plist: ~/Library/LaunchAgents/ai.smartclaw.schedule.reddit-competitor-complaints.plist
#   Schedule: 8:00 AM daily (America/Los_Angeles)
#
# Verified on 2026-06-23:
#   - First manual run: 7/7 queries blocked by 429/403 across Brave, Mojeek,
#     Marginalia, Qwant, Kagi, you.com, DDG, Bing, Yandex, Reddit rss.
#   - Job installed and scheduled; tomorrow 8 AM is the first real fire.
#
# Delivery:
#   - Primary:  slack:C0AUXSVFSA2 (channel-only — new top-level message daily)
#   - Fallback: slack:C0AJQ5M0A0Y (home channel, if workspace token missing)
#   - Failure-mode: if NO engine returns data, post a "no data — all engines
#     rate-limited" message so the daily job never goes silent.
#   - History: prior to 2026-08-05 PRIMARY was pinned to thread_ts=1782239564.437219,
#     which caused every daily run to reply into one ever-growing thread.
#     User feedback: "this job should start new threads, not reply to same one."

set -u  # NOTE: not -e, not -o pipefail — see DIGEST extraction below

LABEL="ai.smartclaw.schedule.reddit-competitor-complaints"
# Channel-only targets — each daily fire starts a NEW top-level message
# (no thread_ts), so the channel timeline is one digest per day per channel
# instead of a single growing reply chain. Fix 2026-08-05: previously pinned
# thread_ts=1782239564.437219 made every run reply to the same thread.
PRIMARY_TARGET="slack:C0AUXSVFSA2"
FALLBACK_TARGET="slack:C0AJQ5M0A0Y"

SCRIPT_DIR="$HOME/.smartclaw/scripts"
LOG_FILE="$HOME/.smartclaw/logs/scheduled-jobs/reddit-competitor-complaints.$(date -u +%Y-%m-%dT%H).log"
mkdir -p "$(dirname "$LOG_FILE")"
exec >> "$LOG_FILE" 2>&1

echo "=== launchd tick $(date -u +%FT%TZ) ==="
echo "Target: $PRIMARY_TARGET (fallback: $FALLBACK_TARGET)"

# NOTE on env loading: do NOT source launchd-env-wrapper.sh here. The wrapper
# script (reddit-competitor-complaints-wrapper.sh) already runs the right chain:
#     bash -c "source launchd-env-wrapper.sh >/dev/null 2>&1; exec $0"
# If we source it again, the env-wrapper's terminal `exec "$@"` runs in our
# current shell with our (empty) positional args and replaces this script with
# `exec` (no-op or 127) — verified bug 2026-06-23 against this very script.
# SLACK_BOT_TOKEN is therefore already in env by the time we run.

echo "Target: $PRIMARY_TARGET (fallback: $FALLBACK_TARGET)"

# Run the python script and capture its stdout
RAW_OUT=$(python3 "$SCRIPT_DIR/reddit-competitor-complaints.py" 2>&1)
PY_RC=$?
echo "=== python exit=$PY_RC ==="
echo "$RAW_OUT" | tail -40

# If the script produced a digest, post it.
# Capture every line between the open marker and the "=== end" sentinel.
# Use awk's own NR exit (no `head` in the pipe) — under `set -o pipefail`,
# `head` exiting early would send SIGPIPE to awk and propagate rc=141.
DIGEST=$(echo "$RAW_OUT" | awk '
  /^=== Reddit competitor-complaints digest/ {flag=1}
  /^=== end \([0-9]+ threads emitted\) ===/ {if (flag) {flag=0; print; exit}}
  flag {print}
')
if [ -z "$DIGEST" ]; then
  # Either python failed OR no hits — synthesize a status message
  if [ "$PY_RC" -ne 0 ]; then
    DIGEST="*Reddit competitor complaints — daily 8 AM run*
:rotating_light: Script crashed (exit=$PY_RC). See log: $LOG_FILE"
  else
    HITS_LINE=$(echo "$RAW_OUT" | grep -E "Total unique threads" | head -1)
    DIGEST="*Reddit competitor complaints — daily 8 AM run*
:warning: No Reddit hits this cycle. Every search engine (Brave, Mojeek, Kagi, you.com, DDG, Reddit rss) returned 429/403 or zero results.
${HITS_LINE:-}
Next attempt: tomorrow 8 AM. Log: $LOG_FILE"
  fi
fi

# Post to Slack
TOKEN="${SLACK_BOT_TOKEN:-}"
if [ -z "$TOKEN" ]; then
  echo "FATAL: SLACK_BOT_TOKEN still empty after env-wrapper — cannot post"
  echo "Digest (not delivered):"
  echo "$DIGEST"
  exit 1
fi

post_to_slack() {
  local target="$1"
  local text="$2"
  # target is "slack:CHAN[:thread_ts]"
  local chan thread_ts
  if [[ "$target" =~ ^slack:([A-Z0-9]+)(:([0-9.]+))?$ ]]; then
    chan="${BASH_REMATCH[1]}"
    thread_ts="${BASH_REMATCH[3]:-}"
  else
    echo "Bad target format: $target"
    return 1
  fi

  local payload
  if [ -n "$thread_ts" ]; then
    payload=$(jq -nc --arg ch "$chan" --arg txt "$text" --arg ts "$thread_ts" \
      '{channel:$ch, text:$txt, thread_ts:$ts, unfurl_links:false, unfurl_media:false}')
  else
    payload=$(jq -nc --arg ch "$chan" --arg txt "$text" \
      '{channel:$ch, text:$txt, unfurl_links:false, unfurl_media:false}')
  fi

  local resp
  resp=$(curl -sS -X POST "https://slack.com/api/chat.postMessage" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json; charset=utf-8" \
    --data-binary "$payload" 2>&1)
  local ok
  ok=$(echo "$resp" | head -c 500 | grep -c '"ok":true' || true)
  if [ "$ok" -gt 0 ]; then
    echo "Posted to $chan (thread=${thread_ts:-none})"
    return 0
  else
    echo "Slack post to $chan failed: ${resp:0:200}"
    return 1
  fi
}

# Try primary, fallback if needed
if post_to_slack "$PRIMARY_TARGET" "$DIGEST"; then
  echo "=== tick done (delivered to primary) ==="
  exit 0
fi

# Primary rejected (likely cross-workspace token guard). Try fallback.
FALLBACK_TEXT="$DIGEST

_(Delivered to home channel fallback — original thread workspace has no bot token configured. To restore: add the originating workspace's bot token to ~/.smartclaw/slack_tokens.json.)_"

if post_to_slack "$FALLBACK_TARGET" "$FALLBACK_TEXT"; then
  echo "=== tick done (delivered to fallback) ==="
  exit 0
fi

echo "FATAL: both primary and fallback Slack posts failed"
echo "Digest (lost):"
echo "$DIGEST"
exit 1
