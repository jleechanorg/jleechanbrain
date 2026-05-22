#!/bin/bash
# Hermes Startup Verification
# Purpose: Runs after login to verify Hermes is running and send confirmation

LOG_FILE="$HOME/.smartclaw/logs/startup-check.log"
LOG_DIR="$(dirname "$LOG_FILE")"
export PATH="$HOME/.nvm/versions/node/current/bin:$HOME/.nvm/versions/node/v22.22.0/bin:$HOME/Library/pnpm:$HOME/.bun/bin:$HOME/.local/bin:$HOME/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
TARGET="${HERMES_WHATSAPP_TARGET:-}"
TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")

resolve_hermes_bin() {
    local candidate
    for candidate in \
        "$(command -v hermes 2>/dev/null || true)" \
        "$HOME/.nvm/versions/node/current/bin/hermes" \
        "$HOME/.nvm/versions/node/v22.22.0/bin/hermes" \
        "$HOME/Library/pnpm/hermes" \
        "$HOME/.bun/bin/hermes" \
        "/opt/homebrew/bin/hermes" \
        "/usr/local/bin/hermes"
    do
        if [ -n "$candidate" ] && [ -x "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

HERMES_BIN="$(resolve_hermes_bin || true)"

# Ensure hermes CLI exists
if [ -z "$HERMES_BIN" ]; then
    echo "[$TIMESTAMP] ❌ hermes CLI not found; PATH=$PATH" >&2
    exit 1
fi

# Ensure log directory exists
if ! mkdir -p "$LOG_DIR"; then
    echo "[$TIMESTAMP] ❌ Failed to create log directory: $LOG_DIR" >&2
    exit 1
fi

if [ -z "$TARGET" ]; then
    echo "[$TIMESTAMP] ℹ️ HERMES_WHATSAPP_TARGET is not set; skipping startup confirmation." >> "$LOG_FILE"
    exit 0
fi

# Wait for network to be available (max 30 seconds)
for i in {1..30}; do
    if ping -c 1 8.8.8.8 &> /dev/null; then
        break
    fi
    sleep 1
done

# Wait for Hermes to start (max 30 seconds)
for i in {1..30}; do
    # Check new label first, then fall back to legacy label for migration.
    LABEL=""
    if launchctl list | grep -q "ai.smartclaw.gateway"; then
        LABEL="ai.smartclaw.gateway"
    elif launchctl list | grep -q "com.smartclaw.gateway"; then
        LABEL="com.smartclaw.gateway"
    fi
    if [[ -n "$LABEL" ]]; then
        PID=$(launchctl list | grep "$LABEL" | awk '{print $1}')
        if [ "$PID" != "-" ] && [ -n "$PID" ]; then
            echo "[$TIMESTAMP] ✅ Hermes started successfully (PID: $PID, label: $LABEL)" >> "$LOG_FILE"

            # Wait a bit more for WhatsApp to connect
            sleep 10

            # Send startup confirmation via WhatsApp
            if "$HERMES_BIN" channels list | grep -q "WhatsApp default: linked, enabled"; then
                if "$HERMES_BIN" message send --target "$TARGET" \
                    --message "🚀 Hermes auto-started successfully (PID: $PID) ✅" \
                    --channel whatsapp >> "$LOG_FILE" 2>&1; then
                    echo "[$TIMESTAMP] ✅ Startup confirmation sent via WhatsApp" >> "$LOG_FILE"
                else
                    echo "[$TIMESTAMP] ❌ Failed to send startup confirmation via WhatsApp" >> "$LOG_FILE"
                    exit 1
                fi
            else
                echo "[$TIMESTAMP] ⚠️  WhatsApp not ready yet" >> "$LOG_FILE"
            fi

            exit 0
        fi
    fi
    sleep 1
done

echo "[$TIMESTAMP] ❌ Hermes failed to start within 30 seconds" >> "$LOG_FILE"
exit 1
