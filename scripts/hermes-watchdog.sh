#!/usr/bin/env bash
# hermes-watchdog.sh — External liveness watchdog for ai.smartclaw.prod
# Called by ai.smartclaw-watchdog launchd job every 5 minutes.
# Checks PID-vs-port match, attempts restart if down, posts Slack alert if unrecoverable.
# Must be externally invoked (NOT inside gateway cron) — gateway-down is the failure to detect.

set -euo pipefail

LABEL="ai.smartclaw.prod"
PORT=8642
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
ALERT_CHANNEL="${HERMES_WATCHDOG_ALERT_CHANNEL:-${SLACK_CHANNEL_ID}}"  # #ai-slack-test fallback
LOG_FILE="${HERMES_WATCHDOG_LOG:-/tmp/hermes-watchdog.log}"
MAX_LOG_LINES=500
U="$(id -u)"

log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

trim_log() {
  if [[ -f "$LOG_FILE" ]]; then
    local lines; lines=$(wc -l < "$LOG_FILE")
    if (( lines > MAX_LOG_LINES )); then
      tail -n $MAX_LOG_LINES "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
    fi
  fi
}

slack_alert() {
  local msg="$1"
  local token="${SLACK_BOT_TOKEN:-${MCP_MAIL_BOT_TOKEN:-${OPENCLAW_SLACK_BOT_TOKEN:-}}}"
  [[ -z "$token" ]] && { log "WARN: no Slack token for alert"; return 0; }
  curl --silent --show-error --connect-timeout 10 --max-time 20 \
    -X POST "https://slack.com/api/chat.postMessage" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg ch "$ALERT_CHANNEL" --arg txt "$msg" '{channel:$ch,text:$txt}')" \
    > /dev/null 2>&1 || log "WARN: Slack alert post failed"
}

check_gateway() {
  local launchd_pid port_pid
  launchd_pid=$(launchctl list 2>/dev/null | awk -v lbl="$LABEL" '$3==lbl{print $1}' || true)
  # LISTEN sockets only — avoid stale ESTABLISHED client connections producing false PIDs
  port_pid=$(lsof -t -sTCP:LISTEN -i ":${PORT}" 2>/dev/null | head -1 || true)

  if [[ -z "$launchd_pid" || "$launchd_pid" == "-" ]]; then
    echo "not_in_launchd"
    return
  fi
  if [[ -z "$port_pid" ]]; then
    echo "pid_exists_port_unbound"
    return
  fi
  if [[ "$launchd_pid" != "$port_pid" ]]; then
    echo "pid_mismatch:launchd=${launchd_pid}:port=${port_pid}"
    return
  fi
  # HTTP /health check — strict 200 required. Per CLAUDE.md, gateway health
  # requires BOTH PID match AND HTTP /health 200 (liveness != functional).
  local http_code
  http_code=$(curl --connect-timeout 3 --max-time 6 -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/health" 2>/dev/null || echo "000")
  if [[ "$http_code" != "200" ]]; then
    echo "unhealthy_http:${http_code}"
    return
  fi
  echo "ok:${launchd_pid}"
}

attempt_restart() {
  log "Attempting restart of $LABEL..."
  launchctl bootout "gui/${U}/${LABEL}" 2>/dev/null || true
  sleep 3
  # NOTE: Do NOT auto-restore ${PLIST}.disabled — deploy.sh Stage 0 may have
  # disabled the plist intentionally (conflicting label, wrong HERMES_HOME, etc.).
  # Blindly renaming .disabled back to .plist fights deploy and re-creates the
  # original conflict. Require manual operator intervention instead.
  if [[ ! -f "$PLIST" ]]; then
    if [[ -f "${PLIST}.disabled" ]]; then
      log "WARN: ${PLIST} missing but ${PLIST}.disabled exists — deploy.sh Stage 0 likely disabled it intentionally; SKIPPING auto-restore. Manual intervention required."
    else
      log "ERROR: plist not found at $PLIST — cannot restart"
    fi
    return 1
  fi
  launchctl bootstrap "gui/${U}" "$PLIST" 2>/dev/null || true
  sleep 12
}

trim_log

status=$(check_gateway)
log "Status: $status"

case "$status" in
  ok:*)
    # Healthy — nothing to do
    exit 0
    ;;
  not_in_launchd|pid_exists_port_unbound|pid_mismatch:*|unhealthy_http:*)
    log "Gateway down or degraded: $status"

    attempt_restart || true  # set -e: must not exit here; status2 re-check sends Slack alert

    # Re-check after restart
    status2=$(check_gateway)
    log "Post-restart status: $status2"

    if [[ "$status2" == ok:* ]]; then
      log "Restart succeeded: $status2"
      slack_alert ":white_check_mark: *Hermes prod auto-recovered* — was: \`${status}\`, now: running (watchdog restart)"
    else
      log "Restart failed: $status2 — escalating"
      slack_alert ":rotating_light: *Hermes prod DOWN* — watchdog restart failed. Status: \`${status2}\`. Manual intervention required. Check: \`launchctl list | grep hermes\` and \`lsof -i :${PORT}\`"
    fi
    ;;
  *)
    log "Unknown status: $status — skipping"
    ;;
esac
