#!/usr/bin/env bash
# Regression: ao-progress-reporter.sh must find the `ao` CLI even when launched
# from a launchd job that only inherits /opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin
# on PATH (the default after a fresh launchd bootstrap, no .bashrc sourcing).
#
# Root cause (2026-06-27): the script's `fetch_ao_sessions()` short-circuited to
# `"[]"` when `command -v ao` returned empty, and the report then posted the
# misleading "AO Progress Report — no active sessions detected" message every
# 30 min for the entire day, even when 22+ AO workers were alive in tmux.
#
# This test sources the script helpers (IS_SOURCED=1) under three PATH scenarios
# and asserts the right behavior in each.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/ao-progress-reporter.sh"

PASSED=0
FAILED=0
pass() { echo "PASS: $1"; PASSED=$((PASSED + 1)); }
fail() { echo "FAIL: $1"; FAILED=$((FAILED + 1)); }

[[ -f "$SCRIPT" ]] || { echo "FAIL: missing $SCRIPT"; exit 1; }

REAL_HOME="$HOME"
NVM_BIN="$REAL_HOME/.nvm/versions/node/v22.22.0/bin"
[[ -d "$NVM_BIN" ]] || { echo "SKIP: nvm dir missing at $NVM_BIN (this test requires real nvm setup)"; exit 0; }
[[ -x "$NVM_BIN/ao" ]] || { echo "SKIP: ao binary missing at $NVM_BIN/ao"; exit 0; }
AO_DIR="${HOME}/project_agento/agent-orchestrator"
[[ -d "$AO_DIR" ]] || { echo "SKIP: $AO_DIR missing"; exit 0; }

# probe_fetch <path_value> <ao_bin_value> <home_value>
# Writes the fetched JSON to $RESULT_FILE and stderr to $STDERR_FILE.
# We `exec 2>...` inside the bash -c so the redirect covers BOTH the source
# step AND the subsequent fetch_ao_sessions call. A trailing `2>...` only
# applies to the `source` command itself because shell redirection is a
# per-command scope, not a subshell scope.
STDERR_FILE="$(mktemp)"
RESULT_FILE="$(mktemp)"
trap 'rm -f "$STDERR_FILE" "$RESULT_FILE"' EXIT

probe_fetch() {
  local path_value="$1" ao_bin_value="$2" home_value="$3"
  HOME="$home_value" PATH="$path_value" \
    AO_DIR="$AO_DIR" AO_BIN="$ao_bin_value" GH_TOKEN=fake-for-test IS_SOURCED=1 \
    bash -c "exec 2>'$STDERR_FILE'; source '$SCRIPT' >/dev/null; fetch_ao_sessions >'$RESULT_FILE'"
}

# ── Scenario 1: launchd-default PATH (no nvm), real HOME ─────────────────────
# The script's PATH-bootstrap block should prepend nvm to PATH and `ao` should
# resolve. Result must be a non-empty JSON array with >0 sessions.
probe_fetch "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" "ao" "$REAL_HOME"
scenario1_result="$(cat "$RESULT_FILE")"
if [[ "$scenario1_result" == "["* ]]; then
  count1="$(printf '%s' "$scenario1_result" | jq 'length' 2>/dev/null || echo 0)"
  if [[ "$count1" -gt 0 ]]; then
    pass "Scenario 1 (launchd PATH, real HOME): bootstrap resolves nvm bin, fetched $count1 sessions"
  else
    fail "Scenario 1 (launchd PATH, real HOME): JSON array but 0 sessions — bootstrap may have broken"
  fi
else
  fail "Scenario 1 (launchd PATH, real HOME): result did not start with '[' — got: ${scenario1_result:0:80}"
fi

# ── Scenario 2: PATH missing nvm AND fake HOME with no nvm dir ──────────────
# Simulates a system where nvm is genuinely uninstalled. Must fail LOUD with
# a diagnostic hint, not silently return [].
FAKE_HOME="$(mktemp -d)"
probe_fetch "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" "ao" "$FAKE_HOME"
scenario2_result="$(cat "$RESULT_FILE")"
scenario2_stderr="$(cat "$STDERR_FILE")"

if [[ "$scenario2_result" == "[]" ]]; then
  pass "Scenario 2 (no nvm): fetch_ao_sessions returns '[]' gracefully"
else
  fail "Scenario 2 (no nvm): expected '[]' but got: ${scenario2_result:0:80}"
fi

if echo "$scenario2_stderr" | grep -q "ERROR: 'ao' not found on PATH"; then
  pass "Scenario 2 (no nvm): error message includes 'ao not found on PATH'"
else
  fail "Scenario 2 (no nvm): no 'ao not found on PATH' error in stderr"
fi

if echo "$scenario2_stderr" | grep -q "install node v22"; then
  pass "Scenario 2 (no nvm): hint points at installing node v22"
else
  fail "Scenario 2 (no nvm): missing 'install node v22' hint"
fi

rm -rf "$FAKE_HOME"

# ── Scenario 3: PATH already includes nvm bin ────────────────────────────────
# Happy path: nothing to fix, just verify no regression.
probe_fetch "$NVM_BIN:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" "ao" "$REAL_HOME"
scenario3_result="$(cat "$RESULT_FILE")"
if [[ "$scenario3_result" == "["* ]]; then
  count3="$(printf '%s' "$scenario3_result" | jq 'length' 2>/dev/null || echo 0)"
  if [[ "$count3" -gt 0 ]]; then
    pass "Scenario 3 (nvm on PATH): fetched $count3 sessions — no regression"
  else
    fail "Scenario 3 (nvm on PATH): got 0 sessions"
  fi
else
  fail "Scenario 3 (nvm on PATH): result did not start with '[' — got: ${scenario3_result:0:80}"
fi

# ── Scenario 4: bootstrap does NOT duplicate nvm in PATH ─────────────────────
# If PATH already has nvm, the script's bootstrap should NOT prepend it twice.
path_with_nvm="$NVM_BIN:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
path_after="$(HOME="$REAL_HOME" PATH="$path_with_nvm" \
              AO_DIR="$AO_DIR" AO_BIN="ao" GH_TOKEN=fake-for-test IS_SOURCED=1 \
              bash -c "exec 2>/dev/null; source '$SCRIPT' >/dev/null; printf '%s' \"\$PATH\"")"
nvm_count="$(printf '%s' "$path_after" | tr ':' '\n' | grep -cFx "$NVM_BIN" || true)"
if [[ "$nvm_count" == "1" ]]; then
  pass "Scenario 4 (no PATH duplication): nvm appears exactly once in PATH"
else
  fail "Scenario 4 (no PATH duplication): nvm appears $nvm_count times in PATH (want 1)"
fi

echo ""
if [[ "$FAILED" -gt 0 ]]; then
  echo "FAILED: $FAILED test(s), PASSED: $PASSED"
  exit 1
fi
echo "PASSED: $PASSED test(s)"