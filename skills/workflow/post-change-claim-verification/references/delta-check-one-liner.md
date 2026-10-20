# Runtime-vs-Disk Delta Check — Copy-Pasteable One-Liner

A single shell command that runs the full delta check for the most common case (config/SOUL.md change vs running gateway). Paste this BEFORE claiming "live."

## The One-Liner

```bash
PID=$(pgrep -f "hermes gateway run" | head -1); \
echo "PID=$PID"; \
ps -p "$PID" -o pid,etime,lstart= 2>/dev/null; \
echo "--- file mtimes ---"; \
stat -f "%Sm %N" \
  ${HOME}/.smartclaw/config.yaml \
  ${HOME}/.smartclaw/workspace/SOUL.md \
  ${HOME}/.smartclaw_prod/workspace/SOUL.md; \
echo "--- SOUL.md COMMIT drift ---"; \
diff -q ${HOME}/.smartclaw/workspace/SOUL.md ${HOME}/.smartclaw_prod/workspace/SOUL.md && echo "staging==prod" || echo "DRIFT"; \
echo "--- gateway health ---"; \
curl -sf http://127.0.0.1:8643/health 2>/dev/null | python3 -m json.tool || echo "gateway unreachable"
```

## What it tells you

| Line | What to look for |
|---|---|
| `PID=...` | The currently-running gateway PID |
| `etime ... lstart` | Process age — if etime < time-since-config-mtime → config NOT loaded |
| `file mtimes` | Compare against `etime` to detect D1 (config-not-hot-reloaded) |
| `SOUL.md COMMIT drift` | `staging==prod` is good; `DRIFT` = D3 (SOUL.md in wrong tree) |
| `gateway health` | Process reachable + `status:ok` confirms liveness; doesn't prove config loaded but confirms the PID is alive |

## Verdict Format

Paste this 3-line block in the reply before claiming "live":

```
PID <pid> etime <etime> (started <lstart>)
SOUL.md mtime <mtime> (staging) / <mtime> (prod)
→ <verdict>  | action: <restart|cp -p|verify Stage 4.5>
```

Examples:

```
PID 12044 etime 02-19:23:12 (started Sun10PM)
SOUL.md mtime Aug 19 18:04:38 (staging) / Aug 19 18:04:38 (prod)
→ staging==prod, BUT file mtime > process etime → gateway has NOT loaded
→ action: `hermes gateway restart` from a separate terminal
```

```
PID 12044 etime 02-19:23:12 (started Sun10PM)
SOUL.md mtime Aug 19 18:04:38 (staging) / Aug 19 17:30:00 (prod)
→ DRIFT — staging has the new COMMIT, prod doesn't
→ action: `cp -p ~/.smartclaw/workspace/SOUL.md ~/.smartclaw_prod/workspace/SOUL.md`
```

```
PID 12044 etime 00:05:12 (started 5m ago, after config mtime)
SOUL.md mtime Aug 19 18:04:38 (staging) / Aug 19 18:04:38 (prod)
→ file mtime < process etime → gateway started AFTER the change → LOADED
→ "fix is live" is honest
```

## When the gateway isn't a single process

Some Hermes components (launchd jobs, cron workers) run as separate `launchd print gui/$(id -u)/<label>` instances. Substitute the right grep:

```bash
# For a launchd job:
PID=$(launchctl print "gui/$(id -u)/ai.smartclaw.schedule.<name>" 2>/dev/null | grep '^ *pid' | awk '{print $3}')

# For a specific cron:
hermes cron status <cron-id>  # shows process + last exit
```

## See also

- `references/gateway-etime-vs-mtime-decision-tree.md` — the exact comparison logic + edge cases (file mtime older than etime due to git checkout, file mtime newer due to mtime-preserving `cp -p`, etc.).
