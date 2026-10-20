#!/usr/bin/env bash
# check_pr_body_has_evidence.sh — Step 7 gate for pr-evidence-inbound-review
#
# Returns exit 0 if the PR body already references Slack file URLs or gist raw
# URLs (i.e. the dropped media is a confirmation, NOT new artifacts to commit).
# Returns exit 1 if the body has neither (i.e. the user dropped net-new evidence
# that needs to be committed under evidence/pr-NNNN/).
#
# Usage: bash check_pr_body_has_evidence.sh <owner/repo> <pr_number>

set -euo pipefail

REPO="${1:?owner/repo required, e.g. jleechanorg/worldarchitect.ai}"
PR="${2:?PR number required}"

body="$(gh pr view "$PR" --repo "$REPO" --json body --jq .body 2>/dev/null || echo '')"

if [[ -z "$body" ]]; then
  echo "FAIL: could not fetch body for $REPO#$PR" >&2
  exit 2
fi

slack_hits=$(printf '%s' "$body" | grep -ciE 'slack\.com/files|gist\.github|gist\.githubusercontent\.com' || true)
raw_hits=$(printf '%s' "$body" | grep -ciE 'raw/[0-9a-f]{40}/' || true)

echo "PR #$PR body scan:"
echo "  slack.com/files | gist.github | gist.githubusercontent.com : $slack_hits matches"
echo "  gist raw URLs (raw/<40hex>/)                              : $raw_hits matches"

if [[ "$slack_hits" -gt 0 || "$raw_hits" -gt 0 ]]; then
  echo "VERDICT: BODY_ALREADY_HAS_EVIDENCE (confirmation, do NOT commit binaries)"
  exit 0
else
  echo "VERDICT: BODY_MISSING_EVIDENCE (net-new, evidence/pr-$PR/ commit needed)"
  exit 1
fi
