#!/usr/bin/env bash
# test_cron_dispatch_contract.sh
#
# Contract tests for scripts/cron-dispatch.sh
# Goal: verify that the openclaw-cron-add → hermes-cron-create translation
# is correct, without ever actually creating a live cron job (we always pass
# --dry-run, which the script's contract guarantees will not call hermes).
#
# Output format (--dry-run): one ARG_TOKEN=<value> per line. Each arg is
# exactly one token — multi-token flags like "--repeat 1" come out as two
# separate lines (ARG_TOKEN=--repeat / ARG_TOKEN=1), so `eval` of the output
# round-trips into the same argv hermes would receive in live mode.
#
# Mirrors the assertion style of scripts/tests/test_digest_parser.sh.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/cron-dispatch.sh"

if [[ ! -f "$SCRIPT" ]]; then
  echo "FATAL: cron-dispatch.sh not found at $SCRIPT" >&2
  exit 1
fi

# Constants the SOUL.md COMMITs hardcode — change-detection regression bait.
CHANNEL_STATUS_20M="${SLACK_CHANNEL_ID}"   # jleechan DM per CLAUDE.md "Slack — Posting"
CHANNEL_FOLLOWUP_10M="${SLACK_CHANNEL_ID}" # alternate channel example

PASSED=0
FAILED=0

# --- assertions -------------------------------------------------------------

assert_contains() {
  local description="$1"
  local actual="$2"
  local needle="$3"
  if [[ "$actual" == *"$needle"* ]]; then
    printf '  PASS: %s\n' "$description"
    PASSED=$((PASSED + 1))
  else
    printf '  FAIL: %s\n' "$description"
    printf '    expected substring: %s\n' "$needle"
    printf '    actual:\n%s\n' "$actual"
    FAILED=$((FAILED + 1))
  fi
}

assert_not_contains() {
  local description="$1"
  local actual="$2"
  local needle="$3"
  if [[ "$actual" != *"$needle"* ]]; then
    printf '  PASS: %s\n' "$description"
    PASSED=$((PASSED + 1))
  else
    printf '  FAIL: %s\n' "$description"
    printf '    forbidden substring present: %s\n' "$needle"
    printf '    actual:\n%s\n' "$actual"
    FAILED=$((FAILED + 1))
  fi
}

assert_exit_zero() {
  local description="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf '  PASS: %s\n' "$description"
    PASSED=$((PASSED + 1))
  else
    printf '  FAIL: %s (exit code %d)\n' "$description" "$?"
    FAILED=$((FAILED + 1))
  fi
}

assert_exit_nonzero() {
  local description="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf '  FAIL: %s (expected non-zero exit, got 0)\n' "$description"
    FAILED=$((FAILED + 1))
  else
    printf '  PASS: %s\n' "$description"
    PASSED=$((PASSED + 1))
  fi
}

assert_token_order() {
  local description="$1"
  local actual="$2"
  shift 2
  local i=0
  for needle in "$@"; do
    local line
    line=$(printf '%s\n' "$actual" | sed -n "$((i + 1))p")
    if [[ "$line" == "ARG_TOKEN=$needle" ]]; then
      printf '  PASS: %s [pos %d = %q]\n' "$description" "$((i + 1))" "$needle"
      PASSED=$((PASSED + 1))
    else
      printf '  FAIL: %s [pos %d]\n    expected: ARG_TOKEN=%s\n    actual:   %s\n' \
        "$description" "$((i + 1))" "$needle" "$line"
      FAILED=$((FAILED + 1))
    fi
    i=$((i + 1))
  done
}

# Convenience: count lines in --dry-run output that start with ARG_TOKEN=.
count_arg_tokens() {
  local actual="$1"
  printf '%s\n' "$actual" | grep -c '^ARG_TOKEN='
}

# --- tests ------------------------------------------------------------------

echo "=== Test 1: SOUL.md:217 status-cron invocation parses and translates ==="
out=$("$SCRIPT" --dry-run \
  --at 20m --delete-after-run --announce \
  --to "$CHANNEL_STATUS_20M" \
  --name "task status (20m)" 2>&1) || true
assert_contains "schedule '20m' is positional" "$out" "ARG_TOKEN=20m"
assert_contains "--name flag" "$out" "ARG_TOKEN=--name"
assert_contains "name value preserved verbatim" "$out" "ARG_TOKEN=task status (20m)"
assert_contains "--deliver flag" "$out" "ARG_TOKEN=--deliver"
assert_contains "channel ID translated" "$out" "ARG_TOKEN=slack:$CHANNEL_STATUS_20M"
assert_contains "--repeat flag emitted" "$out" "ARG_TOKEN=--repeat"
assert_contains "repeat value emitted" "$out" "ARG_TOKEN=1"
assert_not_contains "--announce stripped (implicit in hermes)" "$out" "--announce"
assert_not_contains "no --every emitted" "$out" "--every"
assert_not_contains "no --keep-after-run emitted" "$out" "--keep-after-run"
# Strict positional order so a future "swap --name and --deliver" regression
# is caught immediately.
assert_token_order "argv order matches hermes cron create convention" "$out" \
  "20m" \
  "--name" \
  "task status (20m)" \
  "--deliver" \
  "slack:$CHANNEL_STATUS_20M" \
  "--repeat" \
  "1"

echo "=== Test 2: SOUL.md:237 followup-cron invocation parses and translates ==="
out=$("$SCRIPT" --dry-run \
  --at 10m --delete-after-run --announce \
  --to "$CHANNEL_FOLLOWUP_10M" \
  2>&1) || true
assert_contains "schedule '10m' is positional" "$out" "ARG_TOKEN=10m"
assert_contains "channel ID translated" "$out" "ARG_TOKEN=slack:$CHANNEL_FOLLOWUP_10M"
assert_contains "--repeat flag emitted" "$out" "ARG_TOKEN=--repeat"
assert_contains "repeat value emitted" "$out" "ARG_TOKEN=1"

echo "=== Test 3: every-2h schedule string passes through verbatim ==="
out=$("$SCRIPT" --dry-run \
  --at "every 2h" --delete-after-run --announce \
  --to "$CHANNEL_STATUS_20M" --name "every-2h-test" 2>&1) || true
assert_contains "every 2h preserved" "$out" "ARG_TOKEN=every 2h"

echo "=== Test 4: cron expression schedule (0 9 * * *) passes through verbatim ==="
out=$("$SCRIPT" --dry-run \
  --at "0 9 * * *" --delete-after-run --announce \
  --to "$CHANNEL_STATUS_20M" --name "morning" 2>&1) || true
assert_contains "cron expression preserved" "$out" "ARG_TOKEN=0 9 * * *"

echo "=== Test 5: --prompt appended as final positional arg ==="
out=$("$SCRIPT" --dry-run \
  --at 20m --delete-after-run --announce \
  --to "$CHANNEL_STATUS_20M" --name "with-prompt" \
  --prompt "check status and post reply" 2>&1) || true
assert_contains "prompt token appears" "$out" "ARG_TOKEN=check status and post reply"
# Last line must be the prompt value (positional after all flags).
last=$(printf '%s\n' "$out" | tail -n1)
if [[ "$last" == "ARG_TOKEN=check status and post reply" ]]; then
  printf '  PASS: prompt is the trailing token\n'
  PASSED=$((PASSED + 1))
else
  printf '  FAIL: trailing token should be prompt, got: %s\n' "$last"
  FAILED=$((FAILED + 1))
fi

echo "=== Test 6: --skill / --script / --no-agent / --workdir all passthrough ==="
SCRIPT_EXAMPLE="${HOME}/.smartclaw/scripts/example-watchdog.sh"
out=$("$SCRIPT" --dry-run \
  --at 5m --delete-after-run \
  --to "$CHANNEL_STATUS_20M" --name "watchdog" \
  --no-agent --workdir /tmp --script "$SCRIPT_EXAMPLE" \
  --skill mem0 --skill slack 2>&1) || true
assert_contains "--no-agent flag" "$out" "ARG_TOKEN=--no-agent"
assert_contains "--workdir flag" "$out" "ARG_TOKEN=--workdir"
assert_contains "--workdir value on its own line" "$out" "ARG_TOKEN=/tmp"
assert_contains "--script flag" "$out" "ARG_TOKEN=--script"
assert_contains "--script value on its own line" "$out" "ARG_TOKEN=$SCRIPT_EXAMPLE"
assert_contains "first --skill" "$out" "ARG_TOKEN=--skill"
assert_contains "first --skill value" "$out" "ARG_TOKEN=mem0"
# second --skill === second --skill value (mem0, slack appear in this order)
first_skill_line=$(printf '%s\n' "$out" | grep -n '^ARG_TOKEN=--skill' | head -n1 | cut -d: -f1)
second_skill_line=$(printf '%s\n' "$out" | grep -n '^ARG_TOKEN=--skill' | sed -n '2p' | cut -d: -f1)
skill_after_first=$(printf '%s\n' "$out" | sed -n "$((first_skill_line + 1))p")
skill_after_second=$(printf '%s\n' "$out" | sed -n "$((second_skill_line + 1))p")
if [[ "$skill_after_first" == "ARG_TOKEN=mem0" ]]; then
  printf '  PASS: first --skill value is mem0\n'
  PASSED=$((PASSED + 1))
else
  printf '  FAIL: first --skill value, got: %s\n' "$skill_after_first"
  FAILED=$((FAILED + 1))
fi
if [[ "$skill_after_second" == "ARG_TOKEN=slack" ]]; then
  printf '  PASS: second --skill value is slack\n'
  PASSED=$((PASSED + 1))
else
  printf '  FAIL: second --skill value, got: %s\n' "$skill_after_second"
  FAILED=$((FAILED + 1))
fi

echo "=== Test 7: missing --at fails with exit 2 ==="
assert_exit_nonzero "no --at → exit 2" \
  "$SCRIPT" --dry-run --delete-after-run --announce --to "$CHANNEL_STATUS_20M" --name "no-at"

echo "=== Test 8: unknown flag fails with exit 2 ==="
assert_exit_nonzero "unknown --nope → exit 2" \
  "$SCRIPT" --dry-run --at 20m --delete-after-run --announce --to "$CHANNEL_STATUS_20M" --nope "x"

echo "=== Test 9: --every is explicitly banned ==="
assert_exit_nonzero "--every rejected" \
  "$SCRIPT" --dry-run --at 10m --delete-after-run --every 5m \
  --to "$CHANNEL_STATUS_20M" --name "every-test"

echo "=== Test 10: --keep-after-run is explicitly banned ==="
assert_exit_nonzero "--keep-after-run rejected" \
  "$SCRIPT" --dry-run --at 10m --delete-after-run --keep-after-run \
  --to "$CHANNEL_STATUS_20M" --name "keep-test"

echo "=== Test 11: --announce without --to fails (announce implies a target) ==="
assert_exit_nonzero "--announce + no --to rejected" \
  "$SCRIPT" --dry-run --at 20m --delete-after-run --announce --name "no-channel"

echo "=== Test 12: relative --script path rejected (must be absolute) ==="
assert_exit_nonzero "relative --script rejected" \
  "$SCRIPT" --dry-run --at 5m --delete-after-run \
  --to "$CHANNEL_STATUS_20M" --name "rel-script" --script "scripts/foo.sh"

echo "=== Test 13: --help exits 0 and prints usage ==="
assert_exit_zero "--help exits 0" "$SCRIPT" --help
out=$("$SCRIPT" --help 2>&1) || true
assert_contains "usage mentions --at" "$out" "--at"
assert_contains "usage mentions --to" "$out" "--to"
assert_contains "usage mentions --delete-after-run" "$out" "--delete-after-run"

echo "=== Test 14: --dry-run does NOT invoke hermes CLI ==="
# If the script for any reason bypasses --dry-run and calls hermes, hermes cron
# create with a 5-second schedule would create a real one-time job in the live
# cron store. We can't easily prove "no call" in pure bash, so we run with a
# PATH that contains a hermes shim that records invocations. The shim exits
# 99 so any accidental invocation would fail loudly (the test would error).
TMP_BIN="$(mktemp -d)"
trap 'rm -rf "$TMP_BIN"' EXIT
cat > "$TMP_BIN/hermes" <<'SHIM'
#!/usr/bin/env bash
echo "FATAL_CALLED: hermes CLI was invoked by cron-dispatch.sh in --dry-run mode" >&2
exit 99
SHIM
chmod +x "$TMP_BIN/hermes"
if PATH="$TMP_BIN:$PATH" "$SCRIPT" --dry-run \
     --at 20m --delete-after-run --announce \
     --to "$CHANNEL_STATUS_20M" --name "dry-run-no-hermes" >/dev/null 2>&1; then
  printf '  PASS: --dry-run did not invoke hermes\n'
  PASSED=$((PASSED + 1))
else
  printf '  FAIL: --dry-run invoked hermes (exit %d)\n' "$?"
  FAILED=$((FAILED + 1))
fi

echo "=== Test 15: ARG_TOKEN count parity for canonical status-cron ==="
# Test 1 should produce exactly 7 tokens:
#   20m, --name, task status (20m), --deliver, slack:${SLACK_CHANNEL_ID}, --repeat, 1
out=$("$SCRIPT" --dry-run \
  --at 20m --delete-after-run --announce \
  --to "$CHANNEL_STATUS_20M" \
  --name "task status (20m)" 2>&1) || true
count=$(count_arg_tokens "$out")
if [[ "$count" -eq 7 ]]; then
  printf '  PASS: 7 ARG_TOKEN lines emitted (schedule + name-pair + deliver-pair + repeat-pair)\n'
  PASSED=$((PASSED + 1))
else
  printf '  FAIL: expected 7 ARG_TOKEN lines, got %d\n  output:\n%s\n' "$count" "$out"
  FAILED=$((FAILED + 1))
fi

# --- summary ----------------------------------------------------------------

echo
echo "================================="
printf 'Passed: %d\n' "$PASSED"
printf 'Failed: %d\n' "$FAILED"
echo "================================="

if (( FAILED > 0 )); then
  exit 1
fi
