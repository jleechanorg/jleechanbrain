#!/usr/bin/env bash
# Spawn a minimax worker to /green a specific PR with a strict timeout.
# Usage: agento_green_with_timeout.sh <pr_number> [timeout_minutes]
set -euo pipefail

PR_NUMBER="${1:?usage: $0 <pr_number> [timeout_minutes]}"
TIMEOUT_MIN="${2:-60}"

REPO="jleechanorg/worldarchitect.ai"
PROJECT="worldarchitect"
AGENT="minimax"

echo "[agento-green] PR #${PR_NUMBER} timeout=${TIMEOUT_MIN}m agent=${AGENT}"

# Stop any existing agent on this PR
echo "[agento-green] Stopping prior agents on PR ${PR_NUMBER}..."
for sess in $(ao session ls -p "${PROJECT}" 2>/dev/null | grep -oE "wa-[0-9]+" | sort -u); do
  SESS_PR=$(ao session ls -p "${PROJECT}" 2>/dev/null | grep "$sess" | grep -oE "pulls/[0-9]+" | head -1 | grep -oE "[0-9]+" || true)
  if [ "$SESS_PR" = "$PR_NUMBER" ]; then
    echo "[agento-green] Stopping ${sess} (owns PR ${PR_NUMBER})"
    ao send "$sess" stop 2>&1 | tail -1 || true
  fi
done

# Spawn minimax worker (prompt is a positional arg, not --prompt)
PROMPT="/green ${PR_NUMBER} in ${REPO}

TIME BUDGET: ${TIMEOUT_MIN} MINUTES. Exit cleanly when timer hits.

Plan:
1. cd to the worktree already checked out for this PR's branch (or create one)
2. gh pr view ${PR_NUMBER} — confirm head, current mergeable + CI state
3. If mergeable=false (conflicts): rebase onto origin/main, resolve, push
4. Fix any failing CI checks (gh pr checks ${PR_NUMBER})
5. If CodeRabbit CHANGES_REQUESTED: address inline comments
6. Run /er (evidence review) before declaring green
7. Exit cleanly when green — do not block on CodeRabbit if already APPROVED

Hard rule: when PR is MERGEABLE + CI green, post 'PR is green ✅' and exit.
Hard rule: NEVER gh pr merge. The orchestrator merges.

If time runs out before green, post current blocker summary and exit."

echo "[agento-green] Spawning ${AGENT} worker..."
SPAWN_OUT=$(ao spawn --project "${PROJECT}" --agent "${AGENT}" --claim-pr "${PR_NUMBER}" "${PROMPT}" 2>&1)
echo "$SPAWN_OUT"

SESSION_ID=$(echo "$SPAWN_OUT" | grep -oE "wa-[0-9]+" | head -1 || echo "")
if [ -z "$SESSION_ID" ]; then
  echo "[agento-green] WARN: could not parse session_id from spawn output"
  exit 1
fi
echo "[agento-green] session=${SESSION_ID}"

# Background watchdog — sends stop after timeout. Use nohup + disown to fully
# detach so the parent shell exits immediately after `ao spawn` returns.
nohup bash -c "
  sleep $((TIMEOUT_MIN * 60 + 30))
  echo '[agento-green][watchdog] ${TIMEOUT_MIN}m elapsed for ${SESSION_ID}'
  ao send '${SESSION_ID}' 'TIMEOUT: ${TIMEOUT_MIN} minutes elapsed. Post final status and exit immediately.' 2>&1 || true
  sleep 60
  ao send '${SESSION_ID}' stop 2>&1 || true
" >/dev/null 2>&1 &
WATCHDOG_PID=$!
disown 2>/dev/null || true
echo "[agento-green] watchdog_pid=${WATCHDOG_PID} session=${SESSION_ID}"
echo "${SESSION_ID}"
exit 0