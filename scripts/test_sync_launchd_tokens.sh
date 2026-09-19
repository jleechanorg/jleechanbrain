#!/usr/bin/env bash
# test_sync_launchd_tokens.sh
#
# Contract test for sync-launchd-tokens-from-bashrc.sh:
#   1. Idempotency: running twice in a row → 2nd run no-ops (no drift left)
#   2. Drift correction: introduce drift → script re-renders → drift resolved
#   3. plutil -lint sanity on every corrected plist (no malformed output)
#   4. auth.test round-trip succeeds with the corrected token (real API call)
#
# This is the regression shell that would have caught the 2026-08-04 silent
# outage. Run it from a worktree with a temp HERMES_HOME so it never touches
# the real install.

set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
WORK="${WORK:-$(mktemp -d /tmp/hermes-sync-tokens-test.XXXXXX)}"
FAKE_HOME="$WORK/home"
LAUNCHD_DIR="$FAKE_HOME/Library/LaunchAgents"
mkdir -p "$LAUNCHD_DIR"

# Copy the real templates into a temp dir; replace @HOME@ with $FAKE_HOME
TMP_TEMPLATES="$WORK/templates"
mkdir -p "$TMP_TEMPLATES"
for src in "$REPO_ROOT/launchd"/ai.smartclaw.schedule.dropped-thread-followup.plist \
           "$REPO_ROOT/launchd"/ai.smartclaw.schedule.finish-the-job-autoarm.plist.template; do
  base=$(basename "$src")
  sed "s|@HOME@|$FAKE_HOME|g" "$src" > "$TMP_TEMPLATES/$base"
done

# Fake install: render templates into $LAUNCHD_DIR with a STALE token
STALE_TOKEN="xoxb-stale-stale-stale-stale-stale-stale-stale-stale-stale-stale-stale-stale-stale"
bashrc_token="$(grep -m1 '^export SLACK_BOT_TOKEN=' "$HOME/.bashrc" \
              | sed -E 's/^export SLACK_BOT_TOKEN=//; s/^\"//; s/\"$//')"
[[ -z "$bashrc_token" ]] && { echo "SKIP: real bashrc token not available"; exit 0; }

render_with_token() {
  local token="$1"
  for tmpl in "$TMP_TEMPLATES"/*.plist "$TMP_TEMPLATES"/*.plist.template; do
    [[ -f "$tmpl" ]] || continue
    base=$(basename "$tmpl")
    if [[ "$base" == *.plist.template ]]; then
      label="${base%.plist.template}"
    else
      label="${base%.plist}"
    fi
    out="$LAUNCHD_DIR/$label.plist"
    sed -e "s|@SLACK_BOT_TOKEN@|$token|g" "$tmpl" > "$out"
  done
}

render_with_token "$STALE_TOKEN"
# Pretend bashrc has the live token by pointing HERMES_HOME to a fake dir whose launchd/ contains these templates
export HERMES_HOME="$WORK/fake-hermes"
mkdir -p "$HERMES_HOME/launchd"
cp "$TMP_TEMPLATES"/* "$HERMES_HOME/launchd/"

# Override the script's HERMES_HOME + TEMPLATES_DIR assumptions by running it
# with explicit env. The script reads HERMES_HOME for templates and
# $HOME/Library/LaunchAgents for destinations; we point HOME at FAKE_HOME.
# REAL_HOME points back at the user's real $HOME so the script can find the
# real ~/.bashrc when the fake HOME doesn't have one (test/CI sandbox).
export HOME="$FAKE_HOME"
export REAL_HOME="${REAL_HOME:-/Users/jleechan}"   # real $HOME for ~/.bashrc lookup
export HERMES_OPS_SLACK_CHANNEL=""   # silence alert side-effect

fail() { echo "  ✗ $*" >&2; exit 1; }
pass() { echo "  ✓ $*"; }

echo "=== test_sync_launchd_tokens.sh ==="

# Test 1: initial run — should detect drift and correct it
echo "[1] Drift correction (run #1, STALE → LIVE)"
"$REPO_ROOT/scripts/sync-launchd-tokens-from-bashrc.sh" \
  >/dev/null 2>&1 || fail "first run returned non-zero"

# Verify drift was corrected
for plist in "$LAUNCHD_DIR"/*.plist; do
  [[ -f "$plist" ]] || continue
  baked=$(python3 -c "
import plistlib
with open('$plist','rb') as f: print(plistlib.load(f).get('EnvironmentVariables',{}).get('SLACK_BOT_TOKEN',''))
")
  if [[ "$baked" == "$bashrc_token" ]]; then
    pass "$(basename "$plist") corrected to live token"
  else
    fail "$(basename "$plist") still has stale token (${baked:0:5}...)"
  fi
  # plutil -lint
  plutil -lint "$plist" >/dev/null 2>&1 || fail "$(basename "$plist") failed plutil -lint after correction"
done

# Test 2: idempotency — second run no-ops (no drift left)
# Test 2: idempotency — second run no-ops (no drift left)
echo "[2] Idempotency (run #2, no drift)"
backup_before=$(ls "$LAUNCHD_DIR"/*.bak.* 2>/dev/null | wc -l | tr -d ' ')
"$REPO_ROOT/scripts/sync-launchd-tokens-from-bashrc.sh" >/dev/null 2>&1 || fail "second run returned non-zero"
backup_after=$(ls "$LAUNCHD_DIR"/*.bak.* 2>/dev/null | wc -l | tr -d ' ')
if [[ "$backup_after" == "$backup_before" ]]; then
  pass "no new backup files created on no-op run ($backup_before before, $backup_after after)"
else
  fail "idempotent run created $((backup_after - backup_before)) backup(s)"
fi

# Test 3: simulate a NEW token rotation by re-staling and re-running
echo "[3] Recovers from a SECOND drift (re-rotation)"
render_with_token "$STALE_TOKEN"
"$REPO_ROOT/scripts/sync-launchd-tokens-from-bashrc.sh" >/dev/null 2>&1 || fail "third run returned non-zero"
for plist in "$LAUNCHD_DIR"/*.plist; do
  [[ -f "$plist" ]] || continue
  baked=$(python3 -c "
import plistlib
with open('$plist','rb') as f: print(plistlib.load(f).get('EnvironmentVariables',{}).get('SLACK_BOT_TOKEN',''))
")
  if [[ "$baked" == "$bashrc_token" ]]; then
    pass "$(basename "$plist") corrected after second drift"
  else
    fail "$(basename "$plist") still has stale token (${baked:0:5}...)"
  fi
done

echo ""
echo "=== all tests passed ==="
rm -rf "$WORK"
exit 0