#!/usr/bin/env bash
# Gateway pre-flight check — run before any upgrade, restart, or hermes deploy
#
# Checks the Hermes gateway plist, process count, config validity, and
# critical config keys before any disruptive operation.
#
# Usage: bash gateway-preflight.sh [--fix]
set -uo pipefail

FIX_MODE="${1:-}"
ERRORS=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ACTIVE_PLIST="$HOME/Library/LaunchAgents/ai.smartclaw.prod.plist"
REPO_GATEWAY_PLIST="$REPO_DIR/launchd/ai.smartclaw.prod.plist"
STAGING_CONFIG="$HOME/.smartclaw/config.yaml"
PROD_CONFIG="$HOME/.smartclaw_prod/config.yaml"

read_plist_key() {
  python3 - "$1" "$2" <<'PY'
import plistlib
import sys

path, dotted_key = sys.argv[1], sys.argv[2]
with open(path, "rb") as fh:
    data = plistlib.load(fh)

value = data
for part in dotted_key.split("."):
    if isinstance(value, list):
        try:
            value = value[int(part)]
        except Exception:
            sys.exit(1)
        continue
    if not isinstance(value, dict) or part not in value:
        sys.exit(1)
    value = value[part]

if isinstance(value, bool):
    print("true" if value else "false")
elif isinstance(value, (int, float)):
    print(value)
elif isinstance(value, str):
    print(value)
else:
    sys.exit(1)
PY
}

reload_gateway_plist_from_repo() {
  local domain="gui/$(id -u)"
  if [ ! -f "$REPO_GATEWAY_PLIST" ]; then
    echo "  WARN: canonical repo gateway plist missing: $REPO_GATEWAY_PLIST"
    return 1
  fi
  cp "$REPO_GATEWAY_PLIST" "$ACTIVE_PLIST" || return 1
  launchctl bootout "${domain}/ai.smartclaw.prod" 2>/dev/null || true
  sleep 0.35
  launchctl bootstrap "$domain" "$ACTIVE_PLIST" >/dev/null 2>&1 || return 1
  echo "  FIX: reloaded ai.smartclaw.prod from repo plist"
}

is_stub_main_config() {
  python3 - "$1" <<'PY'
import sys
try:
    import yaml
except ImportError:
    sys.exit(1)

with open(sys.argv[1]) as fh:
    cfg = yaml.safe_load(fh) or {}

slack = cfg.get("slack", {}) or {}
required = [
    cfg.get("slack", {}).get("bot_token"),
    cfg.get("slack", {}).get("app_token"),
]

missing = any(not item for item in required)
sys.exit(0 if missing else 1)
PY
}

resolve_live_config_for_preflight() {
  if [ -f "$STAGING_CONFIG" ] && is_stub_main_config "$STAGING_CONFIG"; then
    if [ -f "$PROD_CONFIG" ]; then
      echo "$PROD_CONFIG"
      return 0
    fi
  fi
  echo "$STAGING_CONFIG"
}

resolve_gateway_port_from_config() {
  local config_path="$1"
  local default_port="$2"
  python3 - "$config_path" "$default_port" <<'PY'
import sys

default = sys.argv[2]
config_path = sys.argv[1]
port = None
try:
    import yaml
    with open(config_path) as fh:
        cfg = yaml.safe_load(fh) or {}
    api_server = (cfg.get("platforms") or {}).get("api_server") or {}
    extra = api_server.get("extra") or {}
    port = extra.get("port")
except Exception:
    port = None

if port is None:
    print(default)
else:
    print(int(port))
PY
}

echo "=== Hermes Gateway Pre-flight Check ==="
echo ""

LIVE_CONFIG_FOR_PREFLIGHT="$(resolve_live_config_for_preflight)"
if [ "$LIVE_CONFIG_FOR_PREFLIGHT" = "$PROD_CONFIG" ]; then
  GATEWAY_PORT_DEFAULT=8642
else
  GATEWAY_PORT_DEFAULT=8644
fi
GATEWAY_PORT="$(resolve_gateway_port_from_config "$LIVE_CONFIG_FOR_PREFLIGHT" "$GATEWAY_PORT_DEFAULT")"

# 1. Check for competing plists
PLIST_COUNT=$(ls ~/Library/LaunchAgents/*hermes*prod* ~/Library/LaunchAgents/*ai.smartclaw.prod* 2>/dev/null | sort -u | wc -l | tr -d ' ')
echo "[1] Gateway plists: $PLIST_COUNT"
if [ "$PLIST_COUNT" -gt 1 ]; then
  echo "  FAIL: Multiple gateway plists detected:"
  ls -1 ~/Library/LaunchAgents/*hermes*prod* ~/Library/LaunchAgents/*ai.smartclaw.prod* 2>/dev/null | sort -u
  if [ "$FIX_MODE" = "--fix" ]; then
    echo "  FIX: Keeping ai.smartclaw.prod, removing others"
    for plist in ~/Library/LaunchAgents/*hermes*prod*; do
      label=$(defaults read "$plist" Label 2>/dev/null || true)
      if [ "$label" != "ai.smartclaw.prod" ] && [ -n "$label" ]; then
        launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
        rm -f "$plist"
        echo "  Removed: $plist ($label)"
      fi
    done
  else
    ERRORS=$((ERRORS + 1))
  fi
elif [ "$PLIST_COUNT" -eq 0 ]; then
  echo "  WARN: No gateway plist found"
else
  echo "  OK"
fi

# 2. Check ThrottleInterval (must be >= 10 to prevent restart storms)
if [ -f "$ACTIVE_PLIST" ]; then
  THROTTLE="$(read_plist_key "$ACTIVE_PLIST" "ThrottleInterval" 2>/dev/null || echo "30")"
  echo "[2] ThrottleInterval: $THROTTLE"
  if [ "$THROTTLE" -lt 10 ]; then
    echo "  FAIL: ThrottleInterval=$THROTTLE is too low (causes restart storms)"
    if [ "$FIX_MODE" = "--fix" ]; then
      if reload_gateway_plist_from_repo; then
        :
      else
        ERRORS=$((ERRORS + 1))
      fi
    else
      ERRORS=$((ERRORS + 1))
    fi
  else
    echo "  OK"
  fi
fi

# 2a. Installed gateway plist must match the canonical runtime wiring.
if [ -f "$ACTIVE_PLIST" ] && [ -f "$REPO_GATEWAY_PLIST" ]; then
  echo "[2a] Gateway plist wiring:"
  PLIST_MISMATCH=0
  for key in \
    ProgramArguments.0 \
    StandardOutPath \
    StandardErrorPath \
    EnvironmentVariables.HERMES_HOME
  do
    expected="$(read_plist_key "$REPO_GATEWAY_PLIST" "$key" 2>/dev/null || true)"
    actual="$(read_plist_key "$ACTIVE_PLIST" "$key" 2>/dev/null || true)"
    if [ -z "$expected" ]; then
      continue
    fi
    if [ "$actual" != "$expected" ]; then
      echo "  FAIL: $key mismatch"
      echo "    expected: $expected"
      echo "    actual:   ${actual:-<missing>}"
      PLIST_MISMATCH=1
    fi
  done
  if [ "$PLIST_MISMATCH" -eq 1 ]; then
    if [ "$FIX_MODE" = "--fix" ]; then
      if reload_gateway_plist_from_repo; then
        :
      else
        ERRORS=$((ERRORS + 1))
      fi
    else
      ERRORS=$((ERRORS + 1))
    fi
  else
    echo "  OK"
  fi
fi

# 2b. Plist must be XML (not binary) so tooling can parse it
if [ -f "$ACTIVE_PLIST" ]; then
  _gw_plist_binary=0
  _hdr=$(head -c 8 "$ACTIVE_PLIST" 2>/dev/null || true)
  if [[ "$_hdr" == bplist* ]]; then
    _gw_plist_binary=1
  elif command -v file >/dev/null 2>&1 && file "$ACTIVE_PLIST" 2>/dev/null | grep -qi "binary property list"; then
    _gw_plist_binary=1
  fi
  echo "[2b] Gateway plist encoding (XML required):"
  if [ "$_gw_plist_binary" -eq 1 ]; then
    echo "  FAIL: plist is binary; XML form required for plist inspection tools"
    if [ "$FIX_MODE" = "--fix" ]; then
      plutil -convert xml1 "$ACTIVE_PLIST" || { echo "  plutil failed"; ERRORS=$((ERRORS + 1)); }
      echo "  FIX: converted to XML (plutil -convert xml1)"
      _domain="gui/$(id -u)"
      if launchctl kickstart -k "${_domain}/ai.smartclaw.prod" >/dev/null 2>&1; then
        echo "  FIX: launchctl kickstart -k ${_domain}/ai.smartclaw.prod (reload from disk)"
      else
        echo "  WARN: kickstart failed; when convenient: launchctl kickstart -k ${_domain}/ai.smartclaw.prod"
      fi
    else
      ERRORS=$((ERRORS + 1))
    fi
  else
    echo "  OK (XML/text plist)"
  fi
fi

# 3. Check for multiple gateway processes
GW_PIDS=$(pgrep -f "hermes.*gateway|hermes.*:${GATEWAY_PORT}|python.*hermes" 2>/dev/null | wc -l | tr -d ' ')
echo "[3] Gateway processes: $GW_PIDS"
if [ "$GW_PIDS" -gt 1 ]; then
  echo "  FAIL: Multiple gateway processes detected"
  ps aux | grep -E "hermes.*(gateway|${GATEWAY_PORT})" | grep -v grep
  ERRORS=$((ERRORS + 1))
else
  echo "  OK"
fi

# 4. Check config YAML validity
echo -n "[4] Config YAML ($STAGING_CONFIG): "
if python3 -c "import yaml; yaml.safe_load(open('$STAGING_CONFIG'))" 2>/dev/null; then
  echo "valid"
else
  echo "INVALID"
  ERRORS=$((ERRORS + 1))
fi

# 5. Check critical config keys
if [ "$LIVE_CONFIG_FOR_PREFLIGHT" = "$PROD_CONFIG" ]; then
  echo "[5] Critical config keys (live prod config — staging config is a repo stub):"
else
  echo "[5] Critical config keys:"
fi
python3 -c "
import sys
try:
    import yaml
except ImportError:
    print('  SKIP: PyYAML not installed')
    sys.exit(0)
with open('$LIVE_CONFIG_FOR_PREFLIGHT') as f:
    d = yaml.safe_load(f) or {}
slack = d.get('slack', {}) or {}
checks = {
    'slack.bot_token': slack.get('bot_token'),
    'slack.app_token': slack.get('app_token'),
}
errors = 0
for path, val in checks.items():
    status = 'OK' if val else 'MISSING'
    print(f'  {path}: {status}')
    if not val: errors += 1
sys.exit(errors)
" 2>/dev/null || ERRORS=$((ERRORS + $?))

# 6. Check hermes HTTP health endpoint (port from live config)
echo -n "[6] Hermes HTTP health (port ${GATEWAY_PORT}): "
if curl -fsS -m 8 "http://127.0.0.1:${GATEWAY_PORT}/health" >/dev/null 2>&1; then
  echo "OK"
else
  echo "FAIL: gateway not responding on port ${GATEWAY_PORT}"
  ERRORS=$((ERRORS + 1))
fi

# 7. Check HERMES_HOME env var in active plist
if [ -f "$ACTIVE_PLIST" ]; then
  echo "[7] HERMES_HOME in plist:"
  PLIST_HERMES_HOME="$(read_plist_key "$ACTIVE_PLIST" "EnvironmentVariables.HERMES_HOME" 2>/dev/null || true)"
  if [ -z "$PLIST_HERMES_HOME" ]; then
    echo "  FAIL: HERMES_HOME not set in plist EnvironmentVariables"
    ERRORS=$((ERRORS + 1))
  elif [ ! -d "$PLIST_HERMES_HOME" ]; then
    echo "  FAIL: HERMES_HOME=$PLIST_HERMES_HOME does not exist"
    ERRORS=$((ERRORS + 1))
  else
    echo "  OK: HERMES_HOME=$PLIST_HERMES_HOME"
  fi
fi

# Summary
echo ""
if [ "$ERRORS" -gt 0 ]; then
  echo "PREFLIGHT FAILED: $ERRORS issue(s) found"
  echo "Run with --fix to auto-repair, or fix manually before proceeding"
  exit 1
else
  echo "PREFLIGHT PASSED: all checks OK"
  exit 0
fi
