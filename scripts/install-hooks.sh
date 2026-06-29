#!/usr/bin/env bash
# scripts/install-hooks.sh
#
# Configure this repo to use .githooks/ as the git hooks path.
# Idempotent — safe to re-run.
#
# What it does:
#   1. Sets core.hooksPath = .githooks (relative to repo root).
#   2. Ensures .githooks/pre-commit is executable.
#   3. Verifies the hook fires on a dry-run (no actual commit).
#
# Usage:
#   bash scripts/install-hooks.sh
set -euo pipefail

REPO_DIR="$(git rev-parse --show-toplevel)"
HOOKS_DIR="$REPO_DIR/.githooks"
PRE_COMMIT="$HOOKS_DIR/pre-commit"

if [[ ! -d "$HOOKS_DIR" ]]; then
  echo "ERROR: $HOOKS_DIR does not exist" >&2
  echo "       Did you forget to git clone with .githooks/?" >&2
  exit 1
fi

if [[ ! -f "$PRE_COMMIT" ]]; then
  echo "ERROR: $PRE_COMMIT does not exist" >&2
  exit 1
fi

# Ensure executable
chmod +x "$PRE_COMMIT"

# Configure git to use the per-repo hooks path
git config core.hooksPath .githooks

echo "✓ Installed git hooks:"
echo "    core.hooksPath = $(git config core.hooksPath)"
echo "    $PRE_COMMIT (executable: $(test -x "$PRE_COMMIT" && echo yes || echo NO))"
echo ""
echo "Test the hook with:"
echo "  .githooks/pre-commit"
echo ""
echo "Or make a dummy commit (will trigger the hook):"
echo "  git commit --allow-empty -m 'test: pre-commit hook smoke'"
