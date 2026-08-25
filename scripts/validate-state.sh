#!/usr/bin/env bash
# validate-state.sh — Validate the state of the Agent Orchestrator (AO).
#
# Emits a single verdict line in the format:
#   <STATE>: <Details>
# Where <STATE> is one of: IDLE, STALLED, HEALTHY
#
# Usage:
#   ./scripts/validate-state.sh [/path/to/worktree_or_session]

set -euo pipefail

TARGET_PATH="${1:-}"

# Resolve the canonical AO data directory (where running.json + per-project
# session/process dirs live). Note: we deliberately use HERMES_AO_DATA_DIR
# instead of AO_DATA_DIR — the latter is set by AO runtime infrastructure
# to point at a per-project sessions dir, which would mask the global
# running.json we need to read.
AO_DATA_DIR="${HERMES_AO_DATA_DIR:-$HOME/.agent-orchestrator}"
GLOBAL_RUNNING_JSON="${AO_DATA_DIR}/running.json"

# Resolve the running.json path
RUNNING_JSON=""

# detect_orphan_workers — probe for orphaned AO processes or worker tmux
# sessions that indicate the orchestrator died but children remain. This is
# the recovery case the IDLE→STALLED detection must catch so callers do not
# spawn a second master daemon and create competing instances.
#
# Returns 0 if any orphan indicators are found, 1 otherwise.
detect_orphan_workers() {
  # 1. Live AO master/lifecycle processes
  if command -v pgrep >/dev/null 2>&1; then
    if pgrep -fl "ao start|agent-orchestrator|lifecycle-manager" >/dev/null 2>&1; then
      return 0
    fi
  fi

  # 2. Lifecycle-manager JSON sidecars with live PIDs
  if [[ -d "$AO_DATA_DIR" ]]; then
    local sidecar
    while IFS= read -r sidecar; do
      [[ -z "$sidecar" ]] && continue
      local pid
      pid=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('pid',''))" "$sidecar" 2>/dev/null || echo "")
      if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        return 0
      fi
    done < <(find "$AO_DATA_DIR" -maxdepth 4 -type f -name "lifecycle-manager-*.json" 2>/dev/null)
  fi

  # 3. Worker tmux sessions (wa-*, jc-*, au-*, auf-*, aun-*, *-ao-*, *-orchestrator)
  if command -v tmux >/dev/null 2>&1; then
    local session
    while IFS= read -r session; do
      [[ -z "$session" ]] && continue
      local name="${session%%:*}"
      if [[ "$name" =~ (^|-)(wa-|jc-|au-|auf-|aun-|ao-|orchestrator) ]] || \
         [[ "$name" =~ -(ao|orchestrator)$ ]] || \
         [[ "$name" == *-orchestrator ]]; then
        return 0
      fi
    done < <(tmux ls 2>/dev/null || true)
  fi

  return 1
}

if [[ -n "$TARGET_PATH" ]]; then
  # If TARGET_PATH is a session ID (e.g. jc-1910), locate the matching project
  # session directory under the canonical AO_DATA_DIR layout:
  #   ${AO_DATA_DIR}/{hash}-{project}/sessions/{session-id}/
  if [[ ! "$TARGET_PATH" =~ / ]] && [[ -d "$AO_DATA_DIR" ]]; then
    SESSION_MATCH=$(find "$AO_DATA_DIR" -maxdepth 3 -type d -path "*/sessions/$TARGET_PATH" 2>/dev/null | head -n1 || true)
    if [[ -n "$SESSION_MATCH" ]]; then
      RUNNING_JSON="$SESSION_MATCH/.agent-orchestrator/running.json"
    fi
  fi

  if [[ -z "$RUNNING_JSON" ]]; then
    if [[ -d "$TARGET_PATH" ]]; then
      # Check inside the directory
      if [[ -f "$TARGET_PATH/.agent-orchestrator/running.json" ]]; then
        RUNNING_JSON="$TARGET_PATH/.agent-orchestrator/running.json"
      elif [[ -f "$TARGET_PATH/running.json" ]]; then
        RUNNING_JSON="$TARGET_PATH/running.json"
      else
        # Fallback: derive a session ID from the basename and search AO_DATA_DIR
        BASENAME=$(basename "$TARGET_PATH")
        if [[ -d "$AO_DATA_DIR" ]]; then
          SESSION_MATCH=$(find "$AO_DATA_DIR" -maxdepth 3 -type d -path "*/sessions/$BASENAME" 2>/dev/null | head -n1 || true)
          if [[ -n "$SESSION_MATCH" ]]; then
            RUNNING_JSON="$SESSION_MATCH/.agent-orchestrator/running.json"
          fi
        fi
      fi
    elif [[ -f "$TARGET_PATH" && "$(basename "$TARGET_PATH")" == "running.json" ]]; then
      RUNNING_JSON="$TARGET_PATH"
    fi
  fi

  if [[ -z "$RUNNING_JSON" || ! -f "$RUNNING_JSON" ]]; then
    echo "IDLE: No running.json found for target: $TARGET_PATH"
    exit 0
  fi
else
  if [[ ! -f "$GLOBAL_RUNNING_JSON" ]]; then
    # No global running.json — but check for orphans before declaring IDLE.
    # If a master/lifecycle process is still alive, or any worker tmux
    # session is running without a master, the system is STALLED, not IDLE.
    if detect_orphan_workers; then
      echo "STALLED: Global running.json is missing but live AO processes or orphaned worker sessions were detected — a prior master daemon is wedged and needs recovery."
      exit 0
    fi
    echo "IDLE: No global running.json found."
    exit 0
  fi
  RUNNING_JSON="$GLOBAL_RUNNING_JSON"
fi

# Read PID, Port and Projects from running.json using python3
PID=$(python3 -c "import json, sys; d=json.load(open(sys.argv[1])); print(d.get('pid', ''))" "$RUNNING_JSON" 2>/dev/null || echo "")
PORT=$(python3 -c "import json, sys; d=json.load(open(sys.argv[1])); print(d.get('port', '3020'))" "$RUNNING_JSON" 2>/dev/null || echo "3020")
PROJECTS=$(python3 -c "import json, sys; d=json.load(open(sys.argv[1])); print(','.join(d.get('projects', [])))" "$RUNNING_JSON" 2>/dev/null || echo "")

if [[ -z "$PID" ]]; then
  echo "STALLED: running.json exists at ${RUNNING_JSON} but contains no valid PID."
  exit 0
fi

# Check if process is alive
if ! kill -0 "$PID" 2>/dev/null; then
  echo "STALLED: running.json exists (PID $PID) but process is dead."
  exit 0
fi

# Check CLI responsiveness (primary check)
# Use a short timeout of 5 seconds to prevent hanging if CLI is wedged
if timeout 5 ao session ls >/dev/null 2>&1; then
  echo "HEALTHY: AO is running on PID $PID polling projects: [$PROJECTS]"
  exit 0
fi

# Fallback check for port liveness (in case CLI fails but API dashboard is listening)
PORT_LIVENESS=0
if command -v lsof >/dev/null 2>&1; then
  if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    PORT_LIVENESS=1
  fi
elif command -v nc >/dev/null 2>&1; then
  if nc -z 127.0.0.1 "$PORT" >/dev/null 2>&1; then
    PORT_LIVENESS=1
  fi
fi

if [[ "$PORT_LIVENESS" -eq 1 ]]; then
  echo "STALLED: Process $PID is alive and port $PORT is listening, but CLI status queries hang."
else
  echo "STALLED: Process $PID is alive, but CLI status queries failed and API port $PORT is not listening."
fi