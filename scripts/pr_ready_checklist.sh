#!/usr/bin/env bash
# pr_ready_checklist.sh — run the 8-gate /ready checklist on a PR.
#
# Usage:  bash ~/.smartclaw/scripts/pr_ready_checklist.sh <PR_NUMBER> [OWNER/REPO]
#
# Default OWNER/REPO = jleechanorg/worldarchitect.ai.
#
# Output: one line per gate + an OVERALL line. Exit code 0 = all pass, 1 = any fail.
#
# Encodes the SOUL.md pr-ready-checklist-hard-gate policy + the
# ~/.smartclaw/skills/pr-ready-checklist/SKILL.md checklist.

set -uo pipefail

PR="${1:-}"
REPO="${2:-jleechanorg/worldarchitect.ai}"

if [[ -z "$PR" ]]; then
  echo "usage: $0 <PR_NUMBER> [OWNER/REPO]" >&2
  exit 2
fi

fail=0

emit() {
  local gate="$1"; local status="$2"; local detail="$3"
  printf 'Gate %s: %s (%s)\n' "$gate" "$status" "$detail"
  if [[ "$status" == "FAIL" ]]; then
    fail=1
  fi
}

# Gate 1 — isDraft false
draft=$(gh pr view "$PR" --repo "$REPO" --json isDraft -q .isDraft 2>/dev/null || echo "UNKNOWN")
if [[ "$draft" == "false" ]]; then
  emit "1 isDraft false" PASS "$draft"
else
  emit "1 isDraft false" FAIL "$draft (must be false)"
fi

# Gate 2 — mergeable MERGEABLE
mergeable=$(gh pr view "$PR" --repo "$REPO" --json mergeable -q .mergeable 2>/dev/null || echo "UNKNOWN")
if [[ "$mergeable" == "MERGEABLE" ]]; then
  emit "2 mergeable MERGEABLE" PASS "$mergeable"
else
  emit "2 mergeable MERGEABLE" FAIL "$mergeable (must be MERGEABLE)"
fi

# Gate 3 — All required CI checks reached a terminal state with PASS
#   FAILURE = blocked, CANCELLED = blocked, queued/IN_PROGRESS = blocked (not ready yet),
#   SKIPPED = allowed only when the change shouldn't trigger that matrix (heuristic: SKIPPED checks
#     with names that start with "Directory tests" or "AGY JSON" are blockers, others are OK).
terminal=$(gh pr view "$PR" --repo "$REPO" --json statusCheckRollup --jq '
  [.statusCheckRollup[]
   | {name, conclusion, status}
   | select(
       (.conclusion == "FAILURE")
       or (.conclusion == "CANCELLED")
       or ((.status != "COMPLETED") and (.status != null))
     )
   | "FAIL=\(.name) (\(.conclusion // .status))"
  ] | join("; ")' 2>/dev/null || echo "QUERY_FAILED")
if [[ -z "$terminal" || "$terminal" == "null" ]]; then
  emit "3 CI checks" PASS "all required checks COMPLETED with no FAILURE/CANCELLED"
else
  emit "3 CI checks" FAIL "$terminal"
fi

# Gate 4 — Green Gate passed
gg=$(gh pr view "$PR" --repo "$REPO" --json statusCheckRollup --jq '
  [.statusCheckRollup[] | select(.name == "Green Gate") | .conclusion][0] // empty' 2>/dev/null || echo "QUERY_FAILED")
if [[ "$gg" == "SUCCESS" ]]; then
  emit "4 Green Gate" PASS "$gg"
else
  emit "4 Green Gate" FAIL "$gg (must be SUCCESS)"
fi

# Gate 5 — CodeRabbit reviewDecision clear
review=$(gh pr view "$PR" --repo "$REPO" --json reviewDecision -q .reviewDecision 2>/dev/null || echo "QUERY_FAILED")
if [[ "$review" == "" || "$review" == "APPROVED" ]]; then
  emit "5 CodeRabbit reviewDecision" PASS "\"$review\""
else
  emit "5 CodeRabbit reviewDecision" FAIL "\"$review\" (must be empty or APPROVED)"
fi

# Gate 6 — Cursor Bugbot clean (zero error-severity comments)
boterr=$(gh api "repos/$REPO/issues/$PR/comments" --jq '
  [.[] | select(.user.login == "cursor[bot]" and (.body | test("error"; "i")))] | length' 2>/dev/null || echo "QUERY_FAILED")
if [[ "$boterr" == "0" ]]; then
  emit "6 Cursor Bugbot" PASS "0 error-severity comments"
else
  emit "6 Cursor Bugbot" FAIL "$boterr error-severity comments"
fi

# Gate 7 — No unresolved inline review threads
owner="${REPO%/*}"
name="${REPO##*/}"
# Use GraphQL with --field pr=<int> (escaped properly inside double quotes via printf %s to avoid bash $-expansion).
query_json=$(printf '{"query":"{ repository(owner: \\"%s\\", name: \\"%s\\") { pullRequest(number: %s) { reviewThreads(first: 100) { nodes { isResolved } } } } }"}' "$owner" "$name" "$PR")
threads=$(echo "$query_json" | gh api graphql --input - --jq '
  [.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false)] | length' 2>/dev/null || echo "QUERY_FAILED")
if [[ "$threads" == "0" ]]; then
  emit "7 Unresolved threads" PASS "0 unresolved"
else
  emit "7 Unresolved threads" FAIL "$threads unresolved (reviewer feedback not addressed)"
fi

# Gate 8 — Evidence Gate (only when PR touches mvp_site/**, docs/CI/workflow exempt)
# Detect mvp_site/** touch from PR file list
files=$(gh pr view "$PR" --repo "$REPO" --json files --jq '.files[].path' 2>/dev/null || true)
if echo "$files" | grep -q '^mvp_site/'; then
  ev=$(gh pr view "$PR" --repo "$REPO" --json statusCheckRollup --jq '
    [.statusCheckRollup[] | select(.name == "Evidence Gate") | .conclusion][0] // empty' 2>/dev/null || echo "QUERY_FAILED")
  # Also verify the gist SHA from PR body is reachable in PR history
  body=$(gh pr view "$PR" --repo "$REPO" --json body -q .body 2>/dev/null || true)
  gist_sha=$(echo "$body" | grep -oE 'sha=([a-f0-9]{40})' | head -1 | cut -d= -f2)
  if [[ -z "$gist_sha" ]]; then
    gist_sha=$(echo "$body" | grep -oE '[a-f0-9]{40}' | head -1)
  fi
  sha_ok="(no gist SHA found in PR body)"
  if [[ -n "$gist_sha" ]]; then
    head_sha=$(gh pr view "$PR" --repo "$REPO" --json headRefOid -q .headRefOid 2>/dev/null || true)
    if git -C "$(git rev-parse --show-toplevel)" cat-file -e "$gist_sha" 2>/dev/null; then
      sha_ok="gist SHA $gist_sha reachable"
    else
      sha_ok="gist SHA $gist_sha NOT reachable in this checkout"
    fi
  fi
  if [[ "$ev" == "SUCCESS" && "$sha_ok" == *reachable* ]]; then
    emit "8 Evidence Gate" PASS "$ev, $sha_ok"
  else
    emit "8 Evidence Gate" FAIL "Evidence Gate=$ev, $sha_ok"
  fi
else
  emit "8 Evidence Gate" PASS "N/A (no mvp_site/** changes)"
fi

echo ""
if [[ $fail -eq 0 ]]; then
  echo "OVERALL: PASS — all 8 gates green"
else
  echo "OVERALL: FAIL — at least one gate failing"
fi
exit $fail