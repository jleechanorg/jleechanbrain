#!/usr/bin/env bash
# Retention Nudge Wrapper
# Runs the retention_nudge.py script with proper environment and Python 3.11
#
# Dry-run mode (default): finds inactive users, generates nudges, emails summary to jleechan@gmail.com
# No writes to Firestore, no emails to actual users.
#
# To execute for real: pass --execute flag to the python script
# (typically via launchd running this wrapper with different args)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_ROOT="${HOME}/.worktrees/worldarchitect/wa-2228"

# Environment
export HOME="/Users/jleechan"
export WORLDAI_DEV_MODE="true"
export GOOGLE_APPLICATION_CREDENTIALS="${HOME}/serviceAccountKey.json"
export TZ="America/Los_Angeles"

# Python 3.11 path (system Homebrew, firebase-admin compatible)
PYTHON_BIN="/opt/homebrew/bin/python3.11"

# Log output
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_DIR="${HOME}/.smartclaw/logs/scheduled-jobs"
mkdir -p "$LOG_DIR"
STDOUT_LOG="$LOG_DIR/retention-nudge.out.log"
STDERR_LOG="$LOG_DIR/retention-nudge.err.log"

echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] Retention Nudge starting (dry-run mode)" >> "$STDOUT_LOG"

# Run the script - always dry-run by default (no --execute)
cd "$WORKTREE_ROOT"
"$PYTHON_BIN" scripts/retention_nudge.py \
    --days 7 \
    --max-nudges 5 \
    >> "$STDOUT_LOG" 2>> "$STDERR_LOG"

EXIT_CODE=$?
echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] Retention Nudge finished with exit code $EXIT_CODE" >> "$STDOUT_LOG"
exit $EXIT_CODE