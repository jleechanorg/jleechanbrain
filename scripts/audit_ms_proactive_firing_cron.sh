#!/usr/bin/env bash
# Wrapper for ai.smartclaw.schedule.ms-proactive-firing-audit launchd job.
# Runs `audit_ms_proactive_firing.sh` and posts a Slack alert ONLY when
# the firing rate is below threshold. Quiet on success.
#
# Wiring added 2026-07-02 per /advice Reviewer A flag: the audit script
# existed (commit 7b5271c8e5) but was never auto-invoked, so any future
# regression would be silent.
#
# Source: 2026-07-02 Slack C0AJ3SD5C79 ts 1783036536.864119

set -euo pipefail

HERMES_HOME="${HERMES_HOME:-$HOME/.smartclaw}"
AUDIT_SCRIPT="$HERMES_HOME/scripts/audit_ms_proactive_firing.sh"
LOG="$HERMES_HOME/logs/ms-proactive-firing-audit.log"
ALERT_CHANNEL="${MS_AUDIT_ALERT_CHANNEL:-C0AJ3SD5C79}"  # default to #jleechanbrain
SLACK_TOKEN="${SLACK_BOT_TOKEN:-}"

mkdir -p "$(dirname "$LOG")"
exec >> "$LOG" 2>&1
echo "=== $(date -Iseconds) ms-proactive-firing-audit ==="

if [[ ! -x "$AUDIT_SCRIPT" ]]; then
  echo "ERROR: $AUDIT_SCRIPT missing or not executable"
  exit 2
fi

# Run the audit. Capture stdout. Exit code 0 = within threshold, 1 = below.
output=$("$AUDIT_SCRIPT" 2>&1) || rc=$?
rc=${rc:-0}
echo "$output"
echo "audit exit code: $rc"

if [[ "$rc" -eq 0 ]]; then
  echo "OK: firing rate within threshold, no Slack alert"
  exit 0
fi

# Below threshold — post a single alert.
if [[ -z "$SLACK_TOKEN" ]]; then
  echo "WARN: SLACK_BOT_TOKEN empty, skipping Slack alert"
  exit "$rc"
fi

# Build the alert text
alert_text=$(printf ':rotating_light: *ms-on-new-task COMMIT under-firing*\n\n```\n%s\n```\n\nDetector: `~/.smartclaw/scripts/audit_ms_proactive_firing.sh`\nNext action: investigate why first-tool-call is not session_search/skill_view. Common causes listed in audit output.' "$output")

payload=$(jq -nc \
  --arg channel "$ALERT_CHANNEL" \
  --arg text "$alert_text" \
  '{channel: $channel, text: $text, unfurl_links: false, unfurl_media: false}')

http_code=$(curl -sS -o /tmp/ms_audit_alert.json -w '%{http_code}' \
  -X POST 'https://slack.com/api/chat.postMessage' \
  -H "Authorization: Bearer $SLACK_TOKEN" \
  -H 'Content-Type: application/json; charset=utf-8' \
  --data "$payload" || echo "curl_failed")
echo "Slack post HTTP $http_code, body: $(cat /tmp/ms_audit_alert.json 2>/dev/null | head -c 200)"

exit "$rc"