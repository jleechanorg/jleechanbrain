#!/usr/bin/env bash
# hermes-monitor.sh — Validates Hermes staging + prod gateways
# Usage: bash scripts/hermes-monitor.sh

set -u

HERMES_BIN="${HERMES_BIN:-hermes}"
HERMES_STAGING_HOME="${HERMES_STAGING_HOME:-${HOME}/.smartclaw}"
HERMES_PROD_HOME="${HERMES_PROD_HOME:-${HOME}/.smartclaw_prod}"

PASS=0
FAIL=0
WARN=0

pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }
warn() { printf '[WARN] %s\n' "$1"; WARN=$((WARN+1)); }
info() { printf '[INFO] %s\n' "$1"; }

echo "=== Hermes Monitor ==="
echo ""

# ── Hermes staging (should NOT be running between deploys) ────
# Staging gateway is disabled between deploy cycles to reduce resource contention.
# If it's running here, that's unexpected — warn so it can be shut down.
info "Hermes staging (HERMES_HOME=$HERMES_STAGING_HOME)"

STAGING_GW=$(HERMES_HOME="$HERMES_STAGING_HOME" "$HERMES_BIN" gateway status 2>&1)
if echo "$STAGING_GW" | grep -qE '"PID" = [0-9]+'; then
    warn "Hermes staging gateway RUNNING (should be disabled outside deploy) — run: bash ~/.smartclaw/scripts/hermes-staging-stop.sh"
else
    pass "Hermes staging gateway idle (expected)"
fi

# Only check Slack/conflicts if staging is actually running
if echo "$STAGING_GW" | grep -qE '"PID" = [0-9]+'; then
    if echo "$STAGING_GW" | grep -q "token already in use"; then
        CONFLICT=$(echo "$STAGING_GW" | grep 'token already in use' | head -1 | sed 's/^[ ]*⚠ //' | sed 's/ Stop.*//')
        warn "Hermes staging platform conflict (non-Slack): $CONFLICT"
    fi
fi

echo ""

# ── Hermes prod ───────────────────────────────────────────────
# hermes gateway status always looks for ai.smartclaw.gateway.plist regardless of
# HERMES_HOME, so it misreports prod which runs under the ai.smartclaw.prod label.
# Use HTTP health + launchd directly instead.
HERMES_PROD_PORT="${HERMES_PROD_PORT:-8643}"
info "Hermes prod (HERMES_HOME=$HERMES_PROD_HOME, port $HERMES_PROD_PORT)"

PROD_HTTP=$(curl -sf -m 5 "http://127.0.0.1:${HERMES_PROD_PORT}/health" 2>/dev/null)
if echo "$PROD_HTTP" | grep -q '"ok"\|"status"'; then
    pass "Hermes prod gateway running (HTTP health OK)"
else
    fail "Hermes prod gateway NOT responding on :${HERMES_PROD_PORT}"
fi

PROD_STAT=$(HERMES_HOME="$HERMES_PROD_HOME" "$HERMES_BIN" status 2>&1)
if echo "$PROD_STAT" | grep "Slack" | grep -q "✓"; then
    pass "Hermes prod Slack: configured"
elif echo "$PROD_STAT" | grep "Slack" | grep -q "✗"; then
    fail "Hermes prod Slack: error"
else
    warn "Hermes prod Slack: unknown"
fi

# Token conflict check: use hermes status (which connects to the running gateway)
PROD_GW=$(HERMES_HOME="$HERMES_PROD_HOME" "$HERMES_BIN" gateway status 2>&1)
if echo "$PROD_GW" | grep -q "token already in use"; then
    fail "Hermes prod platform conflict: $(echo "$PROD_GW" | grep 'token already in use' | head -1)"
else
    pass "Hermes prod no token conflicts"
fi

echo ""

# ── Summary ────────────────────────────────────────────────────
echo "=== Summary: PASS=$PASS FAIL=$FAIL WARN=$WARN ==="
[[ $FAIL -gt 0 ]] && exit 1 || exit 0
