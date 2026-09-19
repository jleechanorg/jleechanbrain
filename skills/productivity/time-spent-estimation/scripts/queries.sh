#!/bin/bash
# Canonical queries for time-spent estimation.
# Run as: bash scripts/queries.sh [DAYS=14]
# Outputs a per-day breakdown across Slack, calendar, Gmail, Claude history, beads.

DAYS="${1:-14}"
CUTOFF=$(date -v "-${DAYS}d" +%s 2>/dev/null || date -d "-${DAYS} days" +%s)

echo "=== Window: last ${DAYS} days (cutoff ts=${CUTOFF}) ==="
echo

echo "## 1. Slack/Hermes active user-hours (per source per day)"
echo "   Math: max(messages.timestamp) - min(user_msg.timestamp) per session, sum per day"
sqlite3 ~/.smartclaw/state.db "
WITH sess_bounds AS (
  SELECT s.id as sid, s.source, s.chat_id, s.display_name, s.title,
         date(s.started_at,'unixepoch') as day,
         s.started_at as start_ts,
         (SELECT max(timestamp) FROM messages WHERE session_id=s.id) as last_msg_ts,
         (SELECT min(timestamp) FROM messages WHERE session_id=s.id AND role='user') as first_user_ts,
         (SELECT max(timestamp) FROM messages WHERE session_id=s.id AND role='user') as last_user_ts
  FROM sessions s
  WHERE s.started_at > ${CUTOFF}
)
SELECT day, source, count(*) as sessions,
       round(sum(last_user_ts - first_user_ts)/3600.0, 1) as user_active_h,
       round(avg(last_user_ts - first_user_ts)/60.0, 1) as avg_session_min
FROM sess_bounds
WHERE last_msg_ts > start_ts AND last_user_ts > first_user_ts
GROUP BY day, source
ORDER BY day DESC, source;
"
echo

echo "## 2. Per-channel breakdown (Slack, last ${DAYS}d)"
sqlite3 ~/.smartclaw/state.db "
SELECT chat_id, display_name, count(*) as sessions,
       round(sum(user_active_h),1) as total_h
FROM (
  SELECT s.chat_id, s.display_name, s.id,
         (julianday(max(m.timestamp))-julianday(min(m.timestamp)))*24 as user_active_h
  FROM sessions s JOIN messages m ON m.session_id=s.id
  WHERE s.source='slack' AND s.started_at > ${CUTOFF} AND m.role='user'
  GROUP BY s.id
)
GROUP BY chat_id
ORDER BY total_h DESC
LIMIT 20;
"
echo

echo "## 3. Per-day user-msg volume (filter compaction spikes)"
sqlite3 ~/.smartclaw/state.db "
SELECT date(timestamp,'unixepoch') as day, count(*) as user_msgs,
       count(DISTINCT session_id) as sessions
FROM messages
WHERE role='user' AND timestamp > ${CUTOFF}
GROUP BY day
HAVING user_msgs < 5000  -- filter 07-31-style compaction spikes
ORDER BY day DESC;
"
echo

echo "## 4. Calendar events next ${DAYS}d (gmail account, junk-filtered)"
gog calendar events --days ${DAYS} -j -a jleechan@gmail.com 2>/dev/null \
  | python3 -c "
import json, sys
from datetime import datetime
data = json.loads(sys.stdin.read())
events = data.get('events', [])
total_min = 0
for e in events:
    s = e.get('start', {}).get('dateTime') or e.get('start', {}).get('date')
    ed = e.get('end', {}).get('dateTime') or e.get('end', {}).get('date')
    summary = (e.get('summary') or '(no title)')[:55]
    if s and ed and 'T' in s:
        try:
            sdt = datetime.fromisoformat(s.replace('Z','+00:00'))
            edt = datetime.fromisoformat(ed.replace('Z','+00:00'))
            dur_min = (edt - sdt).total_seconds()/60
            # Filter multi-day carry-forward junk (anything > 24h)
            if dur_min > 1440:
                print(f'  [JUNK-FILTERED] {dur_min/60:.0f}h  {summary}')
                continue
            total_min += dur_min
            print(f'  {sdt.strftime(\"%m-%d %H:%M\")}  {dur_min:5.0f}m  {summary}')
        except Exception as ex:
            print(f'  parse-err: {s} {ex}')
print(f'TOTAL real meeting time: {total_min/60:.1f}h across {len(events)} events')
"
echo

echo "## 5. Gmail volume last ${DAYS}d"
gog gmail search "newer_than:${DAYS}d" --max 500 -j -a jleechan@gmail.com 2>/dev/null \
  | python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
items = data.get('threads') or data.get('messages') or []
print(f'  total: {len(items) if isinstance(items, list) else 0} threads/msgs')
print(f'  est. time budget: {len(items)*3/60:.1f}h at ~3 min/message (reading+reply)')
"
echo

echo "## 6. Claude Code session history (file count + line count last ${DAYS}d)"
find ~/.claude/projects/-Users-jleechan -name "*.jsonl" -mtime -${DAYS} \
  -exec wc -l {} \; 2>/dev/null | awk '{sum+=$1; n+=1} END {print "  files:", n, " lines:", sum}'
echo

echo "## 7. Beads backlog snapshot"
br list --status open --limit 50 --json 2>/dev/null \
  | python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
items = data.get('issues', [])
print(f'  open beads: {len(items)}')
by_pri = {}
for it in items:
    p = it.get('priority', '?')
    by_pri[p] = by_pri.get(p, 0) + 1
for p, c in sorted(by_pri.items()):
    print(f'    P{p}: {c}')
"
echo
echo "=== Done ==="
