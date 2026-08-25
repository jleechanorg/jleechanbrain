#!/usr/bin/env bash
# Smoke test: run skeptic_auto_merge.py in dry-run mode against a single
# jleechanorg/* repo, verify it enumerates PRs, logs gate failures, and
# NEVER calls `gh pr merge` (which would be a real merge).
#
# Usage:
#   bash tests/scripts/test_skeptic_auto_merge_dryrun.sh
#
# Exit codes:
#   0 — dry-run completed successfully
#   1 — dry-run found an unexpected merge call (test failure)
#   2 — dry-run encountered an unexpected error (test failure)
set -euo pipefail

REPO="${REPO:-jleechanorg/jleechanbrain}"
SCRIPT="${SCRIPT:-scripts/skeptic_auto_merge.py}"

if [[ ! -f "$SCRIPT" ]]; then
  echo "[FAIL] $SCRIPT not found — run from repo root" >&2
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "[FAIL] gh CLI not found" >&2
  exit 2
fi

unset GITHUB_TOKEN
GH_TOKEN="${GH_TOKEN:-}"
if [[ -z "$GH_TOKEN" ]]; then
  GH_TOKEN=$(gh auth token 2>/dev/null || echo "")
fi

# Capture stderr to a logfile for inspection
LOGFILE="$(mktemp)"
trap 'rm -f "$LOGFILE"' EXIT

echo "[INFO] Running dry-run against $REPO"
echo "[INFO] Logfile: $LOGFILE"

# Use --repo to scope to a single repo so the test is bounded
# (the full glob takes ~1 min to enumerate 108 repos).
SKEPTIC_AUTO_MERGE=true SKEPTIC_DRY_RUN=true python3 "$SCRIPT" \
  --dry-run --verbose --repo "$REPO" \
  2> "$LOGFILE"

# Verify no gh pr merge was attempted
if grep -q "gh pr merge\|MERGE_RESULT\|Successfully merged" "$LOGFILE"; then
  echo "[FAIL] dry-run attempted a merge — review the script" >&2
  cat "$LOGFILE" >&2
  exit 1
fi

# Verify at least one gate evaluation happened (any gate1..gate6 reference)
if ! grep -qE 'gate[1-6]-' "$LOGFILE"; then
  echo "[FAIL] no gate evaluations found in output — script may not be working" >&2
  cat "$LOGFILE" >&2
  exit 2
fi

echo "[OK] Dry-run completed safely. $REPO evaluated, gates logged, no merges attempted."
