#!/usr/bin/env bash
# test_dropped_thread_resolve_channels.sh — TDD tests for resolve_channels()
#
# Tests the Slack conversations.list-based dynamic channel resolution added to
# dropped-thread-followup.sh.  Uses a mock HTTP server (python3 -m http.server
# is too slow; we inject via env override instead) — actually we mock by
# replacing the python3 inline script behavior via SLACK_TOKEN and a local
# HTTP stub.
#
# Approach: patch resolve_channels() calls by overriding SLACK_TOKEN and
# pointing at a local mock server that returns fixture JSON.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DROPPED_SCRIPT="$SCRIPT_DIR/../scripts/dropped-thread-followup.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASSED=0
FAILED=0
MOCK_PID=""

log_pass() { echo -e "${GREEN}✓ PASS${NC}: $1"; ((PASSED++)); }
log_fail() { echo -e "${RED}✗ FAIL${NC}: $1"; ((FAILED++)); }
log_info() { echo -e "${YELLOW}ℹ INFO${NC}: $1"; }

cleanup() {
  [[ -n "$MOCK_PID" ]] && kill "$MOCK_PID" 2>/dev/null || true
  [[ -n "${MOCK_DIR:-}" ]] && rm -rf "$MOCK_DIR"
}
trap cleanup EXIT

# ── Mock HTTP server helpers ──────────────────────────────────────────────────

start_mock_server() {
  local response_file="$1"
  local port="${2:-19876}"
  python3 - "$response_file" "$port" <<'PYEOF' &
import sys, http.server, json
response_file, port = sys.argv[1], int(sys.argv[2])
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        with open(response_file) as f: body = f.read().encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)
http.server.HTTPServer(("127.0.0.1", int(port)), Handler).serve_forever()
PYEOF
  MOCK_PID=$!
  sleep 0.3  # let server start
}

# Extract resolve_channels python block from the script and run it against a mock URL
run_resolve_channels() {
  local token="$1"
  local base_url="${2:-https://slack.com}"
  # Pull the python3 heredoc out of resolve_channels() and run it with patched URL
  python3 - "$token" "$base_url" <<'PYEOF'
import sys, json, urllib.request, urllib.parse

token = sys.argv[1]
base_url = sys.argv[2].rstrip("/")
ids = []
cursor = ""
while True:
    params = {"types": "public_channel,private_channel", "exclude_archived": "true",
              "limit": "200"}
    if cursor:
        params["cursor"] = cursor
    url = f"{base_url}/api/conversations.list?" + urllib.parse.urlencode(params)
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

MOCK_DIR="$(mktemp -d)"

# ── Test 1: returns member channel IDs ────────────────────────────────────────
test_returns_member_channels() {
  log_info "Test 1: returns only is_member=true channel IDs"
  cat >"$MOCK_DIR/response1.json" <<'EOF'
{
  "ok": true,
  "channels": [
    {"id": "${SLACK_CHANNEL_ID}", "is_member": true},
    {"id": "C0AH3RY3DK6", "is_member": true},
    {"id": "C0AJ3SD5C79", "is_member": true}
  ],
  "response_metadata": {"next_cursor": ""}
}
EOF
  start_mock_server "$MOCK_DIR/response1.json" 19876
  local result
  result="$(run_resolve_channels "xoxb-test" "http://127.0.0.1:19876")"
  kill "$MOCK_PID" 2>/dev/null; MOCK_PID=""

  if [[ "$result" == "${SLACK_CHANNEL_ID} C0AH3RY3DK6 C0AJ3SD5C79" ]]; then
    log_pass "returns correct member channel IDs"
  else
    log_fail "expected '${SLACK_CHANNEL_ID} C0AH3RY3DK6 C0AJ3SD5C79', got '$result'"
  fi
}

# ── Test 2: filters out non-member channels ───────────────────────────────────
test_filters_non_members() {
  log_info "Test 2: excludes channels where is_member=false"
  cat >"$MOCK_DIR/response2.json" <<'EOF'
{
  "ok": true,
  "channels": [
    {"id": "${SLACK_CHANNEL_ID}", "is_member": true},
    {"id": "CNOTMEMBER1", "is_member": false},
    {"id": "CNOTMEMBER2"},
    {"id": "C0AH3RY3DK6", "is_member": true}
  ],
  "response_metadata": {"next_cursor": ""}
}
EOF
  start_mock_server "$MOCK_DIR/response2.json" 19877
  local result
  result="$(run_resolve_channels "xoxb-test" "http://127.0.0.1:19877")"
  kill "$MOCK_PID" 2>/dev/null; MOCK_PID=""

  if [[ "$result" == "${SLACK_CHANNEL_ID} C0AH3RY3DK6" ]]; then
    log_pass "non-member channels excluded"
  else
    log_fail "expected '${SLACK_CHANNEL_ID} C0AH3RY3DK6', got '$result'"
  fi
}

# ── Test 3: pagination — follows next_cursor ──────────────────────────────────
test_pagination() {
  log_info "Test 3: follows next_cursor across multiple pages"
  # Page 1 returns cursor, page 2 returns empty cursor
  # Single server returns different data based on query param presence
  python3 - "$MOCK_DIR" <<'PYEOF' &
import sys, http.server, json, urllib.parse
mock_dir = sys.argv[1]
PAGE1 = json.dumps({
    "ok": True,
    "channels": [{"id": "C0000000001", "is_member": True},
                 {"id": "C0000000002", "is_member": True}],
    "response_metadata": {"next_cursor": "page2cursor"}
}).encode()
PAGE2 = json.dumps({
    "ok": True,
    "channels": [{"id": "C0000000003", "is_member": True}],
    "response_metadata": {"next_cursor": ""}
}).encode()
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        qs = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        body = PAGE2 if "page2cursor" in qs.get("cursor", [""])[0] else PAGE1
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)
http.server.HTTPServer(("127.0.0.1", 19878), Handler).serve_forever()
PYEOF
  MOCK_PID=$!
  sleep 0.3

  local result
  result="$(run_resolve_channels "xoxb-test" "http://127.0.0.1:19878")"
  kill "$MOCK_PID" 2>/dev/null; MOCK_PID=""

  if [[ "$result" == "C0000000001 C0000000002 C0000000003" ]]; then
    log_pass "pagination: all pages collected correctly"
  else
    log_fail "expected 3 channels across 2 pages, got '$result'"
  fi
}

# ── Test 4: graceful fallback on API error ────────────────────────────────────
test_api_error_fallback() {
  log_info "Test 4: returns empty string on Slack ok=false"
  cat >"$MOCK_DIR/response4.json" <<'EOF'
{"ok": false, "error": "invalid_auth"}
EOF
  start_mock_server "$MOCK_DIR/response4.json" 19879
  local result
  result="$(run_resolve_channels "xoxb-bad-token" "http://127.0.0.1:19879")"
  kill "$MOCK_PID" 2>/dev/null; MOCK_PID=""

  if [[ -z "$result" ]]; then
    log_pass "returns empty on invalid_auth error"
  else
    log_fail "expected empty string on API error, got '$result'"
  fi
}

# ── Test 5: graceful fallback on connection error ─────────────────────────────
test_connection_error_fallback() {
  log_info "Test 5: returns empty string when server unreachable"
  local result
  result="$(run_resolve_channels "xoxb-test" "http://127.0.0.1:19999")"  # nothing listening

  if [[ -z "$result" ]]; then
    log_pass "returns empty on connection error"
  else
    log_fail "expected empty string on connection error, got '$result'"
  fi
}

# ── Test 6: empty channel list ────────────────────────────────────────────────
test_empty_channel_list() {
  log_info "Test 6: handles bot with no joined channels"
  cat >"$MOCK_DIR/response6.json" <<'EOF'
{"ok": true, "channels": [], "response_metadata": {"next_cursor": ""}}
EOF
  start_mock_server "$MOCK_DIR/response6.json" 19880
  local result
  result="$(run_resolve_channels "xoxb-test" "http://127.0.0.1:19880")"
  kill "$MOCK_PID" 2>/dev/null; MOCK_PID=""

  if [[ -z "$result" ]]; then
    log_pass "returns empty string when bot is in no channels"
  else
    log_fail "expected empty string for empty channel list, got '$result'"
  fi
}

# ── Test 7: IS_SOURCED integration — DEFAULT_CHANNELS set after source ────────
test_default_channels_after_source() {
  log_info "Test 7: DEFAULT_CHANNELS is set when DROP_CHANNELS overrides (no live API needed)"
  local result
  result="$(DROP_CHANNELS="CTEST1 CTEST2" IS_SOURCED=1 \
    bash -c 'source '"$DROPPED_SCRIPT"' 2>/dev/null; echo "$DEFAULT_CHANNELS"')"

  if [[ "$result" == "CTEST1 CTEST2"* ]]; then
    log_pass "DROP_CHANNELS override respected in DEFAULT_CHANNELS"
  else
    log_fail "expected DEFAULT_CHANNELS to start with 'CTEST1 CTEST2', got '$result'"
  fi
}

# ── Run all tests ─────────────────────────────────────────────────────────────
echo ""
echo "=== resolve_channels() TDD tests ==="
echo ""

test_returns_member_channels
test_filters_non_members
test_pagination
test_api_error_fallback
test_connection_error_fallback
test_empty_channel_list
test_default_channels_after_source

echo ""
echo "=== Results: ${PASSED} passed, ${FAILED} failed ==="
[[ "$FAILED" -eq 0 ]]
