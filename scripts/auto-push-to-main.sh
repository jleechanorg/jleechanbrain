#!/usr/bin/env bash
# auto-push-to-main.sh
# Runs every 30 min via launchd. Detects uncommitted changes in the target repo,
# commits and pushes to origin main. On failure, falls back to `codex exec --yolo`.
#
# Usage: auto-push-to-main.sh <repo_path> <repo_name>
# Example: auto-push-to-main.sh ~/llm_wiki llm-wiki

set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin${PATH:+:$PATH}"

trap '' PIPE

# ── Config ────────────────────────────────────────────────────────────────────
REPO="${1:-}"
REPO_NAME="${2:-unknown}"

LOCK_DIR="${TMPDIR:-/tmp}/auto-push-${REPO_NAME//[^a-zA-Z0-9_-]/}.lock"
LOG_DIR="${HOME}/.hermes/logs/scheduled-jobs"
COMMIT_LOG="${LOG_DIR}/auto-push-${REPO_NAME}.log"
STATE_FILE="${LOG_DIR}/auto-push-${REPO_NAME}-state.json"
RUN_INTERVAL_SECS="${RUN_INTERVAL_SECS:-1800}"

GIT_EMAIL="${GIT_EMAIL:-$(git config user.email 2>/dev/null || echo jeffrey@openclaw.ai)}"
GIT_NAME="${GIT_NAME:-$(git config user.name 2>/dev/null || echo 'Auto-Push')}"

SLACK_TOKEN="${HERMES_SLACK_BOT_TOKEN:-}"
SLACK_CHANNEL="${SLACK_CHANNEL:-${SLACK_CHANNEL_ID}}"  # #antigravity

CODEX_FALLBACK="${CODEX_FALLBACK:-1}"

mkdir -p "$LOG_DIR"

# ── Helpers ───────────────────────────────────────────────────────────────────
log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] [auto-push:${REPO_NAME}] $*" | tee -a "$COMMIT_LOG"; }

load_state() {
  if [[ -f "$STATE_FILE" ]]; then
    content="$(cat "$STATE_FILE" 2>/dev/null)" || content='{}'
    echo "$content" | jq -e '.' >/dev/null 2>&1 && echo "$content" || echo '{}'
  else
    echo '{}'
  fi
}

save_state() {
  local tmp
  tmp="$(mktemp "$STATE_FILE.XXXXXX")"
  cat > "$tmp" < /dev/stdin
  mv "$tmp" "$STATE_FILE"
}

was_run_recently() {
  local state last_ts now_sec ts_sec
  state="$(load_state)"
  last_ts="$(printf '%s' "$state" | jq -r '.last_run_ts // empty' 2>/dev/null)" || last_ts=""
  [[ -z "$last_ts" || "$last_ts" == "null" ]] && return 1
  now_sec="$(date +%s)"
  if [[ "$(uname -s)" == "Darwin" ]]; then
    ts_sec="$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_ts" '+%s' 2>/dev/null)" || return 1
  else
    ts_sec="$(date -d "$last_ts" '+%s' 2>/dev/null)" || return 1
  fi
  [[ $((now_sec - ts_sec)) -lt RUN_INTERVAL_SECS ]] && return 0
  return 1
}

record_run() {
  local now_iso
  now_iso="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  load_state | jq --arg ts "$now_iso" '.last_run_ts = $ts' | save_state
}

# ── Slack ─────────────────────────────────────────────────────────────────────
slack_post() {
  local text="$1"
  [[ -z "$SLACK_TOKEN" ]] && { log "WARN: no Slack token — skipping notification"; return 0; }

  local payload
  payload="$(jq -n \
    --arg ch "$SLACK_CHANNEL" \
    --arg txt "[auto-push:${REPO_NAME}] $text" \
    '{channel: $ch, text: $txt, unfold_multiple_attachments: false}')"

  curl --silent --show-error --fail \
    --connect-timeout 10 --max-time 30 \
    -X POST "https://slack.com/api/chat.postMessage" \
    -H "Authorization: Bearer $SLACK_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$payload" | jq -e '.ok == true' > /dev/null 2>&1 || log "WARN: Slack notification failed"
}

# ── Codex fallback ────────────────────────────────────────────────────────────
run_codex_fallback() {
  local error_summary="$1"
  log "CODEX FALLBACK: running codex exec --yolo to fix push failure"

  local git_status
  git_status="$(cd "$REPO" && git status --short 2>/dev/null || echo "git unavailable")"

  local codex_task="Fix the git push failure in ${REPO_NAME} at ${REPO}.

Error: $error_summary

Git status:
$(echo "$git_status" | head -30)

Tasks:
1. Diagnose why the push to origin main failed
2. Fix the issue
3. Push to origin main
4. If there are uncommitted changes, commit them first with a descriptive message
5. Report what you did"

  local codex_output
  codex_output="$(codex exec --yolo --project "${REPO_NAME}-auto-push-fix" "$codex_task" 2>&1)" && {
    log "CODEX FALLBACK: codex exec succeeded"
    slack_post "codex --yolo fixed push in ${REPO_NAME}" || true
  } || {
    log "CODEX FALLBACK: codex exec failed or unavailable: $(echo "$codex_output" | tail -3)"
    slack_post "Push failed in ${REPO_NAME} AND codex fallback also failed — manual intervention needed" || true
  }
}

# ── Git helpers ───────────────────────────────────────────────────────────────
has_changes() {
  cd "$REPO" || return 1
  [[ -n "$(git status --porcelain)" ]]
}

tracked_changes() {
  cd "$REPO" || return 1
  git diff --name-only HEAD 2>/dev/null
  git diff --cached --name-only HEAD 2>/dev/null
}

untracked_files() {
  cd "$REPO" || return 1
  git ls-files --others --exclude-standard 2>/dev/null
}

# ── Push logic ────────────────────────────────────────────────────────────────
do_push() {
  cd "$REPO" || { log "ERROR: cannot cd to $REPO"; return 1; }

  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    log "ERROR: not a git repo: $REPO"
    return 1
  fi

  local changed_files untracked_count
  changed_files="$(tracked_changes | sort -u | grep -v '^')" || true
  untracked_count="$(untracked_files | wc -l | tr -d ' ' 2>/dev/null || echo '0')"

  if [[ -z "$changed_files" && "$untracked_count" == "0" ]]; then
    log "No changes — nothing to push"
    return 0
  fi

  if [[ -z "$changed_files" && "$untracked_count" != "0" ]]; then
    log "Only untracked files present — NOT auto-committing"
    slack_post "⚠️ ${REPO_NAME} has untracked files — not auto-pushing. Add manually if needed." || true
    return 0
  fi

  # Configure git identity if not set
  git config user.email "$GIT_EMAIL" 2>/dev/null || true
  git config user.name "$GIT_NAME" 2>/dev/null || true

  # Stage tracked files only
  log "Staging tracked files..."
  if ! git add -u; then
    log "ERROR: git add -u failed"
    [[ "$CODEX_FALLBACK" == "1" ]] && run_codex_fallback "git add -u failed"
    return 1
  fi

  local file_count
  file_count="$(echo "$changed_files" | wc -l | tr -d ' ' || echo '?')"

  if git diff --cached --quiet 2>/dev/null; then
    log "No staged changes — up to date"
    return 0
  fi

  local commit_msg="[Auto] Pending changes $(date '+%Y-%m-%d %H:%M')"
  log "Committing: $commit_msg ($file_count file(s))"

  local commit_output
  commit_output="$(git commit -m "$commit_msg" 2>&1)" || {
    log "ERROR: git commit failed: $(echo "$commit_output" | tail -3)"
    [[ "$CODEX_FALLBACK" == "1" ]] && run_codex_fallback "git commit failed: $commit_output"
    return 1
  }

  log "Pushing to origin main..."
  local push_output
  push_output="$(git push origin main 2>&1)" && {
    log "Push successful"
    slack_post "✅ Auto-pushed ${REPO_NAME}: $file_count file(s) — $(git log -1 --format='%s')" || true
    return 0
  } || {
    log "ERROR: git push failed: $(echo "$push_output" | tail -5)"
    [[ "$CODEX_FALLBACK" == "1" ]] && run_codex_fallback "git push to origin main failed: $push_output"
    return 1
  }
}

# ── Overlap lock ──────────────────────────────────────────────────────────────
acquire_lock() {
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    log "SKIP: another instance running"
    exit 0
  fi
  trap 'rmdir "$LOCK_DIR" >/dev/null 2>&1 || true' EXIT
}

# ── Main ──────────────────────────────────────────────────────────────────────
if [[ -z "$REPO" ]]; then
  echo "Usage: $0 <repo_path> <repo_name>" >&2
  exit 1
fi

acquire_lock
log "Starting auto-push (interval=${RUN_INTERVAL_SECS}s, repo=${REPO})"

if was_run_recently; then
  log "SKIP: ran recently (within ${RUN_INTERVAL_SECS}s)"
  exit 0
fi

if do_push; then
  record_run
  log "Done"
else
  log "ERROR: push failed"
  exit 1
fi