#!/usr/bin/env bash
# dropped-thread-followup.sh
# Audits Slack channels for dropped agent threads and takes action.
# Runs every 4 hours via launchd.
#
# DROP DETECTION — strict criteria (avoid false positives / spam):
#   1. Agent explicitly admitted: "I did not execute it yet", "I only sent an acknowledgment"
#   2. Agent acknowledged but no AO dispatch / PR / commit / action was taken
#   3. Thread is unresolved AND > 2h old AND user asked agent to do work
#   4. Per-ask analysis: delivery vs partial (issue-only / open PR / pending options)
#   5. Agent message indicates timeout / gateway overload — counts as dropped (kind: timeout-failure)
#
# Idempotency: tracks last-nudged ts per (channel, thread_ts) in a JSON state file.
# Only re-nudges if > DROP_NUDGE_INTERVAL_SECS (default: 30m) have passed.
#
# Per-channel rate limit: DROP_CHANNEL_COOLDOWN_SECS (default: 10m) caps how often
# ANY single channel can be nudged, across all kinds (cold / stale-dispatch /
# timeout-failure / standalone). Bounds blast radius of the gateway thread-leak bug.
#
# Per-incident give-up: DROP_MAX_NUDGES (default: 3) caps how many times a single
# (channel, thread) is nudged before we escalate ONCE and stop nudging it forever
# (gave_up=true). Prevents an unresolved thread from being nudged on every tick.
# The .nudged["<channel>_<thread>"] value is an object {last, count, gave_up};
# legacy bare-ISO-string values are migrated on read (treated as count=1).
#
# Guardrails:
#   - DRY_RUN=1: prints actions without executing
#   - IS_SOURCED=1: allows source for test coverage without running main
#   - Overlap lock prevents concurrent runs
#
# Env: DROP_CHANNELS — override channel list (space-separated IDs); default: all bot-member channels via API.
#   DROP_EXCLUDE_CHANNELS — unset → skip nothing; set to space-separated IDs to exclude.
#   DROP_THREAD_REPLY_LIMIT — conversations.replies limit (default 200).
#   DROP_JEFFREY_ONLY_CHANNELS — unset → default ${SLACK_CHANNEL_ID}; set to "" → no jeffrey-only gating.

set -euo pipefail

# Guard: ensure basic commands are always available even in restricted launchd PATH
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin${PATH:+:$PATH}"

# Suppress SIGPIPE — python3 heredoc can exit before echo finishes piping,
# producing "echo: write error: Broken pipe" under set -euo pipefail
trap '' PIPE

# ── Config ────────────────────────────────────────────────────────────────────
LOCK_DIR="${DROP_LOCK_DIR:-${TMPDIR:-/tmp}/hermes-dropped-thread.lock}"
LOG_DIR="${DROP_LOG_DIR:-${HOME}/.smartclaw_prod/logs}"
STATE_FILE="${DROP_STATE_FILE:-$HOME/.smartclaw_prod/logs/dropped-thread-state.json}"
NUDGE_INTERVAL_SECS="${DROP_NUDGE_INTERVAL_SECS:-1800}"   # 30 minutes default
# Per-channel cooldown: cap how often ANY single channel can be nudged, regardless
# of how many distinct dropped threads/messages it has in one run. Mitigates the
# blast radius of a gateway thread-leak bug (agent replies leaking to channel root)
# by preventing a burst of leaking agent runs in a busy channel. Default 10 minutes.
CHANNEL_COOLDOWN_SECS="${DROP_CHANNEL_COOLDOWN_SECS:-600}"
# Per-incident give-up cap: max nudges for a single (channel, thread) before we
# stop nudging forever and escalate ONCE. Prevents an unresolved thread from
# being nudged on every cron tick indefinitely (observed: one thread nudged 5x
# over 27h). After this many nudges, escalate to the daily thread and set
# gave_up=true so the incident is never nudged again. Default 3.
MAX_NUDGES="${DROP_MAX_NUDGES:-3}"
LOOKBACK_HOURS="${DROP_LOOKBACK_HOURS:-48}"              # scan last N hours (8h for tight cron; 48h default)
PROGRESS_STALE_MINUTES="${DROP_PROGRESS_STALE_MINUTES:-5}"  # dispatched task with no progress
# conversations.replies fetch size (Slack allows up to 1000; default 200 for long threads)
DROP_THREAD_REPLY_LIMIT="${DROP_THREAD_REPLY_LIMIT:-200}"
# Space-separated channel IDs: cold/stale/followup nudges apply only if Jeffrey posted in-thread.
# Unset → default ${SLACK_CHANNEL_ID} (#all-jleechan-ai). Set to "" to disable jeffrey-only gating everywhere.
if [[ "${DROP_JEFFREY_ONLY_CHANNELS+x}" = x ]]; then
  JEFFREY_ONLY_CHANNELS="$DROP_JEFFREY_ONLY_CHANNELS"
else
  JEFFREY_ONLY_CHANNELS="${SLACK_CHANNEL_ID}"
fi
POST_AS_BOT="${DROP_POST_AS_BOT:-1}"                      # 0 = post as user
AGENT_USER_ID="${HERMES_BOT_USER_ID:-U0AEZC7RX1Q}"  # bot user ID for classification
JEFFREY_USER_ID="${JLEECHAN_USER_ID:-U09GH5BR3QU}"        # Jeffrey's Slack user ID (standalone msg detection)
ESCALATION_CHANNEL="${DROP_ESCALATION_CHANNEL:-${SLACK_CHANNEL_ID}}"  # channel for uncertain-classification escalations
# Daily escalation thread ts file — persists so restarts reuse the same daily thread
ESCALATION_TS_FILE="${DROP_ESCALATION_TS_FILE:-${LOG_DIR}/dropped-thread-escalation-$(date +%Y-%m-%d).ts}"

mkdir -p "$LOG_DIR"
mkdir -p "$(dirname "$STATE_FILE")"

# ── Helpers ───────────────────────────────────────────────────────────────────

log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] $*"; }

# resolve_escalation_thread_ts: return the daily escalation thread ts.
# Load from ESCALATION_TS_FILE if it exists; otherwise create a new thread
# and persist the ts so subsequent calls (including after restarts) reuse it.
resolve_escalation_thread_ts() {
  if [[ -f "$ESCALATION_TS_FILE" ]]; then
    local cached_ts
    cached_ts="$(cat "$ESCALATION_TS_FILE" 2>/dev/null | tr -d '[:space:]')"
    if [[ -n "$cached_ts" && "$cached_ts" != "null" ]]; then
      echo "$cached_ts"
      return 0
    fi
  fi
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log "[DRY_RUN] Would create new daily escalation thread in $ESCALATION_CHANNEL" >&2
    echo "dry_run_ts"
    return 0
  fi
  local slack_token response ts
  slack_token="${MCP_MAIL_BOT_TOKEN:-${SLACK_BOT_TOKEN:-${SLACK_BOT_TOKEN:-}}}"
  response="$(curl --silent --show-error --connect-timeout 10 --max-time 30 \
    -X POST "https://slack.com/api/chat.postMessage" \
    -H "Authorization: Bearer $slack_token" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg ch "$ESCALATION_CHANNEL" \
      --arg txt "*Dropped-thread escalations* | $(date +%Y-%m-%d) — daily thread" \
      '{channel: $ch, text: $txt}')" 2>/dev/null)" || response=""
  ts="$(echo "$response" | jq -r '.ts // empty' 2>/dev/null)" || ts=""
  if [[ -n "$ts" && "$ts" != "null" ]]; then
    printf '%s' "$ts" > "$ESCALATION_TS_FILE"
    log "Created daily escalation thread: $ts" >&2
    echo "$ts"
    return 0
  fi
  log "WARNING: could not create daily escalation thread; escalations will post top-level"
  echo ""
  return 1
}

# post_escalation_reply: attempts to post an escalation to the daily thread.
# If posting to the cached thread fails, it deletes the stale cache file,
# resolves a new thread timestamp, and retries. Falls back to channel root if both fail.
post_escalation_reply() {
  local esc_text=$1
  local esc_thread_ts
  esc_thread_ts="$(resolve_escalation_thread_ts)" || esc_thread_ts=""
  
  if [[ -n "$esc_thread_ts" && "$esc_thread_ts" != "null" ]]; then
    local exit_code=0
    post_reply "$ESCALATION_CHANNEL" "$esc_thread_ts" "$esc_text" > /dev/null 2>&1 || exit_code=$?
    if [[ $exit_code -eq 0 ]]; then
      return 0
    elif [[ $exit_code -eq 2 ]]; then
      # If it failed because the thread is not found (stale cache), delete the file and retry
      log "WARNING: escalation thread $esc_thread_ts not found (deleted?). Stale cache? Retrying." >&2
      rm -f "$ESCALATION_TS_FILE"
      esc_thread_ts="$(resolve_escalation_thread_ts)" || esc_thread_ts=""
      if [[ -n "$esc_thread_ts" && "$esc_thread_ts" != "null" ]]; then
        if post_reply "$ESCALATION_CHANNEL" "$esc_thread_ts" "$esc_text" > /dev/null 2>&1; then
          return 0
        fi
      fi
    else
      log "WARNING: failed to post to escalation thread $esc_thread_ts (exit code $exit_code). Not retrying." >&2
    fi
  fi
  
  # Fallback: post directly to the channel root
  log "WARNING: posting escalation to channel root as fallback" >&2
  post_reply "$ESCALATION_CHANNEL" "" "$esc_text" > /dev/null 2>&1 || true
}

# Overlap lock (skip when sourced for tests)
if [[ "${IS_SOURCED:-0}" != "1" ]]; then
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    log "SKIP: another instance running"
    exit 0
  fi
  trap 'rmdir "$LOCK_DIR" >/dev/null 2>&1 || true' EXIT
fi

# Load persisted state
load_state() {
  if [[ -f "$STATE_FILE" ]]; then
    cat "$STATE_FILE" 2>/dev/null || echo '{}'
  else
    echo '{}'
  fi
}

# Save persisted state (atomically)
save_state() {
  local tmp
  tmp="$(mktemp "$STATE_FILE.XXXXXX")"
  cat > "$tmp" < /dev/stdin
  mv "$tmp" "$STATE_FILE"
}

# Normalize a .nudged entry to the object form {last, count, gave_up}, migrating
# legacy bare-ISO-string values (treated as a single prior nudge). Emitted as a
# reusable jq snippet so every accessor migrates old state files identically.
# Usage in jq: ($v | _migrate_nudge) where $v is the raw .nudged[key] value.
_NUDGE_MIGRATE_JQ='def _migrate_nudge:
  if . == null then {last: null, count: 0, gave_up: false}
  elif type == "string" then {last: ., count: 1, gave_up: false}
  else {last: (.last // null), count: (.count // 0), gave_up: (.gave_up // false)}
  end;'

# Read one field (last|count|gave_up) of a migrated nudge record.
nudge_field() {
  local channel_id=$1 thread_ts=$2 field=$3
  local state
  state="$(load_state)"
  jq -rn "$state | $_NUDGE_MIGRATE_JQ
    (.nudged.\"${channel_id}_${thread_ts}\" | _migrate_nudge | .$field) // empty" 2>/dev/null || echo ""
}

# Check if thread was nudged recently (idempotency guard).
# Reads the migrated record's .last so legacy bare-string state still works.
was_nudged_recently() {
  local channel_id=$1 thread_ts=$2
  local last_ts now_sec ts_sec
  last_ts="$(nudge_field "$channel_id" "$thread_ts" last)"
  [[ -z "$last_ts" || "$last_ts" == "null" ]] && return 1
  now_sec="$(date +%s)"
  ts_sec="$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_ts" '+%s' 2>/dev/null)" || return 0
  [[ $((now_sec - ts_sec)) -lt $NUDGE_INTERVAL_SECS ]] && return 0
  return 1
}

# True (0) if this incident has been permanently given up on (escalated already).
nudge_gave_up() {
  local channel_id=$1 thread_ts=$2 gu
  gu="$(nudge_field "$channel_id" "$thread_ts" gave_up)"
  [[ "$gu" == "true" ]] && return 0
  return 1
}

# Echo the current nudge count for this incident (0 if never nudged).
nudge_count() {
  local channel_id=$1 thread_ts=$2 c
  c="$(nudge_field "$channel_id" "$thread_ts" count)"
  [[ -z "$c" || "$c" == "null" ]] && c=0
  echo "$c"
}

# Mark an incident as permanently given up — set gave_up=true atomically,
# migrating any legacy bare-string value in the same pass. No-op in DRY_RUN.
mark_gave_up() {
  local channel_id=$1 thread_ts=$2
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    return 0
  fi
  local state
  state="$(load_state)"
  echo "$state" | jq "$_NUDGE_MIGRATE_JQ
    .nudged[\"${channel_id}_${thread_ts}\"] =
      ((.nudged[\"${channel_id}_${thread_ts}\"] | _migrate_nudge) | .gave_up = true)" \
    | save_state
}

# Check if a channel was nudged within the per-channel cooldown window.
# Caps the blast radius so one busy channel can't trigger a burst of nudges
# (and the gateway thread-leak runs they provoke) within a single run window.
channel_in_cooldown() {
  local channel_id=$1
  local state last_epoch now_sec
  state="$(load_state)"
  last_epoch="$(jq -rn "$state | .channel_last_nudge.\"${channel_id}\" // empty" 2>/dev/null)" || last_epoch=""
  [[ -z "$last_epoch" || "$last_epoch" == "null" ]] && return 1
  now_sec="$(date +%s)"
  [[ $((now_sec - last_epoch)) -lt $CHANNEL_COOLDOWN_SECS ]] && return 0
  return 1
}

# Record only the per-channel cooldown epoch (used by the DRY_RUN path, where
# record_nudge is intentionally not called so the per-thread marker is not set).
# No-op in DRY_RUN so an operator audit does not poison the live state file —
# a real run within the cooldown window would otherwise be wrongly suppressed.
record_channel_nudge() {
  local channel_id=$1
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    return 0
  fi
  local state now_sec
  state="$(load_state)"
  now_sec="$(date +%s)"
  echo "$state" | jq --arg ch "$channel_id" --argjson e "$now_sec" \
    '.channel_last_nudge[$ch] = $e' | save_state
}

# Record a nudge — increments the per-incident count, updates .last, and bumps
# the per-channel cooldown epoch in one atomic state write. Legacy bare-string
# values are migrated to the {last, count, gave_up} object form in the same pass.
record_nudge() {
  local channel_id=$1 thread_ts=$2
  local state now_iso now_sec
  state="$(load_state)"
  now_iso="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  now_sec="$(date +%s)"
  echo "$state" | jq "$_NUDGE_MIGRATE_JQ"' .nudged[$k] =
      ((.nudged[$k] | _migrate_nudge)
        | {last: $v, count: (.count + 1), gave_up: .gave_up})
    | .channel_last_nudge[$ch] = $e' \
    --arg k "${channel_id}_${thread_ts}" --arg v "$now_iso" \
    --arg ch "$channel_id" --argjson e "$now_sec" \
    | save_state
}

# ── Thread analysis ─────────────────────────────────────────────────────────────
#
# Returns 0 (drop detected) if thread meets ALL of:
#   - At least one user message asking agent to do / investigate / build / fix something
#   - Agent replied with an acknowledgment but no real action taken
#   - Agent explicitly admitted not executing ("did not execute", "only sent an ack", etc.)
#   - Thread is > 2 hours old OR last agent reply is > 1h old
#
# Also returns 0 if thread:
#   - Has > 2 user messages in last LOOKBACK_HOURS
#   - Last reply was from agent > 2h ago
#   - No recent agent reply
#
# Returns 1 (no drop) if:
#   - Thread has a recent agent reply (last 30 min)
#   - Agent completed work (PR/commit/posted result)
#   - Thread is purely informational / human-only
#
# Output: JSON with {admitted, user_asked, last_agent_reply, hours_old, action_needed, reason}
analyze_thread() {
  local channel_id=$1 thread_ts=$2 user_msgs=$3 agent_msgs=$4 last_reply_ts=$5 messages_file=$6 agent_user_id=$7

  local hours_old
  hours_old="$(echo "$user_msgs $agent_msgs" | python3 - "$channel_id" "$thread_ts" "$last_reply_ts" "${LOOKBACK_HOURS}" "${agent_user_id}" <<'PYEOF'
import sys, json
channel_id = sys.argv[1]
thread_ts  = sys.argv[2]
last_reply = sys.argv[3]  # ISO timestamp of most recent reply
lookback_h = int(sys.argv[4])

from datetime import datetime, timezone

now_sec = __import__('time').time()
try:
    last_sec = datetime.strptime(last_reply, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
except ValueError:
    last_sec = 0

h_age = (now_sec - last_sec) / 3600 if last_sec else 999
print(round(h_age, 2))
PYEOF
)" 2>/dev/null || hours_old=999

  python3 - "$user_msgs" "$agent_msgs" "$hours_old" "$messages_file" "$agent_user_id" "$PROGRESS_STALE_MINUTES" "$channel_id" "$JEFFREY_USER_ID" "$JEFFREY_ONLY_CHANNELS" <<'PYEOF'
import re
import sys, json, os

user_msgs   = int(sys.argv[1]) if sys.argv[1] else 0
agent_msgs  = int(sys.argv[2]) if sys.argv[2] else 0
hours_old   = float(sys.argv[3]) if sys.argv[3] else 999
messages_file = sys.argv[4]
AGENT_ID    = sys.argv[5]
progress_stale_minutes = int(sys.argv[6]) if sys.argv[6] else 10
progress_stale_h = progress_stale_minutes / 60.0
CHANNEL_ID  = sys.argv[7] if len(sys.argv) > 7 else ""
JEFFREY_ID  = sys.argv[8] if len(sys.argv) > 8 else ""
JEFFREY_ONLY_CHANS = [x for x in (sys.argv[9] if len(sys.argv) > 9 else "").split() if x]
now_sec     = __import__('time').time()

try:
    with open(messages_file) as f:
        messages = json.load(f)
except Exception:
    messages = []

# Build a combined text of all agent replies for phrase scanning
agent_texts = [m.get("text", "") for m in messages if m.get("user") == AGENT_ID]
agent_text  = " ".join(agent_texts).lower()

# Basic temporal ordering (Slack ts are numeric strings)
def ts_float(m):
    try:
        return float(m.get("ts", 0) or 0)
    except Exception:
        return 0.0

agent_msgs_list = [m for m in messages if m.get("user") == AGENT_ID]
user_msgs_list = [m for m in messages if m.get("user") and m.get("user") != AGENT_ID]
last_agent = max(agent_msgs_list, key=ts_float) if agent_msgs_list else None
last_user = max(user_msgs_list, key=ts_float) if user_msgs_list else None
last_agent_ts = ts_float(last_agent) if last_agent else 0.0
last_user_ts = ts_float(last_user) if last_user else 0.0
last_user_text = (last_user.get("text", "").lower() if last_user else "")
user_after_agent = bool(last_user_ts and (last_user_ts > last_agent_ts))
minutes_since_last_user = ((now_sec - last_user_ts) / 60.0) if last_user_ts else 999.0

# Admission phrases — agent explicitly said it didn't act
ADMISSION_PHRASES = [
    "did not execute", "not execute", "only sent an acknowledgment",
    "have not started", "have not done", "have not yet done",
    "i only", "i haven't", "i did not", "i am not currently working on",
    "stalled", "dropped", "forgot to", "missed this message",
]

STRONG_RESULT_PHRASES = [
    "pr #", "pull/", "commit ", "pushed", "posted result",
    "merged", "task complete", "completed the", "finished the", "all done", "shipped", "deployed",
]
PROGRESS_PHRASES = [
    "still working", "in progress", "currently working", "blocked",
    "investigating", "working on", "waiting on", "follow up", "follow-up",
]
TASK_VERBS = [
    "fix", "update", "check", "verify", "merge", "summarize", "summarise",
    "create", "build", "implement", "deploy", "investigate", "review",
    "cleanup", "clean up", "skillify", "do it", "make sure", "ship",
    "run ", "drive", "follow up", "retry", "clone", "test", "summarize",
    "read all", "sign off", "greenlight", "green light", "repro",
]

last_agent_text = (last_agent.get("text", "") or "").lower() if last_agent else ""
admitted = any(phrase in last_agent_text for phrase in ADMISSION_PHRASES)


def _has_delivered(text: str) -> bool:
    """Shipped artifact — merged PR, deploy, or explicit completion (open PR alone is not delivery)."""
    t = (text or "").lower()
    if re.search(r"\b(merged|deployed|landed|shipped)\b", t) and re.search(
        r"pr #?\d+|pull/\d+|github\.com[^/\s]+/[^/\s]+/pull/\d+", t
    ):
        return True
    if re.search(r"pr #\d+.*\bmerged\b|\bmerged\b.*pr #\d+", t):
        return True
    if re.search(r"\b(unsubscribed|unwatched|disabled|turned off)\b", t) and len(t) > 80:
        return True
    if re.search(r"\b(task complete|all done|finished the)\b", t) and len(t) > 100:
        return True
    return False


def _has_open_pr_only(text: str) -> bool:
    t = (text or "").lower()
    return bool(re.search(r"github\.com/[^/\s]+/[^/\s]+/pull/\d+", t)) and not _has_delivered(text)


def _is_redrive_or_nudge(text: str) -> bool:
    """Manual redrives and script nudges are not operator asks."""
    t = (text or "").strip().lower()
    if not t:
        return False
    if "dropped-thread followup" in t or "dropped-thread escalation" in t:
        return True
    if t.startswith("<@") and "dropped-thread" in t:
        return True
    if "missed this during" in t and "outage" in t:
        return True
    if "sorry for the delay" in t and "missed this" in t:
        return True
    if "fresh decisions still on you" in t:
        return True
    if "missed your follow-ups during" in t and "slack outage" in t:
        return True
    return False


def _has_partial(text: str) -> bool:
    """Work started but not delivered — issue filed, spawn failed, blocked dispatch."""
    t = (text or "").lower()
    if re.search(r"github\.com/[^/\s]+/[^/\s]+/issues/\d+", t):
        return True
    if re.search(r"\bissue (filed|created|#\d+)\b", t):
        return True
    if re.search(r"spawn.*failed|failed to (create|spawn|dispatch)|could not create", t):
        return True
    if re.search(r"claim-pr|no pr for|draft pr|pr creation failed", t):
        return True
    if re.search(r"worker wa-\d+.*stalled|status cron.*429|429.*cron", t):
        return True
    if re.search(r"iteration budget exhausted|404 not found.*claim-pr", t):
        return True
    if re.search(r"truncat|cut off mid|investigation incomplete", t):
        return True
    return False


def _is_pending_agent_loop(text: str) -> bool:
    """Agent left an open loop — options, confirm, standing by — not finished work."""
    t = (text or "").strip()
    if not t:
        return False
    tl = t.lower()
    patterns = [
        r"want me to", r"standing by", r"\bconfirm\b", r"green light",
        r"pick (option|one|[a-d1-4])", r"awaiting your", r"which (path|option|one)",
        r"next actions?", r"clarif(y|ication)", r"option [a-d]:",
        r"should i (proceed|create|draft|deploy|run)",
        r"let me know (if|which|when)", r"your call",
    ]
    for pat in patterns:
        if re.search(pat, tl):
            return True
    if len(re.findall(r"^\s*\d+\.", t, re.M)) >= 2 and "?" in t:
        return True
    if len(re.findall(r"option [a-d]:", tl)) >= 2:
        return True
    if tl.rstrip().endswith("?"):
        return True
    return False


def _looks_like_task(text: str) -> bool:
    t = (text or "").lower()
    if not t.strip():
        return False
    if _is_mention_only(text) and len(re.sub(r"<@[^>]+>", "", text).strip()) < 20:
        return False
    if any(v in t for v in TASK_VERBS):
        return True
    if "?" in t:
        return True
    if "<@" in t and len(t.strip()) > 15:
        return True
    return len(t.strip()) >= 40


def _user_acknowledged(text: str) -> bool:
    t = (text or "").lower().strip()
    if re.search(r"^(thanks|thank you|lgtm|merged|done|ok\b|yes\b|go\b|approved|confirm)", t):
        return True
    if re.search(r"\b(looks good|that works|ship it|do it)\b", t):
        return True
    return False


has_delivered = _has_delivered(agent_text)
has_partial_work = _has_partial(agent_text)
has_result = has_delivered  # legacy name for downstream checks
has_progress_reply = any(phrase in agent_text for phrase in PROGRESS_PHRASES)
dispatched_ao = "spawning agent for" in agent_text or ("session " in agent_text and " created" in agent_text)


def _agent_reported_timeout(text: str) -> bool:
    """Hermes/LLM timeout or gateway overload — user-visible failure, not a completed task."""
    return bool(
        re.search(
            r"request timed out|timed out before|timeout before a response|"
            r"gateway timeout|error:\s*timeout|deadline exceeded|\brequest timeout\b|"
            r"\btimed out\b|cluster is under high load|server cluster is under high load|"
            r"2064.*high load|high load.*2064",
            text,
            re.I,
        )
    )


agent_timeout_observed = _agent_reported_timeout(agent_text)

total_bot_chars = sum(len(m.get("text", "")) for m in messages if m.get("user") == AGENT_ID)
bot_gave_substantive_answer = (
    total_bot_chars > 200
    and not has_delivered
    and not admitted
    and not agent_timeout_observed
    and not _is_pending_agent_loop(last_agent_text)
    and not has_partial_work
)

# No user messages → nothing to have dropped
if user_msgs == 0:
    print(json.dumps({"admitted": False, "action_needed": False, "reason": "no user asks", "kind": "none"}))
    sys.exit(0)


def _is_assistant_boilerplate(text: str) -> bool:
    """Skip template intros pasted as the only 'user' message (false-positive cold threads)."""
    t = (text or "").strip().lower()
    if not t:
        return False
    if "hello! i'm claude" in t and "anthropic" in t:
        return True
    if "i'm claude" in t and "ai assistant" in t and "anthropic" in t:
        return True
    if t.startswith("hello! i'm an ai assistant"):
        return True
    return False


def _first_user_msg():
    return min(user_msgs_list, key=ts_float) if user_msgs_list else None


if len(user_msgs_list) == 1 and _is_assistant_boilerplate(user_msgs_list[0].get("text", "")):
    print(json.dumps({
        "admitted": False,
        "action_needed": False,
        "reason": "single user message is assistant boilerplate, not a task",
        "kind": "none",
    }))
    sys.exit(0)


def _is_automated_report(text: str) -> bool:
    """Cron/automation posts (bug hunt, scan summaries, monitor-e2e, canary) — not operator tasks."""
    t = (text or "").strip().lower()
    if not t:
        return False
    if "*daily bug hunt report*" in t or "daily bug hunt report" in t[:800]:
        return True
    if "*repos scanned:*" in t or "*repos scanned*" in t:
        return True
    if "*period:*" in t and "*prs reviewed*" in t:
        return True
    if t.startswith("*weekly") and "report" in t[:120]:
        return True
    # Monitor E2E and canary test messages — automated infrastructure probes
    if "[monitor-e2e]" in t or "[canary" in t:
        return True
    if "canary thread test" in t:
        return True
    if re.search(r"\back[-_][0-9a-f]{4,}\b", t):
        return True
    if "hermes-canary" in t or "canary nonce" in t:
        return True
    if re.search(r"\b(smoke test|e2e test ping|thread test)\b", t):
        return True
    # Monitor ping/status reports — automated health checks, not operator tasks
    if "*hermes monitor*" in t or "*hermes monitor*" in t:
        return True
    if t.startswith("status=") or ("status=" in t[:80] and ("pass=" in t or "fail=" in t)):
        return True
    # Disk usage alert posts from disk_usage_alert.sh
    if "disk-alert" in t or "disk usage threshold" in t:
        return True
    # Self-referential dropped-thread nudges / escalations — prevent recursive loops
    if t.startswith("[dropped-thread followup]") or t.startswith("[dropped-thread escalation]"):
        return True
    return False


def _is_mention_only(text: str) -> bool:
    t = re.sub(r"<@[A-Z0-9]+>", "", (text or "")).strip()
    return len(t) < 4


def _is_progress_or_status_noise(text: str) -> bool:
    """AO babysit/progress/stall lines must not count as answering the operator."""
    t = (text or "").strip().lower()
    if not t:
        return True
    if _is_automated_report(text):
        return True
    if "ao progress report" in t:
        return True
    if t.startswith(":bar_chart:") or t.startswith("babysit "):
        return True
    if "stall alert" in t or "still working" in t:
        return True
    if re.search(r"worker wa-\d+", t) and ("alive" in t or "stalled" in t or "status check" in t):
        return True
    if "rate limited" in t or "usage limit exceeded" in t or "api call failed after" in t:
        return True
    return False


def _agent_answered_since_last_user() -> bool:
    """True if agent delivered or gave a non-pending substantive reply after latest user line."""
    if not last_user:
        return True
    lut = last_user_ts
    replies_after = []
    for m in agent_msgs_list:
        if ts_float(m) <= lut:
            continue
        t = m.get("text", "") or ""
        if _is_progress_or_status_noise(t):
            continue
        replies_after.append(m)
    if not replies_after:
        return False
    combined = " ".join(m.get("text", "") for m in replies_after)
    if _has_delivered(combined):
        return True
    last_sub = max(replies_after, key=ts_float)
    lt = last_sub.get("text", "") or ""
    if _agent_reported_timeout(lt) and len(lt) < 300:
        return False
    if _is_pending_agent_loop(lt):
        return False
    if _has_partial(combined) and not _has_delivered(combined):
        return False
    if _looks_like_task(last_user_text) and len(lt.strip()) >= 80:
        return False
    if len(lt.strip()) >= 80:
        return True
    tl = lt.lower()
    if any(p in tl for p in STRONG_RESULT_PHRASES):
        return True
    return False


def _is_status_broadcast(text: str) -> bool:
    """Jeffrey ops/status posts to the channel — not requests for the agent."""
    t = (text or "").strip().lower()
    if not t:
        return False
    if re.search(r"^(hermes prod|token rotation|:white_check_mark:\s*hermes|gateway verified)", t):
        return True
    if "auth.test ok" in t or "token rotation complete" in t:
        return True
    if "gateway restart in progress" in t and "confirm" in t:
        return True
    if "/invite @hermes" in t or "zero channels" in t or "zero* channels" in t:
        return True
    if t.startswith("i pushed") and "commits now on" in t:
        return True
    return False


def _agent_replies_for_ask(ask_ts: float) -> list:
    """Agent replies scoped to this ask — only until the next user message in-thread."""
    next_user_ts = min(
        (ts_float(u) for u in user_msgs_list if ts_float(u) > ask_ts),
        default=float("inf"),
    )
    out = []
    for m in agent_msgs_list:
        mts = ts_float(m)
        if mts <= ask_ts or mts >= next_user_ts:
            continue
        t = m.get("text", "") or ""
        if _is_progress_or_status_noise(t):
            continue
        out.append(m)
    return out


def _reply_addresses_ask(ask_text: str, reply_text: str) -> bool:
    """Heuristic: reply mentions key terms from the ask (avoids topic-drift false positives)."""
    ask = (ask_text or "").lower()
    reply = (reply_text or "").lower()
    stop = {"please", "hermes", "should", "there", "about", "would", "could", "think", "this", "that", "what", "have", "with"}
    keywords = [w for w in re.findall(r"\b[a-z]{4,}\b", ask) if w not in stop]
    if not keywords:
        return len(reply.strip()) >= 80
    hits = sum(1 for k in keywords if k in reply)
    return hits >= max(1, min(2, len(keywords) // 2))


def _classify_jeffrey_ask(ask_msg) -> str:
    """Per-ask status: delivered | answered | unanswered | partial-* | timeout."""
    ask_ts = ts_float(ask_msg)
    ask_text = ask_msg.get("text", "") or ""
    non_noise = _agent_replies_for_ask(ask_ts)

    for um in user_msgs_list:
        if ts_float(um) <= ask_ts or um is ask_msg:
            continue
        if _user_acknowledged(um.get("text", "")):
            agent_before = [m for m in non_noise if ts_float(m) < ts_float(um)]
            if agent_before:
                return "delivered"

    if not non_noise:
        return "unanswered"

    combined = " ".join(m.get("text", "") for m in non_noise)
    last_sub = max(non_noise, key=ts_float)
    last_text = last_sub.get("text", "") or ""

    if re.search(r"model check:", ask_text, re.I) and len(last_text.strip()) < 160:
        return "answered"

    if re.search(r"\b(unsubscribed|unwatched|unwatch|not subscribed|disabled|turned off)\b", combined) and re.search(
        r"email|notification|github", ask_text, re.I
    ):
        return "delivered"
    if re.search(r"(repos unwatched|future emails from these repos:\s*gone|verification:.*404 not found)", combined, re.I):
        return "delivered"

    if _has_delivered(combined):
        return "delivered"

    if _agent_reported_timeout(combined) and not _has_delivered(combined):
        return "timeout"

    if _is_pending_agent_loop(last_text):
        if _looks_like_task(ask_text) and re.search(
            r"\b(build|scrape|mcp|cli|skillify|implement)\b", ask_text, re.I
        ):
            return "partial-pending-agent"
        if _looks_like_task(ask_text):
            return "partial-pending-agent"
        return "partial-pending-user"

    if _has_partial(combined) and not _has_delivered(combined):
        return "partial-blocked"

    if _has_open_pr_only(combined) and not _has_delivered(combined):
        return "partial-blocked"

    if _looks_like_task(ask_text):
        if len(last_text.strip()) >= 80:
            if not _reply_addresses_ask(ask_text, last_text):
                return "unanswered"
            if re.search(r"(root cause|investigation|findings|analysis|design|recommend)", last_text, re.I):
                return "partial-investigation"
            return "partial-no-delivery"
        return "unanswered"

    if len(last_text.strip()) >= 80 and not _is_pending_agent_loop(last_text):
        if _reply_addresses_ask(ask_text, last_text):
            return "answered"
        return "unanswered"
    if len(last_text.strip()) >= 40 and _reply_addresses_ask(ask_text, last_text):
        return "answered"
    return "unanswered"


def _ask_priority(ask_msg) -> tuple:
    """Prefer substantive task asks over short follow-ups (mailto, 'do it', etc.)."""
    t = (ask_msg.get("text") or "").strip()
    taskish = 1 if _looks_like_task(t) and len(t) >= 60 else 0
    return (taskish, len(t), ts_float(ask_msg))


def _find_open_operator_ask():
    """Return (ask_msg, status, age_minutes) for the highest-priority unresolved operator ask."""
    candidates = []
    for m in user_msgs_list:
        if JEFFREY_ID and m.get("user") != JEFFREY_ID:
            continue
        t = (m.get("text") or "").strip()
        if not t or _is_automated_report(t) or _is_assistant_boilerplate(t):
            continue
        if _is_redrive_or_nudge(t):
            continue
        if _is_status_broadcast(t):
            continue
        if not (_looks_like_task(t) or _looks_like_followup(t.lower())):
            continue
        candidates.append(m)
    best = None
    for ask in sorted(candidates, key=_ask_priority, reverse=True):
        status = _classify_jeffrey_ask(ask)
        age_m = (now_sec - ts_float(ask)) / 60.0
        if status in ("delivered", "answered"):
            continue
        if status == "partial-pending-user" and age_m < 240:
            continue
        if age_m < 5:
            continue
        best = (ask, status, age_m)
        break
    if best:
        return best
    return None, None, None


def _root_automated_report() -> bool:
    if not user_msgs_list:
        return False
    first_u = min(user_msgs_list, key=ts_float)
    return _is_automated_report(first_u.get("text", ""))


def _thread_has_actionable_user_request() -> bool:
    """Cold-thread nudge only if at least one human line looks like a real ask (not boilerplate/report)."""
    min_chars = 4 if CHANNEL_ID.startswith("D") else 40
    for m in user_msgs_list:
        t = (m.get("text") or "").strip()
        if not t:
            continue
        if _is_assistant_boilerplate(t):
            continue
        if _is_automated_report(t):
            continue
        if _is_mention_only(t):
            continue
        if "<@" in t:
            return True
        if len(t) >= min_chars:
            return True
    return False


def _jeffrey_participates() -> bool:
    return bool(JEFFREY_ID and any(m.get("user") == JEFFREY_ID for m in user_msgs_list))


def _jeffrey_only_skip() -> bool:
    return bool(
        JEFFREY_ONLY_CHANS
        and CHANNEL_ID in JEFFREY_ONLY_CHANS
        and JEFFREY_ID
        and not _jeffrey_participates()
    )


def _emit_jeffrey_only_skip():
    print(json.dumps({
        "admitted": False,
        "action_needed": False,
        "reason": "jeffrey-only channel: no message from operator in thread",
        "kind": "none",
    }))
    sys.exit(0)

# User followed up after the last agent reply and has waited long enough.
# This catches "new ask in old thread" cases that were previously missed.
ACTION_VERBS = [
    "fix", "update", "check", "verify", "merge", "drive", "make sure", "follow up",
    "please", "retry", "status", "why", "can you", "do ", "run ", "ship", "review",
]


def _looks_like_followup(text: str) -> bool:
    t = (text or "").lower().strip()
    if not t:
        return False
    if "<@" in t:
        return True
    if "?" in t:
        return True
    if any(v in t for v in ACTION_VERBS):
        return True
    if re.search(
        r"\b(what'?s going on|going on|not the default|should be|should already|logged in)\b",
        t,
    ):
        return True
    return len(t) >= 20


KIND_MAP = {
    "unanswered": "unanswered-after-user",
    "timeout": "timeout-failure",
    "partial-blocked": "partial-blocked",
    "partial-investigation": "partial-investigation",
    "partial-no-delivery": "partial-no-delivery",
    "partial-pending-agent": "partial-pending",
    "partial-pending-user": "pending-user-decision",
}

# ── Per-ask analysis (primary drop detector) ───────────────────────────────
if not _root_automated_report():
    open_ask, open_status, open_age = _find_open_operator_ask()
    if open_ask and open_status:
        if _jeffrey_only_skip():
            _emit_jeffrey_only_skip()
        excerpt = (open_ask.get("text") or "")[:100].replace("\n", " ")
        kind = KIND_MAP.get(open_status, "cold-thread")
        nudge = open_status != "partial-pending-user"
        print(json.dumps({
            "admitted": admitted,
            "action_needed": nudge,
            "reason": f"open operator ask ({open_status}, {open_age:.0f}m): {excerpt}",
            "kind": kind,
            "ask_text": (open_ask.get("text") or "")[:500],
        }))
        sys.exit(0)

# User followed up after the last agent reply and has waited long enough.
if user_after_agent and minutes_since_last_user >= 5 and _looks_like_followup(last_user_text):
    if _root_automated_report():
        print(json.dumps({"admitted": False, "action_needed": False,
                           "reason": "thread root is automated report (monitor/canary)", "kind": "none"}))
        sys.exit(0)
    if _jeffrey_only_skip():
        _emit_jeffrey_only_skip()
    if not _agent_answered_since_last_user():
        print(json.dumps({
            "admitted": admitted,
            "action_needed": True,
            "reason": f"user follow-up pending ({minutes_since_last_user:.0f}m) after last agent reply",
            "kind": "followup-pending",
        }))
        sys.exit(0)

# Operator asked; later agent lines are only progress/429/stall noise — still a drop.
if (
    last_user
    and JEFFREY_ID
    and last_user.get("user") == JEFFREY_ID
    and minutes_since_last_user >= 5
    and _looks_like_followup(last_user_text)
    and not _agent_answered_since_last_user()
):
    if _root_automated_report():
        print(json.dumps({"admitted": False, "action_needed": False,
                           "reason": "thread root is automated report (monitor/canary)", "kind": "none"}))
        sys.exit(0)
    if _jeffrey_only_skip():
        _emit_jeffrey_only_skip()
    print(json.dumps({
        "admitted": admitted,
        "action_needed": True,
        "reason": f"operator ask unanswered ({minutes_since_last_user:.0f}m) — only progress/stall noise after",
        "kind": "unanswered-after-user",
    }))
    sys.exit(0)

# Agent posted timeout / overload / deadline failure — treat as dropped work (not resolved Q&A)
if agent_timeout_observed and not has_delivered and _thread_has_actionable_user_request():
    if _jeffrey_only_skip():
        _emit_jeffrey_only_skip()
    print(json.dumps({
        "admitted": admitted,
        "action_needed": True,
        "reason": "agent reply indicates timeout or overload — counts as dropped thread until retried or explained",
        "kind": "timeout-failure",
    }))
    sys.exit(0)

# Agent replied recently AND completed work → not a drop
if hours_old < 0.5 and has_delivered and not user_after_agent:
    print(json.dumps({"admitted": False, "action_needed": False, "reason": "recent agent reply with delivery", "kind": "none"}))
    sys.exit(0)

# Agent replied recently but didn't complete work AND admission present → nudge
if hours_old < 0.5 and admitted:
    if _root_automated_report():
        print(json.dumps({"admitted": False, "action_needed": False,
                           "reason": "thread root is automated report (monitor/canary)", "kind": "none"}))
        sys.exit(0)
    if _jeffrey_only_skip():
        _emit_jeffrey_only_skip()
    print(json.dumps({"admitted": True, "action_needed": True,
                       "reason": f"recent reply with admission, {hours_old:.1f}h old", "kind": "admission"}))
    sys.exit(0)

# Long-running dispatched task with no progress update.
if dispatched_ao and hours_old >= progress_stale_h and not has_delivered and not has_progress_reply:
    if _root_automated_report():
        print(json.dumps({"admitted": False, "action_needed": False,
                           "reason": "thread root is automated report, not an AO task", "kind": "none"}))
        sys.exit(0)
    if _jeffrey_only_skip():
        _emit_jeffrey_only_skip()
    print(json.dumps({
        "admitted": admitted,
        "action_needed": True,
        "reason": f"dispatched task stale ({hours_old:.1f}h) without progress update",
        "kind": "stale-dispatch",
    }))
    sys.exit(0)

# Cold thread fallback (>2h, no delivery) — only if per-ask missed it
if user_msgs > 0 and hours_old > 2.0 and not has_delivered:
    if _root_automated_report():
        print(json.dumps({"admitted": False, "action_needed": False,
                           "reason": "thread root is automated report, not a task thread", "kind": "none"}))
        sys.exit(0)
    _fu = _first_user_msg()
    if _fu and _is_assistant_boilerplate(_fu.get("text", "")):
        _later = [m for m in user_msgs_list if ts_float(m) > ts_float(_fu)]
        if not _later:
            print(json.dumps({"admitted": False, "action_needed": False,
                               "reason": "assistant boilerplate root with no follow-up, not a task", "kind": "none"}))
            sys.exit(0)
    if not _thread_has_actionable_user_request():
        print(json.dumps({"admitted": False, "action_needed": False,
                           "reason": "no actionable user request (boilerplate/automation only)", "kind": "none"}))
        sys.exit(0)
    if has_partial_work and not has_delivered:
        if _jeffrey_only_skip():
            _emit_jeffrey_only_skip()
        print(json.dumps({"admitted": admitted, "action_needed": True,
                           "reason": f"cold thread {hours_old:.1f}h, partial work without delivery", "kind": "partial-blocked"}))
        sys.exit(0)
    if bot_gave_substantive_answer and not _looks_like_task(last_user_text):
        print(json.dumps({"admitted": admitted, "action_needed": False,
                           "reason": f"resolved Q&A ({total_bot_chars} chars), not a task thread", "kind": "none"}))
        sys.exit(0)
    if _jeffrey_only_skip():
        _emit_jeffrey_only_skip()
    print(json.dumps({"admitted": admitted, "action_needed": True,
                       "reason": f"cold thread {hours_old:.1f}h, no delivery found", "kind": "cold-thread"}))
    sys.exit(0)

print(json.dumps({"admitted": admitted, "action_needed": False,
                   "reason": "thread active, recent reply, or delivery present", "kind": "none"}))
PYEOF
}
# SLACK_TOKEN (reads): Hermes bot primary (broader channel access).
# post_reply (writes): MCP mail bot (U0A4G7LDJ4R) primary, Hermes fallback.
resolve_mcp_mail_token() {
  local creds="${HOME}/.mcp_mail/credentials.json"
  if [[ -f "$creds" ]] && command -v python3 >/dev/null 2>&1; then
    python3 - "$creds" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    print(d.get("SLACK_BOT_TOKEN", ""))
except Exception:
    pass
PYEOF
  fi
}

# MCP mail bot token (from env or credentials file)
MCP_MAIL_BOT_TOKEN="${MCP_MAIL_SLACK_TOKEN:-$(resolve_mcp_mail_token)}"

# ── Slack API via curl ──────────────────────────────────────────────────────────
# Uses MCP mail bot (U0A4G7LDJ4R) for posting nudge messages.
# Falls back to Hermes bot (U0AEZC7RX1Q) only if MCP mail bot unavailable.
SLACK_TOKEN="${SLACK_BOT_TOKEN:-${SLACK_BOT_TOKEN:-${MCP_MAIL_BOT_TOKEN:-}}}"

resolve_channels() {
  # Dynamically fetch all channels the bot is a member of via conversations.list.
  # Paginates until all channels are collected. Falls back to empty on error.
  [[ -z "$SLACK_TOKEN" ]] && return
  python3 - "$SLACK_TOKEN" <<'PYEOF'
import sys, json, urllib.request, urllib.parse

token = sys.argv[1]
ids = []
cursor = ""
while True:
    params = {"types": "public_channel,private_channel", "exclude_archived": "true",
              "limit": "200"}
    if cursor:
        params["cursor"] = cursor
    url = "https://slack.com/api/conversations.list?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            d = json.loads(r.read())
    except Exception:
        break
    if not d.get("ok"):
        break
    ids += [ch["id"] for ch in d.get("channels", []) if ch.get("is_member")]
    cursor = d.get("response_metadata", {}).get("next_cursor", "")
    if not cursor:
        break
print(" ".join(ids))
PYEOF
}

DEFAULT_CHANNELS="${DROP_CHANNELS:-$(resolve_channels)}"

# When DROP_SCAN_ALL!=1 (default), scan only operator priority channels + DM — avoids
# post-reinstall @hermes invite noise across every bot-member channel.
DROP_SCAN_ALL="${DROP_SCAN_ALL:-0}"
DROP_PRIORITY_CHANNELS="${DROP_PRIORITY_CHANNELS:-${SLACK_CHANNEL_ID} C0AH3RY3DK6 C0AJ3SD5C79 C0ALSKLU9KM ${SLACK_CHANNEL_ID}}"
if [[ "$DROP_SCAN_ALL" != "1" && -z "${DROP_CHANNELS:-}" ]]; then
  DEFAULT_CHANNELS="$DROP_PRIORITY_CHANNELS"
fi

# Channels excluded from dropped-thread scanning.
# Default excludes C0AKNDEARS5 (disk-alert channel — only automated reports, never real work).
# Semantics: unset → use default | explicitly set (incl. empty) → use that list.
if [[ "${DROP_EXCLUDE_CHANNELS+x}" = x ]]; then
  EXCLUDE_CHANNELS="$DROP_EXCLUDE_CHANNELS"
else
  EXCLUDE_CHANNELS="C0AKNDEARS5"  # disk-alert channel — only automated disk reports
fi
filter_channels() {
  local result=""
  for ch in $DEFAULT_CHANNELS; do
    local excluded=0
    for ex in $EXCLUDE_CHANNELS; do
      [[ "$ch" == "$ex" ]] && excluded=1 && break
    done
    [[ "$excluded" == "0" ]] && result="${result}${result:+ }$ch"
  done
  echo "$result"
}

# Always include DM channel — conversations.list only returns C/G-prefixed channels.
# DM channels (D-prefix) are never in that list, so we add it unless already present.
DM_CHANNEL="${JLEECHAN_DM_CHANNEL:-${SLACK_CHANNEL_ID}}"
case " ${DEFAULT_CHANNELS} " in
  *" ${DM_CHANNEL} "*) : ;;  # already present
  *) DEFAULT_CHANNELS="${DEFAULT_CHANNELS} ${DM_CHANNEL}" ;;
esac

# Always merge priority operator channels when scanning all bot-member channels.
if [[ "$DROP_SCAN_ALL" == "1" || -n "${DROP_CHANNELS:-}" ]]; then
  for _pch in $DROP_PRIORITY_CHANNELS; do
    case " ${DEFAULT_CHANNELS} " in
      *" ${_pch} "*) : ;;
      *) DEFAULT_CHANNELS="${DEFAULT_CHANNELS} ${_pch}" ;;
    esac
  done
fi
SCAN_CHANNELS="$(filter_channels)"

fetch_thread_messages() {
  local channel_id=$1 thread_ts=$2
  local response
  response="$(curl --silent --show-error \
    --connect-timeout 10 --max-time 30 \
    --get "https://slack.com/api/conversations.replies" \
    --data-urlencode "channel=${channel_id}" \
    --data-urlencode "ts=${thread_ts}" \
    --data-urlencode "limit=${DROP_THREAD_REPLY_LIMIT}" \
    -H "Authorization: Bearer $SLACK_TOKEN" 2>/dev/null)" || return 1
  echo "$response" | jq -ce '
    if .ok == true then (.messages // [])
    else error(.error // "slack_api_error")
    end
  ' 2>/dev/null || return 1
}

fetch_recent_threads() {
  local channel_id=$1
  local oldest_ts now_sec all_threads=""
  now_sec="$(date +%s)"
  oldest_ts=$((now_sec - LOOKBACK_HOURS * 3600))

  local cursor=""
  while true; do
    local response
    response="$(curl --silent --show-error \
      --connect-timeout 10 --max-time 30 \
      -X POST "https://slack.com/api/conversations.history" \
      -H "Authorization: Bearer $SLACK_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg ch "$channel_id" --arg oldest "$oldest_ts" \
        --argjson limit 200 \
        --arg cur "$cursor" \
        '{channel: $ch, oldest: $oldest, limit: $limit}
         + (if ($cur|length)>0 then {cursor: $cur} else {} end)')" 2>/dev/null)" || return 1

    local page
    page="$(echo "$response" | jq -r '
      (.messages[] | select(.reply_count > 0) | .ts),
      (.messages[] | select(.thread_ts != null and .thread_ts != .ts) | .thread_ts)
    ' 2>/dev/null)" || return 1
    all_threads="${all_threads}"$'\n'"${page}"

    cursor="$(echo "$response" | jq -r '.response_metadata.next_cursor // empty' 2>/dev/null)"
    [[ -z "$cursor" ]] && break
  done

  echo "$all_threads" | awk 'NF > 0' | sort -u
}

# Fetch standalone (non-threaded) messages from a user that have no agent reply.
# These are missed by fetch_recent_threads because reply_count == 0.
# Returns: one ts per line (Jeffrey messages with no bot follow-up within 30 min).
fetch_standalone_user_messages() {
  local channel_id=$1
  local oldest_ts now_sec cutoff_ts
  now_sec="$(date +%s)"
  oldest_ts=$((now_sec - LOOKBACK_HOURS * 3600))
  cutoff_ts=$((now_sec - NUDGE_INTERVAL_SECS))  # must be > 30 min old

  local response
  response="$(curl --silent --show-error \
    --connect-timeout 10 --max-time 30 \
    -X POST "https://slack.com/api/conversations.history" \
    -H "Authorization: Bearer $SLACK_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg ch "$channel_id" --arg oldest "$oldest_ts" \
      --argjson limit 200 \
      '{channel: $ch, oldest: $oldest, limit: $limit}')" 2>/dev/null)" || return 1

  # Find Jeffrey's standalone roots (reply_count==0) older than NUDGE_INTERVAL_SECS.
  # Also check that no agent message appeared within 30 min after the Jeffrey message.
  # Use a temp file to pass response — pipe+heredoc conflict (both claim stdin).
  local _tmpf
  _tmpf="$(mktemp /tmp/slack-standalone.XXXXXX)"
  echo "$response" > "$_tmpf"
  python3 - "$JEFFREY_USER_ID" "$AGENT_USER_ID" "$cutoff_ts" "$_tmpf" <<'PYEOF'
import sys, json, os, re
jeffrey_id = sys.argv[1]
agent_id   = sys.argv[2]
cutoff     = float(sys.argv[3])
tmpf       = sys.argv[4]


def _is_automated_report(text: str) -> bool:
    t = (text or "").strip().lower()
    if not t:
        return False
    if "*daily bug hunt report*" in t or "daily bug hunt report" in t[:800]:
        return True
    if "*repos scanned:*" in t or "*repos scanned*" in t:
        return True
    if "*period:*" in t and "*prs reviewed*" in t:
        return True
    if t.startswith("*weekly") and "report" in t[:120]:
        return True
    # Monitor E2E and canary test messages — automated infrastructure probes
    if "[monitor-e2e]" in t or "[canary" in t:
        return True
    if "canary thread test" in t:
        return True
    if re.search(r"\back[-_][0-9a-f]{4,}\b", t):
        return True
    if "hermes-canary" in t or "canary nonce" in t:
        return True
    if re.search(r"\b(smoke test|e2e test ping|thread test)\b", t):
        return True
    # Monitor ping/status reports — automated health checks, not operator tasks
    if "*hermes monitor*" in t or "*hermes monitor*" in t:
        return True
    if t.startswith("status=") or ("status=" in t[:80] and ("pass=" in t or "fail=" in t)):
        return True
    # Disk usage alert posts from disk_usage_alert.sh
    if "disk-alert" in t or "disk usage threshold" in t:
        return True
    # Self-referential dropped-thread nudges / escalations — prevent recursive loops
    if t.startswith("[dropped-thread followup]") or t.startswith("[dropped-thread escalation]"):
        return True
    return False

try:
    with open(tmpf) as f:
        data = json.load(f)
    msgs = data.get("messages", [])
except Exception:
    sys.exit(0)
finally:
    try:
        os.unlink(tmpf)
    except Exception:
        pass

# Build a sorted list with timestamps as floats
for m in msgs:
    try:
        m["_ts"] = float(m.get("ts", 0))
    except Exception:
        m["_ts"] = 0.0

msgs_sorted = sorted(msgs, key=lambda m: m["_ts"])

for i, m in enumerate(msgs_sorted):
    if m.get("user") != jeffrey_id:
        continue
    if m.get("subtype"):  # skip joins, leaves, bot_messages, etc.
        continue
    if (m.get("reply_count") or 0) > 0:
        continue  # has thread replies — already handled by fetch_recent_threads
    if m.get("thread_ts") and m["thread_ts"] != m.get("ts"):
        continue  # it's a reply inside another thread, not a root
    if m["_ts"] > cutoff:
        continue  # too recent — not a drop yet

    # Check if the agent replied in the channel within 30 min after this message
    window_end = m["_ts"] + 1800  # 30 min
    agent_replied = any(
        n.get("user") == agent_id and n["_ts"] > m["_ts"] and n["_ts"] <= window_end
        for n in msgs_sorted[i+1:]
    )
    if not agent_replied:
        if _is_automated_report(m.get("text", "")):
            continue
        safe_text = (m.get("text") or "").replace("\t", " ").replace("\n", " ")[:300]
        print(m["ts"] + "\t" + safe_text)
PYEOF
}

post_reply() {
  local channel_id=$1 thread_ts=$2 text=$3
  local as_user=${POST_AS_BOT:-1}
  local token response

  # DM channels (D-prefix) require user identity — bots can't write to DMs they didn't open.
  # Source ~/.profile to pick up SLACK_USER_TOKEN if not already in env.
  if [[ "$channel_id" == D* ]]; then
    if [[ -z "${SLACK_USER_TOKEN:-}" ]]; then
      # shellcheck source=/dev/null
      source "${HOME}/.profile" 2>/dev/null || true
    fi
    token="${SLACK_USER_TOKEN:-}"
  elif [[ "$as_user" == "0" ]]; then
    token="${SLACK_USER_TOKEN:-}"
  else
    # Prefer MCP mail bot token for dropped-thread nudges
    token="${MCP_MAIL_BOT_TOKEN:-${SLACK_BOT_TOKEN:-${SLACK_BOT_TOKEN:-}}}"
  fi

  local payload
  if [[ -n "$thread_ts" && "$thread_ts" != "null" ]]; then
    payload="$(jq -n --arg ch "$channel_id" --arg ts "$thread_ts" --arg txt "$text" \
      '{channel: $ch, text: $txt, thread_ts: $ts}')"
  else
    payload="$(jq -n --arg ch "$channel_id" --arg txt "$text" \
      '{channel: $ch, text: $txt}')"
  fi
  response="$(curl --silent --show-error --fail \
    --connect-timeout 10 --max-time 30 \
    -X POST "https://slack.com/api/chat.postMessage" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "$payload")" || response=""

  if [[ -n "$response" ]]; then
    if echo "$response" | jq -e '.ok == true' > /dev/null 2>&1; then
      return 0
    fi
    if echo "$response" | jq -e '.error == "thread_not_found"' > /dev/null 2>&1; then
      return 2
    fi
  fi
  return 1
}

# Classify a thread context via LLM to determine if it warrants a nudge.
# Routes through the local Hermes gateway (http://127.0.0.1:HERMES_PORT/v1/chat/completions)
# so provider selection is centrally managed — no hardcoded wafer dependency.
# Returns: real_work | testing | uncertain
# Fails open (real_work) if gateway unavailable or response unrecognized.
classify_thread_with_llm() {
  local context="$1"
  local hermes_port="${HERMES_PORT:-8642}"
  local hermes_url="http://127.0.0.1:${hermes_port}/v1/chat/completions"

  # Skip classification if Hermes gateway is not reachable
  if ! curl -sf --connect-timeout 3 "http://127.0.0.1:${hermes_port}/health" > /dev/null 2>&1; then
    echo "real_work"
    return 0
  fi

  local prompt="You are classifying Slack thread content to decide if it needs agent follow-up.

Thread context:
${context}

Classify this as exactly one of:
- real_work: A genuine operator request, task, bug report, or work discussion
- testing: A test message, canary ping, automated report, monitoring probe, or throwaway message
- uncertain: Ambiguous — cannot determine clearly without more context

Respond with ONLY the single classification word (real_work, testing, or uncertain), nothing else."

  local response classification
  response=$(curl --silent --show-error \
    --connect-timeout 10 --max-time 30 \
    -X POST "$hermes_url" \
    -H "Content-Type: application/json" \
    -H "X-Hermes-New-Session: true" \
    -d "$(jq -n --arg p "$prompt" \
      '{messages:[{role:"user",content:$p}],max_tokens:10,temperature:0}')" \
    2>/dev/null) || { echo "real_work"; return 0; }

  classification=$(echo "$response" | \
    jq -r '.choices[0].message.content // ""' 2>/dev/null | \
    tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')

  case "$classification" in
    real_work|testing|uncertain) echo "$classification" ;;
    *) echo "real_work" ;;
  esac
}

# Source guard — after functions are defined so tests can source and call them
[[ "${IS_SOURCED:-0}" == "1" ]] && return 0

# ── Main ───────────────────────────────────────────────────────────────────────

log "Starting dropped-thread-followup (lookback: ${LOOKBACK_HOURS}h)"

[[ -z "$SLACK_TOKEN" ]] && { log "ERROR: SLACK_BOT_TOKEN (or SLACK_BOT_TOKEN) not set"; exit 1; }

actioned=0 skipped=0

for channel in $SCAN_CHANNELS; do
  log "Checking channel $channel..."

  threads=$(fetch_recent_threads "$channel" 2>/dev/null) || { log "  Failed to fetch threads for $channel"; continue; }

  while IFS= read -r thread_ts; do
    [[ -z "$thread_ts" ]] && continue

    # Idempotency guard
    if was_nudged_recently "$channel" "$thread_ts"; then
      ((skipped++)) || true
      log "  SKIP (nudged recently): $channel $thread_ts"
      continue
    fi

    # Per-incident give-up — never nudge a thread we already escalated on
    if nudge_gave_up "$channel" "$thread_ts"; then
      ((skipped++)) || true
      log "  SKIP (gave up — already escalated): $channel $thread_ts"
      continue
    fi

    # Per-incident cap — after DROP_MAX_NUDGES, escalate ONCE then stop forever
    if [[ "$(nudge_count "$channel" "$thread_ts")" -ge "$MAX_NUDGES" ]]; then
      permalink="https://jleechanai.slack.com/archives/${channel}/p${thread_ts//./}"
      esc_text="<@${JEFFREY_USER_ID}> [Dropped-thread escalation] Gave up after ${MAX_NUDGES} nudges with no resolution — needs your review: ${permalink}"
      if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log "DRY_RUN: would escalate (max nudges reached) and give up: $channel $thread_ts"
      else
        post_escalation_reply "$esc_text"
        mark_gave_up "$channel" "$thread_ts"
        log "  ESCALATED + GAVE UP (max nudges $MAX_NUDGES): $channel $thread_ts"
      fi
      ((skipped++)) || true
      continue
    fi

    # Per-channel cooldown — cap nudge blast radius for a busy channel
    if channel_in_cooldown "$channel"; then
      ((skipped++)) || true
      log "  SKIP (channel cooldown): $channel"
      continue
    fi

    # Fetch thread messages
    messages=$(fetch_thread_messages "$channel" "$thread_ts" 2>&1) || {
      log "  WARN: conversations.replies failed for $channel $thread_ts: $(echo "$messages" | head -1)"
      continue
    }

    # Count messages by type
    user_msg_count=$(echo "$messages" | jq --arg agent "$AGENT_USER_ID" '[.[] | select(.user != null and .user != $agent)] | length' 2>/dev/null || echo 0)
    agent_msg_count=$(echo "$messages" | jq --arg agent "$AGENT_USER_ID" '[.[] | select(.user == $agent)] | length' 2>/dev/null || echo 0)
    last_reply_ts=$(echo "$messages" | jq -r '.[-1].ts' 2>/dev/null || echo "")

    # Convert Slack ts to ISO
    last_reply_iso=""
    if [[ -n "$last_reply_ts" ]]; then
      last_reply_iso=$(date -r "${last_reply_ts%.*}" -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "")
    fi

    # Analyze (messages via temp file — long threads exceed argv limits)
    _msg_tmp="$(mktemp /tmp/dropped-msgs.XXXXXX)"
    echo "$messages" > "$_msg_tmp"
    analysis=$(analyze_thread "$channel" "$thread_ts" "$user_msg_count" "$agent_msg_count" "$last_reply_iso" "$_msg_tmp" "$AGENT_USER_ID")
    rm -f "$_msg_tmp"
    needs_action=$(echo "$analysis" | jq -r '.action_needed' 2>/dev/null || echo "false")

    if [[ "$needs_action" != "true" ]]; then
      reason=$(echo "$analysis" | jq -r '.reason' 2>/dev/null || echo "unknown")
      log "  OK ($reason): $channel $thread_ts"
      continue
    fi

    reason=$(echo "$analysis" | jq -r '.reason' 2>/dev/null || echo "unknown")
    kind=$(echo "$analysis" | jq -r '.kind // "cold-thread"' 2>/dev/null || echo "cold-thread")

    # Context for nudge: prefer ask_text from analysis, else Jeffrey's latest message
    original_msg=$(echo "$analysis" | jq -r '.ask_text // empty' 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | cut -c1-500)
    if [[ -z "$original_msg" ]]; then
      original_msg=$(echo "$messages" | jq -r --arg agent "$AGENT_USER_ID" --arg j "$JEFFREY_USER_ID" '
        [ .[] | select(.user != null and .user != $agent) ] as $all
        | ($all | map(select(.user == $j)) | sort_by(.ts | tonumber)) as $jl
        | if ($jl | length) > 0 then $jl[-1] else ($all | sort_by(.ts | tonumber) | last) end
        | .text // empty
      ' 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | cut -c1-500)
    fi

    # LLM classification — skip testing threads, escalate uncertain to Jeffrey
    llm_context="Channel: ${channel}
Kind: ${kind}
Reason: ${reason}
Message excerpt: ${original_msg:-[empty]}"
    classification=$(classify_thread_with_llm "$llm_context")
    if [[ "$classification" == "testing" ]]; then
      log "  SKIP (LLM: testing): $channel $thread_ts"
      continue
    elif [[ "$classification" == "uncertain" ]]; then
      permalink="https://jleechanai.slack.com/archives/${channel}/p${thread_ts//./}"
      esc_text="<@${JEFFREY_USER_ID}> [Dropped-thread escalation] Uncertain thread needs your review: ${permalink} (reason: ${reason})"
      if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log "DRY_RUN: would escalate uncertain thread: $permalink"
      else
        post_escalation_reply "$esc_text"
        log "  ESCALATED (LLM: uncertain): $channel $thread_ts"
      fi
      continue
    fi

    # Build nudge message — prefix with @agent so allow_bots:mentions passes it through
    if [[ "$kind" == "stale-dispatch" ]]; then
      nudge_text="<@${AGENT_USER_ID}> [Dropped-thread followup] This dispatched AO task has been running with no progress update. "
      nudge_text+="Please post a concise status update in-thread now (current step, blocker if any, and next checkpoint). "
      nudge_text+="If work is complete, post proof links (PR/commit/artifact) instead."
    elif [[ "$kind" == "timeout-failure" ]]; then
      nudge_text="<@${AGENT_USER_ID}> [Dropped-thread followup] This thread shows a gateway/model timeout or overload — that counts as a dropped run. "
      nudge_text+="Please retry with a smaller step, lower concurrency, or post the blocker. "
      nudge_text+="Original ask: \"${original_msg:-[could not retrieve]}\"."
    else
      nudge_text="<@${AGENT_USER_ID}> [Dropped-thread followup] This thread appears to have gone cold. "
      nudge_text+="Original request: \"${original_msg:-[could not retrieve]}\". "
      nudge_text+="Please provide a status update on the requested action, or confirm if work is complete. "
      nudge_text+="If you admitted to not executing something, please do so now and either complete the work "
      nudge_text+="or explain the blocker."
    fi

    if [[ "${DRY_RUN:-0}" == "1" ]]; then
      log "DRY_RUN: would nudge $channel $thread_ts ($reason): $nudge_text"
      record_channel_nudge "$channel"
      ((actioned++)) || true
      continue
    fi

    if post_reply "$channel" "$thread_ts" "$nudge_text"; then
      record_nudge "$channel" "$thread_ts"
      log "  NUDGED: $channel $thread_ts"
    else
      log "  ERROR: failed to nudge $channel $thread_ts"
      continue
    fi
    ((actioned++)) || true

  done <<< "$threads"
done

# ── Standalone message scan ────────────────────────────────────────────────────
# Catches Jeffrey messages with reply_count==0 that never got a bot reply.
# These are invisible to fetch_recent_threads.

log "Scanning for standalone unanswered messages..."

for channel in $SCAN_CHANNELS; do
  # Skip DM channels (D-prefix) in standalone scan — bot nudges posted via SLACK_USER_TOKEN
  # appear as Jeffrey messages, creating a recursive self-nudge loop.
  [[ "$channel" == D* ]] && { log "  SKIP standalone (DM channel): $channel"; continue; }

  log "  Standalone scan: $channel"

  standalone_msgs=$(fetch_standalone_user_messages "$channel" 2>/dev/null) || {
    log "  WARN: standalone scan failed for $channel"
    continue
  }

  while IFS=$'\t' read -r msg_ts msg_text; do
    [[ -z "$msg_ts" ]] && continue

    if was_nudged_recently "$channel" "$msg_ts"; then
      ((skipped++)) || true
      log "  SKIP standalone (nudged recently): $channel $msg_ts"
      continue
    fi

    # Per-incident give-up — never nudge a message we already escalated on
    if nudge_gave_up "$channel" "$msg_ts"; then
      ((skipped++)) || true
      log "  SKIP standalone (gave up — already escalated): $channel $msg_ts"
      continue
    fi

    # Per-incident cap — after DROP_MAX_NUDGES, escalate ONCE then stop forever
    if [[ "$(nudge_count "$channel" "$msg_ts")" -ge "$MAX_NUDGES" ]]; then
      permalink="https://jleechanai.slack.com/archives/${channel}/p${msg_ts//./}"
      esc_text="<@${JEFFREY_USER_ID}> [Dropped-thread escalation] Gave up after ${MAX_NUDGES} nudges with no resolution — needs your review: ${permalink}"
      if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log "DRY_RUN: would escalate standalone (max nudges reached) and give up: $channel $msg_ts"
      else
        post_escalation_reply "$esc_text"
        mark_gave_up "$channel" "$msg_ts"
        log "  ESCALATED + GAVE UP standalone (max nudges $MAX_NUDGES): $channel $msg_ts"
      fi
      ((skipped++)) || true
      continue
    fi

    # Per-channel cooldown — cap nudge blast radius for a busy channel
    if channel_in_cooldown "$channel"; then
      ((skipped++)) || true
      log "  SKIP (channel cooldown): $channel"
      continue
    fi

    # LLM classification — skip testing messages, escalate uncertain to Jeffrey
    standalone_context="Channel: ${channel}
Message: ${msg_text:-[empty]}"
    classification=$(classify_thread_with_llm "$standalone_context")
    if [[ "$classification" == "testing" ]]; then
      log "  SKIP standalone (LLM: testing): $channel $msg_ts"
      continue
    elif [[ "$classification" == "uncertain" ]]; then
      permalink="https://jleechanai.slack.com/archives/${channel}/p${msg_ts//./}"
      esc_text="<@${JEFFREY_USER_ID}> [Dropped-thread escalation] Uncertain standalone message needs your review: ${permalink}"
      if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log "DRY_RUN: would escalate uncertain standalone: $permalink"
      else
        post_escalation_reply "$esc_text"
        log "  ESCALATED standalone (LLM: uncertain): $channel $msg_ts"
      fi
      continue
    fi

    nudge_text="<@${AGENT_USER_ID}> [Dropped-thread followup] You sent a message in this channel that never received a reply. "
    nudge_text+="Please respond to Jeffrey's message (ts: ${msg_ts}) now."

    if [[ "${DRY_RUN:-0}" == "1" ]]; then
      log "DRY_RUN: would nudge standalone $channel $msg_ts"
      record_channel_nudge "$channel"
      ((actioned++)) || true
      continue
    fi

    if post_reply "$channel" "$msg_ts" "$nudge_text"; then
      record_nudge "$channel" "$msg_ts"
      log "  NUDGED standalone: $channel $msg_ts"
    else
      log "  ERROR: failed to nudge standalone $channel $msg_ts"
      continue
    fi
    ((actioned++)) || true

  done <<< "$standalone_msgs"
done

log "Done — actioned=$actioned skipped=$skipped"
