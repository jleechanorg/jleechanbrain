#!/usr/bin/env bash

set -u

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mctrl-doctor.XXXXXX")"
trap cleanup EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# LIVE_HERMES is resolved after launchd env hydration (below) — do not set here.
LAUNCHD_DIR="$HOME/Library/LaunchAgents"
# Prod/staging detection: check if running staging profile
if [[ "${HERMES_HOME:-}" == *"/config.staging.yaml" || "${HERMES_CONFIG_PATH:-}" == *"/config.staging.yaml" || "${HERMES_PROFILE:-}" == "staging" || "${HERMES_HOME:-}" == "${HOME}/.smartclaw" ]]; then
  if [[ -f "$LAUNCHD_DIR/ai.smartclaw.staging.plist" ]]; then
    GATEWAY_LABEL="ai.smartclaw.staging"
  elif [[ -f "$LAUNCHD_DIR/ai.smartclaw.gateway.plist" ]]; then
    GATEWAY_LABEL="ai.smartclaw.gateway"
  else
    GATEWAY_LABEL="ai.smartclaw.staging"
  fi
else
  if [[ -f "$LAUNCHD_DIR/ai.smartclaw.prod.plist" ]]; then
    GATEWAY_LABEL="ai.smartclaw.prod"
  else
    GATEWAY_LABEL="ai.smartclaw.prod"
  fi
fi
GATEWAY_PLIST="$LAUNCHD_DIR/$GATEWAY_LABEL.plist"
AO_DASHBOARD_LABEL="ai.agento.dashboard"
AO_DASHBOARD_LEGACY_LABEL="ai.agent-orchestrator.dashboard"
AO_DASHBOARD_PLIST="$LAUNCHD_DIR/$AO_DASHBOARD_LABEL.plist"
AO_DASHBOARD_LEGACY_PLIST="$LAUNCHD_DIR/$AO_DASHBOARD_LEGACY_LABEL.plist"
SCHEDULED_LABELS=(
  "ai.smartclaw.schedule.morning-log-review"
  "ai.smartclaw.schedule.docs-drift-review"
  "ai.smartclaw.schedule.cron-backup-sync"
  "ai.smartclaw.schedule.weekly-error-trends"
  "ai.smartclaw.schedule.daily-research"
  "ai.smartclaw.schedule.harness-analyzer-9am"
  "ai.smartclaw.schedule.orch-health-weekly"
  "ai.smartclaw.schedule.bug-hunt-9am"
  "ai.smartclaw.schedule.workspace-report-weekly"
)
MIGRATED_JOB_IDS=()

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
IS_DARWIN=0

convert_yaml_to_json() {
  local yaml_file="$1"
  local json_file="$2"
  local tmp_file="${json_file}.tmp"

  if command -v yq >/dev/null 2>&1; then
    if yq -o=json "$yaml_file" >"$tmp_file" 2>/dev/null; then
      mv "$tmp_file" "$json_file"
      return 0
    fi
  fi

  if python3 - "$yaml_file" >"$tmp_file" 2>/dev/null <<'PY'
import json
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as handle:
    print(json.dumps(yaml.safe_load(handle) or {}))
PY
  then
    mv "$tmp_file" "$json_file"
    return 0
  fi

  rm -f "$tmp_file"
  return 1
}

# Intercept jq and convert YAML files to JSON on-the-fly to support yaml config.yaml files.
# Conversion is fail-closed: a bad YAML file must not silently become an empty JSON query.
jq() {
  local args=()
  local file_idx=-1
  local i=0
  for arg in "$@"; do
    if [[ -f "$arg" && ( "$arg" == *".yaml" || "$arg" == *".yml" ) ]]; then
      file_idx=$i
    fi
    args+=("$arg")
    i=$((i + 1))
  done

  if [[ $file_idx -ne -1 ]]; then
    local yaml_file="${args[file_idx]}"
    local base_name
    base_name="$(basename "$yaml_file")"
    local json_file="$TMP_DIR/jq_conv_${base_name//[^[:alnum:]._-]/_}.json"
    
    if [[ ! -f "$json_file" || "$yaml_file" -nt "$json_file" ]]; then
      if ! convert_yaml_to_json "$yaml_file" "$json_file"; then
        printf 'doctor.sh: failed to convert YAML for jq: %s\n' "$yaml_file" >&2
        return 2
      fi
    fi
    args[file_idx]="$json_file"
  fi

  command jq "${args[@]}"
}

# Runtime invariants for the production profile. Override via env if needed.
# APPROVED VALUES (2026-04-10, user-approved): maxConcurrent=10, timeoutSeconds=600.
# Do NOT change these without explicit user approval. Changes enforced by doctor.sh exact-match checks.
EXPECTED_PRIMARY_MODEL="${HERMES_DOCTOR_EXPECTED_PRIMARY_MODEL:-minimax/MiniMax-M2.7}"
EXPECTED_MAX_CONCURRENT="${HERMES_DOCTOR_EXPECTED_MAX_CONCURRENT:-10}"
EXPECTED_SUBAGENT_MAX_CONCURRENT="${HERMES_DOCTOR_EXPECTED_SUBAGENT_MAX_CONCURRENT:-10}"
EXPECTED_TIMEOUT_SECONDS="${HERMES_DOCTOR_EXPECTED_TIMEOUT_SECONDS:-600}"
EXPECTED_MEM_EMBEDDER_PROVIDER="${HERMES_DOCTOR_EXPECTED_MEM_EMBEDDER_PROVIDER:-ollama}"

# WS/event-loop warning thresholds (advisory, not hard policy invariants).
WS_SAFE_TIMEOUT_SECONDS="${HERMES_DOCTOR_WS_SAFE_TIMEOUT_SECONDS:-600}"
WS_SAFE_MAX_CONCURRENT="${HERMES_DOCTOR_WS_SAFE_MAX_CONCURRENT:-10}"
WS_SAFE_MAX_SUBAGENT_CONCURRENT="${HERMES_DOCTOR_WS_SAFE_MAX_SUBAGENT_CONCURRENT:-10}"

# hermes gateway status/health use WebSocket RPC (CLI default 10s). Under event-loop pressure
# (Slack pong, mem0, embeds), RPC can exceed 10s while curl /health stays 200 — false FAIL in doctor.
GATEWAY_RPC_TIMEOUT_MS="${HERMES_DOCTOR_GATEWAY_RPC_TIMEOUT_MS:-30000}"

pass() {
  printf '[PASS] %s\n' "$1"
  PASS_COUNT=$((PASS_COUNT + 1))
}

warn() {
  printf '[WARN] %s\n' "$1"
  WARN_COUNT=$((WARN_COUNT + 1))
}

fail() {
  printf '[FAIL] %s\n' "$1"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

cleanup() {
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    rm -rf "$TMP_DIR"
  fi
}

launchd_job_is_running() {
  local label="$1"
  local state_file
  if [[ "$IS_DARWIN" -ne 1 || -z "$label" ]]; then
    return 1
  fi
  state_file="$TMP_DIR/launchctl-${label//[^[:alnum:]._-]/_}.txt"
  if ! launchctl print "gui/$(id -u)/$label" >"$state_file" 2>&1; then
    return 1
  fi
  grep -q 'state = running' "$state_file"
}

list_hermes_gateway_processes() {
  ps -axo pid=,command= 2>/dev/null | awk '
    index($0, "hermes gateway run") > 0 && index($0, "awk") == 0 {
      sub(/^[[:space:]]+/, "", $0)
      print
    }
  '
}

check_gateway_process_concurrency() {
  local proc_file="$TMP_DIR/hermes-gateway-processes.txt"
  local proc_count

  list_hermes_gateway_processes >"$proc_file" || true
  proc_count="$(wc -l <"$proc_file" | tr -d '[:space:]')"

  if [[ "$proc_count" =~ ^[0-9]+$ && "$proc_count" -gt 1 ]]; then
    fail "multiple live 'hermes gateway run' processes detected; verify prod/staging Socket Mode isolation before trusting Slack delivery: $(tr '\n' ';' <"$proc_file")"
  elif [[ "$proc_count" == "1" ]]; then
    pass "single live hermes gateway process detected"
  else
    warn "no live 'hermes gateway run' process found in process table"
  fi
}

config_get() {
  local cfg_path="$1"
  local dotted_path="$2"
  python3 - "$cfg_path" "$dotted_path" <<'PY' 2>/dev/null || true
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as handle:
    current = yaml.safe_load(handle) or {}

for part in sys.argv[2].split("."):
    if not isinstance(current, dict):
        current = ""
        break
    current = current.get(part, "")

if current is None:
    current = ""
print(current if isinstance(current, str) else "")
PY
}

check_shared_slack_socket_tokens() {
  local live_cfg="$1"
  local live_label="$2"
  local live_bot_token="$3"
  local live_app_token="$4"
  local other_cfg='' other_label='' other_profile=''
  local other_bot_raw='' other_bot_token='' other_app_raw='' other_app_token=''

  case "$live_label" in
    ai.smartclaw.prod)
      other_cfg="$HOME/.smartclaw/config.yaml"
      other_label="ai.smartclaw.staging"
      other_profile="staging"
      ;;
    ai.smartclaw.staging|ai.smartclaw.gateway)
      other_cfg="$HOME/.smartclaw/config.yaml"
      other_label="ai.smartclaw.prod"
      other_profile="prod"
      ;;
    *)
      return 0
      ;;
  esac

  # Also add a general concurrency check: if both staging/gateway and prod are running, fail.
  if [[ "$live_label" == "ai.smartclaw.prod" ]]; then
    if launchd_job_is_running "ai.smartclaw.staging" || launchd_job_is_running "ai.smartclaw.gateway"; then
      fail "Both prod (ai.smartclaw.prod) and staging/gateway (ai.smartclaw.staging) launchd jobs are running concurrently! This will cause Slack Socket Mode split-brain conflicts."
    fi
  elif [[ "$live_label" == "ai.smartclaw.staging" || "$live_label" == "ai.smartclaw.gateway" ]]; then
    if launchd_job_is_running "ai.smartclaw.prod"; then
      fail "Both staging/gateway (ai.smartclaw.staging) and prod (ai.smartclaw.prod) launchd jobs are running concurrently! This will cause Slack Socket Mode split-brain conflicts."
    fi
  fi

  if [[ ! -f "$other_cfg" ]]; then
    if [[ "$other_profile" == "staging" && -f "$HOME/.smartclaw/config.staging.yaml" ]]; then
      other_cfg="$HOME/.smartclaw/config.staging.yaml"
    else
      return 0
    fi
  fi

  other_bot_raw="$(config_get "$other_cfg" "channels.slack.botToken")"
  other_bot_token="$(resolve_secret_ref "$other_bot_raw")"
  other_app_raw="$(config_get "$other_cfg" "channels.slack.appToken")"
  other_app_token="$(resolve_secret_ref "$other_app_raw")"

  if is_placeholder_token "$live_bot_token" || is_placeholder_token "$live_app_token"; then
    return 0
  fi
  if is_placeholder_token "$other_bot_token" || is_placeholder_token "$other_app_token"; then
    return 0
  fi

  if [[ "$live_bot_token" == "$other_bot_token" && "$live_app_token" == "$other_app_token" ]]; then
    if launchd_job_is_running "$other_label"; then
      fail "Slack socket-mode tokens are shared with $other_profile ($other_cfg) while both launchd jobs are running; isolate one profile before trusting Slack delivery"
    else
      warn "Slack socket-mode tokens are shared with $other_profile ($other_cfg); do not run both profiles concurrently"
    fi
  else
    pass "Slack socket-mode tokens do not collide with $other_profile profile"
  fi
}

require_file() {
  local path="$1"
  local label="$2"
  if [[ -f "$path" ]]; then
    pass "$label present: $path"
  else
    fail "$label missing: $path"
  fi
}

require_dir() {
  local path="$1"
  local label="$2"
  if [[ -d "$path" ]]; then
    pass "$label present: $path"
  else
    fail "$label missing: $path"
  fi
}

require_cmd() {
  local cmd="$1"
  if command -v "$cmd" >/dev/null 2>&1; then
    pass "command available: $cmd"
  else
    fail "command missing: $cmd"
  fi
}

default_migrated_job_ids() {
  # All previously gateway-managed cron jobs have been migrated to launchd plists.
  # The jobs are tracked via their launchd plist labels (ai.smartclaw.schedule.*).
  # No legacy gateway-managed cron job IDs remain to check.
  cat <<'EOF'
EOF
}

load_migrated_job_ids() {
  while IFS= read -r id; do
    [[ -n "$id" ]] && MIGRATED_JOB_IDS+=("$id")
  done < <(jq -r '.migratedLaunchdJobIds[]?' "$LIVE_HERMES/cron/jobs.json" 2>/dev/null || true)
  if [[ ${#MIGRATED_JOB_IDS[@]} -eq 0 ]]; then
    while IFS= read -r id; do
      [[ -n "$id" ]] && MIGRATED_JOB_IDS+=("$id")
    done < <(default_migrated_job_ids)
  fi
}

detect_local_timezone() {
  local target
  target="$(readlink /etc/localtime 2>/dev/null || true)"
  if [[ "$target" == *"/zoneinfo/"* ]]; then
    echo "${target##*/zoneinfo/}"
    return 0
  fi
  echo "${TZ:-unknown}"
}

infer_gateway_profile_dir_from_port() {
  local gateway_port="${1:-}"
  case "$gateway_port" in
    8643) echo "$HOME/.smartclaw" ;;
    8644) echo "$HOME/.smartclaw" ;;
    *) echo "" ;;
  esac
}

detect_live_profile() {
  local root_ref="${HERMES_HOME:-${LIVE_HERMES:-}}"

  if [[ -n "${HERMES_DOCTOR_PROFILE:-}" ]]; then
    printf '%s' "$HERMES_DOCTOR_PROFILE"
    return 0
  fi
  if [[ "${root_ref%/}" == "${HOME}/.smartclaw" ]]; then
    printf 'prod'
    return 0
  fi
  if [[ "${root_ref%/}" == "${HOME}/.smartclaw" ]]; then
    printf 'staging'
    return 0
  fi
  printf 'prod'
}

expected_heartbeat_runtime_every_for_profile() {
  case "$1" in
    staging) printf '30m' ;;
    *) printf '5m' ;;
  esac
}

expected_gateway_port_for_profile() {
  case "$1" in
    staging) printf '8644' ;;
    *) printf '8643' ;;
  esac
}

expected_state_dir_for_profile() {
  case "$1" in
    staging) printf '%s/.smartclaw' "$HOME" ;;
    *) printf '%s/.smartclaw' "$HOME" ;;
  esac
}

detect_ao_dashboard_port() {
  if [[ -n "${HERMES_DOCTOR_AO_DASHBOARD_PORT:-}" ]]; then
    echo "$HERMES_DOCTOR_AO_DASHBOARD_PORT"
    return 0
  fi

  local plist_path="${1:-}"

  # Priority: launchd plist --port arg > agent-orchestrator.yaml port > fallback 3020
  if [[ -n "$plist_path" && -f "$plist_path" ]]; then
    local arg
    local prev_arg=""
    while IFS= read -r arg; do
      # Handle --port=<n>
      if [[ "$arg" =~ ^--port=([0-9]+)$ ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
      fi

      # Handle -p<n> compact form
      if [[ "$arg" =~ ^-p([0-9]+)$ ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
      fi

      # Handle "-p <n>" and "--port <n>" separate-argument forms
      if [[ "$prev_arg" == "-p" || "$prev_arg" == "--port" ]]; then
        if [[ "$arg" =~ ^[0-9]+$ ]]; then
          echo "$arg"
          return 0
        fi
      fi

      prev_arg="$arg"
    done < <(plutil -convert json -o - "$plist_path" 2>/dev/null | jq -r '.ProgramArguments[]?' 2>/dev/null || true)
  fi

  # Fall back to agent-orchestrator.yaml port (bd-yk9h: actual AO dashboard port is 3020)
  local _ao_yaml _yaml_port
  if [[ -n "${LIVE_HERMES:-}" ]]; then
    _ao_yaml="$LIVE_HERMES/agent-orchestrator.yaml"
    if [[ -f "$_ao_yaml" ]]; then
      _yaml_port="$(awk '/^port:/ {print $2; exit}' "$_ao_yaml" 2>/dev/null || true)"
      if [[ -n "$_yaml_port" && "$_yaml_port" =~ ^[0-9]+$ ]]; then
        echo "$_yaml_port"
        return 0
      fi
    fi
  fi
  _ao_yaml="$HOME/agent-orchestrator.yaml"
  if [[ -f "$_ao_yaml" ]]; then
    _yaml_port="$(awk '/^port:/ {print $2; exit}' "$_ao_yaml" 2>/dev/null || true)"
    if [[ -n "$_yaml_port" && "$_yaml_port" =~ ^[0-9]+$ ]]; then
      echo "$_yaml_port"
      return 0
    fi
  fi

  # Final fallback (bd-yk9h: was 3011 — wrong, actual default is 3020)
  echo "3020"
}

json_valid() {
  local file="$1"
  jq empty "$file" >/dev/null 2>&1
}

plist_extract_raw() {
  local key_path="$1"
  local plist_path="$2"
  local out=""
  out="$(plutil -extract "$key_path" raw -o - "$plist_path" 2>/dev/null)" || return 1
  printf '%s' "$out"
}

validate_heartbeat_config() {
  local cfg_path="$LIVE_HERMES/config.yaml"
  local every target prompt expected_runtime_every

  if jq -e 'has("_config_version")' "$cfg_path" >/dev/null 2>&1; then
    pass "heartbeat config: skipped legacy validation for new-style config.yaml"
    return
  fi

  every="$(jq -r '.agents.defaults.heartbeat.every // empty' "$cfg_path" 2>/dev/null || true)"
  target="$(jq -r '.agents.defaults.heartbeat.target // empty' "$cfg_path" 2>/dev/null || true)"
  prompt="$(jq -r '.agents.defaults.heartbeat.prompt // empty' "$cfg_path" 2>/dev/null || true)"
  expected_runtime_every="$(expected_heartbeat_runtime_every_for_profile "$LIVE_PROFILE")"

  if [[ "$every" == "5m" ]]; then
    pass 'heartbeat config: agents.defaults.heartbeat.every is 5m'
  else
    fail "heartbeat config: agents.defaults.heartbeat.every must be 5m (got '$every')"
  fi

  if [[ "$target" == "last" ]]; then
    pass 'heartbeat config: agents.defaults.heartbeat.target is last'
  else
    fail "heartbeat config: agents.defaults.heartbeat.target must be last (got '$target')"
  fi

  if [[ "$prompt" == *"HEARTBEAT.md"* && "$prompt" == *"HEARTBEAT_OK"* ]]; then
    pass 'heartbeat config: prompt references HEARTBEAT.md and HEARTBEAT_OK contract'
  else
    fail 'heartbeat config: prompt must reference HEARTBEAT.md and HEARTBEAT_OK'
  fi

  local status_raw status_json main_enabled main_every
  status_raw="$(hermes status 2>/dev/null || true)"
  status_json="$(printf '%s\n' "$status_raw" | awk 'f||/^{/{f=1}f')"

  if [[ -z "$status_json" ]] || ! printf '%s\n' "$status_json" | jq empty >/dev/null 2>&1; then
    warn 'heartbeat runtime: unable to parse hermes status JSON output (hermes status may not emit JSON)'
    return
  fi

  main_enabled="$(printf '%s\n' "$status_json" | jq -r '.heartbeat.agents[]? | select(.agentId=="main") | .enabled' | head -n1)"
  main_every="$(printf '%s\n' "$status_json" | jq -r '.heartbeat.agents[]? | select(.agentId=="main") | .every' | head -n1)"

  if [[ "$main_enabled" == "true" ]]; then
    pass 'heartbeat runtime: main agent heartbeat is enabled'
  else
    fail "heartbeat runtime: main agent heartbeat must be enabled (got '$main_enabled')"
  fi

  if [[ "$main_every" == "$expected_runtime_every" ]]; then
    pass "heartbeat runtime: main agent cadence is $expected_runtime_every"
  else
    fail "heartbeat runtime: main agent cadence must be $expected_runtime_every (got '$main_every')"
  fi
}

validate_runtime_invariants() {
  local cfg_path="$LIVE_HERMES/config.yaml"
  local primary max_conc sub_max timeout_s mem_embedder
  local default_workspace expected_workspace_root expected_agent_dir_root
  local wrong_agent_workspaces wrong_agent_dirs

  local busy_mode
  busy_mode="$(config_get "$cfg_path" "display.busy_input_mode")"
  if [[ "$busy_mode" == "steer" ]]; then
    pass "runtime invariant: display.busy_input_mode is steer"
  else
    fail "runtime invariant: display.busy_input_mode must be 'steer' (got '$busy_mode')"
  fi

  if jq -e 'has("_config_version")' "$cfg_path" >/dev/null 2>&1; then
    pass "runtime invariant: skipped legacy validation for new-style config.yaml"
    return
  fi

  primary="$(jq -r '.agents.defaults.model.primary // empty' "$cfg_path" 2>/dev/null || true)"
  max_conc="$(jq -r '.agents.defaults.maxConcurrent // empty' "$cfg_path" 2>/dev/null || true)"
  sub_max="$(jq -r '.agents.defaults.subagents.maxConcurrent // empty' "$cfg_path" 2>/dev/null || true)"
  timeout_s="$(jq -r '.agents.defaults.timeoutSeconds // empty' "$cfg_path" 2>/dev/null || true)"
  mem_embedder="$(jq -r '.plugins.entries."hermes-mem0".config.oss.embedder.provider // empty' "$cfg_path" 2>/dev/null || true)"
  default_workspace="$(jq -r '.agents.defaults.workspace // empty' "$cfg_path" 2>/dev/null || true)"
  expected_workspace_root="$LIVE_HERMES/workspace"
  expected_agent_dir_root="$LIVE_HERMES/agents"

  if [[ -n "$EXPECTED_PRIMARY_MODEL" && "$EXPECTED_PRIMARY_MODEL" != "any" ]]; then
    if [[ "$primary" == "$EXPECTED_PRIMARY_MODEL" ]]; then
      pass "runtime invariant: primary model is $EXPECTED_PRIMARY_MODEL"
    else
      fail "runtime invariant: primary model drifted (got '$primary', expected '$EXPECTED_PRIMARY_MODEL')"
    fi
  fi

  if [[ "$EXPECTED_MAX_CONCURRENT" =~ ^[0-9]+$ ]]; then
    if [[ "$max_conc" =~ ^[0-9]+$ && "$max_conc" -eq "$EXPECTED_MAX_CONCURRENT" ]]; then
      pass "runtime invariant: agents.defaults.maxConcurrent is $EXPECTED_MAX_CONCURRENT (approved)"
    else
      fail "runtime invariant: agents.defaults.maxConcurrent changed without approval (got '$max_conc', must be exactly $EXPECTED_MAX_CONCURRENT)"
    fi
  fi

  if [[ "$EXPECTED_SUBAGENT_MAX_CONCURRENT" =~ ^[0-9]+$ ]]; then
    if [[ "$sub_max" =~ ^[0-9]+$ && "$sub_max" -eq "$EXPECTED_SUBAGENT_MAX_CONCURRENT" ]]; then
      pass "runtime invariant: agents.defaults.subagents.maxConcurrent is $EXPECTED_SUBAGENT_MAX_CONCURRENT (approved)"
    else
      fail "runtime invariant: agents.defaults.subagents.maxConcurrent changed without approval (got '$sub_max', must be exactly $EXPECTED_SUBAGENT_MAX_CONCURRENT)"
    fi
  fi

  if [[ "$EXPECTED_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]]; then
    if [[ "$timeout_s" =~ ^[0-9]+$ && "$timeout_s" -eq "$EXPECTED_TIMEOUT_SECONDS" ]]; then
      pass "runtime invariant: agents.defaults.timeoutSeconds is $EXPECTED_TIMEOUT_SECONDS (approved)"
    else
      fail "runtime invariant: agents.defaults.timeoutSeconds changed without approval (got '$timeout_s', must be exactly $EXPECTED_TIMEOUT_SECONDS)"
    fi
  fi

  if [[ -n "$EXPECTED_MEM_EMBEDDER_PROVIDER" && "$EXPECTED_MEM_EMBEDDER_PROVIDER" != "any" ]]; then
    if [[ "$mem_embedder" == "$EXPECTED_MEM_EMBEDDER_PROVIDER" ]]; then
      pass "runtime invariant: mem0 embedder provider is $EXPECTED_MEM_EMBEDDER_PROVIDER"
    else
      fail "runtime invariant: mem0 embedder provider drifted (got '$mem_embedder', expected '$EXPECTED_MEM_EMBEDDER_PROVIDER')"
    fi
  fi

  if [[ -n "$default_workspace" && "$default_workspace" == "$expected_workspace_root"* ]]; then
    pass "runtime invariant: agents.defaults.workspace rooted in $expected_workspace_root"
  else
    fail "runtime invariant: agents.defaults.workspace drifted outside live profile root (got '$default_workspace', expected prefix '$expected_workspace_root')"
  fi

  wrong_agent_workspaces="$(jq -r --arg root "$expected_workspace_root" '
    (.agents.list // [])
    | map(select((.workspace // "") != "" and ((.workspace | startswith($root)) | not))
      | "\(.id // .name // "<unknown>"):\(.workspace)")
    | .[]
  ' "$cfg_path" 2>/dev/null || true)"
  if [[ -z "$wrong_agent_workspaces" ]]; then
    pass "runtime invariant: agent workspaces rooted in $expected_workspace_root"
  else
    fail "runtime invariant: agent workspace path drift detected: $(printf '%s' "$wrong_agent_workspaces" | paste -sd ';' -)"
  fi

  wrong_agent_dirs="$(jq -r --arg root "$expected_agent_dir_root" '
    (.agents.list // [])
    | map(select((.agentDir // "") != "" and ((.agentDir | startswith($root)) | not))
      | "\(.id // .name // "<unknown>"):\(.agentDir)")
    | .[]
  ' "$cfg_path" 2>/dev/null || true)"
  if [[ -z "$wrong_agent_dirs" ]]; then
    pass "runtime invariant: agentDir paths rooted in $expected_agent_dir_root"
  else
    fail "runtime invariant: agentDir path drift detected: $(printf '%s' "$wrong_agent_dirs" | paste -sd ';' -)"
  fi
}

check_ms_proactive_firing() {
  # Detects /ms rule under-firing by reading ~/.smartclaw/state.db.
  # Wired in scripts/doctor.sh on 2026-07-02 per /advice Reviewer A flag
  # (the audit script existed but was never auto-invoked, so a future
  # regression would be silent). Adds a soft-WARN when firing rate < 50%.
  #
  # See: workspace/SOUL.md `## COMMIT: ms-on-new-task`,
  #      scripts/audit_ms_proactive_firing.sh,
  #      launchd/ai.smartclaw.schedule.ms-proactive-firing-audit.plist.template
  local audit_script="$LIVE_HERMES/scripts/audit_ms_proactive_firing.sh"
  local threshold="${MS_AUDIT_THRESHOLD_PCT:-50}"

  if [[ ! -x "$audit_script" ]]; then
    warn "ms-proactive-firing: audit script missing or not executable: $audit_script"
    return 0
  fi

  local out rc=0
  out="$(HERMES_STATE_DB="$LIVE_HERMES/state.db" THRESHOLD_PCT="$threshold" WINDOW_DAYS=7 \
         "$audit_script" 2>&1)" || rc=$?
  rc="${rc:-0}"

  if [[ "$rc" -eq 0 ]]; then
    pass "ms-proactive-firing: firing rate at/above threshold (${threshold}%)"
    return 0
  fi

  warn "ms-proactive-firing: firing rate BELOW threshold (${threshold}%) — see $audit_script"
  printf '   %s\n' "$out" | sed 's/^/   /'
  return 0  # soft-WARN, not FAIL — the launchd plist handles hard alerting
}

check_config_audit_gateway_rewrites() {
  local audit_path="$LIVE_HERMES/logs/config-audit.jsonl"
  local cfg_path="$LIVE_HERMES/config.yaml"
  local parsed ts changed argv

  if [[ ! -f "$audit_path" ]]; then
    warn "config-audit file missing: $audit_path"
    return 0
  fi

  parsed="$(python3 - "$audit_path" "$cfg_path" <<'PY'
import json, sys
from pathlib import Path

audit_path = Path(sys.argv[1])
cfg_path = str(Path(sys.argv[2]))
latest = None

for raw in audit_path.read_text(encoding="utf-8", errors="replace").splitlines():
    line = raw.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
    except Exception:
        continue
    if obj.get("event") != "config.write":
        continue
    if obj.get("configPath") != cfg_path:
        continue
    argv = obj.get("argv") or []
    if "gateway" not in argv or "--allow-unconfigured" not in argv:
        continue
    latest = obj

if latest is None:
    print("")
else:
    ts = latest.get("ts", "unknown")
    changed = latest.get("changedPathCount")
    if changed is None:
        changed = -1
    argv = " ".join(latest.get("argv") or [])
    print(f"{ts}|{changed}|{argv}")
PY
)"

  if [[ -z "$parsed" ]]; then
    pass "config-audit: no gateway --allow-unconfigured rewrites recorded for $cfg_path"
    return 0
  fi

  IFS='|' read -r ts changed argv <<< "$parsed"
  if [[ "$changed" =~ ^-?[0-9]+$ ]] && [[ "$changed" -gt 2 ]]; then
    warn "config-audit: gateway --allow-unconfigured rewrote $changed paths at $ts (argv: $argv) — investigate drift risk"
  else
    pass "config-audit: latest gateway --allow-unconfigured rewrite touched $changed path(s) at $ts"
  fi
}

cmp_text() {
  local left="$1"
  local right="$2"
  [[ "$left" == "$right" ]]
}

# TMP_DIR and trap initialized at startup

printf 'Hermes Repo Doctor\n'
printf 'Repo: %s\n' "$REPO_ROOT"
printf 'Home: %s\n\n' "$HOME"

# ---------------------------------------------------------------------------
# Aggregate with upstream `hermes doctor`
# ---------------------------------------------------------------------------
# The upstream `hermes doctor` (pip-installed CLI) probes Python env,
# required packages, config files, and auth providers. Run it once and
# translate its ✔/✗ lines into this script's pass/warn/fail counters
# so the totals at the bottom reflect BOTH layers.
if command -v hermes >/dev/null 2>&1; then
  printf '\n── Upstream `hermes doctor` ─────────────────────────────────\n'
  HERMES_DOCTOR_OUT="$TMP_DIR/hermes-doctor.txt"
  if hermes doctor >"$HERMES_DOCTOR_OUT" 2>&1; then
    hermes_doc_rc=0
  else
    hermes_doc_rc=$?
  fi
  while IFS= read -r _hd_line; do
    case "$_hd_line" in
      *✓*)   pass "upstream hermes doctor: $_hd_line" ;;
      *✗*)   fail "upstream hermes doctor: $_hd_line" ;;
      *⚠*)   warn "upstream hermes doctor: $_hd_line" ;;
      *)     printf '  %s\n' "$_hd_line" ;;
    esac
  done <"$HERMES_DOCTOR_OUT"
  if [[ "$hermes_doc_rc" -ne 0 ]]; then
    warn "upstream hermes doctor exited rc=$hermes_doc_rc (see above)"
  fi
  printf '\n'
fi

if [[ "$(uname -s)" == "Darwin" ]]; then
  IS_DARWIN=1
  pass 'running on macOS'
else
  warn 'non-macOS host; launchd checks are skipped'
fi

# Hydrate env vars from the launchd gateway plist so doctor.sh can read them
# regardless of whether it was invoked from a launchd context or a plain shell.
# This ensures the redacted roundtrip env-var check (below) has the full picture.
if [[ "$IS_DARWIN" -eq 1 && -f "$GATEWAY_PLIST" ]]; then
  while IFS= read -r _hyd_line; do
    [[ "$_hyd_line" =~ ^([A-Z0-9_]+)=(.*)$ ]] || continue
    _hyd_var="${BASH_REMATCH[1]}"
    _hyd_val="${BASH_REMATCH[2]}"
    if [[ -z "${!_hyd_var:-}" ]]; then
      export "$_hyd_var"="$_hyd_val"
    fi
  done < <(plutil -convert json -o - "$GATEWAY_PLIST" 2>/dev/null \
    | jq -r '.EnvironmentVariables // {} | to_entries[] | "\(.key)=\(.value)"' 2>/dev/null || true)
  unset _hyd_line _hyd_var _hyd_val

  if [[ -z "${HERMES_HOME:-}" ]]; then
    _gateway_port="$(plutil -extract EnvironmentVariables.HERMES_PORT raw -o - "$GATEWAY_PLIST" 2>/dev/null || true)"
    _inferred_state_dir="$(infer_gateway_profile_dir_from_port "$_gateway_port")"
    if [[ -n "$_inferred_state_dir" ]]; then
      export HERMES_HOME="$_inferred_state_dir"
    fi
    unset _gateway_port _inferred_state_dir
  fi
fi

# Live Hermes tree (config.yaml, cron/, lib/, agents/, logs/): this checkout by default.
# HERMES_LIVE_ROOT overrides; else HERMES_HOME (plist env or shell); else REPO_ROOT.
if [[ -n "${HERMES_LIVE_ROOT:-}" ]]; then
  LIVE_HERMES="${HERMES_LIVE_ROOT}"
elif [[ -n "${HERMES_HOME:-}" ]]; then
  LIVE_HERMES="${HERMES_HOME}"
else
  LIVE_HERMES="$REPO_ROOT"
fi
LIVE_CONFIG_PATH="$LIVE_HERMES/config.yaml"
LIVE_PROFILE="$(detect_live_profile)"

TOKEN_PROBE_LIB="$LIVE_HERMES/lib/token-probes.sh"
if [[ -f "$TOKEN_PROBE_LIB" ]]; then
  # shellcheck disable=SC1090
  source "$TOKEN_PROBE_LIB"
else
  fail "shared token probe library missing: $TOKEN_PROBE_LIB"
  exit 1
fi

printf 'Live Hermes dir: %s\n' "$LIVE_HERMES"
printf 'Live profile: %s\n' "$LIVE_PROFILE"

LOCAL_TZ="$(detect_local_timezone)"
if [[ "$LOCAL_TZ" == "America/Los_Angeles" ]]; then
  pass 'local timezone is America/Los_Angeles (matches migrated schedule semantics)'
elif [[ "${HERMES_ALLOW_NON_PT_SCHEDULE:-0}" == "1" ]]; then
  warn "local timezone is '$LOCAL_TZ' (override HERMES_ALLOW_NON_PT_SCHEDULE=1 active)"
else
  fail "local timezone is '$LOCAL_TZ' but migrated schedules are authored for America/Los_Angeles (set HERMES_ALLOW_NON_PT_SCHEDULE=1 to override)"
fi

require_cmd jq
require_cmd curl
require_cmd hermes
require_cmd lsof
if [[ "$IS_DARWIN" -eq 1 ]]; then
  require_cmd launchctl
  require_cmd plutil
fi
printf '\n'

load_migrated_job_ids
printf '\n'

require_dir "$LIVE_HERMES" 'live Hermes dir'
require_file "$LIVE_HERMES/config.yaml" 'live hermes config'
require_file "$LIVE_HERMES/cron/jobs.json" 'live cron jobs'
require_dir "$LIVE_HERMES/logs" 'live logs dir'
require_file "$LIVE_HERMES/run-scheduled-job.sh" 'live scheduled job runner'
if [[ "$IS_DARWIN" -eq 1 ]]; then
  require_file "$GATEWAY_PLIST" 'live launchd gateway plist'
  # Catch plist-label drift: doctor.sh GATEWAY_LABEL must match the physical plist's actual label.
  # A mismatch means the plist was renamed in git but the migration (install-launchagents.sh)
  # hasn't run yet on this machine — doctor.sh will fail the whole chain.
  physical_label="$(plutil -extract Label raw -o - "$GATEWAY_PLIST" 2>/dev/null || true)"
  if [[ -n "$physical_label" && "$physical_label" != "$GATEWAY_LABEL" ]]; then
    fail "gateway plist label DRIFT: doctor.sh expects '$GATEWAY_LABEL' but physical plist is '$physical_label' — run install-launchagents.sh to migrate"
  elif [[ "$physical_label" == "$GATEWAY_LABEL" ]]; then
    pass "gateway plist label matches: $GATEWAY_LABEL"
  fi
  if [[ -f "$AO_DASHBOARD_PLIST" ]]; then
    pass "live AO dashboard plist present: $AO_DASHBOARD_PLIST"
  elif [[ -f "$AO_DASHBOARD_LEGACY_PLIST" ]]; then
    pass "live AO dashboard plist present (legacy label): $AO_DASHBOARD_LEGACY_PLIST"
  else
    warn "live AO dashboard plist missing: $AO_DASHBOARD_PLIST (legacy: $AO_DASHBOARD_LEGACY_PLIST)"
  fi
  for label in "${SCHEDULED_LABELS[@]}"; do
    require_file "$LAUNCHD_DIR/$label.plist" "live launchd schedule plist ($label)"
  done
else
  warn 'skipping launchd plist file checks on non-macOS'
fi
printf '\n'

live_config_ok=0
if [[ -f "$LIVE_HERMES/config.yaml" ]]; then
  live_config_ok=1
  pass 'config.yaml is present'
else
  fail 'config.yaml is missing'
fi

if [[ "$live_config_ok" -eq 1 ]]; then
  validate_runtime_invariants
  check_config_audit_gateway_rewrites
fi

# ms-on-new-task firing-rate soft-WARN (added 2026-07-02)
check_ms_proactive_firing

# Keep live_json_ok as alias so downstream jq-based checks that still reference it compile
live_json_ok="$live_config_ok"

# MiniMax: validate model/provider consistency, but do not hardcode plugin ids.
# Hermes has shipped both `minimax` and `minimax-portal-auth` naming,
# so plugin-id enforcement here caused false failures on healthy installs.
if [[ "$live_json_ok" -eq 1 ]]; then
  _cfg="$LIVE_HERMES/config.yaml"
  if jq -e 'has("_config_version")' "$_cfg" >/dev/null 2>&1; then
    pass 'MiniMax config check: skipped legacy validation for new-style config.yaml'
  else
    _mm_err=$(jq -r '
      def providers: (.models.providers // {});
      def model_ids:
        ([.agents.defaults.model.primary] + (.agents.defaults.model.fallbacks // [])
          + ([.agents.list[]? | .model // empty]))
        | map(select(. != null and . != ""))
        | unique
        | .[];
      . as $root
      | model_ids as $mid
      | ($mid | split("/")[0]) as $p
      | if $p == "minimax-portal" then
          if ($root | providers | has("minimax-portal") | not) then
            "model \($mid) requires models.providers.minimax-portal"
          else empty end
        elif $p == "minimax" then
          if ($root | providers | has("minimax") | not) then
            "model \($mid) requires models.providers.minimax"
          else empty end
        else empty end
    ' "$_cfg" 2>/dev/null | head -n 1)
    if [[ -n "$_mm_err" ]]; then
      fail "MiniMax model/provider mismatch: $_mm_err"
    else
      pass 'MiniMax model ids match models.providers (minimax / minimax-portal)'
    fi
    _mm_runtime_err=$(jq -r '
      (.models.providers.minimax // null) as $minimax
      | if $minimax == null then
          "models.providers.minimax missing"
        elif (($minimax.api // "") != "anthropic-messages") then
          "models.providers.minimax.api=\($minimax.api // "<missing>")"
        elif (($minimax.baseUrl // "") != "https://api.minimax.io/anthropic") then
          "models.providers.minimax.baseUrl=\($minimax.baseUrl // "<missing>")"
        else empty end
    ' "$_cfg" 2>/dev/null | head -n 1)
    if [[ -n "$_mm_runtime_err" ]]; then
      fail "MiniMax runtime provider drift: $_mm_runtime_err"
    else
      pass 'MiniMax runtime provider matches anthropic-messages https://api.minimax.io/anthropic'
    fi
    unset _mm_err _mm_runtime_err
  fi
  unset _cfg
fi

# ORCH-slack-all-channels: with groupPolicy=allowlist, channels.slack.channels["*"] must
# accept all invited channels without requireMention. Hermes has shipped both
# `enabled:true` and legacy `allow:true` channel entry schemas, so accept either.
assert_slack_listen_all_invited_channels() {
  local json_path="$1"
  local label="$2"
  if ! json_valid "$json_path"; then
    fail "$label: invalid JSON ($json_path)"
    return 1
  fi
  local enabled wild_enabled wild_allow wild_mention
  enabled="$(jq -r '.channels.slack.enabled // false' "$json_path")"
  if [[ "$enabled" != "true" ]]; then
    warn "$label: channels.slack.enabled is not true — skipping Slack wildcard check"
    return 0
  fi
  wild_enabled="$(jq -r 'if (.channels.slack.channels."*" | has("enabled")) then .channels.slack.channels."*".enabled else "missing" end' "$json_path")"
  wild_allow="$(jq -r 'if (.channels.slack.channels."*" | has("allow")) then .channels.slack.channels."*".allow else "missing" end' "$json_path")"
  wild_mention="$(jq -r 'if (.channels.slack.channels."*" | has("requireMention")) then .channels.slack.channels."*".requireMention else "missing" end' "$json_path")"
  if [[ ( "$wild_enabled" == "true" || "$wild_allow" == "true" ) && "$wild_mention" == "false" ]]; then
    pass "$label: Slack channels.\"*\" allows all invited channels (enabled/allow=true, requireMention=false)"
  else
    fail "$label: Slack channels.\"*\" must allow all invited channels with requireMention=false; got enabled=$wild_enabled allow=$wild_allow requireMention=$wild_mention ($json_path)"
  fi
}

if [[ "$live_json_ok" -eq 1 ]]; then
  validate_heartbeat_config
  assert_slack_listen_all_invited_channels "$LIVE_HERMES/config.yaml" 'live config.yaml'
  check_gateway_process_concurrency
fi

live_token_raw=''
live_token=''
if [[ "$live_json_ok" -eq 1 ]]; then
  live_token_raw=$(jq -r '.gateway.auth.token // empty' "$LIVE_HERMES/config.yaml" 2>/dev/null)
  live_token="$(resolve_secret_ref "$live_token_raw")"
fi

plist_token=''
if [[ "$IS_DARWIN" -eq 1 && -f "$GATEWAY_PLIST" ]]; then
  if plist_token=$(plutil -extract EnvironmentVariables.HERMES_GATEWAY_TOKEN raw -o - "$GATEWAY_PLIST" 2>/dev/null); then
    :
  else
    plist_token=''
  fi
fi

if ! is_placeholder_token "$live_token"; then
  pass 'gateway auth token is set in config.yaml'
elif ! is_placeholder_token "$plist_token"; then
  pass 'gateway token provided via launchd EnvironmentVariables'
else
  fail 'gateway token missing/placeholder in both config.yaml and launchd EnvironmentVariables'
fi

shell_token="${HERMES_GATEWAY_TOKEN:-}"
if ! is_placeholder_token "$shell_token" && ! is_placeholder_token "$live_token" && [[ "$shell_token" != "$live_token" ]]; then
  warn 'shell HERMES_GATEWAY_TOKEN differs from config.yaml; gateway probes will use config token'
fi

printf '\n'
if [[ -f "$LIVE_HERMES/cron/jobs.json" ]] && json_valid "$LIVE_HERMES/cron/jobs.json"; then
  still_enabled=''
  missing_ids=''
  for job_id in "${MIGRATED_JOB_IDS[@]:-}"; do
    if ! jq -e --arg id "$job_id" 'any(.jobs[]?; .id == $id)' "$LIVE_HERMES/cron/jobs.json" >/dev/null 2>&1; then
      if [[ -z "$missing_ids" ]]; then
        missing_ids="$job_id"
      else
        missing_ids="$missing_ids $job_id"
      fi
      continue
    fi

    if jq -e --arg id "$job_id" 'any(.jobs[]?; .id == $id and (.enabled == true))' "$LIVE_HERMES/cron/jobs.json" >/dev/null 2>&1; then
      if [[ -z "$still_enabled" ]]; then
        still_enabled="$job_id"
      else
        still_enabled="$still_enabled $job_id"
      fi
    fi
  done

  if [[ -n "$missing_ids" ]]; then
    warn "legacy migrated cron job IDs are missing from $LIVE_HERMES/cron/jobs.json (non-fatal): $missing_ids"
  fi
  if [[ -n "$still_enabled" ]]; then
    warn "legacy migrated cron job IDs are still enabled in $LIVE_HERMES/cron/jobs.json (non-fatal): $still_enabled"
  fi
  if [[ -z "$missing_ids" && -z "$still_enabled" ]]; then
    pass 'legacy migrated Hermes cron jobs are all absent/disabled in cron/jobs.json'
  fi
else
  fail 'could not validate live cron jobs JSON'
fi

printf '\n'
if [[ "$IS_DARWIN" -eq 1 ]]; then
  if [[ -f "$GATEWAY_PLIST" ]]; then
    if plutil -lint "$GATEWAY_PLIST" >/dev/null 2>&1; then
      pass 'gateway launchd plist is valid'
    else
      fail 'gateway launchd plist failed plutil -lint'
    fi

    plist_port="$(plist_extract_raw EnvironmentVariables.HERMES_PORT "$GATEWAY_PLIST" 2>/dev/null || true)"
    if [[ -z "$plist_port" ]]; then
      plist_port="$(expected_gateway_port_for_profile "$LIVE_PROFILE")"
    fi
    live_port=$(jq -r '.gateway.port // empty' "$LIVE_CONFIG_PATH" 2>/dev/null || true)
    if [[ -z "$live_port" ]]; then
      live_port="$(expected_gateway_port_for_profile "$LIVE_PROFILE")"
      warn "gateway port missing from $LIVE_CONFIG_PATH; inferring $live_port for $LIVE_PROFILE profile"
    fi
    if [[ -n "$plist_port" && -n "$live_port" && "$plist_port" == "$live_port" ]]; then
      pass "gateway port matches between plist and live config ($live_port)"
    else
      fail "gateway port mismatch (plist=$plist_port, live=$live_port)"
    fi

    if ! is_placeholder_token "$plist_token"; then
      pass 'gateway token present in launchd EnvironmentVariables'
    elif ! is_placeholder_token "$live_token"; then
      pass 'gateway token sourced from config.yaml'
    else
      warn 'gateway token missing/placeholder in launchd EnvironmentVariables (may still work via config.yaml token)'
    fi

    # Check HERMES_HOME in plist matches the expected prod dir.
    # Mismatch caused the 2026-04-04 incident: plist pointed to wrong dir
    # while deploy.sh syncs to the real prod dir — gateway was live but reading stale/empty config.
    plist_state_dir="$(plist_extract_raw EnvironmentVariables.HERMES_HOME "$GATEWAY_PLIST" 2>/dev/null || true)"
    expected_state_dir="$(expected_state_dir_for_profile "$LIVE_PROFILE")"
    inferred_state_dir="$(infer_gateway_profile_dir_from_port "$plist_port")"
    if [[ -n "$plist_state_dir" ]]; then
      # Normalize: remove trailing slash for comparison
      plist_state_dir_norm="${plist_state_dir%/}"
      if [[ "$plist_state_dir_norm" == "$expected_state_dir" ]]; then
        pass "plist HERMES_HOME matches deploy target ($plist_state_dir_norm)"
      else
        fail "plist HERMES_HOME mismatch: plist='$plist_state_dir_norm' expected='$expected_state_dir' for $LIVE_PROFILE profile — deploy.sh syncs to wrong dir; run install-launchagents.sh"
      fi
    elif [[ -n "$inferred_state_dir" && "$inferred_state_dir" == "$expected_state_dir" ]]; then
      pass "plist HERMES_HOME inferred from gateway port ($plist_port -> $inferred_state_dir)"
    else
      fail "plist has no HERMES_HOME; gateway will use wrong state dir — run install-launchagents.sh to fix"
    fi

    # Check auth-profiles.json present in prod state dir — liveness ≠ functional.
    # HTTP /health returns "live" even when auth-profiles.json is missing.
    # Missing file → all LLM calls fail silently with "No API key found for provider".
    # Always run this check: fall back to expected_state_dir when plist_state_dir is unset.
    auth_state_dir="${plist_state_dir:-${inferred_state_dir:-$expected_state_dir}}"
    prod_auth="$auth_state_dir/agents/main/agent/auth-profiles.json"
    prod_auth_new="$auth_state_dir/auth.json"
    if [[ -f "$prod_auth" ]]; then
      pass "auth-profiles.json present in prod state dir ($prod_auth)"
    elif [[ -f "$prod_auth_new" ]]; then
      pass "auth.json present in prod state dir ($prod_auth_new)"
    else
      fail "Neither auth-profiles.json ($prod_auth) nor auth.json ($prod_auth_new) found in prod state dir — gateway HTTP health will pass but agent cannot authenticate; run deploy.sh or copy from staging"
    fi

    # Check for NVM node path in gateway plist (fragile during Node version upgrades)
    # Node 22 via nvm is the required runtime (CLAUDE.md); skip warning for v22.x paths.
    plist_program=$(plutil -extract ProgramArguments.0 raw -o - "$GATEWAY_PLIST" 2>/dev/null || true)
    if [[ "$plist_program" =~ \.nvm/versions/node/v22\. ]]; then
      pass "gateway service uses nvm Node 22 ($plist_program) — correct per policy"
    elif [[ "$plist_program" =~ \.nvm/versions/node/ ]]; then
      warn "gateway service uses a non-v22 Node version manager path ($plist_program); Recommendation: use \`nvm use 22\` per CLAUDE.md policy"
    fi
  fi
else
  warn 'skipping launchd gateway plist validation on non-macOS'
fi

printf '\n'
if [[ "$IS_DARWIN" -eq 1 ]]; then
  AO_DASHBOARD_REGISTERED=0
  AO_DASHBOARD_LAUNCHD_RUNNING=0
  AO_DASHBOARD_LAUNCHD_NOTE=""
  launchctl_out="$TMP_DIR/launchctl-gateway.txt"
  if launchctl print "gui/$(id -u)/$GATEWAY_LABEL" >"$launchctl_out" 2>&1; then
    pass 'launchd job is registered'
    if grep -q 'state = running' "$launchctl_out"; then
      pass 'launchd job state is running'
    else
      warn 'launchd job is not in running state (will rely on listener + /health probes)'
    fi
  else
    fail "launchctl print failed for $GATEWAY_LABEL"
  fi

  # Check for hermes staging "enabled but not bootstrapped" broken state.
  # Symptom: launchd shows service as enabled in print-disabled, but launchctl print fails.
  # Cause: launchctl unload/load cycle left the service in enabled state without a live bootstrap.
  # This causes any manually-started staging process to get SIGTERM immediately.
  for _staging_label in "ai.smartclaw.staging" "ai.smartclaw.gateway"; do
    if [[ "$GATEWAY_LABEL" != "$_staging_label" && -f "$LAUNCHD_DIR/${_staging_label}.plist" ]]; then
      _staging_disabled=$(
        launchctl print-disabled "gui/$(id -u)" 2>/dev/null \
          | awk -v label="\"$_staging_label\"" '
              index($0, label) {
                if ($0 ~ /=>[[:space:]]*enabled/) print "enabled"
                else if ($0 ~ /=>[[:space:]]*disabled/) print "disabled"
              }
            ' \
          | head -n1
      )
      _staging_disabled="${_staging_disabled:-unknown}"
      _staging_live=$(launchctl print "gui/$(id -u)/$_staging_label" >/dev/null 2>&1 && echo "yes" || echo "no")
      if [[ "$_staging_disabled" == "enabled" && "$_staging_live" == "no" ]]; then
        fail "staging launchd bootstrap broken: service $_staging_label is enabled but not bootstrapped (Bootstrap failed: 5: I/O error). Fix: launchctl unload -w ~/Library/LaunchAgents/${_staging_label}.plist && launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/${_staging_label}.plist"
      elif [[ "$_staging_disabled" == "disabled" ]]; then
        if [[ -f "$LAUNCHD_DIR/${_staging_label}.plist.disabled" ]]; then
          pass "staging launchd service $_staging_label is disabled and plist is marked .disabled (expected between deploy cycles)"
        else
          warn "staging launchd service $_staging_label is disabled — staging gateway will not auto-start on login"
        fi
      else
        pass "staging launchd bootstrap state OK (_staging_label=$_staging_label _staging_disabled=$_staging_disabled _staging_live=$_staging_live)"
      fi
      unset _staging_disabled _staging_live
    fi
  done

  # Check AO dashboard launchd (current label first, then legacy label).
  ao_dashboard_plist_found=""
  if launchctl print "gui/$(id -u)/$AO_DASHBOARD_LABEL" >"$TMP_DIR/launchctl-ao-dashboard.txt" 2>&1; then
    pass 'AO dashboard launchd job is registered'
    AO_DASHBOARD_REGISTERED=1
    ao_dashboard_plist_found="$AO_DASHBOARD_PLIST"
    if grep -q 'state = running' "$TMP_DIR/launchctl-ao-dashboard.txt"; then
      pass 'AO dashboard launchd job state is running'
      AO_DASHBOARD_LAUNCHD_RUNNING=1
    else
      AO_DASHBOARD_LAUNCHD_NOTE='AO dashboard launchd job is registered but not in running state'
    fi
  elif launchctl print "gui/$(id -u)/$AO_DASHBOARD_LEGACY_LABEL" >"$TMP_DIR/launchctl-ao-dashboard-legacy.txt" 2>&1; then
    pass 'AO dashboard launchd job is registered (legacy label)'
    AO_DASHBOARD_REGISTERED=1
    ao_dashboard_plist_found="$AO_DASHBOARD_LEGACY_PLIST"
    if grep -q 'state = running' "$TMP_DIR/launchctl-ao-dashboard-legacy.txt"; then
      pass 'AO dashboard launchd job state is running (legacy label)'
      AO_DASHBOARD_LAUNCHD_RUNNING=1
    else
      AO_DASHBOARD_LAUNCHD_NOTE='AO dashboard launchd job is registered (legacy label) but not in running state'
    fi
  else
    AO_DASHBOARD_LAUNCHD_NOTE='AO dashboard launchd job is not registered (run install-launchagents.sh to install)'
  fi

  # Validate AO dashboard projects against live `ao list projects` output
  if [[ -n "$ao_dashboard_plist_found" && -f "$ao_dashboard_plist_found" ]] && command -v ao >/dev/null 2>&1; then
    # Extract project list from dashboard plist arguments (format: "for p in proj1 proj2; do ...")
    plist_projects=$(plutil -convert json -o - "$ao_dashboard_plist_found" 2>/dev/null \
      | jq -r '.ProgramArguments[]? | select(startswith("for p in")) | gsub("^for p in | proj2; do.*$";"") | split(" ")[]' 2>/dev/null || true)
    if [[ -n "$plist_projects" ]]; then
      # Get live AO projects
      live_ao_projects=$(ao list projects 2>/dev/null | tail -n +2 | awk '{print $1}' || true)
      if [[ -n "$live_ao_projects" ]]; then
        missing_projects=""
        for proj in $plist_projects; do
          if ! grep -qx "$proj" <<<"$live_ao_projects"; then
            if [[ -z "$missing_projects" ]]; then
              missing_projects="$proj"
            else
              missing_projects="$missing_projects $proj"
            fi
          fi
        done
        if [[ -n "$missing_projects" ]]; then
          warn "AO dashboard references projects not in 'ao list projects': $missing_projects"
        else
          pass "AO dashboard projects validated against live 'ao list projects'"
        fi
      else
        warn "Could not retrieve live AO projects list; skipping dashboard project validation"
      fi
    fi
  fi

  for label in "${SCHEDULED_LABELS[@]}"; do
    if launchctl print "gui/$(id -u)/$label" >"$TMP_DIR/launchctl-$label.txt" 2>&1; then
      pass "launchd schedule is registered: $label"
    else
      fail "launchd schedule is not registered: $label"
    fi
  done

  # Check for raw $HOME in launchd plist templates (launchd doesn't expand shell variables)
  for plist in "$GATEWAY_PLIST" "$AO_DASHBOARD_PLIST" "${SCHEDULED_LABELS[@]/#/$LAUNCHD_DIR/}"; do
    plist="${plist%.plist}.plist"  # Ensure .plist extension
    if [[ -f "$plist" ]]; then
      if plutil -convert xml1 -o - "$plist" 2>/dev/null | grep -q '\$HOME'; then
        plist_name=$(basename "$plist")
        warn "launchd plist contains raw '\$HOME' variable: $plist_name — launchd doesn't expand shell variables; use absolute paths or ~ instead"
      fi
    fi
  done
else
  warn 'skipping launchctl runtime checks on non-macOS'
fi

runtime_port=""
runtime_port=$(jq -r '.gateway.port // empty' "$LIVE_CONFIG_PATH" 2>/dev/null || true)
if [[ -z "$runtime_port" ]]; then
  runtime_port="$(expected_gateway_port_for_profile "$LIVE_PROFILE")"
  warn "live gateway port unreadable from $LIVE_CONFIG_PATH; defaulting runtime checks to $runtime_port for $LIVE_PROFILE profile"
fi

GATEWAY_PORT_LISTENING=0
if lsof -nP -iTCP:"$runtime_port" -sTCP:LISTEN >"$TMP_DIR/lsof-listen.txt" 2>&1; then
  GATEWAY_PORT_LISTENING=1
  pass "a process is listening on gateway port $runtime_port"
else
  fail "no process listening on gateway port $runtime_port"
fi

# Initialize ao_dashboard_plist_found to empty string for non-macOS (set -u safety)
ao_dashboard_plist_found=""

# Check AO dashboard port (env override > launchd plist --port > fallback 3011)
AO_DASHBOARD_PORT="$(detect_ao_dashboard_port "${ao_dashboard_plist_found:-}")"
AO_DASHBOARD_PORT_LISTENING=0
if lsof -nP -iTCP:"$AO_DASHBOARD_PORT" -sTCP:LISTEN >"$TMP_DIR/lsof-ao-dashboard.txt" 2>&1; then
  AO_DASHBOARD_PORT_LISTENING=1
  pass "a process is listening on AO dashboard port $AO_DASHBOARD_PORT"
else
  warn "no process listening on AO dashboard port $AO_DASHBOARD_PORT (dashboard may not be running; override with HERMES_DOCTOR_AO_DASHBOARD_PORT)"
fi
if [[ "$IS_DARWIN" -eq 1 && "$AO_DASHBOARD_REGISTERED" -eq 1 && "$AO_DASHBOARD_LAUNCHD_RUNNING" -eq 0 && "$AO_DASHBOARD_PORT_LISTENING" -eq 1 ]]; then
  pass "AO dashboard is reachable on port $AO_DASHBOARD_PORT even though the standalone launchd job is idle"
elif [[ "$IS_DARWIN" -eq 1 && -n "${AO_DASHBOARD_LAUNCHD_NOTE:-}" ]]; then
  warn "$AO_DASHBOARD_LAUNCHD_NOTE"
fi

health_body_file="$TMP_DIR/health.json"
health_err_file="$TMP_DIR/health-curl.err"
HEALTH_HTTP_OK=0
health_code=$(curl -sS --max-time 5 -o "$health_body_file" -w '%{http_code}' "http://127.0.0.1:${runtime_port}/health" 2>"$health_err_file")
curl_rc=$?
if [[ "$curl_rc" -ne 0 ]]; then
  fail "HTTP /health probe command failed (curl exit=$curl_rc)"
  if [[ -s "$health_err_file" ]]; then
    warn "curl error: $(< "$health_err_file")"
  fi
elif [[ "$health_code" == '200' ]]; then
  HEALTH_HTTP_OK=1
  pass 'HTTP /health endpoint returned 200'
  if jq empty "$health_body_file" >/dev/null 2>&1; then
    pass '/health response body is valid JSON'
  else
    warn '/health response body is not JSON'
  fi
else
  fail "HTTP /health endpoint failed (code=$health_code)"
fi

gateway_probe_cmd=(env)
if ! is_placeholder_token "$live_token"; then
  gateway_probe_cmd=(env HERMES_GATEWAY_TOKEN="$live_token")
fi

status_output="$("${gateway_probe_cmd[@]}" hermes gateway status 2>&1 || true)"
# Accept either legacy "Runtime: running" or current format indicators (Slack/Agents active)
if grep -qE 'Runtime: running|Slack: ok|^Agents:|running' <<<"$status_output"; then
  pass 'hermes gateway status reports runtime running'
elif [[ "$HEALTH_HTTP_OK" -eq 1 && "$GATEWAY_PORT_LISTENING" -eq 1 ]]; then
  warn 'hermes gateway status output missing runtime marker, but listener + /health are healthy'
else
  fail 'hermes gateway status does not report runtime running'
fi

health_cli_output="$("${gateway_probe_cmd[@]}" hermes gateway status 2>&1)"
health_cli_rc=$?
if [[ "$health_cli_rc" -ne 0 ]]; then
  # Distinguish optional-feature misconfig (missing tunnel tokens) from real failures.
  if grep -qE 'secret reference could not be resolved|missing env var|auth\.token|remote\.token' <<<"$health_cli_output"; then
    warn "hermes gateway status: optional token missing (exit=$health_cli_rc) — gateway is operational"
  # Treat transient local close as non-fatal when /health and gateway status already passed.
  elif grep -qE 'gateway closed \(1000|normal closure' <<<"$health_cli_output"; then
    warn "hermes gateway status returned transient close (exit=$health_cli_rc): treating as non-fatal"
  # RPC budget exceeded while HTTP liveness is fine — common under event-loop saturation.
  elif grep -qE 'gateway timeout|Error: gateway timeout' <<<"$health_cli_output" && [[ "$HEALTH_HTTP_OK" -eq 1 ]]; then
    warn "hermes gateway status RPC timed out (exit=$health_cli_rc) under load; HTTP /health is OK (raise HERMES_DOCTOR_GATEWAY_RPC_TIMEOUT_MS if persistent)"
  else
    fail "hermes gateway status command failed (exit=$health_cli_rc)"
    if grep -q 'gateway token mismatch' <<<"$health_cli_output"; then
      fail 'gateway token mismatch detected'
    fi
  fi
elif grep -q '^Error:' <<<"$health_cli_output"; then
  fail 'hermes gateway status reported an error'
else
  pass 'hermes gateway status completed without errors'
fi

printf '\n'
if [[ "$live_json_ok" -eq 1 ]]; then
  # Check for env var placeholders in critical token fields
  # These MUST be hardcoded real tokens, not ${ENV_VAR} references
  slack_bot_raw="$(jq -r '.channels.slack.botToken // empty' "$LIVE_HERMES/config.yaml" 2>/dev/null || true)"
  if [[ -z "$slack_bot_raw" && -f "$LIVE_HERMES/hermes.json" ]]; then
    slack_bot_raw="$(jq -r '.channels.slack.botToken // empty' "$LIVE_HERMES/hermes.json" 2>/dev/null || true)"
  fi
  slack_app_raw="$(jq -r '.channels.slack.appToken // empty' "$LIVE_HERMES/config.yaml" 2>/dev/null || true)"
  if [[ -z "$slack_app_raw" && -f "$LIVE_HERMES/hermes.json" ]]; then
    slack_app_raw="$(jq -r '.channels.slack.appToken // empty' "$LIVE_HERMES/hermes.json" 2>/dev/null || true)"
  fi

  if [[ -z "$slack_bot_raw" && -z "$slack_app_raw" ]]; then
    warn 'Slack socket-mode token fields are not present in this config schema; process-table concurrency check still ran'
  fi
  
  if [[ "$slack_bot_raw" =~ ^\$\{.*\}$ ]]; then
    fail "channels.slack.botToken contains env var placeholder: $slack_bot_raw (must be hardcoded token)"
  else
    pass 'channels.slack.botToken is hardcoded (not an env var reference)'
  fi
  
  if [[ "$slack_app_raw" =~ ^\$\{.*\}$ ]]; then
    fail "channels.slack.appToken contains env var placeholder: $slack_app_raw (must be hardcoded token)"
  else
    pass 'channels.slack.appToken is hardcoded (not an env var reference)'
  fi

  token_probe_timeout=12

  slack_bot_token="${SLACK_BOT_TOKEN:-${OPENCLAW_SLACK_BOT_TOKEN:-}}"
  if [[ -z "$slack_bot_token" ]]; then
    slack_bot_token="$(resolve_secret_ref "$slack_bot_raw")"
  fi
  if is_placeholder_token "$slack_bot_token"; then
    fail 'Slack bot token is missing/placeholder (channels.slack.botToken)'
  else
    slack_bot_body="$TMP_DIR/slack-bot-auth.json"
    if probe_slack_bot_token "$slack_bot_token" "$token_probe_timeout" "$slack_bot_body"; then
      pass 'Slack bot token passed auth.test'
    else
      fail "Slack bot token failed auth.test (http=$LAST_PROBE_HTTP_CODE)"
    fi
  fi

  slack_app_token="${SLACK_APP_TOKEN:-${OPENCLAW_SLACK_APP_TOKEN:-}}"
  if [[ -z "$slack_app_token" ]]; then
    slack_app_token="$(resolve_secret_ref "$slack_app_raw")"
  fi
  if is_placeholder_token "$slack_app_token"; then
    fail 'Slack app token is missing/placeholder (channels.slack.appToken)'
  else
    slack_app_body="$TMP_DIR/slack-app-open.json"
    if probe_slack_app_token "$slack_app_token" "$token_probe_timeout" "$slack_app_body"; then
      pass 'Slack app token passed apps.connections.open'
    else
      fail "Slack app token failed apps.connections.open (http=$LAST_PROBE_HTTP_CODE)"
    fi
  fi
  check_shared_slack_socket_tokens "$LIVE_HERMES/config.yaml" "$GATEWAY_LABEL" "$slack_bot_token" "$slack_app_token"

  openai_raw="$(jq -r '.plugins.entries."hermes-mem0".config.oss.embedder.config.apiKey // empty' "$LIVE_HERMES/config.yaml" 2>/dev/null || true)"
  openai_token="$(resolve_secret_ref "$openai_raw")"
  if is_placeholder_token "$openai_token"; then
    warn 'OpenAI API key is missing/placeholder (mem0 embedder config); skipped OpenAI key probe'
  else
    openai_body="$TMP_DIR/openai-models.json"
    if probe_openai_models_token "$openai_token" "$token_probe_timeout" "$openai_body"; then
      pass 'OpenAI API key passed /v1/models probe'
    else
      fail "OpenAI API key failed /v1/models probe (http=$LAST_PROBE_HTTP_CODE)"
    fi
  fi

  mem0_embedder_provider="$(jq -r '.plugins.entries."hermes-mem0".config.oss.embedder.provider // empty' "$LIVE_HERMES/config.yaml" 2>/dev/null || true)"
  mem0_embedder_baseurl="$(jq -r '.plugins.entries."hermes-mem0".config.oss.embedder.config.baseURL // .plugins.entries."hermes-mem0".config.oss.embedder.config.url // empty' "$LIVE_HERMES/config.yaml" 2>/dev/null || true)"
  mem0_embedder_legacy_baseurl="$(jq -r '.plugins.entries."hermes-mem0".config.oss.embedder.config.ollama_base_url // empty' "$LIVE_HERMES/config.yaml" 2>/dev/null || true)"
  if [[ "$mem0_embedder_provider" == "ollama" ]]; then
    if [[ -n "$mem0_embedder_baseurl" ]]; then
      pass "mem0 Ollama embedder exposes a supported base URL key"
    else
      fail "mem0 Ollama embedder is missing baseURL/url (found legacy ollama_base_url='${mem0_embedder_legacy_baseurl:-<empty>}')"
    fi
  else
    pass "mem0 embedder provider is $mem0_embedder_provider"
  fi

  mem0_llm_provider="$(jq -r '.plugins.entries."hermes-mem0".config.oss.llm.provider // empty' "$LIVE_HERMES/config.yaml" 2>/dev/null || true)"
  mem0_llm_baseurl="$(jq -r '.plugins.entries."hermes-mem0".config.oss.llm.config.baseURL // .plugins.entries."hermes-mem0".config.oss.llm.config.url // empty' "$LIVE_HERMES/config.yaml" 2>/dev/null || true)"
  mem0_llm_legacy_baseurl="$(jq -r '.plugins.entries."hermes-mem0".config.oss.llm.config.ollama_base_url // empty' "$LIVE_HERMES/config.yaml" 2>/dev/null || true)"
  if [[ "$mem0_llm_provider" == "ollama" ]]; then
    if [[ -n "$mem0_llm_baseurl" ]]; then
      pass "mem0 Ollama LLM exposes a supported base URL key"
    else
      fail "mem0 Ollama LLM is missing baseURL/url (found legacy ollama_base_url='${mem0_llm_legacy_baseurl:-<empty>}')"
    fi
  else
    pass "mem0 LLM provider is $mem0_llm_provider"
  fi

  xai_raw="$(jq -r '.env.XAI_API_KEY // empty' "$LIVE_HERMES/config.yaml" 2>/dev/null || true)"
  xai_token="$(resolve_secret_ref "$xai_raw")"
  if is_placeholder_token "$xai_token"; then
    warn 'XAI API key is missing/placeholder (env.XAI_API_KEY); skipped xAI probe'
  else
    xai_body="$TMP_DIR/xai-models.json"
    if probe_xai_models_token "$xai_token" "$token_probe_timeout" "$xai_body"; then
      pass 'xAI API key passed /v1/models probe'
    else
      fail "xAI API key failed /v1/models probe (http=$LAST_PROBE_HTTP_CODE)"
    fi
  fi

  discord_enabled="$(jq -r '.channels.discord.enabled // false' "$LIVE_HERMES/config.yaml" 2>/dev/null || echo false)"
  if [[ "$discord_enabled" != "true" ]]; then
    pass 'Discord not enabled (channels.discord.enabled != true); skipped Discord probe'
  else
    discord_raw="$(jq -r '.channels.discord.token // empty' "$LIVE_HERMES/config.yaml" 2>/dev/null || true)"
    discord_token="$(resolve_secret_ref "$discord_raw")"
    if is_placeholder_token "$discord_token"; then
      fail 'Discord is enabled but channels.discord.token is empty/placeholder'
    else
      discord_body="$TMP_DIR/discord-me.json"
      if probe_discord_bot_token "$discord_token" "$token_probe_timeout" "$discord_body"; then
        pass 'Discord bot token passed users/@me probe'
      else
        fail "Discord bot token failed users/@me probe (http=$LAST_PROBE_HTTP_CODE)"
      fi
    fi
  fi

  mcp_adapter_enabled="$(jq -r '.plugins.entries."hermes-mcp-adapter".enabled // false' "$LIVE_HERMES/config.yaml" 2>/dev/null || echo false)"
  if [[ "$mcp_adapter_enabled" == "true" ]]; then
    mcp_mail_url="$(jq -r '.plugins.entries."hermes-mcp-adapter".config.servers[]? | select(.name=="mcp-agent-mail") | .url // empty' "$LIVE_HERMES/config.yaml" 2>/dev/null | head -n1)"
    mcp_mail_auth_raw="$(jq -r '.plugins.entries."hermes-mcp-adapter".config.servers[]? | select(.name=="mcp-agent-mail") | .headers.Authorization // empty' "$LIVE_HERMES/config.yaml" 2>/dev/null | head -n1)"
    if [[ -n "$mcp_mail_url" ]]; then
      mcp_mail_token="$(resolve_bearer_token_ref "$mcp_mail_auth_raw")"
      mcp_mail_body="$TMP_DIR/mcp-agent-mail-probe.json"
      if is_placeholder_token "$mcp_mail_token"; then
        # No-auth config: probe without bearer token and expect 200 (server runs unauthenticated).
        if probe_mcp_tools_list "$mcp_mail_url" "$token_probe_timeout" "$mcp_mail_body" ""; then
          pass 'MCP Agent Mail tools/list probe passed (no-auth)'
        else
          fail "MCP Agent Mail tools/list probe failed (no-auth, http=$LAST_PROBE_HTTP_CODE)"
        fi
      else
        if probe_mcp_tools_list "$mcp_mail_url" "$token_probe_timeout" "$mcp_mail_body" "$mcp_mail_token"; then
          pass 'MCP Agent Mail token passed tools/list probe'
        else
          fail "MCP Agent Mail token failed tools/list probe (http=$LAST_PROBE_HTTP_CODE)"
        fi
      fi
    else
      warn 'MCP adapter enabled but mcp-agent-mail server URL missing; skipped MCP Agent Mail probe'
    fi
  else
    pass 'MCP adapter not configured/enabled; skipped MCP Agent Mail probe'
  fi
fi

# Live end-to-end probes (Slack send, gateway inference, memory)
if command -v hermes >/dev/null 2>&1; then
  PROBE_TIMEOUT=15
  INFER_TIMEOUT=60

  # 1. Slack message send via hermes CLI (gateway must be running)
  SLACK_PROBE_TARGET="${HERMES_DOCTOR_SLACK_PROBE_TARGET:-C0AP8LRKM9N}"
  # hermes does not expose `message send` directly; use hermes slack send if available
  slack_out="$(hermes slack send --channel "$SLACK_PROBE_TARGET" \
    --text "[doctor.sh probe] $(date '+%Y-%m-%d %H:%M:%S %Z')" 2>&1 || true)"
  if printf '%s\n' "$slack_out" | grep -q '"ok"\|messageId\|Message ID\|sent'; then
    pass "Slack send probe delivered message to $SLACK_PROBE_TARGET"
  else
    warn "Slack send probe via hermes slack send unavailable or failed: $(printf '%s\n' "$slack_out" | head -1)"
  fi

  # 1b. Slack RECEIVE probe — the send probe above only exercises chat.postMessage
  # (requires chat:write scope) and passes even when the Slack app's "Enable Events"
  # toggle is OFF at api.slack.com. Socket Mode can stay connected with a live
  # ping/pong heartbeat while zero inbound events are ever delivered — this exact
  # failure silently dropped 100% of messages for 24h+ (2026-07-03, hermes_pc) and
  # recurred from an identical 2026-05-11 staging incident with no automated check
  # added after the first occurrence. This probe posts a self-mentioning marker
  # message and confirms the gateway actually logs it as processed.
  if [[ "${HERMES_DOCTOR_SKIP_SLACK_RECEIVE_PROBE:-0}" == "1" ]]; then
    warn "Slack receive probe skipped (HERMES_DOCTOR_SKIP_SLACK_RECEIVE_PROBE=1)"
  elif [[ -z "${slack_bot_token:-}" ]] || [[ ! -f "${slack_bot_body:-/nonexistent}" ]]; then
    warn "Slack receive probe skipped — bot token or auth.test response unavailable"
  else
    _receive_bot_uid="$(jq -r '.user_id // empty' "$slack_bot_body" 2>/dev/null)"
    _receive_log="${LIVE_HERMES}/logs/gateway.log"
    if [[ -z "$_receive_bot_uid" ]]; then
      warn "Slack receive probe skipped — could not resolve bot user_id from auth.test"
    elif [[ ! -f "$_receive_log" ]]; then
      warn "Slack receive probe skipped — gateway.log not found at $_receive_log"
    else
      _receive_marker="doctor-receive-probe-$(date +%s)-$$"
      _receive_start_line="$(wc -l < "$_receive_log" 2>/dev/null || echo 0)"
      _receive_send_resp="$(curl -sS --max-time 10 -X POST \
        -H "Authorization: Bearer $slack_bot_token" \
        -H 'Content-Type: application/json' \
        -d "$(jq -n --arg ch "$SLACK_PROBE_TARGET" --arg uid "$_receive_bot_uid" --arg m "$_receive_marker" \
          '{channel: $ch, text: ("<@" + $uid + "> [doctor.sh receive-probe " + $m + "] gateway liveness check — ignore")}')" \
        -w $'\n%{http_code}' \
        'https://slack.com/api/chat.postMessage' 2>&1 || true)"
      _receive_send_status="$(printf '%s' "$_receive_send_resp" | tail -n1)"
      _receive_send_body="$(printf '%s' "$_receive_send_resp" | sed '$d')"
      if [[ "${_receive_send_status:-}" == "200" ]] && printf '%s' "$_receive_send_body" | grep -q '"ok":true'; then
        _receive_found=0
        _receive_waited=0
        while [[ "$_receive_waited" -lt 25 ]]; do
          if tail -n "+$((_receive_start_line + 1))" "$_receive_log" 2>/dev/null | grep -q "$_receive_marker"; then
            _receive_found=1
            break
          fi
          sleep 2
          _receive_waited=$((_receive_waited + 2))
        done
        if [[ "$_receive_found" -eq 1 ]]; then
          pass "Slack receive probe: gateway logged inbound event within ${_receive_waited}s (Event Subscriptions live)"
        else
          fail "Slack receive probe: no inbound event in gateway.log within 25s — Socket Mode may be connected but 'Enable Events' is OFF at https://api.slack.com/apps/<APP_ID>/event-subscriptions, or gateway is not processing messages (check for a stale gateway.lock / competing process)"
        fi
      else
        _receive_send_error="$(printf '%s' "$_receive_send_body" | jq -r '.error // "unknown error"' 2>/dev/null || echo "unknown error")"
        warn "Slack receive probe: chat.postMessage failed (HTTP ${_receive_send_status:-unknown}, error: $_receive_send_error) — send never succeeded, skipping 25s event wait"
      fi
    fi
  fi

  # 2. Gateway inference — real end-to-end LLM round-trip
  # Uses a longer timeout (60s) since cold-start LLM calls can be slow.
  # rc=124 = timed out — demote to WARN (gateway is healthy, model is just cold).
  # Skipped when HERMES_DOCTOR_SKIP_INFERENCE=1 (e.g. called from monitor which
  # already runs a canary E2E test for LLM reachability).
  if [[ "${HERMES_DOCTOR_SKIP_INFERENCE:-0}" == "1" ]]; then
    warn "Gateway inference probe skipped (HERMES_DOCTOR_SKIP_INFERENCE=1)"
  else
    infer_out="$(timeout "$INFER_TIMEOUT" hermes chat -q "Reply with exactly one word: pong" -Q --max-turns 1 2>&1)"
    infer_rc=$?
    if [[ "$infer_rc" -eq 0 && -n "$infer_out" ]]; then
      pass "Gateway inference probe succeeded (response: $(printf '%s' "$infer_out" | tr '\n' ' ' | cut -c1-40))"
    elif [[ "$infer_rc" -eq 124 ]]; then
      warn "Gateway inference probe timed out after ${INFER_TIMEOUT}s — gateway is running but model cold-start is slow"
    else
      fail "Gateway inference probe failed (rc=$infer_rc): $(printf '%s\n' "$infer_out" | head -1)"
    fi
  fi

  # 3. Memory lookup verification — ensure hermes memory status is functional
  if [[ "${HERMES_DOCTOR_SKIP_MEMORY:-0}" == "1" ]]; then
    warn "Memory lookup probe skipped (HERMES_DOCTOR_SKIP_MEMORY=1)"
  else
    memory_out="$(timeout 10 hermes memory status 2>&1)"
    memory_rc=$?
    if [[ "$memory_rc" -eq 0 ]]; then
      pass "Memory lookup probe succeeded (hermes memory status OK)"
    elif [[ "$memory_rc" -eq 124 ]]; then
      warn "Memory lookup command timed out after 10s — treating as transient"
    else
      fail "Memory lookup command failed (rc=$memory_rc): $memory_out"
    fi
  fi
fi

# gog (Google CLI) — OAuth + Gmail/Calendar/Drive probes (non-interactive)
if [[ "${HERMES_DOCTOR_SKIP_GOG:-0}" != "1" ]]; then
  printf '\n=== gog (Google CLI) ===\n'
  if command -v gog >/dev/null 2>&1; then
    _gog_health="$REPO_ROOT/scripts/gog-auth-health.sh"
    if [[ -x "$_gog_health" ]]; then
      LIVE_HERMES="${LIVE_HERMES:-$HOME/.smartclaw}" \
        bash "$_gog_health" >/tmp/gog-auth-health.out 2>/tmp/gog-auth-health.err
      _gog_rc=$?
      if [[ "$_gog_rc" -eq 0 ]]; then
        pass "gog: $(tr -d '\n' </tmp/gog-auth-health.out)"
      elif [[ "$_gog_rc" -eq 2 ]]; then
        warn "gog: $(head -1 /tmp/gog-auth-health.err 2>/dev/null || true) — see stderr in /tmp/gog-auth-health.err"
      else
        fail "gog auth/API probe failed — $(head -2 /tmp/gog-auth-health.err 2>/dev/null | tr '\n' ' ')"
      fi
    else
      warn "gog-auth-health.sh missing or not executable — skipped"
    fi
  else
    warn "gog not installed — skipped Google CLI probe (brew install jleechanorg/tap/gog)"
  fi
fi

# Lane backlog — Slack can stall while /health is 200 (parity with monitor-agent / CLAUDE.md)
printf '\n=== Gateway lane backlog (err.log) ===\n'
_err_log="${LIVE_HERMES}/logs/gateway.err.log"
if [[ -f "$_err_log" ]]; then
  # grep -c prints 0 with no match but may exit 1 — do not use || echo 0 (would duplicate)
  _lane_hits=$(tail -n 400 "$_err_log" 2>/dev/null | grep -c 'lane wait exceeded' 2>/dev/null || true)
  _lane_hits=$(echo "$_lane_hits" | tr -d '[:space:]')
  _lane_hits=${_lane_hits:-0}
  if [[ "$_lane_hits" =~ ^[0-9]+$ ]] && [[ "$_lane_hits" -gt 0 ]]; then
    warn "gateway.err.log shows lane wait exceeded ($_lane_hits hit(s) in last ~400 lines) — Slack may stall; see CLAUDE.md Gateway (lane backlog)"
  else
    pass "No recent lane wait exceeded in gateway.err.log tail (~400 lines)"
  fi
else
  warn "gateway.err.log not found at $_err_log — lane backlog check skipped"
fi

printf '\n=== Session health ===\n'

# Stale session lock files (dead-owner locks cause silent message loss)
SESSION_DIR="$LIVE_HERMES/agents/main/sessions"
if [[ -d "$SESSION_DIR" ]]; then
  stale_locks=()
  while IFS= read -r lockfile; do
    raw=$(cat "$lockfile" 2>/dev/null)
    pid=$(echo "$raw" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['pid'])" 2>/dev/null || echo "$raw" | tr -d '[:space:]')
    if [[ -n "$pid" ]] && [[ "$pid" =~ ^[0-9]+$ ]] && ! kill -0 "$pid" 2>/dev/null; then
      stale_locks+=("$(basename "$lockfile") (pid=$pid dead)")
    fi
  done < <(find "$SESSION_DIR" -name "*.lock" -maxdepth 1 2>/dev/null)
  if [[ ${#stale_locks[@]} -eq 0 ]]; then
    pass "No stale session lock files (dead-owner locks cause silent Slack message loss)"
  else
    fail "Stale session lock files found — remove and restart gateway: ${stale_locks[*]}"
  fi
  # Warn on excessive .tmp accumulation (indicates frequent unclean shutdowns)
  tmp_count=$(find "$SESSION_DIR" -name "*.tmp" -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$tmp_count" -gt 50 ]]; then
    warn "Excessive stale .tmp files in sessions dir ($tmp_count) — run: find $SESSION_DIR -name '*.tmp' -mtime +1 -delete"
  fi
else
  warn "Sessions dir $SESSION_DIR not found — session lock/.tmp checks skipped"
fi

printf '\n=== config.yaml validation ===\n'

# Pytest validation (hermes config)
if command -v python3 >/dev/null 2>&1 && python3 -c "import pytest" >/dev/null 2>&1; then
  pytest_out="$TMP_DIR/pytest-configs.txt"
  # Default: validate the same tree as LIVE_HERMES. Override via HERMES_DOCTOR_PYTEST_CONFIG_PATH.
  PYTEST_MAIN="$LIVE_HERMES/config.yaml"
  if [[ -n "${HERMES_DOCTOR_PYTEST_CONFIG_PATH:-}" ]] && [[ -f "${HERMES_DOCTOR_PYTEST_CONFIG_PATH}" ]]; then
    PYTEST_MAIN="${HERMES_DOCTOR_PYTEST_CONFIG_PATH}"
  fi
  if [[ -f "$REPO_ROOT/tests/test_hermes_configs.py" ]]; then
    # Run only the comprehensive config-validation classes (not legacy tests with known pre-existing failures)
    HERMES_TEST_MAIN_CONFIG_PATH="$PYTEST_MAIN" \
    python3 -m pytest "$REPO_ROOT/tests/test_hermes_configs.py" \
      -k "TestWsSafeAgentDefaults or TestMetaAndLogging or TestAuthProfiles or TestAgentDefaults or TestMinimaxProviderConsistency or TestToolsConfig or TestEnvSection or TestGatewaySecurity or TestHooksConfig or TestSessionConfig or TestCommandsConfig or TestMessagesConfig or TestPluginChannelConsistency or TestSlackChannelsConfig or TestRequiredAgents or TestSkillsConfig or TestExecSafeBins" \
      -v --tb=short 2>&1 | tee "$pytest_out" || true
    pytest_exit=${PIPESTATUS[0]}
    if [[ "$pytest_exit" -eq 0 ]]; then
      pytest_pass_count=$(grep -c ' PASSED' "$pytest_out" 2>/dev/null || true)
      pass "pytest config.yaml validation: $pytest_pass_count tests passed"
    else
      pytest_fail_count=$(grep -c ' FAILED\|ERROR' "$pytest_out" 2>/dev/null || true)
      fail "pytest config.yaml validation: $pytest_fail_count test(s) failed (see above)"
    fi
  else
    warn 'test_hermes_configs.py not found — skipping pytest config validation'
  fi
else
  warn 'python3 or pytest not available — skipping config.yaml pytest validation'
fi

printf '\n=== skill resolution audit ===\n' 2>/dev/null || true

# Fail if any SKILL.md is duplicated byte-for-byte across the two resolver roots.
# Both roots are valid (the canonical tree + the hermes-imports mirror), but they MUST
# not carry the same byte-identical file — the resolver refuses to pick between them
# and the cron silently adapt-inlines (clawchief:ea-sweep-hourly 2f942031797e pattern, 2026-08-18).
# Source repo for the canonical copy is hermes-imports/; the top-level mirror is the
# hub-install artifact that should be either (a) deleted, or (b) replaced with a
# regenerated file from the hub source. Either move synchronizes the resolver.
check_duplicate_skill_resolution() {
  local hermes_root="$1"
  local canonical_root="$hermes_root/skills"
  local mirror_root="$hermes_root/skills/hermes-imports"
  if [[ ! -d "$mirror_root" ]]; then
    pass "no hermes-imports/ mirror present (resolver cannot produce ambiguity)"
    return 0
  fi
  local dup_pairs=()
  local scanned=0
  # Build sha256 -> path map for mirror SKILL.md files
  while IFS= read -r -d '' skill_file; do
    scanned=$((scanned + 1))
  done < <(find "$mirror_root" -type f -name 'SKILL.md' -print0 2>/dev/null)
  if [[ "$scanned" -eq 0 ]]; then
    pass "no SKILL.md files under hermes-imports/ — no duplication possible"
    return 0
  fi
  while IFS= read -r -d '' skill_file; do
    local mirror_sha
    mirror_sha="$(shasum -a 256 "$skill_file" 2>/dev/null | awk '{print $1}')"
    # Compute the corresponding top-level path: hermes-imports/<category>/<name>/SKILL.md
    # maps to <category>/<name>/SKILL.md under the canonical root.
    local rel="${skill_file#"$mirror_root"/}"
    local canonical_path="$canonical_root/$rel"
    if [[ -f "$canonical_path" ]]; then
      local canonical_sha
      canonical_sha="$(shasum -a 256 "$canonical_path" 2>/dev/null | awk '{print $1}')"
      if [[ "$mirror_sha" == "$canonical_sha" ]]; then
        dup_pairs+=("$canonical_path  <==>  $skill_file")
      fi
    fi
  done < <(find "$mirror_root" -type f -name 'SKILL.md' -print0 2>/dev/null)
  if [[ ${#dup_pairs[@]} -eq 0 ]]; then
    pass "no duplicate-skill-resolution ambiguity under hermes-imports/ ($scanned skill files scanned)"
  else
    fail "duplicate-skill-resolution ambiguity detected (${#dup_pairs[@]} byte-identical pair(s)) — resolver will fail ambiguous; sync from hub then delete the local top-level mirror, OR delete the mirror copy under hermes-imports/ and let the canonical copy win. Pairs:"
    local pair
    for pair in "${dup_pairs[@]}"; do
      printf '         %s\n' "$pair" >&2
    done
  fi
}

# Run the check against the LIVE Hermes tree (where the resolver actually loads from),
# not REPO_ROOT (which is the doctor.sh checkout itself). Fall back to REPO_ROOT if
# LIVE_HERMES is unset for any reason.
_dup_skill_target="${LIVE_HERMES:-$REPO_ROOT}"
if [[ -d "$_dup_skill_target/skills" ]]; then
  check_duplicate_skill_resolution "$_dup_skill_target"
else
  warn "skill root not found at $_dup_skill_target/skills — duplicate-skill check skipped"
fi
unset _dup_skill_target

printf '\nSummary: %s pass, %s warn, %s fail\n' "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi

exit 0
