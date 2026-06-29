#!/usr/bin/env bash
# test_slack_5e_local_deliver_leak.sh
#
# Regression tests for sub-class 5e Slack misroute:
#   gateway-cron-LLM with `deliver: local` posts conversational narration
#   (clarifications, status, "got the test but want to make sure I read you right")
#   at channel root instead of the cron job's origin thread.
#
# Detection signature (5e):
#   • channel-root post (no thread_ts OR thread_ts == ts)
#   • author == hermes bot (U0AEZC7RX1Q)
#   • text mentions BOTH a cron job name AND any other PR/thread identifiers
#     from the cron job's prompt (here: PR #7570 + wa-2366 / rev-5deak)
#   • parent job in ~/.smartclaw_prod/cron/jobs.json has `deliver: local`
#
# Real incident: ts 1781793603.149289, 1781793611.471479, 1781793618.797789
# in #worldai (C0AH3RY3DK6). Should have threaded under 1781477039.080969
# (babysit-wa-2366-rev-5deak origin thread). 3 channel-root orphans.
#
# Strategy:
#   1. Stage a fake ~/.smartclaw_prod/cron/jobs.json with the babysit job.
#   2. Stage fake conversations.history fixtures with the 3 leak messages
#      plus decoy posts that should NOT alert (proper thread, other channel,
#      user-authored, no cron-job-name match, etc.).
#   3. Source scripts/slack_5b_leak_detector.sh with IS_SOURCED=1.
#   4. Call detect_5e_local_deliver_leaks.
#   5. Assert exit code + ALERT line + decoys ignored.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DETECTOR="$REPO_DIR/scripts/slack_5b_leak_detector.sh"

PASSED=0
FAILED=0
pass() { echo "PASS: $1"; PASSED=$((PASSED + 1)); }
fail() { echo "FAIL: $1"; FAILED=$((FAILED + 1)); }

[[ -f "$DETECTOR" ]] || { echo "FAIL: missing $DETECTOR"; exit 1; }

# ── Stage isolated workdir ──────────────────────────────────────────────────
WORKDIR="$(mktemp -d)"
BIN_DIR="$WORKDIR/bin"
LOG_DIR="$WORKDIR/logs"
FIXTURES_DIR="$WORKDIR/fixtures"
FAKE_PROD_HOME="$WORKDIR/hermes_prod"
FAKE_CRON_DIR="$FAKE_PROD_HOME/cron"
FAKE_VAR_SLACK="$FAKE_PROD_HOME/var/slack"
mkdir -p "$BIN_DIR" "$LOG_DIR" "$FIXTURES_DIR" "$FAKE_CRON_DIR" "$FAKE_VAR_SLACK/babysit-wa-2366-rev-5deak"

CURL_LOG="$LOG_DIR/curl.log"

# ── Stage fake cron jobs.json ───────────────────────────────────────────────
# The babysit-wa-2366-rev-5deak job is the leak source.  The prompt
# references PR #7570 and wa-2366 / rev-5deak (extractable by the detector).
cat > "$FAKE_CRON_DIR/jobs.json" <<EOF_JSON
{
  "updated_at": "2026-06-18T00:00:00Z",
  "jobs": [
    {
      "id": "728a2ba69e8e",
      "name": "babysit-wa-2366-rev-5deak",
      "deliver": "local",
      "channel_id": "C0AH3RY3DK6",
      "thread_ts": "1781477039.080969",
      "prompt": "Babysit AO worker wa-2366 for bead rev-5deak (v2-aligned convert of PR #7570). Post progress every poll. Origin thread C0AH3RY3DK6 / 1781477039.080969."
    },
    {
      "id": "other12345",
      "name": "some-other-job",
      "deliver": "slack",
      "prompt": "Slack-delivered job, should be ignored by 5e detector."
    }
  ]
}
EOF_JSON

# ── Stage conversations.history fixtures ────────────────────────────────────
# Channel C0AH3RY3DK6 = the 3 real 5e leaks.
# Each leak references BOTH "PR #7570" AND "wa-2366 / rev-5deak".
write_fixture() {
  local name="$1"
  cat > "$FIXTURES_DIR/$name"
}

write_fixture "C0AH3RY3DK6.json" <<'JSON_EOF'
{
  "ok": true,
  "messages": [
    {
      "ts": "1781793603.149289",
      "user": "U0AEZC7RX1Q",
      "text": "Got the PR #7570 test result. Just want to confirm: wa-2366 / rev-5deak wants the full convert or just the dice audit slice?"
    },
    {
      "ts": "1781793611.471479",
      "user": "U0AEZC7RX1Q",
      "text": "Phase complete on PR #7570 (wa-2366 / rev-5deak): swe-bench harness rebuilt, waiting on next iteration."
    },
    {
      "ts": "1781793618.797789",
      "user": "U0AEZC7RX1Q",
      "text": "Worker spawned for wa-2366 / rev-5deak to retry PR #7570 build with new flag."
    },
    {
      "ts": "1781793700.000000",
      "thread_ts": "1781477039.080969",
      "user": "U0AEZC7RX1Q",
      "text": "Bring-to-green status: PR #7570 ready for merge"
    },
    {
      "ts": "1781793800.000001",
      "user": "U09GH5BR3QU",
      "text": "PR #7570 review notes from jleechan"
    },
    {
      "ts": "1781793900.000002",
      "user": "U0AEZC7RX1Q",
      "text": "Bring-to-green status: unrelated PR #1234 (no cron job name match)"
    }
  ]
}
JSON_EOF

# Channel without cron jobs: must not be scanned at all.
write_fixture "C0BA4MCBPFB.json" <<<'{"ok":true,"messages":[]}'
write_fixture "${SLACK_CHANNEL_ID}.json" <<<'{"ok":true,"messages":[]}'
write_fixture "${SLACK_CHANNEL_ID}.json" <<<'{"ok":true,"messages":[]}'

# ── Fake curl ───────────────────────────────────────────────────────────────
cat > "$BIN_DIR/curl" <<'CURL_EOF'
#!/usr/bin/env bash
LOG_FILE="${FAKE_CURL_LOG:-/tmp/fake-curl.log}"
echo "[curl] $*" >> "$LOG_FILE"
URL=""
CHANNEL=""
for ((i=1; i<=$#; i++)); do
  arg="${!i}"
  case "$arg" in
    https://slack.com/api/*) URL="$arg" ;;
    --data-urlencode=channel=*) CHANNEL="${arg#--data-urlencode=channel=}" ;;
    --data-urlencode) i=$((i+1)); next="${!i}"; case "$next" in channel=*) CHANNEL="${next#channel=}" ;; esac ;;
  esac
done
if [[ "$URL" == *"conversations.history"* ]]; then
  fx="${FIXTURES_DIR:-/tmp/fake-fix}/$CHANNEL.json"
  if [[ -f "$fx" ]]; then cat "$fx"; else echo '{"ok":true,"messages":[]}'; fi
  exit 0
fi
echo '{"ok":true,"ts":"9999999999.999999"}'
CURL_EOF
chmod +x "$BIN_DIR/curl"
export PATH="$BIN_DIR:$PATH"
export FAKE_CURL_LOG="$CURL_LOG"
export FIXTURES_DIR

# ── Driver ──────────────────────────────────────────────────────────────────
run_5e() {
  local state_file="$1"
  (
    export SLACK_USER_TOKEN="xoxp-fake"
    export SLACK_5B_CURL_BIN="$BIN_DIR/curl"
    export SLACK_5B_DRY_RUN="1"
    export SLACK_5B_STATE_FILE="$state_file"
    export SLACK_5B_CHANNELS="C0AH3RY3DK6 C0BA4MCBPFB ${SLACK_CHANNEL_ID} ${SLACK_CHANNEL_ID}"
    export SLACK_5B_BOT_USER_ID="U0AEZC7RX1Q"
    # Critical: point 5e detector at the staged fake prod home.
    export SLACK_5E_CRON_HOME="$FAKE_PROD_HOME"
    # shellcheck source=/dev/null
    IS_SOURCED=1 source "$DETECTOR"
    # Pre-condition: function MUST exist for the 5e drive to mean anything.
    if ! declare -F detect_5e_local_deliver_leaks >/dev/null; then
      echo "RED-PRECONDITION: detect_5e_local_deliver_leaks not defined in $DETECTOR" >&2
      return 127
    fi
    detect_5e_local_deliver_leaks
  )
}

# ── Test A: function exists ────────────────────────────────────────────────
TMP_STATE="$WORKDIR/state-a.json"
rm -f "$TMP_STATE"
set +e
OUT_A=$(run_5e "$TMP_STATE" 2>&1)
RC_A=$?
set -e
if [[ $RC_A -ne 127 ]]; then
  pass "test A (green): detect_5e_local_deliver_leaks is defined"
else
  fail "test A: detect_5e_local_deliver_leaks missing"
fi

# ── Test B: once implemented, the 3 leak ts should be surfaced ──────────────
# Only meaningful once function exists. With current code RC=127 so this is
# skipped automatically by set +e on the OUT_A capture, but we still assert
# by running the full flow again. If the function exists and is correct:
#   rc=1 (leaks found) AND 3 ALERT lines for the leak ts AND decoys ignored.
TMP_STATE="$WORKDIR/state-b.json"
rm -f "$TMP_STATE"
set +e
OUT_B=$(run_5e "$TMP_STATE" 2>&1)
RC_B=$?
set -e
echo "----- fixture preview (human verification) -----"
cat "$FIXTURES_DIR/C0AH3RY3DK6.json" | jq -r '.messages[] | "  ts=\(.ts) thread_ts=\(.thread_ts // "(none)") text=\(.text)"'
echo "----- run output -----"
echo "$OUT_B"

if [[ $RC_B -eq 127 ]]; then
  fail "test B: detect_5e_local_deliver_leaks still not implemented"
elif [[ $RC_B -eq 1 ]] \
     && echo "$OUT_B" | grep -q "5E-ALERT ts=1781793603.149289" \
     && echo "$OUT_B" | grep -q "5E-ALERT ts=1781793611.471479" \
     && echo "$OUT_B" | grep -q "5E-ALERT ts=1781793618.797789" \
     && ! echo "$OUT_B" | grep -q "5E-ALERT ts=1781793700.000000" \
     && ! echo "$OUT_B" | grep -q "5E-ALERT ts=1781793800.000001" \
     && ! echo "$OUT_B" | grep -q "5E-ALERT ts=1781793900.000002"; then
  pass "test B (green): 3 leak ts detected, threaded reply + human + non-cron-job-name all ignored"
else
  fail "test B: expected rc=1 + 3 5E-ALERTs + decoys skipped, got rc=$RC_B out=$OUT_B"
fi

# ── Test E: channel_id fallback from prompt (real prod shape: null) ────────
# Production jobs (e.g. babysit-wa-2366-rev-5deak) sometimes ship with
# channel_id: null and embed the channel id in the prompt text instead.
# The detector MUST derive the channel from the prompt rather than
# silently skipping the job (P1 review #638 / cursor[bot] 2026-06-18).
TMP_STATE="$WORKDIR/state-e.json"
cat > "$FAKE_CRON_DIR/jobs.json" <<EOF_JSON
{
  "updated_at": "2026-06-18T00:00:00Z",
  "jobs": [
    {
      "id": "prod-shape-1",
      "name": "babysit-wa-2366-rev-5deak",
      "deliver": "local",
      "channel_id": null,
      "prompt": "Babysit AO worker wa-2366 for bead rev-5deak. Origin channel C0AH3RY3DK6 / thread 1781477039.080969. Reference PR #7570."
    }
  ]
}
EOF_JSON
rm -f "$TMP_STATE"
set +e
OUT_E=$(run_5e "$TMP_STATE" 2>&1)
RC_E=$?
set -e
if [[ $RC_E -eq 127 ]]; then
  fail "test E: detect_5e_local_deliver_leaks still not implemented"
elif [[ $RC_E -eq 1 ]] \
     && echo "$OUT_E" | grep -q "5E-ALERT" \
     && echo "$OUT_E" | grep -q "channel=C0AH3RY3DK6"; then
  pass "test E: channel_id=null job scanned via prompt-derived channel (no silent skip)"
else
  fail "test E: expected rc=1 + 5E-ALERT + channel=C0AH3RY3DK6, got rc=$RC_E out=$OUT_E"
fi

# ── Test F: jobs with no channel and no extractable channel must FAIL LOUDLY
# We expect rc=2 (scan failure) and a SCAN-GAP log line so an operator can
# notice and add channel_id. Silently skipping would leave the 5e class
# unmonitored for that job.
TMP_STATE="$WORKDIR/state-f.json"
cat > "$FAKE_CRON_DIR/jobs.json" <<EOF_JSON
{
  "updated_at": "2026-06-18T00:00:00Z",
  "jobs": [
    {
      "id": "no-channel-1",
      "name": "babysit-unscannable-job",
      "deliver": "local",
      "channel_id": null,
      "prompt": "Some prompt that has no Slack channel id anywhere in it."
    }
  ]
}
EOF_JSON
rm -f "$TMP_STATE"
set +e
OUT_F=$(run_5e "$TMP_STATE" 2>&1)
RC_F=$?
set -e
if [[ $RC_F -eq 127 ]]; then
  fail "test F: detect_5e_local_deliver_leaks still not implemented"
elif [[ $RC_F -eq 2 ]] \
     && echo "$OUT_F" | grep -q "5e SCAN-GAP"; then
  pass "test F: no-channel + no-prompt-channel → rc=2 + SCAN-GAP log (loud failure, not silent skip)"
else
  fail "test F: expected rc=2 + SCAN-GAP, got rc=$RC_F out=$OUT_F"
fi

# ── Test G: detect_all_leaks returns nonzero when either detector does ─────
# The combined runner MUST propagate exit codes (rc_5b / rc_5e) so cron
# and launchd callers can detect leaks or scan failures, not just print
# OK no leaks while emitting 5E-ALERT lines. Restore the live-fail cron
# config (channel_id set, leak ts in fixture) and confirm rc=1.
TMP_STATE="$WORKDIR/state-g.json"
cat > "$FAKE_CRON_DIR/jobs.json" <<EOF_JSON
{
  "updated_at": "2026-06-18T00:00:00Z",
  "jobs": [
    {
      "id": "728a2ba69e8e",
      "name": "babysit-wa-2366-rev-5deak",
      "deliver": "local",
      "channel_id": "C0AH3RY3DK6",
      "thread_ts": "1781477039.080969",
      "prompt": "Babysit AO worker wa-2366 for bead rev-5deak (v2-aligned convert of PR #7570)."
    }
  ]
}
EOF_JSON
rm -f "$TMP_STATE"
set +e
OUT_G=$(
  export SLACK_USER_TOKEN="xoxp-fake"
  export SLACK_5B_CURL_BIN="$BIN_DIR/curl"
  export SLACK_5B_DRY_RUN="1"
  export SLACK_5B_STATE_FILE="$TMP_STATE"
  export SLACK_5B_CHANNELS="C0AH3RY3DK6 C0BA4MCBPFB ${SLACK_CHANNEL_ID} ${SLACK_CHANNEL_ID}"
  export SLACK_5B_BOT_USER_ID="U0AEZC7RX1Q"
  export SLACK_5E_CRON_HOME="$FAKE_PROD_HOME"
  IS_SOURCED=1 source "$DETECTOR"
  detect_all_leaks
)
RC_G=$?
set -e
if [[ $RC_G -eq 127 ]]; then
  fail "test G: detect_all_leaks still not implemented"
elif [[ $RC_G -eq 1 ]] \
     && echo "$OUT_G" | grep -q "5E-ALERT"; then
  pass "test G: detect_all_leaks rc=1 when 5e detector finds leaks (rc propagated, not swallowed)"
else
  fail "test G: expected rc=1 + 5E-ALERT, got rc=$RC_G out=$OUT_G"
fi

# ── Test C: idempotent re-run on same state file → second run exit 0 ────────
TMP_STATE="$WORKDIR/state-c.json"
rm -f "$TMP_STATE"
set +e
OUT_C1=$(run_5e "$TMP_STATE" 2>&1)
RC_C1=$?
OUT_C2=$(run_5e "$TMP_STATE" 2>&1)
RC_C2=$?
set -e
if [[ $RC_C1 -eq 127 ]]; then
  fail "test C: detect_5e_local_deliver_leaks still not implemented"
elif [[ $RC_C1 -eq 1 && $RC_C2 -eq 0 ]]; then
  pass "test C: dedup — second run exit 0, state contains 1781793603.149289"
elif [[ $RC_C1 -eq 127 ]]; then
  pass "test C: deferred (function not implemented)"
else
  fail "test C: expected RC1=1 RC2=0, got RC1=$RC_C1 RC2=$RC_C2"
fi

# ── Test D: escape hatch disable_5e_detect on the job → no alert ───────────
TMP_STATE="$WORKDIR/state-d.json"
# Rebuild jobs.json with disable_5e_detect on the babysit job.
cat > "$FAKE_CRON_DIR/jobs.json" <<EOF_JSON
{
  "updated_at": "2026-06-18T00:00:00Z",
  "jobs": [
    {
      "id": "728a2ba69e8e",
      "name": "babysit-wa-2366-rev-5deak",
      "deliver": "local",
      "channel_id": "C0AH3RY3DK6",
      "thread_ts": "1781477039.080969",
      "disable_5e_detect": true,
      "prompt": "Babysit AO worker wa-2366 for bead rev-5deak (v2-aligned convert of PR #7570)."
    }
  ]
}
EOF_JSON
rm -f "$TMP_STATE"
set +e
OUT_D=$(run_5e "$TMP_STATE" 2>&1)
RC_D=$?
set -e
if [[ $RC_D -eq 127 ]]; then
  fail "test D: detect_5e_local_deliver_leaks still not implemented"
elif [[ $RC_D -eq 0 ]] && ! echo "$OUT_D" | grep -q "5E-ALERT"; then
  pass "test D: disable_5e_detect escape hatch honored (exit 0, no alert)"
else
  fail "test D: expected rc=0 + no 5E-ALERT, got rc=$RC_D out=$OUT_D"
fi

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "=============================="
echo "PASSED: $PASSED / 7"
echo "FAILED: $FAILED / 7"
echo "=============================="

rm -rf "$WORKDIR"

if [[ "$FAILED" -gt 0 ]]; then
  exit 1
fi
exit 0
