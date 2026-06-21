#!/usr/bin/env bash
# hermes-staging-stop.sh — Stop and disable the staging Hermes gateway.
# Staging should only run during deploy testing. Run this after any staging test.
# Usage: bash scripts/hermes-staging-stop.sh

set -u
LABEL="ai.smartclaw.gateway"
DOMAIN="gui/$(id -u)"

echo "Stopping Hermes staging gateway ($LABEL)..."

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null && echo "  Stopped" || echo "  (already stopped)"
launchctl disable "$DOMAIN/$LABEL" 2>/dev/null && echo "  Disabled (won't auto-start on login)"

# Verify it's gone
if launchctl print "$DOMAIN/$LABEL" 2>&1 | grep -q '"PID" = [0-9]'; then
    echo "  WARNING: process still running — may need: kill -9 $(pgrep -f 'hermes.*gateway.*run' | head -1)"
else
    echo "  Confirmed: staging is not running"
fi

# Verify prod is still healthy
PROD_HEALTH=$(curl -sf -m 5 http://127.0.0.1:8643/health 2>/dev/null)
if echo "$PROD_HEALTH" | grep -q '"ok"'; then
    echo "  Prod gateway: healthy"
else
    echo "  WARNING: prod gateway health check failed — check http://127.0.0.1:8643/health"
fi
