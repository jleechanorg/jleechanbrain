#!/usr/bin/env bash
# ao-progress-reporter.sh
# Every 30 min: check all AO worker sessions across all projects,
# report remote commit URLs of work done to Slack, and fix/nudge stalled sessions.
#
# Output goes to Slack thread: original trigger message ts in #agent-orchestrator
# Idempotency: tracks last-reported per (project, session) to avoid spam.
# Guardrails:
#   - DRY_RUN=1: prints actions without executing or posting to Slack
#   - IS_SOURCED=1: allows source for test coverage without running main
#   - Overlap lock prevents concurrent runs

set -euo pipefail

export PATH="$HOME/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin${PATH:+:$PATH}"
trap '' PIPE

# ── Config ────────────────────────────────────────────────────────────────────
LOCK_DIR="${AOPR_LOCK_DIR:-${TMPDIR:-/tmp}/hermes-ao-progress.lock}"
LOG_DIR="${AOPR_LOG_DIR:-${HOME}/.smartclaw/logs}"
STATE_FILE="${AOPR_STATE_FILE:-$HOME/.smartclaw/logs/ao-progress-state.json}"
REPORT_INTERVAL_SECS="${AOPR_INTERVAL_SECS:-1800}"   # 30 min
SLACK_CHANNEL="${AOPR_SLACK_CHANNEL:-C0ALSKLU9KM}"   # #agent-orchestrator
# Root thread for progress replies (#agent-orchestrator)
# Default (fallback). Script auto-creates a new thread each calendar day (PDT).
SLACK_THREAD_TS="${AOPR_SLACK_THREAD_TS:-}"
AO_DIR="${AO_DIR:-$HOME/project_agento/agent-orchestrator}"
AO_BIN="${AO_BIN:-ao}"

# Compute today's date key for thread-per-day logic (PDT = America/Los_Angeles)
TODAY_KEY="$(TZ=America/Los_Angeles date '+%Y-%m-%d')"

mkdir -p "$LOG_DIR"

log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] $*" >&2; }

# Overlap lock
if [[ "${IS_SOURCED:-0}" != "1" ]]; then
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    log "SKIP: another instance running"
    exit 0
  fi
  trap 'rmdir "$LOCK_DIR" >/dev/null 2>&1 || true' EXIT
fi

# ── Slack helper ──────────────────────────────────────────────────────────────
post_slack() {
  local text="$1"
  local thread_ts_arg="${2:-}"
  local effective_ts="${thread_ts_arg:-${SLACK_THREAD_TS:-}}"

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log "[DRY_RUN] Slack: $text [thread:$effective_ts]"
    return
  fi
  local token="${SLACK_BOT_TOKEN:-}"
  if [[ -z "$token" ]]; then
    log "ERROR: SLACK_BOT_TOKEN not set"
    return
  fi
  export SLACK_TEXT="$text"
  export SLACK_THREAD_TS="$effective_ts"
  python3 -c "
import urllib.request, json, os, sys
text = os.environ.get('SLACK_TEXT', '')
ts = os.environ.get('SLACK_THREAD_TS', '')
payload = {
  'channel': '${SLACK_CHANNEL}',
  'text': text
}
if ts:
    payload['thread_ts'] = ts
payload = json.dumps(payload)
req = urllib.request.Request(
  'https://slack.com/api/chat.postMessage',
  data=payload.encode(),
  headers={'Authorization': 'Bearer ${token}', 'Content-Type': 'application/json'},
  method='POST'
)
with urllib.request.urlopen(req) as resp:
  result = json.load(resp)
  sys.exit(0 if result.get('ok') else 1)
" || log "Slack post failed"
}

# ── GH token ─────────────────────────────────────────────────────────────────
resolve_token() {
  local tok=""
  # Try hermes config(s) for embedded gh token (prod may use ~/.smartclaw_prod)
  for cfg in "$HOME/.smartclaw/config.yaml" "$HOME/.smartclaw_prod/config.yaml"; do
    [[ -f "$cfg" ]] || continue
    tok="$(jq -r 'try .skills.entries["gh-issues"].apiKey catch empty' "$cfg" 2>/dev/null)" || tok=""
    [[ -n "$tok" && "$tok" != "null" ]] && break
  done
  # Skip if null or empty
  if [[ -z "$tok" || "$tok" == "null" ]]; then
    tok="${GH_TOKEN:-}"
  fi
  if [[ -z "$tok" || "$tok" == "null" ]]; then
    tok="${GITHUB_TOKEN:-}"
  fi
  # gh CLI is authenticated — use it directly for REST calls via gh api
  if [[ -z "$tok" || "$tok" == "null" ]] && command -v gh >/dev/null 2>&1; then
    tok="$(gh auth token 2>/dev/null)" || tok=""
  fi
  printf '%s' "$tok"
}
GH_TOKEN="$(resolve_token)" || true
[[ -n "$GH_TOKEN" && "$GH_TOKEN" != "null" ]] || { log "ERROR: No GH_TOKEN found"; exit 1; }

# ── Load state ───────────────────────────────────────────────────────────────
load_state() {
  if [[ -f "$STATE_FILE" ]]; then
    cat "$STATE_FILE" 2>/dev/null || echo '{}'
  else
    echo '{}'
  fi
}

save_state() {
  local json=$1
  cat > "$STATE_FILE" <<< "$json"
}

# ── Thread-per-day: resolve or create today's thread ─────────────────────────
# Persistence file: scoped to configured log dir and channel to prevent cross-channel/staging issues
THREAD_TS_FILE="${LOG_DIR}/ao-progress-reporter-thread-${SLACK_CHANNEL}-${TODAY_KEY}.ts"
REPORTER_LOG="${LOG_DIR}/ao-progress-reporter.log"

_log_reporter() {
  local msg="[$(date '+%Y-%m-%dT%H:%M:%S')] $*"
  echo "$msg" >&2
  mkdir -p "$(dirname "$REPORTER_LOG")" 2>/dev/null || true
  echo "$msg" >> "$REPORTER_LOG" 2>/dev/null || true
}

resolve_thread_ts() {
  local state_json=$1
  local today_ts

  # 1. Check the dedicated TS file first (survives process restarts and state JSON resets)
  if [[ -f "$THREAD_TS_FILE" ]]; then
    today_ts="$(<"$THREAD_TS_FILE")"
    today_ts="${today_ts//[$'\t\r\n ']}"  # strip whitespace
    if [[ -n "$today_ts" && "$today_ts" != "null" && "$today_ts" != "dry_run_thread_ts" ]]; then
      log "Using persisted thread for $TODAY_KEY: $today_ts"
      echo "$today_ts"
      return
    fi
  fi

  # 2. Fall back to in-memory state JSON (backward compat with older runs)
  today_ts="$(echo "$state_json" | jq -r ".daily_threads[\"$TODAY_KEY\"] // empty" 2>/dev/null)" || today_ts=""
  if [[ -n "$today_ts" && "$today_ts" != "null" && "$today_ts" != "dry_run_thread_ts" ]]; then
    log "Using cached thread (state) for $TODAY_KEY: $today_ts"
    # Persist to file so future calls skip the JSON parse
    mkdir -p "$(dirname "$THREAD_TS_FILE")" 2>/dev/null || true
    printf '%s' "$today_ts" > "$THREAD_TS_FILE" 2>/dev/null || true
    echo "$today_ts"
    return
  fi

  # DRY_RUN: skip actual Slack post; return placeholder to allow dry-run flow
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log "[DRY_RUN] Would create new thread for $TODAY_KEY in #agent-orchestrator"
    echo "dry_run_thread_ts"
    return
  fi

  # 3. No cached thread for today — check Slack channel history first to prevent duplication,
  #    and if not found, post a new daily thread header with retry logic.
  log "Resolving or creating daily thread for $TODAY_KEY"
  local response attempt
  for attempt in 1 2 3; do
    response="$(python3 -c "
import urllib.request, json, os, sys

token = os.environ.get('SLACK_BOT_TOKEN', '')
channel = '${SLACK_CHANNEL}'
today_key = '${TODAY_KEY}'

def call_slack(endpoint, payload):
  req = urllib.request.Request(
    'https://slack.com/api/' + endpoint,
    data=json.dumps(payload).encode(),
    headers={
      'Authorization': 'Bearer ' + token,
      'Content-Type': 'application/json'
    },
    method='POST'
  )
  with urllib.request.urlopen(req, timeout=15) as resp:
    return json.load(resp)

try:
  # 1. Check history first to prevent duplicate creation (e.g. if previous attempt timed out on response but posted successfully)
  history = call_slack('conversations.history', {'channel': channel, 'limit': 50})
  if history.get('ok'):
    for msg in history.get('messages', []):
      if '*AO Progress Report* | ' + today_key + ' — new daily thread' in msg.get('text', ''):
        ts = msg.get('ts')
        if ts:
          print(ts)
          sys.exit(0)

  # 2. Create the thread if not found
  payload = {
    'channel': channel,
    'text': '*AO Progress Report* | ' + today_key + ' — new daily thread',
    'unfurl_links': False
  }
  result = call_slack('chat.postMessage', payload)
  if result.get('ok'):
    print(result.get('ts', ''))
  else:
    print('ERROR:' + str(result))
except Exception as e:
  print('ERROR:' + str(e))
  sys.exit(1)
" 2>/dev/null)" || response=""

    if [[ "$response" == ERROR:* || -z "$response" || "$response" == "null" ]]; then
      _log_reporter "Attempt $attempt/3 failed to resolve or create thread: '${response:-empty}'"
      if [[ $attempt -lt 3 ]]; then
        log "Retrying in 5s..."
        sleep 5
      fi
    else
      # Success — persist to file and return
      log "Daily thread resolved/created (attempt $attempt): $response"
      mkdir -p "$(dirname "$THREAD_TS_FILE")" 2>/dev/null || true
      printf '%s' "$response" > "$THREAD_TS_FILE" 2>/dev/null || true
      echo "$response"
      return
    fi
  done

  # All retries exhausted — log prominently and return failure (empty string)
  _log_reporter "ERROR: resolve_thread_ts() exhausted 3 retries on $TODAY_KEY — skipping this reporter run to avoid channel-root spam"
  echo ""
  return 1
}

# ── Get AO sessions JSON (all projects) ───────────────────────────────────────
fetch_ao_sessions() {
  local all_sessions="[]"
  if [[ ! -d "$AO_DIR" ]] || ! command -v "$AO_BIN" >/dev/null 2>&1; then
    echo "$all_sessions"
    return
  fi
  # Try JSON status first, fall back to parsing text
  all_sessions="$(cd "$AO_DIR" && "$AO_BIN" status --json 2>/dev/null)" || echo "[]"
  echo "$all_sessions"
}

# ── Get remote commit URL for a branch ───────────────────────────────────────
get_commit_urls() {
  local repo=$1   # owner/repo
  local branch=$2
  local max_commits=${3:-3}
  local commits=""
  commits="$(gh api "repos/$repo/commits/$branch" \
    --jq "[.sha, (.parents[].sha // empty)[] | select(. != null)] | .[0:$max_commits] | .[]" \
    2>/dev/null)" || commits=""
  if [[ -z "$commits" ]]; then
    echo ""
    return
  fi
  local urls=""
  while IFS= read -r sha; do
    [[ -z "$sha" || "$sha" == "null" ]] && continue
    urls+="https://github.com/$repo/commit/$sha
"
  done <<< "$commits"
  echo -n "$urls"
}

# ── Check if session has made progress since last report ─────────────────────
session_has_progress() {
  local session_name=$1
  local state_json=$2
  local last_sha
  last_sha="$(echo "$state_json" | jq -r ".\"$session_name\".last_sha // \"\"" 2>/dev/null)" || last_sha=""
  echo "$last_sha"
}

# ── Get session info from AO status JSON ─────────────────────────────────────
get_session_info() {
  local ao_json=$1
  local session_name=$2
  local info
  info="$(echo "$ao_json" | jq -c "map(select(.name == \"$session_name\")) | .[0]" 2>/dev/null)" || info=""
  echo "$info"
}

# ── Terminal-state classification ────────────────────────────────────────────
# A terminal session has finished its lifecycle (PR merged/closed, worker killed).
# Terminal sessions are reported at most once after going terminal; once they
# leave the active set their state entry is pruned so the file stays bounded.
#
# Single source of truth for terminal statuses (sessions that are definitively
# finished and safe to prune from state once they leave the active set).
TERMINAL_STATUSES=(killed merged closed done)
TERMINAL_STATUSES_JSON="$(printf '%s\n' "${TERMINAL_STATUSES[@]}" | jq -R . | jq -sc .)"

is_terminal_status() {
  local s=$1 t
  for t in "${TERMINAL_STATUSES[@]}"; do
    [[ "$s" == "$t" ]] && return 0
  done
  return 1
}

# Prune state entries for TERMINAL sessions that are no longer in the active set
# (orphans), so ao-progress-state.json stays bounded. A terminal session that is
# STILL in the active set is kept on purpose: session_should_report already
# suppresses it every tick, whereas deleting it would make it a "first sighting"
# again and re-report forever (the exact noise this script must avoid). The
# reserved "daily_threads" key is always preserved. Fail-open: any jq error
# returns the state unchanged so a transient parse failure never drops state.
#   $1 = state JSON   $2 = JSON array of session names seen this tick
prune_terminal_orphans() {
  local state_json=$1 seen_json=$2
  echo "$state_json" | jq \
    --argjson seen "$seen_json" \
    --argjson terminal "$TERMINAL_STATUSES_JSON" \
    'with_entries(
       select(
         .key as $k | (.value.last_status // "") as $st
         | $k == "daily_threads"                  # reserved key — always keep
         or (($seen | index($k)) != null)         # still in the active set
         or (($terminal | index($st)) == null)    # non-terminal → keep
       )
     )' 2>/dev/null || echo "$state_json"
}

# ── Should this session be reported on this tick? ────────────────────────────
# Suppress no-op posts: only emit a per-session block when the session actually
# moved since the last recorded state. "Moved" = new commits OR a status change.
# Conservative: an empty/unknown prior status (first sighting) counts as changed,
# so a genuinely-new session is never silently dropped.
#   $1 has_new_commits ("yes"/"no")   $2 current status   $3 last recorded status
session_should_report() {
  local has_new_commits=$1 current_status=$2 last_status=$3
  [[ "$has_new_commits" == "yes" ]] && return 0
  [[ -z "$last_status" ]] && return 0          # first sighting → report
  [[ "$current_status" != "$last_status" ]] && return 0  # status/phase changed
  return 1                                      # nothing moved → suppress
}

# ── Main ──────────────────────────────────────────────────────────────────────
# IS_SOURCED=1 lets tests source the helpers above without running main.
if [[ "${IS_SOURCED:-0}" == "1" ]]; then
  return 0 2>/dev/null || exit 0
fi

{
  log "Starting AO progress reporter"

  current_state="$(load_state)" || current_state="{}"
  ao_sessions_json="$(fetch_ao_sessions)" || ao_sessions_json="[]"

  # Resolve or create today's thread — store in state
  thread_ts="$(resolve_thread_ts "$current_state")" || thread_ts=""
  if [[ -z "$thread_ts" || "$thread_ts" == "null" ]]; then
    # resolve_thread_ts() failed after all retries — skip this run entirely.
    # Never post to channel root: that creates noise outside the daily thread and
    # cannot be threaded after the fact.
    _log_reporter "SKIP: no thread_ts available for $TODAY_KEY — aborting run to avoid channel-root post"
    save_state "$current_state"
    exit 0
  fi

  # Persist real thread_ts (but not dry-run placeholder) in state so next run reuses it
  if [[ "$thread_ts" != "dry_run_thread_ts" ]]; then
    current_state="$(echo "$current_state" | jq --arg key "$TODAY_KEY" --arg ts "$thread_ts" \
      'setpath(["daily_threads"]; (if .daily_threads == null then {} else .daily_threads end) | .[$key] = $ts)')" || true
  fi
  log "Thread for $TODAY_KEY resolved: $thread_ts"
  # Export thread_ts so post_slack uses it without needing explicit arg
  SLACK_THREAD_TS="$thread_ts"

  save_state "$current_state"

  if [[ "$ao_sessions_json" == "[]" ]] || [[ -z "$ao_sessions_json" ]]; then
    log "No AO sessions found or AO unavailable"
    post_slack ":zzz: *AO Progress Report* — no active sessions detected"
    current_state="$(prune_terminal_orphans "$current_state" "[]")"
    save_state "$current_state"
    exit 0
  fi

  session_count="$(echo "$ao_sessions_json" | jq 'length' 2>/dev/null)" || session_count=0
  log "Found $session_count AO sessions"

  # Collect report lines
  report_blocks=()
  healthy=0
  stalled=0
  no_pr=0
  seen_sessions=()   # session names present in THIS tick (drives orphan pruning)

  # Iterate over sessions
  while IFS= read -r session_json; do
    [[ -z "$session_json" || "$session_json" == "null" ]] && continue

    session_name="$(echo "$session_json" | jq -r '.name // empty' 2>/dev/null)" || session_name=""
    project_id="$(echo "$session_json" | jq -r '.projectId // .project // empty' 2>/dev/null)" || project_id=""
    branch="$(echo "$session_json" | jq -r '.branch // empty' 2>/dev/null)" || branch=""
    status="$(echo "$session_json" | jq -r '.status // empty' 2>/dev/null)" || status=""
    pr_url="$(echo "$session_json" | jq -r '.prUrl // .prUrl // empty' 2>/dev/null)" || pr_url=""
    pr_number="$(echo "$session_json" | jq -r '.prNumber // empty' 2>/dev/null)" || pr_number=""

    [[ -z "$session_name" ]] && continue
    seen_sessions+=("$session_name")

    # Get repo from project
    repo=""
    case "$project_id" in
      agent-orchestrator) repo="jleechanorg/agent-orchestrator" ;;
      browserclaw)        repo="jleechanorg/browserclaw" ;;
      worldarchitect)     repo="jleechanorg/worldarchitect.ai" ;;
      worldai-claw)       repo="jleechanorg/worldai_claw" ;;
      claude-commands)    repo="jleechanorg/claude-commands" ;;
      ralph)              repo="jleechanorg/ralph" ;;
      jleechanbrain)       repo="jleechanorg/jleechanbrain" ;;
      ai-universe-living-blog) repo="jleechanorg/ai_universe_living_blog" ;;
      *)                  repo="" ;;
    esac

    # Get last known SHA + status from state (used for no-op suppression below)
    last_sha="$(echo "$current_state" | jq -r ".\"$session_name\".last_sha // \"\" " 2>/dev/null)" || last_sha=""
    last_status="$(echo "$current_state" | jq -r ".\"$session_name\".last_status // \"\" " 2>/dev/null)" || last_status=""

    # Fetch current head SHA (if branch known)
    current_sha=""
    if [[ -n "$branch" && -n "$repo" ]]; then
      current_sha="$(gh api "repos/$repo/commits/$branch" --jq '.sha' 2>/dev/null)" || current_sha=""
    fi

    # Determine if session is making progress
    has_new_commits="no"
    commit_urls=""
    if [[ -n "$current_sha" && "$current_sha" != "$last_sha" ]]; then
      has_new_commits="yes"
      # Get 3 most recent commit URLs
      commit_urls="$(get_commit_urls "$repo" "$branch" 3)"
      # Update state (record status too, for next tick's change detection)
      current_state="$(echo "$current_state" | jq \
        --arg name "$session_name" \
        --arg sha "$current_sha" \
        --arg status "$status" \
        --argjson now "$(date +%s)" \
        'setpath([$name]; {last_sha: $sha, last_status: $status, last_report: $now})')" || true
    elif [[ -n "$current_sha" ]]; then
      # Same HEAD as last report — refresh last_report + last_status, preserve last_sha
      current_state="$(echo "$current_state" | jq \
        --arg name "$session_name" \
        --arg status "$status" \
        --argjson now "$(date +%s)" \
        '.[$name] |= (. // {}) + {last_report: $now, last_status: $status}' 2>/dev/null)" || true
    else
      # No SHA available (no branch/repo) — still track status so a phase change
      # (e.g. spawning → working) is detected and reported next tick.
      current_state="$(echo "$current_state" | jq \
        --arg name "$session_name" \
        --arg status "$status" \
        --argjson now "$(date +%s)" \
        '.[$name] |= (. // {}) + {last_report: $now, last_status: $status}' 2>/dev/null)" || true
    fi

    # Suppress no-op posts: skip building/appending a block when nothing moved.
    # (State above is already refreshed; we just don't emit a Slack line.)
    if ! session_should_report "$has_new_commits" "$status" "$last_status"; then
      log "skip unchanged session: $session_name (status=$status sha=${current_sha:0:7})"
      continue
    fi

    # Classify session health
    case "$status" in
      killed)   label=":skull: killed" ;;
      pr_open)  label=":white_check_mark: PR open" ;;
      working)  label=":hourglass: working" ;;
      spawning) label=":rocket: spawning" ;;
      stuck)    label=":warning: STUCK" ;;
      ci_failed) label=":red_circle: CI failed" ;;
      needs_input) label=":thinking_face: needs input" ;;
      idle)     label=":zzz: idle" ;;
      "")       label=":grey_question: unknown" ;;
      *)        label=":$status:" ;;
    esac

    # Build session report block
    if [[ -n "$repo" && -n "$current_sha" ]]; then
      if [[ -n "$commit_urls" ]]; then
        session_report="• \`$session_name\` ($project_id) $label
  $commit_urls"
      else
        session_report="• \`$session_name\` ($project_id) $label
  $repo @ \`${current_sha:0:7}\`"
      fi
    else
      session_report="• \`$session_name\` ($project_id) $label"
    fi

    # Add PR off-track diagnostics (zero-touch smooth proxy: inactivity > 60m)
    if [[ -n "$repo" && -n "$pr_number" && "$pr_number" != "null" ]]; then
      pr_updated_at="$(gh pr view "$pr_number" --repo "$repo" --json updatedAt --jq '.updatedAt' 2>/dev/null)" || pr_updated_at=""
      if [[ -n "$pr_updated_at" && "$pr_updated_at" != "null" ]]; then
        pr_updated_epoch="$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$pr_updated_at" "+%s" 2>/dev/null)" || pr_updated_epoch="0"
        now_epoch="$(date +%s)"
        idle_min=$(( (now_epoch - pr_updated_epoch) / 60 ))
        idle_h=$(( idle_min / 60 ))
        idle_m=$(( idle_min % 60 ))
        if [[ "$idle_min" -gt 60 ]]; then
          offtrack_status=":red_circle: off-track"
        else
          offtrack_status=":green_circle: on-track"
        fi

        fail_summary="$(gh pr checks "$pr_number" --repo "$repo" --json name,state 2>/dev/null | jq -r '[.[] | select(.state != "SUCCESS") | "\(.name):\(.state)"] | .[:3] | join(", ")' 2>/dev/null)" || fail_summary=""
        if [[ -z "$fail_summary" || "$fail_summary" == "null" ]]; then
          fail_summary="none"
        fi

        session_report="$session_report
  PR #$pr_number $offtrack_status | idle ${idle_h}h${idle_m}m | blockers: $fail_summary"
      fi
    fi

    # Detect stalled sessions (working but no commits pushed for >1h or stuck/ci_failed/needs_input)
    if [[ "$status" == "stuck" || "$status" == "ci_failed" || "$status" == "killed" ]]; then
      stalled=$((stalled + 1))
      session_report="$session_report :fire:"
    elif [[ "$status" == "working" && -z "$commit_urls" ]]; then
      # working but no new commits since last report
      stalled=$((stalled + 1))
      session_report="$session_report :warning: (no new commits since last report)"
    elif [[ "$status" == "needs_input" || "$status" == "idle" ]]; then
      no_pr=$((no_pr + 1))
      session_report="$session_report"
    else
      healthy=$((healthy + 1))
    fi

    report_blocks+=("$session_report")

  done <<< "$(echo "$ao_sessions_json" | jq -c '.[]' 2>/dev/null)"

  # Prune terminal sessions that have left the active set (bounds state growth;
  # still-active terminals are intentionally kept — see prune_terminal_orphans).
  seen_json='[]'
  if [[ ${#seen_sessions[@]} -gt 0 ]]; then
    seen_json="$(printf '%s\n' "${seen_sessions[@]}" | jq -R . | jq -sc .)"
  fi
  current_state="$(prune_terminal_orphans "$current_state" "$seen_json")"

  # Save updated state
  save_state "$current_state"

  # Build and post Slack report
  header="*AO Progress Report* | $(date '+%H:%M PDT') | $session_count sessions"
  if [[ $healthy -gt 0 ]]; then
    header="$header | :white_check_mark: $healthy healthy"
  fi
  if [[ $stalled -gt 0 ]]; then
    header="$header | :warning: $stalled stalled"
  fi
  if [[ $no_pr -gt 0 ]]; then
    header="$header | :grey_question: $no_pr no PR yet"
  fi

  if [[ ${#report_blocks[@]} -eq 0 ]]; then
    # Sessions exist but none moved since the last tick — suppress the post
    # entirely. Posting an empty/"no changes" block every 30 min for a long-lived
    # PR is exactly the forever-repeat noise this script must avoid. State is
    # already saved above (last_report refreshed, terminal sessions pruned).
    log "AO progress reporter done — no session changes this tick, suppressing post (sessions:$session_count)"
  else
    body="$(printf '%s\n' "${report_blocks[@]}")"
    post_slack "$header
$body"
    log "AO progress reporter done — healthy:$healthy stalled:$stalled no_pr:$no_pr"
  fi

} 2>&1 | tee -a "$LOG_DIR/ao-progress-reporter.log"
