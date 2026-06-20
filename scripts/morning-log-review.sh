#!/usr/bin/env bash
#
# Morning Log Review — 8:00 AM PT Mon–Fri
# Parses last night's gateway + agent logs, extracts errors, and posts
# an actionable fixes summary to Slack via the shared slack_thread_lib
# (PR #615) so it shares the same thread-anchor + dedupe + channel-resolver
# as the other 3 fixed cron scripts.
#
# Do NOT post as reminder relay text — post real findings only.
# If no errors found, post a brief "all clear" confirmation.
#
# NOTE: this is the launchd-installed copy (see
# scripts/install-hermes-scheduled-jobs.sh:144-145). The top-level
# morning-log-review.sh is identical in behaviour; the launchd templates
# at launchd/ai.smartclaw.schedule.morning-log-review.plist.template execute
# @HOME@/.smartclaw/scripts/morning-log-review.sh, so this file must also
# use slack_post — leaving the curl+hardcoded C0AJQ5M0A0Y path here
# would re-introduce the channel-bleed bug the top-level migration
# closed. (PR #616 chatgpt-codex-connector P1 follow-up.)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"
# shellcheck source=lib/slack_thread_lib.sh
IS_SOURCED=1 source "$LIB_DIR/slack_thread_lib.sh"

ROOT="${HERMES_HOME:-$HOME/.smartclaw}"
LOG_DIR="$ROOT/logs"
OUT_DIR="$ROOT/logs/morning-log-review"
REPORT="$OUT_DIR/report-$(date +%Y%m%d).txt"

mkdir -p "$OUT_DIR"

# ── helpers ──────────────────────────────────────────────────────────────────

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*"; }

# ── collect log files ─────────────────────────────────────────────────────────

GW_LOG="$LOG_DIR/gateway.log"
GW_ERR="$LOG_DIR/gateway.err.log"
HC_LOG="$LOG_DIR/health-check.log"
AGENT_LOG="$LOG_DIR/monitor-agent.log"

collect_logs() {
  local out="$1"
  : > "$out"

  for logfile in "$GW_LOG" "$GW_ERR" "$HC_LOG" "$AGENT_LOG"; do
    if [[ -f "$logfile" ]]; then
      echo "===== $(basename "$logfile") =====" >> "$out"
      # Extract all error/warning lines from the log file
      grep -E '(ERROR|FATAL|WARN|CRITICAL|failed|exception)' "$logfile" 2>/dev/null >> "$out" || true
      echo "" >> "$out"
    fi
  done
}

# ── build report ──────────────────────────────────────────────────────────────

collect_logs "$OUT_DIR/raw-$(date +%Y%m%d).log"

ERROR_LINES=$(grep -cE '(ERROR|FATAL|CRITICAL)' "$OUT_DIR/raw-$(date +%Y%m%d).log" 2>/dev/null || echo 0)
# Warn bucket: exclude error-level lines to avoid double-counting
WARN_LINES=$(grep -vE '(ERROR|FATAL|CRITICAL)' "$OUT_DIR/raw-$(date +%Y%m%d).log" 2>/dev/null | grep -cE '(WARN|failed|exception)' || echo 0)
TOTAL_ERRORS=$((ERROR_LINES + WARN_LINES))

{
  echo "Morning Log Review — $(date '+%Y-%m-%d')"
  echo "========================================="
  echo "Gateway log: $GW_LOG"
  echo "Errors found: $ERROR_LINES | Warnings: $WARN_LINES"
  echo ""
  echo "=== Errors ==="
  grep -E '(ERROR|FATAL|CRITICAL)' "$OUT_DIR/raw-$(date +%Y%m%d).log" 2>/dev/null | head -30 || echo "(none)"
  echo ""
  echo "=== Warnings / Failed Operations ==="
  grep -E '(WARN|failed|exception)' "$OUT_DIR/raw-$(date +%Y%m%d).log" 2>/dev/null | grep -vE '(ERROR|FATAL|CRITICAL)' | head -30 || echo "(none)"
  echo ""
  echo "=== Actionable Items ==="
  # Heuristic: errors that mention specific files or modules
  grep -E '(ERROR|FATAL|CRITICAL)' "$OUT_DIR/raw-$(date +%Y%m%d).log" 2>/dev/null \
    | grep -oE '(tools?|gateway|agent|launchd|plutil|script|orchestration|health)' \
    | sort | uniq -c | sort -rn | head -10 \
    | awk '{print "- ["$1" occurrences] "$2" — review related module"}' || echo "(none)"
} > "$REPORT"

# ── Slack notification via consolidated slack_thread_lib (PR #615) ────────────
# Channel resolution: HERMES_OPS_SLACK_CHANNEL env → SLACK_CHANNEL → empty
# (skip). Empty default = "caller didn't set the plist env"; do not silently
# bleed into a wrong channel. slack_post handles thread-anchor + dedupe.

if [[ "$TOTAL_ERRORS" -eq 0 ]]; then
  SUMMARY="Morning Log Review ✅ — No errors in last night's gateway/agent logs."
  slack_post "morning-log-review" "$SUMMARY" --channel "${SLACK_CHANNEL:-}" 2>/dev/null || \
    log "slack_post failed (see slack_thread_lib) — summary not delivered"
  log "All clear. Summary: $SUMMARY"
else
  # Post just the top 5 actionable items to Slack (don't dump full log)
  TOP_ITEMS=$(grep -E '(ERROR|FATAL|CRITICAL)' "$OUT_DIR/raw-$(date +%Y%m%d).log" 2>/dev/null | head -5)
  SLACK_MSG="Morning Log Review ⚠️ — $ERROR_LINES error(s), $WARN_LINES warning(s) in last night's logs.

*Top errors:*
$(echo "$TOP_ITEMS" | sed 's/.*ERROR.*/**ERROR**/; s/.*FATAL.*/**FATAL**/; s/.*CRITICAL.*/**CRITICAL**/')

Full report: $REPORT"

  slack_post "morning-log-review" "$SLACK_MSG" --channel "${SLACK_CHANNEL:-}" 2>/dev/null || \
    log "slack_post failed (see slack_thread_lib) — summary not delivered"
  log "Errors found. Report: $REPORT"
fi

log "Done. Total issues: $TOTAL_ERRORS"
exit 0
