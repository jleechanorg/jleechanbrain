#!/usr/bin/env bash
# hermes-watchdog.sh — Periodic health watchdog for Hermes gateways
# Run by launchd: ai.smartclaw-watchdog (every 5 min)
# Alerts Slack if prod gateway is down for >= FAIL_STREAK_REQUIRED
# consecutive checks (default 4 = ~20 min). Resets streak on recovery so
# a transient blip never spams #all-jleechan-ai. Staging-down is logged
# only — staging can be intentionally stopped.
set -uo pipefail

HERMES_HOME="${HERMES_HOME:-${HOME}/.smartclaw}"
HERMES_PROD_HOME="${HERMES_PROD_HOME:-${HOME}/.smartclaw}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"
# Source shared Slack post helper (thread anchor + dedupe + channel resolution).
# shellcheck source=../lib/slack_thread_lib.sh
IS_SOURCED=1 source "$LIB_DIR/slack_thread_lib.sh"

# 20-min debounce: 4 consecutive checks at 5 min each. Override via env if a
# noisier/faster alert is desired (e.g. 2 for a 10-min window).
FAIL_STREAK_REQUIRED="${HERMES_WATCHDOG_FAIL_STREAK:-4}"
WATCHDOG_STATE_DIR="${HERMES_WATCHDOG_STATE_DIR:-/tmp/hermes/watchdog-state}"
mkdir -p "$WATCHDOG_STATE_DIR"

# Streak counter helpers — atomic write, no flock needed (single-process).
streak_get() {
  local f="$WATCHDOG_STATE_DIR/$1.streak"
  [[ -f "$f" ]] || { echo 0; return; }
  cat "$f" 2>/dev/null || echo 0
}
streak_set() {
  local f="$WATCHDOG_STATE_DIR/$1.streak" val="$2"
  printf '%s\n' "$val" > "$f"
}
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

# Check prod gateway + update streak counter
PROD_STREAK=$(streak_get prod)
if check_gateway "prod" 8643; then
  log "prod gateway: healthy (port 8643)"
  if [ "$PROD_STREAK" -gt 0 ]; then
    log "prod recovered after $PROD_STREAK consecutive failures — resetting streak"
    # Clear last-alerted marker so the NEXT outage fires fresh, even if the
    # streak had crossed the threshold during the just-recovered window.
    rm -f "$WATCHDOG_STATE_DIR/prod.last_alerted_streak" 2>/dev/null || true
  fi
  streak_set prod 0
  PROD_HEALTHY=true
else
  PROD_STREAK=$((PROD_STREAK + 1))
  streak_set prod "$PROD_STREAK"
  PROD_HEALTHY=false
  log "prod gateway: DOWN (port 8643) — streak $PROD_STREAK/$FAIL_STREAK_REQUIRED"
fi

# Check staging gateway (logged only — staging can be intentionally stopped).
STAGING_STREAK=$(streak_get staging)
if check_gateway "staging" 8644; then
  log "staging gateway: healthy (port 8644)"
  streak_set staging 0
else
  STAGING_STREAK=$((STAGING_STREAK + 1))
  streak_set staging "$STAGING_STREAK"
  log "staging gateway: DOWN (port 8644) — streak $STAGING_STREAK (logged only, no alert)"
fi

# Alert only when prod has been down for >= FAIL_STREAK_REQUIRED consecutive
# checks (default 4 = ~20 min). One failure = no alert (transient blip);
# sustained outage = single alert, then quiet until recovery.
if [ "$PROD_HEALTHY" = false ] && [ "$PROD_STREAK" -ge "$FAIL_STREAK_REQUIRED" ]; then
  # Only alert on the exact threshold crossing to avoid repeat spam during
  # an extended outage (slack_thread_lib dedupe would catch most repeats,
  # but be explicit). Once it recovers the streak resets and a new outage
  # gets a fresh alert.
  PREV_STREAK_FILE="$WATCHDOG_STATE_DIR/prod.last_alerted_streak"
  PREV_STREAK=$( [[ -f "$PREV_STREAK_FILE" ]] && cat "$PREV_STREAK_FILE" 2>/dev/null || echo 0 )
  if [ "$PROD_STREAK" -eq "$FAIL_STREAK_REQUIRED" ] || [ "$PREV_STREAK" -lt "$FAIL_STREAK_REQUIRED" ]; then
    log "ALERT: prod gateway DOWN sustained for $PROD_STREAK checks — alerting $ALERT_CHANNEL"
    slack_post "hermes-watchdog" ":rotating_light: Hermes prod gateway DOWN (port 8643) — sustained $PROD_STREAK checks (~$(($PROD_STREAK * 5)) min) since $(date '+%Y-%m-%d %H:%M:%S %Z')" \
      --channel "$ALERT_CHANNEL" --force >/dev/null 2>&1 || \
      log "slack_post returned non-zero (channel may be unset)"
    printf '%s\n' "$PROD_STREAK" > "$PREV_STREAK_FILE"
  else
    log "prod still down (streak $PROD_STREAK) — suppressing repeat alert (last alerted at streak $PREV_STREAK)"
  fi
fi

log "watchdog check complete"
