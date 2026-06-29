#!/usr/bin/env bash
# test_launchd_ops_channel.sh
#
# Verifies the launchd ops channel plumbing required by PR jleechan-ops-chan:
#   1. scripts/launchd-env-wrapper.sh exports HERMES_OPS_SLACK_CHANNEL with
#      EMPTY default (umbrella pattern, PR #681, #687). Plist is source of truth.
#   2. The wrapper reads the var from the plist environment when set
#      (i.e., the export is `export HERMES_OPS_SLACK_CHANNEL=...`, not a
#      hardcoded assignment that would clobber a plist value).
#   3. The watchdog plist template sets HERMES_OPS_SLACK_CHANNEL to a real
#      ops channel (${SLACK_CHANNEL_ID} = #all-jleechan-ai) — NOT the design channel
#      (C0AJ3SD5C79) which was the prior buggy default per PR #687.
#   4. The wrapper has a _extract_bashrc_var HERMES_OPS_SLACK_CHANNEL call
#      so that operators who set it in .bashrc get it picked up.
#
# Usage:
#   bash tests/test_launchd_ops_channel.sh
#
# Returns:
#   0 if all checks pass
#   1 if any check fails
#
# Skipped (not failed) if the harness checkout is absent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

WRAPPER="$REPO_DIR/scripts/launchd-env-wrapper.sh"
WATCHDOG_TEMPLATE="$REPO_DIR/launchd/ai.smartclaw.watchdog.plist.template"

PASS=1

check() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "  PASS: $label"
  else
    echo "  FAIL: $label"
    PASS=0
  fi
}

echo "=== test_launchd_ops_channel ==="
echo ""

# ── 1. Wrapper file exists and is executable ────────────────────────────────
if [[ -f "$WRAPPER" ]]; then
  echo "Checking wrapper: $WRAPPER"
  check "wrapper file exists"                      test -f "$WRAPPER"
  check "wrapper is executable"                    test -x "$WRAPPER"
  check "wrapper contains _extract_bashrc_var HERMES_OPS_SLACK_CHANNEL" \
    grep -qF '_extract_bashrc_var HERMES_OPS_SLACK_CHANNEL' "$WRAPPER"
  check "wrapper exports HERMES_OPS_SLACK_CHANNEL" \
    grep -Eq '^export HERMES_OPS_SLACK_CHANNEL=' "$WRAPPER"
  # Empty default per umbrella pattern: export line should be `:-"`.
  if grep -Eq '^export HERMES_OPS_SLACK_CHANNEL="\$\{HERMES_OPS_SLACK_CHANNEL:-"\}"' "$WRAPPER" \
      || grep -Eq '^export HERMES_OPS_SLACK_CHANNEL="\$\{HERMES_OPS_SLACK_CHANNEL:-\}"' "$WRAPPER"; then
    echo "  PASS: wrapper default is EMPTY (umbrella pattern, PR #681, #687)"
  else
    echo "  FAIL: wrapper default is NOT empty — must be \${HERMES_OPS_SLACK_CHANNEL:-} per umbrella pattern"
    PASS=0
  fi
  # Must NOT hardcode C0AJ3SD5C79 (design channel) — that was the buggy default
  # the umbrella pattern was created to eliminate.
  if grep -qF 'C0AJ3SD5C79' "$WRAPPER"; then
    echo "  FAIL: wrapper hardcodes C0AJ3SD5C79 (design channel) — must be empty default"
    PASS=0
  else
    echo "  PASS: wrapper does NOT hardcode C0AJ3SD5C79 (design channel)"
  fi
  echo ""

  # ── 2. Behavioral: sourcing the wrapper with no env sets var to empty ────
  # This catches regressions where a future change adds a non-empty default.
  # NOTE: the wrapper ends with `exec "$@"` which would replace the parent shell
  # when sourced with no args, so we must run the source in a subshell and
  # inspect the resulting env via a sentinel pattern.
  RESULT=$(env -u HERMES_OPS_SLACK_CHANNEL /bin/bash -c "
    # Stop just before `exec \"\$@\"` by tailing the wrapper to that point
    WRAPPER='$WRAPPER'
    # Source everything except the trailing exec line
    sed '\$d' \"\$WRAPPER\" > /tmp/.wr-no-exec-\$\$.sh
    source /tmp/.wr-no-exec-\$\$.sh
    rm -f /tmp/.wr-no-exec-\$\$.sh
    printf '%s' \"\${HERMES_OPS_SLACK_CHANNEL+set}:\${HERMES_OPS_SLACK_CHANNEL:-}\"
  " 2>/dev/null)
  case "$RESULT" in
    "set:"|":")
      echo "  PASS: wrapper default is empty (sourced with no env → var empty)"
      ;;
    "set:"*)
      echo "  FAIL: wrapper sets non-empty default: '${RESULT#set:}'"
      PASS=0
      ;;
    *)
      echo "  FAIL: wrapper does not export HERMES_OPS_SLACK_CHANNEL (got: '$RESULT')"
      PASS=0
      ;;
  esac

  # ── 3. Behavioral: plist-set value flows through the export ──────────────
  RESULT=$(/bin/bash -c "
    export HERMES_OPS_SLACK_CHANNEL='${SLACK_CHANNEL_ID}'
    WRAPPER='$WRAPPER'
    sed '\$d' \"\$WRAPPER\" > /tmp/.wr-no-exec-\$\$.sh
    source /tmp/.wr-no-exec-\$\$.sh
    rm -f /tmp/.wr-no-exec-\$\$.sh
    printf '%s' \"\${HERMES_OPS_SLACK_CHANNEL:-}\"
  " 2>/dev/null)
  if [[ "$RESULT" == "${SLACK_CHANNEL_ID}" ]]; then
    echo "  PASS: plist-set HERMES_OPS_SLACK_CHANNEL flows through wrapper"
  else
    echo "  FAIL: plist-set value not preserved (got '$RESULT', expected ${SLACK_CHANNEL_ID})"
    PASS=0
  fi
  echo ""
else
  echo "SKIP: $WRAPPER does not exist"
  echo ""
fi

# ── 4. Watchdog plist template sets the right channel ───────────────────────
if [[ -f "$WATCHDOG_TEMPLATE" ]]; then
  echo "Checking template: $WATCHDOG_TEMPLATE"
  check "template has HERMES_OPS_SLACK_CHANNEL key" \
    grep -qF '<key>HERMES_OPS_SLACK_CHANNEL</key>' "$WATCHDOG_TEMPLATE"
  # Note: the grep -A1 | grep -qF pipe must be wrapped in a subshell or the
  # pipe operator leaks out and breaks the surrounding test.
  if bash -c "grep -A1 '<key>HERMES_OPS_SLACK_CHANNEL</key>' '$WATCHDOG_TEMPLATE' | grep -qF '<string>${SLACK_CHANNEL_ID}</string>'" >/dev/null 2>&1; then
    echo "  PASS: template value is ${SLACK_CHANNEL_ID} (real ops channel)"
  else
    echo "  FAIL: template value is NOT ${SLACK_CHANNEL_ID} — must be the real ops channel"
    PASS=0
  fi
  # Must NOT use C0AJ3SD5C79 (design channel — the buggy default).
  if bash -c "grep -A1 '<key>HERMES_OPS_SLACK_CHANNEL</key>' '$WATCHDOG_TEMPLATE' | grep -qF 'C0AJ3SD5C79'" >/dev/null 2>&1; then
    echo "  FAIL: template value is C0AJ3SD5C79 (design channel) — must be a real ops channel"
    PASS=0
  else
    echo "  PASS: template does NOT use C0AJ3SD5C79 (design channel)"
  fi
  echo ""
else
  echo "SKIP: $WATCHDOG_TEMPLATE does not exist"
  echo ""
fi

# ── 5. Installed plists on this machine (informational) ─────────────────────
INSTALLED_WATCHDOG="$HOME/Library/LaunchAgents/ai.smartclaw-watchdog.plist"
INSTALLED_GUARDIAN="$HOME/Library/LaunchAgents/ai.agento.health-guardian.plist"
echo "Installed plists (informational — not in the git repo):"
for plist in "$INSTALLED_WATCHDOG" "$INSTALLED_GUARDIAN"; do
  if [[ -f "$plist" ]]; then
    val="$(/usr/libexec/PlistBuddy -c "Print :EnvironmentVariables:HERMES_OPS_SLACK_CHANNEL" "$plist" 2>/dev/null || echo "<missing>")"
    if [[ "$val" == "<missing>" ]]; then
      echo "  WARN: $plist — HERMES_OPS_SLACK_CHANNEL not set (re-render after PR merge)"
    else
      echo "  OK:   $plist — HERMES_OPS_SLACK_CHANNEL=$val"
    fi
  fi
done
echo ""

echo ""
if [[ "$PASS" -eq 1 ]]; then
  echo "✓ All checks passed"
  exit 0
else
  echo "✗ One or more checks failed"
  exit 1
fi

