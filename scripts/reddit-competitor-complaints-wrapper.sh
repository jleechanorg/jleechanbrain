#!/bin/bash
# reddit-competitor-complaints-wrapper.sh
# launchd entry point: chains through launchd-env-wrapper.sh to load
# SLACK_BOT_TOKEN (and friends) into the environment, then runs
# the reddit-competitor-complaints job script.
#
# Why this wrapper exists:
#   - launchd jobs do NOT source ~/.bashrc, so the script would see no
#     Slack token and silently skip the post.
#   - launchd-env-wrapper.sh ends with `exec "$@"`, so it REPLACES the
#     current shell with its first argument. The cmux wrapper pattern
#     (verified) uses `bash -c "source wrapper; exec $script"`.
#
# Verified pattern: ai.smartclaw.schedule.slack-thread-roadmap-report
# (see launchd-job-authoring skill §Pattern C).

set -uo pipefail

LABEL="ai.smartclaw.schedule.reddit-competitor-complaints"
LOG_FILE="$HOME/Library/Logs/${LABEL}.log"

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [reddit-competitor] $*"; }

log "=== launchd tick ==="

if [ ! -x "$HOME/.smartclaw/scripts/launchd-env-wrapper.sh" ]; then
  log "FATAL: launchd-env-wrapper.sh missing — Slack token won't load"
  exit 1
fi

# Chain through env wrapper, then exec the job script
bash -c "source '$HOME/.smartclaw/scripts/launchd-env-wrapper.sh' >/dev/null 2>&1; exec '$HOME/.smartclaw/scripts/reddit-competitor-complaints.sh'" \
  2>&1 | tee -a "$LOG_FILE"
RC=${PIPESTATUS[0]}

log "=== tick done (rc=$RC) ==="
exit "$RC"
