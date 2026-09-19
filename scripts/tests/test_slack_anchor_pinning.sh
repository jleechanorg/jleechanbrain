#!/usr/bin/env bash
# test_slack_anchor_pinning.sh
#
# Unit-style assertions for the daily-anchor pinning fix in
# lib-slack-post.sh. Verifies:
#   1. DAILY_ANCHOR_CHANNEL env overrides default #ai-general target.
#   2. slack_post_daily_anchor emits one Slack post to the anchor channel.
#   3. slack_post_per_thread_summary emits one POST per (chan, ts) row
#      in threads.csv, with thread_ts=<row.ts> (a reply, not a channel-root).
#   4. Threads younger than DAILY_ANCHOR_GRACE_MIN are skipped.
#
# All Slack calls are intercepted by a fake slack_post_message that just
# appends to $TMPDIR/requests.log. We source lib-slack-post.sh after
# defining slack_post_message so the lib's real function is shadowed.
#
# Exit code: 0 if all assertions pass, 1 otherwise.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO_ROOT/scripts/lib-slack-post.sh"
if [[ ! -f "$LIB" ]]; then
  echo "FATAL: lib-slack-post.sh not found at $LIB" >&2
  exit 1
fi

TMPDIR=$(mktemp -d -t anchor-pin-test.XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

# Stub: intercept slack_post_message and append args to the requests log.
# Each line: <channel> <thread_ts|""> <message>
cat > "$TMPDIR/slack_post_message" <<'STUB'
#!/usr/bin/env bash
echo "$1|$2|$3" >> "$TMPDIR/requests.log"
STUB
chmod +x "$TMPDIR/slack_post_message"
export PATH="$TMPDIR:$PATH"

# Stub: slack__resolve_token — always succeeds.
cat > "$TMPDIR/slack__resolve_token" <<'STUB'
#!/usr/bin/env bash
echo "xoxb-test-token"
STUB
chmod +x "$TMPDIR/slack__resolve_token"

# Override the real lib's slack_post_message / slack__resolve_token by
# putting our stubs earlier on PATH (the lib doesn't re-export them, so
# we instead re-source the lib and rely on the stubs via PATH shadowing).
source "$LIB"

# Override slack_post_message (one Bash call = one logical Slack post).
# Use a sidecar counter file so multi-line message bodies don't inflate
# line counts. Each call writes ONE record to /requests.log (containing the
# multi-line body, with the count preserved separately) and ONE numeric
# increment to /call_count.
slack_post_message() {
  {
    printf 'CALL %d:\n' "$(($(cat "$TMPDIR/call_count" 2>/dev/null || echo 0) + 1))"
    printf 'CHANNEL=%s\n' "$1"
    printf 'THREAD_TS=%s\n' "${3:-}"
    printf 'BODY_BEGIN\n'
    printf '%s\n' "$2"
    printf 'BODY_END\n'
    echo "---"
  } >> "$TMPDIR/requests.log"
  echo $(( $(cat "$TMPDIR/call_count" 2>/dev/null || echo 0) + 1 )) > "$TMPDIR/call_count"
}
slack__resolve_token() { echo "xoxb-test-token"; }
# Helper used by tests: count Slack calls.
count_calls() { cat "$TMPDIR/call_count" 2>/dev/null || echo 0; }
# Helper: count calls that match a regex (e.g. a channel prefix).
count_calls_matching() {
  awk -v re="$1" '
    /^CHANNEL=/ { chan = substr($0, 9); next }
    /^CALL [0-9]+:/ { in_call = 1; next }
    /^---/ { if (in_call && chan ~ re) cnt++; in_call = 0; chan = ""; next }
    { next }
    END { print cnt + 0 }
  ' "$TMPDIR/requests.log"
}
# Helper: count threaded replies (calls with non-empty THREAD_TS).
count_threaded() {
  awk '
    /^THREAD_TS=/ {
      ts = substr($0, 11)
      threaded = (ts != "")
      next
    }
    /^CALL [0-9]+:/ { in_call = 1; next }
    /^---/ { if (in_call && threaded) cnt++; in_call = 0; threaded = 0; next }
    { next }
    END { print cnt + 0 }
  ' "$TMPDIR/requests.log"
}

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# Build a sample threads.csv: 3 threads across 2 channels, mixed ages.
NOW=$(date +%s)
OLD1_TS="$(( NOW - 7200 )).000100"   # 2h old → past grace window (60 min)
OLD2_TS="$(( NOW - 3600 )).000200"   # 1h old → past grace
NEW_TS="$(( NOW - 30 )).000300"      # 30s old → within grace → SKIP
THREADS_CSV_TXT=$'C0AH3RY3DK6|'"$OLD1_TS"$'|https://slack.com/archives/C0AH3RY3DK6/p'"${OLD1_TS//./}"$'|admitted\nC0AH3RY3DK6|'"$OLD2_TS"$'|https://slack.com/archives/C0AH3RY3DK6/p'"${OLD2_TS//./}"$'|cold\n${SLACK_CHANNEL_ID}|'"$NEW_TS"$'|https://slack.com/archives/${SLACK_CHANNEL_ID}/p'"${NEW_TS//./}"$'|timeout_failure'
JUDGMENT_TXT=$'### thread A — admitted\n\n<a href="https://slack.com/archives/C0AH3RY3DK6/p'"${OLD1_TS//./}"$'">thread</a>\n\nbody for A\n\n### thread B — cold\n\n<a href="https://slack.com/archives/C0AH3RY3DK6/p'"${OLD2_TS//./}"$'">thread</a>\n\nbody for B\n\n### thread C — timeout_failure\n\n<a href="https://slack.com/archives/${SLACK_CHANNEL_ID}/p'"${NEW_TS//./}"$'">thread</a>\n\nbody for C\n'

# Use a tab-separated format in the stub so message-body pipes don't confuse
# downstream counting. Rewrite the stub.
cat > "$TMPDIR/slack_post_message" <<'STUB'
#!/usr/bin/env bash
printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$TMPDIR/requests.log"
STUB

reset_log() {
  : > "$TMPDIR/requests.log"
  echo 0 > "$TMPDIR/call_count"
}

echo ""
echo "=== test 1: DAILY_ANCHOR_CHANNEL override ==="
reset_log
DAILY_ANCHOR_CHANNEL="C0BA4MCBPFB" \
  slack_post_daily_anchor "" \
    "https://github.com/jleechanorg/roadmap/blob/main/test.md" \
    "2026-06-21 1800" "$JUDGMENT_TXT" "$THREADS_CSV_TXT" \
    >> "$TMPDIR/out.log" 2>&1
OVERRIDE_COUNT=$(count_calls_matching '^C0BA4MCBPFB$')
if [[ "$OVERRIDE_COUNT" -ge 1 ]]; then
  ok "anchor landed in override channel C0BA4MCBPFB ($OVERRIDE_COUNT post)"
else
  bad "anchor did NOT land in override channel"
  cat "$TMPDIR/out.log"
fi

echo ""
echo "=== test 2: default anchor = C0AJQ5M0A0Y (=#ai-general) ==="
reset_log
unset DAILY_ANCHOR_CHANNEL
slack_post_daily_anchor "" \
  "https://github.com/jleechanorg/roadmap/blob/main/test.md" \
  "2026-06-21 1800" "$JUDGMENT_TXT" "$THREADS_CSV_TXT" \
  >> "$TMPDIR/out.log" 2>&1
DEFAULT_COUNT=$(count_calls_matching '^C0AJQ5M0A0Y$')
if [[ "$DEFAULT_COUNT" -ge 1 ]]; then
  ok "default anchor landed in C0AJQ5M0A0Y ($DEFAULT_COUNT post)"
else
  bad "default anchor did NOT land in C0AJQ5M0A0Y"
  cat "$TMPDIR/out.log"
fi

echo ""
echo "=== test 3: per-thread summary → one reply per (chan, ts) ==="
reset_log
slack_post_per_thread_summary "C0AH3RY3DK6 ${SLACK_CHANNEL_ID}" \
  "https://github.com/jleechanorg/roadmap/blob/main/test.md" \
  "2026-06-21 1800" "$JUDGMENT_TXT" "$THREADS_CSV_TXT" \
  >> "$TMPDIR/out.log" 2>&1
TOTAL_POSTS=$(count_calls)
# Expectation: 2 posts (OLD1_TS and OLD2_TS in C0AH3RY3DK6). NEW_TS in
# ${SLACK_CHANNEL_ID} is within the 60m grace → SKIPPED.
if [[ "$TOTAL_POSTS" -eq 2 ]]; then
  ok "per-thread emitted 2 replies (1 within grace skipped)"
else
  bad "per-thread expected 2 replies, got $TOTAL_POSTS"
  cat "$TMPDIR/out.log"
fi
THREADED_REPLIES=$(count_threaded)
if [[ "$THREADED_REPLIES" -eq 2 ]]; then
  ok "all 2 posts used thread_ts (replies, not channel-root)"
else
  bad "expected 2 threaded replies, got $THREADED_REPLIES"
fi
NON_GRACE_LEAK=$(count_calls_matching '^${SLACK_CHANNEL_ID}$')
if [[ "$NON_GRACE_LEAK" -eq 0 ]]; then
  ok "no leak into ${SLACK_CHANNEL_ID} (NEW_TS skipped by grace)"
else
  bad "leak: $NON_GRACE_LEAK post(s) to ${SLACK_CHANNEL_ID} within grace"
fi

echo ""
echo "=== test 4: DAILY_ANCHOR_GRACE_MIN=0 → no skips ==="
reset_log
DAILY_ANCHOR_GRACE_MIN=0 \
  slack_post_per_thread_summary "C0AH3RY3DK6 ${SLACK_CHANNEL_ID}" \
    "https://github.com/jleechanorg/roadmap/blob/main/test.md" \
    "2026-06-21 1800" "$JUDGMENT_TXT" "$THREADS_CSV_TXT" \
    >> "$TMPDIR/out.log" 2>&1
ZERO_GRACE_POSTS=$(count_calls)
if [[ "$ZERO_GRACE_POSTS" -eq 3 ]]; then
  ok "grace=0 → all 3 threads got replies (NEW_TS not skipped)"
else
  bad "grace=0 expected 3 replies, got $ZERO_GRACE_POSTS"
  cat "$TMPDIR/requests.log"
fi

echo ""
echo "=== test 5: DAILY_ANCHOR_GRACE_MIN=99999 → all skipped ==="
reset_log
DAILY_ANCHOR_GRACE_MIN=99999 \
  slack_post_per_thread_summary "C0AH3RY3DK6 ${SLACK_CHANNEL_ID}" \
    "https://github.com/jleechanorg/roadmap/blob/main/test.md" \
    "2026-06-21 1800" "$JUDGMENT_TXT" "$THREADS_CSV_TXT" \
    >> "$TMPDIR/out.log" 2>&1
HIGH_GRACE_POSTS=$(count_calls)
if [[ "$HIGH_GRACE_POSTS" -eq 0 ]]; then
  ok "grace=99999 → all threads skipped (0 replies)"
else
  bad "grace=99999 expected 0 replies, got $HIGH_GRACE_POSTS"
fi

echo ""
echo "=== test 6: threads.csv filter (channels_csv narrows scope) ==="
reset_log
DAILY_ANCHOR_GRACE_MIN=0 \
  slack_post_per_thread_summary "${SLACK_CHANNEL_ID}" \
    "https://github.com/jleechanorg/roadmap/blob/main/test.md" \
    "2026-06-21 1800" "$JUDGMENT_TXT" "$THREADS_CSV_TXT" \
    >> "$TMPDIR/out.log" 2>&1
FILTERED_POSTS=$(count_calls)
# Only NEW_TS is in ${SLACK_CHANNEL_ID} → 1 reply, not 3.
if [[ "$FILTERED_POSTS" -eq 1 ]]; then
  ok "channels_csv filter respected (1 reply, not 3)"
else
  bad "filter expected 1 reply, got $FILTERED_POSTS"
  cat "$TMPDIR/requests.log"
fi

echo ""
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
