#!/usr/bin/env bash
# cmux-terminal-review.sh — Inspect cmux workspaces + AO tmux sessions, emit a status report.
# Designed to run headless from cron (no_agent: true). Outputs markdown to stdout.
set -euo pipefail

# ── Socket discovery ────────────────────────────────────────────────
SOCKET=""
CANDIDATE="${CMUX_SOCKET_PATH:-}"
if [ -n "$CANDIDATE" ] && [ -S "$CANDIDATE" ]; then
  SOCKET="$CANDIDATE"
fi
if [ -z "$SOCKET" ]; then
  for d in /private/tmp /tmp "$HOME/Library/Application Support/cmux"; do
    for s in "$d"/cmux*.sock "$d"/cmux.sock; do
      if [ -S "$s" ]; then
        SOCKET="$s"
        break 2
      fi
    done
  done
fi

if [ -z "$SOCKET" ]; then
  echo "ERROR: no cmux socket found"
  exit 1
fi

export CMUX_SOCKET_PATH="$SOCKET"

# ── RPC helper ─────────────────────────────────────────────────────
rpc_call() {
  local method="$1"
  local params="${2:-{}}"
  timeout 5 bash -c "echo '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}' | nc -w 3 -U '$SOCKET'" 2>/dev/null || true
}

# ── Workspace list via RPC ─────────────────────────────────────────
WS_JSON=$(rpc_call "workspace.list" '{}' 2>/dev/null)

if [ -z "$WS_JSON" ]; then
  echo "ERROR: cmux socket found but no RPC response"
  exit 1
fi

# Parse workspace count

WS_COUNT=$(echo "$WS_JSON" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(len(d.get('result', d).get('workspaces', [])))
except: print(0)
" 2>/dev/null || echo "0")

# ── Surface capture per workspace ───────────────────────────────────
SURFACE_LINES=""
for ws_ref in $(echo "$WS_JSON" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    for ws in d.get('result', d).get('workspaces', []):
        print(ws.get('ref', ''))
except: pass
" 2>/dev/null); do
  [ -z "$ws_ref" ] && continue
  # Get surfaces for this workspace
  SURF_JSON=$(rpc_call "workspace.surfaces" "{\"workspace_ref\":\"$ws_ref\"}" 2>/dev/null)
  if [ -n "$SURF_JSON" ]; then
    SURF_INFO=$(echo "$SURF_JSON" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    surfaces = d.get('result', d).get('surfaces', [])
    for s in surfaces:
        stype = s.get('surface_type', '?')
        cmd = s.get('shell', {}).get('command', '') or s.get('detail', '')
        short_cmd = (cmd[:60] + '...') if len(cmd) > 60 else cmd
        ref = s.get('ref', '?')
        print(f'    {ref:10s} [{stype}] {short_cmd}')
except: pass
" 2>/dev/null || true)
    if [ -n "$SURF_INFO" ]; then
      # Get workspace title from WS_JSON
      WS_TITLE=$(echo "$WS_JSON" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    for ws in d.get('result', d).get('workspaces', []):
        if ws.get('ref') == '$ws_ref':
            print(ws.get('title', '?'))
            break
except: pass
" 2>/dev/null || echo "?")
      SURFACE_LINES="${SURFACE_LINES}  **${WS_TITLE}** ($ws_ref)
${SURF_INFO}
"
    fi
  fi
done

# ── tmux sessions (AO workers) ────────────────────────────────────
TMUX_OUT=""
if command -v tmux &>/dev/null; then
  TMUX_RAW=$(timeout 5 tmux list-sessions -F '#{session_name}: #{session_windows} windows' 2>/dev/null || true)
  if [ -n "$TMUX_RAW" ]; then
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      sname=$(echo "$line" | cut -d: -f1)
      # Quick pane capture with timeout
      pane_ctx=$(timeout 3 tmux capture-pane -t "$sname" -p 2>/dev/null | grep -v '^$' | tail -1 || true)
      if [ -n "$pane_ctx" ]; then
        # Truncate long lines
        short_ctx=$(echo "$pane_ctx" | cut -c1-80)
        TMUX_OUT="${TMUX_OUT}  ${sname}: ${short_ctx}
"
      else
        TMUX_OUT="${TMUX_OUT}  ${sname}: (no output)
"
      fi
    done <<< "$TMUX_RAW"
  fi
fi

# ── Categorize ─────────────────────────────────────────────────────
HEALTHY=""
RISKY=""
BLOCKED=""

# Classify workspaces by surface activity
while IFS= read -r line; do
  [ -z "$line" ] && continue
  if echo "$line" | grep -qiE 'active|working|teammate|spawn|push|commit|compil|build|test'; then
    HEALTHY="${HEALTHY}${line}
"
  elif echo "$line" | grep -qiE 'error|fail|stuck|crash|frozen|hang|block'; then
    BLOCKED="${BLOCKED}${line}
"
  else
    RISKY="${RISKY}${line}
"
  fi
done <<< "$SURFACE_LINES"

# ── Emit report ────────────────────────────────────────────────────
cat <<EOF
🖥️ **cmux Terminal Review** — $(date '+%Y-%m-%d %H:%M %Z')
_Socket: \`${SOCKET}\` • ${WS_COUNT} workspaces_

**Healthy** 🟢
$(echo "${HEALTHY:-  (none)}" | sed '/^$/d')

**Risky** 🟡
$(echo "${RISKY:-  (none)}" | sed '/^$/d')

**Blocked** 🔴
$(echo "${BLOCKED:-  (none)}" | sed '/^$/d')

**AO tmux sessions**
$(echo "${TMUX_OUT:-  (none running)}" | sed '/^$/d')

**Next actions**
$(if [ -n "$BLOCKED" ]; then echo "  — Investigate blocked sessions above"; fi)
$(if [ -z "$TMUX_OUT" ] && [ "$WS_COUNT" -eq 0 ]; then echo "  — No active terminals found"; fi)
EOF
