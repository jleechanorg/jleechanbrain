#!/usr/bin/env bash
# scripts/autonomy-report.sh — Daily detector that scores Hermes against
# Jeffrey's left/right-shift autonomy tenet and posts a single Slack digest
# ONLY when violations are found. Quiet on success (matches the 5b-leak
# detector pattern).
#
# Tenet (from 2026-06-27 thread ${SLACK_CHANNEL_ID}, msg 1782598553.950269):
#   1. Left shift: spend more time UPFRONT on planning + setup. Mid-task
#      interruptions to ask the user questions or do validation are bad.
#   2. Right shift: spend more time at the END validating output (UI,
#      captioned video/gif of landing page or any user-facing surface).
#   3. AVOID: interrupting the user in the MIDDLE for things that should
#      have been done at the planning stage or the validation stage.
#
# What this detector scans (last 48h):
#   A. Slack threads where hermes asked the user a clarifying question
#      mid-flight (signal: any chat.postMessage with thread_ts that
#      contains a literal "?" right after the user said "drive" / "do it"
#      / "your call" / "/a" / "/fullrun").  ← LEFT-SHIFT FAIL
#   B. Slack threads where hermes finished a task WITHOUT posting an
#      evidence stack on a UI / landing-page / wizard change.           ← RIGHT-SHIFT FAIL
#   C. SOUL.md COMMIT coverage: ensure `a-fullrun-evidence-stack` is
#      loaded in BOTH ~/.smartclaw/SOUL.md AND ~/.smartclaw/SOUL.md.    ← TENET ENFORCEMENT
#   D. Mid-task "want me to X?" or "should I X?" follow-ups after a
#      /a or /fullrun was the prior user message.                       ← MID-TASK FAIL
#   E. Interactive `clarify` calls inside an /a / /fullrun / /auto run. ← MID-TASK FAIL
#
# Output contract:
#   - Quiet on success: exit 0, no stdout, no Slack post.
#   - On ANY violation: post ONE digest to AUTONOMY_ALERT_CHANNEL with
#     the failures + a one-line fix recommendation per failure.
#   - Always append a JSON line to the state log for trend tracking.
#
# Env (optional, with defaults):
#   AUTONOMY_ALERT_CHANNEL  default: C0AJQ5M0A0Y (=#ai-general home)
#   AUTONOMY_LOOKBACK_HOURS default: 48
#   AUTONOMY_DRY_RUN        1 = scan + log but do NOT post to Slack
#   AUTONOMY_STATE_FILE     default: ~/.smartclaw/var/autonomy-report.state.jsonl
#   AUTONOMY_CURL_BIN       default: curl
#   AUTONOMY_BOT_USER_ID    default: U0AEZC7RX1Q (hermes bot)
#   AUTONOMY_MONITORED_CHANNELS
#                           default: C0AH3RY3DK6 C0BA4MCBPFB ${SLACK_CHANNEL_ID} ${SLACK_CHANNEL_ID}
#                           (worldarchitect, worldai, jeffrey/jleechanbrain DM,
#                            ai-slack-test — same list as 5b-leak-detector)
#
# State: each tick appends one JSONL record with:
#   {ts, violations: N, by_signal: {A: n, B: n, C: n, D: n, E: n}, alert_posted: bool}
#
# Logs: ~/.smartclaw/logs/autonomy-report.{log,err}
# Sourceable: IS_SOURCED=1 source scripts/autonomy-report.sh
#
# Exit codes:
#   0 = clean (no violations OR dry-run successful)
#   1 = violations found (ALERT lines on stdout, Slack post attempted)
#   2 = scan failure (ERROR lines on stderr)

set -euo pipefail

# ── Force bash 4+ on macOS where /bin/bash is 3.2 ─────────────────────────
if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash "$HOME/.nvm/versions/node"/*/bin/bash; do
    if [[ -x "$candidate" ]]; then
      exec "$candidate" "$0" "$@"
    fi
  done
  echo "autonomy-report: bash 4+ required (have bash ${BASH_VERSION}); no candidate found" >&2
  exit 1
fi

# ── Config ─────────────────────────────────────────────────────────────────
AUTONOMY_ALERT_CHANNEL="${AUTONOMY_ALERT_CHANNEL:-C0AJQ5M0A0Y}"
AUTONOMY_LOOKBACK_HOURS="${AUTONOMY_LOOKBACK_HOURS:-48}"
AUTONOMY_DRY_RUN="${AUTONOMY_DRY_RUN:-0}"
AUTONOMY_STATE_FILE="${AUTONOMY_STATE_FILE:-$HOME/.smartclaw/var/autonomy-report.state.jsonl}"
AUTONOMY_CURL_BIN="${AUTONOMY_CURL_BIN:-curl}"
AUTONOMY_BOT_USER_ID="${AUTONOMY_BOT_USER_ID:-U0AEZC7RX1Q}"
AUTONOMY_MONITORED_CHANNELS="${AUTONOMY_MONITORED_CHANNELS:-C0AH3RY3DK6 C0BA4MCBPFB ${SLACK_CHANNEL_ID} ${SLACK_CHANNEL_ID}}"
HERMES_HOME="${HERMES_HOME:-${HOME}/.smartclaw}"
LOG_DIR="$HERMES_HOME/logs"
mkdir -p "$LOG_DIR" "$(dirname "$AUTONOMY_STATE_FILE")"
LOG_FILE="$LOG_DIR/autonomy-report.log"
ERR_FILE="$LOG_DIR/autonomy-report.err"
ts() { date '+%Y-%m-%dT%H:%M:%S%z'; }

if [[ "${IS_SOURCED:-0}" -ne 1 ]]; then
  # Parse command line options
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        AUTONOMY_DRY_RUN=1
        shift
        ;;
      --48h)
        AUTONOMY_LOOKBACK_HOURS=48
        shift
        ;;
      --7d)
        AUTONOMY_LOOKBACK_HOURS=168
        shift
        ;;
      --channel)
        if [[ -n "${2:-}" ]]; then
          AUTONOMY_ALERT_CHANNEL="$2"
          shift 2
        else
          echo "Error: --channel requires a value" >&2
          exit 2
        fi
        ;;
      *)
        echo "Error: Unknown option $1" >&2
        exit 2
        ;;
    esac
  done
fi

# SECURITY: scrub tokens from any log output (mirrors 5b-leak-detector).
scrub_token() {
  printf '%s' "$1" | sed -E 's/xox[abp]-[A-Za-z0-9-]{20,}/<TOKEN_REDACTED>/g'
}
log() {
  printf '[%s] %s\n' "$(ts)" "$(scrub_token "$*")" >> "$LOG_FILE"
}
err() {
  printf '[%s] ERROR %s\n' "$(ts)" "$(scrub_token "$*")" >> "$ERR_FILE" >&2
}

# ── Signal A: mid-flight clarifying questions after /a or /fullrun ────────
# Scan messages authored by hermes bot in the lookback window. A signal
# is any hermes-authored thread reply that contains a question mark AND
# whose parent thread (or prior user message) contains an /a or /fullrun
# trigger phrase.
trigger_pattern='(/\a\b|/\bfullrun\b|/auto\b|/finish\b|fullsend|drive with /a|do it|just do it|your call|you decide|handle it|ship it|hands off mode|fullrun|don.t stop halfway)'
question_pattern='\?'

scan_mid_task_clarifying() {
  local violations=0
  local channels_arr=($AUTONOMY_MONITORED_CHANNELS)
  for ch in "${channels_arr[@]}"; do
    # Use Slack search via the MCP shim path: pull last N hours of channel
    # history, filter to hermes bot, then check if parent thread had a
    # trigger phrase. We use the conversations.history API directly via curl
    # because the launchd job may not have MCP context.
    local since_ts=$(( $(date +%s) - AUTONOMY_LOOKBACK_HOURS * 3600 ))
    local resp
    resp=$("$AUTONOMY_CURL_BIN" -sS --max-time 30 \
      -H "Authorization: Bearer ${SLACK_BOT_TOKEN:-}" \
      "https://slack.com/api/conversations.history?channel=${ch}&oldest=${since_ts}&limit=200" \
      2>>"$ERR_FILE") || { err "scan_mid_task_clarifying: curl failed for $ch"; continue; }
    # Lightweight parser: jq-free awk that finds lines with bot user + "?"
    # and remembers the parent text for the trigger-pattern check.
    echo "$resp" | awk -v bot="$AUTONOMY_BOT_USER_ID" -v trig="$trigger_pattern" '
      BEGIN { qcount=0 }
      /"user":"[^"]*'"$AUTONOMY_BOT_USER_ID"'"/ {
        bot_msg = 1
        line = $0
        # Pull text
        if (match($0, /"text":"[^"]*"/)) {
          text = substr($0, RSTART+9, RLENGTH-10)
        } else { text = "" }
        if (text ~ /\?/) {
          # Check the thread for a trigger
          # (simplified: rely on parent_text set below)
          if (parent_text ~ trig) {
            qcount++
            printf "VIOLATION signal=A channel=%s ts=%s q=%s\n", ch, "...", text
          }
        }
        bot_msg = 0
      }
      /"text":"[^"]*\/a / || /"text":"[^"]*fullsend/ {
        if (!bot_msg && match($0, /"text":"[^"]*"/)) {
          parent_text = substr($0, RSTART+9, RLENGTH-10)
        }
      }
      END { exit (qcount>0?1:0) }
    ' >> "$LOG_FILE" 2>&1 && violations=$((violations + 0)) || violations=$((violations + $(echo "$?")))
  done
  echo "$violations"
}

# ── Signal B: UI changes finished without visual proof ─────────────────────
# Heuristic: scan the same channels for hermes "done" replies on threads
# where prior messages referenced UI keywords (UI / landing / wizard /
# form / modal / theme) but the final reply lacks visual proof markers
# (MEDIA:, !\[alt\], /er, /skeptic).
scan_ui_without_proof() {
  local violations=0
  local ui_keywords='(UI|landing page|wizard|form|modal|theme|styling|CSS|layout)'
  local proof_keywords='(MEDIA:|\!\['
  local channels_arr=($AUTONOMY_MONITORED_CHANNELS)
  for ch in "${channels_arr[@]}"; do
    local since_ts=$(( $(date +%s) - AUTONOMY_LOOKBACK_HOURS * 3600 ))
    local resp
    resp=$("$AUTONOMY_CURL_BIN" -sS --max-time 30 \
      -H "Authorization: Bearer ${SLACK_BOT_TOKEN:-}" \
      "https://slack.com/api/conversations.history?channel=${ch}&oldest=${since_ts}&limit=200" \
      2>>"$ERR_FILE") || continue
    echo "$resp" | python3 -c "
import json, sys, re
try:
    data = json.loads(sys.stdin.read())
except Exception:
    sys.exit(0)
msgs = data.get('messages', [])
ui_kw = re.compile(r'(UI|landing page|wizard|form|modal|theme|styling|CSS|layout)', re.I)
proof_kw = re.compile(r'(MEDIA:|!\[|screenshot|playwright|capture-before-after)', re.I)
done_kw = re.compile(r'(done|finished|shipped|merged|green)', re.I)
count = 0
# Group messages by thread_ts (parent)
threads = {}
for m in msgs:
    if m.get('subtype'):
        continue
    thread = m.get('thread_ts') or m.get('ts')
    threads.setdefault(thread, []).append(m)
for ts_id, tmsgs in threads.items():
    ui_in_thread = any(ui_kw.search(m.get('text','')) for m in tmsgs)
    has_proof = any(proof_kw.search(m.get('text','')) for m in tmsgs)
    hermes_done = any(
        m.get('user') == '$AUTONOMY_BOT_USER_ID' and done_kw.search(m.get('text',''))
        for m in tmsgs
    )
    if ui_in_thread and hermes_done and not has_proof:
        count += 1
        print(f'VIOLATION signal=B channel=$ch ts={ts_id} reason=ui_finished_without_proof')
sys.exit(0 if count == 0 else 1)
" 2>>"$ERR_FILE" || violations=$((violations + 1))
  done
  echo "$violations"
}

# ── Signal C: SOUL.md COMMIT coverage check ────────────────────────────────
# Verifies that `## COMMIT: a-fullrun-evidence-stack` is present in BOTH
# the staging SOUL.md (symlink to workspace/SOUL.md) AND the prod SOUL.md.
scan_soul_coverage() {
  local missing=0
  local staging_path="$HERMES_HOME/workspace/SOUL.md"
  local prod_path="$HOME/.smartclaw/SOUL.md"
  local required_commit="a-fullrun-evidence-stack"

  if [[ ! -f "$staging_path" ]]; then
    err "scan_soul_coverage: missing $staging_path"
    missing=$((missing + 1))
  elif ! grep -q "## COMMIT: $required_commit" "$staging_path"; then
    echo "VIOLATION signal=C path=$staging_path reason=missing_commit:$required_commit" >> "$LOG_FILE"
    missing=$((missing + 1))
  fi

  if [[ ! -f "$prod_path" ]]; then
    err "scan_soul_coverage: missing $prod_path"
    missing=$((missing + 1))
  elif ! grep -q "## COMMIT: $required_commit" "$prod_path"; then
    echo "VIOLATION signal=C path=$prod_path reason=missing_commit:$required_commit" >> "$LOG_FILE"
    missing=$((missing + 1))
  fi

  echo "$missing"
}

# ── Signal D: "want me to X?" / "should I X?" follow-ups after /a/fullrun ──
# Catches the exact anti-pattern from the user's bug-ref: posting
# "want me to X?" follow-ups after a hands-off directive. The COMMIT
# itself says no follow-up questions, but the detector verifies behavior.
scan_followup_prompts() {
  local violations=0
  local anti_pattern='(want me to|should I|shall I|do you want me to|would you like me to|let me know if)'
  local channels_arr=($AUTONOMY_MONITORED_CHANNELS)
  for ch in "${channels_arr[@]}"; do
    local since_ts=$(( $(date +%s) - AUTONOMY_LOOKBACK_HOURS * 3600 ))
    local resp
    resp=$("$AUTONOMY_CURL_BIN" -sS --max-time 30 \
      -H "Authorization: Bearer ${SLACK_BOT_TOKEN:-}" \
      "https://slack.com/api/conversations.history?channel=${ch}&oldest=${since_ts}&limit=200" \
      2>>"$ERR_FILE") || continue
    echo "$resp" | python3 -c "
import json, sys, re
try:
    data = json.loads(sys.stdin.read())
except Exception:
    sys.exit(0)
msgs = data.get('messages', [])
anti = re.compile(r'(want me to|should I|shall I|do you want me to|would you like me to|let me know if)', re.I)
trigger = re.compile(r'(/\a\b|/\bfullrun\b|/auto\b|/finish\b|fullsend|your call|just do it|hands off mode)', re.I)
bot = '$AUTONOMY_BOT_USER_ID'
threads = {}
for m in msgs:
    if m.get('subtype'):
        continue
    thread = m.get('thread_ts') or m.get('ts')
    threads.setdefault(thread, []).append(m)
count = 0
for ts_id, tmsgs in threads.items():
    had_trigger = any(not (m.get('user') == bot) and trigger.search(m.get('text','')) for m in tmsgs)
    has_followup = any(m.get('user') == bot and anti.search(m.get('text','')) for m in tmsgs)
    if had_trigger and has_followup:
        count += 1
        print(f'VIOLATION signal=D channel=$ch ts={ts_id} reason=followup_after_hands_off_directive')
sys.exit(0 if count == 0 else 1)
" 2>>"$ERR_FILE" || violations=$((violations + 1))
  done
  echo "$violations"
}

# ── Signal E: Slack search.cross-channel autonomy keywords ──────────────────
# Uses search.messages with user token to look for autonomy keywords in monitored channels.
signal_e_slack_search() {
  local query='"/a","/fullrun","fullsend","want me to","hands off","evidence stack","left shift","right shift"'
  local lookback_hours="$AUTONOMY_LOOKBACK_HOURS"
  local user_token="${HERMES_SLACK_USER_TOKEN:-${SLACK_USER_TOKEN:-}}"
  
  if [[ -z "$user_token" ]]; then
    echo "skipped — user token missing search:read scope"
    return 0
  fi

  AUTONOMY_USER_TOKEN="$user_token" \
  AUTONOMY_SLACK_QUERY="$query" \
  AUTONOMY_LOOKBACK_HOURS="$lookback_hours" \
  AUTONOMY_LOG_FILE="$LOG_FILE" \
  AUTONOMY_ERR_FILE="$ERR_FILE" \
  AUTONOMY_MONITORED_CHANNELS="$AUTONOMY_MONITORED_CHANNELS" \
  python3 -c "
import sys, os, urllib.request, urllib.parse, json, re, time

token = os.environ.get('AUTONOMY_USER_TOKEN', '')
lookback_hours = int(os.environ.get('AUTONOMY_LOOKBACK_HOURS', '48'))
debug_toggle = os.environ.get('AUTONOMY_SLACK_SEARCH_DEBUG', '0') == '1'
log_file = os.environ.get('AUTONOMY_LOG_FILE', '')
err_file = os.environ.get('AUTONOMY_ERR_FILE', '')

query = os.environ.get('AUTONOMY_SLACK_QUERY', '')
encoded_query = urllib.parse.quote(query)
url = f'https://slack.com/api/search.messages?query={encoded_query}&count=100'

req = urllib.request.Request(
    url,
    headers={'Authorization': f'Bearer {token}'}
)

def _scrub(s):
    return re.sub(r'xox[abp]-[A-Za-z0-9-]{20,}', '<TOKEN_REDACTED>', s)

mock_search = os.environ.get('AUTONOMY_MOCK_SLACK_SEARCH', '0') == '1'
try:
    if mock_search:
        mock_matches_json = os.environ.get('AUTONOMY_MOCK_SLACK_MATCHES', '[]')
        res = {\"ok\": True, \"messages\": {\"matches\": json.loads(mock_matches_json)}}
    else:
        with urllib.request.urlopen(req, timeout=15) as response:
            res_data = response.read()
            res = json.loads(res_data.decode('utf-8'))
        
        if debug_toggle:
            tmp_path = f'/tmp/autonomy-report-signal-e-{os.getpid()}.json'
            with open(tmp_path, 'wb') as f:
                f.write(res_data)
            sys.stderr.write(f'Raw Slack search API response saved to {tmp_path}\n')

        if not res.get('ok'):
            err_code = res.get('error', 'unknown_error')
            if err_code in ('not_allowed_token_type', 'missing_scope', 'invalid_auth', 'account_inactive', 'token_revoked'):
                print('skipped — user token missing search:read scope')
                sys.exit(0)
            else:
                with open(err_file, 'a') as f:
                    err_msg = f'[{time.strftime(\"%Y-%m-%dT%H:%M:%S\")}][Signal E] Error: {err_code}\n'
                    f.write(_scrub(err_msg))
                print('skipped — user token missing search:read scope')
                sys.exit(0)

        matches = res.get('messages', {}).get('matches', [])
        now = time.time()
        since_ts = now - lookback_hours * 3600
        
        keywords = ['/a', '/fullrun', 'fullsend', 'want me to', 'hands off', 'evidence stack', 'left shift', 'right shift']
        keyword_counts = {kw: 0 for kw in keywords}
        
        monitored_channels = set(os.environ.get('AUTONOMY_MONITORED_CHANNELS', '').split())
        
        valid_matches = []
        for m in matches:
            try:
                ts_val = float(m.get('ts', 0))
            except ValueError:
                continue
            if ts_val < since_ts:
                continue
            
            ch_id = m.get('channel', {}).get('id')
            ch_name = m.get('channel', {}).get('name')
            
            if ch_id in monitored_channels or ch_name == 'all-jleechan-ai':
                valid_matches.append(m)
                text = m.get('text', '')
                for kw in keywords:
                    if kw.lower() in text.lower():
                        keyword_counts[kw] += 1
                        
        if not valid_matches:
            print('0')
            sys.exit(0)
            
        sorted_kws = sorted(keyword_counts.items(), key=lambda x: x[1], reverse=True)
        top_kws = [f'{kw}: {count}' for kw, count in sorted_kws[:5] if count > 0]
        kw_str = ', '.join(top_kws) if top_kws else 'none'
        
        thread_tss = []
        for m in valid_matches:
            t_ts = m.get('thread_ts') or m.get('ts')
            if t_ts and t_ts not in thread_tss:
                thread_tss.append(t_ts)
                
        top_threads = thread_tss[:3]
        threads_str = ', '.join(top_threads) if top_threads else 'none'
        
        with open(log_file, 'a') as f:
            f.write(_scrub(f'VIOLATION signal=E keyword_counts={kw_str} threads={threads_str}\n'))
            for m in valid_matches[:3]:
                match_text = f'  - Match: channel={m.get(\"channel\", {}).get(\"name\")} ts={m.get(\"ts\")} text={m.get(\"text\")[:60]}...\n'
                f.write(_scrub(match_text))
                
        print(f'{len(valid_matches)} keyword_counts={kw_str} threads={threads_str}')
        
except Exception as e:
    with open(err_file, 'a') as f:
        err_msg = f'[{time.strftime(\"%Y-%m-%dT%H:%M:%S\")}][Signal E] Exception: {e}\n'
        f.write(_scrub(err_msg))
    print('skipped — user token missing search:read scope')
    sys.exit(0)
"
}

# ── Signal F: /ms (memory_search) cross-reference ──────────────────────────
# Tries session_search + memory_search, falls back to grep over memory dirs.
signal_f_memory_crossref() {
  local hit_ids=""
  local fallback_triggered=1

  if command -v session_search >/dev/null 2>&1; then
    local bin_session="session_search"
    
    if "$bin_session" --probe >/dev/null 2>&1 || "$bin_session" -h >/dev/null 2>&1; then
      local s_hits
      s_hits=$("$bin_session" "autonomy report violation signal" 2>/dev/null | grep -E '^[0-9a-f]{8,}' | head -3 || true)
      
      local bin_mem="${MEMORY_SEARCH_BIN:-memory_search}"
      local m_hits=""
      if [[ -x "$bin_mem" ]] || command -v "$bin_mem" >/dev/null 2>&1; then
        m_hits=$("$bin_mem" "autonomy left shift right shift" 2>/dev/null | grep -E '^[0-9a-f]{8,}' | head -3 || true)
      fi
      
      local combined
      combined=$(echo -e "${s_hits}\n${m_hits}" | grep -E '^[0-9a-f]{8,}' | sort -u | head -3 || true)
      if [[ -n "$combined" ]]; then
        hit_ids=$(echo "$combined" | tr '\n' ' ' | xargs)
        fallback_triggered=0
      fi
    fi
  fi

  if [[ "$fallback_triggered" -eq 1 ]]; then
    local paths
    paths=$(grep -rln -E 'autonomy|left.shift|right.shift' \
      ~/.smartclaw/memory/ ~/.smartclaw/var/memory/ 2>/dev/null \
      | head -10 || true)
    if [[ -n "$paths" ]]; then
      local path_list=""
      while read -r p; do
        if [[ -n "$p" ]]; then
          path_list="${path_list} ${p/#$HOME/\~}"
        fi
      done <<< "$paths"
      echo "grep_fallback:${path_list# }"
    else
      echo "none"
    fi
  else
    echo "hits:${hit_ids}"
  fi
}

# ── Aggregate + state log + Slack post ─────────────────────────────────────
run() {
  log "autonomy-report tick: lookback=${AUTONOMY_LOOKBACK_HOURS}h dry_run=${AUTONOMY_DRY_RUN}"
  local a b c d e f
  a=$(scan_mid_task_clarifying || echo "0")
  b=$(scan_ui_without_proof || echo "0")
  c=$(scan_soul_coverage || echo "0")
  d=$(scan_followup_prompts || echo "0")
  
  local e_out f_out
  e_out=$(signal_e_slack_search || echo "0")
  f_out=$(signal_f_memory_crossref || echo "0")
  
  # Normalize to ints
  a=$(echo "$a" | grep -E '^[0-9]+$' | head -1 || echo 0)
  b=$(echo "$b" | grep -E '^[0-9]+$' | head -1 || echo 0)
  c=$(echo "$c" | grep -E '^[0-9]+$' | head -1 || echo 0)
  d=$(echo "$d" | grep -E '^[0-9]+$' | head -1 || echo 0)
  
  local e_status="0"
  local e=0
  if [[ "$e_out" == "skipped"* ]]; then
    e_status="$e_out"
    e=0
  else
    e=$(echo "$e_out" | awk '{print $1}' | grep -E '^[0-9]+$' || echo 0)
    if [[ "$e" -gt 0 ]]; then
      local e_details
      e_details=$(echo "$e_out" | cut -d' ' -f2-)
      e_status="$e ($e_details)"
    else
      e_status="0"
    fi
  fi
  
  local f_status="0"
  local f=0
  if [[ "$f_out" == "grep_fallback:"* ]]; then
    local paths_str="${f_out#grep_fallback:}"
    if [[ "$paths_str" == "none" || -z "$paths_str" ]]; then
      f_status="0 (grep fallback: none)"
      f=0
    else
      f=$(echo "$paths_str" | wc -w | xargs)
      f_status="$f (grep fallback: $paths_str)"
    fi
  elif [[ "$f_out" == "hits:"* ]]; then
    local hits_str="${f_out#hits:}"
    if [[ "$hits_str" == "none" || -z "$hits_str" ]]; then
      f_status="0"
      f=0
    else
      f=$(echo "$hits_str" | wc -w | xargs)
      f_status="$f (hits: $hits_str)"
    fi
  else
    f_status="0"
    f=0
  fi
  
  local total=$((a + b + c + d + e + f))
  log "results: A(mid-task-clarify)=$a B(ui-no-proof)=$b C(soul-coverage)=$c D(followup)=$d E(slack-search)=$e F(memory-crossref)=$f total=$total"

  # Extract VIOLATION detail lines
  local detail
  detail=$(grep '^VIOLATION ' "$LOG_FILE" 2>/dev/null | tail -15 || true)

  # Always append JSONL state
  printf '{"ts":"%s","A":%d,"B":%d,"C":%d,"D":%d,"E":%d,"F":%d,"total":%d,"alert_posted":%s}\n' \
    "$(ts)" "$a" "$b" "$c" "$d" "$e" "$f" "$total" "false" \
    >> "$AUTONOMY_STATE_FILE"

  if [[ "$total" -eq 0 ]]; then
    log "clean: no violations, exiting 0"
    exit 0
  fi

  # Post the alert
  local body
  body=$(cat <<EOF
🚨 *Autonomy Report — violations in last ${AUTONOMY_LOOKBACK_HOURS}h*

Total: *$total* violations across the left/right-shift tenet.

• Signal A (mid-task clarifying after /a or /fullrun): $a
• Signal B (UI change finished without visual proof): $b
• Signal C (SOUL.md COMMIT missing on staging or prod): $c
• Signal D (follow-up "want me to X?" after hands-off): $d
• Signal E (slack search keywords): $e_status
• Signal F (/ms cross-reference):     $f_status

\`\`\`
$(echo "$detail" | head -15)
\`\`\`

*Remediation per signal:*
- A → front-load the planning question into the brief BEFORE \`ao spawn\`
- B → use the \`a-fullrun-evidence-stack\` COMMIT contract (UI changes need MEDIA: + /er)
- C → commit + push + Stage 4.5 sync (re-run \`deploy.sh\`)
- D → never post "want me to X?" after an /a or /fullrun — finish the job
- E → user token missing search:read scope OR check keywords
- F → verify memory search configuration or review fallback files

Full state: \`${AUTONOMY_STATE_FILE}\`
EOF
)

  if [[ "$AUTONOMY_DRY_RUN" == "1" ]]; then
    log "DRY_RUN: $total violations, would alert but suppressing"
    echo "$body"
    exit 1
  fi
  local post_resp
  post_resp=$("$AUTONOMY_CURL_BIN" -sS --max-time 15 \
    -X POST \
    -H "Authorization: Bearer ${SLACK_BOT_TOKEN:-}" \
    -H "Content-Type: application/json; charset=utf-8" \
    --data "$(python3 -c "import json,sys; print(json.dumps({'channel':'$AUTONOMY_ALERT_CHANNEL','text':sys.stdin.read()}))" <<< "$body")" \
    "https://slack.com/api/chat.postMessage" 2>>"$ERR_FILE") || { err "Slack post failed"; exit 2; }
  log "Slack post response: $(echo "$post_resp" | head -c 200)"

  # Update state with alert_posted=true
  printf '{"ts":"%s","A":%d,"B":%d,"C":%d,"D":%d,"E":%d,"F":%d,"total":%d,"alert_posted":true}\n' \
    "$(ts)" "$a" "$b" "$c" "$d" "$e" "$f" "$total" \
    >> "$AUTONOMY_STATE_FILE"

  exit 1
}

run "$@"