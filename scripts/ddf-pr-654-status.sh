#!/bin/bash
# One-shot status reader for PR #654 / bead dark-factory-qyze.
# Posts a compact Slack reply in the originating thread.
set -euo pipefail

CHANNEL="C0AH3RY3DK6"
THREAD_TS="1787112356.555659"
PR_NUM=654
REPO="jleechanorg/dark-factory"
BEAD="dark-factory-qyze"

PR_JSON=$(gh pr view "$PR_NUM" --repo "$REPO" --json number,state,mergeable,mergedAt,labels 2>&1)
MERGE_STATE=$(echo "$PR_JSON" | python3 -c "import sys, json; print(json.load(sys.stdin).get('state', '?'))")
MERGED_AT=$(echo "$PR_JSON" | python3 -c "import sys, json; print(json.load(sys.stdin).get('mergedAt') or '')")
LABELS=$(echo "$PR_JSON" | python3 -c "import sys, json; print(', '.join(l.get('name','') for l in json.load(sys.stdin).get('labels', [])))")

# Read the latest dev daemon events for the bead
BEAD_EVENTS=$(ssh jeff-ubuntu "tail -300 /home/jleechan/Library/Logs/dark-factory/daemon.jsonl 2>/dev/null | python3 -c \"
import sys, json
events = []
for l in sys.stdin:
    try: e = json.loads(l)
    except: continue
    bid = str(e.get('beadId', ''))
    if bid == '${BEAD}' or 'dark-factory#${PR_NUM}' in str(e) or '${PR_NUM}' in bid:
        summary = {k: e.get(k) for k in ['timestamp', 'eventType', 'beadId', 'lifecycleState']}
        ctx = e.get('context', {}) or {}
        if ctx.get('reason'):
            summary['reason'] = ctx['reason'][:80]
        events.append(summary)
for e in events[-8:]:
    print(json.dumps(e))
\" 2>&1")

# Read the bead's current state
BEAD_STATE=$(ssh jeff-ubuntu "cd /home/jleechan/.local/state/dark-factory/.beads/ && ~/.local/bin/br show ${BEAD} --json 2>&1" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    if isinstance(data, list) and data:
        d = data[0]
        print(f\"{d.get('status', '?')} | priority={d.get('priority', '?')} | external_ref={d.get('external_ref', '')}\")
except Exception as e:
    print(f'(parse error: {e})')
" 2>&1)

# Compose the message
if [ "$MERGE_STATE" = "MERGED" ]; then
    STATUS="✅ PR #${PR_NUM} is MERGED (${MERGED_AT}). Daemon will deploy on next release rollout."
elif [ "$MERGE_STATE" = "CLOSED" ]; then
    STATUS="⚠️ PR #${PR_NUM} is CLOSED. Bead may need to be re-filed."
else
    STATUS="⏳ PR #${PR_NUM} is OPEN, mergeable. Bead state: ${BEAD_STATE}."
fi

MSG="${STATUS}

_Labels_: ${LABELS}
_Bead events (latest 8)_:
\`\`\`
${BEAD_EVENTS}
\`\`\`"

# Post to Slack
curl -fsS -X POST "https://slack.com/api/chat.postMessage" \
    -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
    -H "Content-Type: application/json; charset=utf-8" \
    -d "$(python3 -c "
import json
print(json.dumps({
    'channel': '${CHANNEL}',
    'thread_ts': '${THREAD_TS}',
    'text': '''${MSG}'''
}))
")" >/dev/null
echo "Posted status to Slack thread"
