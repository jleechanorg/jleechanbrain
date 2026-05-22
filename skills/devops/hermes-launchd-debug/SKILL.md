---
name: hermes-launchd-debug
description: Full diagnostic runbook for Hermes gateway + launchd + mem0 server on this machine. Covers service state, port binding, health endpoints, orphan plists, config parity, Slack/Discord token routing, and repair via install.sh --fix.
when_to_use: "Use when Hermes gateway is down, crashing, not responding to Slack messages, showing Slack flood/spam, Discord conflict, port bind failure, mem0 unavailable, or when running a health check after any restart or deploy."
tags: [hermes, launchd, gateway, debug, slack, discord, mem0, install, port]
---

# Hermes + Launchd Debug Runbook

## Quick Triage (run in order, stop when you find the issue)

```bash
# 1. Service state — are all three jobs loaded and running?
launchctl list | grep hermes

# 2. Port binding — does the right PID own each port?
lsof -i :8642 -i :8643 -i :8000 2>/dev/null | grep LISTEN

# 3. Health endpoints
curl -fsS -m 5 http://127.0.0.1:8642/health && echo " [prod OK]"
curl -fsS -m 5 http://127.0.0.1:8643/health && echo " [staging OK]"
curl -fsS -m 5 http://127.0.0.1:8000/health && echo " [mem0 OK]"

# 4. Recent errors
tail -30 ~/.smartclaw_prod/logs/gateway.error.log
tail -30 ~/.smartclaw/logs/gateway.error.log
```

---

## Services Reference

| Service | Label | Port | HERMES_HOME |
|---------|-------|------|-------------|
| Production | `ai.smartclaw.prod` | 8642 | `~/.smartclaw_prod` |
| Staging | `ai.smartclaw-staging` | 8643 | `~/.smartclaw` |
| Mem0 | `ai.smartclaw-mem0-server` | 8000 | n/a |

Plist files: `~/Library/LaunchAgents/ai.smartclaw*.plist`

---

## Step-by-Step Diagnostics

### 1. Orphan Plist Check

Any plist label NOT in `{ai.smartclaw.prod, ai.smartclaw-staging, ai.smartclaw-mem0-server}` is an orphan. Orphans sharing `HERMES_HOME` with a canonical job cause port conflicts and restart storms.

```bash
python3 - <<'EOF'
import plistlib, os, glob

LAUNCHD_DIR = os.path.expanduser("~/Library/LaunchAgents")
CANONICAL = {"ai.smartclaw.prod", "ai.smartclaw-staging", "ai.smartclaw-mem0-server"}

for p in sorted(glob.glob(f"{LAUNCHD_DIR}/ai.smartclaw*.plist")):
    label = os.path.basename(p).removesuffix(".plist")
    with open(p, "rb") as f:
        d = plistlib.load(f)
    home = d.get("EnvironmentVariables", {}).get("HERMES_HOME", "n/a")
    status = "OK" if label in CANONICAL else "ORPHAN ⚠️"
    print(f"{status:8s} {label:35s} HERMES_HOME={home}")
EOF
```

**Fix**: `launchctl bootout gui/$(id -u)/<orphan-label> && rm ~/Library/LaunchAgents/<orphan-label>.plist`

Or run `~/.smartclaw/scripts/install.sh --fix` (check 5 handles this automatically).

### 2. Port Bind Verification

```bash
# Verify correct PID owns each port
check_port() {
  local port=$1 label=$2
  local port_pid proc_pid
  port_pid=$(lsof -t -i ":$port" 2>/dev/null | head -1)
  proc_pid=$(launchctl list 2>/dev/null | awk -v l="$label" '$3==l{print $1}')
  if [[ -z "$port_pid" ]]; then
    echo "FAIL $label: nothing on :$port"
  elif [[ "$port_pid" == "$proc_pid" ]]; then
    echo "OK   $label: :$port bound by PID $port_pid (matches launchctl)"
  else
    echo "MISMATCH $label: :$port bound by PID $port_pid, launchctl shows $proc_pid"
  fi
}
check_port 8642 ai.smartclaw.prod
check_port 8643 ai.smartclaw-staging
check_port 8000 ai.smartclaw-mem0-server
```

### 3. Config Parity Check (staging vs prod)

Staging and prod `config.yaml` must be identical except for intentional overrides:
- `platforms.api_server.extra.port`: staging=8643, prod=8642 (intentional)

```bash
diff <(grep -v "port:" ~/.smartclaw/config.yaml) \
     <(grep -v "port:" ~/.smartclaw_prod/config.yaml)
# Output should be empty
```

If drift exists: copy staging → prod then restart prod.

```bash
cp ~/.smartclaw/config.yaml ~/.smartclaw_prod/config.yaml
# Then manually restore prod port:
sed -i '' 's/port: 8643/port: 8642/' ~/.smartclaw_prod/config.yaml
```

### 4. Slack / Discord Token Routing

Only one gateway may hold a given `SLACK_APP_TOKEN` at a time (Socket Mode constraint). Only prod may hold `DISCORD_BOT_TOKEN`.

`launchd-env-wrapper.sh` handles token isolation:
- For non-prod (`HERMES_HOME != ~/.smartclaw_prod`): overrides Slack tokens with `HERMES_STAGING_SLACK_*` vars, then **unsets** `DISCORD_BOT_TOKEN`
- For prod: uses tokens from `~/.bash_profile` unchanged

```bash
# Verify wrapper is present and correct
grep "unset DISCORD_BOT_TOKEN" ~/.smartclaw/scripts/launchd-env-wrapper.sh
# Should return the unset line — if missing, the script is stale

# Check what tokens each running hermes process sees
for pid in $(pgrep -f "hermes gateway"); do
  echo "=== PID $pid ==="
  ps eww -p "$pid" 2>/dev/null | tr ' ' '\n' | grep -E "SLACK|DISCORD|HERMES_HOME"
done
```

**Symptom: Slack channel flooded with disconnect/reconnect messages**
Cause: Two gateways competing for same `SLACK_APP_TOKEN`. Fix: remove orphan plist (see step 1), then verify only one job is running.

**Symptom: Discord not working on prod**
Cause: Staging process grabbed `DISCORD_BOT_TOKEN` before prod. Fix: verify wrapper has `unset DISCORD_BOT_TOKEN` for staging, then restart both gateways in order: staging first, prod second.

### 5. Hermes Process Count

Should be exactly 1 prod + 1 staging (+ 1 mem0 if enabled):

```bash
echo "All hermes processes:"
pgrep -a -f "hermes gateway" | grep -v grep

echo ""
echo "By HERMES_HOME:"
for pid in $(pgrep -f "hermes gateway"); do
  home=$(ps eww -p "$pid" 2>/dev/null | tr ' ' '\n' | grep "^HERMES_HOME=" | cut -d= -f2-)
  echo "  PID $pid → ${home:-unknown}"
done
```

If count > 1 per home: kill extras then restart via launchd.

### 6. Gateway Logs — Common Patterns

| Log pattern | Meaning | Fix |
|-------------|---------|-----|
| `address already in use :8642` | Port conflict, orphan process | Kill orphan, restart |
| `SlackWebSocket:N > 5` | WS churn, token conflict or event-loop saturation | Remove token conflict; reduce concurrency |
| `session file locked (timeout)` | Dead process holding `.lock` file | Remove stale `.lock` files |
| `Error ensuring model exists: 404` | Mem0 catalog drift | `launchctl stop/start ai.smartclaw-mem0-server` |
| `DISCORD_BOT_TOKEN` errors in staging log | Staging grabbed Discord token | Verify wrapper has `unset DISCORD_BOT_TOKEN` |

```bash
# Find stale session locks
find ~/.smartclaw/logs/ ~/.smartclaw_prod/logs/ -name "*.lock" 2>/dev/null
# Remove stale ones (verify PID is dead first):
# kill -0 <pid> 2>/dev/null || rm <lockfile>
```

---

## Canonical Repair Command

When in doubt, run the full validator with fix mode:

```bash
~/.smartclaw/scripts/install.sh --fix
```

This checks (in order):
1. Hermes binary installed and on PATH
2. Required directories exist (`~/.smartclaw`, `~/.smartclaw_prod`, logs, skills)
3. Both `config.yaml` files present and valid YAML
4. Required env vars exported (`SLACK_BOT_TOKEN`, `SLACK_APP_TOKEN`, `WAFER_API_KEY`, etc.)
5. Orphan/duplicate plists removed
6. Both gateways running and bound to correct ports
7. Slack tokens present and non-conflicting
8. Provider registry not duplicated (no `providers` + `custom_providers` overlap)
9. Mem0 server available on port 8000
10. `launchd-env-wrapper.sh` present and contains `unset DISCORD_BOT_TOKEN`

Exit 0 = all checks pass. Non-zero = at least one FAIL remains after fix attempt.

---

## Restart Procedures

### Safe single gateway restart (bootout + bootstrap)
```bash
U=$(id -u)
LABEL="ai.smartclaw.prod"   # or ai.smartclaw-staging
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"

launchctl bootout gui/$U/$LABEL 2>/dev/null || true
sleep 2
launchctl bootstrap gui/$U "$PLIST"
launchctl start gui/$U/$LABEL
sleep 5
curl -fsS -m 5 http://127.0.0.1:8642/health   # adjust port for staging
```

**Do NOT use `kickstart -k`** — it does not reload plist `EnvironmentVariables`.

### Restart both gateways (staging first, then prod)
```bash
U=$(id -u)
for label in ai.smartclaw-staging ai.smartclaw.prod; do
  plist="$HOME/Library/LaunchAgents/${label}.plist"
  launchctl bootout gui/$U/$label 2>/dev/null || true
  sleep 1
  launchctl bootstrap gui/$U "$plist"
  launchctl start gui/$U/$label
  sleep 3
done
# Verify
curl -fsS -m 5 http://127.0.0.1:8643/health && echo "[staging OK]"
curl -fsS -m 5 http://127.0.0.1:8642/health && echo "[prod OK]"
```

---

## Slack Proof Test

After restart, send a real message and verify the correct bot responds:

```bash
# Test via Slack API (replace CHANNEL with your test channel ID)
source ~/.bash_profile
curl -s -X POST https://slack.com/api/chat.postMessage \
  -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"channel":"$SLACK_HOME_CHANNEL","text":"hermes health check — please respond"}'
```

Expected: @hermes or @hermes_staging replies within ~30s.
