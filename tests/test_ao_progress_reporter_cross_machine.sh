#!/usr/bin/env bash
# test_ao_progress_reporter_cross_machine.sh
#
# Verifies the cross-machine AO state plumbing added to ao-progress-reporter.sh.
# On 2026-08-05: daily report must surface BOTH ~/.ao/data/ao.db on the Mac
# AND /linux (default SSH host: jeff-ubuntu) with explicit staleness escalation.
# On 2026-08-13: switched stale-detection signal from db-file mtime alone to a
# live /healthz daemon probe PLUS a true activity/freshness contract
# (linux_max_activity_h — hours since most-recent session.activity_last_at).
# A healthy-but-idle daemon (no recent worker activity) is normal operation,
# not a stuck write — must NOT emit a false "Xh stale" warning.
# On 2026-08-18: /linux is the primary AO daemon — Mac AO is not expected
# to be running. The Mac-down probe is preserved for diagnostics but its
# warning line is downgraded to silent (empty). Only Linux-side failures
# surface (true stuck write / SSH unreachable / Mac-side fallback).
#
# Strategy: source the script with IS_SOURCED=1, build a synthetic mac db,
# stub `ssh` and `curl` via PATH override, and exercise:
#   - healthy linux (daemon up, busy, db fresh) → silent (no header, no alert)
#   - TRUE stuck write (daemon up + busy + db stale > threshold) → stale line
#   - HEALTHY idle (daemon up, idle, db stale — the false-positive case) → silent
#   - worker ended within stale window (last activity just past threshold, db
#     same age) → silent (the exact bug that originally produced 384h warnings)
#   - Mac daemon DOWN → SILENT (Mac AO is not expected to run; /linux is primary)
#   - Mac daemon DOWN + linux TRUE stuck → only linux stale line
#   - Linux unreachable (SSH down) → fallback note
#   - format_cross_machine_block end-to-end with full real-data shape
#
# Reference incident: Slack C0ALSKLU9KM ts=1785914189.566169 (2026-08-05) —
# daily reports were lying because they never queried /linux.
# Reference bug fix:   Slack C0ALSKLU9KM ts=1786604836.495059 (2026-08-13) —
# the 2026-08-05 fix emitted false-positive stale warnings every 30 min for a
# week because db mtime is not a stuck-write signal when the daemon is healthy
# but simply idle. Replaced with a daemon-/healthz probe + max_activity_h
# activity gate.
# Followup 2026-08-18: Mac AO is intentionally not run on this Mac
# (/linux is the primary AO daemon); the Mac-down warning is downgraded to
# a silent diagnostic and only real Linux-side failures surface.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$(cd "$HERE/../scripts" && pwd)"
SCRIPT="$SCRIPT_DIR/ao-progress-reporter.sh"

if [[ ! -x "$SCRIPT" ]]; then
  echo "FAIL: $SCRIPT missing or not executable"
  exit 1
fi

PASS=0
FAIL=0

assert_eq() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    expected: $expected"
    echo "    actual:   $actual"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    needle:  $needle"
    echo "    haystack (head 200): ${haystack:0:200}"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    needle:  $needle (should NOT appear)"
    echo "    haystack (head 200): ${haystack:0:200}"
    FAIL=$((FAIL + 1))
  fi
}

# ── Test 1: function is defined and sourceable ────────────────────────────────
echo "== Test 1: script sources with IS_SOURCED=1 =="
if IS_SOURCED=1 GH_TOKEN=dummy bash -c "source '$SCRIPT'; declare -F fetch_cross_machine_ao_state >/dev/null" 2>/dev/null; then
  echo "  PASS: fetch_cross_machine_ao_state is defined"
  PASS=$((PASS + 1))
else
  echo "  FAIL: fetch_cross_machine_ao_state is NOT defined (script broken)"
  FAIL=$((FAIL + 1))
fi

if IS_SOURCED=1 GH_TOKEN=dummy bash -c "source '$SCRIPT'; declare -F format_cross_machine_block >/dev/null" 2>/dev/null; then
  echo "  PASS: format_cross_machine_block is defined"
  PASS=$((PASS + 1))
else
  echo "  FAIL: format_cross_machine_block is NOT defined"
  FAIL=$((FAIL + 1))
fi

# Stub-ssh helper. Writes a fake ssh to $STUB_BIN that:
#   - returns success on the connectivity probe (arg == "true")
#   - returns "up" or "down" on the /healthz probe (looks for "echo up")
#   - emits the configurable linux_row on the db query
# Args:
#   $1 STUB_BIN     path to bin dir (will write $STUB_BIN/ssh)
#   $2 LINUX_ROW    "open|green|workers|workers24h|max_activity_h|age_h"
#                   (empty → unreachable)
#   $3 LINUX_DAEMON  "up" or "down" — what the fake healthz returns
write_stub_ssh() {
  local stub_bin="$1" linux_row="$2" linux_daemon="$3"
  cat > "$stub_bin/ssh" <<STUB
#!/usr/bin/env bash
LINUX_ROW='$linux_row'
LINUX_DAEMON='$linux_daemon'
# Connectivity probe: `ssh host "true"` → exit success.
for arg in "\$@"; do
  if [[ "\$arg" == "true" ]]; then exit 0; fi
done
# /healthz probe: `ssh host "curl ... | grep ... && echo up || echo down"`
# We only need to look for the trigger "echo up" in the command string.
if [[ "\$*" == *"echo up"* ]]; then
  if [[ "\$LINUX_DAEMON" == "up" ]]; then echo up; else echo down; fi
  exit 0
fi
# Main cross-machine SQLite query (looks for the SELECT keyword).
if [[ "\$*" == *"pr_state='open'"* ]]; then
  if [[ "\$LINUX_ROW" == "" ]]; then exit 1; fi
  echo "\$LINUX_ROW"
  exit 0
fi
# Default: simulate unreachable by exiting non-zero
exit 1
STUB
  chmod +x "$stub_bin/ssh"
}

# Stub-curl helper. Writes a fake curl to $STUB_BIN that:
#   - returns '{"status":"ok"}' when MAC_DAEMON=up (Mac probe success)
#   - returns empty + exits non-zero when MAC_DAEMON=down (probe failure)
# Args:
#   $1 STUB_BIN    path to bin dir
#   $2 MAC_DAEMON  "up" or "down" — what the fake local healthz returns
write_stub_curl() {
  local stub_bin="$1" mac_daemon="$2"
  cat > "$stub_bin/curl" <<STUB
#!/usr/bin/env bash
MAC_DAEMON='$mac_daemon'
# We only respond to the Mac /healthz probe path.
if [[ "\$*" == *"/healthz"* ]]; then
  if [[ "\$MAC_DAEMON" == "up" ]]; then
    echo '{"status":"ok"}'
    exit 0
  else
    exit 22  # curl's "HTTP error" code — silent fail in -fsS mode
  fi
fi
exit 1
STUB
  chmod +x "$stub_bin/curl"
}

# ── Setup shared tmpdir + stub bin ────────────────────────────────────────────
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
STUB_BIN="$TMPDIR/bin"
mkdir -p "$STUB_BIN"

# Build a minimal ao.db with the columns the script reads
MAC_DB="$TMPDIR/mac_ao.db"
sqlite3 "$MAC_DB" "CREATE TABLE pr (pr_state TEXT, ci_state TEXT, mergeability TEXT, review_decision TEXT);
INSERT INTO pr VALUES ('open','success','mergeable','APPROVED');
INSERT INTO pr VALUES ('open','success','mergeable','APPROVED');
INSERT INTO pr VALUES ('open','success','mergeable','none');
INSERT INTO pr VALUES ('open','failing','blocked','none');
CREATE TABLE sessions (kind TEXT, activity_last_at TEXT);
INSERT INTO sessions VALUES ('worker', datetime('now','-2 hour'));
INSERT INTO sessions VALUES ('worker', datetime('now','-30 minutes'));
INSERT INTO sessions VALUES ('worker', datetime('now','-3 days'));
INSERT INTO sessions VALUES ('orchestrator', datetime('now','-1 hour'));" >/dev/null

# Helper: run fetch_cross_machine_ao_state against the stubs.
# Args: $1 linux_row (6 pipe-separated numbers), $2 linux_daemon up/down,
#       $3 mac_daemon up/down
fetch_state() {
  local linux_row="$1" linux_daemon="$2" mac_daemon="$3"
  write_stub_ssh "$STUB_BIN" "$linux_row" "$linux_daemon"
  write_stub_curl "$STUB_BIN" "$mac_daemon"
  HOME="$TMPDIR" IS_SOURCED=1 GH_TOKEN=dummy AO_DIR_DB="$MAC_DB" \
    PATH="$STUB_BIN:/usr/bin:/bin" AOPR_LINUX_SSH_HOST=stub-linux \
    bash -c "source '$SCRIPT'; fetch_cross_machine_ao_state"
}

# Helper: format the cross-machine block from a JSON state string.
format_block() {
  local state_json="$1"
  HOME="$TMPDIR" IS_SOURCED=1 GH_TOKEN=dummy \
    PATH="$STUB_BIN:/usr/bin:/bin" \
    bash -c "source '$SCRIPT'; format_cross_machine_block '$state_json'"
}

# ── Test 2: healthy linux (daemon up, busy, db fresh) → header only ───────────
echo
echo "== Test 2: healthy linux (daemon up, busy, db fresh) =="
# row: open=5, green=1, workers=7, workers24h=2, max_activity_h=0, age_h=0
OUT="$(fetch_state '5|1|7|2|0|0' up up)"
echo "  output: $OUT"
assert_contains "mac.open_prs parsed"             "$OUT" '"open_prs":4'
assert_contains "mac.green_prs parsed"            "$OUT" '"green_prs":2'
assert_contains "mac.worker_sessions_24h parsed"  "$OUT" '"worker_sessions_24h":2'
assert_contains "linux.open_prs parsed"           "$OUT" '"open_prs":5'
assert_contains "stale_threshold_h honored"       "$OUT" '"stale_threshold_h":6'
assert_contains "linux_db_stale_h present (0)"   "$OUT" '"linux_db_stale_h":0'
assert_contains "mac_daemon_up=true"              "$OUT" '"mac_daemon_up":true'
assert_contains "linux_daemon_up=true"            "$OUT" '"linux_daemon_up":true'
assert_contains "linux_max_activity_h present"    "$OUT" '"linux_max_activity_h":0'

# ── Test 3: TRUE stuck write (daemon up + busy + db stale) → stale line ──────
echo
echo "== Test 3: TRUE stuck write (daemon up, recent activity, db stale) =="
# row: open=2, green=0, workers=3, workers24h=1, max_activity_h=0 (busy now),
# age_h=24 (db mtime 24h old)
OUT="$(fetch_state '2|0|3|1|0|24' up up)"
echo "  output: $OUT"
assert_contains "true stuck: linux_db_stale_h=24"  "$OUT" '"linux_db_stale_h":24'
assert_contains "true stuck: max_activity_h=0"     "$OUT" '"linux_max_activity_h":0'
BLOCK="$(format_block "$OUT")"
echo "  block:"
echo "$BLOCK" | sed 's/^/    /'
assert_contains "true stuck: stale warning emitted"  "$BLOCK" "24h stale"
assert_contains "true stuck: warning names recent activity" "$BLOCK" "most-recent activity"
assert_not_contains "true stuck: NO mac DOWN line (mac is up)" "$BLOCK" "Mac AO daemon is DOWN"
assert_not_contains "true stuck: NO unreachable fallback"      "$BLOCK" "Linux side unreachable"

# ── Test 4: HEALTHY IDLE (daemon up, no recent activity, db old) → silent ────
echo
echo "== Test 4: HEALTHY IDLE (daemon up, no recent activity, db stale) → silent =="
# THE FALSE-POSITIVE SCENARIO: db is 24h old, but the most recent session
# activity was 30h ago — so nothing SHOULD be writing. The old logic
# (db-stale-only) fired here; the new max_activity_h gate must silence it.
# 2026-08-18 spec: healthy idle MUST be silent — no header, no block at all.
OUT="$(fetch_state '5|1|7|0|30|24' up up)"
echo "  output: $OUT"
assert_contains "healthy idle: linux_db_stale_h=24"  "$OUT" '"linux_db_stale_h":24'
assert_contains "healthy idle: max_activity_h=30"    "$OUT" '"linux_max_activity_h":30'
BLOCK="$(format_block "$OUT")"
echo "  block: '$BLOCK'"
assert_eq "healthy idle: SILENT (no block, no header)" "$BLOCK" ""
assert_not_contains "healthy idle: NO stale warning (the bug we're fixing)" "$BLOCK" "h stale"
assert_not_contains "healthy idle: NO Mac DOWN line (mac is up)" "$BLOCK" "Mac AO daemon is DOWN"
assert_not_contains "healthy idle: NO unreachable fallback"      "$BLOCK" "Linux side unreachable"

# ── Test 5: WORKER ENDED WITHIN STALE WINDOW → silent ────────────────────────
echo
echo "== Test 5: WORKER ENDED within stale window (exact bug repro) =="
# Exact bug scenario: a worker ran and finished 7h ago (max_activity_h=7),
# threshold is 6, db is 7h old (age_h=7). The OLD worker_sessions_24h OR
# open_prs gate would fire here because open_prs=5 is still >0. The NEW
# max_activity_h gate (7 > 6) must silence it. Per the 2026-08-18 spec
# "Healthy idle must be silent (no cross-machine block at all), including
# a worker that ended 7h ago with a 7h-old DB and open PRs still present",
# the BLOCK must be the empty string — no header, no alert line.
OUT="$(fetch_state '5|1|7|0|7|7' up up)"
echo "  output: $OUT"
assert_contains "worker ended: linux_db_stale_h=7" "$OUT" '"linux_db_stale_h":7'
assert_contains "worker ended: max_activity_h=7"   "$OUT" '"linux_max_activity_h":7'
BLOCK="$(format_block "$OUT")"
echo "  block: '$BLOCK'"
assert_eq "worker ended: SILENT (7h-old worker + 7h-old DB + open PRs present)" "$BLOCK" ""
assert_not_contains "worker ended: NO stale warning (last activity > threshold)" "$BLOCK" "h stale"
assert_not_contains "worker ended: NO Mac DOWN line" "$BLOCK" "Mac AO daemon is DOWN"
assert_not_contains "worker ended: NO unreachable fallback" "$BLOCK" "Linux side unreachable"

# ── Test 6: MAC DAEMON DOWN → 🚨 line, no stale warning ──────────────────────
echo
echo "== Test 6: MAC DAEMON DOWN — silent (Mac AO not expected to run) =="
# 2026-08-18: /linux is the primary AO daemon; Mac-down is silent.
# Mac /healthz is dead (PID 19125 case). Linux is healthy and idle.
OUT="$(fetch_state '5|1|7|2|0|0' up down)"
echo "  output: $OUT"
assert_contains "mac down: mac_daemon_up=false" "$OUT" '"mac_daemon_up":false'
assert_contains "mac down: linux_daemon_up=true" "$OUT" '"linux_daemon_up":true'
BLOCK="$(format_block "$OUT")"
echo "  block: '$BLOCK'"
assert_eq "mac down: SILENT (Mac-down is not surfaced as a warning)" "$BLOCK" ""
assert_not_contains "mac down: no mac warning line" "$BLOCK" "Mac AO daemon is DOWN"
assert_not_contains "mac down: no stale warning (db fresh)" "$BLOCK" "h stale"
assert_not_contains "mac down: no unreachable fallback (linux reachable)" "$BLOCK" "Linux side unreachable"

# ── Test 7: MAC DAEMON DOWN + linux also stuck → both lines emitted ──────────
echo
echo "== Test 7: MAC DAEMON DOWN + linux TRUE stuck → only linux stale line =="
# Mac-down is silent, only the linux true-stuck line surfaces.
OUT="$(fetch_state '2|0|3|1|0|24' up down)"
BLOCK="$(format_block "$OUT")"
echo "  block:"
echo "$BLOCK" | sed 's/^/    /'
assert_not_contains "mac+linux stuck: NO mac DOWN line (mac-down is silent)" "$BLOCK" "Mac AO daemon is DOWN"
assert_contains "mac+linux stuck: linux stale line emitted" "$BLOCK" "24h stale"

# ── Test 8: Linux unreachable (SSH down) → fallback note ──────────────────────
echo
echo "== Test 8: LINUX UNREACHABLE → fallback note =="
# Make the connectivity probe fail so the linux branch is skipped.
write_stub_ssh "$STUB_BIN" "" "down"
write_stub_curl "$STUB_BIN" "up"
OUT="$(HOME="$TMPDIR" IS_SOURCED=1 GH_TOKEN=dummy AO_DIR_DB="$MAC_DB" PATH="$STUB_BIN:/usr/bin:/bin" AOPR_LINUX_SSH_HOST=stub-linux bash -c "source '$SCRIPT'; fetch_cross_machine_ao_state")"
echo "  output: $OUT"
BLOCK="$(format_block "$OUT")"
echo "  block:"
echo "$BLOCK" | sed 's/^/    /'
assert_contains "linux unreach: linux=null in JSON" "$OUT" '"linux":null'
assert_contains "linux unreach: falls back to mac-only" "$BLOCK" "Linux side unreachable"
assert_not_contains "linux unreach: NO stale warning (no linux data)" "$BLOCK" "h stale"

# ── Test 9: format_cross_machine_block end-to-end with full real shape ────────
echo
echo "== Test 9: format_cross_machine_block against full real-data shape =="
# Healthy busy linux (recent activity, fresh db within threshold) → silent
# 2026-08-18 spec: block is emitted ONLY for drift/daemon-down/true-stuck.
# A healthy busy state (db_stale_h=2 < threshold=6) is no-alert → silent.
FULL_HEALTHY='{"mac":{"open_prs":28,"green_prs":0,"worker_sessions":306,"worker_sessions_24h":11},"mac_daemon_up":true,"linux":{"open_prs":0,"green_prs":0,"worker_sessions":31,"worker_sessions_24h":0},"linux_daemon_up":true,"linux_db_stale_h":2,"linux_max_activity_h":1,"stale_threshold_h":6}'
BLOCK_H="$(format_block "$FULL_HEALTHY")"
echo "  healthy block: '$BLOCK_H'"
assert_eq "healthy: SILENT (no block when db is fresh and daemon is up)" "$BLOCK_H" ""
if [[ "$BLOCK_H" == *"h stale"* ]]; then
  echo "  FAIL: healthy: stale line leaked into fresh-db block"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: healthy: NO stale line when daemon is up and recent activity"
  PASS=$((PASS + 1))
fi

# Healthy idle: db is old AND no recent activity → silent (the regression case)
FULL_IDLE='{"mac":{"open_prs":28,"green_prs":0,"worker_sessions":306,"worker_sessions_24h":11},"mac_daemon_up":true,"linux":{"open_prs":0,"green_prs":0,"worker_sessions":31,"worker_sessions_24h":0},"linux_daemon_up":true,"linux_db_stale_h":180,"linux_max_activity_h":200,"stale_threshold_h":6}'
BLOCK_I="$(format_block "$FULL_IDLE")"
echo "  idle block: '$BLOCK_I'"
assert_eq "idle: SILENT (no block at all, even with 180h stale + 200h activity)" "$BLOCK_I" ""
assert_not_contains "idle: NO stale warning (no recent activity)" "$BLOCK_I" "h stale"

# No-sessions case: linux_max_activity_h = -1 → silent (no sessions to be stuck)
FULL_NO_SESS='{"mac":{"open_prs":28,"green_prs":0,"worker_sessions":306,"worker_sessions_24h":11},"mac_daemon_up":true,"linux":{"open_prs":0,"green_prs":0,"worker_sessions":0,"worker_sessions_24h":0},"linux_daemon_up":true,"linux_db_stale_h":180,"linux_max_activity_h":-1,"stale_threshold_h":6}'
BLOCK_N="$(format_block "$FULL_NO_SESS")"
echo "  no-sessions block: '$BLOCK_N'"
assert_eq "no-sessions: SILENT (-1 max_activity means no sessions to track)" "$BLOCK_N" ""
assert_not_contains "no-sessions: NO stale warning" "$BLOCK_N" "h stale"

# True stuck: daemon up + busy + db stale → warning
FULL_STUCK='{"mac":{"open_prs":28,"green_prs":0,"worker_sessions":306,"worker_sessions_24h":11},"mac_daemon_up":true,"linux":{"open_prs":0,"green_prs":0,"worker_sessions":31,"worker_sessions_24h":0},"linux_daemon_up":true,"linux_db_stale_h":180,"linux_max_activity_h":1,"stale_threshold_h":6}'
BLOCK_S="$(format_block "$FULL_STUCK")"
echo "  stuck block:"
echo "$BLOCK_S" | sed 's/^/    /'
assert_contains "stuck: surfaces warning" "$BLOCK_S" "180h stale"

# Mac daemon down — silent on Mac line, but Linux true-stuck STILL surfaces.
# (Linux side is independently degraded here, so its alert is the right thing to ship.)
FULL_MAC_DOWN='{"mac":{"open_prs":28,"green_prs":0,"worker_sessions":306,"worker_sessions_24h":11},"mac_daemon_up":false,"linux":{"open_prs":0,"green_prs":0,"worker_sessions":31,"worker_sessions_24h":0},"linux_daemon_up":true,"linux_db_stale_h":180,"linux_max_activity_h":1,"stale_threshold_h":6}'
BLOCK_M="$(format_block "$FULL_MAC_DOWN")"
echo "  mac-down block:"
echo "$BLOCK_M" | sed 's/^/    /'
assert_not_contains "mac-down: no mac line" "$BLOCK_M" "Mac AO daemon is DOWN"
assert_contains "mac-down+stuck: linux stale line still surfaces" "$BLOCK_M" "180h stale"

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "==== Cross-machine reporter tests: PASS=$PASS FAIL=$FAIL ===="
[[ $FAIL -eq 0 ]] || exit 1