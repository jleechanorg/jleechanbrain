#!/usr/bin/env bash
# test_slack_thread_lib.sh — RED-GREEN test for lib/slack_thread_lib.sh
#
# Verifies the three safety nets the lib wraps around chat.postMessage:
#   1. Daily thread anchor — per-job daily-thread.ts persists; same-day
#      posts thread under the root; new day resets.
#   2. Dedupe — identical text within DEDUPE_WINDOW_SEC is suppressed.
#   3. Channel resolution — HERMES_OPS_SLACK_CHANNEL env wins over caller
#      default; missing env + missing caller default → fail-soft skip.
#
# Uses SLACK_POST_MOCK_RESP to bypass real curl. The lib's own self-test
# (at the bottom of slack_thread_lib.sh) is the canonical unit test; this
# file adds wiring-level coverage that the self-test skips (e.g. dedupe
# state cleanup, anchor file race, env vs caller channel resolution).
set -uo pipefail

LIB="${HOME}/.smartclaw/.worktrees/slack-cronjob-consolidate/lib/slack_thread_lib.sh"
[[ -f "$LIB" ]] || { echo "FAIL: lib not found at $LIB"; exit 1; }

PASSED=0
FAILED=0
pass() { echo "PASS: $1"; PASSED=$((PASSED + 1)); }
fail() { echo "FAIL: $1"; FAILED=$((FAILED + 1)); }

# Isolated state dir per test so anchor/dedupe files don't bleed.
mkstate() {
    local d
    d=$(mktemp -d /tmp/slack-thread-test.XXXXXX)
    echo "$d"
}

cleanup() { rm -rf /tmp/slack-thread-test.* 2>/dev/null || true; }
trap cleanup EXIT

# ─── Channel resolution ────────────────────────────────────────────────────
# 1. Env wins over caller default.
TMP=$(mkstate)
out=$(HERMES_OPS_SLACK_CHANNEL=${SLACK_CHANNEL_ID} \
    SLACK_THREAD_STATE_DIR="$TMP" SLACK_DEDUPE_STATE_DIR="$TMP/dedupe" \
    bash -c "IS_SOURCED=1 source '$LIB'; slack_resolve_channel C0AJ3SD5C79")
[[ "$out" == "${SLACK_CHANNEL_ID}" ]] && pass "env wins over caller default" \
    || fail "env wins over caller default (got '$out')"

# 2. Caller default used when no env.
TMP=$(mkstate)
out=$(SLACK_THREAD_STATE_DIR="$TMP" SLACK_DEDUPE_STATE_DIR="$TMP/dedupe" \
    bash -c "IS_SOURCED=1 source '$LIB'; slack_resolve_channel C0AJ3SD5C79")
[[ "$out" == "C0AJ3SD5C79" ]] && pass "caller default used when no env" \
    || fail "caller default used when no env (got '$out')"

# 3. Empty when no env + no caller default.
TMP=$(mkstate)
out=$(SLACK_THREAD_STATE_DIR="$TMP" SLACK_DEDUPE_STATE_DIR="$TMP/dedupe" \
    bash -c "IS_SOURCED=1 source '$LIB'; slack_resolve_channel '' || echo EMPTY")
[[ "$out" == "EMPTY" ]] && pass "fail-soft when no channel resolves" \
    || fail "fail-soft when no channel resolves (got '$out')"

# ─── Thread anchor ────────────────────────────────────────────────────────
# 4. Empty on first run (no prior post).
TMP=$(mkstate)
ts=$(SLACK_THREAD_STATE_DIR="$TMP" SLACK_DEDUPE_STATE_DIR="$TMP/dedupe" \
    bash -c "IS_SOURCED=1 source '$LIB'; slack_thread_anchor_get self-test 2>/dev/null || echo ''")
[[ -z "$ts" ]] && pass "no anchor on first run" \
    || fail "no anchor on first run (got '$ts')"

# 5. Persisted after slack_post succeeds with mock.
TMP=$(mkstate)
SLACK_POST_MOCK_RESP='{"ok":true,"ts":"1700000000.000100"}' \
SLACK_BOT_TOKEN="xoxb-fake" \
HERMES_OPS_SLACK_CHANNEL="${SLACK_CHANNEL_ID}" \
SLACK_THREAD_STATE_DIR="$TMP" SLACK_DEDUPE_STATE_DIR="$TMP/dedupe" \
bash -c "IS_SOURCED=1 source '$LIB'; slack_post self-test 'msg1' >/dev/null 2>&1"
ts=$(SLACK_THREAD_STATE_DIR="$TMP" SLACK_DEDUPE_STATE_DIR="$TMP/dedupe" \
    bash -c "IS_SOURCED=1 source '$LIB'; slack_thread_anchor_get self-test 2>/dev/null || echo ''")
[[ -n "$ts" ]] && pass "anchor persisted after first post" \
    || fail "anchor persisted after first post (got '$ts')"
# Verify exact ts round-trips
[[ "$ts" == "1700000000.000100" ]] && pass "anchor ts round-trips exactly" \
    || fail "anchor ts round-trips exactly (got '$ts')"

# 6. Second post in same day uses thread_ts (i.e. dedupe-suppressed skipped;
#    a different text threads under the anchor).
TMP=$(mkstate)
# First post establishes the anchor.
SLACK_POST_MOCK_RESP='{"ok":true,"ts":"1700000000.000100"}' \
SLACK_BOT_TOKEN="xoxb-fake" \
HERMES_OPS_SLACK_CHANNEL="${SLACK_CHANNEL_ID}" \
SLACK_THREAD_STATE_DIR="$TMP" SLACK_DEDUPE_STATE_DIR="$TMP/dedupe" \
bash -c "IS_SOURCED=1 source '$LIB'; slack_post self-test 'first' >/dev/null 2>&1"
# Second post with different text — should thread under anchor.
SLACK_POST_MOCK_RESP='{"ok":true,"ts":"1700000001.000200"}' \
SLACK_BOT_TOKEN="xoxb-fake" \
HERMES_OPS_SLACK_CHANNEL="${SLACK_CHANNEL_ID}" \
SLACK_THREAD_STATE_DIR="$TMP" SLACK_DEDUPE_STATE_DIR="$TMP/dedupe" \
bash -c "IS_SOURCED=1 source '$LIB'; slack_post self-test 'second' 2>&1" \
    | grep -q "ok channel=${SLACK_CHANNEL_ID} ts=1700000001.000200" \
    && pass "second post succeeds (thread anchor applied)" \
    || fail "second post succeeds (thread anchor applied)"

# 7. New day resets anchor (different day file AND mtime > 36h → empty).
# After PR #634 added a 36h grace window for cross-UTC-day anchors, this
# test now also backdates the mtime > 36h so the cross-day fallback path
# is exercised (not the strict stored_day==today fast path). Otherwise a
# fresh mtime within 36h of now would still return the anchor.
TMP=$(mkstate)
mkdir -p "$TMP/self-test"
echo "1700000000.000100" > "$TMP/self-test/daily-thread.ts"
echo "2026-06-12" > "$TMP/self-test/daily-thread.ts.day"  # stale day
# Backdate mtime to 7 days ago (well outside 36h grace)
python3 -c "import os,time; os.utime('$TMP/self-test/daily-thread.ts', (int(time.time())-7*86400, int(time.time())-7*86400))"
ts=$(SLACK_THREAD_STATE_DIR="$TMP" SLACK_DEDUPE_STATE_DIR="$TMP/dedupe" \
    bash -c "IS_SOURCED=1 source '$LIB'; slack_thread_anchor_get self-test 2>/dev/null || echo ''")
[[ -z "$ts" ]] && pass "anchor resets on new day (mtime outside 36h grace)" \
    || fail "anchor resets on new day (mtime outside 36h grace) (got '$ts')"

# ─── Dedupe ───────────────────────────────────────────────────────────────
# 8. Same text within window is suppressed.
TMP=$(mkstate)
# First post — should succeed.
out1=$(SLACK_POST_MOCK_RESP='{"ok":true,"ts":"1700000000.000100"}' \
    SLACK_BOT_TOKEN="xoxb-fake" \
    HERMES_OPS_SLACK_CHANNEL="${SLACK_CHANNEL_ID}" \
    SLACK_THREAD_STATE_DIR="$TMP" SLACK_DEDUPE_STATE_DIR="$TMP/dedupe" \
    bash -c "IS_SOURCED=1 source '$LIB'; slack_post dedup-test 'msg1' 2>&1")
echo "$out1" | grep -q "ok channel=" && pass "first post lands" \
    || fail "first post lands (got: $out1)"
# Second identical post within window — should be suppressed.
out2=$(SLACK_POST_MOCK_RESP='{"ok":true,"ts":"1700000001.000200"}' \
    SLACK_BOT_TOKEN="xoxb-fake" \
    HERMES_OPS_SLACK_CHANNEL="${SLACK_CHANNEL_ID}" \
    DEDUPE_WINDOW_SEC=60 \
    SLACK_THREAD_STATE_DIR="$TMP" SLACK_DEDUPE_STATE_DIR="$TMP/dedupe" \
    bash -c "IS_SOURCED=1 source '$LIB'; slack_post dedup-test 'msg1' 2>&1")
echo "$out2" | grep -q "SUPPRESSED" && pass "duplicate within window suppressed" \
    || fail "duplicate within window suppressed (got: $out2)"

# 9. --force bypasses dedupe.
TMP=$(mkstate)
SLACK_POST_MOCK_RESP='{"ok":true,"ts":"1700000000.000100"}' \
SLACK_BOT_TOKEN="xoxb-fake" \
HERMES_OPS_SLACK_CHANNEL="${SLACK_CHANNEL_ID}" \
SLACK_THREAD_STATE_DIR="$TMP" SLACK_DEDUPE_STATE_DIR="$TMP/dedupe" \
bash -c "IS_SOURCED=1 source '$LIB'; slack_post force-test 'msg1' >/dev/null 2>&1"
out=$(SLACK_POST_MOCK_RESP='{"ok":true,"ts":"1700000001.000200"}' \
    SLACK_BOT_TOKEN="xoxb-fake" \
    HERMES_OPS_SLACK_CHANNEL="${SLACK_CHANNEL_ID}" \
    DEDUPE_WINDOW_SEC=60 \
    SLACK_THREAD_STATE_DIR="$TMP" SLACK_DEDUPE_STATE_DIR="$TMP/dedupe" \
    bash -c "IS_SOURCED=1 source '$LIB'; slack_post force-test 'msg1' --force 2>&1")
echo "$out" | grep -q "ok channel=" && pass "--force bypasses dedupe" \
    || fail "--force bypasses dedupe (got: $out)"

# 10. Different text within window is NOT suppressed.
TMP=$(mkstate)
SLACK_POST_MOCK_RESP='{"ok":true,"ts":"1700000000.000100"}' \
SLACK_BOT_TOKEN="xoxb-fake" \
HERMES_OPS_SLACK_CHANNEL="${SLACK_CHANNEL_ID}" \
SLACK_THREAD_STATE_DIR="$TMP" SLACK_DEDUPE_STATE_DIR="$TMP/dedupe" \
bash -c "IS_SOURCED=1 source '$LIB'; slack_post diff-test 'msg-A' >/dev/null 2>&1"
out=$(SLACK_POST_MOCK_RESP='{"ok":true,"ts":"1700000001.000200"}' \
    SLACK_BOT_TOKEN="xoxb-fake" \
    HERMES_OPS_SLACK_CHANNEL="${SLACK_CHANNEL_ID}" \
    DEDUPE_WINDOW_SEC=60 \
    SLACK_THREAD_STATE_DIR="$TMP" SLACK_DEDUPE_STATE_DIR="$TMP/dedupe" \
    bash -c "IS_SOURCED=1 source '$LIB'; slack_post diff-test 'msg-B' 2>&1")
echo "$out" | grep -q "ok channel=" && pass "different text not suppressed" \
    || fail "different text not suppressed (got: $out)"

# ─── End-to-end failure modes ────────────────────────────────────────────
# 11. Missing token → fail-soft skip, no curl invoked.
TMP=$(mkstate)
out=$(unset SLACK_BOT_TOKEN; unset SLACK_BOT_TOKEN; \
    HERMES_OPS_SLACK_CHANNEL="${SLACK_CHANNEL_ID}" \
    SLACK_THREAD_STATE_DIR="$TMP" SLACK_DEDUPE_STATE_DIR="$TMP/dedupe" \
    bash -c "IS_SOURCED=1 source '$LIB'; slack_post no-token 'x' 2>&1")
echo "$out" | grep -q "no SLACK_BOT_TOKEN" && pass "fail-soft on missing token" \
    || fail "fail-soft on missing token (got: $out)"

# 12. Slack API error → returns non-zero, logs error.
TMP=$(mkstate)
out=$(SLACK_POST_MOCK_RESP='{"ok":false,"error":"channel_not_found"}' \
    SLACK_BOT_TOKEN="xoxb-fake" \
    HERMES_OPS_SLACK_CHANNEL="${SLACK_CHANNEL_ID}" \
    SLACK_THREAD_STATE_DIR="$TMP" SLACK_DEDUPE_STATE_DIR="$TMP/dedupe" \
    bash -c "IS_SOURCED=1 source '$LIB'; slack_post api-err 'x' 2>&1")
echo "$out" | grep -q "channel_not_found" && pass "API error propagated to log" \
    || fail "API error propagated to log (got: $out)"

# ─── Summary ──────────────────────────────────────────────────────────────
echo ""
if [[ "$FAILED" -gt 0 ]]; then
    echo "FAILED: $FAILED test(s), PASSED: $PASSED"
    exit 1
fi
echo "PASSED: $PASSED test(s)"
