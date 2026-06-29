#!/usr/bin/env bash
# test_slack_5b_leak_detector.sh
#
# Regression / unit tests for scripts/slack_5b_leak_detector.sh.
#
# Strategy: source the script with IS_SOURCED=1 (so main doesn't run), then
# call detect_5b_leaks() in-process. Inject a fake `curl` (a tiny shell script
# placed first in PATH) that:
#   • returns canned JSON for conversations.history
#   • records chat.postMessage calls to a log file
# This proves the detector's filter logic (root post, bot author, signal
# match, dedup) without any network access.
#
# Tests:
#   1. no leaks  → exit 0, no alert posted
#   2. one leak with workflow emoji → exit 1, alert posted
#   3. reply (thread_ts != ts) → ignored, exit 0
#   4. human post → ignored, exit 0
#   5. dedup: rerun on same state file → no second alert
#   6. text signal match (Bring-to-green status) → exit 1
#   7. state file created on first run if missing
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DETECTOR="$REPO_DIR/scripts/slack_5b_leak_detector.sh"

PASSED=0
FAILED=0
pass() { echo "PASS: $1"; PASSED=$((PASSED + 1)); }
fail() { echo "FAIL: $1"; FAILED=$((FAILED + 1)); }

[[ -f "$DETECTOR" ]] || { echo "FAIL: missing $DETECTOR"; exit 1; }

# ── Build a fake curl in a tmp bin dir ──────────────────────────────────────
WORKDIR="$(mktemp -d)"
BIN_DIR="$WORKDIR/bin"
LOG_DIR="$WORKDIR/logs"
FIXTURES_DIR="$WORKDIR/fixtures"
mkdir -p "$BIN_DIR" "$LOG_DIR" "$FIXTURES_DIR"
CURL_LOG="$LOG_DIR/curl.log"

# Helper to write a fixture file used by the fake curl.
write_fixture() {
  local name="$1" content="$2"
  printf '%s' "$content" > "$FIXTURES_DIR/$name"
}

# Test 1: empty channel (no messages)
write_fixture "C0AH3RY3DK6.json" '{"ok":true,"messages":[]}'
# Test 2: one leak with :rotating_light: emoji at root, from bot
write_fixture "C0BA4MCBPFB.json" '{"ok":true,"messages":[{"ts":"1781731123.137169","user":"U0AEZC7RX1Q","text":":rotating_light: bringing the build back, hold tight"}]}'
# Test 3: reply (thread_ts present and != ts) — should be ignored
write_fixture "${SLACK_CHANNEL_ID}.json" '{"ok":true,"messages":[{"ts":"1781731500.000001","thread_ts":"1781731000.000000","user":"U0AEZC7RX1Q","text":":clipboard: status update"}]}'
# Test 4: human post (different user_id) — should be ignored
write_fixture "${SLACK_CHANNEL_ID}.json" '{"ok":true,"messages":[{"ts":"1781731600.000002","user":"U09GH5BR3QU","text":":rotating_light: human typed this, not a bot"}]}'
# Test 6: text signal match
write_fixture "C0TEST0001.json" '{"ok":true,"messages":[{"ts":"1781731700.000003","user":"U0AEZC7RX1Q","text":"Bring-to-green status: PR #700 ready"}]}'
# Test 8/9/10: sub-class 5c intentional-anchor exclusion.
# The candidate ts is 1781800000.000001 (a leak signature at channel root).
write_fixture "C0TEST0002.json" '{"ok":true,"messages":[{"ts":"1781800000.000001","user":"U0AEZC7RX1Q","text":":rotating_light: status update"}]}'
# Test 11: pagination — page 1 has a leak + next_cursor, page 2 has a different leak.
write_fixture "C0TESTPAGE1.json" '{"ok":true,"messages":[{"ts":"1781900001.000001","user":"U0AEZC7RX1Q","text":":rotating_light: page 1 leak"}],"response_metadata":{"next_cursor":"dGVzdGN1cnNvcg=="}}'
write_fixture "C0TESTPAGE1.cursor.json" '{"ok":true,"messages":[{"ts":"1781900002.000001","user":"U0AEZC7RX1Q","text":"Bring-to-green status: page 2 leak"}]}'
# Test 12: error propagation — fixture returns ok:false, detector must rc=2.
write_fixture "C0TESTBAD.json" '{"ok":false,"error":"invalid_auth"}'

# The fake curl: parses -G <url> for conversations.history, or sees
# chat.postMessage in the body. Routes to fixture or records post.
cat > "$BIN_DIR/curl" <<'CURL_EOF'
#!/usr/bin/env bash
LOG_FILE="${FAKE_CURL_LOG:-/tmp/fake-curl.log}"
echo "[curl] $*" >> "$LOG_FILE"
# Crude arg parse: scan for endpoint, data-urlencode, and -d body.
URL=""
CHANNEL=""
CURSOR=""
POST_BODY=""
for ((i=1; i<=$#; i++)); do
  arg="${!i}"
  case "$arg" in
    https://slack.com/api/*) URL="$arg" ;;
    --data-urlencode=channel=*) CHANNEL="${arg#--data-urlencode=channel=}" ;;
    --data-urlencode=cursor=*)  CURSOR="${arg#--data-urlencode=cursor=}" ;;
    --data-urlencode=oldest=*) : ;; # consumed; not needed for routing
    --data-urlencode=limit=*) : ;;
    --data-urlencode=*) : ;;
    --data-urlencode) i=$((i+1)); next="${!i}"; case "$next" in channel=*) CHANNEL="${next#channel=}" ;; cursor=*) CURSOR="${next#cursor=}" ;; esac ;;
    -d) i=$((i+1)); POST_BODY="${!i}" ;;
  esac
done

if [[ "$URL" == *"conversations.history"* ]]; then
  # If cursor was supplied, route to <channel>.cursor.json (pagination test fixture).
  # Otherwise route to <channel>.json.
  if [[ -n "$CURSOR" ]]; then
    fx="${FIXTURES_DIR:-/tmp/fake-fix}/$CHANNEL.cursor.json"
  else
    fx="${FIXTURES_DIR:-/tmp/fake-fix}/$CHANNEL.json"
  fi
  if [[ -f "$fx" ]]; then
    cat "$fx"
  else
    echo '{"ok":true,"messages":[]}'
  fi
  exit 0
fi

if [[ "$URL" == *"chat.postMessage"* || "$POST_BODY" == *"chat.postMessage"* ]]; then
  echo "[curl] POST alert to ${ALERT_CHAN:-unknown}: $POST_BODY" >> "$LOG_FILE"
  echo '{"ok":true,"ts":"9999999999.999999","channel":"x"}'
  exit 0
fi

echo '{"ok":false,"error":"unknown_endpoint"}'
CURL_EOF
chmod +x "$BIN_DIR/curl"
export PATH="$BIN_DIR:$PATH"
export FAKE_CURL_LOG="$CURL_LOG"
export FIXTURES_DIR
export ALERT_CHAN="${SLACK_CHANNEL_ID}"

# ── Helpers for test isolation ──────────────────────────────────────────────
# Source the detector into a subshell with IS_SOURCED=1, then call
# detect_5b_leaks directly. This is the only way to drive the helpers
# without a separate network roundtrip.
# Note: state file is NOT reset here — each test manages its own state-file
# lifecycle so dedup tests can chain runs against the same file.
run_detector() {
  local state_file="$1" channels="${2:-C0AH3RY3DK6 C0BA4MCBPFB ${SLACK_CHANNEL_ID} ${SLACK_CHANNEL_ID}}" anchor_dirs="${3:-}"
  (
    export SLACK_USER_TOKEN="xoxp-fake"
    export SLACK_5B_CURL_BIN="$BIN_DIR/curl"
    export SLACK_5B_DRY_RUN="1"
    export SLACK_5B_STATE_FILE="$state_file"
    export SLACK_5B_CHANNELS="$channels"
    export SLACK_5B_BOT_USER_ID="U0AEZC7RX1Q"
    if [[ -n "$anchor_dirs" ]]; then
      export SLACK_5B_ANCHOR_DIRS="$anchor_dirs"
    fi
    # shellcheck source=/dev/null
    IS_SOURCED=1 source "$DETECTOR"
    detect_5b_leaks
  )
}

# ── Test 1: no leaks → exit 0 ───────────────────────────────────────────────
TMP_STATE="$WORKDIR/state1.json"
rm -f "$TMP_STATE"
set +e
OUT=$(run_detector "$TMP_STATE" "C0AH3RY3DK6" 2>&1)
RC=$?
set -e
if [[ $RC -eq 0 ]] && echo "$OUT" | grep -q "OK no leaks"; then
  pass "test 1: no leaks → exit 0 + OK summary"
else
  fail "test 1: expected exit 0 + 'OK no leaks', got rc=$RC out=$OUT"
fi

# ── Test 2: one leak with workflow emoji → exit 1, alert line emitted ──────
# In DRY_RUN mode the script logs "[DRY_RUN] ALERT ..." to stderr instead of
# calling chat.postMessage. We assert on the stdout ALERT line + the dry-run
# log entry. A separate (non-dry) test path is covered by the
# post_alert() unit logic in test 7-style flows.
TMP_STATE="$WORKDIR/state2.json"
rm -f "$TMP_STATE"
set +e
OUT=$(run_detector "$TMP_STATE" "C0BA4MCBPFB" 2>&1)
RC=$?
set -e
if [[ $RC -eq 1 ]] && echo "$OUT" | grep -q "ALERT ts=1781731123.137169" && \
   echo "$OUT" | grep -q "DRY_RUN. ALERT channel=C0BA4MCBPFB"; then
  pass "test 2: one emoji leak → exit 1, ALERT line + DRY_RUN log emitted"
else
  fail "test 2: expected exit 1 + ALERT + DRY_RUN log, got rc=$RC out=$OUT"
fi

# ── Test 3: reply (thread_ts != ts) → ignored ───────────────────────────────
# (${SLACK_CHANNEL_ID} has a threaded reply — scan over only that channel.)
TMP_STATE="$WORKDIR/state3.json"
rm -f "$TMP_STATE"
set +e
OUT=$(run_detector "$TMP_STATE" "${SLACK_CHANNEL_ID}" 2>&1)
RC=$?
set -e
if [[ $RC -eq 0 ]] && ! echo "$OUT" | grep -q "ALERT"; then
  pass "test 3: thread reply ignored (no ALERT)"
else
  fail "test 3: expected exit 0 + no ALERT, got rc=$RC out=$OUT"
fi

# ── Test 4: human post → ignored ───────────────────────────────────────────
TMP_STATE="$WORKDIR/state4.json"
rm -f "$TMP_STATE"
set +e
OUT=$(run_detector "$TMP_STATE" "${SLACK_CHANNEL_ID}" 2>&1)
RC=$?
set -e
if [[ $RC -eq 0 ]] && ! echo "$OUT" | grep -q "ALERT"; then
  pass "test 4: human post ignored"
else
  fail "test 4: expected exit 0 + no ALERT, got rc=$RC out=$OUT"
fi

# ── Test 5: dedup — second run does not re-alert ───────────────────────────
TMP_STATE="$WORKDIR/state5.json"
rm -f "$TMP_STATE"
set +e
OUT1=$(run_detector "$TMP_STATE" "C0BA4MCBPFB" 2>&1)
RC1=$?
OUT2=$(run_detector "$TMP_STATE" "C0BA4MCBPFB" 2>&1)
RC2=$?
set -e
if [[ $RC1 -eq 1 && $RC2 -eq 0 ]]; then
  if grep -Fxq "1781731123.137169" "$TMP_STATE"; then
    pass "test 5: dedup — second run exit 0, state has ts"
  else
    fail "test 5: state file missing deduped ts"
  fi
else
  fail "test 5: expected RC1=1 RC2=0, got RC1=$RC1 RC2=$RC2"
fi

# ── Test 6: text signal match ──────────────────────────────────────────────
TMP_STATE="$WORKDIR/state6.json"
rm -f "$TMP_STATE"
set +e
OUT=$(run_detector "$TMP_STATE" "C0TEST0001" 2>&1)
RC=$?
set -e
if [[ $RC -eq 1 ]] && echo "$OUT" | grep -q "reason=text:Bring-to-green status"; then
  pass "test 6: text signal match → ALERT with text: prefix"
else
  fail "test 6: expected exit 1 + text: reason, got rc=$RC out=$OUT"
fi

# ── Test 7: state file created on first run if missing ─────────────────────
TMP_STATE="$WORKDIR/state7-missing-on-purpose.json"
rm -f "$TMP_STATE"
(
  export SLACK_USER_TOKEN="xoxp-fake"
  export SLACK_5B_CURL_BIN="$BIN_DIR/curl"
  export SLACK_5B_DRY_RUN="1"
  export SLACK_5B_STATE_FILE="$TMP_STATE"
  export SLACK_5B_CHANNELS="C0AH3RY3DK6"
  export SLACK_5B_BOT_USER_ID="U0AEZC7RX1Q"
  # shellcheck source=/dev/null
  IS_SOURCED=1 source "$DETECTOR" >/dev/null 2>&1
) || true
if [[ -f "$TMP_STATE" ]]; then
  pass "test 7: state file created on first run"
else
  fail "test 7: state file not created at $TMP_STATE"
fi

# ── Test 8: intentional-anchor (sub-class 5c) — recent anchor matches ts ───
# Fake var/slack with one job whose daily-thread.ts is 30s old and contains
# the candidate ts. Detector must treat this as an anchor and skip.
TMP_STATE="$WORKDIR/state8.json"
ANCHOR_ROOT_8="$WORKDIR/var8/slack"
mkdir -p "$ANCHOR_ROOT_8/babysit-wa-2366-rev-5deak"
printf '1781800000.000001' > "$ANCHOR_ROOT_8/babysit-wa-2366-rev-5deak/daily-thread.ts"
# Force mtime 30s in the past.
touch -t "$(date -v-30S '+%Y%m%d%H%M.%S' 2>/dev/null || date -d '30 seconds ago' '+%Y%m%d%H%M.%S')" \
  "$ANCHOR_ROOT_8/babysit-wa-2366-rev-5deak/daily-thread.ts"
rm -f "$TMP_STATE"
set +e
OUT=$(run_detector "$TMP_STATE" "C0TEST0002" "$ANCHOR_ROOT_8" 2>&1)
RC=$?
set -e
if [[ $RC -eq 0 ]] && ! echo "$OUT" | grep -q "ALERT ts=1781800000.000001" && \
   echo "$OUT" | grep -q "intentional-anchor"; then
  pass "test 8: matching recent anchor → exit 0, intentional-anchor logged"
else
  fail "test 8: expected exit 0 + intentional-anchor log, got rc=$RC out=$OUT"
fi

# ── Test 9: no anchor file present → real leak, exit 1 ─────────────────────
# Same candidate ts, but the anchor dirs are empty.
TMP_STATE="$WORKDIR/state9.json"
EMPTY_ANCHOR="$WORKDIR/var9/slack"
mkdir -p "$EMPTY_ANCHOR"
rm -f "$TMP_STATE"
set +e
OUT=$(run_detector "$TMP_STATE" "C0TEST0002" "$EMPTY_ANCHOR" 2>&1)
RC=$?
set -e
if [[ $RC -eq 1 ]] && echo "$OUT" | grep -q "ALERT ts=1781800000.000001"; then
  pass "test 9: no anchor → real leak, exit 1 + ALERT line"
else
  fail "test 9: expected exit 1 + ALERT, got rc=$RC out=$OUT"
fi

# ── Test 10: stale anchor (mtime > grace) → still treated as a real leak ──
# Anchor file exists, matches ts, but mtime is 30 min old (beyond the
# 10-min DAILY_ANCHOR_GRACE_MIN default). Detector must alert.
TMP_STATE="$WORKDIR/state10.json"
ANCHOR_ROOT_10="$WORKDIR/var10/slack"
mkdir -p "$ANCHOR_ROOT_10/babysit-wa-2366-rev-5deak"
printf '1781800000.000001' > "$ANCHOR_ROOT_10/babysit-wa-2366-rev-5deak/daily-thread.ts"
# Force mtime 30 min in the past.
touch -t "$(date -v-30M '+%Y%m%d%H%M.%S' 2>/dev/null || date -d '30 minutes ago' '+%Y%m%d%H%M.%S')" \
  "$ANCHOR_ROOT_10/babysit-wa-2366-rev-5deak/daily-thread.ts"
rm -f "$TMP_STATE"
set +e
OUT=$(run_detector "$TMP_STATE" "C0TEST0002" "$ANCHOR_ROOT_10" 2>&1)
RC=$?
set -e
if [[ $RC -eq 1 ]] && echo "$OUT" | grep -q "ALERT ts=1781800000.000001" && \
   ! echo "$OUT" | grep -q "intentional-anchor"; then
  pass "test 10: stale anchor (30m) → real leak, exit 1"
else
  fail "test 10: expected exit 1 + ALERT + no anchor log, got rc=$RC out=$OUT"
fi

# ── Test 11: pagination — detector follows next_cursor across pages ────────
# Page 1 returns a leak + next_cursor; page 2 returns a different leak.
# Detector must surface BOTH ALERT lines (rc=1) in a single run.
TMP_STATE="$WORKDIR/state11.json"
rm -f "$TMP_STATE"
set +e
OUT=$(run_detector "$TMP_STATE" "C0TESTPAGE1" 2>&1)
RC=$?
set -e
if [[ $RC -eq 1 ]] \
   && echo "$OUT" | grep -q "ALERT ts=1781900001.000001" \
   && echo "$OUT" | grep -q "ALERT ts=1781900002.000001" \
   && grep -c "conversations.history" "$CURL_LOG" | grep -qE '^([2-9]|[1-9][0-9]+)$'; then
  pass "test 11: pagination — both pages scanned, 2 ALERT lines, ≥2 curl calls"
else
  fail "test 11: expected rc=1 + 2 ALERT lines + ≥2 history calls, got rc=$RC out=$OUT"
fi

# ── Test 12: error propagation — ok:false response surfaces as rc=2 ─────────
# The fixture returns {"ok":false,...}; scan_channel must return 2; detect_5b_leaks
# must aggregate and exit 2 (NOT print "OK no leaks").
TMP_STATE="$WORKDIR/state12.json"
rm -f "$TMP_STATE"
set +e
OUT=$(run_detector "$TMP_STATE" "C0TESTBAD" 2>&1)
RC=$?
set -e
if [[ $RC -eq 2 ]] && echo "$OUT" | grep -q "ERROR: scan failures" && ! echo "$OUT" | grep -q "OK no leaks"; then
  pass "test 12: error propagation — ok:false → rc=2 + ERROR line, no false OK"
else
  fail "test 12: expected rc=2 + ERROR + no OK, got rc=$RC out=$OUT"
fi

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "=============================="
echo "PASSED: $PASSED / 12"
echo "FAILED: $FAILED / 12"
echo "=============================="

# Cleanup
rm -rf "$WORKDIR"

if [[ "$FAILED" -gt 0 ]]; then
  exit 1
fi
exit 0
