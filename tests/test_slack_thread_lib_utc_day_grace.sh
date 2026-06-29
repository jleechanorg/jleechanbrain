#!/usr/bin/env bash
# test_slack_thread_lib_utc_day_grace.sh — RED-GREEN test for the
# 36h cross-UTC-day grace window in slack_thread_anchor_get.
#
# Background: cron scripts that post at 23:50 UTC day N and then 00:20 UTC
# day N+1 previously created a spurious 2nd thread because the lib's strict
# `stored_day == today` check failed across the UTC day boundary. The fix
# extends anchor validity to ANCHOR_GRACE_SEC (default 129600s = 36h) so
# the same anchor threads both posts.
#
# Tests:
#   1. same-day anchor (mtime = now - 1h, day = today)         → returns ts
#   2. yesterday's anchor within 36h (mtime = now - 25h)        → returns ts
#   3. 2-day-old anchor (mtime = now - 50h, day = 2d ago)      → returns empty
#   4. 36h boundary just under (mtime = now - 36h + 60s)       → returns ts
#   5. 36h boundary just over (mtime = now - 36h - 60s)        → returns empty
#   6. missing daily-thread.ts                                 → returns empty
#   7. missing daily-thread.ts.day                             → returns empty
#   8. ANCHOR_GRACE_SEC override (set to 1h, 2d-old anchor)    → returns empty
#
# The test uses touch -t to set the mtime on the anchor file relative to
# the current "now" — this avoids depending on `date -d` which is GNU-only
# and unreliable on macOS in some bash versions.
set -uo pipefail

# Resolve LIB relative to this test file's location so the test runs in any
# checkout (CI, fresh clone, worktree). Falls back to git toplevel for
# robustness against symlinked test directories.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$(cd "$SCRIPT_DIR/.." && pwd)/lib/slack_thread_lib.sh"
if [[ ! -f "$LIB" ]]; then
  # Fallback: try git toplevel
  if command -v git >/dev/null 2>&1; then
    REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
    [[ -n "$REPO_ROOT" && -f "$REPO_ROOT/lib/slack_thread_lib.sh" ]] \
      && LIB="$REPO_ROOT/lib/slack_thread_lib.sh"
  fi
fi
[[ -f "$LIB" ]] || { echo "FAIL: lib not found at $LIB"; exit 1; }

PASSED=0
FAILED=0
pass() { echo "PASS: $1"; PASSED=$((PASSED + 1)); }
fail() { echo "FAIL: $1"; FAILED=$((FAILED + 1)); }

# Isolated state dir per test.
mkstate() { mktemp -d /tmp/slack-grace-test.XXXXXX; }
cleanup() { rm -rf /tmp/slack-grace-test.* 2>/dev/null || true; }
trap cleanup EXIT

# Write the anchor pair (ts + day) into a per-job subdir under $1.
# Args: state_dir, job, ts, day_string
write_anchor() {
  local sdir="$1" job="$2" ts="$3" day="$4"
  mkdir -p "$sdir/$job"
  printf '%s' "$ts" > "$sdir/$job/daily-thread.ts"
  printf '%s' "$day" > "$sdir/$job/daily-thread.ts.day"
}

# Set the mtime of the anchor file to "now - $1 seconds".
# Use python for second precision (macOS touch -t has minute precision only,
# which fails at the 36h boundary where ±1s matters).
# Args: anchor_file, age_seconds
backdate() {
  local file="$1" age="$2"
  python3 -c "
import os, time
target = int(time.time()) - $age
# os.utime takes float seconds since epoch
os.utime('$file', (target, target))
"
}

# Run slack_thread_anchor_get with the given state dir, capturing output.
# Args: state_dir, job, [extra_env]
get_anchor() {
  local sdir="$1" job="$2"
  shift 2
  SLACK_THREAD_STATE_DIR="$sdir" SLACK_DEDUPE_STATE_DIR="$sdir/dedupe" \
    "$@" \
    bash -c "IS_SOURCED=1 source '$LIB'; slack_thread_anchor_get '$job' 2>/dev/null || echo ''"
}

# ─── Test 1: same-day anchor (mtime = now - 1h, day = today) → returns ts ──
TMP=$(mkstate)
TODAY="$(date -u +%Y-%m-%d)"
write_anchor "$TMP" "t1" "1700000000.000100" "$TODAY"
backdate "$TMP/t1/daily-thread.ts" 3600  # 1h ago
out=$(get_anchor "$TMP" t1)
[[ "$out" == "1700000000.000100" ]] && pass "same-day anchor returns ts" \
    || fail "same-day anchor returns ts (got '$out')"

# ─── Test 2: yesterday's anchor within 36h → returns ts ────────────────────
# Anchor was created 25h ago (mtime 25h) but stored_day is "yesterday".
# The strict day check would fail; the new mtime check should return the ts.
TMP=$(mkstate)
YESTERDAY="$(date -u -v-1d +%Y-%m-%d 2>/dev/null \
  || date -u -d '1 day ago' +%Y-%m-%d)"
write_anchor "$TMP" "t2" "1700000000.000200" "$YESTERDAY"
backdate "$TMP/t2/daily-thread.ts" 90000  # 25h ago
out=$(get_anchor "$TMP" t2)
[[ "$out" == "1700000000.000200" ]] && pass "yesterday anchor (25h) within grace returns ts" \
    || fail "yesterday anchor (25h) within grace returns ts (got '$out')"

# ─── Test 3: 2-day-old anchor (mtime = now - 50h) → returns empty ──────────
# 50h exceeds the 36h grace → anchor should NOT be returned.
TMP=$(mkstate)
TWO_DAYS_AGO="$(date -u -v-2d +%Y-%m-%d 2>/dev/null \
  || date -u -d '2 days ago' +%Y-%m-%d)"
write_anchor "$TMP" "t3" "1700000000.000300" "$TWO_DAYS_AGO"
backdate "$TMP/t3/daily-thread.ts" 180000  # 50h ago
out=$(get_anchor "$TMP" t3)
[[ -z "$out" ]] && pass "2-day-old anchor outside grace returns empty" \
    || fail "2-day-old anchor outside grace returns empty (got '$out')"

# ─── Test 4: 36h boundary just under (now - 36h + 60s) → returns ts ───────
# 60s under the 36h threshold should still return.
TMP=$(mkstate)
write_anchor "$TMP" "t4" "1700000000.000400" "$YESTERDAY"
backdate "$TMP/t4/daily-thread.ts" $((129600 - 60))
out=$(get_anchor "$TMP" t4)
[[ "$out" == "1700000000.000400" ]] && pass "36h boundary under returns ts" \
    || fail "36h boundary under returns ts (got '$out')"

# ─── Test 5: 36h boundary just over (now - 36h - 60s) → returns empty ─────
# 60s over the 36h threshold should NOT return.
TMP=$(mkstate)
write_anchor "$TMP" "t5" "1700000000.000500" "$YESTERDAY"
backdate "$TMP/t5/daily-thread.ts" $((129600 + 60))
out=$(get_anchor "$TMP" t5)
[[ -z "$out" ]] && pass "36h boundary over returns empty" \
    || fail "36h boundary over returns empty (got '$out')"

# ─── Test 6: missing daily-thread.ts → returns empty ─────────────────────
TMP=$(mkstate)
mkdir -p "$TMP/t6"
# .day file present, .ts file absent
printf '%s' "$TODAY" > "$TMP/t6/daily-thread.ts.day"
out=$(get_anchor "$TMP" t6)
[[ -z "$out" ]] && pass "missing daily-thread.ts returns empty" \
    || fail "missing daily-thread.ts returns empty (got '$out')"

# ─── Test 7: missing daily-thread.ts.day → returns empty ─────────────────
TMP=$(mkstate)
mkdir -p "$TMP/t7"
printf '%s' "1700000000.000700" > "$TMP/t7/daily-thread.ts"
out=$(get_anchor "$TMP" t7)
[[ -z "$out" ]] && pass "missing daily-thread.ts.day returns empty" \
    || fail "missing daily-thread.ts.day returns empty (got '$out')"

# ─── Test 8: ANCHOR_GRACE_SEC override honored ────────────────────────────
# Set ANCHOR_GRACE_SEC=3600 (1h). A 2h-old anchor should then return empty
# even though the default 36h grace would have accepted it.
TMP=$(mkstate)
write_anchor "$TMP" "t8" "1700000000.000800" "$YESTERDAY"
backdate "$TMP/t8/daily-thread.ts" 7200  # 2h ago
out=$(get_anchor "$TMP" t8 env ANCHOR_GRACE_SEC=3600)
[[ -z "$out" ]] && pass "ANCHOR_GRACE_SEC=3600 rejects 2h-old anchor" \
    || fail "ANCHOR_GRACE_SEC=3600 rejects 2h-old anchor (got '$out')"

# And a 30-min-old anchor under the same 1h override should be accepted.
TMP=$(mkstate)
write_anchor "$TMP" "t8b" "1700000000.000801" "$YESTERDAY"
backdate "$TMP/t8b/daily-thread.ts" 1800  # 30min ago
out=$(get_anchor "$TMP" t8b env ANCHOR_GRACE_SEC=3600)
[[ "$out" == "1700000000.000801" ]] && pass "ANCHOR_GRACE_SEC=3600 accepts 30m-old anchor" \
    || fail "ANCHOR_GRACE_SEC=3600 accepts 30m-old anchor (got '$out')"

# ─── Test 9: no anchor at all (no files) → returns empty ─────────────────
TMP=$(mkstate)
out=$(get_anchor "$TMP" t9)
[[ -z "$out" ]] && pass "no anchor files returns empty" \
    || fail "no anchor files returns empty (got '$out')"

# ─── Summary ──────────────────────────────────────────────────────────────
echo ""
if [[ "$FAILED" -gt 0 ]]; then
    echo "FAILED: $FAILED test(s), PASSED: $PASSED"
    exit 1
fi
echo "PASSED: $PASSED test(s)"
