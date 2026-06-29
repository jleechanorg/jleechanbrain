#!/usr/bin/env bash
# beads-conflict-resolver.sh — Scan open PRs in worldarchitect.ai modified in the last 48 hours and resolve beads conflicts.
set -euo pipefail

REPO="jleechanorg/worldarchitect.ai"
PROJECT="worldarchitect"
LOG_FILE="${HOME}/.smartclaw/logs/beads-conflict-resolver.log"
mkdir -p "$(dirname "$LOG_FILE")"
LOCK_DIR="${HOME}/.smartclaw/locks/beads-conflict-resolver.lock"

DROP_MAX_SPAWN="${DROP_MAX_SPAWN:-3}"

# When run under launchd, stdout already goes to the log file.
# Only use tee when running interactively (not under launchd).
if [[ -t 1 ]]; then
  log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S%z')] $*" | tee -a "$LOG_FILE"; }
else
  log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S%z')] $*" >> "$LOG_FILE"; }
fi

run_with_timeout() {
  local secs="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" "$@"
  else
    "$@"
  fi
}

acquire_lock() {
  mkdir -p "$(dirname "$LOCK_DIR")"
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    local lock_time=0
    if [[ "$OSTYPE" == "darwin"* ]]; then
      lock_time=$(stat -f "%m" "$LOCK_DIR" 2>/dev/null || echo 0)
    else
      lock_time=$(stat -c "%Y" "$LOCK_DIR" 2>/dev/null || echo 0)
    fi
    local now
    now=$(date +%s)
    local diff=$((now - lock_time))
    if (( diff > 7200 )); then
      log "Stale lock detected (older than 2 hours). Removing and acquiring."
      rmdir "$LOCK_DIR" 2>/dev/null || rm -rf "$LOCK_DIR"
      mkdir "$LOCK_DIR" 2>/dev/null || return 0
    else
      log "Scan skipped: another beads-conflict-resolver process is already active."
      exit 0
    fi
  fi
  trap 'rmdir "$LOCK_DIR" 2>/dev/null || rm -rf "$LOCK_DIR"' EXIT
}

acquire_lock

log "START: beads-conflict-resolver scan"

# Verify GitHub CLI authentication before running
if ! gh auth status >/dev/null 2>&1; then
  log "ERROR: GitHub CLI is not authenticated. Please run 'gh auth login' or set GH_TOKEN."
  exit 1
fi

# 1. Resolve 48 hours ago timestamp (cross-platform compatible date-only format)
if [[ "$OSTYPE" == "darwin"* ]]; then
  FORTY_EIGHT_HOURS_AGO=$(date -u -v-48H '+%Y-%m-%d')
else
  FORTY_EIGHT_HOURS_AGO=$(date -u -d '48 hours ago' '+%Y-%m-%d')
fi

# 2. Fetch open PRs modified in last 48 hours
log "Fetching open PRs modified since $FORTY_EIGHT_HOURS_AGO..."
search_query="repo:${REPO} is:pr is:open updated:>=${FORTY_EIGHT_HOURS_AGO}"
encoded_query=$(jq -nr --arg q "$search_query" '$q | @uri')

raw_prs=""
page=1
while true; do
  log "Fetching page $page of open PRs..."
  page_json=$(gh api "search/issues?q=${encoded_query}&per_page=100&page=${page}") || {
    log "ERROR: GitHub API query failed for search/issues on page $page"
    exit 1
  }
  
  page_prs=$(echo "$page_json" | jq -c '.items[] | {number: .number, title: .title, updatedAt: .updated_at}' 2>/dev/null || true)
  
  if [[ -z "$page_prs" ]]; then
    break
  fi
  
  if [[ -z "$raw_prs" ]]; then
    raw_prs="$page_prs"
  else
    raw_prs="${raw_prs}"$'\n'"${page_prs}"
  fi
  
  item_count=$(echo "$page_json" | jq '.items | length')
  if (( item_count < 100 )); then
    break
  fi
  
  page=$((page + 1))
done

if [[ -z "$raw_prs" ]]; then
  log "No open PRs modified in the last 48 hours."
  exit 0
fi

# 3. List active sessions to avoid duplicates
active_sessions=$(ao session ls -p "$PROJECT" 2>/dev/null || true)

# 4. Check AO lifecycle is running
if ! ao session ls -p "$PROJECT" >/dev/null 2>&1; then
  log "ERROR: AO lifecycle is not running. Cannot spawn workers."
  log "  Run 'ao start worldarchitect' to start the orchestrator."
  exit 1
fi

# 5. Count spawned workers to avoid overwhelming AO
spawned=0
MAX_SPAWN="$DROP_MAX_SPAWN"

# 6. Process each PR
while IFS= read -r pr_line; do
  [[ -z "$pr_line" ]] && continue

  pr_num=$(echo "$pr_line" | jq -r '.number')
  pr_title=$(echo "$pr_line" | jq -r '.title')

  log "Checking PR #$pr_num: $pr_title"

  # Check if mergeable status is CONFLICTING
  mergeable=$(gh pr view "$pr_num" --repo "$REPO" --json mergeable --jq '.mergeable' 2>/dev/null) || mergeable="unknown"

  if [[ "$mergeable" != "CONFLICTING" ]]; then
    log "  PR #$pr_num is not conflicting (mergeable=$mergeable) — skipping."
    continue
  fi

  # Get PR branch name
  pr_branch=$(gh pr view "$pr_num" --repo "$REPO" --json headRefName --jq '.headRefName' 2>/dev/null) || pr_branch=""

  # Check if PR contains beads modifications or differs on beads compared to main
  has_beads_changes="no"
  diff_list=$(gh pr diff "$pr_num" --repo "$REPO" --name-only 2>/dev/null || true)
  if echo "$diff_list" | grep -q "\.beads/"; then
    has_beads_changes="yes"
  elif [[ -n "$pr_branch" ]]; then
    compare_list=$(gh api "repos/$REPO/compare/main...$pr_branch" --jq '.files[].filename' 2>/dev/null || true)
    if echo "$compare_list" | grep -q "\.beads/"; then
      has_beads_changes="yes"
    fi
  fi

  if [[ "$has_beads_changes" != "yes" ]]; then
    log "  PR #$pr_num does not contain beads changes — skipping."
    continue
  fi

  # Check if a session already exists for this PR
  if echo "$active_sessions" | grep -qE "(/pulls?/)$pr_num( |$)"; then
    log "  PR #$pr_num already has an active AO session — skipping."
    continue
  fi

  # Check if the PR branch is already checked out in another worktree
  if [[ -n "$pr_branch" ]]; then
    existing_wt=$(git -C ~/projects/worldarchitect.ai worktree list 2>/dev/null | grep "\[$pr_branch\]" | head -1 || true)
    if [[ -n "$existing_wt" ]]; then
      log "  PR #$pr_num branch '$pr_branch' already checked out in worktree — skipping."
      continue
    fi
  fi

  # Rate limit: max spawns per run
  if [[ $spawned -ge $MAX_SPAWN ]]; then
    log "  Hit max spawn limit ($MAX_SPAWN) — deferring PR #$pr_num to next run."
    continue
  fi

  # Spawn beads conflict resolution worker!
  log "  Found beads conflict in PR #$pr_num! Spawning AO worker..."

  instruction="Resolve beads-only conflicts for PR #$pr_num. Configure beads merge driver locally, merge origin/main into this branch, run scripts/deduplicate_beads_jsonl.py .beads/issues.jsonl to resolve beads conflicts. If any non-beads conflicts remain (check git diff --name-only --diff-filter=U), abort the merge. Otherwise, commit the resolution and push. Make sure the PR title is prefixed with [antig]."

  spawn_output=$(run_with_timeout 300 ao spawn --claim-pr "$pr_num" -p "$PROJECT" --agent claude-code "$instruction" < /dev/null 2>&1) || spawn_rc=$?
  spawn_rc=${spawn_rc:-0}
  echo "$spawn_output" >> "$LOG_FILE"

  if [[ "$spawn_rc" -eq 0 ]] && echo "$spawn_output" | grep -qE "Session.*created and claimed PR"; then
    log "  Successfully spawned beads resolver worker for PR #$pr_num."
    spawned=$((spawned + 1))
  else
    log "  ERROR: Failed to spawn worker for PR #$pr_num (exit=$spawn_rc, output match fail)."
  fi

done <<< "$raw_prs"

log "DONE: beads-conflict-resolver scan complete (spawned $spawned workers)"
