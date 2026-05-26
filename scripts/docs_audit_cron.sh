#!/usr/bin/env bash
# Docs audit cron wrapper: runs docs_audit.sh, only outputs to stdout if gaps found.
# When no_agent=true, stdout becomes the Slack message. Empty stdout = silent.
set -euo pipefail

ROOT="${HERMES_ROOT:-$HOME/.hermes}"
GAPS="$ROOT/docs/context/DOC_GAPS.md"

# Run the actual audit (always updates snapshot + gaps file)
bash "$ROOT/scripts/docs_audit.sh" >/dev/null 2>&1

# Check if any real gaps were found (skip the "No required doc gaps" line)
if [[ -f "$GAPS" ]] && grep -qE 'Missing or empty' "$GAPS" 2>/dev/null; then
  version=$(cd "$ROOT" && git describe --tags --always 2>/dev/null || echo "unknown")
  gaps_list=$(grep -E 'Missing or empty' "$GAPS")
  echo "⚠️ Hermes Docs Audit found gaps (v${version}):"
  echo "$gaps_list"
  echo "See $GAPS for details."
fi
# If no gaps, stdout is empty → cron delivers nothing (silent)
