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

# ── Shared Slack lib ──────────────────────────────────────────────────────────
# Source slack_thread_lib.sh so the canary notification message threads under a
# per-job daily anchor instead of flooding channel root. bead jleechan-ry3y
# follow-up to PR #615. The lib's slack_post cannot be used directly here
# because the canary needs the message ts back to poll for the bot reply; we
# reuse the lib's anchor helpers and post with USER_TOKEN (xoxp).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/lib"
# shellcheck source=lib/slack_thread_lib.sh
source "$LIB_DIR/slack_thread_lib.sh"

# ── Defaults ──────────────────────────────────────────────────────────────────
CHANNEL="${SLACK_TEST_CHANNEL:-${SLACK_CHANNEL_ID}}"
TIMEOUT="${HERMES_CANARY_TIMEOUT:-20}"
PROD_CONFIG="${HERMES_PROD_CONFIG:-$HOME/.smartclaw_prod/config.yaml}"
if [[ -z "${HERMES_CANARY_PORT:-}" ]]; then
  PORT="$(python3 - "$PROD_CONFIG" <<'PY'
import sys
default = 8642
path = sys.argv[1]
try:
    import yaml
    with open(path) as fh:
        cfg = yaml.safe_load(fh) or {}
    port = (((cfg.get("platforms") or {}).get("api_server") or {}).get("extra") or {}).get("port")
    print(int(port) if port is not None else default)
except Exception:
    print(default)
PY
)"
else
  PORT="$HERMES_CANARY_PORT"
fi
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

# ── Helpers ───────────────────────────────────────────────────────────────────
json_escape() {
  # Escape a string for safe JSON embedding.
  python3 -c "import json,sys; print(json.dumps(sys.stdin.read().strip()))" 2>/dev/null
}

slack_ensure_anchor() {
  # Returns the daily-thread anchor ts, creating one if needed. The anchor
  # message is a lightweight top-level post that is NEVER deleted by the
  # canary cleanup path — only the actual canary messages are deleted. This
  # separates "thread parent" (anchor) from "thread content" (canary), so the
  # P1 issue on PR #630 (anchor stored a ts that the main flow then deleted,
  # breaking subsequent same-day canary runs) cannot recur.
  local thread_ts
  thread_ts="$(slack_thread_anchor_get 'hermes-canary' 2>/dev/null || true)"
  if [[ -n "$thread_ts" ]]; then
    printf '%s' "$thread_ts"
    return 0
  fi

  local anchor_text="hermes-canary daily anchor (UTC $(date -u +%Y-%m-%d))"
  local payload
  payload="$(jq -n --arg ch "$CHANNEL" --arg txt "$anchor_text" \
    '{channel: $ch, text: $txt}')"

  local resp
  resp=$(curl -sf -X POST "https://slack.com/api/chat.postMessage" \
    -H "Authorization: Bearer ${USER_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    --max-time 10 2>/dev/null) || return 1

  local ok ts
  ok=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('ok',False))" 2>/dev/null)
  if [[ "$ok" != "True" ]]; then
    local err
    err=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('error','unknown'))" 2>/dev/null)
    echo "FAIL: anchor chat.postMessage error: ${err}" >&2
    return 1
  fi

  ts=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('ts',''))" 2>/dev/null)
  [[ -z "$ts" ]] && return 1

  slack_thread_anchor_set 'hermes-canary' "$ts"
  printf '%s' "$ts"
}

slack_post() {
  local text="$1"

  # Ensure a daily anchor exists, then post the canary message as a reply
  # under it. The anchor message is created once per UTC day by
  # slack_ensure_anchor() and is NEVER deleted — only this canary message is
  # cleaned up by slack_delete_message. The canary channel (${SLACK_CHANNEL_ID}) is
  # low-traffic so threading under a long-lived daily anchor is safe.
  local thread_ts
  thread_ts="$(slack_ensure_anchor)" || return 1

  local payload
  payload="$(jq -n --arg ch "$CHANNEL" --arg txt "$text" --arg ts "$thread_ts" \
    '{channel: $ch, text: $txt, thread_ts: $ts}')"

  local resp
  resp=$(curl -sf -X POST "https://slack.com/api/chat.postMessage" \
    -H "Authorization: Bearer ${USER_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    --max-time 10 2>/dev/null) || return 1

  local ok ts
  ok=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('ok',False))" 2>/dev/null)
  if [[ "$ok" != "True" ]]; then
    local err
    err=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('error','unknown'))" 2>/dev/null)
    echo "FAIL: Slack chat.postMessage error: ${err}" >&2
    return 1
  fi

  ts=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('ts',''))" 2>/dev/null)
  echo "$ts"
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
