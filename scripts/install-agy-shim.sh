#!/usr/bin/env bash
# install-agy-shim.sh — install the agy-shim launchd job.
#
# Substitutes @HOME@ and @PATH_AGY@ placeholders in the plist template,
# copies to ~/Library/LaunchAgents/, then loads it. Idempotent: re-running
# boots out the existing job first.
#
# Usage:
#   ./scripts/install-agy-shim.sh           # install + bootout/bootstrap
#   ./scripts/install-agy-shim.sh --uninstall   # bootout + remove plist

set -euo pipefail

PLIST_NAME="com.jleechan.agy-shim"
TEMPLATE="$(cd "$(dirname "$0")/.." && pwd)/launchd/${PLIST_NAME}.plist.template"
DEST="$HOME/Library/LaunchAgents/${PLIST_NAME}.plist"

VENV_PY="$(cd "$(dirname "$0")/.." && pwd)/.venv/bin/python3"
if [[ ! -x "$VENV_PY" ]]; then
  VENV_PY="/usr/bin/python3"
fi

# Discover agy's parent dir so the plist env.PATH lets the shim's subprocess
# find `agy` even if the launchd env doesn't inherit our shell PATH.
AGY_BIN_PATH="$(command -v agy || echo "$HOME/.local/bin/agy")"
PATH_AGY="$(dirname "$AGY_BIN_PATH"):/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$HOME/.local/bin:$HOME/.bun/bin"

uninstall() {
  launchctl bootout "gui/$UID/${PLIST_NAME}" 2>/dev/null || true
  rm -f "$DEST"
  echo "Uninstalled ${PLIST_NAME}."
}

install() {
  if [[ ! -f "$TEMPLATE" ]]; then
    echo "Template not found: $TEMPLATE" >&2
    exit 1
  fi
  # Substitute @HOME@, @PATH_AGY@, and @VENV_PY@ placeholders.
  mkdir -p "$(dirname "$DEST")"
  sed -e "s|@HOME@|$HOME|g" \
      -e "s|@PATH_AGY@|$PATH_AGY|g" \
      -e "s|@VENV_PY@|$VENV_PY|g" \
      "$TEMPLATE" > "$DEST"
  echo "Wrote $DEST"

  # Bootout any existing instance, then bootstrap fresh.
  launchctl bootout "gui/$UID/${PLIST_NAME}" 2>/dev/null || true
  launchctl bootstrap "gui/$UID" "$DEST"
  launchctl enable "gui/$UID/${PLIST_NAME}"
  launchctl kickstart -k "gui/$UID/${PLIST_NAME}"
  echo "Started ${PLIST_NAME}. Health: curl -fsS http://127.0.0.1:8766/health"
}

case "${1:-install}" in
  --uninstall|-u|uninstall) uninstall ;;
  --help|-h) sed -n '2,12p' "$0" ;;
  *) install ;;
esac