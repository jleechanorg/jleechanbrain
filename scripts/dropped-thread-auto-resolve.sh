#!/usr/bin/env bash
# dropped-thread-auto-resolve.sh
#
# Companion to dropped-thread-followup.sh. Before the main script runs,
# scan the .nudged state for threads that have been "answered" by the agent
# (a status reply with proof, no user follow-up question) and mark them
# gave_up=true so the main script doesn't keep flagging them as pending.
#
# Why: dropped-thread-followup.sh only sets gave_up=true after MAX_NUDGES=3,
# but agents often answer within the first nudge. Without this auto-resolve,
# state accumulates stale "pending" entries that the roadmap-report cron
# picks up as actionable threads, producing noise.
#
# Run from: slack-thread-roadmap-report.sh (calls this first).
# Idempotency: calls mark_gave_up (no-op if already gave_up). Safe to re-run.
#
# DRY: reuses the existing state migration + mark_gave_up helper from
# dropped-thread-followup.sh by sourcing it with IS_SOURCED=1. No new
# state-touching logic; no copy of jq snippets, no parallel Python parser.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin${PATH:+:$PATH}"

DROP_SCRIPT="${DROP_SCRIPT:-$HOME/.smartclaw/scripts/dropped-thread-followup.sh}"
if [[ ! -x "$DROP_SCRIPT" ]]; then
  echo "dropped-thread-followup.sh not found at $DROP_SCRIPT; cannot source helpers" >&2
  exit 1
fi

# Source the dropped-thread-followup.sh to get mark_gave_up + state helpers
# without running its main body. IS_SOURCED=1 short-circuits main; set trap
# '' PIPE is re-set inside the source so we don't need to do it here.
IS_SOURCED=1
# shellcheck disable=SC1090
source "$DROP_SCRIPT"

# Resolve Slack token.
TOKEN="${SLACK_BOT_TOKEN:-}"
if [[ -z "$TOKEN" ]]; then
  TOKEN="$(bash -c 'source ~/.bashrc 2>/dev/null; echo -n "${SLACK_BOT_TOKEN:-}"' 2>/dev/null || true)"
fi
if [[ -z "$TOKEN" ]]; then
  echo "no SLACK token; cannot fetch threads for auto-resolve check" >&2
  exit 0
fi
if [[ ! -f "$STATE_FILE" ]]; then
  echo "no state file at $STATE_FILE; skipping auto-resolve" >&2
  exit 0
fi

# Snapshot the nudge keys we need to consider (we mutate state via mark_gave_up
# while iterating, so we can't iterate the live state). Filter to entries
# that look "pending" (count > 0, not yet gave_up, modified in last 24h).
KEYS=$(STATE="$(load_state)" python3 -c '
import json, os, sys, time
from datetime import datetime
state = json.loads(os.environ["STATE"])
now = time.time()
day = now - 24*3600
for key, v in (state.get("nudged") or {}).items():
  if not (isinstance(v, dict) and v.get("count", 0) > 0 and not v.get("gave_up", False)):
    continue
  try:
    ts = datetime.fromisoformat(v["last"].replace("Z", "+00:00")).timestamp()
  except Exception:
    continue
  if ts < day:
    continue
  print(key)
')
if [[ -z "$KEYS" ]]; then
  exit 0
fi

PROOF_PAT='(https://github\.com/[^\s)]+|merged|shipped|landed|:white_check_mark:|\*Status|\*PR #|complete ✓|self-improvement review|skill .* created)'
QUESTION_PAT='(\?$|\?[\s\n]|<@U[A-Z0-9]+>|could you|\bcan you\b|\bplease\b|\bdo you\b|\bwould you\b)'

examined=0
resolved=0
for key in $KEYS; do
  ch="${key%%_*}"
  ts="${key#*_}"
  # Skip if already gave_up (race: another process may have done it)
  if nudge_gave_up "$ch" "$ts"; then
    continue
  fi
  examined=$((examined + 1))

  url="https://slack.com/api/conversations.replies?channel=${ch}&ts=${ts}&limit=15"
  msgs_json=$(curl --silent --show-error --connect-timeout 10 --max-time 30 \
    -H "Authorization: Bearer $TOKEN" "$url" 2>/dev/null || echo '{}')
  if [[ -z "$msgs_json" || "$msgs_json" == "{}" ]]; then
    continue
  fi

  # Decide resolved/pending in Python (re uses Python already; same logic
  # lives in dropped-thread-auto-resolve.sh v1 and is unchanged).
  decision=$(MSGS="$msgs_json" python3 -c '
import json, os, re
msgs = json.loads(os.environ["MSGS"]).get("messages", [])
if not msgs:
  print("skip"); raise SystemExit
agent_user = "U0AEZC7RX1Q"
user_msgs = [m for m in msgs if m.get("user") and m.get("user") != agent_user and not m.get("bot_id")]
latest_agent = None
for m in reversed(msgs):
  if m.get("user") == agent_user or m.get("bot_id"):
    latest_agent = m
    break
if not latest_agent:
  print("skip"); raise SystemExit
text = latest_agent.get("text", "")
ts = float(latest_agent.get("ts", 0))
proof = bool(re.search(r"'"$PROOF_PAT"'", text, re.IGNORECASE))
question = bool(re.search(r"'"$QUESTION_PAT"'", text, re.IGNORECASE))
user_after = any(float(m.get("ts", 0)) > ts for m in user_msgs)
print("resolve" if (proof and not question and not user_after) else "skip")
')

  if [[ "$decision" == "resolve" ]]; then
    mark_gave_up "$ch" "$ts"
    resolved=$((resolved + 1))
    echo "  resolved: $key"
  fi
done

echo "examined=$examined resolved=$resolved" >&2
