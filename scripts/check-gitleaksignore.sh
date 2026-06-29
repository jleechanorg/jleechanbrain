#!/usr/bin/env bash
# scripts/check-gitleaksignore.sh
#
# Treat .gitleaksignore as a TODO queue, not a permanent fix.
# Flags entries older than 30 days so they surface as remediation work
# (rotate the credential + history rewrite), not as silent suppressions.
#
# The 30-day window is a balance:
#   - Too short (e.g. 7d): false-positive churn for legitimate long-lived
#     intentional suppressions (e.g. local dev secrets, intentional
#     placeholder values).
#   - Too long (e.g. 180d): suppressions become invisible debt.
#   - 30d: forces a monthly review cycle without being noisy.
#
# Format expected in .gitleaksignore:
#   # <comment>
#   path/to/file:rule-id:line-number
#
# Older .gitleaksignore format (no rule-id) is also accepted.
#
# This script does NOT consider the age of the SECRET in the codebase —
# only the age of the suppression entry. The proper fix for any old
# suppression is rotation + history rewrite, tracked separately.
#
# Usage:
#   bash scripts/check-gitleaksignore.sh
#   bash scripts/check-gitleaksignore.sh --max-age 60
set -euo pipefail

REPO_DIR="$(git rev-parse --show-toplevel)"
GITLEAKSIGNORE="$REPO_DIR/.gitleaksignore"

MAX_AGE_DAYS=30
if [[ "${1:-}" == "--max-age" && -n "${2:-}" ]]; then
  MAX_AGE_DAYS="$2"
fi

echo "=== check-gitleaksignore ==="
echo "    Max age: $MAX_AGE_DAYS days"
echo ""

if [[ ! -f "$GITLEAKSIGNORE" ]]; then
  echo "  No .gitleaksignore file — nothing to check"
  echo "  PASS"
  exit 0
fi

# Find the commit that last touched .gitleaksignore (most recent change)
# Use --follow to track renames; if no commits yet, the file is fresh.
if ! git -C "$REPO_DIR" log --oneline --follow -- "$GITLEAKSIGNORE" >/dev/null 2>&1; then
  echo "  WARN: cannot read git history for $GITLEAKSIGNORE"
  echo "  Skipping age check (file may be fresh — no commits yet)"
  exit 0
fi

LAST_TOUCH_COMMIT=$(git -C "$REPO_DIR" log --format=%H -1 --follow -- "$GITLEAKSIGNORE")
LAST_TOUCH_DATE=$(git -C "$REPO_DIR" show -s --format=%cI "$LAST_TOUCH_COMMIT")
LAST_TOUCH_TS=$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$LAST_TOUCH_DATE" "+%s" 2>/dev/null) \
  || LAST_TOUCH_TS=$(date -u -j -f "%Y-%m-%dT%H:%M:%S" "${LAST_TOUCH_DATE%%[+-]*}" "+%s" 2>/dev/null) \
  || LAST_TOUCH_TS=$(date -d "$LAST_TOUCH_DATE" "+%s" 2>/dev/null) \
  || LAST_TOUCH_TS=$(python3 -c "from datetime import datetime, timezone
import sys, re
s = sys.argv[1]
# Strip colon in timezone: -04:00 -> -0400 for fromisoformat
m = re.match(r'(.+)([+-])(\d{2}):(\d{2})$', s)
if m:
    s = m.group(1) + m.group(2) + m.group(3) + m.group(4)
print(int(datetime.fromisoformat(s).timestamp()))" "$LAST_TOUCH_DATE" 2>/dev/null) \
  || LAST_TOUCH_TS=0
# Strip any whitespace/newlines from date output
LAST_TOUCH_TS=$(printf '%s' "$LAST_TOUCH_TS" | tr -d '[:space:]')
# If non-numeric, default to 0
if ! [[ "$LAST_TOUCH_TS" =~ ^[0-9]+$ ]]; then
  LAST_TOUCH_TS=0
fi
NOW_TS=$(date "+%s")

if [[ "$LAST_TOUCH_TS" -eq 0 ]]; then
  echo "  WARN: cannot parse last touch date: $LAST_TOUCH_DATE"
  echo "  Skipping age check"
  exit 0
fi

AGE_DAYS=$(( (NOW_TS - LAST_TOUCH_TS) / 86400 ))

echo "  .gitleaksignore last touched: $LAST_TOUCH_DATE ($AGE_DAYS days ago)"
echo "    Commit: $LAST_TOUCH_COMMIT"
echo ""

# Walk entries. An entry is a non-comment, non-empty line.
OVERDUE=0
TOTAL=0
while IFS= read -r LINE; do
  # Skip blanks and comments
  [[ -z "$LINE" || "$LINE" =~ ^# ]] && continue
  TOTAL=$((TOTAL + 1))
done < "$GITLEAKSIGNORE"

if [[ "$AGE_DAYS" -gt "$MAX_AGE_DAYS" ]]; then
  echo "  ✗ .gitleaksignore has not been reviewed in $AGE_DAYS days (max: $MAX_AGE_DAYS)"
  echo "    $TOTAL suppression(s) need review"
  echo ""
  echo "  Remediation options:"
  echo "    a) If the suppression is still needed: rotate the underlying secret, then"
  echo "       rewrite history to remove the secret and remove the suppression."
  echo "    b) If the suppression is stale (e.g. test fixture no longer exists):"
  echo "       git rm the suppression, or add a date prefix and re-commit."
  echo "    c) If a permanent suppression is correct: convert to a .gitleaks.toml"
  echo "       [allowlist] rule with a date-bounded comment."
  echo ""
  echo "  Then re-run this script to confirm."
  exit 1
else
  echo "  ✓ .gitleaksignore is fresh ($AGE_DAYS days old, max: $MAX_AGE_DAYS)"
  echo "    $TOTAL suppression(s) — review on a $MAX_AGE_DAYS-day cadence"
  exit 0
fi
