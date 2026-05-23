---
description: /claw - Route all tasks through OpenClaw gateway inference
type: orchestration
execution_mode: immediate
---
# /claw - OpenClaw Gateway Inference

**Usage**: `/claw <task description>`

**Purpose**: Routes ALL tasks through OpenClaw gateway inference. Coding tasks go through OpenClaw, which may then call `dispatch-task` internally if needed.

> **Note (2026-04-07):** Jeffrey confirmed ALL tasks — including coding — must go through OpenClaw inference. Direct `ao spawn` from `/claw` is disabled. The `dispatch-task` skill is available for OpenClaw sessions that need to spawn AO sub-tasks.

## Execution

When this command is invoked with `$ARGUMENTS`:

```bash
TASK_DESCRIPTION="$ARGUMENTS"
set -euo pipefail

LOGDIR="/tmp/openclaw"
mkdir -p "$LOGDIR"
chmod 700 "$LOGDIR" 2>/dev/null || true
STATUS_LOG="$(mktemp "$LOGDIR/.claw-status-XXXXXXXX")"

# Gateway auth: `openclaw config get gateway.*.token` prints __OPENCLAW_REDACTED__ — never export that.
# Drop stale env overrides so the CLI reads real tokens from the config file (must match the running gateway).
unset OPENCLAW_GATEWAY_TOKEN OPENCLAW_GATEWAY_REMOTE_TOKEN 2>/dev/null || true

OPENCLAW_CFG="${OPENCLAW_CONFIG_PATH:-$HOME/.smartclaw/openclaw.json}"
if [ ! -f "$OPENCLAW_CFG" ]; then
  echo "OpenClaw config not found: $OPENCLAW_CFG"
  exit 1
fi
if ! python3 -c "
import json, sys
p = sys.argv[1]
cfg = json.load(open(p))
g = cfg.get('gateway') or {}
a = (g.get('auth') or {}).get('token') or ''
r = (g.get('remote') or {}).get('token') or ''
sys.exit(0 if (a and r and a == r) else 1)
" "$OPENCLAW_CFG"; then
  echo "gateway.auth.token and gateway.remote.token must be non-empty and equal in $OPENCLAW_CFG"
  echo "If the gateway runs with a different profile, copy gateway.auth/remote from that file or set OPENCLAW_CONFIG_PATH."
  exit 1
fi

# Verify gateway is healthy and the CLI can authenticate to it.
if ! openclaw gateway status >"$STATUS_LOG" 2>&1; then
  echo "OpenClaw gateway status check failed."
  sed -n '1,80p' "$STATUS_LOG"
  exit 1
fi
if ! grep -q "RPC probe: ok" "$STATUS_LOG"; then
  echo "OpenClaw gateway is not healthy."
  sed -n '1,80p' "$STATUS_LOG"
  exit 1
fi
# Resolve slash commands
TASK_WITH_RESOLVED="$TASK_DESCRIPTION"

SLASH_CMD=$(printf '%s' "$TASK_DESCRIPTION" | python3 -c "
import sys, re
text = sys.stdin.read().strip()
clean = re.sub(r'https?://\S+', '', text)
m = re.search(r'(?:^|\s)/([\w-]+)', clean)
if m:
    print(m.group(1))
" 2>/dev/null)

if [ -n "$SLASH_CMD" ]; then
  RESOLVED_CONTENT=""
  RESOLVED_SOURCE=""
  for search_dir in ".claude/commands" "$HOME/.claude/commands"; do
    if [ -f "$search_dir/$SLASH_CMD.md" ]; then
      RESOLVED_CONTENT=$(cat "$search_dir/$SLASH_CMD.md" 2>/dev/null)
      RESOLVED_SOURCE="$search_dir/$SLASH_CMD.md"
      break
    fi
  done
  if [ -z "$RESOLVED_CONTENT" ]; then
    for search_dir in ".claude/skills" "$HOME/.claude/skills"; do
      if [ -f "$search_dir/$SLASH_CMD/SKILL.md" ]; then
        RESOLVED_CONTENT=$(cat "$search_dir/$SLASH_CMD/SKILL.md" 2>/dev/null)
        RESOLVED_SOURCE="$search_dir/$SLASH_CMD/SKILL.md"
        break
      elif [ -f "$search_dir/$SLASH_CMD.md" ]; then
        RESOLVED_CONTENT=$(cat "$search_dir/$SLASH_CMD.md" 2>/dev/null)
        RESOLVED_SOURCE="$search_dir/$SLASH_CMD.md"
        break
      fi
    done
  fi
  if [ -n "$RESOLVED_CONTENT" ]; then
    echo "Resolved /$SLASH_CMD from $RESOLVED_SOURCE"
    TASK_WITH_RESOLVED="The user asked: $TASK_DESCRIPTION

Below is the full definition of /$SLASH_CMD (resolved from $RESOLVED_SOURCE). Execute it as instructed:

---
$RESOLVED_CONTENT
---"
  fi
fi

TASK_FILE="$(mktemp "$LOGDIR/.claw-task-XXXXXXXX")"
chmod 600 "$TASK_FILE" 2>/dev/null || true
printf '%s' "$TASK_WITH_RESOLVED" >"$TASK_FILE"
if [ ! -s "$TASK_FILE" ]; then
  echo "Failed to build OpenClaw task file"
  exit 1
fi

LOGFILE="$LOGDIR/claw-$(date +%s).log"
nohup python3 - "$TASK_FILE" <<'PY' >"$LOGFILE" 2>&1 &
import subprocess
import sys

task_file = sys.argv[1]
message = open(task_file, "r", encoding="utf-8").read()
raise SystemExit(
    subprocess.call(
        [
            "openclaw",
            "agent",
            "--agent",
            "main",
            "--thinking",
            "medium",
            "--json",
            "--message",
            message,
        ]
    )
)
PY

CLAW_PID=$!
sleep 2
if ! kill -0 "$CLAW_PID" 2>/dev/null; then
  echo "OpenClaw agent exited immediately."
  sed -n '1,80p' "$LOGFILE"
  exit 1
fi
if grep -Eq 'gateway connect failed|falling back to embedded|unauthorized:' "$LOGFILE"; then
  kill "$CLAW_PID" 2>/dev/null || true
  echo "OpenClaw gateway path failed; refusing to continue via degraded fallback."
  sed -n '1,80p' "$LOGFILE"
  exit 1
fi

echo "Task dispatched to OpenClaw gateway (PID: $CLAW_PID)"
echo "Log: $LOGFILE"
echo "Monitor: tail -f $LOGFILE"
echo "Kill: kill $CLAW_PID"
```

## Requirements

- OpenClaw gateway healthy via `openclaw gateway status`
- `gateway.remote.token` must match `gateway.auth.token`
- Slash command resolution: looks up `.claude/commands/` and `.claude/skills/` directories

## Notes

- All tasks route through OpenClaw gateway inference.
- If an OpenClaw session needs to spawn an AO sub-task, it calls the `dispatch-task` skill internally — NOT directly from `/claw`.
- `/claw` fails closed if the OpenClaw CLI tries to degrade into embedded mode instead of using the gateway path.
- Slash commands are resolved before dispatch.
- Log file written to `/tmp/openclaw/claw-<timestamp>.log`
