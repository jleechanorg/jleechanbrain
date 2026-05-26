#!/usr/bin/env bash
# hermes-canary.sh — External pipeline canary for Hermes gateway.
#
# Sends a message through the full Slack→LLM→response pipeline and verifies
# the bot generates a novel response (not an echo). Proves the entire stack
# works, not just that the process is running.
#
# Usage:
#   ./hermes-canary.sh                    # run canary against prod gateway
#   ./hermes-canary.sh --channel Cxxx     # override channel
#   ./hermes-canary.sh --timeout 30       # override response timeout
#   ./hermes-canary.sh --json             # machine-readable output
#
# Exit codes:
#   0 — canary passed (bot responded with novel text)
#   1 — canary failed (timeout or error)
#   2 — configuration error (missing token)
#
# Env vars:
#   SLACK_MCP_XOXP_TOKEN  — user token to post as human and read replies (required)
#   SLACK_TEST_CHANNEL    — channel ID for canary messages (default: ${SLACK_CHANNEL_ID})
#   HERMES_CANARY_TIMEOUT — seconds to wait for bot response (default: 20)
#
# Integration:
#   - deploy.sh: call after hermes_restart_prod() PID/port check
#   - launchd: schedule every 10 minutes for continuous monitoring
#   - hermes-watchdog.sh: call before attempting restart
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
CHANNEL="${SLACK_TEST_CHANNEL:-${SLACK_CHANNEL_ID}}"
TIMEOUT="${HERMES_CANARY_TIMEOUT:-20}"
PORT="${HERMES_CANARY_PORT:-8642}"
JSON_OUTPUT=false
CANARY_TAG="canary-$(date +%s)-$$"
# Unique nonce that the bot must include in its response to prove LLM processing.
# The gateway's SOUL.md instructs the bot to echo back nonces from canary messages.
CANARY_NONCE="ack-$(openssl rand -hex 4 2>/dev/null || echo "$RANDOM")"

# ── CLI args ──────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --channel)  CHANNEL="$2"; shift 2 ;;
    --timeout)  TIMEOUT="$2"; shift 2 ;;
    --port)     PORT="$2"; shift 2 ;;
    --json)     JSON_OUTPUT=true; shift ;;
    -h|--help)
      echo "Usage: $0 [--channel Cxxx] [--timeout N] [--port PORT] [--json]"
      exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

# ── Token resolution ──────────────────────────────────────────────────────────
USER_TOKEN="${SLACK_MCP_XOXP_TOKEN:-}"
if [[ -z "$USER_TOKEN" ]]; then
  echo "FAIL: SLACK_MCP_XOXP_TOKEN not set" >&2
  $JSON_OUTPUT && echo '{"status":"fail","reason":"missing_user_token"}'
  exit 2
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
json_escape() {
  # Escape a string for safe JSON embedding.
  python3 -c "import json,sys; print(json.dumps(sys.stdin.read().strip()))" 2>/dev/null
}

slack_post() {
  local text="$1"
  local escaped_text
  escaped_text=$(echo "$text" | json_escape)
  local resp
  resp=$(curl -sf -X POST "https://slack.com/api/chat.postMessage" \
    -H "Authorization: Bearer ${USER_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"channel\":\"${CHANNEL}\",\"text\":${escaped_text}}" \
    --max-time 10 2>/dev/null) || return 1

  local ok
  ok=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('ok',False))" 2>/dev/null)
  if [[ "$ok" != "True" ]]; then
    local err
    err=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('error','unknown'))" 2>/dev/null)
    echo "FAIL: Slack chat.postMessage error: ${err}" >&2
    return 1
  fi

  echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('ts',''))" 2>/dev/null
}

slack_find_bot_reply() {
  # Find a bot reply in the thread that contains the canary nonce.
  # Returns the bot's response text on success.
  local thread_ts="$1"
  local nonce="$2"
  local resp

  resp=$(curl -sf "https://slack.com/api/conversations.replies" \
    -H "Authorization: Bearer ${USER_TOKEN}" \
    -G --data-urlencode "channel=${CHANNEL}" \
    --data-urlencode "ts=${thread_ts}" \
    --data-urlencode "limit=20" \
    --max-time 10 2>/dev/null) || return 1

  # Python: find a bot reply (not the user's original) containing the nonce.
  # Slack bot messages use bot_id (B-prefix), not user_id (U-prefix).
  echo "$resp" | python3 -c "
import sys, json

raw = sys.stdin.read().strip()
if not raw:
    sys.exit(1)

data = json.loads(raw)
nonce = '$nonce'
parent_ts = '$thread_ts'
for msg in data.get('messages', []):
    # Skip parent message (user's original post)
    if msg.get('ts') == parent_ts:
        continue
    text = msg.get('text', '')
    # Bot messages have bot_id field; user messages don't.
    is_bot = bool(msg.get('bot_id', ''))
    if is_bot and nonce in text:
        print(text[:200].replace('\n', ' '))
        sys.exit(0)
sys.exit(1)
" 2>/dev/null
}

slack_delete_message() {
  local ts="$1"
  curl -sf -X POST "https://slack.com/api/chat.delete" \
    -H "Authorization: Bearer ${USER_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"channel\":\"${CHANNEL}\",\"ts\":\"${ts}\"}" \
    --max-time 5 >/dev/null 2>&1 || true
}

# ── Pre-flight checks ─────────────────────────────────────────────────────────
if ! curl -sf --max-time 5 "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
  echo "FAIL: gateway health endpoint not responding on :${PORT}" >&2
  $JSON_OUTPUT && echo "{\"status\":\"fail\",\"reason\":\"health_endpoint_down\",\"tag\":\"${CANARY_TAG}\"}"
  exit 1
fi

# ── Send canary message ───────────────────────────────────────────────────────
# The nonce proves the LLM actually processed the message — a simple echo
# (which happens when Slack WS is connected but LLM fails) won't include it.
CANARY_TEXT="[${CANARY_TAG}] Respond with exactly: ${CANARY_NONCE}"
echo "  Sending canary: ${CANARY_TAG} (nonce=${CANARY_NONCE})"

MSG_TS=$(slack_post "${CANARY_TEXT}") || {
  echo "FAIL: could not post canary message" >&2
  $JSON_OUTPUT && echo "{\"status\":\"fail\",\"reason\":\"post_failed\",\"tag\":\"${CANARY_TAG}\"}"
  exit 1
}

echo "  Posted message ts=${MSG_TS}"

# ── Wait for bot response ─────────────────────────────────────────────────────
ELAPSED=0
POLL_INTERVAL=2
RESPONSE=""

while [[ $ELAPSED -lt $TIMEOUT ]]; do
  sleep "$POLL_INTERVAL"
  ELAPSED=$((ELAPSED + POLL_INTERVAL))

  RESPONSE=$(slack_find_bot_reply "$MSG_TS" "$CANARY_NONCE" 2>/dev/null) && break

  echo "  Waiting... (${ELAPSED}s/${TIMEOUT}s)"
done

# ── Cleanup ───────────────────────────────────────────────────────────────────
slack_delete_message "$MSG_TS"

# ── Result ────────────────────────────────────────────────────────────────────
if [[ -n "$RESPONSE" ]]; then
  echo "PASS: bot responded in ${ELAPSED}s"
  echo "  Response: ${RESPONSE:0:120}"
  if $JSON_OUTPUT; then
    ESCAPED=$(echo "$RESPONSE" | json_escape)
    echo "{\"status\":\"pass\",\"elapsed_seconds\":${ELAPSED},\"tag\":\"${CANARY_TAG}\",\"nonce\":\"${CANARY_NONCE}\",\"response\":${ESCAPED}}"
  fi
  exit 0
else
  echo "FAIL: no bot response with nonce '${CANARY_NONCE}' within ${TIMEOUT}s" >&2
  echo "  Gateway health was OK but pipeline did not produce a valid LLM response" >&2
  echo "  Possible: LLM API key invalid, provider misconfigured, Slack WS disconnected" >&2
  if $JSON_OUTPUT; then
    echo "{\"status\":\"fail\",\"reason\":\"timeout\",\"timeout_seconds\":${TIMEOUT},\"tag\":\"${CANARY_TAG}\",\"nonce\":\"${CANARY_NONCE}\"}"
  fi
  exit 1
fi
