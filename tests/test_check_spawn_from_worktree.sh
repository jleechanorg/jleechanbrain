#!/usr/bin/env bash
# test_check_spawn_from_worktree.sh
#
# Verifies that scripts/check-spawn-from-worktree.sh exists and enforces
# the five spawn-check invariants every AO worktree session must satisfy.
#
# The script under test must FAIL (exit non-zero) when ANY invariant is
# violated. This test simulates each violation by mutating a scratch repo,
# invoking the script, and asserting the exit code is non-zero.
#
# Usage:
#   bash tests/test_check_spawn_from_worktree.sh
#
# Returns:
#   0 if all checks pass (script exists + executable + 5 negative-path
#     cases + 1 positive path)
#   1 if any invariant is missing or the script does not behave correctly
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="${REPO_DIR}/scripts/check-spawn-from-worktree.sh"

PASS=0
FAIL=0

echo "=== test_check_spawn_from_worktree ==="
echo ""

# ------------------------------------------------------------------
# Helper: build a scratch git repo that mimics a worktree so we can
# exercise each invariant without poisoning the real repo.
#
# IMPORTANT: the worktree-shaped fixture must live inside a directory
# whose path contains `/.worktrees/` — otherwise invariant 1 (cwd
# check) would fail BEFORE the invariant under test, masking real
# regressions in checks 2-5. We therefore put the parent `.worktrees/`
# directory on disk and create the fixture inside it.
# ------------------------------------------------------------------
WORKTREES_PARENT="$(mktemp -d -t worktrees.XXXXXX)"
# Ensure the parent itself contains the segment the validator checks
# for: it is `/tmp/worktrees.XXXXXX/.worktrees/...`. Since the parent
# basename starts with `worktrees.` (not `.worktrees`), we need the
# fixture path to include a `.worktrees/` segment directly. Use a
# parent named `.worktrees` to satisfy the cwd invariant cleanly.
rm -rf "$WORKTREES_PARENT"
WORKTREES_PARENT="$(mktemp -d -t jc-XXXXXX)/.worktrees"
mkdir -p "$WORKTREES_PARENT"

build_scratch_repo() {
  local scratch
  scratch="$(mktemp -d -t spawn-check-XXXXXX)"
  git -C "$scratch" init -q -b main
  # Disable globally-installed pre-commit hooks for scratch repos so the
  # test output is not polluted by the example.com placeholder guard.
  git -C "$scratch" config core.hooksPath /dev/null
  git -C "$scratch" config user.email "test@example.com"
  git -C "$scratch" config user.name  "test"
  echo "x" > "$scratch/.gitkeep"
  git -C "$scratch" add .gitkeep
  git -C "$scratch" commit -q -m "init"
  printf '%s\n' "$scratch"
}

# Helper: convert a base scratch repo into a worktree-shaped path
# (contains /.worktrees/) with correct origin + branch + non-empty AO
# hooks so the only invariant under test is what the caller mutates next.
make_worktree_fixture() {
  local branch="$1"
  local wt
  wt="$(mktemp -d -t jc-fixture-XXXXXX -p "$WORKTREES_PARENT")"
  cp -R "$SCRATCH_BASE/." "$wt/"
  git -C "$wt" config core.hooksPath /dev/null
  git -C "$wt" remote add origin https://github.com/jleechanorg/jleechanbrain.git
  git -C "$wt" checkout -q -B "$branch"
  mkdir -p "$wt/.claude"
  # Install REAL (non-empty) AO hooks so the fixture passes invariant 5
  # by default. Individual negative-path tests overwrite this file to
  # exercise the empty-arrays / missing-keys cases.
  cat > "$wt/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {"type": "command", "command": "/tmp/fake-ao-pretooluse-hook.sh"}
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {"type": "command", "command": "/tmp/fake-ao-posttooluse-hook.sh"}
        ]
      }
    ]
  }
}
JSON
  printf '%s\n' "$wt"
}

assert_script_fails() {
  local label="$1"
  local cwd="$2"
  if ( cd "$cwd" && "$SCRIPT" >/dev/null 2>&1 ); then
    echo "  FAIL: script returned 0 when $label (expected non-zero)"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS: script rejects $label"
    PASS=$((PASS + 1))
  fi
}

assert_script_passes() {
  local label="$1"
  local cwd="$2"
  if ( cd "$cwd" && "$SCRIPT" >/dev/null 2>&1 ); then
    echo "  PASS: script accepts $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: script rejected $label (expected 0)"
    ( cd "$cwd" && "$SCRIPT" ) || true
    FAIL=$((FAIL + 1))
  fi
}

# ------------------------------------------------------------------
# 1. Script must exist
# ------------------------------------------------------------------
if [[ ! -f "$SCRIPT" ]]; then
  echo "  FAIL: $SCRIPT does not exist (TDD: write the test before the script)"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: script exists at $SCRIPT"
  PASS=$((PASS + 1))
fi

# ------------------------------------------------------------------
# 2. Script must be executable
# ------------------------------------------------------------------
if [[ ! -f "$SCRIPT" ]]; then
  : # already reported above
elif [[ ! -x "$SCRIPT" ]]; then
  echo "  FAIL: $SCRIPT is not executable (chmod +x required)"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: script is executable"
  PASS=$((PASS + 1))
fi

# Bail early if the script itself is missing — all remaining checks
# depend on it. This keeps the summary line truthful.
if [[ ! -x "$SCRIPT" ]]; then
  echo ""
  echo "=== summary: $PASS pass, $FAIL fail ==="
  echo "✗ Script missing or not executable — cannot exercise invariants"
  exit 1
fi

# ------------------------------------------------------------------
# Invariant 1: cwd must contain /.worktrees/
# Use a fixture WITHOUT the .worktrees/ segment.
# ------------------------------------------------------------------
SCRATCH_BASE="$(build_scratch_repo)"
assert_script_fails "cwd was not a worktree" "$SCRATCH_BASE"
rm -rf "$SCRATCH_BASE"

# ------------------------------------------------------------------
# Invariant 2: origin must be the canonical jleechanorg/jleechanbrain URL
# (rejects forks, mirrors, and other-org remotes).
# ------------------------------------------------------------------
SCRATCH_BASE="$(build_scratch_repo)"
WT="$(make_worktree_fixture "feat/spawn-check-origin-test")"
git -C "$WT" remote set-url origin https://github.com/jleechanbrain-mirror/jleechanbrain.git
assert_script_fails "origin was a non-canonical mirror" "$WT"
rm -rf "$SCRATCH_BASE" "$WT"

SCRATCH_BASE="$(build_scratch_repo)"
WT="$(make_worktree_fixture "feat/spawn-check-origin-test")"
git -C "$WT" remote set-url origin https://github.com/${GITHUB_USER}/jleechanbrain.git
assert_script_fails "origin was a non-canonical per-user fork" "$WT"
rm -rf "$SCRATCH_BASE" "$WT"

# ------------------------------------------------------------------
# Invariant 3: branch must NOT be a protected default branch.
# ------------------------------------------------------------------
SCRATCH_BASE="$(build_scratch_repo)"
WT="$(make_worktree_fixture "main")"
assert_script_fails "branch was 'main'" "$WT"
rm -rf "$SCRATCH_BASE" "$WT"

SCRATCH_BASE="$(build_scratch_repo)"
WT="$(make_worktree_fixture "master")"
assert_script_fails "branch was 'master'" "$WT"
rm -rf "$SCRATCH_BASE" "$WT"

# Confirm normal AO branches (fix/*, feat/*, jc-*) are ACCEPTED.
SCRATCH_BASE="$(build_scratch_repo)"
WT="$(make_worktree_fixture "fix/some-real-task")"
assert_script_passes "branch was 'fix/some-real-task' (normal AO branch)" "$WT"
rm -rf "$SCRATCH_BASE" "$WT"

# ------------------------------------------------------------------
# Invariant 4: no uncommitted tracked-file modifications
# ------------------------------------------------------------------
SCRATCH_BASE="$(build_scratch_repo)"
WT="$(make_worktree_fixture "feat/spawn-check-dirty-test")"
echo "dirty" >> "$WT/.gitkeep"
assert_script_fails "tracked file had uncommitted modifications" "$WT"
rm -rf "$SCRATCH_BASE" "$WT"

# ------------------------------------------------------------------
# Invariant 5: .claude/settings.json must contain real AO hook entries
# (non-empty PreToolUse AND PostToolUse arrays with at least one command).
# ------------------------------------------------------------------
SCRATCH_BASE="$(build_scratch_repo)"
WT="$(make_worktree_fixture "feat/spawn-check-hooks-test")"
# Replace the well-formed hooks JSON with one missing the keys entirely.
printf '%s\n' '{"hooks":{}}' > "$WT/.claude/settings.json"
assert_script_fails ".claude/settings.json missing AO hooks (empty hooks map)" "$WT"
rm -rf "$SCRATCH_BASE" "$WT"

SCRATCH_BASE="$(build_scratch_repo)"
WT="$(make_worktree_fixture "feat/spawn-check-hooks-test")"
# Hook keys present but arrays empty — must STILL fail (this is the bug
# the strict JSON check exists to prevent).
printf '%s\n' '{"hooks":{"PreToolUse":[],"PostToolUse":[]}}' > "$WT/.claude/settings.json"
assert_script_fails ".claude/settings.json had empty hook arrays (key-only pass)" "$WT"
rm -rf "$SCRATCH_BASE" "$WT"

# ------------------------------------------------------------------
# Positive path: must PASS on the real worktree this test runs in
# ------------------------------------------------------------------
if "$SCRIPT" >/dev/null 2>&1; then
  echo "  PASS: script passes on real worktree $REPO_DIR"
  PASS=$((PASS + 1))
else
  echo "  FAIL: script failed on real worktree $REPO_DIR"
  "$SCRIPT" || true
  FAIL=$((FAIL + 1))
fi

echo ""
echo "=== summary: $PASS pass, $FAIL fail ==="
# Clean up the parent .worktrees/ directory we created in /tmp
rm -rf "$(dirname "$WORKTREES_PARENT")" 2>/dev/null || true
if [[ "$FAIL" -eq 0 ]]; then
  echo "✓ All checks passed"
  exit 0
fi
echo "✗ One or more checks failed"
exit 1