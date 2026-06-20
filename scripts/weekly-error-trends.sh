#!/usr/bin/env bash
#
# Weekly Error Trends -- 9:00 AM PT Mondays
# Analyzes the last 7 days of Hermes logs, summarizes recurring errors,
# identifies root causes, suggests fastest fixes, and provides a prevention checklist.
#
# Posts to Slack via the shared slack_thread_lib (PR #615) so it shares
# the same thread-anchor + dedupe + channel-resolver as the other 3 fixed
# cron scripts. This is the launchd-installed copy (see
# scripts/install-hermes-scheduled-jobs.sh:144-146); the launchd template
# at launchd/ai.smartclaw.schedule.weekly-error-trends.plist.template executes
# @HOME@/.smartclaw/scripts/weekly-error-trends.sh, so leaving the
# curl+hardcoded C0AJQ5M0A0Y path here would re-introduce the channel-bleed
# bug the top-level migration closed. (PR #616 chatgpt-codex-connector P1
# follow-up.)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"
# shellcheck source=lib/slack_thread_lib.sh
IS_SOURCED=1 source "$LIB_DIR/slack_thread_lib.sh"

ROOT="${HERMES_HOME:-$HOME/.smartclaw}"
LOG_DIR="$ROOT/logs"
OUT_DIR="$ROOT/logs/weekly-error-trends"
REPORT="$OUT_DIR/report-$(date +%Y%m%d).txt"
TMP_ERRORS="$OUT_DIR/errors-7d.tmp"

mkdir -p "$OUT_DIR"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# -- 1. Collect errors from available log files --------------------------------

log "Collecting errors from available log files..."
: > "$TMP_ERRORS"

for logfile in "$LOG_DIR/gateway.log" "$LOG_DIR/gateway.err.log" \
               "$LOG_DIR/health-check.log" "$LOG_DIR/monitor-agent.log"; do
  if [[ -f "$logfile" ]]; then
    echo "" >> "$TMP_ERRORS"
    echo "# Source: $(basename "$logfile")" >> "$TMP_ERRORS"
    grep -E '(ERROR|FATAL|CRITICAL|failed|exception|WARN)' "$logfile" 2>/dev/null >> "$TMP_ERRORS" || true
  fi
done

ERROR_COUNT=$(grep -vE '^(#|$)' "$TMP_ERRORS" 2>/dev/null | wc -l | tr -d ' ')
log "Collected $ERROR_COUNT error/warning lines"

# -- 2. Categorize recurring patterns -------------------------------------------

# Pattern-based categorization via grep counts
categorize() { grep -cE "$1" "$TMP_ERRORS" 2>/dev/null || echo 0; }

CAT_GATEWAY=$(categorize 'gateway')
CAT_LAUNCHD=$(categorize 'launchd|plist|bootstrap')
CAT_NETWORK=$(categorize 'connect|timeout|network|dns|refused')
CAT_AUTH=$(categorize 'auth|token|credential|permission')
CAT_MEMORY=$(categorize 'memory|heap|leak|OOM')
CAT_SCRIPT=$(categorize 'script|\.sh|runner')
CAT_CRONSCHED=$(categorize 'cron|schedule|calendar')

# -- 3. Root cause heuristics ----------------------------------------------

ROOT_CAUSES=""
if [[ "$CAT_LAUNCHD" -gt 3 ]]; then
  ROOT_CAUSES="${ROOT_CAUSES}
- launchd reload failures -- usually stale plist after config change; fix: launchctl bootout && launchctl bootstrap"
fi
if [[ "$CAT_NETWORK" -gt 3 ]]; then
  ROOT_CAUSES="${ROOT_CAUSES}
- Network/connectivity errors -- external service timeout or DNS failure; fix: check service status"
fi
if [[ "$CAT_AUTH" -gt 2 ]]; then
  ROOT_CAUSES="${ROOT_CAUSES}
- Auth/token errors -- token expired or scope missing; fix: hermes agents auth <agent-id>"
fi
if [[ "$CAT_MEMORY" -gt 2 ]]; then
  ROOT_CAUSES="${ROOT_CAUSES}
- Memory issues -- agent session leak or unbounded log growth; fix: kill stale tmux sessions, rotate logs"
fi
if [[ "$CAT_SCRIPT" -gt 3 ]]; then
  ROOT_CAUSES="${ROOT_CAUSES}
- Script failures -- missing dependency or bad PATH in launchd environment; fix: verify PATH in plist"
fi

# -- 4. Fastest fixes ----------------------------------------------------

FASTEST_FIXES=""
[[ "$CAT_LAUNCHD" -gt 0 ]] && FASTEST_FIXES="${FASTEST_FIXES}
1. launchd failures: launchctl bootout gui/$(id -u)/<label> && launchctl bootstrap gui/$(id -u) <plist>"
[[ "$CAT_NETWORK" -gt 0 ]] && FASTEST_FIXES="${FASTEST_FIXES}
2. Services unreachable: hermes gateway probe && hermes channels status"
[[ "$CAT_AUTH" -gt 0 ]] && FASTEST_FIXES="${FASTEST_FIXES}
3. Auth errors: re-authenticate with hermes agents auth <agent-id>"
[[ "$CAT_SCRIPT" -gt 0 ]] && FASTEST_FIXES="${FASTEST_FIXES}
4. Script errors: run the script manually with the same PATH to reproduce"
[[ "$CAT_MEMORY" -gt 0 ]] && FASTEST_FIXES="${FASTEST_FIXES}
5. Memory/log errors: find large log files with: find ~/.smartclaw/logs -size +100M"

# -- 5. Prevention checklist ----------------------------------------------

PREVENTION_CHECKLIST="
- Run hermes doctor weekly -- catches config drift early
- Verify launchd PATH before installing new plists
- Keep log directory under 5 GB; prune monthly: find ~/.smartclaw/logs -name '*.log' -mtime +30 -delete
- Test scripts in a launchd-like environment (stripped PATH) before deploying
- After any plist change: verify with launchctl print gui/$(id -u)/<label>
"

# -- 6. Write report ----------------------------------------------------

{
  echo "Weekly Error Trends -- $(date '+%Y-%m-%d')"
  echo "=========================================="
  echo "Period: errors in current log files (no date filter applied)"
  echo "Total error/warning lines: $ERROR_COUNT"
  echo ""
  echo "## Category Breakdown"
  echo "| Category | Count |"
  echo "|---------|-------|"
  echo "| Gateway errors | $CAT_GATEWAY |"
  echo "| launchd/plist errors | $CAT_LAUNCHD |"
  echo "| Network/connectivity | $CAT_NETWORK |"
  echo "| Auth/token errors | $CAT_AUTH |"
  echo "| Memory/resource issues | $CAT_MEMORY |"
  echo "| Script failures | $CAT_SCRIPT |"
  echo "| Cron/schedule issues | $CAT_CRONSCHED |"
  echo ""
  echo "## Top Error Patterns"
  echo '```'
  grep -vE '^(#|$)' "$TMP_ERRORS" 2>/dev/null | head -30
  echo '```'
  echo ""
  echo "## Likely Root Causes${ROOT_CAUSES}"
  echo ""
  echo "## Fastest Fixes${FASTEST_FIXES}"
  echo ""
  echo "## Prevention Checklist"
  echo "$PREVENTION_CHECKLIST"
} > "$REPORT"

log "Report written: $REPORT"

# -- 7. Slack notification via consolidated slack_thread_lib (PR #615) ----
# Channel resolution: HERMES_OPS_SLACK_CHANNEL env → SLACK_CHANNEL → empty.
# Empty default = "caller didn't set the plist env"; do not silently bleed.
# slack_post handles thread-anchor + dedupe.

TOP_CAT="None"
TOP_COUNT=0
for cat_name in "GATEWAY" "LAUNCHD" "NETWORK" "AUTH" "MEMORY" "SCRIPT" "CRONSCHED"; do
  count_var="CAT_${cat_name}"
  count="${!count_var}"
  if [[ "${count:-0}" -gt "$TOP_COUNT" ]]; then
    TOP_COUNT="${count:-0}"
    TOP_CAT="$cat_name"
  fi
done

SLACK_MSG="Weekly Error Trends: $ERROR_COUNT errors/warnings in available logs.
Top category: ${TOP_CAT} (${TOP_COUNT} occurrences).

${ROOT_CAUSES:+Top root causes:${ROOT_CAUSES}}

Full report: $REPORT"

slack_post "weekly-error-trends" "$SLACK_MSG" --channel "${SLACK_CHANNEL:-}" 2>/dev/null || \
  log "slack_post failed (see slack_thread_lib) — summary not delivered"
log "Done. Report: $REPORT"
exit 0
