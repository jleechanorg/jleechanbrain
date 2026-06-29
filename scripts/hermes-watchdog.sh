#!/usr/bin/env bash
# hermes-watchdog.sh — Periodic health watchdog for Hermes gateways
# Run by launchd: ai.smartclaw-watchdog (every 5 min)
# Alerts Slack if prod/staging gateways are down.
set -uo pipefail

HERMES_HOME="${HERMES_HOME:-${HOME}/.smartclaw}"
HERMES_PROD_HOME="${HERMES_PROD_HOME:-${HOME}/.smartclaw_prod}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"
# Source shared Slack post helper (thread anchor + dedupe + channel resolution).
# shellcheck source=../lib/slack_thread_lib.sh
IS_SOURCED=1 source "$LIB_DIR/slack_thread_lib.sh"
# PR #681 routes ops alerts to HERMES_OPS_SLACK_CHANNEL. We no longer default
# to C0AJ3SD5C79 (design channel) — empty default falls through to the plist
# env or HERMES_OPS_SLACK_CHANNEL, and slack_post fails soft if neither sets.
HERMES_OPS_SLACK_CHANNEL="${HERMES_OPS_SLACK_CHANNEL:-}"
if [ "${HERMES_WATCHDOG_ALERT_CHANNEL:-}" = "${SLACK_CHANNEL_ID}" ]; then
  HERMES_WATCHDOG_ALERT_CHANNEL=""
fi
ALERT_CHANNEL="${HERMES_WATCHDOG_ALERT_CHANNEL:-$HERMES_OPS_SLACK_CHANNEL}"
LOG_PREFIX="[hermes-watchdog]"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $LOG_PREFIX $*"; }

# Check if a gateway process is alive and healthy on given port
check_gateway() {
  local label="$1"; local port="$2"
  if curl -sf --max-time 3 "http://localhost:$port/health" 2>/dev/null | grep -q '"status"'; then
    return 0
  fi
  return 1
}

# Check prod gateway
PROD_HEALTHY=false
if check_gateway "prod" 8643; then
  log "prod gateway: healthy (port 8643)"
  PROD_HEALTHY=true
else
  log "prod gateway: DOWN (port 8643)"
fi

# Check staging gateway
STAGING_HEALTHY=false
if check_gateway "staging" 8644; then
  log "staging gateway: healthy (port 8644)"
  STAGING_HEALTHY=true
else
  log "staging gateway: DOWN (port 8644)"
fi

# Alert only if prod is down (staging can be intentionally stopped).
# The watchdog's previous hardcoded channel default C0AJ3SD5C79 was the
# design channel — the consolidated slack_post helper with HERMES_OPS_SLACK_CHANNEL
# resolution routes ops alerts to the right place (jleechan-fu5b).
if [ "$PROD_HEALTHY" = false ]; then
  log "ALERT: prod gateway is DOWN — alerting $ALERT_CHANNEL"
  slack_post "hermes-watchdog" ":rotating_light: Hermes prod gateway DOWN (port 8643) — last check $(date '+%Y-%m-%d %H:%M:%S %Z')" \
    --channel "$ALERT_CHANNEL" >/dev/null 2>&1 || \
    log "slack_post returned non-zero (channel may be unset)"
fi

log "watchdog check complete"
