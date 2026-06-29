#!/usr/bin/env bash
# test_hermes_watchdog_ports.sh — RED-GREEN test for hermes-watchdog.sh
# port assignments. Verifies the script checks prod=8643 and staging=8644
# (the actual live ports) rather than the old 8642/8643 mapping.
#
# This test would have caught the 2026-06-13 prod-down silent alert:
# the watchdog was checking port 8642 for "prod" but actual prod is on 8643,
# so the script reported "DOWN" for a non-existent port, then alerted
# correctly — but the post-fix verification would have shown port 8643 is
# the correct one to check, and the misroute would have been visible from
# the first failed curl.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WATCHDOG="$REPO_ROOT/scripts/hermes-watchdog.sh"
[[ -f "$WATCHDOG" ]] || { echo "FAIL: watchdog not found at $WATCHDOG"; exit 1; }

PASSED=0
FAILED=0
pass() { echo "PASS: $1"; PASSED=$((PASSED + 1)); }
fail() { echo "FAIL: $1 — got '$2'"; FAILED=$((FAILED + 1)); }

# 1. Watchdog source must check port 8643 for prod
if grep -qE 'check_gateway "prod" 8643\b' "$WATCHDOG"; then
  pass "watchdog checks prod on port 8643 (live prod port)"
else
  fail "watchdog checks prod on port 8643" "$(grep -E 'check_gateway "prod"' "$WATCHDOG")"
fi

# 2. Watchdog source must check port 8644 for staging
if grep -qE 'check_gateway "staging" 8644\b' "$WATCHDOG"; then
  pass "watchdog checks staging on port 8644 (live staging port)"
else
  fail "watchdog checks staging on port 8644" "$(grep -E 'check_gateway "staging"' "$WATCHDOG")"
fi

# 3. Watchdog must NOT still check port 8642 for prod (the bug)
if grep -qE 'check_gateway "prod" 8642\b' "$WATCHDOG"; then
  fail "watchdog no longer checks prod on port 8642 (legacy wrong port)" "still present"
else
  pass "watchdog no longer checks prod on port 8642"
fi

# 4. Watchdog alert message must reference 8643, not 8642
if grep -q "Hermes prod gateway DOWN (port 8643)" "$WATCHDOG"; then
  pass "watchdog alert message references port 8643"
else
  fail "watchdog alert message references port 8643" "missing or wrong"
fi

# 5. RED proof — the pre-fix script checked port 8642 for prod
# (This is just a static source check; if 8642 is absent, the regression would have been caught.)
if ! grep -qE '"prod" 8642\b' "$WATCHDOG"; then
  pass "RED proof: pre-fix port 8642 mapping is gone"
else
  fail "RED proof: pre-fix port 8642 mapping is gone" "still present"
fi

echo ""
echo "Summary: $PASSED passed, $FAILED failed"
[[ "$FAILED" -eq 0 ]] && exit 0 || exit 1
