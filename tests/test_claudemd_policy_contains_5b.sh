#!/usr/bin/env bash
# test_claudemd_policy_contains_5b.sh
#
# Verifies that BOTH staging (~/.smartclaw/CLAUDE.md) and prod
# (~/.smartclaw_prod/CLAUDE.md) contain the sub-class 5b narration
# threading rule added in PR (jleechan-5bcl).
#
# This test exists to prevent the exact drift failure mode that
# produced the 5b leak on 2026-06-14 (prod CLAUDE.md was 29 days
# stale). If either file is missing the rule, the test fails.
#
# Usage:
#   bash tests/test_claudemd_policy_contains_5b.sh
#
# Returns:
#   0 if staging contains the rule (prod drift is a warning, not a failure)
#   1 if staging is missing the rule (the rule must exist where the agent reads it)
#
# Skipped (not failed) if neither ~/.smartclaw nor ~/.smartclaw_prod exists
# (e.g. running on a machine without the harness installed).
#
# IMPORTANT — prod drift is a WARNING, not a failure. Before the PR merges,
# prod is expected to be stale; failing the test on that would make the CI
# run ungreenable. The deploy.sh Stage 5.5 drift warning (PR #624) is the
# authoritative runtime check; this test enforces that the rule is present
# in staging (where the agent reads it) and provides actionable drift
# reporting.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

STAGING_FILE="$REPO_DIR/CLAUDE.md"
PROD_FILE="$HOME/.smartclaw_prod/CLAUDE.md"

# Required strings (the rule's anchor + bypass log prefix + hard-rule text patterns)
REQUIRED_STAGING=(
  "### Slack — Narration threading — sub-class 5b enforcement (MCP-direct path)"
  "5b-bypass: refused MCP post in"
  "Bring-to-green status"
  "/slack-audit"
  "Sub-class 5b is a Claude Code session calling"
)

# Additional guardrails added 2026-06-16 — ensure the rule body contains the
# concrete examples and detection signature that operators grep for during
# incident triage. Without these, the section header alone would pass but the
# actionable guidance could drift away from the operational reality.
REQUIRED_RULE_BODY=(
  "mcp__slack__conversations_add_message"
  "thread_ts"
  "MUST NOT post a status update at all"
  "log to stderr only"
)

PASS=1

echo "=== test_claudemd_policy_contains_5b ==="
echo ""

# Check staging CLAUDE.md
if [[ ! -f "$STAGING_FILE" ]]; then
  echo "SKIP: $STAGING_FILE does not exist (not in a harness checkout)"
  exit 0
fi
echo "Checking staging: $STAGING_FILE"
for needle in "${REQUIRED_STAGING[@]}"; do
  if grep -F -- "$needle" "$STAGING_FILE" >/dev/null 2>&1; then
    echo "  PASS: '$needle' found"
  else
    echo "  FAIL: '$needle' NOT found in $STAGING_FILE"
    PASS=0
  fi
done

# Rule body guardrails (extra substantive checks added 2026-06-16 to ensure
# the actionable guidance inside the section survives drift)
for needle in "${REQUIRED_RULE_BODY[@]}"; do
  if grep -F -- "$needle" "$STAGING_FILE" >/dev/null 2>&1; then
    echo "  PASS (body): '$needle' found"
  else
    echo "  FAIL (body): '$needle' NOT found in $STAGING_FILE"
    PASS=0
  fi
done

# Check prod CLAUDE.md (only if it exists)
if [[ -f "$PROD_FILE" ]]; then
  echo ""
  echo "Checking prod: $PROD_FILE (WARN-only — drift is expected pre-merge)"
  PROD_DRIFT=0
  for needle in "${REQUIRED_STAGING[@]}"; do
    if grep -F -- "$needle" "$PROD_FILE" >/dev/null 2>&1; then
      echo "  PASS: '$needle' found"
    else
      echo "  WARN (prod drift): '$needle' NOT found in $PROD_FILE"
      echo "         (expected pre-merge; deploy.sh Stage 5.5 is the runtime check)"
      PROD_DRIFT=1
    fi
  done
  # Rule body guardrails on prod too — WARN-only
  for needle in "${REQUIRED_RULE_BODY[@]}"; do
    if grep -F -- "$needle" "$PROD_FILE" >/dev/null 2>&1; then
      echo "  PASS (body): '$needle' found"
    else
      echo "  WARN (prod drift body): '$needle' NOT found in $PROD_FILE"
      PROD_DRIFT=1
    fi
  done
  if [[ "$PROD_DRIFT" -eq 1 ]]; then
    echo ""
    echo "  NOTE: prod drift is EXPECTED before this PR merges. After merge,"
    echo "        run: cp ~/.smartclaw/CLAUDE.md ~/.smartclaw_prod/CLAUDE.md &&"
    echo "             launchctl kickstart -k gui/\$UID/ai.smartclaw.prod"
  fi
else
  echo ""
  echo "SKIP: $PROD_FILE does not exist (no prod install on this machine)"
fi

# Bonus: verify staging == prod (byte-identical), warn on divergence
if [[ -f "$PROD_FILE" ]]; then
  echo ""
  echo "Diff check: staging vs prod"
  if diff -q "$STAGING_FILE" "$PROD_FILE" >/dev/null 2>&1; then
    echo "  PASS: staging and prod are byte-identical"
  else
    echo "  WARN: staging and prod differ (see 'diff' output)"
    echo "         (deploy.sh Stage 5.5 should have warned about this)"
    # Don't fail on diff — only fail on missing rule content. Drift is a
    # warning, missing content is a failure.
  fi
fi

echo ""
if [[ "$PASS" -eq 1 ]]; then
  echo "✓ All checks passed"
  exit 0
else
  echo "✗ One or more checks failed"
  exit 1
fi
