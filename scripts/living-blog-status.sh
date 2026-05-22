#!/usr/bin/env bash
#
# Living Blog + Novel Status — hourly via launchd
# Posts status update to #novel channel (C0ANS2MF15G)
# Launchd equivalent of gateway cron job "living-blog:novel-hourly-status"
#
# Bead: orch-dha (launchd migration)

set -euo pipefail

ROOT="${HERMES_ROOT:-$HOME/.smartclaw}"

mkdir -p "$ROOT/logs/scheduled-jobs"

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*"; }

# Always use the correct repo for PR checks — never infer from PR number alone
MESSAGE="Post a brief living blog + novel status update to this channel. Format: **Living Blog Server** (MCP server running on port 30000, PR #2 for jleechanorg/ai_universe_living_blog is MERGED, any new dispatches), **Novel Entries** (new entries since last check, count of total posts on the blog MCP server, notable worker events), **AO Workers** (active sessions, any stuck/idle workers), **Next actions** (what needs attention). Keep under 8 bullets. Be factual. Always check \`gh pr list --repo jleechanorg/ai_universe_living_blog\` for the correct PR state."

if ! command -v hermes >/dev/null 2>&1; then
  log "fail: hermes not in PATH"
  exit 1
fi

log "start living-blog-status"
set +e
hermes chat --quiet -q "$MESSAGE"
rc=$?
set -e
log "finish rc=$rc"
exit "$rc"
