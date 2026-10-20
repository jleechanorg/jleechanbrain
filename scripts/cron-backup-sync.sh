#!/usr/bin/env bash
set -euo pipefail

ROOT="${HERMES_HOME:-$HOME/.smartclaw}"
CTX="$ROOT/docs/context"
JOBS_STORE="$ROOT/cron/jobs.json"
BACKUP_JSON="$CTX/CRON_JOBS_BACKUP.json"
BACKUP_MD="$CTX/CRON_JOBS_BACKUP.md"

mkdir -p "$CTX" "$ROOT/logs/cron-backup"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# Back up from the canonical job store, not the CLI table. The table is a
# human-facing rendering: it omits fields needed to restore a job (prompt,
# skills, workdir, model) and its per-job header format is not a stable API.
if [[ ! -f "$JOBS_STORE" ]]; then
  log "FATAL: job store not found at $JOBS_STORE"
  exit 1
fi

log "Exporting Hermes cron jobs from $JOBS_STORE ..."

CRON_JOBS=$(python3 - "$JOBS_STORE" <<'PY'
import json, sys

store = json.load(open(sys.argv[1]))
jobs = store.get("jobs", [])
if not isinstance(jobs, list):
    raise SystemExit("job store 'jobs' is not a list")

# Volatile per-tick runtime state. Excluded so that the diff against the
# previous backup reflects real configuration changes rather than clock
# movement -- otherwise every run reports itself as "changed".
VOLATILE = {
    "next_run_at", "last_run_at", "last_status", "last_error",
    "last_delivery_error", "fire_claim",
}

clean = []
for j in jobs:
    clean.append({k: v for k, v in sorted(j.items()) if k not in VOLATILE})

by_state = {}
for j in clean:
    by_state[j.get("state", "unknown")] = by_state.get(j.get("state", "unknown"), 0) + 1

print(json.dumps({
    "jobs": clean,
    "total": len(clean),
    "enabled": sum(1 for j in clean if j.get("enabled")),
    "by_state": dict(sorted(by_state.items())),
}, indent=2, sort_keys=True))
PY
) || { log "FATAL: failed to parse $JOBS_STORE"; exit 1; }

# Write via temp file so a crash mid-write cannot truncate a good backup.
printf '%s\n' "$CRON_JOBS" > "$BACKUP_JSON.tmp"
mv "$BACKUP_JSON.tmp" "$BACKUP_JSON"

python3 - "$BACKUP_JSON" "$BACKUP_MD" <<'PY'
import json, sys
from datetime import datetime, timezone

data = json.load(open(sys.argv[1]))
jobs = data["jobs"]
ts = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")

lines = [
    "# Cron Jobs Backup", "",
    f"Exported: {ts}",
    f"Total jobs: {data['total']}",
    f"Enabled: {data['enabled']}",
    "By state: " + ", ".join(f"{k}={v}" for k, v in data["by_state"].items()),
    "", "## Jobs", "",
]
for j in jobs:
    sched = j.get("schedule_display") or j.get("schedule") or "?"
    if isinstance(sched, dict):
        sched = sched.get("expr", "?")
    lines += [
        f"### {j.get('name', 'unknown')}",
        f"- ID: `{j.get('id', '?')}`",
        f"- Enabled: {j.get('enabled', '?')}",
        f"- State: {j.get('state', '?')}",
        f"- Schedule: `{sched}`",
        f"- Deliver: `{j.get('deliver', '?')}`",
    ]
    if j.get("skills"):
        lines.append("- Skills: " + ", ".join(j["skills"]))
    if j.get("script"):
        lines.append(f"- Script: `{j['script']}`")
    if j.get("workdir"):
        lines.append(f"- Workdir: `{j['workdir']}`")
    lines.append("")

open(sys.argv[2], "w").write("\n".join(lines) + "\n")
PY

CHANGED=0
if [[ -f "$BACKUP_JSON.bak" ]]; then
  diff -q "$BACKUP_JSON" "$BACKUP_JSON.bak" >/dev/null 2>&1 || CHANGED=1
else
  CHANGED=1
fi

# Force a safe user.name/user.email for every git invocation. The local
# repo's user.name may be set to literal "..." (placeholder left by an
# older install), which makes `git stash push -m` fail with
# "fatal: name consists only of disallowed characters: ..." -- git
# rejects the value before the stash can be created. Bug-ref: Slack
# C0AJQ5M0A0Y/1788363021.388999 (cron backup reported "changed but NOT
# committed" daily since Aug 28).
GIT_COMMON_ARGS=( -c gc.auto=0 -c user.name="hermes-cron-backup" -c user.email="harness@hermes.local" )

# Clear stale index.lock (a previous crashed run can leave it). Only remove if
# no live git process holds the repo — pgrep guard avoids racing with one.
remove_stale_lock() {
  local lock="$ROOT/.git/index.lock"
  [[ -f "$lock" ]] || return 0
  local age_s
  age_s=$(( $(date +%s) - $(stat -f %m "$lock" 2>/dev/null || echo 0) ))
  if (( age_s > 300 )); then
    if ! pgrep -fl "git (commit|add|rebase|merge|cherry-pick|am)" >/dev/null 2>&1; then
      log "Removing stale index.lock (age=${age_s}s)"
      rm -f "$lock"
    else
      log "WARN: index.lock present (age=${age_s}s) but a git process is live — leaving it"
    fi
  else
    log "WARN: index.lock present (age=${age_s}s, <5m) — leaving it"
  fi
}

# Commit the backup on a detached HEAD pinned to origin/main. This avoids
# polluting whatever triage/feature branch the operator happened to leave
# checked out — a recurring footgun since Aug 28. Strategy: stash dirty
# work, checkout detached at origin/main, add+commit+push, restore branch,
# then pop the stash. Falls back to current branch only when origin/main
# is unreachable (offline / no remote).
COMMIT_SHA=""
COMMIT_BRANCH=""
if [[ "$CHANGED" -eq 1 ]]; then
  log "Cron backup changed -- committing..."
  cp "$BACKUP_JSON" "$BACKUP_JSON.bak" 2>/dev/null || true
  if cd "$ROOT" 2>/dev/null; then
    remove_stale_lock
    ORIG_BRANCH=$(git "${GIT_COMMON_ARGS[@]}" symbolic-ref --short HEAD 2>/dev/null || echo "")
    ORIG_HEAD_SHA=$(git "${GIT_COMMON_ARGS[@]}" rev-parse HEAD 2>/dev/null || echo "")
    TARGET_SHA=""
    if git "${GIT_COMMON_ARGS[@]}" fetch origin main >/dev/null 2>&1; then
      TARGET_SHA=$(git "${GIT_COMMON_ARGS[@]}" rev-parse origin/main 2>/dev/null || echo "")
    fi
    if [[ -n "$TARGET_SHA" ]] && [[ -n "$ORIG_BRANCH" ]]; then
      COMMIT_BRANCH="detached@${TARGET_SHA:0:9}"
      STASH_REF=""
      # Stash any unrelated dirty work the operator left on the branch.
      # Includes untracked files (`--include-untracked`) because git checkout
      # refuses to overwrite untracked files in the destination tree.
      if [[ -n "$(git "${GIT_COMMON_ARGS[@]}" status --porcelain 2>/dev/null)" ]]; then
        STASH_REF=$(git "${GIT_COMMON_ARGS[@]}" stash push -u -m "cron-backup-sync auto-stash $(date -u +%FT%TZ)" 2>/dev/null | tail -1 | awk -F'[ :]' '{print $NF}')
      fi
      if git "${GIT_COMMON_ARGS[@]}" -c advice.detachedHead=false checkout -q "$TARGET_SHA" 2>/dev/null; then
        # Drop any stale index in the new HEAD.
        remove_stale_lock
        # Re-create the backup files in the detached HEAD's working tree. The
        # stash pop after commit restores the operator's untracked files,
        # but our regenerated BACKUP_JSON/MD belong to origin/main's tree.
        mkdir -p "$(dirname "$BACKUP_JSON")" "$(dirname "$BACKUP_MD")"
        printf '%s\n' "$CRON_JOBS" > "$BACKUP_JSON"
        python3 - "$BACKUP_JSON" "$BACKUP_MD" <<'PY_BACKUP_MD'
import json, sys
from datetime import datetime, timezone
data = json.load(open(sys.argv[1]))
jobs = data["jobs"]
ts = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
lines = [
    "# Cron Jobs Backup", "",
    f"Exported: {ts}",
    f"Total jobs: {data['total']}",
    f"Enabled: {data['enabled']}",
    "By state: " + ", ".join(f"{k}={v}" for k, v in data["by_state"].items()),
    "", "## Jobs", "",
]
for j in jobs:
    sched = j.get("schedule_display") or j.get("schedule") or "?"
    if isinstance(sched, dict):
        sched = sched.get("expr", "?")
    lines += [
        f"### {j.get('name', 'unknown')}",
        f"- ID: `{j.get('id', '?')}`",
        f"- Enabled: {j.get('enabled', '?')}",
        f"- State: {j.get('state', '?')}",
        f"- Schedule: `{sched}`",
        f"- Deliver: `{j.get('deliver', '?')}`",
    ]
    if j.get("skills"):
        lines.append("- Skills: " + ", ".join(j["skills"]))
    if j.get("script"):
        lines.append(f"- Script: `{j['script']}`")
    if j.get("workdir"):
        lines.append(f"- Workdir: `{j['workdir']}`")
    lines.append("")
open(sys.argv[2], "w").write("\n".join(lines) + "\n")
PY_BACKUP_MD
        if git "${GIT_COMMON_ARGS[@]}" add "$BACKUP_JSON" "$BACKUP_MD" 2>/dev/null && \
           ! git "${GIT_COMMON_ARGS[@]}" diff --cached --quiet 2>/dev/null; then
          if GIT_AUTHOR_NAME="hermes-cron-backup" \
             GIT_AUTHOR_EMAIL="harness@hermes.local" \
             GIT_COMMITTER_NAME="hermes-cron-backup" \
             GIT_COMMITTER_EMAIL="harness@hermes.local" \
             git "${GIT_COMMON_ARGS[@]}" commit -m "claudem/minimax-M3: chore: refresh cron backup" \
                -m "Refreshed from cron/jobs.json via scripts/cron-backup-sync.sh. Detached HEAD at origin/main so the operator's working branch is never polluted." \
                >/dev/null 2>&1; then
            NEW_SHA=$(git "${GIT_COMMON_ARGS[@]}" rev-parse HEAD)
            if git "${GIT_COMMON_ARGS[@]}" push origin "HEAD:refs/heads/main" >/dev/null 2>&1; then
              COMMIT_SHA="$NEW_SHA"
              log "Committed (detached at origin/main) and pushed: $COMMIT_SHA"
            else
              log "WARN: detached commit created ($NEW_SHA) but push to origin/main failed"
            fi
          else
            log "WARN: detached commit failed"
          fi
        else
          log "No new commit needed (working tree already matches backup)"
        fi
      else
        log "WARN: failed to checkout detached at $TARGET_SHA"
      fi
      # Restore the operator's original branch and pop the stash (if any).
      if [[ -n "$ORIG_BRANCH" ]]; then
        git "${GIT_COMMON_ARGS[@]}" checkout -q "$ORIG_BRANCH" >/dev/null 2>&1 || \
          git "${GIT_COMMON_ARGS[@]}" checkout -q "$ORIG_HEAD_SHA" >/dev/null 2>&1 || true
      else
        git "${GIT_COMMON_ARGS[@]}" checkout -q "$ORIG_HEAD_SHA" >/dev/null 2>&1 || true
      fi
      if [[ -n "$STASH_REF" ]]; then
        git "${GIT_COMMON_ARGS[@]}" stash pop -q >/dev/null 2>&1 || \
          log "WARN: failed to pop stash $STASH_REF — operator must resolve"
      fi
    else
      log "WARN: origin/main unavailable or repo not on a branch — falling back to current HEAD"
      if git "${GIT_COMMON_ARGS[@]}" add "$BACKUP_JSON" "$BACKUP_MD" 2>/dev/null && \
         ! git "${GIT_COMMON_ARGS[@]}" diff --cached --quiet 2>/dev/null; then
        if GIT_AUTHOR_NAME="hermes-cron-backup" \
           GIT_AUTHOR_EMAIL="harness@hermes.local" \
           GIT_COMMITTER_NAME="hermes-cron-backup" \
           GIT_COMMITTER_EMAIL="harness@hermes.local" \
           git "${GIT_COMMON_ARGS[@]}" commit -m "claudem/minimax-M3: chore: refresh cron backup" \
              -m "Refreshed from cron/jobs.json via scripts/cron-backup-sync.sh (fallback to current branch)." \
              >/dev/null 2>&1; then
          COMMIT_SHA=$(git "${GIT_COMMON_ARGS[@]}" rev-parse HEAD)
          COMMIT_BRANCH=$(git "${GIT_COMMON_ARGS[@]}" branch --show-current 2>/dev/null || echo "detached")
          log "Committed (fallback): $COMMIT_SHA on $COMMIT_BRANCH"
          if [[ -n "$(git "${GIT_COMMON_ARGS[@]}" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)" ]]; then
            git "${GIT_COMMON_ARGS[@]}" push >/dev/null 2>&1 || log "WARN: push failed"
          else
            log "WARN: no upstream set on $COMMIT_BRANCH — skipping push"
          fi
        else
          log "WARN: fallback commit failed"
        fi
      fi
    fi
  fi
fi

TOTAL=$(python3 -c "import json,sys; print(json.load(sys.stdin)['total'])" <<<"$CRON_JOBS")
ENABLED=$(python3 -c "import json,sys; print(json.load(sys.stdin)['enabled'])" <<<"$CRON_JOBS")

do_slack() {
  local msg="$1"
  [[ -f "$HOME/.profile" ]] && source "$HOME/.profile" 2>/dev/null || true
  [[ -z "${SLACK_USER_TOKEN:-}" ]] && { log "SLACK_USER_TOKEN not set"; return 0; }
  local cid="${SLACK_REVIEW_CHANNEL_ID:-C0AJQ5M0A0Y}"
  local payload
  payload=$(python3 -c "import json,sys; print(json.dumps({'channel': sys.argv[1], 'text': sys.stdin.read().strip()}))" "$cid" <<< "$msg")
  curl -s -X POST "https://slack.com/api/chat.postMessage" \
    -H "Authorization: Bearer ${SLACK_USER_TOKEN}" \
    -H "Content-Type: application/json" -d "$payload" \
    >> "$ROOT/logs/cron-backup/slack-$(date +%Y%m%d).log" 2>&1 || true
}

if [[ "$CHANGED" -eq 1 ]] && [[ -n "$COMMIT_SHA" ]]; then
  do_slack "Cron Backup: committed ${COMMIT_SHA:0:9}. Total: $TOTAL jobs ($ENABLED enabled)."
elif [[ "$CHANGED" -eq 1 ]]; then
  do_slack "Cron Backup: changed but NOT committed. Total: $TOTAL jobs ($ENABLED enabled)."
else
  do_slack "Cron Backup: no changes. Total: $TOTAL jobs ($ENABLED enabled)."
fi

log "Done. Total=$TOTAL Enabled=$ENABLED Changed=$CHANGED Commit=${COMMIT_SHA:-none}"
exit 0
