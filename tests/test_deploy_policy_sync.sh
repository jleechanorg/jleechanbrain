#!/usr/bin/env bash
# test_deploy_policy_sync.sh
#
# Verifies scripts/deploy.sh Stage 4.5 policy-file sync behavior:
#   1. Drift scenario: staging differs from prod → cp triggers, files match
#   2. No-drift scenario: staging == prod → no-op
#   3. --no-sync flag: drift remains (operator explicitly skipped)
#   4. Missing files: --no-sync or one-side missing → safe skip
#   5. Policy file list is exactly {CLAUDE.md, SOUL.md, TOOLS.md, HEARTBEAT.md}
#
# Strategy: extract Stage 4.5 to a temp script that overrides REPO_DIR and
# PROD_DIR to point at fixture dirs, then run that script and assert outcomes.
# This avoids running the full deploy.sh (which restarts the gateway).
#
# Returns 0 on all-pass, 1 on any failure.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEPLOY_SH="$REPO_DIR/scripts/deploy.sh"

[[ -f "$DEPLOY_SH" ]] || { echo "FAIL: $DEPLOY_SH not found"; exit 1; }

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# Extract the Stage 4.5 block from deploy.sh: from "Stage 4.5: Policy Sync"
# up to (but not including) "Stage 5: Canary Check". This is the standalone
# logic we want to test, free of banner/git-pull/restart/canary noise.
extract_stage45() {
  awk '
    /# ── Stage 4\.5:/ { capturing = 1 }
    capturing { print }
    /# ── Stage 5:/ { exit }
  ' "$DEPLOY_SH"
}

run_stage45_in_fixtures() {
  local fixture_root="$1"
  local staging_dir="$fixture_root/staging"
  local prod_dir="$fixture_root/prod"

  # Make a fresh Stage 4.5 harness script that overrides REPO_DIR + PROD_DIR
  # via inline env, then sources the extracted block. This isolates the sync
  # from any real prod dir.
  local harness
  harness=$(mktemp "${TMPDIR:-/tmp}/stage45-harness-XXXXXX.sh")
  cat > "$harness" <<EOF
#!/usr/bin/env bash
set -euo pipefail
REPO_DIR="$staging_dir"
PROD_DIR="$prod_dir"
SKIP_SYNC=0
ts()      { date '+%Y-%m-%d %H:%M:%S'; }
section() { echo ""; echo "=== \$1 ==="; echo "\$(ts)"; echo ""; }
die()     { echo "DEPLOY FAILED: \$1" >&2; exit 1; }
POLICY_FILES=(CLAUDE.md SOUL.md TOOLS.md HEARTBEAT.md)
EOF
  extract_stage45 >> "$harness"
  bash "$harness"
  local rc=$?
  rm -f "$harness"
  return $rc
}

# ── Fixture builders ────────────────────────────────────────────────────────
# Make a fixture: staging/ + prod/ with all 4 policy files. $1 is the
# fixture root. $2 (optional) is the drift mode:
#   none  — staging == prod (default)
#   full  — staging has new content for all 4 files (drift on all)
#   one   — staging differs from prod for exactly CLAUDE.md
make_fixture() {
  local root="$1"
  local mode="${2:-none}"
  mkdir -p "$root/staging" "$root/prod"

  local prod_claude="# CLAUDE.md prod
last_sync: 2026-06-15T20:00:00Z"

  local prod_soul="# SOUL.md prod"
  local prod_tools="# TOOLS.md prod"
  local prod_heartbeat="# HEARTBEAT.md prod"

  printf '%s\n' "$prod_claude"   > "$root/prod/CLAUDE.md"
  printf '%s\n' "$prod_soul"     > "$root/prod/SOUL.md"
  printf '%s\n' "$prod_tools"    > "$root/prod/TOOLS.md"
  printf '%s\n' "$prod_heartbeat" > "$root/prod/HEARTBEAT.md"

  case "$mode" in
    none)
      cp "$root/prod/CLAUDE.md"    "$root/staging/CLAUDE.md"
      cp "$root/prod/SOUL.md"      "$root/staging/SOUL.md"
      cp "$root/prod/TOOLS.md"     "$root/staging/TOOLS.md"
      cp "$root/prod/HEARTBEAT.md" "$root/staging/HEARTBEAT.md"
      ;;
    full)
      printf '%s\n' "# CLAUDE.md staging — NEW RULE"   > "$root/staging/CLAUDE.md"
      printf '%s\n' "# SOUL.md staging — NEW"          > "$root/staging/SOUL.md"
      printf '%s\n' "# TOOLS.md staging — NEW"         > "$root/staging/TOOLS.md"
      printf '%s\n' "# HEARTBEAT.md staging — NEW"     > "$root/staging/HEARTBEAT.md"
      ;;
    one)
      cp "$root/prod/CLAUDE.md"    "$root/staging/CLAUDE.md"
      cp "$root/prod/SOUL.md"      "$root/staging/SOUL.md"
      cp "$root/prod/TOOLS.md"     "$root/staging/TOOLS.md"
      cp "$root/prod/HEARTBEAT.md" "$root/staging/HEARTBEAT.md"
      printf '%s\n' "# CLAUDE.md staging — NEW RULE"   > "$root/staging/CLAUDE.md"
      ;;
    missing_staging)
      cp "$root/prod/CLAUDE.md"    "$root/staging/CLAUDE.md"
      cp "$root/prod/SOUL.md"      "$root/staging/SOUL.md"
      cp "$root/prod/TOOLS.md"     "$root/staging/TOOLS.md"
      # HEARTBEAT.md intentionally missing in staging
      ;;
  esac
}

# ── Tests ────────────────────────────────────────────────────────────────────
echo "=== test_deploy_policy_sync ==="
echo ""

# Test 1: drift scenario — staging differs from prod → cp triggers
fx1=$(mktemp -d "${TMPDIR:-/tmp}/deploy-sync-1-XXXXXX")
make_fixture "$fx1" "full"
if run_stage45_in_fixtures "$fx1" >/dev/null 2>&1; then
  if diff -q "$fx1/staging/CLAUDE.md" "$fx1/prod/CLAUDE.md" >/dev/null \
     && diff -q "$fx1/staging/SOUL.md" "$fx1/prod/SOUL.md" >/dev/null \
     && diff -q "$fx1/staging/TOOLS.md" "$fx1/prod/TOOLS.md" >/dev/null \
     && diff -q "$fx1/staging/HEARTBEAT.md" "$fx1/prod/HEARTBEAT.md" >/dev/null; then
    pass "drift scenario: all 4 files synced (staging==prod)"
  else
    fail "drift scenario: files did not match after sync"
  fi
else
  fail "drift scenario: Stage 4.5 returned non-zero"
fi
rm -rf "$fx1"

# Test 2: no-drift scenario — staging == prod → no-op (cp NOT called)
fx2=$(mktemp -d "${TMPDIR:-/tmp}/deploy-sync-2-XXXXXX")
make_fixture "$fx2" "none"
# Capture mtime of prod CLAUDE.md before
mtime_before=$(stat -f %m "$fx2/prod/CLAUDE.md" 2>/dev/null || echo 0)
sleep 1  # ensure any rewrite would change mtime
if run_stage45_in_fixtures "$fx2" >/dev/null 2>&1; then
  mtime_after=$(stat -f %m "$fx2/prod/CLAUDE.md" 2>/dev/null || echo 0)
  if [[ "$mtime_before" == "$mtime_after" ]]; then
    pass "no-drift scenario: prod mtime unchanged (no cp called)"
  else
    fail "no-drift scenario: prod mtime changed ($mtime_before → $mtime_after) — unexpected cp"
  fi
else
  fail "no-drift scenario: Stage 4.5 returned non-zero"
fi
rm -rf "$fx2"

# Test 3: --no-sync flag — drift remains
fx3=$(mktemp -d "${TMPDIR:-/tmp}/deploy-sync-3-XXXXXX")
make_fixture "$fx3" "one"
# Wrap extract in a SKIP_SYNC=1 harness
harness=$(mktemp "${TMPDIR:-/tmp}/stage45-harness-3-XXXXXX.sh")
cat > "$harness" <<EOF
#!/usr/bin/env bash
set -euo pipefail
REPO_DIR="$fx3/staging"
PROD_DIR="$fx3/prod"
SKIP_SYNC=1
ts()      { date '+%Y-%m-%d %H:%M:%S'; }
section() { echo ""; echo "=== \$1 ==="; echo "\$(ts)"; echo ""; }
die()     { echo "DEPLOY FAILED: \$1" >&2; exit 1; }
POLICY_FILES=(CLAUDE.md SOUL.md TOOLS.md HEARTBEAT.md)
EOF
extract_stage45 >> "$harness"
if bash "$harness" >/dev/null 2>&1; then
  if ! diff -q "$fx3/staging/CLAUDE.md" "$fx3/prod/CLAUDE.md" >/dev/null; then
    pass "--no-sync scenario: drift preserved (files still differ)"
  else
    fail "--no-sync scenario: files unexpectedly synced despite SKIP_SYNC=1"
  fi
else
  fail "--no-sync scenario: harness returned non-zero"
fi
rm -f "$harness"
rm -rf "$fx3"

# Test 4: missing staging file — safe skip, no error
fx4=$(mktemp -d "${TMPDIR:-/tmp}/deploy-sync-4-XXXXXX")
make_fixture "$fx4" "missing_staging"
if run_stage45_in_fixtures "$fx4" >/dev/null 2>&1; then
  pass "missing-staging scenario: returned 0 (safe skip)"
else
  fail "missing-staging scenario: returned non-zero"
fi
rm -rf "$fx4"

# Test 5: policy file list is exactly {CLAUDE.md, SOUL.md, TOOLS.md, HEARTBEAT.md}
fx5=$(mktemp -d "${TMPDIR:-/tmp}/deploy-sync-5-XXXXXX")
make_fixture "$fx5" "none"
# Make 2 extra files in staging that are NOT in the policy list
printf '%s\n' "extra" > "$fx5/staging/AGENTS.md"
printf '%s\n' "extra" > "$fx5/staging/USER.md"
# Make AGENTS.md differ in staging from prod (should NOT be synced)
printf '%s\n' "different" > "$fx5/prod/AGENTS.md"
if run_stage45_in_fixtures "$fx5" >/dev/null 2>&1; then
  if diff -q "$fx5/prod/AGENTS.md" "$fx5/staging/AGENTS.md" >/dev/null; then
    fail "policy list: AGENTS.md was synced (should NOT be — out of policy list)"
  else
    pass "policy list: AGENTS.md was NOT synced (out of policy list, correct)"
  fi
fi
rm -rf "$fx5"

echo ""
if [[ "$FAIL" -gt 0 ]]; then
  echo "✗ $FAIL failures, $PASS passes"
  exit 1
fi
echo "✓ All $PASS checks passed"
exit 0
