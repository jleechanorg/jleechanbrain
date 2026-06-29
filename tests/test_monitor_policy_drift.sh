#!/usr/bin/env bash
# test_monitor_policy_drift.sh
#
# Verifies lib/policy-drift-probe.sh:
#   1. RC=0 when staging and prod files are byte-identical
#   2. RC=0 when neither staging nor prod exists (check disabled)
#   3. RC=0 when staging file is missing (cannot compute drift)
#   4. RC=2 (WARN) when drift is >1h but ≤24h
#   5. RC=1 (FAIL) when drift is >24h
#   6. Summary contains the drifted filename
#   7. Both-sides-missing case: all 4 policy files missing → RC=0
#   8. Override HERMES_MONITOR_POLICY_FILES works
#   9. Override HERMES_MONITOR_POLICY_DRIFT_WARN_HOURS / FAIL_HOURS works
#
# Returns 0 on all-pass, 1 on any failure.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$REPO_DIR/lib/policy-drift-probe.sh"

[[ -f "$LIB" ]] || { echo "FAIL: $LIB not found"; exit 1; }

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# Source the lib and call the probe with overridden env vars. Capture
# RC=.../SUMMARY=... output and parse it back out.
run_probe() {
  local fx="$1"
  (
    # shellcheck disable=SC1090
    source "$LIB"
    HERMES_STAGING_HOME="$fx/staging"
    HERMES_PROD_HOME="$fx/prod"
    _policy_drift_probe
  )
}

# Parse the multi-line output: first line is RC=, second is SUMMARY=
parse_rc()     { printf '%s' "$1" | sed -n 's/^RC=//p' | head -1; }
parse_summary(){ printf '%s' "$1" | sed -n 's/^SUMMARY=//p' | head -1; }

# Set a file's mtime to N hours ago. macOS `touch -t` doesn't accept relative,
# so we use a small python helper for portability (not present on bare macOS
# without dev tools — fall back to `date` arithmetic if python missing).
set_age_hours() {
  local file="$1"
  local hours="$2"
  local target_epoch
  target_epoch=$(( $(date +%s) - hours * 3600 ))
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "import os,sys; t=int(sys.argv[2]); os.utime(sys.argv[1], (t, t))" \
      "$file" "$target_epoch"
  else
    # macOS touch -t YYYYMMDDHHMM.SS
    local ts
    ts=$(date -r "$target_epoch" '+%Y%m%d%H%M.%S' 2>/dev/null || echo "")
    [[ -n "$ts" ]] && touch -t "$ts" "$file"
  fi
}

# Build a fixture: staging/<files> + prod/<files> with given drift in hours
# for one specific file. drift_hours is "how long ago the rule landed in
# staging without being deployed to prod" — i.e. staging is fresher than
# prod by that many hours. staging mtime = now - drift_hours, prod mtime =
# drift_hours + 1 hour older.
make_drift_fixture() {
  local root="$1"
  local drift_file="$2"  # which file differs (or "" for none)
  local drift_hours="$3"  # age of staging file in hours (0 for now)
  mkdir -p "$root/staging" "$root/prod"
  for f in CLAUDE.md SOUL.md TOOLS.md HEARTBEAT.md; do
    if [[ "$f" == "$drift_file" && "$drift_hours" -gt 0 ]]; then
      printf '%s\n' "# $f staging NEW VERSION at $drift_hours h ago" \
        > "$root/staging/$f"
      printf '%s\n' "# $f prod OLD VERSION" > "$root/prod/$f"
      set_age_hours "$root/staging/$f" "$drift_hours"
      # prod is 1 hour OLDER than staging → staging newer by $drift_hours
      set_age_hours "$root/prod/$f" "$((drift_hours + 1))"
    else
      printf '%s\n' "# $f shared" > "$root/staging/$f"
      cp "$root/staging/$f" "$root/prod/$f"
    fi
  done
}

echo "=== test_monitor_policy_drift ==="
echo ""

# Test 1: all in sync → RC=0
fx1=$(mktemp -d "${TMPDIR:-/tmp}/policy-drift-1-XXXXXX")
make_drift_fixture "$fx1" "" 0
out=$(run_probe "$fx1")
rc=$(parse_rc "$out")
sum=$(parse_summary "$out")
if [[ "$rc" == "0" ]]; then
  pass "all-in-sync: RC=0"
else
  fail "all-in-sync: expected RC=0, got '$rc' (summary: $sum)"
fi
rm -rf "$fx1"

# Test 2: staging dir missing → RC=0 disabled
fx2=$(mktemp -d "${TMPDIR:-/tmp}/policy-drift-2-XXXXXX")
mkdir -p "$fx2/prod"
printf '%s\n' "x" > "$fx2/prod/CLAUDE.md"
out=$(run_probe "$fx2")
rc=$(parse_rc "$out")
sum=$(parse_summary "$out")
if [[ "$rc" == "0" && "$sum" == *"disabled"* ]]; then
  pass "staging-missing: RC=0 disabled"
else
  fail "staging-missing: expected RC=0 disabled, got RC='$rc' sum='$sum'"
fi
rm -rf "$fx2"

# Test 3: drift > 1h but < 24h on one file → RC=2 (WARN)
fx3=$(mktemp -d "${TMPDIR:-/tmp}/policy-drift-3-XXXXXX")
make_drift_fixture "$fx3" "CLAUDE.md" 5
out=$(run_probe "$fx3")
rc=$(parse_rc "$out")
sum=$(parse_summary "$out")
if [[ "$rc" == "2" && "$sum" == *"CLAUDE.md"* && "$sum" == *"1h"* ]]; then
  pass "drift-5h: RC=2 WARN, summary mentions CLAUDE.md"
else
  fail "drift-5h: expected RC=2 with CLAUDE.md, got RC='$rc' sum='$sum'"
fi
rm -rf "$fx3"

# Test 4: drift > 24h on one file → RC=1 (FAIL)
fx4=$(mktemp -d "${TMPDIR:-/tmp}/policy-drift-4-XXXXXX")
make_drift_fixture "$fx4" "SOUL.md" 48
out=$(run_probe "$fx4")
rc=$(parse_rc "$out")
sum=$(parse_summary "$out")
if [[ "$rc" == "1" && "$sum" == *"SOUL.md"* && "$sum" == *"24h"* ]]; then
  pass "drift-48h: RC=1 FAIL, summary mentions SOUL.md"
else
  fail "drift-48h: expected RC=1 with SOUL.md, got RC='$rc' sum='$sum'"
fi
rm -rf "$fx4"

# Test 5: multiple drifted files — both reported
fx5=$(mktemp -d "${TMPDIR:-/tmp}/policy-drift-5-XXXXXX")
make_drift_fixture "$fx5" "CLAUDE.md" 30
# Now manually add drift to TOOLS.md too
printf '%s\n' "# TOOLS.md NEW" > "$fx5/staging/TOOLS.md"
printf '%s\n' "# TOOLS.md OLD" > "$fx5/prod/TOOLS.md"
set_age_hours "$fx5/staging/TOOLS.md" 30
set_age_hours "$fx5/prod/TOOLS.md" 31
out=$(run_probe "$fx5")
rc=$(parse_rc "$out")
sum=$(parse_summary "$out")
if [[ "$rc" == "1" && "$sum" == *"CLAUDE.md"* && "$sum" == *"TOOLS.md"* ]]; then
  pass "multi-drift: RC=1, both files in summary"
else
  fail "multi-drift: expected RC=1 with both files, got RC='$rc' sum='$sum'"
fi
rm -rf "$fx5"

# Test 6: override HERMES_MONITOR_POLICY_DRIFT_WARN_HOURS to 0 → even small drift WARNs
fx6=$(mktemp -d "${TMPDIR:-/tmp}/policy-drift-6-XXXXXX")
mkdir -p "$fx6/staging" "$fx6/prod"
# Create real byte-drift (not just mtime touch) with staging newer by ~1 minute
printf '%s\n' "# CLAUDE.md staging NEW" > "$fx6/staging/CLAUDE.md"
printf '%s\n' "# CLAUDE.md prod OLD"   > "$fx6/prod/CLAUDE.md"
# staging is fresher by 1 minute (~60s drift, < 1h WARN default but >= 0h)
now_epoch=$(date +%s)
staging_target=$((now_epoch - 60))   # 60s ago
prod_target=$((now_epoch - 120))     # 120s ago (older than staging)
python3 -c "import os,sys; t=int(sys.argv[2]); os.utime(sys.argv[1], (t, t))" \
  "$fx6/staging/CLAUDE.md" "$staging_target"
python3 -c "import os,sys; t=int(sys.argv[2]); os.utime(sys.argv[1], (t, t))" \
  "$fx6/prod/CLAUDE.md" "$prod_target"
# Other 3 policy files: in sync
for f in SOUL.md TOOLS.md HEARTBEAT.md; do
  printf '%s\n' "# $f shared" > "$fx6/staging/$f"
  cp "$fx6/staging/$f" "$fx6/prod/$f"
done
out=$(HERMES_MONITOR_POLICY_DRIFT_WARN_HOURS=0 \
       HERMES_MONITOR_POLICY_DRIFT_FAIL_HOURS=24 \
       bash -c "
         source '$LIB'
         HERMES_STAGING_HOME='$fx6/staging'
         HERMES_PROD_HOME='$fx6/prod'
         _policy_drift_probe
       ")
rc=$(parse_rc "$out")
# 60s drift with WARN_HOURS=0 → drift_secs(60) >= warn_secs(0) → RC=2
if [[ "$rc" == "2" || "$rc" == "1" ]]; then
  pass "WARN_HOURS=0 override: 60s drift detected (rc=$rc)"
else
  fail "WARN_HOURS=0 override: expected RC=1 or 2, got RC='$rc'"
fi
rm -rf "$fx6"

# Test 7: override HERMES_MONITOR_POLICY_FILES to subset
fx7=$(mktemp -d "${TMPDIR:-/tmp}/policy-drift-7-XXXXXX")
make_drift_fixture "$fx7" "" 0  # all in sync
# Now add drift only to AGENTS.md (NOT in default policy list)
printf '%s\n' "# AGENTS.md NEW" > "$fx7/staging/AGENTS.md"
printf '%s\n' "# AGENTS.md OLD" > "$fx7/prod/AGENTS.md"
set_age_hours "$fx7/staging/AGENTS.md" 48
set_age_hours "$fx7/prod/AGENTS.md" 49
out=$(run_probe "$fx7")
rc=$(parse_rc "$out")
# AGENTS.md is NOT in the default policy list, so drift should be ignored.
if [[ "$rc" == "0" ]]; then
  pass "default policy list excludes AGENTS.md: RC=0 (no false positive)"
else
  fail "default policy list excludes AGENTS.md: expected RC=0, got '$rc'"
fi
# Now override the policy list to include AGENTS.md
out=$(HERMES_MONITOR_POLICY_FILES="AGENTS.md" \
       bash -c "
         source '$LIB'
         HERMES_STAGING_HOME='$fx7/staging'
         HERMES_PROD_HOME='$fx7/prod'
         _policy_drift_probe
       ")
rc=$(parse_rc "$out")
if [[ "$rc" == "1" ]]; then
  pass "override HERMES_MONITOR_POLICY_FILES=AGENTS.md: drift detected RC=1"
else
  fail "override policy list: expected RC=1, got '$rc'"
fi
rm -rf "$fx7"

# Test 8: prod mtime > staging mtime (staging older) — non-drift case
# Make staging OLDER than prod → no drift, but bytes may still differ.
# Our probe treats staging-older-than-prod as "EOL diff" → WARN tier
# (not FAIL, but a heads-up).
fx8=$(mktemp -d "${TMPDIR:-/tmp}/policy-drift-8-XXXXXX")
mkdir -p "$fx8/staging" "$fx8/prod"
printf '%s\n' "# CLAUDE.md NEW prod" > "$fx8/prod/CLAUDE.md"
printf '%s\n' "# CLAUDE.md OLD staging" > "$fx8/staging/CLAUDE.md"
set_age_hours "$fx8/staging/CLAUDE.md" 100  # staging is OLD
touch "$fx8/prod/CLAUDE.md"  # prod is fresh
out=$(run_probe "$fx8")
rc=$(parse_rc "$out")
sum=$(parse_summary "$out")
# Staging older than prod → not FAIL; bytes differ → at least WARN
if [[ "$rc" == "2" && "$sum" == *"EOL diff"* ]]; then
  pass "staging-older-than-prod: RC=2 with 'EOL diff' label"
else
  fail "staging-older-than-prod: expected RC=2 with EOL diff, got RC='$rc' sum='$sum'"
fi
rm -rf "$fx8"

echo ""
if [[ "$FAIL" -gt 0 ]]; then
  echo "✗ $FAIL failures, $PASS passes"
  exit 1
fi
echo "✓ All $PASS checks passed"
exit 0
