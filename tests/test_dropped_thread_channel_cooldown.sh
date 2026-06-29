#!/usr/bin/env bash
# test_dropped_thread_channel_cooldown.sh — real (no-mock) tests for the
# per-channel cooldown rate-limit added to dropped-thread-followup.sh.
#
# Exercises the actual cooldown helpers by sourcing the script in function-only
# mode (IS_SOURCED=1 returns before main) and driving a real temp state file —
# no mocking of jq, date, or the state store.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DROP_SCRIPT="$SCRIPT_DIR/../scripts/dropped-thread-followup.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASSED=0
FAILED=0

log_pass() { echo -e "${GREEN}PASS${NC}: $1"; ((PASSED++)); }
log_fail() { echo -e "${RED}FAIL${NC}: $1"; ((FAILED++)); }
log_info() { echo -e "${YELLOW}INFO${NC}: $1"; }

# Isolate the state file so we never touch the live one.
TMP_STATE_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_STATE_DIR"' EXIT
export DROP_STATE_FILE="$TMP_STATE_DIR/state.json"
export DROP_LOG_DIR="$TMP_STATE_DIR/logs"

# Source script in function-only mode; restore -e afterwards (script sets -euo).
IS_SOURCED=1 source "$DROP_SCRIPT"
set +e

CH="C0AH3RY3DK6"   # #worldai — the channel that got flooded on 2026-06-11

# ── Test 1: fresh channel is NOT in cooldown ──────────────────────────────────
test_fresh_channel_not_in_cooldown() {
  log_info "Test: a never-nudged channel is not in cooldown"
  echo '{}' > "$DROP_STATE_FILE"
  if channel_in_cooldown "$CH"; then
    log_fail "fresh channel reported in cooldown"
  else
    log_pass "fresh channel not in cooldown"
  fi
}

# ── Test 2: after record_nudge, channel IS in cooldown (real cooldown skip) ────
test_record_then_cooldown() {
  log_info "Test: after a nudge, the same channel is rate-limited"
  echo '{}' > "$DROP_STATE_FILE"
  CHANNEL_COOLDOWN_SECS=600
  record_nudge "$CH" "1718000000.000100"
  if channel_in_cooldown "$CH"; then
    log_pass "channel in cooldown after record_nudge (second nudge would SKIP)"
  else
    log_fail "channel not in cooldown immediately after record_nudge"
  fi
}

# ── Test 3: per-channel epoch persisted atomically alongside per-thread marker ─
test_state_persists_both_keys() {
  log_info "Test: record_nudge writes BOTH .nudged and .channel_last_nudge"
  echo '{}' > "$DROP_STATE_FILE"
  record_nudge "$CH" "1718000000.000200"
  local nudged channel_epoch
  nudged="$(jq -r '.nudged["'"$CH"'_1718000000.000200"] // empty' "$DROP_STATE_FILE")"
  channel_epoch="$(jq -r '.channel_last_nudge["'"$CH"'"] // empty' "$DROP_STATE_FILE")"
  if [[ -n "$nudged" && -n "$channel_epoch" ]]; then
    log_pass "both per-thread ISO marker and per-channel epoch persisted ($channel_epoch)"
  else
    log_fail "missing key(s): nudged='$nudged' channel_epoch='$channel_epoch'"
  fi
}

# ── Test 4: cooldown expires once DROP_CHANNEL_COOLDOWN_SECS elapses ───────────
test_cooldown_expires() {
  log_info "Test: cooldown clears after the window elapses (tiny window)"
  echo '{}' > "$DROP_STATE_FILE"
  # Stamp the channel as nudged 5s ago, then use a 1s window: must be expired.
  local past=$(( $(date +%s) - 5 ))
  jq -n --arg ch "$CH" --argjson e "$past" '{channel_last_nudge: {($ch): $e}}' > "$DROP_STATE_FILE"
  CHANNEL_COOLDOWN_SECS=1
  if channel_in_cooldown "$CH"; then
    log_fail "channel still in cooldown after window elapsed"
  else
    log_pass "cooldown correctly expired with tiny DROP_CHANNEL_COOLDOWN_SECS"
  fi
}

# ── Test 5: distinct channels are independent ─────────────────────────────────
test_other_channel_independent() {
  log_info "Test: nudging one channel does not rate-limit a different channel"
  echo '{}' > "$DROP_STATE_FILE"
  CHANNEL_COOLDOWN_SECS=600
  record_nudge "$CH" "1718000000.000300"
  if channel_in_cooldown "${SLACK_CHANNEL_ID}"; then
    log_fail "unrelated channel reported in cooldown"
  else
    log_pass "unrelated channel independent of $CH cooldown"
  fi
}

# ── Test 6: record_channel_nudge arms cooldown outside DRY_RUN ───────────────
test_record_channel_nudge_arms_cooldown() {
  log_info "Test: record_channel_nudge (used by DRY_RUN) arms the per-channel cooldown"
  echo '{}' > "$DROP_STATE_FILE"
  CHANNEL_COOLDOWN_SECS=600
  # Explicitly clear DRY_RUN — the live-run path is what arms cooldown in prod.
  unset DRY_RUN
  record_channel_nudge "$CH"
  if channel_in_cooldown "$CH"; then
    log_pass "record_channel_nudge arms cooldown without writing a per-thread marker"
  else
    log_fail "record_channel_nudge did not arm cooldown"
  fi
}

# ── Test 7: record_channel_nudge is a NO-OP under DRY_RUN (no state writes) ──
test_record_channel_nudge_noop_in_dry_run() {
  log_info "Test: record_channel_nudge is a no-op under DRY_RUN=1 (no live-state poison)"
  echo '{}' > "$DROP_STATE_FILE"
  CHANNEL_COOLDOWN_SECS=600
  DRY_RUN=1 record_channel_nudge "$CH"
  # State file must be byte-for-byte unchanged from '{}'.
  local contents
  contents="$(cat "$DROP_STATE_FILE" 2>/dev/null)"
  if [[ "$contents" == "{}" ]]; then
    log_pass "DRY_RUN=1 record_channel_nudge did not write live state (P2 review fix)"
  else
    log_fail "DRY_RUN=1 record_channel_nudge poisoned live state: $contents"
  fi
  if channel_in_cooldown "$CH"; then
    log_fail "DRY_RUN=1 record_channel_nudge incorrectly armed cooldown"
  else
    log_pass "DRY_RUN=1 record_channel_nudge did not arm cooldown"
  fi
  unset DRY_RUN
}

THREAD="1781078086.705169"   # the real thread nudged 5x over 27h

# ── Test 8: legacy bare-string state migrates without error ───────────────────
test_legacy_bare_string_migrates() {
  log_info "Test: legacy bare-ISO-string .nudged value migrates to count=1, gave_up=false"
  # Exactly the live format in ~/.smartclaw_prod/logs/dropped-thread-state.json.
  printf '{"nudged":{"%s_%s":"2026-06-10T20:00:00Z"}}' "$CH" "$THREAD" > "$DROP_STATE_FILE"
  local count last gu
  count="$(nudge_count "$CH" "$THREAD")"
  last="$(nudge_field "$CH" "$THREAD" last)"
  gu="false"; nudge_gave_up "$CH" "$THREAD" && gu="true"
  if [[ "$count" == "1" && "$last" == "2026-06-10T20:00:00Z" && "$gu" == "false" ]]; then
    log_pass "bare-string migrated: count=1 last=preserved gave_up=false (no crash)"
  else
    log_fail "bare-string migration wrong: count=$count last=$last gave_up=$gu"
  fi
}

# ── Test 9: record_nudge increments count across the object boundary ──────────
test_record_nudge_increments_count() {
  log_info "Test: record_nudge migrates bare string then increments count to 2"
  printf '{"nudged":{"%s_%s":"2026-06-10T20:00:00Z"}}' "$CH" "$THREAD" > "$DROP_STATE_FILE"
  unset DRY_RUN
  record_nudge "$CH" "$THREAD"
  local count typ
  count="$(nudge_count "$CH" "$THREAD")"
  typ="$(jq -r '.nudged["'"${CH}_${THREAD}"'"] | type' "$DROP_STATE_FILE")"
  if [[ "$count" == "2" && "$typ" == "object" ]]; then
    log_pass "record_nudge: count incremented 1->2 and value is now an object"
  else
    log_fail "record_nudge increment failed: count=$count type=$typ"
  fi
}

# ── Test 10: at DROP_MAX_NUDGES the loop escalates ONCE and sets gave_up ───────
# Stub ONLY the external Slack-posting boundary (post_escalation_reply) so we can
# count escalations without hitting Slack; the give-up state logic under test is real.
ESC_COUNT=0
post_escalation_reply() { ((ESC_COUNT++)); }

test_escalate_once_then_give_up() {
  log_info "Test: when count >= DROP_MAX_NUDGES, escalate exactly once and set gave_up"
  MAX_NUDGES=3
  unset DRY_RUN
  ESC_COUNT=0
  # Seed a record already at the cap (count=3) in object form.
  jq -n --arg k "${CH}_${THREAD}" \
    '{nudged: {($k): {last: "2026-06-10T20:00:00Z", count: 3, gave_up: false}}}' \
    > "$DROP_STATE_FILE"

  # Replicate the loop's decision block (the exact code path in the script).
  # Sets DECISION in the current shell (no subshell) so ESC_COUNT increments survive.
  DECISION=""
  decide() {
    if nudge_gave_up "$CH" "$THREAD"; then DECISION="skip-gaveup"; return; fi
    if [[ "$(nudge_count "$CH" "$THREAD")" -ge "$MAX_NUDGES" ]]; then
      post_escalation_reply "esc"
      mark_gave_up "$CH" "$THREAD"
      DECISION="escalated"; return
    fi
    DECISION="nudge"
  }

  local r1 r2
  decide; r1="$DECISION"   # should escalate + set gave_up
  decide; r2="$DECISION"   # should now skip (gave_up)
  local gu="false"; nudge_gave_up "$CH" "$THREAD" && gu="true"

  if [[ "$r1" == "escalated" && "$gu" == "true" && "$ESC_COUNT" == "1" ]]; then
    log_pass "first attempt at cap escalated once (ESC_COUNT=1) and set gave_up=true"
  else
    log_fail "expected escalate+gaveup: r1=$r1 gave_up=$gu esc_count=$ESC_COUNT"
  fi
  # ── Test 11 (subassert): once gave_up, no further nudge or escalation ───────
  if [[ "$r2" == "skip-gaveup" && "$ESC_COUNT" == "1" ]]; then
    log_pass "after give-up, subsequent ticks skip with NO further escalation (ESC_COUNT still 1)"
  else
    log_fail "expected skip-gaveup with no extra escalation: r2=$r2 esc_count=$ESC_COUNT"
  fi
}

main() {
  echo "========================================"
  echo "dropped-thread per-channel cooldown tests"
  echo "========================================"
  echo ""
  test_fresh_channel_not_in_cooldown
  test_record_then_cooldown
  test_state_persists_both_keys
  test_cooldown_expires
  test_other_channel_independent
  test_record_channel_nudge_arms_cooldown
  test_record_channel_nudge_noop_in_dry_run
  test_legacy_bare_string_migrates
  test_record_nudge_increments_count
  test_escalate_once_then_give_up
  echo ""
  echo "========================================"
  echo "Results: $PASSED passed, $FAILED failed"
  echo "========================================"
  [[ $FAILED -gt 0 ]] && exit 1
  exit 0
}

main "$@"
