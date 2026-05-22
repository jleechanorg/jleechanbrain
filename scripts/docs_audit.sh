#!/usr/bin/env bash
# Captures a system snapshot and doc-gap report to docs/context/.
# Output is ANSI-stripped and home-path-normalized for GitHub readability.
set -euo pipefail

ROOT="${HERMES_ROOT:-$HOME/.smartclaw}"
CTX="$ROOT/docs/context"
SNAP="$CTX/SYSTEM_SNAPSHOT.md"
GAPS="$CTX/DOC_GAPS.md"

# Strip ANSI color codes and normalize home paths
sanitize() { sed -E $'s/\x1b\\[[0-9;]*m//g' | sed -E "s|$HOME/|~/|g"; }

mkdir -p "$CTX"

{
  echo "# System Snapshot"
  echo
  echo "Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  echo
  echo "## Hermes version"
  (cd "$ROOT" && git describe --tags --always 2>/dev/null || echo "(unknown)") | sanitize
  echo
  echo "## Cron jobs"
  echo "(see CRON_JOBS_BACKUP.md for current job list)"
  echo
  echo "## Diagnostics flags"
  echo "(see hermes logs for runtime diagnostics)"
} > "$SNAP"

missing=0
: > "$GAPS"
echo "# Documentation Gap Report" >> "$GAPS"
echo >> "$GAPS"
echo "Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')" >> "$GAPS"
echo >> "$GAPS"

for f in PRODUCT.md WORKFLOWS.md FILE_MAP.md LEARNINGS.md PROMPTING_GUIDES.md; do
  if [[ ! -s "$CTX/$f" ]]; then
    echo "- Missing or empty: docs/context/$f" >> "$GAPS"
    missing=1
  fi
done

if [[ $missing -eq 0 ]]; then
  echo "- No required doc gaps detected." >> "$GAPS"
fi

echo "Wrote: $SNAP"
echo "Wrote: $GAPS"
