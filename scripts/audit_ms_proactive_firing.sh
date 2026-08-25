#!/usr/bin/env bash
# Audit /ms proactive firing rate across the last 7 days.
# Verifies that the `## COMMIT: ms-on-new-task` rule is actually firing.
# Run as part of `scripts/doctor.sh` and after each SOUL.md deploy.
#
# Returns exit 0 if firing rate >= 50%, exit 1 if < 50% (catches the under-fire regression).
# Adds a Signal E to autonomy-report.sh: flag any first reply with ≥1 tool call that doesn't
# include either `session_search` or `skill_view` (memory-search).
#
# Source: 2026-07-02 Slack C0AJ3SD5C79 ts 1783036536.864119 — user asked for this audit.

set -euo pipefail

DB="${HERMES_STATE_DB:-$HOME/.smartclaw/state.db}"
WINDOW_DAYS="${WINDOW_DAYS:-7}"
THRESHOLD_PCT="${THRESHOLD_PCT:-50}"

if [[ ! -f "$DB" ]]; then
  echo "ERROR: hermes state.db not found at $DB" >&2
  exit 2
fi

now_s=$(date +%s)
window_s=$((WINDOW_DAYS * 86400))
cutoff_s=$((now_s - window_s))

# Total sessions that used at least one tool in the window
total_sessions=$(sqlite3 -separator '|' "$DB" "
  SELECT COUNT(DISTINCT session_id) FROM messages
  WHERE role='tool' AND tool_name IS NOT NULL AND timestamp > $cutoff_s
")

# Sessions where the FIRST tool call was session_search OR skill_view
first_tool_search=$(sqlite3 -separator '|' "$DB" "
  WITH first_tool AS (
    SELECT session_id, MIN(id) AS first_id FROM messages
    WHERE role='tool' AND timestamp > $cutoff_s GROUP BY session_id
  )
  SELECT COUNT(*) FROM first_tool ft JOIN messages m ON m.id=ft.first_id
  WHERE m.tool_name='session_search' OR m.tool_name='skill_view'
")

# Sessions where the user explicitly typed /ms (canary — should track first_tool_search)
user_typed_ms=$(sqlite3 -separator '|' "$DB" "
  SELECT COUNT(DISTINCT session_id) FROM messages
  WHERE role='user' AND content LIKE '%/ms%' AND timestamp > $cutoff_s
")

# Sessions citing 🧠 Memories used:
cited=$(sqlite3 -separator '|' "$DB" "
  SELECT COUNT(DISTINCT session_id) FROM messages
  WHERE role='assistant' AND content LIKE '%Memories used:%' AND timestamp > $cutoff_s
")

# Citation-without-search: sessions that cited Memories used but never called session_search
fabrications=$(sqlite3 -separator '|' "$DB" "
  WITH citers AS (
    SELECT DISTINCT session_id FROM messages
    WHERE role='assistant' AND content LIKE '%Memories used:%' AND timestamp > $cutoff_s
  )
  SELECT COUNT(*) FROM citers c
  WHERE NOT EXISTS (
    SELECT 1 FROM messages m WHERE m.session_id=c.session_id AND m.tool_name='session_search'
  )
")

if [[ "$total_sessions" -gt 0 ]]; then
  firing_pct=$((first_tool_search * 100 / total_sessions))
else
  firing_pct=0
fi

printf "%-32s %d\n" "sessions_with_tools_7d:"      "$total_sessions"
printf "%-32s %d (%.1f%%)\n" "first_tool_was_search:"  "$first_tool_search" "$(echo "scale=1; $first_tool_search * 100 / $total_sessions" | bc 2>/dev/null || echo 0)"
printf "%-32s %d\n" "user_typed_ms_7d:"           "$user_typed_ms"
printf "%-32s %d\n" "cited_memories_used:"        "$cited"
printf "%-32s %d (FABRICATION RATE)\n" "cited_without_search:" "$fabrications"
printf "\nFiring-rate vs threshold: %d%% / %d%% (window=%dd)\n" "$firing_pct" "$THRESHOLD_PCT" "$WINDOW_DAYS"

if [[ "$firing_pct" -lt "$THRESHOLD_PCT" ]]; then
  echo ""
  echo "❌ FIRING RATE BELOW THRESHOLD ($firing_pct% < $THRESHOLD_PCT%)"
  echo "   The 'ms-on-new-task' COMMIT is under-firing."
  echo "   Common causes:"
  echo "   1. New runtime missing Hermes-side memory-search overlay (check ~/.smartclaw/skills/memory-search/SKILL.md)"
  echo "   2. SOUL.md wording reverted to 'judgment-based' exemption (must be 4-condition pattern)"
  echo "   3. Agent fabricated Memories used citation without prior session_search call"
  exit 1
fi

echo ""
echo "✅ Firing rate within threshold."
exit 0