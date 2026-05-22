#!/usr/bin/env bash
# install.sh — Hermes repo setup: validate, correct, and install all components.
#
# Usage: bash scripts/install.sh [--fix] [--skip-launchd] [--verbose]
#
# Modes:
#   Default (check):  validate every component, report PASS/FAIL/WARN, exit 0 if all pass
#   --fix:            correct what can be auto-fixed (create dirs, sync config, load plists)
#
# What it validates/fixes:
#   1. Hermes binary installed and on PATH
#   2. Required directories exist (staging + prod)
#   3. config.yaml parity between staging and prod (except port)
#   4. API keys available in shell environment
#   5. LaunchAgent plists installed and loaded in launchd
#   5b. No duplicate plists sharing the same HERMES_HOME
#   6. Gateways running, bound to expected ports, auth-profiles.json present
#   7. Slack connectivity (token present, no token conflict)
#   8. mem0 server running
#   9. Provider registry consistency (no duplicate entries)
#  10. launchd-env-wrapper.sh present and executable
set -euo pipefail

# Require bash 4+ for associative arrays (macOS ships bash 3.2)
# Auto re-exec via Homebrew bash if available
if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  for _bash4 in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [[ -x "$_bash4" ]] && "$_bash4" -c '[[ ${BASH_VERSINFO[0]} -ge 4 ]]' 2>/dev/null; then
      exec "$_bash4" "$0" "$@"
    fi
  done
  echo "ERROR: bash 4+ required (found ${BASH_VERSION:-unknown}). Install with: brew install bash" >&2
  exit 1
fi


# ── Configuration ──────────────────────────────────────────────
HERMES_BIN="${HERMES_BIN:-hermes}"
HERMES_STAGING_HOME="${HERMES_STAGING_HOME:-$HOME/.smartclaw}"
HERMES_PROD_HOME="${HERMES_PROD_HOME:-$HOME/.smartclaw_prod}"
STAGING_PORT="${HERMES_STAGING_PORT:-8643}"
PROD_PORT="${HERMES_PROD_PORT:-8642}"
LAUNCHD_DIR="$HOME/Library/LaunchAgents"
U="$(id -u)"

FIX_MODE=false
SKIP_LAUNCHD=false
VERBOSE=false

for arg in "$@"; do
  case "$arg" in
    --fix)          FIX_MODE=true ;;
    --skip-launchd) SKIP_LAUNCHD=true ;;
    --verbose)      VERBOSE=true ;;
    --uninstall)
      echo "ERROR: --uninstall is no longer supported. Use 'launchctl bootout' directly." >&2
      echo "  launchctl bootout gui/$(id -u)/<plist-label>" >&2
      exit 1
      ;;
    --help|-h)
      echo "Usage: bash scripts/install.sh [--fix] [--skip-launchd] [--verbose]"
      echo ""
      echo "  --fix          Auto-fix issues found (create dirs, sync config, load plists)"
      echo "  --skip-launchd Skip launchd plist installation/loading"
      echo "  --verbose      Show detailed output"
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      echo "Usage: bash scripts/install.sh [--fix] [--skip-launchd] [--verbose]" >&2
      exit 1
      ;;
  esac
done

# ── Output helpers ─────────────────────────────────────────────
PASS=0; FAIL=0; WARN=0; FIX_COUNT=0

pass() { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }
warn() { printf '  [WARN] %s\n' "$1"; WARN=$((WARN+1)); }
info() { printf '  [INFO] %s\n' "$1"; }
fixed() { printf '  [FIX]  %s\n' "$1"; FIX_COUNT=$((FIX_COUNT+1)); FAIL=$((FAIL>0 ? FAIL-1 : 0)); }
verbose() { $VERBOSE && printf '  [DBG]  %s\n' "$1" || true; }

header() { printf '\n=== %s ===\n' "$1"; }

# ── 1. Hermes binary ─────────────────────────────────────────
check_hermes_binary() {
  header "1. Hermes binary"
  local bin_path
  bin_path="$(command -v "$HERMES_BIN" 2>/dev/null || true)"
  if [[ -n "$bin_path" ]]; then
    local version
    version="$("$HERMES_BIN" --version 2>/dev/null | tr '\n' ' ' | sed 's/ *$//' || echo 'unknown')"
    pass "hermes binary: $bin_path ($version)"

    if echo "$version" | grep -qi "behind"; then
      warn "Hermes update available — run 'hermes update'"
    fi
  else
    fail "hermes binary not found on PATH"
    if $FIX_MODE; then
      info "Install with: pip install hermes-agent (or brew install hermes-agent)"
    fi
  fi
}

# ── 2. Required directories ──────────────────────────────────
check_directories() {
  header "2. Directory structure"
  for dir in "$HERMES_STAGING_HOME" "$HERMES_PROD_HOME"; do
    local label
    label="$(basename "$dir")"
    if [[ -d "$dir" ]]; then
      pass "$label directory exists"
    else
      fail "$label directory missing ($dir)"
      if $FIX_MODE; then
        mkdir -p "$dir"
        fixed "created $dir"
      fi
    fi
  done

  for base in "$HERMES_STAGING_HOME" "$HERMES_PROD_HOME"; do
    local label
    label="$(basename "$base")"
    for subdir in logs agents; do
      if [[ -d "$base/$subdir" ]]; then
        pass "$label/$subdir exists"
      else
        fail "$label/$subdir missing"
        if $FIX_MODE; then
          mkdir -p "$base/$subdir"
          fixed "created $base/$subdir"
        fi
      fi
    done
  done
}

# ── 3. Config parity ──────────────────────────────────────────
check_config_parity() {
  header "3. Config parity (staging <-> prod)"
  local staging_config="$HERMES_STAGING_HOME/config.yaml"
  local prod_config="$HERMES_PROD_HOME/config.yaml"

  if [[ ! -f "$staging_config" ]]; then
    fail "staging config.yaml missing ($staging_config)"
    return
  fi
  if [[ ! -f "$prod_config" ]]; then
    fail "prod config.yaml missing ($prod_config)"
    if $FIX_MODE && [[ -f "$staging_config" ]]; then
      python3 -c "
import yaml, shutil
shutil.copy2('$staging_config', '$prod_config')
with open('$prod_config') as f: d = yaml.safe_load(f) or {}
d.setdefault('platforms', {}).setdefault('api_server', {}).setdefault('extra', {})['port'] = $PROD_PORT
d.setdefault('slack', {})['require_mention'] = False
with open('$prod_config', 'w') as f: yaml.dump(d, f, default_flow_style=False, allow_unicode=True)
"
      fixed "created prod config from staging (port set to $PROD_PORT, require_mention set to False)"
    fi
    return
  fi

  pass "both config.yaml files exist"

  # Normalize both configs (zero out port, normalize require_mention) and compare
  local diff_output
  diff_output="$(diff <(python3 -c "
import yaml, sys
d = yaml.safe_load(open('$staging_config')) or {}
if isinstance(d, dict):
    d.setdefault('platforms', {}).setdefault('api_server', {}).setdefault('extra', {})['port'] = 0
    d.setdefault('slack', {})['require_mention'] = None
yaml.dump(d, sys.stdout, default_flow_style=False, allow_unicode=True)
" 2>/dev/null || echo "STAGING_PARSE_ERROR") <(python3 -c "
import yaml, sys
d = yaml.safe_load(open('$prod_config')) or {}
if isinstance(d, dict):
    d.setdefault('platforms', {}).setdefault('api_server', {}).setdefault('extra', {})['port'] = 0
    d.setdefault('slack', {})['require_mention'] = None
yaml.dump(d, sys.stdout, default_flow_style=False, allow_unicode=True)
" 2>/dev/null || echo "PROD_PARSE_ERROR") 2>&1)" || true

  if [[ -z "$diff_output" ]]; then
    pass "config.yaml parity OK (ignoring port, require_mention)"
  else
    fail "config.yaml differs between staging and prod"
    $VERBOSE && echo "$diff_output" | head -20
    if $FIX_MODE; then
      python3 -c "
import yaml, shutil
shutil.copy2('$staging_config', '$prod_config')
with open('$prod_config') as f: d = yaml.safe_load(f) or {}
d.setdefault('platforms', {}).setdefault('api_server', {}).setdefault('extra', {})['port'] = $PROD_PORT
d.setdefault('slack', {})['require_mention'] = False
with open('$prod_config', 'w') as f: yaml.dump(d, f, default_flow_style=False, allow_unicode=True)
"
      fixed "synced staging config -> prod (port set to $PROD_PORT, require_mention set to False)"
    fi
  fi

  # Verify ports specifically
  local prod_port_val staging_port_val
  prod_port_val="$(python3 -c "
import yaml
d = yaml.safe_load(open('$prod_config'))
print(d.get('platforms',{}).get('api_server',{}).get('extra',{}).get('port','?'))
" 2>/dev/null || echo '?')"
  staging_port_val="$(python3 -c "
import yaml
d = yaml.safe_load(open('$staging_config'))
print(d.get('platforms',{}).get('api_server',{}).get('extra',{}).get('port','?'))
" 2>/dev/null || echo '?')"

  if [[ "$prod_port_val" == "$PROD_PORT" ]]; then
    pass "prod config port = $PROD_PORT"
  else
    fail "prod config port = $prod_port_val (expected $PROD_PORT)"
  fi

  if [[ "$staging_port_val" == "$STAGING_PORT" ]]; then
    pass "staging config port = $STAGING_PORT"
  else
    warn "staging config port = $staging_port_val (expected $STAGING_PORT)"
  fi
}

# ── 4. API keys ───────────────────────────────────────────────
check_api_keys() {
  header "4. API keys (from shell environment)"

  local required_keys=( "WAFER_API_KEY" "SLACK_APP_TOKEN" "SLACK_BOT_TOKEN" )
  local optional_keys=( "MINIMAX_API_KEY" "MEM0_API_KEY" "HERMES_STAGING_SLACK_APP_TOKEN" "HERMES_STAGING_SLACK_BOT_TOKEN" )

  for key in "${required_keys[@]}"; do
    local val
    val="$(bash -lc "printf '%s' \"\${$key:-}\"" 2>/dev/null || true)"
    if [[ -n "$val" && "$val" != "your-"* && "$val" != *"REDACTED"* ]]; then
      pass "$key present (${#val} chars)"
    else
      fail "$key missing or placeholder"
    fi
  done

  for key in "${optional_keys[@]}"; do
    local val
    val="$(bash -lc "printf '%s' \"\${$key:-}\"" 2>/dev/null || true)"
    if [[ -n "$val" && "$val" != "your-"* ]]; then
      pass "$key present (${#val} chars)"
    else
      warn "$key not set (optional)"
    fi
  done

  # Staging slack token separation — actually compare against prod tokens
  local staging_app staging_bot prod_app prod_bot
  staging_app="$(bash -lc 'printf "%s" "${HERMES_STAGING_SLACK_APP_TOKEN:-}"' 2>/dev/null || true)"
  staging_bot="$(bash -lc 'printf "%s" "${HERMES_STAGING_SLACK_BOT_TOKEN:-}"' 2>/dev/null || true)"
  prod_app="$(bash -lc 'printf "%s" "${SLACK_APP_TOKEN:-}"' 2>/dev/null || true)"
  prod_bot="$(bash -lc 'printf "%s" "${SLACK_BOT_TOKEN:-}"' 2>/dev/null || true)"
  if [[ -z "$staging_app" || -z "$staging_bot" ]]; then
    warn "staging Slack tokens not configured — staging and prod share SLACK_APP_TOKEN (crash risk on simultaneous restart)"
  elif [[ "$staging_app" == "$prod_app" || "$staging_bot" == "$prod_bot" ]]; then
    fail "staging Slack tokens are identical to prod — this causes the crash conflict from the 12.6h outage"
  else
    pass "staging Slack tokens separate from prod"
  fi
}

# ── 5. LaunchAgent plists ─────────────────────────────────────
check_plists() {
  header "5. LaunchAgent plists"

  check_one_plist() {
    local label="$1"
    local plist_name="$2"
    local plist_path="$LAUNCHD_DIR/$plist_name"
    local expected_home="$3"

    if [[ ! -f "$plist_path" ]]; then
      fail "$label plist missing ($plist_path)"
      if $FIX_MODE; then
        generate_hermes_plist "$label" "$plist_path" "$expected_home"
        fixed "created $plist_path"
        # Bootstrap the newly created plist so subsequent checks find it loaded
        if ! $SKIP_LAUNCHD; then
          launchctl bootstrap "gui/$U" "$plist_path" 2>/dev/null || true
          launchctl kickstart "gui/$U/$label" 2>/dev/null || true
          info "bootstrapped newly created $label"
        fi
      fi
      return
    fi

    pass "$label plist exists"

    # Verify HERMES_HOME in plist
    local plist_home
    plist_home="$(python3 -c "
import plistlib
with open('$plist_path', 'rb') as f: d = plistlib.load(f)
print(d.get('EnvironmentVariables', {}).get('HERMES_HOME', 'MISSING'))
" 2>/dev/null || echo 'PARSE_ERROR')"

    if [[ "$plist_home" == "$expected_home" ]]; then
      pass "$label HERMES_HOME = $expected_home"
    else
      fail "$label HERMES_HOME = $plist_home (expected $expected_home)"
      if $FIX_MODE; then
        python3 -c "
import plistlib
with open('$plist_path', 'rb') as f: d = plistlib.load(f)
d['EnvironmentVariables']['HERMES_HOME'] = '$expected_home'
with open('$plist_path', 'wb') as f: plistlib.dump(d, f)
"
        fixed "updated $label HERMES_HOME -> $expected_home"
        # Reload the LaunchAgent so the live process picks up the new env
        if ! $SKIP_LAUNCHD; then
          launchctl bootout "gui/$U/$label" 2>/dev/null || true
          launchctl bootstrap "gui/$U" "$plist_path" 2>/dev/null || true
          launchctl kickstart "gui/$U/$label" 2>/dev/null || true
          info "reloaded $label to apply HERMES_HOME change"
        fi
      fi
    fi

    # Verify no --replace flag in ProgramArguments (causes draining deadlock)
    local has_replace
    has_replace="$(python3 -c "
import plistlib
with open('$plist_path', 'rb') as f: d = plistlib.load(f)
args = d.get('ProgramArguments', [])
print('yes' if '--replace' in args else 'no')
" 2>/dev/null || echo 'error')"

    if [[ "$has_replace" == "yes" ]]; then
      fail "$label plist has --replace flag (causes draining deadlock — gateway refuses new messages)"
      if $FIX_MODE; then
        python3 -c "
import plistlib
with open('$plist_path', 'rb') as f: d = plistlib.load(f)
args = d.get('ProgramArguments', [])
d['ProgramArguments'] = [a for a in args if a != '--replace']
with open('$plist_path', 'wb') as f: plistlib.dump(d, f)
"
        fixed "removed --replace from $label ProgramArguments"
      fi
    elif [[ "$has_replace" == "no" ]]; then
      pass "$label plist has no --replace flag"
    fi

    # Check if loaded in launchd
    if $SKIP_LAUNCHD; then
      warn "$label: launchd check skipped"
      return
    fi

    local loaded
    loaded="$(launchctl list 2>/dev/null | ( grep "$label" || true ) )"
    if [[ -n "$loaded" ]]; then
      local pid
      pid="$(echo "$loaded" | awk '{print $1}' | head -1)"
      if [[ "$pid" =~ ^[0-9]+$ ]] && [[ "$pid" -gt 0 ]]; then
        pass "$label loaded in launchd (PID $pid)"
      else
        warn "$label in launchd but no active PID (may be in backoff after crash storm)"
        if $FIX_MODE; then
          launchctl bootout "gui/$U/$label" 2>/dev/null || true
          sleep 1
          launchctl bootstrap "gui/$U" "$plist_path" 2>/dev/null || true
          launchctl kickstart "gui/$U/$label" 2>/dev/null || true
          info "re-bootstrapped $label"
          # Verify single-instance — multiple hermes-gateway PIDs cause lock storms
          local gw_count
          gw_count="$(pgrep -f "hermes.*gateway" 2>/dev/null | wc -l | tr -d ' ' || true)"
          : "${gw_count:=0}"
          if [[ "$gw_count" -gt 1 ]]; then
            warn "Multiple hermes gateway processes detected ($gw_count) after re-bootstrap"
          fi
        fi
      fi
    else
      fail "$label NOT loaded in launchd"
      if $FIX_MODE; then
        launchctl bootstrap "gui/$U" "$plist_path" 2>/dev/null || true
        launchctl kickstart "gui/$U/$label" 2>/dev/null || true
        fixed "bootstrapped and started $label"
        # Verify single-instance — multiple hermes-gateway PIDs cause lock storms
        local gw_count
        gw_count="$(pgrep -f "hermes.*gateway" 2>/dev/null | wc -l | tr -d ' ' || true)"
        : "${gw_count:=0}"
        if [[ "$gw_count" -gt 1 ]]; then
          warn "Multiple hermes gateway processes detected ($gw_count) — potential lock storm"
          warn "Kill orphans: pkill -f 'hermes.*gateway' && launchctl kickstart gui/$U/$label"
        fi
      fi
    fi
  }

  check_one_plist "ai.smartclaw.prod"         "ai.smartclaw.prod.plist"         "$HERMES_PROD_HOME"
  check_one_plist "ai.smartclaw-staging"      "ai.smartclaw-staging.plist"      "$HERMES_STAGING_HOME"

  # mem0-server has a custom plist (python3 + mem0_server.py, not hermes gateway)
  # Only check existence and HERMES_HOME — don't attempt to generate
  check_mem0_plist

  # Check for conflicting plists sharing the same HERMES_HOME
  check_duplicate_plists
}

check_mem0_plist() {
  local label="ai.smartclaw-mem0-server"
  local plist_path="$LAUNCHD_DIR/ai.smartclaw-mem0-server.plist"
  local expected_home="$HERMES_PROD_HOME"

  if [[ ! -f "$plist_path" ]]; then
    fail "$label plist missing ($plist_path) — requires manual creation (non-gateway service)"
    return
  fi
  pass "$label plist exists"

  local plist_home
  plist_home="$(python3 -c "
import plistlib
with open('$plist_path', 'rb') as f: d = plistlib.load(f)
print(d.get('EnvironmentVariables', {}).get('HERMES_HOME', 'MISSING'))
" 2>/dev/null || echo 'PARSE_ERROR')"

  if [[ "$plist_home" == "$expected_home" ]]; then
    pass "$label HERMES_HOME = $expected_home"
  else
    fail "$label HERMES_HOME = $plist_home (expected $expected_home)"
    if $FIX_MODE; then
      python3 -c "
import plistlib
with open('$plist_path', 'rb') as f: d = plistlib.load(f)
d['EnvironmentVariables']['HERMES_HOME'] = '$expected_home'
with open('$plist_path', 'wb') as f: plistlib.dump(d, f)
"
      fixed "updated $label HERMES_HOME -> $expected_home"
      # Reload the LaunchAgent so the live process picks up the new env
      if ! $SKIP_LAUNCHD; then
        launchctl bootout "gui/$U/$label" 2>/dev/null || true
        launchctl bootstrap "gui/$U" "$plist_path" 2>/dev/null || true
        launchctl kickstart "gui/$U/$label" 2>/dev/null || true
        info "reloaded $label to apply HERMES_HOME change"
      fi
    fi
  fi

  if $SKIP_LAUNCHD; then
    warn "$label: launchd check skipped"
    return
  fi

  local loaded
  loaded="$(launchctl list 2>/dev/null | grep "$label" || true)"
  if [[ -n "$loaded" ]]; then
    local pid
    pid="$(echo "$loaded" | awk '{print $1}' | head -1)"
    if [[ "$pid" =~ ^[0-9]+$ ]] && [[ "$pid" -gt 0 ]]; then
      pass "$label loaded in launchd (PID $pid)"
    else
      warn "$label in launchd but no active PID"
      if $FIX_MODE; then
        launchctl bootout "gui/$U/$label" 2>/dev/null || true
        sleep 1
        launchctl bootstrap "gui/$U" "$plist_path" 2>/dev/null || true
        launchctl kickstart "gui/$U/$label" 2>/dev/null || true
        info "re-bootstrapped $label"
      fi
    fi
  else
    warn "$label not loaded in launchd"
    if $FIX_MODE; then
      launchctl bootstrap "gui/$U" "$plist_path" 2>/dev/null || true
      launchctl kickstart "gui/$U/$label" 2>/dev/null || true
      info "bootstrapped and started $label"
    fi
  fi
}

check_duplicate_plists() {
  verbose "Checking for plists sharing the same HERMES_HOME..."
  local -A home_to_plists
  # Canonical labels that must never be deleted as orphans
  local canonical_set="ai.smartclaw.prod ai.smartclaw-staging ai.smartclaw-mem0-server"
  local dupes_found=0
  # Scan ALL hermes plists, but allow known exceptions:
  # - prod + mem0-server intentionally share HERMES_PROD_HOME
  for plist_path in "$LAUNCHD_DIR"/ai.smartclaw*.plist; do
    [[ -f "$plist_path" ]] || continue
    local plist_home plist_label
    plist_home="$(python3 -c "
import plistlib
with open('$plist_path', 'rb') as f: d = plistlib.load(f)
print(d.get('EnvironmentVariables', {}).get('HERMES_HOME', 'MISSING'))
" 2>/dev/null || echo 'PARSE_ERROR')"
    plist_label="$(basename "$plist_path" .plist)"
    if [[ -n "$plist_home" && "$plist_home" != "MISSING" && "$plist_home" != "PARSE_ERROR" ]]; then
      if [[ -n "${home_to_plists[$plist_home]:-}" ]]; then
        local existing="${home_to_plists[$plist_home]}"
        # Allow prod+mem0 sharing the same HERMES_HOME (by design)
        # Check if the new label is allowed alongside ALL existing labels for this home
        local is_allowed=true
        local all_labels="$existing $plist_label"
        for lbl in $all_labels; do
          if [[ "$lbl" != "ai.smartclaw.prod" && "$lbl" != *mem0* ]]; then
            is_allowed=false
            break
          fi
        done
        if $is_allowed; then
          pass "prod+mem0 share HERMES_HOME=$plist_home (by design)"
        else
          fail "Duplicate HERMES_HOME=$plist_home in plists: $existing + $plist_label"
          dupes_found=1
          if $FIX_MODE; then
            # Only delete non-canonical plists — never remove ai.smartclaw.prod/staging/mem0-server
            local orphan_label=""
            for lbl in $plist_label $existing; do
              if ! echo "$canonical_set" | grep -qw "$lbl"; then
                orphan_label="$lbl"
                break
              fi
            done
            if [[ -n "$orphan_label" ]]; then
              local orphan_path="$LAUNCHD_DIR/${orphan_label}.plist"
              launchctl bootout "gui/$U/$orphan_label" 2>/dev/null || true
              rm -f "$orphan_path"
              fixed "removed orphan plist $orphan_label (bootout + deleted file)"
            else
              warn "Cannot auto-fix: both plists are canonical — resolve manually"
            fi
          fi
        fi
        # Accumulate labels so a 3rd plist triggers correctly
        home_to_plists[$plist_home]="$existing $plist_label"
      else
        home_to_plists[$plist_home]="$plist_label"
      fi
    fi
  done
  if [[ "$dupes_found" -eq 0 ]]; then
    pass "no unexpected duplicate HERMES_HOME assignments across plists"
  fi
}

generate_hermes_plist() {
  local label="$1"
  local plist_path="$2"
  local hermes_home="$3"

  local log_dir="$hermes_home/logs"
  mkdir -p "$log_dir"

  local working_dir_line=""
  if [[ "$label" == *"prod"* || "$label" == *"mem0"* ]]; then
    working_dir_line="    <key>WorkingDirectory</key>
    <string>$hermes_home</string>"
  fi

  # Align with config.yaml + deploy.sh: staging channels mention-gated; prod does not.
  local slack_require_mention="false"
  if [[ "$label" == *"staging"* ]]; then
    slack_require_mention="true"
  fi

  # Resolve hermes binary path for plist ProgramArguments
  local hermes_bin_path
  hermes_bin_path="$(command -v "$HERMES_BIN" 2>/dev/null || true)"
  if [[ -z "$hermes_bin_path" ]]; then
    for candidate in /opt/homebrew/bin/hermes /usr/local/bin/hermes "$HOME/.local/bin/hermes"; do
      if [[ -x "$candidate" ]]; then
        hermes_bin_path="$candidate"
        break
      fi
    done
  fi
  : "${hermes_bin_path:=/opt/homebrew/bin/hermes}"
  [[ ! -x "$hermes_bin_path" ]] && warn "hermes binary not found; plist will use $hermes_bin_path (may fail at launch)"

  # Determine ProgramArguments based on service type
  # Use the appropriate env-wrapper (from hermes_home, not always staging)
  local wrapper_path="$hermes_home/scripts/launchd-env-wrapper.sh"
  local program_args
  if [[ "$label" == *"mem0"* ]]; then
    program_args="        <string>/bin/bash</string>
        <string>$wrapper_path</string>
        <string>$hermes_bin_path</string>
        <string>mem0</string>
        <string>server</string>
        <string>start</string>"
  else
    program_args="        <string>/bin/bash</string>
        <string>$wrapper_path</string>
        <string>$hermes_bin_path</string>
        <string>gateway</string>
        <string>run</string>"
  fi

  cat > "$plist_path" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HERMES_HOME</key>
        <string>$hermes_home</string>
        <key>HERMES_LOG_LEVEL</key>
        <string>INFO</string>
        <key>PYTHONUNBUFFERED</key>
        <string>1</string>
        <key>SLACK_ALLOW_BOTS</key>
        <string>mentions</string>
        <key>SLACK_REQUIRE_MENTION</key>
        <string>$slack_require_mention</string>
    </dict>
    <key>KeepAlive</key>
    <true/>
    <key>Label</key>
    <string>$label</string>
    <key>ProgramArguments</key>
    <array>
$program_args
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardErrorPath</key>
    <string>$log_dir/gateway.error.log</string>
    <key>StandardOutPath</key>
    <string>$log_dir/gateway.log</string>
    <key>ThrottleInterval</key>
    <integer>30</integer>
$working_dir_line
</dict>
</plist>
PLIST
}

# ── 6. Gateways running ──────────────────────────────────────
check_gateways() {
  header "6. Gateway health"

  if $SKIP_LAUNCHD; then
    warn "gateway health check skipped"
    return
  fi

  check_one_gateway() {
    local label="$1"
    local port="$2"

    # Port check — take first PID only (lsof -t may return multiple for IPv4/IPv6)
    local port_pid
    port_pid="$(lsof -t -i :"$port" 2>/dev/null | head -1 || true)"
    if [[ -n "$port_pid" ]]; then
      pass "$label port $port bound (PID $port_pid)"

      # Verify PID matches launchd — mismatch means wrong process holds port
      local launchd_pid
      launchd_pid="$(launchctl list 2>/dev/null | ( grep "$label" || true ) | awk '{print $1}' | head -1 || true)"
      if [[ "$launchd_pid" == "$port_pid" ]]; then
        pass "$label launchd PID matches port PID"
      else
        fail "$label launchd PID ($launchd_pid) != port PID ($port_pid) — different process holds port"
        if $FIX_MODE; then
          warn "Kill the orphaned PID $port_pid and restart $label, or run: launchctl kickstart gui/$U/$label"
        fi
      fi
    else
      fail "$label port $port not bound"
    fi

    # HTTP health check
    local health
    health="$(curl -fsS -m 5 "http://127.0.0.1:$port/health" 2>/dev/null || true)"
    if [[ -n "$health" ]]; then
      pass "$label /health -> $health"
    else
      fail "$label /health no response on port $port"
    fi

    # Auth profiles check — HTTP 200 doesn't prove the gateway is functional.
    # Hermes resolves API keys from: config.yaml inline → auth-profiles.json → .env
    local plist_home
    plist_home="$(python3 -c "
import plistlib
plist_path = '$LAUNCHD_DIR/$label.plist'
try:
    with open(plist_path, 'rb') as f: d = plistlib.load(f)
    print(d.get('EnvironmentVariables', {}).get('HERMES_HOME', ''))
except: print('')
" 2>/dev/null || true)"
    local has_auth=false
    if [[ -n "$plist_home" && -f "$plist_home/agents/main/agent/auth-profiles.json" ]]; then
      has_auth=true
    elif [[ -n "$plist_home" && -f "$plist_home/config.yaml" ]]; then
      # Check if config.yaml has inline api_key values (Hermes resolves these)
      local has_inline_key
      has_inline_key="$(python3 -c "
import yaml
with open('$plist_home/config.yaml') as f: d = yaml.safe_load(f)
providers = d.get('providers', {})
for name, prov in providers.items():
    if prov.get('api_key'):
        print('yes')
        break
else:
    print('no')
" 2>/dev/null || echo 'no')"
      if [[ "$has_inline_key" == "yes" ]]; then
        has_auth=true
      fi
    fi
    if $has_auth; then
      pass "$label API key source present (auth-profiles.json or config.yaml inline)"
    else
      fail "$label missing API key source (no auth-profiles.json and no inline api_key in config.yaml)"
      if $FIX_MODE; then
        warn "Run 'hermes login' in $plist_home to regenerate auth-profiles.json"
      fi
    fi
  }

  check_one_gateway "ai.smartclaw.prod"    "$PROD_PORT"
  check_one_gateway "ai.smartclaw-staging" "$STAGING_PORT"
}

# ── 7. Slack token conflict check ────────────────────────────
check_slack_conflict() {
  header "7. Slack token conflict check"

  local wrapper="$HERMES_STAGING_HOME/scripts/launchd-env-wrapper.sh"
  # Existence is validated in check 10 (check_env_wrapper) — only check token routing here
  if [[ -f "$wrapper" ]]; then
    if grep -q "HERMES_STAGING_SLACK_APP_TOKEN" "$wrapper" \
      && grep -q "HERMES_STAGING_SLACK_BOT_TOKEN" "$wrapper"; then
      pass "wrapper routes staging Slack tokens"
    else
      warn "wrapper does not route both staging Slack tokens"
    fi
  fi

  if ! $SKIP_LAUNCHD; then
    # Check tail of error logs for active token conflicts (not historical)
    # Use grep + wc (not grep -c) to avoid exit-code issues under set -e
    local tail_conflicts
    tail_conflicts="$(tail -50 "$HERMES_PROD_HOME/logs/gateway.error.log" 2>/dev/null | grep -c "Slack app token already in use" 2>/dev/null || true)"
    : "${tail_conflicts:=0}"
    local staging_tail_conflicts
    staging_tail_conflicts="$(tail -50 "$HERMES_STAGING_HOME/logs/gateway.error.log" 2>/dev/null | grep -c "Slack app token already in use" 2>/dev/null || true)"
    : "${staging_tail_conflicts:=0}"
    local total_recent=$(( tail_conflicts + staging_tail_conflicts ))
    if [[ "$total_recent" -gt 0 ]]; then
      fail "Active Slack token conflict detected ($total_recent recent occurrences in error log tail)"
      warn "Root cause: staging and prod may share SLACK_APP_TOKEN"
    else
      pass "no active Slack token conflicts (historical entries may exist deeper in error log)"
    fi
  fi
}

# ── 8. Provider registry consistency ────────────────────────
check_provider_registry() {
  header "8. Provider registry consistency"
  local config="$HERMES_STAGING_HOME/config.yaml"
  if [[ ! -f "$config" ]]; then
    fail "config.yaml missing — cannot check providers"
    return
  fi

  local overlap
  overlap="$(python3 -c "
import yaml, sys
d = yaml.safe_load(open('$config'))
providers = set(d.get('providers', {}).keys())
custom = set(x.get('name', '') for x in d.get('custom_providers', []))
dupes = providers & custom
if dupes:
    print('DUPES:' + ','.join(dupes))
    sys.exit(0)
else:
    print('ok')
" 2>/dev/null || echo 'PARSE_ERROR')"

  if [[ "$overlap" == "ok" ]]; then
    pass "no duplicate provider entries"
  elif [[ "$overlap" == "PARSE_ERROR" ]]; then
    fail "cannot parse config.yaml for provider check"
  elif [[ "$overlap" == DUPES:* ]]; then
    local dupe_names="${overlap#DUPES:}"
    fail "duplicate provider entries: $dupe_names (causes 401 on compression)"
    if $FIX_MODE; then
      for _cfg in "$config" "$HERMES_PROD_HOME/config.yaml"; do
        [[ -f "$_cfg" ]] || continue
        python3 -c "
import yaml
with open('$_cfg') as f: d = yaml.safe_load(f)
p_names = set(d.get('providers', {}).keys())
custom = d.get('custom_providers', [])
d['custom_providers'] = [x for x in custom if x.get('name','') not in p_names]
with open('$_cfg', 'w') as f: yaml.dump(d, f, default_flow_style=False, allow_unicode=True)
"
      done
      fixed "removed duplicate custom_providers entries from staging+prod"
    fi
  fi
}

# ── 9. mem0 server ────────────────────────────────────────────
check_mem0() {
  header "9. mem0 server"

  if $SKIP_LAUNCHD; then
    warn "mem0 server launchd check skipped"
    return
  fi

  local label="ai.smartclaw-mem0-server"
  local loaded
  loaded="$(launchctl list 2>/dev/null | grep "$label" || true)"

  if [[ -n "$loaded" ]]; then
    local pid
    pid="$(echo "$loaded" | awk '{print $1}' | head -1)"
    if [[ "$pid" =~ ^[0-9]+$ ]] && [[ "$pid" -gt 0 ]]; then
      pass "mem0 server running (PID $pid)"
    else
      warn "mem0 server loaded but no active PID"
    fi
  else
    warn "mem0 server not loaded in launchd"
  fi

  # Check local self-hosted mem0 server health
  local mem0_health
  mem0_health="$(curl -fsS -m 3 http://127.0.0.1:8000/health 2>/dev/null || echo "")"
  if [[ "$mem0_health" == *"ok"* ]]; then
    pass "self-hosted mem0 server healthy (port 8000)"
  else
    warn "self-hosted mem0 server not responding on port 8000"
  fi

  # MEM0_API_KEY is for cloud mem0 (api.mem0.ai) — required only if not using self-hosted
  local mem0_key
  mem0_key="$(bash -lc 'printf "%s" "${MEM0_API_KEY:-}"' 2>/dev/null || true)"
  if [[ -n "$mem0_key" ]]; then
    pass "MEM0_API_KEY set (cloud mem0 enabled)"
  elif [[ "$mem0_health" == *"ok"* ]]; then
    warn "MEM0_API_KEY not set — cloud mem0 disabled, but self-hosted mem0 is available"
  else
    warn "MEM0_API_KEY not set and no self-hosted mem0 — mem0 sync will fail"
  fi
}

# ── 10. launchd-env-wrapper.sh ────────────────────────────────
check_env_wrapper() {
  header "10. launchd-env-wrapper.sh"
  # Check both staging and prod wrapper paths (prod may use a symlink or copy)
  for home_dir in "$HERMES_STAGING_HOME" "$HERMES_PROD_HOME"; do
    local label
    label="$(basename "$home_dir")"
    local wrapper="$home_dir/scripts/launchd-env-wrapper.sh"
    if [[ -f "$wrapper" && -x "$wrapper" ]]; then
      pass "$label launchd-env-wrapper.sh exists and executable"
    elif [[ -f "$wrapper" ]]; then
      warn "$label launchd-env-wrapper.sh exists but not executable"
      if $FIX_MODE; then
        chmod +x "$wrapper"
        info "made $label launchd-env-wrapper.sh executable"
      fi
    else
      warn "$label launchd-env-wrapper.sh missing"
    fi
  done
}

# ── Run all checks ────────────────────────────────────────────
echo "=============================================================="
echo "  Hermes install.sh — setup validation & correction"
echo "  Mode: $([ "$FIX_MODE" = true ] && echo 'FIX (auto-correct)' || echo 'CHECK ONLY')"
echo "=============================================================="
echo ""

check_hermes_binary
check_directories
check_config_parity
check_api_keys
check_plists
check_gateways
check_slack_conflict
check_provider_registry
check_mem0
check_env_wrapper

# Patch AO doctor to accept canonical lifecycle-worker binary detection
# (wrapper path approved for this machine — see scripts/patch-ao-doctor-canonical-binary.sh)
_INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -x "${_INSTALL_DIR}/patch-ao-doctor-canonical-binary.sh" ]]; then
  "${_INSTALL_DIR}/patch-ao-doctor-canonical-binary.sh" || true
  _patch_exit=$?
  if [[ $_patch_exit -ne 0 ]]; then
    echo "  [WARN] patch-ao-doctor-canonical-binary.sh exited with code $_patch_exit" >&2
  fi
fi
unset _INSTALL_DIR

# ── Summary ───────────────────────────────────────────────────
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
echo "  WARN: $WARN"
if $FIX_MODE; then
  echo "  FIX:  $FIX_COUNT"
fi
echo ""

if [[ "$FAIL" -gt 0 ]]; then
  echo "Action required: $FAIL check(s) failed."
  if ! $FIX_MODE; then
    echo "Run with --fix to auto-correct what can be fixed."
  fi
  exit 1
else
  echo "All critical checks passed."
  exit 0
fi
