#!/usr/bin/env bash
# Regression: deploy.sh Stage 5 must retry the canary on transient failure
# (e.g. hermes-canary.sh cron anchor race) and only die after the second failure.
#
# Root cause (2026-06-17 18:39:42Z): deploy canary failed because
# hermes-canary.sh cron posted its daily-thread anchor at the same instant.
# Manual retry at 18:41:19Z returned the exact nonce in 7.3s — LLM pipeline
# was healthy, just a transient race. Without retry logic, deploy was a
# false-positive failure.
#
# Strategy: extract the Stage 5 block from deploy.sh and run it with a
# stub canary script that fails N times then succeeds. Assert the deploy
# exit code matches the stub's eventual outcome (success → deploy succeeds
# after retry; persistent failure → deploy dies after the second attempt).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEPLOY_SH="$REPO_DIR/scripts/deploy.sh"

[[ -f "$DEPLOY_SH" ]] || { echo "FAIL: $DEPLOY_SH not found"; exit 1; }

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# Build a temp fixture that wraps the Stage 5 block from deploy.sh and
# drives it against a stub canary script we control. We override
# SCRIPT_DIR so the deploy Stage 5 calls our stub instead of the real
# hermes-canary.sh.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Stub canary: honors STUB_CANARY_FAIL_COUNT env var, fails that many
# times then exits 0. Records call count in $STUB_CALLS_LOG file because
# each invocation is a subshell (cannot mutate parent env).
cat > "$TMP/hermes-canary.sh" <<'STUB'
#!/usr/bin/env bash
n=${STUB_CANARY_FAIL_COUNT:-0}
# Atomic increment of a per-stub counter file.
counter_file="$STUB_CALLS_LOG"
touch "$counter_file"
current=$(wc -l < "$counter_file" | tr -d ' ')
call_n=$((current + 1))
echo "call ${call_n}" >> "$counter_file"
if [[ "$call_n" -le "$n" ]]; then
  echo "STUB: canary call ${call_n}/${n} (failing)"
  exit 1
fi
echo "STUB: canary call ${call_n} (success)"
exit 0
STUB
chmod +x "$TMP/hermes-canary.sh"
STUB_CALLS_LOG="$TMP/calls.log" export STUB_CALLS_LOG

# Extract the Stage 5 block from deploy.sh (from "Stage 5: Canary Check"
# up to but not including "Stage 5.5").
extract_stage5() {
  awk '
    /# ── Stage 5:/ { capturing = 1 }
    capturing { print }
    /# ── Stage 5\.5:/ { exit }
  ' "$DEPLOY_SH"
}

# Wrap Stage 5 in a script that uses our stub instead of the real
# hermes-canary.sh. We do this by overriding SCRIPT_DIR via env.
build_stage5_runner() {
  local fail_count="$1"
  local out="$TMP/run_stage5.sh"
  cat > "$out" <<WRAP
#!/usr/bin/env bash
set -euo pipefail
# override SCRIPT_DIR so "\$SCRIPT_DIR/hermes-canary.sh" hits our stub
export SCRIPT_DIR="$TMP"
export STUB_DIR="$TMP"
export STUB_CALLS_LOG="$STUB_CALLS_LOG"
export STUB_CANARY_FAIL_COUNT="$fail_count"
export PROD_PORT=8643
# Provide the section() and die() helpers that deploy.sh uses upstream
ts()      { date '+%Y-%m-%d %H:%M:%S'; }
section() { echo ""; echo "=== \$1 ==="; echo "\$(ts)"; echo ""; }
die()     { echo "DIE: \$*" >&2; exit 1; }
WRAP
  extract_stage5 >> "$out"
  chmod +x "$out"
  echo "$out"
}

# ── Case 1: stub passes first try → no retry, no die ────────────────────────
rm -f "$STUB_CALLS_LOG"
RUNNER=$(build_stage5_runner 0)
STUB_DIR="$TMP" bash "$RUNNER" && rc=0 || rc=$?
CALLS=$(wc -l < "$STUB_CALLS_LOG" | tr -d ' ')
if [[ "$rc" -eq 0 ]] && [[ "$CALLS" -eq 1 ]]; then
  pass "first-try success: deploy Stage 5 passes with 1 canary call"
else
  fail "first-try success: rc=$rc calls=$CALLS (expected rc=0 calls=1)"
fi

# ── Case 2: stub fails once then succeeds → retry succeeds, deploy passes ──
rm -f "$STUB_CALLS_LOG"
RUNNER=$(build_stage5_runner 1)
STUB_DIR="$TMP" bash "$RUNNER" >/dev/null 2>&1 && rc=0 || rc=$?
CALLS=$(wc -l < "$STUB_CALLS_LOG" | tr -d ' ')
if [[ "$rc" -eq 0 ]] && [[ "$CALLS" -eq 2 ]]; then
  pass "transient race: deploy Stage 5 passes after retry (2 calls, rc=0)"
else
  fail "transient race: rc=$rc calls=$CALLS (expected rc=0 calls=2)"
fi

# ── Case 3: stub fails twice → deploy dies after second failure ─────────────
rm -f "$STUB_CALLS_LOG"
RUNNER=$(build_stage5_runner 2)
STUB_DIR="$TMP" bash "$RUNNER" >/dev/null 2>&1 && rc=0 || rc=$?
CALLS=$(wc -l < "$STUB_CALLS_LOG" | tr -d ' ')
# Expect non-zero (die ran) and exactly 2 canary attempts (no 3rd)
if [[ "$rc" -ne 0 ]] && [[ "$CALLS" -eq 2 ]]; then
  pass "persistent failure: deploy dies after 2 canary calls (rc=$rc calls=$CALLS)"
else
  fail "persistent failure: rc=$rc calls=$CALLS (expected non-zero rc, 2 calls)"
fi

# ── Case 4: Stage 5 block must mention retry behavior in a comment ─────────
# Guard against the fix being removed in a future edit (a regression where
# someone simplifies Stage 5 back to a single attempt without the retry).
if grep -q 'waiting 30s before retry' "$DEPLOY_SH"; then
  pass "Stage 5 retry comment is present in deploy.sh"
else
  fail "Stage 5 retry comment missing from deploy.sh (fix may have been removed)"
fi

# ── Case 4b: Stage 5 actually sleeps 30s between attempts ───────────────────
# Guards against a regression where someone changes `sleep 30` to e.g.
# `sleep 5` (too short — re-races the same cron window) or `sleep 60`
# (blocks deploy for too long on a genuine outage). The 30s value is
# deliberate: long enough for the cron anchor to clear the gateway event
# loop, short enough that a real outage is surfaced within ~1 minute.
if grep -qE '^\s*sleep[[:space:]]+30\s*$' "$DEPLOY_SH"; then
  pass "Stage 5 retry uses documented 30s backoff"
else
  fail "Stage 5 retry sleep duration is not 30s (would defeat the race-recovery purpose)"
fi

# ── Case 5: heredoc strings to make sure no syntax error leaked into Stage 5
# Run the full Stage 5 with a passing stub and assert we don't hit
# bash syntax errors (a malformed heredoc would surface as rc=2 here).
rm -f "$STUB_CALLS_LOG"
RUNNER=$(build_stage5_runner 0)
if STUB_DIR="$TMP" bash -n "$RUNNER" 2>/dev/null; then
  pass "Stage 5 runner has valid bash syntax"
else
  fail "Stage 5 runner has bash syntax errors"
fi

# ── Case 6: persistent failure prints the exact die message ────────────────
# Catches the silent-regression where someone rewords the die() call and
# loses the actionable "Check logs" hint. We capture stderr and assert the
# exact operator-facing string is emitted.
rm -f "$STUB_CALLS_LOG"
RUNNER=$(build_stage5_runner 2)
STUB_DIR="$TMP" bash "$RUNNER" >/dev/null 2>"$TMP/case6.err" && rc=0 || rc=$?
EXPECTED="Canary failed twice — production gateway may be unhealthy. Check logs."
if [[ "$rc" -ne 0 ]] && grep -qF "$EXPECTED" "$TMP/case6.err"; then
  pass "persistent failure: die() prints exact operator-facing message"
else
  fail "persistent failure: rc=$rc message missing or wrong (see $TMP/case6.err)"
fi

# ── Case 7: comment block above Stage 5 captures the race rationale ─────────
# Catches a future edit where someone strips the operator-facing comment
# block (which documents the 4 false-positive instances, the WS-pong
# discipline, and the 30s backoff derivation). Without this guard, a
# drive-by refactor could delete the rationale and leave future operators
# to re-derive the entire diagnosis from logs.
STAGE5_BLOCK="$(awk '
  /^# ── Stage 5:/ { capturing = 1; next }
  /^# ── Stage 5\.5:/ { exit }
  capturing { print }
' "$DEPLOY_SH")"
if echo "$STAGE5_BLOCK" | grep -qE '(hermes-canary.sh|anchor|race|SlackSocket|event-loop|30s)'; then
  pass "Stage 5 comment block documents the canary-race rationale"
else
  fail "Stage 5 comment block missing race rationale (cron anchor / SlackSocket / 30s backoff)"
fi

# ── Case 8: file-based counter is the documented retry mechanism ───────────
# Bash subshells can't mutate parent env vars, so the canary-stub counter
# is persisted to a per-test file (`STUB_CALLS_LOG`). This test asserts the
# stub itself increments via the file (not env), so future refactors don't
# silently regress the persistence path and break the "exactly 2 canary
# calls" assertion in case 3.
rm -f "$STUB_CALLS_LOG"
STUB_DIR="$TMP" bash -c 'export STUB_CALLS_LOG="'"$STUB_CALLS_LOG"'"; export STUB_CANARY_FAIL_COUNT="0"; '"$TMP"'/hermes-canary.sh; '"$TMP"'/hermes-canary.sh; '"$TMP"'/hermes-canary.sh' >/dev/null 2>&1
CALLS=$(wc -l < "$STUB_CALLS_LOG" | tr -d ' ')
if [[ "$CALLS" -eq 3 ]]; then
  pass "file-based counter increments across 3 invocations (3 calls)"
else
  fail "file-based counter: expected 3 calls, got $CALLS (stub persistence broken)"
fi

echo ""
echo "Stage 5 canary-retry: $PASS pass, $FAIL fail"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
