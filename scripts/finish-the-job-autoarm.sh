#!/usr/bin/env bash
# finish-the-job-autoarm.sh
#
# Safety net for SOUL.md ## COMMIT: finish-the-job. Re-dispatches a stalled
# goal-shaped Slack thread through the finish-the-job pipeline when the
# inline session ack'd but didn't drive it to a provable end-state within
# AUTOARM_GRACE_MIN.
#
# Runs every 15 minutes via launchd. Idempotent — state file at
# $HERMES_STATE_DIR/finish-the-job-autoarm.state tracks (channel, thread_ts)
# pairs and the dispatch count. State survives reboot (under $HOME, not TMPDIR).
#
# Logs: ~/.smartclaw/logs/finish-the-job-autoarm.{log,err}
# Slack delivery: chat.postMessage via curl + SLACK_BOT_TOKEN
# (same path dropped-thread-followup.sh uses, verified 2026-06-19).
#
# When to actually post: the dropped-thread-followup audit emits a
# "DRY_RUN: would nudge <chan> <ts>" line for each actionable thread.
# For each one we haven't re-dispatched MAX_REDISPATCHES times yet, we
# post a finish-the-job-style nudge (re-state goal, re-state contract,
# link thread) so the next inline session sees the recovery signal.
#
# Verified 2026-06-19:
#   - Bash 4+ required for `mapfile` (launchd uses /bin/bash 3.2 on macOS;
#     we re-exec into /opt/homebrew/bin/bash 5.x). Tested under both.
#   - Slack post path matches dropped-thread-followup.sh: token from
#     SLACK_BOT_TOKEN (sourced from ~/.bashrc via sourcing wrapper
#     in cron), curl to slack.com/api/chat.postMessage.
#   - State moved from $TMPDIR to $HERMES_STATE_DIR (CodeRabbit MAJOR).

set -euo pipefail

# Force bash 4+ on macOS where /bin/bash is 3.2 (mapfile is a bash 4 feature).
# Verified 2026-06-19 — cron died with exit 127 "mapfile: command not found"
# because launchd ran it under /bin/bash 3.2, not the interactive shell's bash 5.
if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash ${HOME}/.nvm/versions/node/*/bin/bash; do
    if [[ -x "$candidate" ]]; then
      exec "$candidate" "$0" "$@"
    fi
  done
  echo "finish-the-job-autoarm: bash 4+ required (have bash ${BASH_VERSION}); no candidate found" >&2
  exit 1
fi

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin${PATH:+:$PATH}"

HERMES_HOME="${HERMES_HOME:-$HOME/.smartclaw}"
DROPPED_SCRIPT="${DROPPED_SCRIPT:-$HERMES_HOME/scripts/dropped-thread-followup.sh}"
LOG_FILE="$HERMES_HOME/logs/finish-the-job-autoarm.log"
ERR_FILE="$HERMES_HOME/logs/finish-the-job-autoarm.err"
STATE_DIR="${HERMES_STATE_DIR:-$HERMES_HOME/state}"
STATE_FILE="$STATE_DIR/finish-the-job-autoarm.state"

# Load Slack token from interactive-shell environment (cron doesn't source ~/.bashrc).
# Compatible with the dropped-thread-followup.sh sourcing convention.
TOKEN="${SLACK_BOT_TOKEN:-}"
if [[ -z "$TOKEN" ]]; then
  TOKEN="$(bash -c 'source ~/.bashrc 2>/dev/null; echo -n "${SLACK_BOT_TOKEN:-}"' 2>/dev/null || true)"
fi
if [[ -z "$TOKEN" ]]; then
  TOKEN="$(bash -c 'source ~/.zshrc 2>/dev/null; echo -n "${SLACK_BOT_TOKEN:-}"' 2>/dev/null || true)"
fi

AUTOARM_CHANNELS="${AUTOARM_CHANNELS:-C0AH3RY3DK6 ${SLACK_CHANNEL_ID}}"
AUTOARM_GRACE_MIN="${AUTOARM_GRACE_MIN:-30}"
AUTOARM_LOOKBACK_H="${AUTOARM_LOOKBACK_H:-4}"
MAX_REDISPATCHES="${MAX_REDISPATCHES:-1}"
DRY_RUN="${DRY_RUN:-0}"

mkdir -p "$(dirname "$LOG_FILE")" "$STATE_DIR"
ts() { date '+%Y-%m-%d %H:%M:%S'; }

# SECURITY: scrub any token-shaped strings (xoxb-..., xoxp-..., xoxa-...) from the log
# before tee. CRITICAL — the previous version leaked the bot token into the log on every tick.
scrub_token() {
  local input="$1"
  if [[ -z "$TOKEN" ]]; then
    printf '%s' "$input"
    return
  fi
  local escaped="${TOKEN//[\&/]/\\&}"
  printf '%s' "$input" | sed -E "s/${escaped}/<TOKEN_REDACTED>/g; s/xox[abp]-[A-Za-z0-9-]{20,}/<TOKEN_REDACTED>/g"
}
_log_raw() { echo "[$(ts)] $*"; }
_log_scrubbed() { scrub_token "$(_log_raw "$*")"; }
log() { _log_scrubbed "$*" | tee -a "$LOG_FILE" >&2; }
err() { _log_scrubbed "$*" | tee -a "$ERR_FILE" >&2; }

# IMPORTANT: never echo goal text into the log — user Slack requests may
# include private incident details, secrets, or PII. Log state_key + count only.
log "finish-the-job-autoarm start (channels='$AUTOARM_CHANNELS' grace=${AUTOARM_GRACE_MIN}m lookback=${AUTOARM_LOOKBACK_H}h dry_run=$DRY_RUN token=${TOKEN:+present}${TOKEN:-MISSING})"

if [[ ! -x "$DROPPED_SCRIPT" ]]; then
  err "dropped-thread-followup.sh not found at $DROPPED_SCRIPT — cannot scan. Bailing."
  exit 1
fi

# Snapshot actionable dropped threads via the existing cron script in DRY_RUN mode.
TMPDIR_LOCAL=$(mktemp -d -t finish_the_job_autoarm.XXXXXX)
trap 'rm -rf "$TMPDIR_LOCAL"' EXIT

DRY_RUN=1 \
  DROP_LOOKBACK_HOURS="$AUTOARM_LOOKBACK_H" \
  DROP_CHANNELS="$AUTOARM_CHANNELS" \
  DROP_THREAD_REPLY_LIMIT=100 \
  bash "$DROPPED_SCRIPT" > "$TMPDIR_LOCAL/audit.txt" 2>&1 || {
    err "dropped-thread-followup.sh exited non-zero; skipping this tick"
    exit 0
  }

# Parse DRY_RUN nudge lines
mapfile -t REDRIVE_LINES < <(grep -E "DRY_RUN: would nudge" "$TMPDIR_LOCAL/audit.txt" || true)
log "  actionable threads: ${#REDRIVE_LINES[@]}"

if [[ ${#REDRIVE_LINES[@]} -eq 0 ]]; then
  log "  nothing to auto-arm; exiting"
  exit 0
fi

# State load
declare -A REDISPATCHED
if [[ -f "$STATE_FILE" ]]; then
  while IFS=: read -r key count last_ts; do
    REDISPATCHED["$key"]="${count}:${last_ts}"
  done < "$STATE_FILE"
fi

# Slack post helper. Mirrors dropped-thread-followup's curl pattern.
slack_post() {
  local channel="$1" thread_ts="$2" text="$3"
  if [[ "$DRY_RUN" == "1" || -z "$TOKEN" ]]; then
    log "    DRY_RUN: would post to $channel thread=$thread_ts (token=${TOKEN:+present}${TOKEN:-MISSING})"
    return 0
  fi
  local payload
  payload=$(printf '{"channel":"%s","thread_ts":"%s","text":"%s"}' \
    "$channel" "$thread_ts" "$(printf '%s' "$text" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read())[1:-1])')")
  local resp
  resp=$(curl -sS -X POST https://slack.com/api/chat.postMessage \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json; charset=utf-8" \
    -d "$payload" 2>&1) || { err "    curl failed: $resp"; return 1; }
  # Verify the post landed in the right thread (the dropped-thread-followup
  # recipe: response MUST echo back the requested thread_ts).
  if ! echo "$resp" | grep -q "\"ok\":true"; then
    err "    chat.postMessage failed: $resp"
    return 1
  fi
  if ! echo "$resp" | grep -q "\"thread_ts\":\"$thread_ts\""; then
    err "    chat.postMessage ok but thread_ts mismatch: $resp"
    return 1
  fi
  log "    posted to $channel thread=$thread_ts"
}

# Walk each actionable thread; auto-dispatch only the unaddressed ones.
DISPATCHED=0
SKIPPED=0
for line in "${REDRIVE_LINES[@]}"; do
  chan=$(echo "$line" | grep -oE "nudge [A-Z0-9]+ [0-9.]+" | awk '{print $2}' || echo "")
  ts_id=$(echo "$line" | grep -oE "nudge [A-Z0-9]+ [0-9.]+" | awk '{print $3}' || echo "")
  [[ -z "$chan" || -z "$ts_id" ]] && { SKIPPED=$((SKIPPED+1)); continue; }

  state_key="${chan}_${ts_id}"
  prior="${REDISPATCHED[$state_key]:-0:0}"
  prior_count="${prior%%:*}"
  prior_ts="${prior#*:}"

  if [[ ${prior_count:-0} -ge $MAX_REDISPATCHES ]]; then
    log "  SKIP (already re-dispatched $prior_count times): ${state_key}"
    SKIPPED=$((SKIPPED+1))
    continue
  fi

  # Pull goal text (truncated) — used in the Slack message but NOT logged.
  ask=$(echo "$line" | grep -oE 'Original request: "[^"]{0,200}' | sed 's/Original request: "//' || echo "")
  thread_url="https://jleechanai.slack.com/archives/${chan}/p${ts_id//./}"

  message=$(cat <<EOF
:arrows_counterclockwise: *finish-the-job auto-arm* — goal unaddressed for ${AUTOARM_GRACE_MIN}m, re-dispatching through the finish-the-job pipeline.

*Goal*: ${ask:0:200}

*Contract*: load \`finish-the-job\` skill, classify goal, drive to a provable end-state (green PR, finished change, dry-run to local machine state). No mid-stream questions. No follow-up "want me to X?" — make the call per the user's rule (correct-but-misinterpreted is fine; stopping halfway is not).

*Thread*: <${thread_url}|${ts_id}>
EOF
)

  log "  AUTO-DISPATCHING (count=$((prior_count + 1))): ${state_key}"
  slack_post "$chan" "$ts_id" "$message" && {
    # Only mark state if Slack post confirmed; otherwise retry next tick.
    REDISPATCHED["$state_key"]="$((prior_count + 1)):$(date +%s)"
    DISPATCHED=$((DISPATCHED+1))
  } || err "    dispatch failed for $state_key — will retry"
done

# Write state atomically (only if we actually changed something).
if [[ $DISPATCHED -gt 0 ]]; then
  : > "$STATE_FILE.tmp"
  for k in "${!REDISPATCHED[@]}"; do
    echo "${k}:${REDISPATCHED[$k]}" >> "$STATE_FILE.tmp"
  done
  mv "$STATE_FILE.tmp" "$STATE_FILE"
fi

log "finish-the-job-autoarm done (dispatched=$DISPATCHED skipped=$SKIPPED)"
