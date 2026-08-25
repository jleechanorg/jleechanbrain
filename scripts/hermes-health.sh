#!/usr/bin/env bash
# hermes-health.sh — Fast proactive health check (<5s, no LLM calls)
# Usage: hermes-health.sh [--json] [--quiet]
# Exit: 0=healthy, 1=degraded/down
#
# NOTE: The Hermes gateway uses Slack Socket Mode and does NOT bind a TCP port.
# Historical HERMES_HEALTH_PORT=8642 was a probe-only HTTP server that has been
# decommissioned — checking :8642 produces a false "UNBOUND" DOWN verdict even
# when the gateway is fully responsive on Slack. The health check now uses:
#   1. launchd registration (process alive)
#   2. Gateway log heartbeat (mtime + recent activity)
#   3. Recent ERROR / Traceback in gateway log
# Override with HERMES_HEALTH_PORT=<port> if you have a real health server bound.

set -uo pipefail

LABEL="${HERMES_HEALTH_LABEL:-ai.smartclaw.prod}"
PORT="${HERMES_HEALTH_PORT:-}"  # empty by default; legacy 8642 is gone
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
PLIST_DISABLED="${PLIST}.disabled"
U="$(id -u)"
JSON=0
QUIET=0

for arg in "$@"; do
  case "$arg" in
    --json)  JSON=1 ;;
    --quiet) QUIET=1 ;;
  esac
done

PASS=()
WARN=()
FAIL=()

ts() { date '+%Y-%m-%dT%H:%M:%S'; }

# 1. Plist file state
if [[ -f "$PLIST" ]]; then
  PASS+=("plist:present")
elif [[ -f "$PLIST_DISABLED" ]]; then
  FAIL+=("plist:DISABLED — ${LABEL}.plist renamed to .disabled (deploy.sh Stage 0 ran with wrong canonical label)")
else
  FAIL+=("plist:MISSING — ${PLIST} not found")
fi

# 2. Launchd registration
launchd_pid=$(launchctl list 2>/dev/null | awk -v lbl="$LABEL" '$3==lbl{print $1}')
if [[ -n "$launchd_pid" && "$launchd_pid" != "-" ]]; then
  PASS+=("launchd:registered(pid=$launchd_pid)")
else
  FAIL+=("launchd:NOT_REGISTERED — run: launchctl bootstrap gui/$U $PLIST")
fi

# 3. Port binding + HTTP health (optional — only when HERMES_HEALTH_PORT is set
#    to a port the gateway actually binds). The Hermes gateway uses Slack
#    Socket Mode and does NOT bind a TCP port by default; the old :8642 check
#    was a false-positive "UNBOUND" trigger. Skip cleanly when PORT is empty.
if [[ -n "$PORT" ]]; then
  port_pid=$(lsof -t -sTCP:LISTEN -i ":${PORT}" 2>/dev/null | head -1)
  if [[ -z "$port_pid" ]]; then
    FAIL+=("port:UNBOUND — nothing on :${PORT} (set HERMES_HEALTH_PORT='' to disable)")
  elif [[ -n "$launchd_pid" && "$launchd_pid" != "-" && "$port_pid" != "$launchd_pid" ]]; then
    FAIL+=("pid_mismatch:launchd=${launchd_pid} port=${port_pid}")
  else
    PASS+=("port:bound(pid=$port_pid)")
  fi

  # HTTP health endpoint — strict 200 required (only if port is bound)
  if [[ -n "$port_pid" ]]; then
    # NOTE: -f intentionally omitted — with -f curl exits non-zero on 4xx/5xx
    # while still writing the code via -w, then `|| echo 000` appends a second
    # line and corrupts http_code into a multi-line string. Plain curl writes
    # the status code reliably and exits 0; the || echo 000 covers connect failures.
    http_code=$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 5 "http://127.0.0.1:${PORT}/health" 2>/dev/null || echo "000")
    if [[ "$http_code" == "200" ]]; then
      PASS+=("http:/health:ok(${http_code})")
    else
      FAIL+=("http:/health:BAD(code=${http_code})")
    fi
  fi
fi

# 4. Gateway log heartbeat — real health surface for a Socket-Mode Slack bot.
#    A bound port is not a proxy for "gateway is responsive on Slack". A log
#    mtime within HEARTBEAT_MAX_AGE_SECONDS plus a recent activity line is
#    the actual evidence the gateway is doing work.
GATEWAY_LOG="$HOME/.smartclaw/logs/gateway.log"
HEARTBEAT_MAX_AGE_SECONDS="${HERMES_HEALTH_HEARTBEAT_MAX_AGE:-120}"
if [[ -f "$GATEWAY_LOG" ]]; then
  log_mtime=$(stat -f %m "$GATEWAY_LOG" 2>/dev/null || echo 0)
  log_age=$(( $(date +%s) - log_mtime ))
  if (( log_age <= HEARTBEAT_MAX_AGE_SECONDS )); then
    PASS+=("log:heartbeat_ok(age=${log_age}s, max=${HEARTBEAT_MAX_AGE_SECONDS}s)")
  else
    WARN+=("log:stale(age=${log_age}s, max=${HEARTBEAT_MAX_AGE_SECONDS}s — gateway may be idle or stuck)")
  fi

  # 4b. ERROR / Traceback scan over the last 200 lines — repeated ERRORs
  #     (e.g. api_server key retries) are a WARN, a fresh Traceback is a FAIL.
  recent_errors=$(tail -n 200 "$GATEWAY_LOG" 2>/dev/null | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3} (ERROR|CRITICAL)')
  recent_traceback=$(tail -n 200 "$GATEWAY_LOG" 2>/dev/null | grep -cE '^Traceback \(most recent call last\):')
  if (( recent_traceback > 0 )); then
    FAIL+=("log:Traceback_detected(count=${recent_traceback} in last 200 lines)")
  elif (( recent_errors > 5 )); then
    WARN+=("log:ERROR_burst(count=${recent_errors} in last 200 lines)")
  elif (( recent_errors > 0 )); then
    PASS+=("log:ERROR_present(count=${recent_errors}, non-burst)")
  else
    PASS+=("log:clean(no ERROR in last 200 lines)")
  fi
else
  WARN+=("log:MISSING — ${GATEWAY_LOG} not found")
fi

# 5. Process uptime (from launchd_pid, not from port)
if [[ -n "$launchd_pid" && "$launchd_pid" != "-" ]]; then
  proc_start=$(ps -o lstart= -p "$launchd_pid" 2>/dev/null | xargs)
  [[ -n "$proc_start" ]] && PASS+=("uptime:since $proc_start (pid=$launchd_pid)")
fi

# 6. Watchdog registered (periodic job — PID is '-' when idle, that's fine)
wd_registered=$(launchctl list 2>/dev/null | awk '$3=="ai.smartclaw.watchdog"{print "yes"}')
if [[ "$wd_registered" == "yes" ]]; then
  PASS+=("watchdog:registered(periodic)")
else
  WARN+=("watchdog:NOT_REGISTERED — run: launchctl bootstrap gui/$U $HOME/Library/LaunchAgents/ai.smartclaw-watchdog.plist")
fi

# 7. Loadavg check
load1=$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}')
load_int=${load1%.*}
if (( load_int > 30 )); then
  WARN+=("loadavg:HIGH(${load1}) — launchd may SIGTERM gateway via ThrottleInterval")
elif (( load_int > 15 )); then
  WARN+=("loadavg:ELEVATED(${load1})")
else
  PASS+=("loadavg:ok(${load1})")
fi

# Output
overall="HEALTHY"
[[ ${#WARN[@]} -gt 0 ]] && overall="DEGRADED"
[[ ${#FAIL[@]} -gt 0 ]] && overall="DOWN"

if [[ $JSON -eq 1 ]]; then
  python3 -c "
import json, sys
data = {
  'ts': '$(ts)',
  'status': '$overall',
  'pass': $(if ((${#PASS[@]})); then printf '%s\n' "${PASS[@]}" | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))'; else echo '[]'; fi),
  'warn': $(if ((${#WARN[@]})); then printf '%s\n' "${WARN[@]}" | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))'; else echo '[]'; fi),
  'fail': $(if ((${#FAIL[@]})); then printf '%s\n' "${FAIL[@]}" | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))'; else echo '[]'; fi),
}
print(json.dumps(data, indent=2))
"
else
  if [[ $QUIET -eq 0 ]]; then
    echo "=== Hermes Health Check — $(ts) ==="
    ((${#PASS[@]})) && for p in "${PASS[@]}"; do echo "  [PASS] $p"; done
    ((${#WARN[@]})) && for w in "${WARN[@]}"; do echo "  [WARN] $w"; done
    ((${#FAIL[@]})) && for f in "${FAIL[@]}"; do echo "  [FAIL] $f"; done
    echo ""
  fi
  case "$overall" in
    HEALTHY)  echo "STATUS: ✅ HEALTHY" ;;
    DEGRADED) echo "STATUS: ⚠️  DEGRADED (${#WARN[@]} warning(s))" ;;
    DOWN)     echo "STATUS: 🚨 DOWN (${#FAIL[@]} failure(s))" ;;
  esac
fi

case "$overall" in
  HEALTHY)  exit 0 ;;
  DEGRADED) exit 1 ;;
  DOWN)     exit 2 ;;
esac
