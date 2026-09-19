#!/usr/bin/env bash
# Install the three git hooks that re-canonicalize a tracked append-only log file
# on every commit, merge, and checkout.
#
# Idempotent: re-running overwrites all three hooks with the latest version.
# Per-clone: hooks don't transfer across clones (git's design), so every fresh
# clone needs to run this once.
#
# Adapt the SORTER variable to your canonicalizer path.

set -euo pipefail

# === ADAPT THESE TWO LINES FOR YOUR REPO ===
REPO_ROOT="$(git rev-parse --show-toplevel)"
SORTER="$REPO_ROOT/scripts/<your-canonicalizer>.py"
TARGET_FILE="<path/to/your/log.file>"   # path checked inside hooks
# ==========================================

HOOKS_DIR="$(git rev-parse --git-path hooks)"
mkdir -p "$HOOKS_DIR"

write_hook() {
  local hook_name="$1"
  local hook_file="$HOOKS_DIR/$hook_name"
  cat > "$hook_file" << INNER
#!/usr/bin/env bash
# Auto-installed by $(basename "$0") — re-runs the canonicalizer
# after $hook_name to keep $TARGET_FILE clean.
set -euo pipefail

if [ ! -x "$SORTER" ]; then
  # Don't block the user's workflow if the canonicalizer is missing.
  exit 0
fi

case "$hook_name" in
  pre-commit)
    if git diff --cached --name-only | grep -q "^${TARGET_FILE//./\\.}\$"; then
      "$SORTER"
      git add "$TARGET_FILE"
    fi
    ;;
  post-merge)
    # Unconditionally re-canonicalize after any merge — defense-in-depth for
    # contributors who might not have the pre-commit hook installed.
    "$SORTER"
    ;;
  post-checkout)
    # Only re-canonicalize when the checked-out tree updates TARGET_FILE
    # (e.g. switching between worktrees where main has new records).
    if git diff --name-only HEAD@{1} HEAD 2>/dev/null | grep -q "^${TARGET_FILE//./\\.}\$"; then
      "$SORTER"
    fi
    ;;
esac
INNER
  chmod +x "$hook_file"
}

write_hook pre-commit
write_hook post-merge
write_hook post-checkout

echo "Installed 3 hooks at $HOOKS_DIR: pre-commit, post-merge, post-checkout"
echo "Test it: stage a change to $TARGET_FILE and run git commit"
