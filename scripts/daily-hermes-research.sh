#!/usr/bin/env bash
#
# Daily Hermes Research — 6:00 PM PT daily
# Sends a tips/research prompt to the hermes agent session.
# Launchd equivalent of gateway cron job "tips:daily-hermes-research"
#
# Bead: orch-sq2 (launchd-migration)

set -euo pipefail

ROOT="${HERMES_ROOT:-$HOME/.smartclaw}"
THINKING="${HERMES_SCHEDULED_THINKING:-low}"
TIMEOUT="${HERMES_SCHEDULED_TIMEOUT_SECONDS:-1200}"

mkdir -p "$ROOT/logs/scheduled-jobs"

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*"; }

MESSAGE="Before suggesting tips, verify current state with local checks (hermes gateway status, hermes cron list --json, hermes config get diagnostics.flags, hermes update status). Only include tips that are NOT already implemented, or explicitly label as 'Validation: already configured'. At least 2 tips must cite concrete evidence from local command output (quote the relevant output line). Prioritize jleechan's active setup (Slack, cron automations, diagnostics, docs/context, AO workflows). Provide exactly 3-5 tips with: What changed/why now, concrete command, and source link (docs.smartclaw.ai or official GitHub/release notes). No generic beginner advice."

if ! command -v hermes >/dev/null 2>&1; then
  log "fail: hermes not in PATH"
  exit 1
fi

log "start daily-research (thinking=$THINKING timeout=${TIMEOUT}s)"
set +e
hermes agent --thinking "$THINKING" --timeout "$TIMEOUT" --message "$MESSAGE" --json
rc=$?
set -e
log "finish rc=$rc"
exit "$rc"
