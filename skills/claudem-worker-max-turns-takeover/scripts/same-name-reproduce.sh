#!/usr/bin/env bash
# Verify a failing CI test reproduces byte-identically on origin/main HEAD.
# Use this BEFORE dismissing a PR failure as pre-existing.
#
# Usage: scripts/same-name-reproduce.sh <pr-number> <pytest-node-id>
#   pr-number: e.g. 8829
#   pytest-node-id: e.g. mvp_site/tests/test_streaming_orchestrator.py::TestStreamingRawRequestPayloadPopulated::test_error_path_populates_payload_when_bq_enabled
#
# Output: PASS if the test fails with byte-identical traceback on origin/main HEAD,
# FAIL if it passes on origin/main HEAD (then it IS a real PR regression).
# Side effect: creates /tmp/wa-baseline-pr<PR> worktree + venv (auto-cleaned at end).

set -euo pipefail

PR_NUMBER="${1:?usage: same-name-reproduce.sh <pr-number> <pytest-node-id>}"
TEST_NODE="${2:?usage: same-name-reproduce.sh <pr-number> <pytest-node-id>}"

REPO_ROOT="${HOME}/projects/worldarchitect.ai"
BASELINE_WT="/tmp/wa-baseline-pr${PR_NUMBER}"

cleanup() {
  rm -rf "$BASELINE_WT" 2>/dev/null || true
}
trap cleanup EXIT

echo "=== Capturing PR-side traceback ==="
cd "$REPO_ROOT"
PR_TRACE=$(./venv/bin/python -m pytest "$TEST_NODE" --tb=long 2>&1 | tail -50 || true)
echo "$PR_TRACE" | tail -10

echo
echo "=== Reproducing on origin/main HEAD ==="
git worktree add "$BASELINE_WT" origin/main >/dev/null 2>&1
cd "$BASELINE_WT"
python3 -m venv venv >/dev/null 2>&1
./venv/bin/pip install --quiet -r mvp_site/requirements.txt >/dev/null 2>&1
BASELINE_TRACE=$(./venv/bin/python -m pytest "$TEST_NODE" --tb=long 2>&1 | tail -50 || true)
echo "$BASELINE_TRACE" | tail -10

echo
echo "=== Diffing (PR-side vs origin/main) ==="
if diff <(echo "$PR_TRACE") <(echo "$BASELINE_TRACE") >/dev/null; then
  echo "✅ SAME-NAME PASS: traceback is byte-identical. Pre-existing on origin/main. Safe to dismiss per qa-test-failure-dismissal-anti-pattern (4/4 checks pass)."
  exit 0
else
  echo "❌ DIFFERENT tracebacks. This is a real regression introduced by the PR — do NOT dismiss."
  diff <(echo "$PR_TRACE") <(echo "$BASELINE_TRACE") | head -40
  exit 1
fi
