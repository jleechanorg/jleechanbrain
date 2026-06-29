#!/usr/bin/env bash
# hermes-staging-stop.sh — Bring down Hermes staging gateway
# Usage: bash hermes-staging-stop.sh
set -uo pipefail

STAGING_LABEL="ai.smartclaw.staging"
STAGING_PORT="${HERMES_STAGING_PORT:-8644}"
TIMEOUT="${STOP_TIMEOUT:-10}"

echo "=== Hermes Staging Stop ==="
echo "  Label : $STAGING_LABEL"
echo "  Port  : $STAGING_PORT"

# Check if running
if ! lsof -i ":${STAGING_PORT}" -sTCP:LISTEN 2>/dev/null | grep -qv "^COMMAND"; then
    echo "  INFO: Staging gateway not running on port $STAGING_PORT"
    exit 0
fi

# Graceful unload via launchd — if not registered, fall back to direct kill
if launchctl list 2>/dev/null | grep -q "ai.smartclaw.staging"; then
    echo "  Unloading launchd service..."
    launchctl unload -w "$HOME/Library/LaunchAgents/${STAGING_LABEL}.plist" 2>/dev/null || true
    sleep 2
else
    echo "  Service not registered in launchd (already stopped or orphaned process)"
fi

# Kill any remaining process on the staging port
echo "  Checking for orphaned gateway process..."
_pids=$(lsof -ti ":${STAGING_PORT}" 2>/dev/null || true)
if [[ -n "$_pids" ]]; then
    echo "  Killing orphaned process(es) on port ${STAGING_PORT}: $_pids"
    kill -TERM $_pids 2>/dev/null || true
    sleep 3
    # Force kill if still alive
    _remaining=$(lsof -ti ":${STAGING_PORT}" 2>/dev/null || true)
    if [[ -n "$_remaining" ]]; then
        echo "  Force-killing remaining process(es): $_remaining"
        kill -9 $_remaining 2>/dev/null || true
        sleep 1
    fi
fi

# Verify it's gone
sleep 1
if lsof -i ":${STAGING_PORT}" -sTCP:LISTEN 2>/dev/null | grep -qv "^COMMAND"; then
    echo "  FAIL: Port $STAGING_PORT still in use after stop"
    exit 1
else
    echo "  Staging gateway stopped (port $STAGING_PORT free)"
fi