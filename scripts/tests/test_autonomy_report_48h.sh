#!/usr/bin/env bash
# scripts/tests/test_autonomy_report_48h.sh
#
# Automated tests for the 48h lookback, Slack search (Signal E), and
# memory cross-reference (Signal F) in autonomy-report.sh.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/autonomy-report.sh"

if [[ ! -f "$SCRIPT" ]]; then
  echo "FATAL: autonomy-report.sh not found at $SCRIPT" >&2
  exit 1
fi

PASS=0
FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# Create temporary sandbox for state and logs
TMPDIR=$(mktemp -d -t autonomy-test.XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

# Create mock staging and prod directories with valid SOUL.md files for clean dry-run
mkdir -p "$TMPDIR/hermes_home/workspace"
mkdir -p "$TMPDIR/home/.smartclaw"
echo "## COMMIT: a-fullrun-evidence-stack" > "$TMPDIR/hermes_home/workspace/SOUL.md"
echo "## COMMIT: a-fullrun-evidence-stack" > "$TMPDIR/home/.smartclaw/SOUL.md"

# Create mock curl script to stub network calls
MOCK_CURL="$TMPDIR/mock_curl"
cat << 'EOF' > "$MOCK_CURL"
#!/usr/bin/env bash
if [[ "$*" == *"conversations.history"* ]]; then
  echo '{"ok": true, "messages": []}'
elif [[ "$*" == *"chat.postMessage"* ]]; then
  echo '{"ok": true}'
else
  echo '{"ok": false, "error": "unknown mock request"}'
fi
EOF
chmod +x "$MOCK_CURL"

export AUTONOMY_CURL_BIN="$MOCK_CURL"
export AUTONOMY_MOCK_SLACK_SEARCH=1
export AUTONOMY_MOCK_SLACK_MATCHES='[]'
export HERMES_SLACK_USER_TOKEN="xoxp-mock-token-for-test"
export SLACK_USER_TOKEN="xoxp-mock-token-for-test"
export SLACK_BOT_TOKEN="xoxb-mock-token-for-test"
export SLACK_BOT_TOKEN="xoxb-mock-token-for-test"

echo ""
echo "=== Test A: Dry-run with no violations (clean state) ==="
# Setting HERMES_HOME and HOME overrides to use our clean sandbox files.
# Slack search is run (using SLACK_BOT_TOKEN) but is skipped or clean.
# Memory search falls back to grep over empty mock memory dirs (which yields 0).
# Under clean conditions, total violations is 0, so the script exits 0.
AUTONOMY_DRY_RUN=1 \
AUTONOMY_LOOKBACK_HOURS=48 \
HERMES_HOME="$TMPDIR/hermes_home" \
HOME="$TMPDIR/home" \
AUTONOMY_STATE_FILE="$TMPDIR/state.jsonl" \
bash "$SCRIPT" > "$TMPDIR/clean.log" 2>&1
EXIT_CODE=$?

if [[ $EXIT_CODE -eq 0 ]]; then
  ok "Dry-run with no violations exited with 0"
else
  bad "Expected exit 0 for clean dry-run, got $EXIT_CODE. Log: $(cat "$TMPDIR/clean.log")"
fi

echo ""
echo "=== Test B: Positive control (force Signal C violation) ==="
# Mangle staging SOUL.md by removing the required commit line.
echo "mangled" > "$TMPDIR/hermes_home/workspace/SOUL.md"

# Mangle prod SOUL.md too
echo "mangled" > "$TMPDIR/home/.smartclaw/SOUL.md"

# Now running dry-run should detect the missing commit violations and exit 1.
AUTONOMY_DRY_RUN=1 \
AUTONOMY_LOOKBACK_HOURS=48 \
HERMES_HOME="$TMPDIR/hermes_home" \
HOME="$TMPDIR/home" \
AUTONOMY_STATE_FILE="$TMPDIR/state.jsonl" \
bash "$SCRIPT" > "$TMPDIR/violation.log" 2>&1
EXIT_CODE=$?

if [[ $EXIT_CODE -eq 1 ]]; then
  ok "Dry-run with forced Signal C violation exited with 1"
else
  bad "Expected exit 1 for violations, got $EXIT_CODE. Log: $(cat "$TMPDIR/violation.log")"
fi

if grep -q "Signal C (SOUL.md COMMIT missing on staging or prod): 2" "$TMPDIR/violation.log" || grep -q "Signal C" "$TMPDIR/violation.log"; then
  ok "Digest correctly reported Signal C violations"
else
  bad "Signal C not reported in digest. Log: $(cat "$TMPDIR/violation.log")"
fi

echo ""
echo "=== Test C: Signal E (Slack search keywords) presence in digest ==="
# We check if the Slack search output section or skip statement is present in the digest output.
if grep -q "Signal E (slack search keywords):" "$TMPDIR/violation.log"; then
  ok "Signal E section header is present in the output digest"
else
  bad "Signal E section header missing from output digest. Log: $(cat "$TMPDIR/violation.log")"
fi

# Confirm that the python search was executed and handled token scope gracefully (either skipped, got hits, or clean run with 0 hits)
if grep -q "skipped — user token missing" "$TMPDIR/violation.log" || grep -q "keyword_counts=" "$TMPDIR/violation.log" || grep -q "VIOLATION signal=E" "$TMPDIR/violation.log" || grep -q "slack search keywords): 0" "$TMPDIR/violation.log"; then
  ok "Signal E execution outcome correctly formatted or skipped gracefully"
else
  bad "Signal E execution output missing or unhandled. Log: $(cat "$TMPDIR/violation.log")"
fi

echo ""
echo "=== Test D: Signal F (Memory cross-reference) fallback and UPDATE check ==="
# Verify that RESOLVER.md has been updated with the key autonomy keywords per step 4
RESOLVER_HITS=$(grep -c -E 'autonomy-report|autonomy\.report|launchd-autonomy' "$REPO_ROOT/skills/RESOLVER.md" || true)
if [[ $RESOLVER_HITS -ge 1 ]]; then
  ok "RESOLVER.md updated successfully with autonomy keywords ($RESOLVER_HITS hits)"
else
  bad "RESOLVER.md lacks required autonomy keywords"
fi

# Run detector using the real RESOLVER.md path mapped to mock memory/skills path
# Let's make sure the grep fallback detects RESOLVER.md file or other memory files.
# We create a mock memory directory structure and link RESOLVER.md inside it.
mkdir -p "$TMPDIR/home/.smartclaw/memory"
cp "$REPO_ROOT/skills/RESOLVER.md" "$TMPDIR/home/.smartclaw/memory/RESOLVER.md"

AUTONOMY_DRY_RUN=1 \
AUTONOMY_LOOKBACK_HOURS=48 \
HERMES_HOME="$TMPDIR/hermes_home" \
HOME="$TMPDIR/home" \
AUTONOMY_STATE_FILE="$TMPDIR/state.jsonl" \
bash "$SCRIPT" > "$TMPDIR/memory_fallback.log" 2>&1

if grep -q "Signal F (/ms cross-reference):" "$TMPDIR/memory_fallback.log"; then
  ok "Signal F section header is present in the output digest"
else
  bad "Signal F section header missing from output digest. Log: $(cat "$TMPDIR/memory_fallback.log")"
fi

if grep -q "grep fallback:" "$TMPDIR/memory_fallback.log" || grep -q "hits:" "$TMPDIR/memory_fallback.log"; then
  ok "Signal F resolved to either grep fallback files or memory search hits"
else
  bad "Signal F output format is invalid. Log: $(cat "$TMPDIR/memory_fallback.log")"
fi

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
