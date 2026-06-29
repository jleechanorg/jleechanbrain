#!/usr/bin/env bash
# Regression: ao-progress-reporter.sh must NOT post a status block every 30 min
# for an unchanged session, and must prune terminal sessions from its state file
# so the file stops growing unbounded.
#
# Root cause (see .dark-factory/ao-status-forever.md): the reporter posted a block
# for every active session on every tick — even when HEAD SHA + status were
# unchanged — so a long-lived pr_open session (e.g. PR #601, ~144 reports) was
# re-reported forever, and the state file accumulated 230+ un-pruned keys.
#
# This test sources the script helpers (IS_SOURCED=1) and drives the real
# decision logic, then exercises the actual state-prune jq expression.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/ao-progress-reporter.sh"

PASSED=0
FAILED=0
pass() { echo "PASS: $1"; PASSED=$((PASSED + 1)); }
fail() { echo "FAIL: $1"; FAILED=$((FAILED + 1)); }

[[ -f "$SCRIPT" ]] || { echo "FAIL: missing $SCRIPT"; exit 1; }

# Source helpers only — IS_SOURCED=1 stops the script before main runs.
# shellcheck source=/dev/null
IS_SOURCED=1 source "$SCRIPT"

# Sanity: helpers exist
for fn in session_should_report is_terminal_status; do
  if [[ "$(type -t "$fn")" == "function" ]]; then
    pass "helper defined: $fn"
  else
    fail "helper missing: $fn"
  fi
done

# ── Suppress no-op: same SHA, same status → NO report ────────────────────────
# Prior state recorded SHA X / status pr_open. This tick: same SHA X (so
# has_new_commits=no), same status pr_open. Expect suppression.
if session_should_report "no" "pr_open" "pr_open"; then
  fail "unchanged session (same SHA, same status) was NOT suppressed"
else
  pass "unchanged session suppressed (no post)"
fi

# ── New commits (SHA X → SHA Y) → report block IS produced ───────────────────
if session_should_report "yes" "pr_open" "pr_open"; then
  pass "new commits produce a report block"
else
  fail "new commits were incorrectly suppressed"
fi

# ── Status change (working → pr_open) with same SHA → report ─────────────────
if session_should_report "no" "pr_open" "working"; then
  pass "status change produces a report block"
else
  fail "status change was incorrectly suppressed"
fi

# ── First sighting (no prior status) → report (never go silent on new work) ──
if session_should_report "no" "working" ""; then
  pass "first sighting (empty last_status) produces a report block"
else
  fail "first sighting was incorrectly suppressed"
fi

# ── Terminal-state classification ────────────────────────────────────────────
for s in killed merged closed done; do
  if is_terminal_status "$s"; then
    pass "is_terminal_status: $s is terminal"
  else
    fail "is_terminal_status: $s should be terminal"
  fi
done
for s in pr_open working spawning idle stuck; do
  if is_terminal_status "$s"; then
    fail "is_terminal_status: $s should NOT be terminal"
  else
    pass "is_terminal_status: $s correctly non-terminal"
  fi
done

# ── Prune (real helper): orphan terminals removed, active terminals retained ──
# Drive the ACTUAL prune_terminal_orphans() helper from the script — NOT a
# re-implementation of the jq — so the test pins the real code path. Seeded
# state has a terminal orphan, a terminal-but-still-active session, and a live
# orphan, plus daily_threads. "seen" = sessions present in THIS tick.
seed_state='{
  "daily_threads": { "2026-06-11": "1781000000.000100" },
  "jc-dead":   { "last_sha": "aaa111", "last_status": "killed",  "last_report": 1781000000 },
  "jc-ending": { "last_sha": "ccc333", "last_status": "merged",  "last_report": 1781000002 },
  "jc-live":   { "last_sha": "bbb222", "last_status": "pr_open", "last_report": 1781000001 }
}'
# This tick only jc-ending and jc-live are still active; jc-dead has left.
seen='["jc-ending","jc-live"]'
pruned="$(prune_terminal_orphans "$seed_state" "$seen")"

# jc-dead: terminal AND gone from the active set → pruned.
if echo "$pruned" | jq -e 'has("jc-dead")' >/dev/null; then
  fail "terminal orphan jc-dead still present after prune"
else
  pass "terminal orphan jc-dead pruned from state"
fi

# jc-ending: terminal BUT still active → retained. Deleting it would make it a
# "first sighting" next tick and re-report forever (the regression we prevent).
if echo "$pruned" | jq -e 'has("jc-ending")' >/dev/null; then
  pass "terminal-but-active jc-ending retained (no re-report regression)"
else
  fail "terminal-but-active jc-ending was wrongly pruned"
fi

# jc-live: non-terminal orphan → retained. A transient drop from the active set
# must never lose a live session's state.
if echo "$pruned" | jq -e 'has("jc-live")' >/dev/null; then
  pass "non-terminal orphan jc-live preserved after prune"
else
  fail "non-terminal orphan jc-live was wrongly pruned"
fi

# daily_threads MUST survive pruning (per-day thread persistence is sacred).
if echo "$pruned" | jq -e '.daily_threads["2026-06-11"] == "1781000000.000100"' >/dev/null; then
  pass "daily_threads persistence intact after prune"
else
  fail "daily_threads was damaged by prune"
fi

# Empty active set: every terminal is an orphan → pruned; non-terminal +
# daily_threads survive.
pruned_empty="$(prune_terminal_orphans "$seed_state" '[]')"
if echo "$pruned_empty" | jq -e 'has("jc-dead") or has("jc-ending")' >/dev/null; then
  fail "terminal sessions survived prune with empty active set"
else
  pass "all terminal sessions pruned when active set is empty"
fi
if echo "$pruned_empty" | jq -e 'has("jc-live") and (.daily_threads | has("2026-06-11"))' >/dev/null; then
  pass "non-terminal + daily_threads survive empty-active-set prune"
else
  fail "non-terminal or daily_threads lost on empty-active-set prune"
fi

# ── E2E empty active set pruning integration test ────────────────────────────
E2E_STATE_FILE="$(mktemp)"

cat > "$E2E_STATE_FILE" <<'JSON'
{
  "daily_threads": { "2026-06-11": "1781000000.000100" },
  "jc-dead":   { "last_sha": "aaa111", "last_status": "killed",  "last_report": 1781000000 },
  "jc-live":   { "last_sha": "bbb222", "last_status": "pr_open", "last_report": 1781000001 }
}
JSON

DRY_RUN=1 \
AOPR_STATE_FILE="$E2E_STATE_FILE" \
AOPR_LOCK_DIR="${E2E_STATE_FILE}.lock" \
AOPR_LOG_DIR="${E2E_STATE_FILE}.logs" \
AO_DIR="/does/not/exist" \
GH_TOKEN="dummy_token" \
bash "$SCRIPT" >/dev/null 2>&1 || true

if [[ -f "$E2E_STATE_FILE" ]]; then
  updated_state="$(cat "$E2E_STATE_FILE")"
  if echo "$updated_state" | jq -e 'has("jc-dead")' >/dev/null; then
    fail "E2E: terminal session jc-dead was NOT pruned when active set is empty"
  else
    pass "E2E: terminal session jc-dead was pruned when active set is empty"
  fi
  if echo "$updated_state" | jq -e 'has("jc-live")' >/dev/null; then
    pass "E2E: live session jc-live preserved when active set is empty"
  else
    fail "E2E: live session jc-live was wrongly pruned when active set is empty"
  fi
else
  fail "E2E: state file was deleted"
fi

rm -f "$E2E_STATE_FILE"

echo ""
if [[ "$FAILED" -gt 0 ]]; then
  echo "FAILED: $FAILED test(s), PASSED: $PASSED"
  exit 1
fi
echo "PASSED: $PASSED test(s)"

