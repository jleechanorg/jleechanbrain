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

COMMIT_SHA=""
if [[ "$CHANGED" -eq 1 ]]; then
  log "Cron backup changed -- committing..."
  cp "$BACKUP_JSON" "$BACKUP_JSON.bak" 2>/dev/null || true
  if cd "$ROOT" 2>/dev/null; then
    if git add "$BACKUP_JSON" "$BACKUP_MD" 2>/dev/null && ! git diff --cached --quiet; then
      if git commit -m "chore: refresh cron backup" >/dev/null 2>&1; then
        COMMIT_SHA=$(git rev-parse HEAD)
        log "Committed: $COMMIT_SHA"
        git push >/dev/null 2>&1 || log "WARN: push failed"
      else
        log "WARN: commit failed"
      fi
    fi
  fi
fi

TOTAL=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['total'])" "$BACKUP_JSON")
ENABLED=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['enabled'])" "$BACKUP_JSON")

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
