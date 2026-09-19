#!/usr/bin/env bash
# gateway-heartbeat.sh — Supplementary heartbeat confirming gateway health.
# Posts a 30-min Slack ping to the home channel. Alert cooldown: only DOWN
# (exit code 2) escalates to :rotating_light:; HEALTHY (0) and DEGRADED (1)
# are status pings without the siren emoji. See the comment block in
# scripts/hermes-health.sh for the full postmortem (2026-07-02 incident):
# the gateway is Slack Socket Mode and does not bind a TCP port, so
# HERMES_HEALTH_PORT must be empty here (was hardcoded to 8643, which the
# gateway never used → permanent false DOWN alert every 30 min).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# IMPORTANT: leave HERMES_HEALTH_PORT empty. The gateway uses Slack Socket Mode
# and binds no TCP port. Setting it here would re-introduce the "port:UNBOUND"
# false positive. hermes-health.sh will skip the port check when the var is
# empty and use the log-heartbeat surface instead.
unset HERMES_HEALTH_PORT

STATUS=0
"$SCRIPT_DIR/hermes-health.sh" --quiet || STATUS=$?

# Map hermes-health.sh exit codes (0=HEALTHY, 1=DEGRADED, 2=DOWN) to alert tone.
# Only DOWN (rc=2) is alert-worthy — DEGRADED is normal background noise
# (loadavg:ELEVATED, etc.) and should not page.
case "$STATUS" in
  0) MSG=":large_green_circle: Hermes gateway healthy ($(date +%H:%M))" ;;
  1) MSG=":large_yellow_circle: Hermes gateway DEGRADED ($(date +%H:%M)) — run: hermes-health.sh for details" ;;
  2) MSG=":rotating_light: Hermes gateway DOWN — run: hermes-health.sh for details" ;;
  *) MSG=":grey_question: Hermes health check returned unexpected rc=$STATUS" ;;
esac

# Post to Slack home channel using SLACK_BOT_TOKEN or SLACK_MCP_XOXB_TOKEN
TOKEN="${SLACK_BOT_TOKEN:-${SLACK_MCP_XOXB_TOKEN:-}}"
if [[ -n "$TOKEN" ]]; then
  curl -s -X POST https://slack.com/api/chat.postMessage \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"channel\":\"C0AJQ5M0A0Y\",\"text\":\"$MSG\"}" > /dev/null
else
  echo "Error: SLACK_BOT_TOKEN and SLACK_MCP_XOXB_TOKEN are both empty. Cannot post heartbeat." >&2
  exit 1
fi
