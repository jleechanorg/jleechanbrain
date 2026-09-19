#!/bin/bash
# cmux-surface-report-4h-wrapper.sh
# launchd entry point: sources user login env (SLACK_BOT_TOKEN, etc.),
# then runs the cmux 4h surface report script.
#
# Why the wrapper: launchd jobs do NOT source ~/.bashrc, so the report script
# would see no Slack token and skip the post. The launchd-env-wrapper.sh
# sources ~/.bash_profile -> ~/.bashrc and explicitly extracts key API tokens.
#
# Verified pattern: ai.smartclaw.schedule.slack-thread-roadmap-report
# (see launchd-job-authoring skill §Pattern C).

set -uo pipefail

LABEL="com.jleechan.cmux-surface-report-4h"
LOG_TAG="cmux-surface-report-4h"
LOG_FILE="$HOME/Library/Logs/${LABEL}.log"

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [$LOG_TAG] $*"; }

log "=== launchd tick ==="

# Resolve env (SLACK_BOT_TOKEN, HOME, PATH via ~/.bashrc)
if [ -x "$HOME/.smartclaw/scripts/launchd-env-wrapper.sh" ]; then
  # The wrapper exec's its argument, so we chain through bash -c.
  bash -c "source '$HOME/.smartclaw/scripts/launchd-env-wrapper.sh' >/dev/null 2>&1; exec '$HOME/.smartclaw/scripts/cmux-surface-report-4h.sh'" \
    2>&1 | tee -a "$LOG_FILE"
  RC=${PIPESTATUS[0]}
else
  log "FATAL: launchd-env-wrapper.sh missing — Slack token won't load"
  exit 1
fi

log "=== tick done (rc=$RC) ==="
exit "$RC"
