#!/usr/bin/env bash
# ao-babysit-7652.sh
# Babysit AO worker wa-2374 on PR jleechanorg/worldarchitect.ai#7653 (issue #7652).
# Posts one-line status to Slack thread 1781768647.678629 in C0AH3RY3DK6 every 5 min.
# Detects completion and self-disables.
set -uo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin${PATH:+:$PATH}"

AO_SESSION="wa-2374"
TMUX_SESSION="953501c04ccc-wa-2374"
BEAD_ID="rev-xvlfg"
PR_NUMBER="7653"
REPO="jleechanorg/worldarchitect.ai"
SLACK_CHANNEL="C0AH3RY3DK6"
SLACK_THREAD_TS="1781768647.678629"
WORKTREE="${HOME}/.worktrees/worldarchitect/wa-2374"
BRANCH="fix/7652-martial-attribution-silo"

LOG="${HOME}/.smartclaw/logs/ao-babysit-7652.log"
STATE="${HOME}/.smartclaw/logs/ao-babysit-7652-state.json"
PLIST_PATH="$HOME/Library/LaunchAgents/ai.smartclaw.schedule.ao-babysit-7652.plist"

mkdir -p "$(dirname "$LOG")" "$(dirname "$STATE")"

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log() { echo "[$(ts)] $*" >> "$LOG"; }

# Heartbeat
log "tick AO_SESSION=$AO_SESSION TMUX=$TMUX_SESSION"

# Token from bashrc (strip surrounding quotes from the value)
TOKEN=$(bash -c 'source ~/.bashrc 2>/dev/null; echo -n "$SLACK_BOT_TOKEN"' 2>/dev/null | tr -d '"' || true)
if [ -z "$TOKEN" ]; then
  TOKEN=$(bash -c 'source ~/.bashrc 2>/dev/null; echo -n "$OPENCLAW_SLACK_BOT_TOKEN"' 2>/dev/null | tr -d '"' || true)
fi
if [ -z "$TOKEN" ]; then
  log "ERROR: no Slack token in ~/.bashrc; cannot post. Skipping tick."
  exit 0
fi

post_thread() {
  local text="$1"
  if [ "${DRY_RUN:-0}" = "1" ]; then
    log "DRY_RUN post: $text"
    return 0
  fi
  local payload
  payload=$(printf '{"channel":"%s","thread_ts":"%s","text":%s}' \
    "$SLACK_CHANNEL" "$SLACK_THREAD_TS" "$(printf '%s' "$text" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')")
  local resp
  resp=$(curl -s -X POST "https://slack.com/api/chat.postMessage" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$payload")
  log "post_thread resp: ${resp:0:200}"
}

# 1. Check if worker is alive
TMUX_ALIVE=0
if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
  TMUX_ALIVE=1
fi

# 2. Check PR state
PR_STATE="UNKNOWN"
PR_SHA="none"
PR_COMMITS=0
if command -v gh >/dev/null 2>&1; then
  PR_JSON=$(gh pr view "$PR_NUMBER" --repo "$REPO" --json state,mergeCommit,headRefName,commits 2>/dev/null || echo '{}')
  PR_STATE=$(echo "$PR_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("state","UNKNOWN"))' 2>/dev/null || echo "UNKNOWN")
  PR_SHA=$(echo "$PR_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); print((d.get("mergeCommit") or {}).get("oid","none")[:12])' 2>/dev/null || echo "none")
  PR_COMMITS=$(echo "$PR_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d.get("commits",[])))' 2>/dev/null || echo "0")
fi

# 3. Check bead
BEAD_STATUS="unknown"
if command -v br >/dev/null 2>&1; then
  BEAD_STATUS=$(br show "$BEAD_ID" 2>/dev/null | head -3 | grep -oE '(IN_PROGRESS|DONE|CLOSED|OPEN)' | head -1 | tr 'A-Z' 'a-z' || echo "unknown")
fi

# 4. Check last commit on the worktree branch
LAST_COMMIT=""
if [ -d "$WORKTREE" ]; then
  LAST_COMMIT=$(cd "$WORKTREE" && git log origin/${BRANCH} --oneline -1 2>/dev/null || echo "none")
fi

log "state: tmux_alive=$TMUX_ALIVE pr_state=$PR_STATE pr_sha=$PR_SHA pr_commits=$PR_COMMITS bead=$BEAD_STATUS last_commit=$LAST_COMMIT"

# Decision: done?
DONE=0
if [ "$BEAD_STATUS" = "done" ] || [ "$BEAD_STATUS" = "closed" ]; then
  DONE=1
fi
if [ "$PR_STATE" = "MERGED" ]; then
  DONE=1
fi
if [ "$PR_COMMITS" -gt 1 ] && [ "$BEAD_STATUS" = "done" ]; then
  DONE=1
fi

if [ "$DONE" = "1" ]; then
  log "DONE detected — posting completion + disabling cron"
  post_thread "✅ *AO worker finished* (bead $BEAD_ID). PR #$PR_NUMBER state: $PR_STATE. Last commit: $LAST_COMMIT. Self-disabling babysit."
  launchctl bootout gui/501/ai.smartclaw.schedule.ao-babysit-7652 2>/dev/null || true
  rm -f "$PLIST_PATH"
  exit 0
fi

# Worker dead?
if [ "$TMUX_ALIVE" = "0" ]; then
  log "DEAD detected (tmux gone)"
  post_thread "⚠️ *AO worker wa-2374 is dead* — tmux session $TMUX_SESSION not found. Check the worktree at $WORKTREE. Last PR commit: $LAST_COMMIT. Bead: $BEAD_STATUS."
  exit 0
fi

# Worker alive — post 5-min status
PANE_TAIL=$(tmux capture-pane -t "$TMUX_SESSION" -p 2>/dev/null | tail -10 | tr '\n' ' ' | head -c 280 || echo "(no pane)")
STATUS_LINE=$(echo "$PANE_TAIL" | sed 's/^[[:space:]]*//' | head -c 250)
MSG="🔄 *#7652 babysit* — tmux: alive · PR #$PR_NUMBER: $PR_STATE ($PR_COMMITS commits) · bead: $BEAD_STATUS · last: $LAST_COMMIT"
post_thread "$MSG"
log "posted status tick"
exit 0
