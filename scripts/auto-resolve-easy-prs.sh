#!/usr/bin/env bash
# ~/.smartclaw/scripts/auto-resolve-easy-prs.sh
#
# Cron job: every 20 min, spawn ONE AO worker (minimax agent, jleechanbrain project)
# whose job is to fan out to N parallel delegate_task subagents (one per easy PR) and
# fix as many of the 7 currently-easy worldarchitect.ai PRs as possible.
#
# "Easy" heuristic (live at spawn time, not hardcoded):
#   - PR is OPEN
#   - headRefName does NOT contain "antig" or "agento" (avoid worker-controlled branches)
#   - mergeable is MERGEABLE (no conflict to resolve — pure CI/review work)
#   - changedFiles <= 7
#   - additions <= 500
#   - title does NOT contain "[antig]" (avoid antigravity worker PRs)
#
# Output: full work-order at ~/.smartclaw/logs/easy-prs-work-order.txt
#         spawn receipt at ~/.smartclaw/logs/easy-prs-spawn.log
#         Slack thread reply to #ai-slack-test (${SLACK_CHANNEL_ID})

set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
REPO="jleechanorg/worldarchitect.ai"
PROJECT="jleechanbrain"        # AO project (orchestration side; worker uses minimax)
AGENT="minimax"                # explicit: don't rely on project default
CHANNEL_ID="${SLACK_CHANNEL_ID}"       # #ai-slack-test
LOG_DIR="$HOME/.smartclaw/logs"
WORK_ORDER="$LOG_DIR/easy-prs-work-order.txt"
SPAWN_LOG="$LOG_DIR/easy-prs-spawn.log"
SLACK_TOKEN="${SLACK_BOT_TOKEN:-${SLACK_USER_TOKEN:-}}"
MAX_PRS=7
MAX_ADDITIONS=500
MAX_FILES=7
mkdir -p "$LOG_DIR"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] $*"; }
log_to() { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] $*" >> "$SPAWN_LOG"; }

# Source bashrc to pick up GH_TOKEN, MINIMAX_API_KEY, etc.
set +u
if [[ -f "$HOME/.bash_profile" ]]; then
  source "$HOME/.bash_profile" 2>/dev/null || true
fi
if [[ -f "$HOME/.bashrc" ]]; then
  # bashrc may have interactive guard; force-source critical vars
  for v in GH_TOKEN GITHUB_TOKEN MINIMAX_API_KEY MINIMAX_MODEL SLACK_BOT_TOKEN; do
    if grep -qE "^export $v=" "$HOME/.bashrc" 2>/dev/null; then
      val=$(grep -E "^export $v=" "$HOME/.bashrc" | head -1 | sed -E "s/^export $v=//; s/^['\"]//; s/['\"]$//")
      export "$v"="$val"
    fi
  done
fi
set -u

# Resolve GH_TOKEN if still empty
if [[ -z "${GH_TOKEN:-}" ]]; then
  GH_TOKEN="$(gh auth token 2>/dev/null || true)"
  export GH_TOKEN
fi

# ---------------------------------------------------------------------------
# Step 1: enumerate the 7 currently-easy PRs (re-derives every run, not stale)
# ---------------------------------------------------------------------------
log_to "Enumerating easy PRs for $REPO …"

EASY_PRS_JSON=$(gh pr list \
  --repo "$REPO" \
  --state open \
  --limit 100 \
  --json number,title,headRefName,additions,changedFiles,mergeable,statusCheckRollup,url \
  2>/dev/null) || {
    log_to "ERROR: gh pr list failed: $(gh pr list --repo "$REPO" --state open --limit 1 2>&1 | head -3)"
    exit 1
  }

# Filter and sort to top MAX_PRS
# "Easy" heuristic (loose — worker's Phase 0 will re-triage):
#   - mergeable in (MERGEABLE, UNKNOWN) — UNKNOWN is common for live PRs
#   - additions <= MAX_ADDITIONS (default 500)
#   - changedFiles <= MAX_FILES (default 7)
#   - title/branch does NOT contain "antig" or "agento" (avoid worker PRs)
FILTERED=$(echo "$EASY_PRS_JSON" | python3 -c "
import json, sys
d = json.load(sys.stdin)
max_add = $MAX_ADDITIONS
max_files = $MAX_FILES
max_prs = $MAX_PRS
out = []
for pr in d:
    if pr['mergeable'] not in ('MERGEABLE','UNKNOWN'):
        continue
    if pr['additions'] > max_add:
        continue
    if pr['changedFiles'] > max_files:
        continue
    title = pr['title']
    branch = pr['headRefName']
    if 'antig' in branch or 'agento' in branch:
        continue
    if title.startswith('[antig]') or title.startswith('[agento]'):
        continue
    out.append({
        'number': pr['number'],
        'title': title,
        'branch': branch,
        'additions': pr['additions'],
        'changedFiles': pr['changedFiles'],
        'url': pr['url'],
        'mergeable': pr['mergeable'],
        'failingChecks': sorted(set(
            c['name'] for c in (pr.get('statusCheckRollup') or [])
            if c.get('conclusion') in ('FAILURE','TIMED_OUT','ERROR')
        )),
    })
# sort by smallest first (most likely to be truly easy)
out.sort(key=lambda p: (p['additions'], p['changedFiles']))
print(json.dumps(out[:max_prs], indent=2))
")

COUNT=$(echo "$FILTERED" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")
log_to "Filtered to $COUNT easy PRs (cap=$MAX_PRS)."

if [[ "$COUNT" -eq 0 ]]; then
  log_to "Nothing to do — no easy PRs match the heuristic."
  echo "[$(date '+%Y-%m-%dT%H:%M:%S')] No easy PRs; skipping spawn." >> "$SPAWN_LOG"
  exit 0
fi

# ---------------------------------------------------------------------------
# Step 2: build the per-PR work-order block (concise, machine-friendly)
# ---------------------------------------------------------------------------
WORK_ORDER_BLOCK=$(echo "$FILTERED" | python3 -c "
import json, sys
prs = json.load(sys.stdin)
print('| # | PR | Branch | Files | +Lines | mergeable | Failing checks |')
print('|---|----|--------|-------|--------|-----------|----------------|')
for i, p in enumerate(prs, 1):
    fails = ', '.join(p['failingChecks'][:3]) or '—'
    print(f'| {i} | #{p[\"number\"]} | \`{p[\"branch\"]}\` | {p[\"changedFiles\"]} | {p[\"additions\"]} | {p[\"mergeable\"]} | {fails} |')
print()
print('Detail (per PR):')
for i, p in enumerate(prs, 1):
    print(f'''---
### PR {i}: #{p[\"number\"]} — {p[\"title\"]}
- branch: \`{p[\"branch\"]}\`
- url: {p[\"url\"]}
- additions: {p[\"additions\"]}  files: {p[\"changedFiles\"]}
- mergeable: {p[\"mergeable\"]}
- failing checks: {p[\"failingChecks\"] or \"[]\"}
''')
")

# Save work-order for the worker to read
{
  echo "# Work-order generated $(date -u +'%Y-%m-%dT%H:%M:%SZ') for $REPO"
  echo "# Heuristic: MERGEABLE, additions<=$MAX_ADDITIONS, files<=$MAX_FILES, no antig/agento"
  echo
  echo "$WORK_ORDER_BLOCK"
} > "$WORK_ORDER"
log_to "Work-order written to $WORK_ORDER"

# ---------------------------------------------------------------------------
# Step 3: load the prompt template and substitute
# ---------------------------------------------------------------------------
PROMPT_TEMPLATE="$HOME/.smartclaw/scripts/prompts/auto-resolve-easy-prs.md"
if [[ ! -f "$PROMPT_TEMPLATE" ]]; then
  log_to "ERROR: prompt template missing at $PROMPT_TEMPLATE"
  exit 1
fi

# Substitute the work-order block into the prompt
PROMPT=$(python3 -c "
import pathlib
tpl = pathlib.Path('$PROMPT_TEMPLATE').read_text()
order = pathlib.Path('$WORK_ORDER').read_text()
out = tpl.replace('{{WORK_ORDER}}', order)
out = out.replace('{{GENERATED_AT}}', '$(date -u +'%Y-%m-%dT%H:%M:%SZ')')
out = out.replace('{{REPO}}', '$REPO')
out = out.replace('{{PR_COUNT}}', '$COUNT')
out = out.replace('{{MAX_PRS}}', '$MAX_PRS')
print(out)
")

# ---------------------------------------------------------------------------
# Step 4: pre-spawn cap check (5 for worldarchitect per agento v1.19.0)
# ---------------------------------------------------------------------------
ACTIVE_COUNT=$(ao session ls --project worldarchitect 2>/dev/null | grep -cE '^\[' || echo 0)
log_to "Active worldarchitect sessions: $ACTIVE_COUNT (cap=5)"
if [[ "$ACTIVE_COUNT" -ge 5 ]]; then
  log_to "Cap reached — running cleanup of zombies before spawn"
  ao session cleanup -p worldarchitect 2>&1 | tee -a "$SPAWN_LOG" || true
  ACTIVE_COUNT=$(ao session ls --project worldarchitect 2>/dev/null | grep -cE '^\[' || echo 0)
  log_to "After cleanup: $ACTIVE_COUNT active"
  if [[ "$ACTIVE_COUNT" -ge 5 ]]; then
    log_to "Still at cap after cleanup — SKIPPING this tick (will retry next 20-min tick)"
    echo "[$(date '+%Y-%m-%dT%H:%M:%S')] Cap reached, skipped." >> "$SPAWN_LOG"
    exit 0
  fi
fi

# ---------------------------------------------------------------------------
# Step 5: spawn the worker
# ---------------------------------------------------------------------------
PROMPT_FILE="$LOG_DIR/easy-prs-prompt.$(date +%Y%m%d%H%M%S).md"
echo "$PROMPT" > "$PROMPT_FILE"
log_to "Prompt written to $PROMPT_FILE ($(wc -l < "$PROMPT_FILE") lines, $(wc -c < "$PROMPT_FILE") bytes)"

log_to "Spawning AO worker: project=$PROJECT agent=$AGENT"
SPAWN_OUT=$(ao spawn \
  --project "$PROJECT" \
  --agent "$AGENT" \
  --runtime tmux \
  "$(cat "$PROMPT_FILE")" \
  2>&1) || SPAWN_OUT="ao spawn failed: $SPAWN_OUT"

log_to "Spawn output: $SPAWN_OUT"

# Extract session id if present (e.g. "Spawned wa-2503")
SESSION_ID=$(echo "$SPAWN_OUT" | grep -oE 'wa-[0-9]+' | head -1 || echo "unknown")
log_to "Session ID: $SESSION_ID"

# ---------------------------------------------------------------------------
# Step 6: post Slack thread reply to #ai-slack-test
# ---------------------------------------------------------------------------
if [[ -n "$SLACK_TOKEN" && -n "${SLACK_THREAD_TS:-}" ]]; then
  SLACK_MSG="🔁 *easy-PR cron tick* (every 20 min)
- *PRs queued:* $COUNT (cap $MAX_PRS)
- *Session:* \`$SESSION_ID\`
- *Project:* \`$PROJECT\` (agent=\`$AGENT\`)
- *Work-order:* \`$WORK_ORDER\`
- *Prompt:* \`$PROMPT_FILE\`
- *PR list:*
$(echo "$FILTERED" | python3 -c "import json,sys; [print(f'  • #{p[\"number\"]} ({p[\"additions\"]}+/{p[\"changedFiles\"]}f) {p[\"branch\"]}') for p in json.load(sys.stdin)]")"

  curl -fsS -X POST "https://slack.com/api/chat.postMessage" \
    -H "Authorization: Bearer $SLACK_TOKEN" \
    --data-urlencode "channel=$CHANNEL_ID" \
    --data-urlencode "thread_ts=$SLACK_THREAD_TS" \
    --data-urlencode "text=$SLACK_MSG" \
    > /dev/null 2>&1 && log_to "Slack thread reply posted" || log_to "Slack post failed (non-fatal)"
else
  log_to "Skipped Slack post (no SLACK_TOKEN or SLACK_THREAD_TS)"
fi

log_to "DONE"
exit 0
