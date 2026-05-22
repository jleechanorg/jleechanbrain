#!/usr/bin/env bash
set -euo pipefail

# Hermes Full Setup Script
# Sets up Hermes with automated backups on a new machine
#
# Usage:
#   ./scripts/setup-hermes-full.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== Hermes Full Setup ==="
echo "Repository: $REPO_ROOT"
echo

# Check if we're in the right location
if [[ ! -f "$REPO_ROOT/scripts/setup-hermes-full.sh" ]]; then
    echo "ERROR: Must run from hermes repository root" >&2
    exit 1
fi

# Step 1: Check prerequisites
echo "[1/4] Checking prerequisites..."
if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 is required but not installed" >&2
    exit 1
fi

if ! command -v git >/dev/null 2>&1; then
    echo "ERROR: git is required but not installed" >&2
    exit 1
fi

echo "  ✓ python3 found: $(python3 --version)"
echo "  ✓ git found: $(git --version)"
echo

# Step 2: Detect if this repo should be placed in ~/.smartclaw/workspace/
echo "[2/4] Detecting installation location..."

# Check if we're already in ~/.smartclaw/workspace/hermes
if [[ "$REPO_ROOT" == "$HOME/.smartclaw/workspace/hermes" ]]; then
    echo "  ✓ Already in ~/.smartclaw/workspace/hermes"
    HERMES_REPO="$REPO_ROOT"
elif [[ -d "$HOME/.smartclaw/workspace/hermes" ]]; then
    echo "  ✓ Found existing ~/.smartclaw/workspace/hermes"
    HERMES_REPO="$HOME/.smartclaw/workspace/hermes"
    echo "  ! Using existing installation, will copy scripts there"
else
    echo "  → Creating ~/.smartclaw/workspace/hermes"
    mkdir -p "$HOME/.smartclaw/workspace"

    # Ask user if they want to move or copy
    read -p "  Copy (c) or Move (m) this repo to ~/.smartclaw/workspace/hermes? [c/m]: " choice
    case "$choice" in
        m|M)
            echo "  → Moving repository..."
            mv "$REPO_ROOT" "$HOME/.smartclaw/workspace/hermes"
            HERMES_REPO="$HOME/.smartclaw/workspace/hermes"
            cd "$HERMES_REPO"
            ;;
        c|C|*)
            echo "  → Copying repository..."
            cp -R "$REPO_ROOT" "$HOME/.smartclaw/workspace/hermes"
            HERMES_REPO="$HOME/.smartclaw/workspace/hermes"
            ;;
    esac
fi

echo "  Hermes repo: $HERMES_REPO"
echo

# Step 3: Copy scripts to hermes repo if needed
echo "[3/4] Setting up backup scripts..."
if [[ "$REPO_ROOT" != "$HERMES_REPO" ]]; then
    echo "  → Copying scripts to $HERMES_REPO"
    cp -v "$REPO_ROOT"/scripts/*backup* "$HERMES_REPO/scripts/" || true
    cp -v "$REPO_ROOT"/scripts/run-hermes-backup.sh "$HERMES_REPO/scripts/" || true
    cp -v "$REPO_ROOT"/docs/hermes-backup-jobs.md "$HERMES_REPO/docs/" || true
fi

# Make scripts executable
chmod +x "$HERMES_REPO"/scripts/*.sh

echo "  ✓ Backup scripts ready"
echo

# Step 4: Install backup jobs
echo "[4/4] Installing backup jobs (launchd only)..."
cd "$HERMES_REPO"
"$HERMES_REPO/scripts/install-hermes-backup-jobs.sh"

echo
echo "=== Setup Complete! ==="
echo
echo "Hermes is now configured with automated backups:"
echo "  • Launchd: Every 4 hours"
echo "  • System crontab: not used for Hermes backup automation"
echo "  • Backups: $HERMES_REPO/.smartclaw-backups/"
echo
echo "To test the backup:"
echo "  cd $HERMES_REPO"
echo "  ./scripts/run-hermes-backup.sh"
echo
echo "To view logs:"
echo "  tail -f ~/Library/Logs/hermes-backup/hermes-backup.log"
echo
