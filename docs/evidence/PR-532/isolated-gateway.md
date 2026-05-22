# PR #532 — Isolated gateway smoke (skills / eloop touch)

**Date:** 2026-04-06 (local)  
**Procedure:** `CLAUDE.md` → Isolated Gateway Testing — use a gateway **not** on production port **18789**.

## Commands

```bash
export HERMES_STATE_DIR="$HOME/.smartclaw"
export HERMES_CONFIG_PATH="$HOME/.smartclaw/hermes.json"
cd ${HOME}/.worktrees/smartclaw/jc-1795
hermes gateway run --bind loopback --port 18999 --force 2>/tmp/gw-pr532.err &
GW_PID=$!
sleep 12
curl -fsS -m 5 http://127.0.0.1:18999/health
kill "$GW_PID"
```

## Result

- Gateway bound to **127.0.0.1:18999** (not 18789).
- `GET /health` returned: `{"ok":true,"status":"live"}`.
- Process terminated cleanly after SIGTERM.

## Note

This PR changes **skills** markdown and bootstrap wiring; the gateway binary loads the same config as staging. The isolated check confirms a non-prod port comes up healthy with the local harness state dir.
