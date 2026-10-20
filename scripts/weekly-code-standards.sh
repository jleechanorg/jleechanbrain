#!/bin/bash
# weekly-code-standards.sh — Tue 10:00 PT
# Runs the four-lane code-standards review (ponytail, ZFC, ZFC leveling, root-cause-first)
# against the set of PRs in jleechanorg/worldarchitect.ai that were opened or updated
# in the last 7 days, and writes a Markdown report to
# ${HOME}/.smartclaw/logs/scheduled-jobs/weekly-code-standards-report.md.
#
# No Slack delivery (read-only audit by design). The plist logs stdout to
# ${HOME}/.smartclaw/logs/scheduled-jobs/weekly-code-standards.out.log.
#
# Exit codes: 0 = success, 1 = gh failed, 2 = jq/json failed, 3 = report-write failed.
# ThrottleInterval=300s in the plist prevents launchd stampede if this hangs.

set -uo pipefail

LOG_DIR="${HOME}/.smartclaw/logs/scheduled-jobs"
mkdir -p "$LOG_DIR"
REPORT="$LOG_DIR/weekly-code-standards-report.md"
TMP="$(mktemp -t weekly-code-standards.XXXXXX)"
trap 'rm -f "$TMP"' EXIT

GH_TIMEOUT=20

if ! command -v gh >/dev/null 2>&1; then
  echo "$(date -u +%FT%TZ) FAIL: gh not on PATH" >> "$LOG_DIR/weekly-code-standards.err.log"
  exit 1
fi

# Verify gh auth (don't fail if not authed — just record and skip)
if ! gh auth status >/dev/null 2>&1; then
  echo "$(date -u +%FT%TZ) SKIP: gh not authed; nothing to review" >> "$REPORT"
  echo "# Weekly Code Standards — no gh auth" > "$REPORT"
  exit 0
fi

# Pull PRs updated in the last 7 days across the operator's main repos.
# Default scope: jleechanorg/worldarchitect.ai (operator's primary work repo).
# Other repos can be added later by extending REPOS.
REPOS=(
  "jleechanorg/worldarchitect.ai"
)

SINCE=$(date -u -v-7d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u --date='7 days ago' +%Y-%m-%dT%H:%M:%SZ)

{
  echo "# Weekly Code Standards Review — $(date -u +%FT%TZ)"
  echo ""
  echo "Schedule: **Tue 10:00 PT** (Weekday=2 in plist)"
  echo "Scope: PRs updated in last 7 days across: ${REPOS[*]}"
  echo "Skill: \`~/.claude/skills/code-standards/SKILL.md\` (4 lanes: ponytail, ZFC, ZFC leveling, root-cause-first)"
  echo ""
  echo "---"
  echo ""

  TOTAL_PRS=0
  DIRTY=0
  UNSTABLE=0
  CLEAN=0
  BLOCKED=0

  for repo in "${REPOS[@]}"; do
    echo "## Repo: \`$repo\`"
    echo ""

    # Pull PRs updated since $SINCE. Don't fail the whole script on one repo error.
    if ! PR_JSON=$(gh pr list --repo "$repo" --state all \
                    --search "updated:>=$SINCE" \
                    --json number,title,headRefName,state,mergeStateStatus,author,additions,changedFiles,updatedAt \
                    --limit 100 2>/dev/null); then
      echo "_gh query failed for $repo — skipping_"
      echo ""
      continue
    fi

    # PR_JSON is a JSON array on stdout; write to TMP for stable processing.
    printf '%s' "$PR_JSON" > "$TMP"

    if ! jq -e 'type == "array"' "$TMP" >/dev/null 2>&1; then
      echo "_jq parse failed for $repo — skipping_"
      echo ""
      continue
    fi

    COUNT=$(jq 'length' "$TMP")
    TOTAL_PRS=$((TOTAL_PRS + COUNT))
    if [ "$COUNT" = "0" ]; then
      echo "_No PRs updated in last 7 days._"
      echo ""
      continue
    fi

    # Bucket by merge state
    echo "**$COUNT PRs** updated in last 7 days."
    echo ""

    # Group by mergeStateStatus
    jq -r 'group_by(.mergeStateStatus) | .[] | "### \(.[0].mergeStateStatus // "UNKNOWN") (\(length))"' "$TMP"
    echo ""

    # Per-PR row with the 4-lane summary placeholder.
    # Real review happens when operator runs /code-standards on a specific PR;
    # this weekly job just inventories which PRs are open and what state they're in.
    jq -r '.[] | "| #\(.number) [\(.mergeStateStatus // "?")] +\(.additions)/\(.changedFiles)f | \(.title | gsub("[\\|]"; "\\\\|") | .[0:90]) |" ' "$TMP"
    echo ""

    # Tally
    DIRTY=$((DIRTY + $(jq '[.[] | select(.mergeStateStatus == "DIRTY")] | length' "$TMP")))
    UNSTABLE=$((UNSTABLE + $(jq '[.[] | select(.mergeStateStatus == "UNSTABLE")] | length' "$TMP")))
    CLEAN=$((CLEAN + $(jq '[.[] | select(.mergeStateStatus == "CLEAN")] | length' "$TMP")))
    BLOCKED=$((BLOCKED + $(jq '[.[] | select(.mergeStateStatus == "BLOCKED")] | length' "$TMP")))

    echo ""
  done

  echo "---"
  echo ""
  echo "## Tally"
  echo ""
  echo "| State | Count |"
  echo "|---|---|"
  echo "| DIRTY | $DIRTY |"
  echo "| UNSTABLE | $UNSTABLE |"
  echo "| CLEAN | $CLEAN |"
  echo "| BLOCKED | $BLOCKED |"
  echo "| **Total reviewed** | **$TOTAL_PRS** |"
  echo ""

  echo "## Next steps"
  echo ""
  echo "1. Pick any **DIRTY** PR (highest signal) and run \`/code-standards <PR>\`."
  echo "2. For **BLOCKED** PRs, check upstream merge-conflict status with \`gh pr view <N> --json mergeStateStatus\`."
  echo "3. **UNSTABLE** PRs likely have failing CI — check \`gh pr checks <N>\`."
  echo "4. Skip **CLEAN** PRs (already mergeable)."
  echo ""
  echo "_This report is read-only. It does NOT post to Slack. To act, run \`/code-standards <PR>\` manually._"
  echo ""

} > "$REPORT" 2>>"$LOG_DIR/weekly-code-standards.err.log"

RC=$?
if [ "$RC" -ne 0 ]; then
  echo "$(date -u +%FT%TZ) FAIL exit=$RC — see $REPORT and $LOG_DIR/weekly-code-standards.err.log" >> "$LOG_DIR/weekly-code-standards.err.log"
  exit "$RC"
fi

echo "$(date -u +%FT%TZ) OK — wrote $REPORT ($(wc -c < "$REPORT" | tr -d ' ') bytes)" >> "$LOG_DIR/weekly-code-standards.out.log"
exit 0
