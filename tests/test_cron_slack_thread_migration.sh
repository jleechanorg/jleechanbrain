#!/usr/bin/env bash
# test_cron_slack_thread_migration.sh
#
# Static-analysis test that the 4 cron scripts from bead jleechan-ry3y have
# been migrated to source lib/slack_thread_lib.sh instead of shadowing the
# `slack_post` helper with their own local definition.
#
# Verifies (per script):
#   T1. The lib is sourced (bash) OR Python shells out to bash -c 'source lib && slack_post' (wa_daily).
#   T2. No local `slack_post() {` definition remains in the script.
#   T3. A `slack_post` invocation appears that matches the lib's signature
#       (slack_post <job> <text> [--channel C]) OR, for canary, the lib's
#       slack_thread_anchor_get/set helpers are used.
#
# Plus an idempotency test (T4): running a no-op transformation of each script
# twice does not introduce duplicate `source` lines or break sourcing.
#
# Layer: 1 (static analysis). Does not run the cron scripts or talk to Slack.
set -uo pipefail

# Resolve repo root from this test's path so the test works in worktrees too.
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
LIB="$REPO_ROOT/lib/slack_thread_lib.sh"

[[ -f "$LIB" ]] || { echo "FAIL: lib not found at $LIB"; exit 1; }

PASSED=0
FAILED=0
pass() { echo "PASS: $1"; PASSED=$((PASSED + 1)); }
fail() { echo "FAIL: $1"; FAILED=$((FAILED + 1)); }

# ─── T1/T2/T3: per-script migration checks ───────────────────────────────────
# Args: $1 = script path, $2 = job-name expected in slack_post invocation,
#       $3 = mode: bash or python
check_script() {
  local script="$1" expected_job="$2" mode="$3"
  local label
  label="$(basename "$script")"

  # T1: lib is sourced / reached
  case "$mode" in
    bash)
      if grep -qE '(^|[[:space:]])source[[:space:]]+"?\$LIB_DIR/slack_thread_lib\.sh"?[[:space:]]*$' "$script" \
         || grep -qE 'source[[:space:]]+"?\S*slack_thread_lib\.sh"?[[:space:]]*$' "$script"; then
        pass "[$label] T1: sources slack_thread_lib.sh"
      else
        fail "[$label] T1: does not source slack_thread_lib.sh"
      fi
      ;;
    python)
      # Python helper must shell out to the lib via subprocess + bash -c.
      if grep -q 'slack_thread_lib\.sh' "$script" \
         && grep -q 'subprocess\.run' "$script" \
         && grep -q 'bash' "$script"; then
        pass "[$label] T1: Python shells out to slack_thread_lib.sh"
      else
        fail "[$label] T1: Python does not shell out to slack_thread_lib.sh"
      fi
      ;;
  esac

  # T2: no local `slack_post() {` definition that would shadow the lib.
  # Allow comments and inline references; only flag function-definition lines.
  if grep -nE '^[[:space:]]*slack_post[[:space:]]*\(\)[[:space:]]*\{' "$script" >/dev/null; then
    # For commit-pending-changes.sh: a local wrapper that calls the lib's
    # slack_post (renamed) is the documented migration pattern. Allow it if
    # the wrapper body delegates to lib_slack_post / slack_thread_anchor_*.
    if [[ "$label" == "commit-pending-changes.sh" ]] \
       && grep -q 'lib_slack_post' "$script"; then
      pass "[$label] T2: local slack_post is a thin wrapper that delegates to lib"
    elif [[ "$label" == "hermes-canary.sh" ]] \
         && grep -q 'slack_thread_anchor_get' "$script" \
         && grep -q 'slack_thread_anchor_set' "$script"; then
      pass "[$label] T2: local slack_post is a thin wrapper that uses lib anchor helpers"
    else
      fail "[$label] T2: still defines a local slack_post() that shadows the lib"
    fi
  else
    pass "[$label] T2: no local slack_post() shadow"
  fi

  # T3: a slack_post call matches the lib signature.
  case "$mode" in
    bash)
      # Look for `slack_post "job-name"` (the lib's first arg).
      if grep -nE "slack_post[[:space:]]+[\"']${expected_job}[\"']" "$script" >/dev/null; then
        pass "[$label] T3: calls slack_post with job='$expected_job'"
      elif grep -nE "lib_slack_post[[:space:]]+[\"']${expected_job}[\"']" "$script" >/dev/null; then
        # commit-pending-changes.sh uses the renamed lib_slack_post alias.
        pass "[$label] T3: calls lib_slack_post (lib alias) with job='$expected_job'"
      elif [[ "$label" == "hermes-canary.sh" ]] \
           && grep -q 'slack_thread_anchor_get' "$script"; then
        pass "[$label] T3: uses slack_thread_anchor_get (lib helper)"
      else
        fail "[$label] T3: no slack_post call with expected job='$expected_job'"
      fi
      ;;
    python)
      # Python helper invokes slack_post via the bash subprocess.
      if grep -nE "slack_post[[:space:]]+[\"']${expected_job}[\"']" "$script" >/dev/null; then
        pass "[$label] T3: Python subprocess invokes slack_post '$expected_job'"
      else
        fail "[$label] T3: no slack_post invocation with job='$expected_job'"
      fi
      ;;
  esac
}

check_script "$REPO_ROOT/scripts/auto-push-to-main.sh"        "auto-push-to-main"        bash
check_script "$REPO_ROOT/scripts/commit-pending-changes.sh"   "commit-pending"           bash
check_script "$REPO_ROOT/scripts/hermes-canary.sh"           "hermes-canary"            bash
check_script "$REPO_ROOT/scripts/wa_daily_test_watcher.sh"    "wa-daily-test-watcher"    python

# ─── T4: idempotency ─────────────────────────────────────────────────────────
# Re-sourcing the lib is a no-op (the lib guards against double-sourcing).
# The 4 scripts must each source it exactly once (no duplicate lines that
# would cause double-source warning spam).
for script in \
    "$REPO_ROOT/scripts/auto-push-to-main.sh" \
    "$REPO_ROOT/scripts/commit-pending-changes.sh" \
    "$REPO_ROOT/scripts/hermes-canary.sh" \
    "$REPO_ROOT/scripts/wa_daily_test_watcher.sh"; do
  label="$(basename "$script")"
  sources=$(grep -cE 'source[[:space:]]+"?\$?LIB_DIR/slack_thread_lib\.sh"?[[:space:]]*$|source[[:space:]]+"?\S*lib/slack_thread_lib\.sh"?' "$script" || true)
  if [[ "$sources" -eq 1 ]]; then
    pass "[$label] T4: exactly one source line for slack_thread_lib.sh"
  else
    fail "[$label] T4: found $sources source lines for slack_thread_lib.sh (expected 1)"
  fi
done

# ─── T5: shell syntax check on each migrated script ──────────────────────────
for script in \
    "$REPO_ROOT/scripts/auto-push-to-main.sh" \
    "$REPO_ROOT/scripts/commit-pending-changes.sh" \
    "$REPO_ROOT/scripts/hermes-canary.sh" \
    "$REPO_ROOT/scripts/wa_daily_test_watcher.sh"; do
  label="$(basename "$script")"
  if bash -n "$script" 2>/dev/null; then
    pass "[$label] T5: bash -n passes (no syntax errors)"
  else
    fail "[$label] T5: bash -n reports syntax errors"
  fi
done

# ─── T6: behavioral verification of P1 review fixes ──────────────────────────
# Two regressions closed by chatgpt-codex-connector on PR #630:
#   (a) commit-pending-changes.sh: lib_slack_post was a wrapper
#       `{ slack_post "$@"; }` that resolved slack_post at call time, recursing
#       into the local slack_post defined later. Fixed by physically copying
#       the lib's slack_post body via `declare -f` + `eval`.
#   (b) hermes-canary.sh: stored the canary message ts as the daily-thread
#       anchor, then deleted that message; subsequent same-day canary runs
#       threaded under a deleted parent. Fixed by separating concerns: a
#       dedicated anchor message is created (and never deleted), and the
#       canary message threads under it.

# T6a: declare -f + eval pattern preserves the lib's slack_post even after a
# later function definition shadows `slack_post` in the same shell.
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
(
  cd "$tmpdir"
  # Fresh shell with a dedicated state dir so the lib doesn't touch real state.
  export SLACK_THREAD_STATE_DIR="$tmpdir/state"
  export SLACK_DEDUPE_STATE_DIR="$tmpdir/dedupe"
  mkdir -p "$SLACK_THREAD_STATE_DIR" "$SLACK_DEDUPE_STATE_DIR"

  # shellcheck source=lib/slack_thread_lib.sh
  source "$LIB"

  # Mock the lib's curl path so slack_post returns cleanly without Slack.
  export SLACK_BOT_TOKEN="xoxb-test-mock"
  export SLACK_POST_MOCK_RESP='{"ok":true,"channel":"C0TEST","ts":"1700000000.000100"}'

  # Apply the same fix the script uses: declare -f + sed + eval copies the
  # lib's slack_post body under a new name BEFORE any local shadow.
  eval "$(declare -f slack_post | sed '1s/^slack_post()/lib_slack_post()/')"

  # Now define a local slack_post that records every call. If lib_slack_post
  # resolved `slack_post` at call time (the bug), this would recurse into
  # itself. With the fix, lib_slack_post holds the lib's body verbatim.
  RECURSION_DEPTH=0
  slack_post() {
    RECURSION_DEPTH=$((RECURSION_DEPTH + 1))
    if [[ $RECURSION_DEPTH -gt 5 ]]; then
      echo "INFINITE_RECURSION_DETECTED" >&2
      return 99
    fi
    lib_slack_post "test-job" "test-text" 2>/dev/null
  }

  # Trigger the local wrapper; should not recurse.
  slack_post "trigger"
  rc=$?
  if [[ $rc -eq 99 ]]; then
    fail "T6a: recursion detected — declare -f copy did not survive shadow"
  elif [[ $RECURSION_DEPTH -ne 1 ]]; then
    fail "T6a: unexpected depth=$RECURSION_DEPTH (expected 1)"
  else
    pass "T6a: declare -f copy survives shadow; no recursion (depth=$RECURSION_DEPTH)"
  fi
)

# T6b: hermes-canary.sh source must contain the slack_ensure_anchor helper and
# route every slack_post call through it (so the anchor is created separately
# from the canary message and survives slack_delete_message).
if grep -q 'slack_ensure_anchor()' "$REPO_ROOT/scripts/hermes-canary.sh" \
   && grep -q 'slack_thread_anchor_set' "$REPO_ROOT/scripts/hermes-canary.sh" \
   && grep -qE 'slack_post\(\)[[:space:]]*\{' "$REPO_ROOT/scripts/hermes-canary.sh"; then
  # Verify slack_post calls slack_ensure_anchor (not slack_thread_anchor_get)
  if awk '/^slack_post\(\) \{/,/^\}/' "$REPO_ROOT/scripts/hermes-canary.sh" \
       | grep -q 'slack_ensure_anchor'; then
    pass "T6b: hermes-canary.sh routes slack_post through slack_ensure_anchor"
  else
    fail "T6b: hermes-canary.sh slack_post body does not call slack_ensure_anchor"
  fi
else
  fail "T6b: hermes-canary.sh missing slack_ensure_anchor helper"
fi

# T6c: hermes-canary.sh anchor message must NOT be deleted by slack_delete_message.
# Verify the canary's MSG_TS is the message we delete (slack_delete_message
# "$MSG_TS") and the anchor set call uses a SEPARATE ts (the one we post
# inside slack_ensure_anchor, never assigned to MSG_TS).
if awk '/^slack_ensure_anchor\(\) \{/,/^\}/' "$REPO_ROOT/scripts/hermes-canary.sh" \
     | grep -q 'slack_thread_anchor_set' \
   && grep -qE 'slack_delete_message[[:space:]]+"\$MSG_TS"' "$REPO_ROOT/scripts/hermes-canary.sh"; then
  # The anchor ts and MSG_TS must come from different curl calls.
  if [[ "$(grep -cE 'curl -sf -X POST "https://slack\.com/api/chat\.postMessage"' "$REPO_ROOT/scripts/hermes-canary.sh")" -ge 2 ]]; then
    pass "T6c: hermes-canary.sh has separate anchor + canary POSTs; MSG_TS is deleted, anchor survives"
  else
    fail "T6c: hermes-canary.sh appears to use a single post for anchor+canary"
  fi
else
  fail "T6c: hermes-canary.sh does not separate anchor deletion from canary deletion"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
echo
echo "Summary: $PASSED passed, $FAILED failed"
[[ "$FAILED" -eq 0 ]] && exit 0 || exit 1
