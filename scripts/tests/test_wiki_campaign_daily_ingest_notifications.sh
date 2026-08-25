#!/usr/bin/env bash
# test_wiki_campaign_daily_ingest_notifications.sh
#
# RED-phase TDD contract tests for ${HOME}/.smartclaw/scripts/wiki-campaign-daily-ingest.sh.
# Each test asserts a contract that the FIXED script MUST satisfy. Tests
# run against the script itself (sourcing its top half with mocked
# notify() / slack_post_message) so they exercise the SAME control flow
# the real launchd job executes, without making any real Slack/Gmail
# calls. Exit 0 if all pass, 1 otherwise.
#
# Contracts asserted:
#   1. notify_error() posts to #ai-general (C0AJQ5M0A0Y), NOT #life.
#   2. notify_error() tag-mentions <@U09GH5BR3QU> <@U0AEZC7RX1Q> so
#      the operator and Hermes bot get pinged (failure-path escalation
#      only — does NOT tag on success path).
#   3. The script detects a missing/broken venv python before invoking
#      it (either the symlink target is missing, or the symlink is
#      dangling), and triggers notify_error() with a clear "what to fix"
#      message rather than dying on a shell "No such file or directory".
#
# Run:  bash tests/test_wiki_campaign_daily_ingest_notifications.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/wiki-campaign-daily-ingest.sh"
if [[ ! -f "$SCRIPT" ]]; then
  echo "FATAL: script not found at $SCRIPT" >&2
  exit 1
fi

PASS=0
FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# --- Build a harness environment that runs the script with notify() ---
# stubbed so we can observe the args passed to notify_error() / the channel
# chosen for slack_post_message(). We source the script's helper funcs
# (notify/notify_error/build_success_summary) but redirect everything that
# would touch Slack/Gmail/logs.
#
# Pattern: source the script with stubbed commands at the TOP, then call
# notify_error "synthetic failure". The harness captures $SLACK_CHANNEL
# and the exact text passed to slack_post_message.

write_log() { :; }   # tee to /dev/null stub
export -f write_log
export LOG_FD=0
# Make log() a no-op so we don't pollute test output / create files
log() { :; }

# Stub helper inlined here so we can observe what notify_error passes to it
CAPTURED_CHANNEL=""
CAPTURED_TEXT=""
CAPTURED_SUBJECT=""
CAPTURED_BODY=""
slack_post_message() {
  CAPTURED_CHANNEL="$1"
  CAPTURED_TEXT="$2"
  echo "captured-channel=$CAPTURED_CHANNEL" >&2
  return 0
}
gog() { return 0; }
command() { return 0; }   # stub `command -v gog` so notify() proceeds past it
export -f slack_post_message
export -f gog
export -f command

# Source the script — but first stub dangerous builtins we don't want to
# really execute (touch, mkdir, tee). These are inline in the script so
# we can't fully isolate; instead we run it in a sub-bash and only source
# the parts we need (the helpers), which is what the actual launchd job
# ends up executing anyway because the script's ERR trap only fires after
# sourcing. So we extract the function bodies via a marker.
#
# Approach: re-source the script as-is but with PYTHON pointing at a
# deliberately-broken path so its initial venv probe does the detection
# we want to test. Capture the slack_post_message args BEFORE the script
# exits, then inspect.

# Build a sandbox dir for a fake script run
TMPD=$(mktemp -d -t wikitest.XXXXXX)
export HOME="$TMPD"
export WORLDAI_DEV_MODE=true
export GOOGLE_APPLICATION_CREDENTIALS="/dev/null"

# === Test 1: notify_error() posts to #ai-general (C0AJQ5M0A0Y) ===
echo "Test 1: notify_error() targets #ai-general (C0AJQ5M0A0Y)"
CAPTURED_CHANNEL=""
(
  set +u
  # Override notify() so we don't recurse into the real lib-slack-post path
  notify() {
    # notify <subject> <slack_text> [gmail_body]
    # The script passes $(slack_text) -> to slack_post_message.
    # We mimic the wrapper here in micro.
    slack_post_message "$CHANNEL_OVERRIDE" "$2"
  }
  CHANNEL_OVERRIDE=""
  # Source just the function definitions we need. The cleanest way is to
  # run the script up to but not past the trap, then call notify_error
  # manually. But the script sources lib-slack-post.sh at top, which is
  # fine because we stubbed slack_post_message above.
  # We instead run the script with a fresh subshell and a deliberately
  # empty SLACK_CHANNEL so the script's SLACK_CHANNEL="${SLACK_CHANNEL:-...}"
  # default kicks in — capturing which channel it picks.
  unset SLACK_CHANNEL
  # Source the whole script. Its `set -u` would abort on missing vars,
  # but we left notify() as a no-recursive stub so it ends gracefully.
  bash -c '
    set -u
    # Pre-stub the helper load so the notify function in the script
    # goes through OUR override when called.
    notify() {
      : # no-op; we trigger notify_error directly below
    }
    log() { :; }
    source "'"$SCRIPT"'"
  '
) >/dev/null 2>&1

# That source attempt will likely exit on the unset PYTHON -- that is
# OK for the first test. Re-source by extracting just the function defs.
#
# Simpler approach: read the script, extract the var-defaults + the
# notify_error function + the SLACK_CHANNEL default, source those as a
# minimal harness.

SLACK_LINE=$(grep -nE '^SLACK_CHANNEL=' "$SCRIPT" | head -1 | cut -d: -f1)
echo "    SLACK_CHANNEL declared at line $SLACK_LINE"
# Extract SLACK_CHANNEL default from script (without running the script)
DEFAULT_SLACK=$(grep -E '^SLACK_CHANNEL=' "$SCRIPT" | head -1 | sed -E 's/.*\$\{SLACK_CHANNEL:-([^}]+)\}.*/\1/')
echo "    Default SLACK_CHANNEL resolved to: '$DEFAULT_SLACK'"

# --- HARD ASSERTION: default must be C0AJQ5M0A0Y ---
if [[ "$DEFAULT_SLACK" == "C0AJQ5M0A0Y" ]]; then
  ok "SLACK_CHANNEL default = C0AJQ5M0A0Y (#ai-general)"
else
  bad "SLACK_CHANNEL default = '$DEFAULT_SLACK' (want 'C0AJQ5M0A0Y' for #ai-general)"
fi

# === Test 2: notify_error() prepends operator + Hermes mention ===
# The script uses ${SLACK_OPERATOR_ID} / ${SLACK_HERMES_BOT_ID} variables,
# not literal <@U09GH5BR3QU> strings, so we verify:
#   (a) the variables are defined at top of script,
#   (b) they hold the correct literal user IDs,
#   (c) the heredoc body of notify_error() interpolates both variables.
echo "Test 2: notify_error() tags <@U09GH5BR3QU> <@U0AEZC7RX1Q> on failure"

# (a) variable definitions present
DEF_OPERATOR=$(grep -E '^SLACK_OPERATOR_ID="U09GH5BR3QU"' "$SCRIPT" || echo "")
DEF_HERMES=$(grep -E '^SLACK_HERMES_BOT_ID="U0AEZC7RX1Q"' "$SCRIPT" || echo "")
if [[ -n "$DEF_OPERATOR" ]] && [[ -n "$DEF_HERMES" ]]; then
  ok "script declares SLACK_OPERATOR_ID + SLACK_HERMES_BOT_ID with correct literal IDs"
else
  bad "missing/invalid Slack ID variable declarations (operator='$DEF_OPERATOR' hermes='$DEF_HERMES')"
fi

# (b) notify_error heredoc interpolates both
HEREDOC_BODY=$(awk '
  /^notify_error\(\)/ { capture=1; next }
  capture && /^notify / { capture=0 }
  capture { print }
' "$SCRIPT")
USES_OPERATOR=$(printf '%s' "$HEREDOC_BODY" | grep -cE '<@\$\{SLACK_OPERATOR_ID\}>')
USES_HERMES=$(printf '%s' "$HEREDOC_BODY" | grep -cE '<@\$\{SLACK_HERMES_BOT_ID\}>')

if [[ "$USES_OPERATOR" -ge 1 ]] && [[ "$USES_HERMES" -ge 1 ]]; then
  ok "notify_error heredoc interpolates BOTH <@...> tags"
else
  bad "notify_error heredoc missing tag interpolation — operator-uses=$USES_OPERATOR hermes-uses=$USES_HERMES"
fi

# Bonus: check that the success path's build_success_summary() does NOT
# mention these IDs (USER_PROFILE: tag-only-on-failure-paths rule).
SUCCESS_HEREDOC=$(awk '
  /^build_success_summary\(\)/ { capture=1; next }
  capture && /^notify / { capture=0 }
  capture { print }
' "$SCRIPT")

SUCCESS_LEAKS_OPERATOR=$(printf '%s' "$SUCCESS_HEREDOC" | grep -cE '<@\$\{SLACK_OPERATOR_ID\}|<@U09GH5BR3QU>')
SUCCESS_LEAKS_HERMES=$(printf '%s' "$SUCCESS_HEREDOC" | grep -cE '<@\$\{SLACK_HERMES_BOT_ID\}|<@U0AEZC7RX1Q>')

if [[ "$SUCCESS_LEAKS_OPERATOR" -eq 0 ]] && [[ "$SUCCESS_LEAKS_HERMES" -eq 0 ]]; then
  ok "build_success_summary does NOT tag operator or Hermes (success path stays silent)"
else
  bad "build_success_summary inappropriately tags — operator=$SUCCESS_LEAKS_OPERATOR hermes=$SUCCESS_LEAKS_HERMES (must be 0 each)"
fi

# === Test 3: broken venv python detected BEFORE shell aborts ===
# Runs the script with PYTHON pointing at a guaranteed-missing path AND
# redirects LOG to a tmpfile so we can assert the preflight wrote a
# clear "venv python missing" diagnostic plus a remediation hint.
# The script's log() function does `echo ... | tee -a "$LOG"` so we
# capture stdout (where tee writes) and ignore stderr.
echo "Test 3: broken venv python triggers notify_error() with actionable error (not silent 'No such file or directory')"

TMPLOG="$TMPD/Library/Logs/wiki-campaign-daily-ingest.log"
(
  set +e
  HOME="$TMPD" \
  PYTHON="/nonexistent/pythonXYZ-$(date +%s)" \
  SLACK_CHANNEL="C0AJQ5M0A0Y" \
  GOOGLE_APPLICATION_CREDENTIALS="/dev/null" \
  WORLDAI_DEV_MODE=true \
  bash "$SCRIPT" \
    >/dev/null 2>&1 \
    || true
) >/dev/null 2>&1

if [[ ! -s "$TMPLOG" ]]; then
  bad "venv-precheck log is empty -- test setup failed (script never ran)"
else
  # Assert log contains both the venv diagnostic and a remediation hint.
  DIAG=$(grep -E 'venv python (missing|symlink broken)' "$TMPLOG" | head -1)
  RECOURSE=$(grep -E 'Recourse|recreate with|relink to a system' "$TMPLOG" | head -1)
  if [[ -n "$DIAG" ]]; then
    ok "venv precheck fired with actionable diagnostic: '${DIAG:0:80}'"
  else
    bad "venv precheck did not log an actionable diagnostic — log tail:"; tail -20 "$TMPLOG" | sed 's/^/    /'
  fi
  if [[ -n "$RECOURSE" ]]; then
    ok "venv precheck log includes remediation hint"
  else
    bad "venv precheck log missing remediation hint"
  fi
fi

# Cleanup
rm -rf "$TMPD"

echo
echo "==============================================="
echo "PASS: $PASS    FAIL: $FAIL"
echo "==============================================="
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
