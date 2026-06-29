#!/usr/bin/env bash
# test_launchd_wrapper_token_consistency.sh
#
# Verifies the launchd-env-wrapper.sh dotfile-drift check added 2026-06-18
# to prevent the 2026-06-18 `invalid_auth` outage from recurring:
#
#   The wrapper sources .bash_profile → .profile → .bashrc-grep in that
#   order. Both .bashrc and .profile may define OPENCLAW_SLACK_APP_TOKEN
#   (or SLACK_APP_TOKEN). When they disagree, .bashrc wins for the
#   daemon — even if .profile is the correct one. The prior outage
#   caused a stale xapp- token in .bashrc to silently override a fresh
#   xapp- in .profile; restart alone did not fix it because .bashrc
#   kept reasserting the stale value.
#
# This test asserts:
#   1. scripts/launchd-env-wrapper.sh defines a consistency check
#      function (no behavioral regression if a future refactor renames
#      it — the function call sites still need to be present).
#   2. With .bashrc and .profile tokens MATCHING, the check exports
#      LAUNCHD_WRAPPER_DOTFILE_CONSISTENCY_OK=1 and emits no warning.
#   3. With .bashrc and .profile tokens DIVERGING, the check exports
#      LAUNCHD_WRAPPER_DOTFILE_CONSISTENCY_OK=0 AND prints a warning
#      to stderr that names the variable and shows a `diff` hint.
#   4. The check is run for both OPENCLAW_SLACK_APP_TOKEN and
#      OPENCLAW_SLACK_BOT_TOKEN (the two tokens that caused the
#      2026-06-18 outage and the prior 2026-05-14 staging token fix).
#
# Usage:
#   bash tests/test_launchd_wrapper_token_consistency.sh
#
# Returns:
#   0 if all checks pass
#   1 if any check fails
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

WRAPPER="$REPO_DIR/scripts/launchd-env-wrapper.sh"

PASS=1

echo "=== test_launchd_wrapper_token_consistency ==="
echo ""

# Helper: run the wrapper up to (but not including) the trailing
# `exec "$@"` in a subshell with a fake HOME containing .bashrc
# and .profile, then echo the resulting LAUNCHD_WRAPPER_DOTFILE_CONSISTENCY_OK
# value and captured stderr.
run_wrapper_with_dotfiles() {
  local bashrc_value="$1"
  local profile_value="$2"
  local token_label="$3"  # OPENCLAW_SLACK_APP_TOKEN or OPENCLAW_SLACK_BOT_TOKEN

  local fake_home
  fake_home="$(mktemp -d)"
  # Write .bashrc and .profile with the test values for the given label.
  # Quote with double-quotes (matches the wrapper's regex/sed parser).
  printf 'export %s="%s"\n' "$token_label" "$bashrc_value" > "$fake_home/.bashrc"
  printf 'export %s="%s"\n' "$token_label" "$profile_value" > "$fake_home/.profile"
  # Some wrapper logic may source .bash_profile — keep it empty (no-op).
  touch "$fake_home/.bash_profile"

  local stderr_file
  stderr_file="$(mktemp)"
  # Run the wrapper up to the last `exec "$@"` line. Strip the trailing
  # line so the subshell can source it without `exec` replacing itself.
  local result
  result=$(env -i HOME="$fake_home" PATH="/usr/bin:/bin" /bin/bash -c "
    sed '\$d' '$WRAPPER' > /tmp/.wr-no-exec-\$\$.sh
    source /tmp/.wr-no-exec-\$\$.sh
    rm -f /tmp/.wr-no-exec-\$\$.sh
    printf '%s' \"\${LAUNCHD_WRAPPER_DOTFILE_CONSISTENCY_OK:-unset}\"
  " 2>"$stderr_file")

  echo "RESULT=$result"
  echo "STDERR:"
  cat "$stderr_file"
  rm -f "$stderr_file"
  rm -rf "$fake_home"
}

# ── 1. Wrapper file exists and contains the check ──────────────────────────
if [[ ! -f "$WRAPPER" ]]; then
  echo "FAIL: $WRAPPER does not exist"
  exit 1
fi

echo "Checking wrapper structure: $WRAPPER"

if grep -qF '_assert_dotfile_token_consistency' "$WRAPPER"; then
  echo "  PASS: wrapper defines _assert_dotfile_token_consistency function"
else
  echo "  FAIL: wrapper missing _assert_dotfile_token_consistency function"
  PASS=0
fi

if grep -qF '_assert_dotfile_token_consistency OPENCLAW_SLACK_APP_TOKEN' "$WRAPPER"; then
  echo "  PASS: wrapper runs check for OPENCLAW_SLACK_APP_TOKEN"
else
  echo "  FAIL: wrapper missing call site for OPENCLAW_SLACK_APP_TOKEN"
  PASS=0
fi

if grep -qF '_assert_dotfile_token_consistency OPENCLAW_SLACK_BOT_TOKEN' "$WRAPPER"; then
  echo "  PASS: wrapper runs check for OPENCLAW_SLACK_BOT_TOKEN"
else
  echo "  FAIL: wrapper missing call site for OPENCLAW_SLACK_BOT_TOKEN"
  PASS=0
fi

if grep -qF 'LAUNCHD_WRAPPER_DOTFILE_CONSISTENCY_OK' "$WRAPPER"; then
  echo "  PASS: wrapper exports LAUNCHD_WRAPPER_DOTFILE_CONSISTENCY_OK"
else
  echo "  FAIL: wrapper missing LAUNCHD_WRAPPER_DOTFILE_CONSISTENCY_OK export"
  PASS=0
fi

# The function body should reference ~/.bashrc AND ~/.profile (both
# read in the comparison).
if grep -qF '.bashrc' "$WRAPPER" && grep -qF '.profile' "$WRAPPER"; then
  echo "  PASS: wrapper references both .bashrc and .profile"
else
  echo "  FAIL: wrapper missing reference to one of .bashrc / .profile"
  PASS=0
fi

# The function should include a `diff` hint so operators know how to
# reconcile drift (the same hint referenced in the warning text).
if grep -qF 'diff' "$WRAPPER"; then
  echo "  PASS: wrapper includes a diff-based remediation hint"
else
  echo "  FAIL: wrapper missing diff remediation hint"
  PASS=0
fi
echo ""

# ── 2. GREEN: matching tokens → OK=1, no warning ───────────────────────────
echo "Behavioral test 1: matching .bashrc and .profile tokens"
GREEN_OUT="$(run_wrapper_with_dotfiles \
  'xapp-1-FAKE-WORKSPACE-AAAAAAAA-correctvalue' \
  'xapp-1-FAKE-WORKSPACE-AAAAAAAA-correctvalue' \
  'OPENCLAW_SLACK_APP_TOKEN')"

if [[ "$GREEN_OUT" == *$'RESULT=1'* ]]; then
  echo "  PASS: matching tokens → LAUNCHD_WRAPPER_DOTFILE_CONSISTENCY_OK=1"
else
  echo "  FAIL: matching tokens did not set OK=1"
  echo "$GREEN_OUT"
  PASS=0
fi

if [[ "$GREEN_OUT" == *"WARNING"* && "$GREEN_OUT" == *"drift"* ]]; then
  echo "  FAIL: matching tokens should NOT emit a drift warning"
  echo "$GREEN_OUT"
  PASS=0
else
  echo "  PASS: matching tokens → no drift warning emitted"
fi
echo ""

# ── 3. RED: divergent tokens → OK=0, warning on stderr ─────────────────────
echo "Behavioral test 2: divergent .bashrc and .profile tokens"
RED_OUT="$(run_wrapper_with_dotfiles \
  'xapp-1-FAKE-WORKSPACE-BBBBBBBB-stalevalue' \
  'xapp-1-FAKE-WORKSPACE-CCCCCCCC-freshvalue' \
  'OPENCLAW_SLACK_APP_TOKEN')"

if [[ "$RED_OUT" == *$'RESULT=0'* ]]; then
  echo "  PASS: divergent tokens → LAUNCHD_WRAPPER_DOTFILE_CONSISTENCY_OK=0"
else
  echo "  FAIL: divergent tokens did not set OK=0"
  echo "$RED_OUT"
  PASS=0
fi

if [[ "$RED_OUT" == *"WARNING"* && "$RED_OUT" == *"OPENCLAW_SLACK_APP_TOKEN"* ]]; then
  echo "  PASS: divergent tokens emit WARNING naming OPENCLAW_SLACK_APP_TOKEN"
else
  echo "  FAIL: divergent tokens should emit WARNING naming the drifted variable"
  echo "$RED_OUT"
  PASS=0
fi

if [[ "$RED_OUT" == *"diff"* ]]; then
  echo "  PASS: warning includes a diff-based remediation hint"
else
  echo "  FAIL: warning should include a diff-based remediation hint"
  echo "$RED_OUT"
  PASS=0
fi
echo ""

# ── 4. Behavioral: bot-token drift is also detected ────────────────────────
echo "Behavioral test 3: divergent OPENCLAW_SLACK_BOT_TOKEN"
BOT_OUT="$(run_wrapper_with_dotfiles \
  'xoxb-stale-bot-token' \
  'xoxb-fresh-bot-token' \
  'OPENCLAW_SLACK_BOT_TOKEN')"

if [[ "$BOT_OUT" == *$'RESULT=0'* ]]; then
  echo "  PASS: bot-token drift → LAUNCHD_WRAPPER_DOTFILE_CONSISTENCY_OK=0"
else
  echo "  FAIL: bot-token drift did not set OK=0"
  echo "$BOT_OUT"
  PASS=0
fi

if [[ "$BOT_OUT" == *"WARNING"* && "$BOT_OUT" == *"OPENCLAW_SLACK_BOT_TOKEN"* ]]; then
  echo "  PASS: bot-token drift emits WARNING naming OPENCLAW_SLACK_BOT_TOKEN"
else
  echo "  FAIL: bot-token drift should emit WARNING naming the drifted variable"
  echo "$BOT_OUT"
  PASS=0
fi
echo ""

# ── 5. Behavioral: only one dotfile set (the other missing) → OK=1 (no warn)
# When .bashrc has the token but .profile doesn't (or vice versa), we
# can't compare; treat as consistent. This is the common case during
# initial setup.
echo "Behavioral test 4: only one of .bashrc/.profile defines the token"
PARTIAL_OUT="$(run_wrapper_with_dotfiles \
  'xapp-1-FAKE-ONLY-IN-BASHRC' \
  '' \
  'OPENCLAW_SLACK_APP_TOKEN')"

if [[ "$PARTIAL_OUT" == *$'RESULT=1'* ]]; then
  echo "  PASS: only-one-side-defined → LAUNCHD_WRAPPER_DOTFILE_CONSISTENCY_OK=1"
else
  echo "  FAIL: only-one-side-defined should not flag drift"
  echo "$PARTIAL_OUT"
  PASS=0
fi

if [[ "$PARTIAL_OUT" == *"WARNING"* ]]; then
  echo "  FAIL: only-one-side-defined should NOT emit a warning"
  echo "$PARTIAL_OUT"
  PASS=0
else
  echo "  PASS: only-one-side-defined → no warning"
fi
echo ""

echo ""
if [[ "$PASS" -eq 1 ]]; then
  echo "✓ All checks passed"
  exit 0
else
  echo "✗ One or more checks failed"
  exit 1
fi
