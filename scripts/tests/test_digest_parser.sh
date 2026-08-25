#!/usr/bin/env bash
# test_digest_parser.sh
#
# Regression test for the PY_DIGEST_SCRIPT sys.argv[1] bug in
# slack-thread-roadmap-report.sh (line 230). With the original invocation
# `python3 -c SCRIPT -- "$messages_json"`, sys.argv[1] is the literal string
# "--" (the option-list terminator), and `json.loads("--")` raises
# JSONDecodeError, causing every thread to fall through to the
# "[parse error]" branch — which is what produced the "Digest failed to
# parse" / "unreadable — manual review needed" lines in the LLM judgment
# (incident 2026-06-22, root-caused 2026-06-22, fixed in this commit).
#
# This test asserts:
#   1. The current invocation produces real digests (no JSONDecodeError).
#   2. The output contains the user IDs and text from the input messages.
#   3. The output respects the 30-message cap.
#   4. The output respects the 280-char per-message truncation.
#   5. Empty/missing input produces empty output (no [parse error]).
#   6. Direct negative control: re-introducing `--` causes the bug.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/slack-thread-roadmap-report.sh"
if [[ ! -f "$SCRIPT" ]]; then
  echo "FATAL: slack-thread-roadmap-report.sh not found at $SCRIPT" >&2
  exit 1
fi

# Pull the live PY_DIGEST_SCRIPT out of the report script so this test
# always exercises the actual code, not a copy. The script is a single-
# quoted heredoc-style assignment. We strip BOTH the opening `'` (on the
# first line, after `PY_DIGEST_SCRIPT=`) and the closing `'` (its own
# line at the end). What remains is the bare Python code.
PY_DIGEST_SCRIPT=$(awk '
  /^[[:space:]]*PY_DIGEST_SCRIPT=/ {
    flag = 1
    sub(/^[[:space:]]*PY_DIGEST_SCRIPT='"'"'/, "")
    print
    next
  }
  flag == 1 && /^[[:space:]]*'"'"'$/ {
    flag = 0
    exit
  }
  flag == 1 { print }
' "$SCRIPT")
if [[ -z "$PY_DIGEST_SCRIPT" ]]; then
  echo "FATAL: could not extract PY_DIGEST_SCRIPT from $SCRIPT" >&2
  exit 1
fi

# Pull the matching invocation line (the bash `if ! digest=...` line).
# Use python's regex to extract the inner python3 -c command (between
# `if ! digest=$(` and `)`) — sed/awk had trouble with the `$(` combo.
INVOCATION=$(SCRIPT="$SCRIPT" python3 -c '
import re, sys, os
with open(os.environ["SCRIPT"]) as f:
    content = f.read()
m = re.search(r"if ! digest=\$\((python3 -c[^)]+)\)", content)
print(m.group(1) if m else "")
')
if [[ -z "$INVOCATION" ]]; then
  echo "FATAL: could not find the PY_DIGEST_SCRIPT invocation in $SCRIPT" >&2
  exit 1
fi
echo "  (debug) extracted INVOCATION: [$INVOCATION]"

PASS=0
FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

run_digest() {
  # $1 = messages JSON. The script's invocation is
  # `python3 -c "$PY_DIGEST_SCRIPT" "$messages_json" 2>/dev/null` — it
  # reads the JSON from the $messages_json bash var. Set that var, eval
  # the live invocation, then unset. (Substitution broke because the JSON
  # contains its own double-quotes which conflicted with the eval string.)
  local messages_json="$1"
  eval "$INVOCATION" 2>/dev/null
}

TMPDIR=$(mktemp -d -t digest-test.XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

echo ""
echo "=== test 1: live invocation parses real messages ==="
MSGS=$'[{"user":"U0AEZC7RX1Q","text":"hello world","ts":"1700000000.000100"},'
MSGS+=$'{"user":"U09GH5BR3QU","text":"reply with link to thread","ts":"1700000060.000200"}]'
OUT=$(run_digest "$MSGS")
if [[ "$OUT" == *"U0AEZC7RX1Q"* && "$OUT" == *"hello world"* && "$OUT" == *"U09GH5BR3QU"* && "$OUT" == *"reply with link to thread"* ]]; then
  ok "real messages produced real digests (no [parse error])"
else
  bad "expected user/text in digest, got: $(echo "$OUT" | head -3)"
fi
if [[ "$OUT" != *"[parse error]"* ]]; then
  ok "no [parse error] in output"
else
  bad "got [parse error] — the bug is back"
fi

echo ""
echo "=== test 2: per-message 280-char truncation ==="
LONG=$(printf 'a%.0s' $(seq 1 400))
LONG_MSGS=$'[{"user":"U_LONGTEXT","text":"'"$LONG"'","ts":"1700000000.000100"}]'
LONG_OUT=$(run_digest "$LONG_MSGS")
if echo "$LONG_OUT" | grep -q "aaaa…"; then
  ok "long messages truncated to 280 chars + ellipsis"
else
  bad "expected 'aaaa…' in output, got first 100 chars: $(echo "$LONG_OUT" | head -c 100)"
fi

echo ""
echo "=== test 3: 30-message cap ==="
CAP_JSON="["
for i in $(seq 1 50); do
  if [[ $i -gt 1 ]]; then CAP_JSON+=","; fi
  CAP_JSON+="{\"user\":\"U$i\",\"text\":\"msg $i\",\"ts\":\"1700000$i.000100\"}"
done
CAP_JSON+="]"
CAP_OUT=$(run_digest "$CAP_JSON")
CAP_COUNT=$(echo "$CAP_OUT" | grep -c '^\[')
if [[ "$CAP_COUNT" -eq 30 ]]; then
  ok "30-message cap enforced (got 30 lines from 50-message input)"
else
  bad "expected 30 lines, got $CAP_COUNT"
fi

echo ""
echo "=== test 4: empty input → empty output (not [parse error]) ==="
EMPTY_OUT=$(run_digest "")
if [[ -z "$EMPTY_OUT" ]]; then
  ok "empty input → empty output"
else
  bad "expected empty output, got: $(echo "$EMPTY_OUT" | head -1)"
fi
EMPTY_OUT2=$(run_digest "[]")
if [[ -z "$EMPTY_OUT2" ]]; then
  ok "empty JSON list → empty output"
else
  bad "expected empty output for [], got: $(echo "$EMPTY_OUT2" | head -1)"
fi

echo ""
echo "=== test 5: bot_id fallback when user missing ==="
BOT_MSGS=$'[{"bot_id":"B12345","text":"bot reply","ts":"1700000000.000100"}]'
BOT_OUT=$(run_digest "$BOT_MSGS")
if echo "$BOT_OUT" | grep -q "<B12345>"; then
  ok "bot_id used as user fallback"
else
  bad "expected <B12345> in output, got: $(echo "$BOT_OUT" | head -1)"
fi

echo ""
echo "=== test 6: negative control — '--' arg causes JSONDecodeError ==="
# This documents the bug we are testing for. If someone re-introduces the
# `--` separator in the invocation, this test fails and CI catches it.
if python3 -c "$PY_DIGEST_SCRIPT" -- "$MSGS" > "$TMPDIR/neg.out" 2>"$TMPDIR/neg.err"; then
  bad "negative control: '--' invocation unexpectedly succeeded (the bug should resurface if -- is re-added)"
else
  if grep -q "JSONDecodeError\|Expecting value" "$TMPDIR/neg.err"; then
    ok "negative control: '--' invocation produces JSONDecodeError as expected"
  else
    bad "negative control: '--' invocation failed but with wrong error: $(cat "$TMPDIR/neg.err" | head -1)"
  fi
fi

echo ""
echo "=== test 7: invocation line does NOT contain a '--' separator ==="
if echo "$INVOCATION" | grep -q -- "-- "; then
  bad "invocation line still contains a '--' separator: $INVOCATION"
else
  ok "invocation line is clean (no '--' separator)"
fi

echo ""
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
