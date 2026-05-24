#!/usr/bin/env bash
# git-push-or-codex.sh — Push a repo to origin/main; if it fails, use codex to fix.
# Usage: git-push-or-codex.sh <repo-path>
set -euo pipefail

REPO="${1:?Usage: $0 <repo-path>}"
LOG_TAG="[$(basename "$REPO")]"
MAX_CODEX_RETRIES=2

if [ ! -d "$REPO/.git" ]; then
  echo "$LOG_TAG ERROR: $REPO is not a git repo" >&2
  exit 1
fi

cd "$REPO"

echo "$LOG_TAG === Run started $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

# --- Step 1: Stage + commit anything dirty ---
if git diff --quiet && git diff --cached --quiet && [ -z "$(git ls-files --others --exclude-standard)" ]; then
  echo "$LOG_TAG No local changes to commit."
else
  echo "$LOG_TAG Staging and committing local changes..."
  git add -A
  # Allow empty commit so we don't fail if nothing actually staged after add
  git commit --allow-empty-message -m "" 2>&1 || true
  echo "$LOG_TAG Commit done."
fi

# --- Step 2: Try git push ---
echo "$LOG_TAG Attempting git push origin main..."
if git push origin main 2>&1; then
  echo "$LOG_TAG Push succeeded."
  echo "$LOG_TAG === Run finished $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  exit 0
fi

echo "$LOG_TAG Push FAILED. Entering codex recovery..."

# --- Step 3: Codex recovery ---
ATTEMPT=0
while [ $ATTEMPT -lt $MAX_CODEX_RETRIES ]; do
  ATTEMPT=$((ATTEMPT + 1))
  echo "$LOG_TAG Codex attempt $ATTEMPT/$MAX_CODEX_RETRIES..."

  if codex exec --yolo \
    "In the current directory ($(pwd)), fix whatever is preventing 'git push origin main' from succeeding. \
Common issues: merge conflicts, divergence from remote, auth problems, dirty state. \
Resolve them and push. Do NOT force-push. After fixing, run 'git push origin main' and confirm it succeeds." \
    2>&1; then

    # Verify the push actually worked
    if git push origin main 2>&1; then
      echo "$LOG_TAG Codex recovery succeeded on attempt $ATTEMPT."
      echo "$LOG_TAG === Run finished $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
      exit 0
    else
      echo "$LOG_TAG Codex ran but push still fails. Retrying..."
    fi
  else
    echo "$LOG_TAG Codex exec failed (exit $?). Retrying..."
  fi
done

echo "$LOG_TAG All codex recovery attempts exhausted. Manual intervention needed." >&2
echo "$LOG_TAG === Run FAILED $(date -u +%Y-%m-%dT%H:%M:%SZ) ===" >&2
exit 1
