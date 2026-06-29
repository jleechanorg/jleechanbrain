#!/usr/bin/env bash
# Test script for the browserclaw cookies subcommand skill.
#
# Verifies that the skill file is complete and that the installed
# browserclaw CLI really exposes the `cookies decrypt` / `cookies inject`
# subcommands described in the skill.
#
# Exit 0 on success, non-zero on any failed assertion.

set -uo pipefail

# Resolve repo root (parent of tests/) regardless of where the script is invoked from.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_PATH="$REPO_ROOT/skills/browserclaw/SKILL.md"

fail_count=0
pass_count=0

assert() {
  local description="$1"
  local condition="$2"
  if eval "$condition"; then
    printf "  PASS  %s\n" "$description"
    pass_count=$((pass_count + 1))
  else
    printf "  FAIL  %s\n" "$description"
    printf "        condition: %s\n" "$condition"
    fail_count=$((fail_count + 1))
  fi
}

echo "==> browserclaw skill test"
echo "    REPO_ROOT:  $REPO_ROOT"
echo "    SKILL_PATH: $SKILL_PATH"
echo

# 1. Skill file exists and is non-empty.
echo "[1] Skill file presence"
assert "SKILL.md exists at canonical Hermes skill path" "[ -f '$SKILL_PATH' ]"
assert "SKILL.md is non-empty (>500 bytes)" "[ -s '$SKILL_PATH' ] && [ \$(wc -c < '$SKILL_PATH') -gt 500 ]"

# 2. Subcommands are documented in the skill.
echo
echo "[2] Skill content"
assert "SKILL.md mentions 'cookies decrypt'" "grep -q 'cookies decrypt' '$SKILL_PATH'"
assert "SKILL.md mentions 'cookies inject'" "grep -q 'cookies inject' '$SKILL_PATH'"
assert "SKILL.md mentions 'browserclaw'" "grep -q 'browserclaw' '$SKILL_PATH'"
assert "SKILL.md has a real --db example for decrypt" "grep -q -- '--db' '$SKILL_PATH'"
assert "SKILL.md has a real --cookies example for inject" "grep -q -- '--cookies' '$SKILL_PATH'"
assert "SKILL.md has a real --goto example for inject" "grep -q -- '--goto' '$SKILL_PATH'"
assert "SKILL.md documents --domain-filter" "grep -q -- '--domain-filter' '$SKILL_PATH'"
assert "SKILL.md documents --summary flag" "grep -q -- '--summary' '$SKILL_PATH'"
assert "SKILL.md documents --headless flag" "grep -q -- '--headless' '$SKILL_PATH'"
assert "SKILL.md documents --screenshot flag" "grep -q -- '--screenshot' '$SKILL_PATH'"

# 3. Security section is present (item 6 of the skillify checklist).
echo
echo "[3] Security warning"
assert "SKILL.md has a Security section header" "grep -qiE '^##.*[Ss]ecurity' '$SKILL_PATH'"
assert "SKILL.md warns against logging raw cookie values" \
  "grep -qE 'raw cookie values|cookie values|never log' '$SKILL_PATH'"
assert "SKILL.md warns against committing cookies.json" \
  "grep -qiE 'commit.*cookies\\.json|cookies\\.json.*\\.gitignore' '$SKILL_PATH'"
assert "SKILL.md mentions macOS Keychain trust model" \
  "grep -q 'macOS Keychain' '$SKILL_PATH'"

# 4. Cross-references and metadata (items 9 + 10 of the skillify checklist).
echo
echo "[4] Cross-references + metadata"
assert "SKILL.md links PR #6 (the introducing PR)" "grep -q 'pull/6' '$SKILL_PATH'"
assert "SKILL.md links the browserclaw repo" "grep -q 'jleechanorg/browserclaw' '$SKILL_PATH'"
assert "SKILL.md has a Last-updated metadata line" "grep -qE 'Last updated|last-updated' '$SKILL_PATH'"
assert "SKILL.md has a Version metadata line" "grep -qiE 'browserclaw[[:space:]]+version|^[[:space:]]*[Vv]ersion[[:space:]]*[:#]' '$SKILL_PATH'"
assert "SKILL.md lists tests/test_cookies_decrypt.py" "grep -q 'test_cookies_decrypt.py' '$SKILL_PATH'"

# 5. Real CLI surface (item 5: not just docs — the binary must expose the subcommands).
echo
echo "[5] Real CLI surface"
# Honor a pre-set BROWSERCLAW_BIN env var so operators can point this test
# at a non-default install path (e.g. a worktree venv) without editing the script.
if [ -z "${BROWSERCLAW_BIN:-}" ]; then
  BROWSERCLAW_BIN=""
  for candidate in browserclaw ${HOME}/.local/orch-venv/bin/browserclaw; do
    if command -v "$candidate" >/dev/null 2>&1; then
      BROWSERCLAW_BIN="$candidate"
      break
    fi
    if [ -x "$candidate" ]; then
      BROWSERCLAW_BIN="$candidate"
      break
    fi
  done
fi

if [ -n "$BROWSERCLAW_BIN" ]; then
  echo "    found browserclaw binary: $BROWSERCLAW_BIN"
  assert "$BROWSERCLAW_BIN --help mentions 'cookies'" \
    "$BROWSERCLAW_BIN --help 2>&1 | grep -q 'cookies'"

  decrypt_help="$($BROWSERCLAW_BIN cookies decrypt --help 2>&1)"
  decrypt_rc=$?
  assert "$BROWSERCLAW_BIN cookies decrypt --help exits 0" "[ $decrypt_rc -eq 0 ]"
  assert "decrypt --help lists --db flag" \
    "echo \"\$decrypt_help\" | grep -q -- '--db'"
  assert "decrypt --help lists --output flag" \
    "echo \"\$decrypt_help\" | grep -q -- '--output'"
  assert "decrypt --help lists --domain-filter flag" \
    "echo \"\$decrypt_help\" | grep -q -- '--domain-filter'"

  inject_help="$($BROWSERCLAW_BIN cookies inject --help 2>&1)"
  inject_rc=$?
  assert "$BROWSERCLAW_BIN cookies inject --help exits 0" "[ $inject_rc -eq 0 ]"
  assert "inject --help lists --cookies flag" \
    "echo \"\$inject_help\" | grep -q -- '--cookies'"
  assert "inject --help lists --goto flag" \
    "echo \"\$inject_help\" | grep -q -- '--goto'"

  # 6. Error case (item 7 of the skillify checklist):
  # `cookies decrypt --db /nonexistent` must fail loudly with non-zero exit code.
  echo
  echo "[6] Error case — non-existent --db"
  # Use mktemp so parallel CI runs don't collide on the same /tmp paths.
  err_out="$(mktemp -t bc_err.XXXXXX.out)"
  err_json="$(mktemp -t bc_err.XXXXXX.json)"
  set +e
  $BROWSERCLAW_BIN cookies decrypt --db /nonexistent/path/Cookies --output "$err_json" >"$err_out" 2>&1
  err_rc=$?
  set -e
  assert "cookies decrypt with bad --db exits non-zero" "[ $err_rc -ne 0 ]"
  assert "cookies decrypt with bad --db prints a CookieDecryptError-style message" \
    "grep -qE 'CookieDecryptError|not found|is empty|not a Chromium' '$err_out'"
  rm -f "$err_out" "$err_json"
else
  # No browserclaw binary — the doc/binary-drift guarantee this PR advertises
  # is unverifiable, so the test must fail rather than silently pass.
  printf "  FAIL  browserclaw binary not found on PATH\n"
  printf "        This test verifies that the docs and the installed CLI agree.\n"
  printf "        Install with: pip install -e '.[dev]' in ~/browserclaw\n"
  printf "        (or set BROWSERCLAW_BIN env var to the binary path)\n"
  printf "        Searched: PATH + ${HOME}/.local/orch-venv/bin/browserclaw\n"
  fail_count=$((fail_count + 1))
fi

echo
echo "==> Results: $pass_count passed, $fail_count failed"

if [ "$fail_count" -gt 0 ]; then
  exit 1
fi
exit 0