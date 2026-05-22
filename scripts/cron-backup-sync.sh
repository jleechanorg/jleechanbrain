#!/usr/bin/env bash
set -euo pipefail

ROOT="${HERMES_ROOT:-$HOME/.smartclaw}"
CTX="$ROOT/docs/context"
BACKUP_JSON="$CTX/CRON_JOBS_BACKUP.json"
BACKUP_MD="$CTX/CRON_JOBS_BACKUP.md"
REPORT="$ROOT/logs/cron-backup/report-$(date +%Y%m%d).txt"

mkdir -p "$CTX" "$ROOT/logs/cron-backup"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

if ! command -v hermes >/dev/null 2>&1; then
  log "SKIP: hermes CLI not found"
  exit 0
fi

log "Exporting Hermes cron jobs..."
CRON_JSON=$(hermes cron list --json 2>/dev/null) || true

# hermes may emit plugin noise before the JSON; find the first { and parse from there
CRON_JOBS=$(echo "$CRON_JSON" | awk '/^{/ {found=1} found' | python3 -c "
import json, sys
raw = sys.stdin.read().strip()
if not raw.startswith('{'):
    print(raw); sys.exit(1)
d = json.loads(raw)
jobs = d.get('jobs', [])
for j in jobs:
    for k in list(j.keys()):
        if k.startswith('last') or k.startswith('next'):
            del j[k]
    # Keep schedule.kind + schedule.expr/everyMs + tz for cron expression fidelity
    sched = j.get('schedule', {})
    for k in list(sched.keys()):
        if k not in ('kind', 'expr', 'everyMs', 'tz', 'anchorMs', 'staggerMs'):
            del sched[k]
print(json.dumps({'jobs': jobs, 'total': len(jobs)}, indent=2))
" 2>/dev/null) || CRON_JOBS="$CRON_JSON"

echo "$CRON_JOBS" > "$BACKUP_JSON"

# Generate markdown summary.
# Use a QUOTED heredoc (<<'PYEOF') so the shell does not interpret backticks
# or $ inside the python source — markdown code-span backticks must reach
# python literally, not get rewritten to escape sequences.
if ! CRON_JOBS_RAW="$CRON_JOBS" python3 - "$BACKUP_MD" <<'PYEOF'
import json, sys, os, datetime
raw = os.environ.get('CRON_JOBS_RAW', '').strip()
if not raw.startswith('{'):
    open(sys.argv[1], 'w').write('# Cron Jobs Backup\nError: bad JSON\n')
    sys.exit(0)
d = json.loads(raw)
jobs = d.get('jobs', [])
lines = ['# Cron Jobs Backup', '',
         'Exported: ' + datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S UTC'),
         'Total jobs: ' + str(len(jobs)), '', '## Jobs', '']
for j in jobs:
    sched = j.get('schedule', {})
    if sched.get('kind') == 'cron':
        sched_str = sched.get('expr', '?')
    elif sched.get('kind') == 'every':
        ms = sched.get('everyMs', 0)
        mins = ms // 60000
        sched_str = f'every {mins}m'
    else:
        sched_str = '?'
    lines += ['### ' + j.get('name', 'unknown'),
              '- ID: ' + j.get('id', '?'),
              '- Enabled: ' + str(j.get('enabled', '?')),
              '- Schedule: `' + sched_str + '`',
              '- Description: ' + j.get('description', '?')]
open(sys.argv[1], 'w').write('\n'.join(lines))
PYEOF
then
  echo "# Cron Jobs Backup" > "$BACKUP_MD"
  echo "Exported: $(date)" >> "$BACKUP_MD"
fi

CHANGED=0
COMMIT_SHA=""
if [[ -f "$BACKUP_JSON" ]] && [[ -f "$BACKUP_JSON.bak" ]]; then
  diff -q "$BACKUP_JSON" "$BACKUP_JSON.bak" >/dev/null 2>&1 || CHANGED=1
else
  CHANGED=1
fi

if [[ "$CHANGED" -eq 1 ]]; then
  log "Cron backup changed -- committing..."
  cp "$BACKUP_JSON" "$BACKUP_JSON.bak" 2>/dev/null || true
  if cd "$ROOT" 2>/dev/null; then
    if git add "$BACKUP_JSON" "$BACKUP_MD" 2>/dev/null; then
      if ! git diff --cached --quiet; then
        if git commit -m "chore: refresh cron backup" 2>/dev/null; then
          COMMIT_SHA=$(git rev-parse HEAD)
          log "Committed: $COMMIT_SHA"
          git push 2>/dev/null || true
        fi
      fi
    fi
  fi
fi

TOTAL=$(echo "$CRON_JOBS" | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('jobs',[])))" 2>/dev/null || echo "?")
ENABLED=$(echo "$CRON_JOBS" | python3 -c "import json,sys; print(sum(1 for j in json.load(sys.stdin).get('jobs',[]) if j.get('enabled')))" 2>/dev/null || echo "?")

do_slack() {
  local msg="$1"
  [[ -f "$HOME/.profile" ]] && source "$HOME/.profile" 2>/dev/null || true
  [[ -z "${SLACK_USER_TOKEN:-}" ]] && { log "SLACK_USER_TOKEN not set"; return 0; }
  local cid="${SLACK_REVIEW_CHANNEL_ID:-C0AJQ5M0A0Y}"
  local payload
  payload=$(python3 -c "import json,sys; print(json.dumps({'channel': '$cid', 'text': sys.stdin.read().strip()}))" <<< "$msg")
  curl -s -X POST "https://slack.com/api/chat.postMessage" \
    -H "Authorization: Bearer $SLACK_USER_TOKEN" \
    -H "Content-Type: application/json" -d "$payload" \
    >> "$ROOT/logs/cron-backup/slack-$(date +%Y%m%d).log" 2>&1 || true
}

if [[ "$CHANGED" -eq 1 ]] && [[ -n "$COMMIT_SHA" ]]; then
  do_slack "Cron Backup: committed. Total: $TOTAL jobs ($ENABLED enabled)."
elif [[ "$CHANGED" -eq 1 ]]; then
  do_slack "Cron Backup: changed (not committed). Total: $TOTAL jobs."
else
  do_slack "Cron Backup: no changes. Total: $TOTAL jobs ($ENABLED enabled)."
fi

log "Done. Total=$TOTAL Enabled=$ENABLED Changed=$CHANGED"
exit 0
