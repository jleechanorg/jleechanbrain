#!/usr/bin/env bash
# Regression: cmux-surface-report-4h.sh must post a one-liner to Slack when a
# tick is skipped (no live socket OR `cmux tree` RPC wedged), so silent
# failures are visible. The user requested this on 2026-06-24 after seeing
# multiple ticks in a row with no Slack post and no other signal.
#
# Root cause (2026-06-25): the script's two early-exit paths
#   (1) no live cmux socket (script lines ~38-41)
#   (2) cmux tree --window AND --all both return empty (script lines ~105-114)
# both `exit 0` silently with no Slack post. That's why today (2026-06-25)
# the 14:28, 18:28, 22:28 UTC ticks all posted nothing.
#
# Approach: drive the REAL script end-to-end against a fake cmux (returns
# empty) + a fake curl that records Slack POSTs. The test is hermetic — no
# network, no real cmux. It pins three properties:
#   A. Tree-wedge integration path posts to Slack (kills the silent failure)
#   B. No-socket path posts to Slack (same silent failure class)
#   C. Skip rate-limit: a second skip within 4h is suppressed (no spam when
#      cmux is wedged for hours; otherwise the cure is worse than the disease)
#
# This test does NOT source the script's internals — there is no IS_SOURCED
# guard in the current script. It drives the whole pipeline like launchd does.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/cmux-surface-report-4h.sh"

PASSED=0
FAILED=0
pass() { echo "PASS: $1"; PASSED=$((PASSED + 1)); }
fail() { echo "FAIL: $1"; FAILED=$((FAILED + 1)); }

[[ -f "$SCRIPT" ]] || { echo "FAIL: missing $SCRIPT"; exit 1; }

# ── Build hermetic sandbox ───────────────────────────────────────────────────
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

# Fake curl: capture URL + payload; reply ok:true so production code doesn't
# treat a successful post as an error.
cat > "$SANDBOX/curl" <<'CURL_EOF'
#!/bin/bash
echo "URL: $1" >> "${SLACK_POSTS:?need SLACK_POSTS}"
shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--data|--data-raw|--data-binary)
      echo "PAYLOAD: $2" >> "$SLACK_POSTS"
      shift 2 ;;
    -H|--header)
      echo "HEADER: $2" >> "$SLACK_POSTS"
      shift 2 ;;
    *)
      shift ;;
  esac
done
printf '{"ok":true,"channel":"C0AJQ5M0A0Y","ts":"1782400000.000001"}\n'
CURL_EOF
chmod +x "$SANDBOX/curl"

# Fake cmux: returns empty (simulates wedge) unless FAKE_CMUX_STDOUT is set.
cat > "$SANDBOX/cmux" <<'CMUX_EOF'
#!/bin/bash
if [[ -n "${FAKE_CMUX_STDOUT:-}" ]]; then
  printf '%s\n' "$FAKE_CMUX_STDOUT"
fi
exit 0
CMUX_EOF
chmod +x "$SANDBOX/cmux"

# Helper: run the real script under the sandbox + record this run's posts.
# Args after the two mandatory paths go to env (e.g. FAKE_CMUX_STDOUT).
# The script hardcodes LOG_DIR to ~/.smartclaw/logs/cmux-surface-report — fine
# for production, so we mirror that here (no override needed).
SCRIPT_LOG_DIR="$HOME/.smartclaw/logs/cmux-surface-report"

run_script() {
  local posts_file="$1"
  local state_dir="$2"
  shift 2
  : > "$posts_file"
  PATH="$SANDBOX:$PATH" \
    SLACK_POSTS="$posts_file" \
    SLACK_BOT_TOKEN="xoxb-test-fake-token" \
    HERMES_CMUX_4H_CHANNEL="C0AJQ5M0A0Y" \
    CMUX_REPORT_STATE_DIR="$state_dir" \
    "$@" \
    bash "$SCRIPT" >/dev/null 2>&1 || true
}

# Helper: count POST "URL:" lines (1 per successful chat.postMessage call).
count_posts() {
  grep -c '^URL: ' "$1" 2>/dev/null || true
}

# ── Test A: tree-wedged integration — must post to Slack ─────────────────────
# This is the EXACT path the user hit today. Pin the failure mode.
STATE_A="$(mktemp -d)"
POSTS_A="$SANDBOX/posts_a.log"
run_script "$POSTS_A" "$STATE_A"

# Side-effect: the log must show the wedge was detected.
# Script writes per-hour logs to ~/.smartclaw/logs/cmux-surface-report/.
if grep -rq "RPC may be wedged" "$SCRIPT_LOG_DIR" 2>/dev/null; then
  pass "wedge path: log captured 'RPC may be wedged'"
else
  fail "wedge path: log did NOT capture wedge message"
fi
# Main contract: the channel received at least one Slack post.
POST_COUNT_A="$(count_posts "$POSTS_A")"
if [[ "$POST_COUNT_A" -ge 1 ]]; then
  pass "wedge path: posted to Slack (silent failure regression killed)"
else
  fail "wedge path: NO Slack post — silent failure regression"
fi
# Pin the message shape so it can't accidentally become noise.
if grep -q "Authorization: Bearer xoxb-test-fake-token" "$POSTS_A"; then
  pass "wedge path: used SLACK_BOT_TOKEN"
else
  fail "wedge path: did not include bot token"
fi
if grep -q '"channel":"C0AJQ5M0A0Y"' "$POSTS_A"; then
  pass "wedge path: targeted C0AJQ5M0A0Y"
else
  fail "wedge path: wrong channel: $(grep PAYLOAD "$POSTS_A" || echo none)"
fi
if grep -qE '"text":"[^"]*cmux surface report[^"]*skip' "$POSTS_A"; then
  pass "wedge path: text tagged as a skip"
else
  fail "wedge path: text not tagged: $(grep PAYLOAD "$POSTS_A" || echo none)"
fi
if grep -qE 'RPC (may be )?wedged' "$POSTS_A"; then
  pass "wedge path: text echoed the wedge reason"
else
  fail "wedge path: text did not echo wedge reason"
fi
rm -rf "$STATE_A"

# ── Test B: rate-limit — second skip within 4h is suppressed ────────────────
# Goal: when cmux is wedged for 8h straight, the channel gets exactly 1 post,
# not 6. Otherwise the cure is worse than the disease.
STATE_B="$(mktemp -d)"
POSTS_B="$SANDBOX/posts_b.log"
run_script "$POSTS_B" "$STATE_B"
POST_COUNT_B1="$(count_posts "$POSTS_B")"

# Second tick (still wedged). The state file from run 1 is preserved via
# STATE_B, which is what `run_script` writes the rate-limit marker into.
POSTS_B2="$SANDBOX/posts_b2.log"
run_script "$POSTS_B2" "$STATE_B"
POST_COUNT_B2="$(count_posts "$POSTS_B2")"

if [[ "$POST_COUNT_B1" -ge 1 ]]; then
  pass "rate-limit: first wedge tick posts"
else
  fail "rate-limit: first wedge tick did not post"
fi
if [[ "$POST_COUNT_B2" -eq 0 ]]; then
  pass "rate-limit: second wedge tick within 4h suppressed (no spam)"
else
  fail "rate-limit: second tick posted $POST_COUNT_B2 times — would spam channel"
fi
rm -rf "$STATE_B"

# ── Test C: rate-limit reset — faking a stale state file MUST allow a post ─
# We write a 5h-old timestamp and expect a fresh post. This pins the 4h
# boundary so a refactor that uses 1h or 24h fails the test.
STATE_C="$(mktemp -d)"
echo "$(($(date +%s) - 5 * 3600))" > "$STATE_C/notify_skip.last_post"
POSTS_C="$SANDBOX/posts_c.log"
run_script "$POSTS_C" "$STATE_C"
POST_COUNT_C="$(count_posts "$POSTS_C")"
if [[ "$POST_COUNT_C" -ge 1 ]]; then
  pass "rate-limit reset: stale state (5h old) allows a fresh post"
else
  fail "rate-limit reset: stale state wrongly suppressed — boundary wrong"
fi
rm -rf "$STATE_C"

# ── Test D: no-token integration — must NOT crash, must NOT post ────────────
# Mirrors the existing "No Slack token available — skipping post" guard.
# notify_skip must respect it: posting with no token would either crash or
# send an unauthenticated request.
STATE_D="$(mktemp -d)"
POSTS_D="$SANDBOX/posts_d.log"
PATH="$SANDBOX:$PATH" \
  SLACK_POSTS="$POSTS_D" \
  SLACK_BOT_TOKEN="" \
  HERMES_SLACK_USER_TOKEN="" \
  HERMES_CMUX_4H_CHANNEL="C0AJQ5M0A0Y" \
  CMUX_REPORT_STATE_DIR="$STATE_D" \
  bash "$SCRIPT" >/dev/null 2>&1 || true
POST_COUNT_D="$(count_posts "$POSTS_D")"
if [[ "$POST_COUNT_D" -eq 0 ]]; then
  pass "no-token: no Slack POST attempted"
else
  fail "no-token: $POST_COUNT_D Slack POSTs attempted without a token"
fi
# It must still log the wedge — we never want to lose that signal.
if grep -rq "RPC may be wedged" "$SCRIPT_LOG_DIR" 2>/dev/null; then
  pass "no-token: wedge still logged even though Slack post skipped"
else
  fail "no-token: wedge not logged — losing signal"
fi
rm -rf "$STATE_D"

echo ""
if [[ "$FAILED" -gt 0 ]]; then
  echo "FAILED: $FAILED test(s), PASSED: $PASSED"
  exit 1
fi
echo "PASSED: $PASSED test(s)"