#!/usr/bin/env bash
# check-spawn-from-worktree.sh
#
# Verifies that the current shell was spawned by AO into a worktree of
# jleechanorg/jleechanbrain with the expected branch naming convention and
# the AO hook wiring intact. Used as a pre-flight sanity check at the
# start of an AO session and as a CI smoke test before merge.
#
# Invariants enforced (any failure → exit 1):
#   1. cwd resolves to a path containing a `.worktrees/` segment
#   2. `origin` remote URL normalizes to the canonical
#      `https://github.com/jleechanorg/jleechanbrain.git`
#      (or its `git@` SSH form). Substring matches such as `*-mirror.git`
#      are REJECTED — CLAUDE.md requires the exact canonical remote.
#   3. current branch is NOT `main`, `master`, or detached HEAD. Any other
#      branch name is accepted (fix/*, feat/*, jc-*, etc. — AO does not
#      enforce a single branch policy per `skills/agento/SKILL.md`).
#   4. working tree has no uncommitted tracked-file modifications
#      (untracked files are allowed — AO scaffolding may create them)
#   5. .claude/settings.json contains non-empty AO PreToolUse/PostToolUse
#      hook entries (JSON-parsed; presence of the key with an empty array
#      does NOT satisfy the invariant).
#
# Usage:
#   bash scripts/check-spawn-from-worktree.sh
#
# Output: a single PASS/FAIL summary line followed by per-invariant
#         detail. Exit 0 on PASS, non-zero on any FAIL.
set -euo pipefail

PASS=1
REASONS=()

pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; PASS=0; REASONS+=("$1"); }

CWD="$(pwd)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'none')"
ORIGIN="$(git remote get-url origin 2>/dev/null || echo 'none')"

echo "=== check-spawn-from-worktree ==="
echo "  cwd    : $CWD"
echo "  branch : $BRANCH"
echo "  origin : $ORIGIN"
echo ""

# 1. cwd must be inside a worktree
if [[ "$CWD" == *"/.worktrees/"* ]]; then
  pass "cwd contains /.worktrees/"
else
  fail "cwd does NOT contain /.worktrees/ (expected worktree-based spawn)"
fi

# 2. origin must normalize to the canonical jleechanorg/jleechanbrain URL.
# Strip optional trailing `.git`, optional embedded credentials (e.g.
# `https://x-access-token:TOKEN@github.com/...` injected by `gh auth`),
# and try both https and ssh forms. This rejects remotes like
# `jleechanbrain-mirror`, `jleechanbrain-fork`, or per-user forks (e.g.
# `${GITHUB_USER}/jleechanbrain`).
canonical_origin() {
  local url="$1"
  # Strip trailing .git if present
  url="${url%.git}"
  # Strip embedded credentials: scheme://user:token@host/...
  url="${url#*://}"
  url="${url#*@}"
  case "$url" in
    github.com/jleechanorg/jleechanbrain)
      return 0 ;;
  esac
  # SSH form
  case "$1" in
    git@github.com:jleechanorg/jleechanbrain.git|git@github.com:jleechanorg/jleechanbrain)
      return 0 ;;
  esac
  return 1
}
if canonical_origin "$ORIGIN"; then
  pass "origin is canonical jleechanorg/jleechanbrain"
else
  fail "origin is NOT canonical jleechanorg/jleechanbrain (got: $ORIGIN)"
fi

# 3. branch must not be main / master / detached HEAD. Any other branch
# (fix/*, feat/*, jc-*, chore/*, etc.) is accepted — AO does not enforce
# a single branch policy per `skills/agento/SKILL.md`.
case "$BRANCH" in
  main|master)
    fail "branch '$BRANCH' is a protected default branch"
    ;;
  HEAD)
    fail "branch is detached HEAD (no branch checked out)"
    ;;
  *)
    pass "branch '$BRANCH' is a non-default branch"
    ;;
esac

# 4. no uncommitted modifications to tracked files
if git diff --quiet 2>/dev/null && git diff --cached --quiet 2>/dev/null; then
  pass "no uncommitted tracked-file modifications"
else
  fail "uncommitted tracked-file modifications present (commit or stash first)"
fi

# 5. .claude/settings.json exists and contains non-empty AO hook entries.
# We parse the JSON to verify at least one command exists under both
# PreToolUse and PostToolUse. A grep for the key alone accepts empty
# arrays (or hook keys with no commands) — that is the bug this guard
# exists to prevent.
SETTINGS=".claude/settings.json"
if [[ ! -f "$SETTINGS" ]]; then
  fail "$SETTINGS not found (AO hooks not wired)"
else
  if ! command -v python3 >/dev/null 2>&1; then
    fail "python3 unavailable — cannot validate AO hook JSON shape"
  else
    # python3 exits 0 iff both PreToolUse and PostToolUse have at least
    # one non-empty `command` entry.
    if SETTINGS_PATH="$SETTINGS" python3 - "$SETTINGS" <<'PY'
import json
import os
import sys

path = sys.argv[1]
try:
    with open(path) as fh:
        data = json.load(fh)
except (OSError, json.JSONDecodeError) as exc:
    print(f"hook-check: cannot parse {path}: {exc}", file=sys.stderr)
    sys.exit(2)

hooks = data.get("hooks") or {}

def has_real_entry(key: str) -> bool:
    entries = hooks.get(key)
    if not isinstance(entries, list) or not entries:
        return False
    for entry in entries:
        # Each entry may be a dict with a `hooks` array of commands, or
        # a bare matcher dict. Walk both shapes looking for a `command`
        # string.
        if not isinstance(entry, dict):
            continue
        sub_hooks = entry.get("hooks")
        if isinstance(sub_hooks, list):
            for sub in sub_hooks:
                if isinstance(sub, dict) and isinstance(sub.get("command"), str) and sub["command"].strip():
                    return True
        if isinstance(entry.get("command"), str) and entry["command"].strip():
            return True
    return False

ok = has_real_entry("PreToolUse") and has_real_entry("PostToolUse")
sys.exit(0 if ok else 1)
PY
    then
      pass ".claude/settings.json has non-empty AO PreToolUse/PostToolUse hook commands"
    else
      fail ".claude/settings.json missing AO hook commands (need non-empty PreToolUse AND PostToolUse)"
    fi
  fi
fi

echo ""
if [[ "$PASS" -eq 1 ]]; then
  echo "✓ spawn-check PASS"
  exit 0
fi
echo "✗ spawn-check FAIL (${#REASONS[@]} invariant(s) violated)"
for r in "${REASONS[@]}"; do
  echo "    - $r"
done
exit 1