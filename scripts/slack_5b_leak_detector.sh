#!/usr/bin/env bash
# scripts/slack_5b_leak_detector.sh — Runtime safety-net detector for sub-class 5b
# Slack leaks (LLM agent narration posted to channel root without thread_ts).
#
# Why this exists: the CLAUDE.md sub-class 5b pre-write check failed on
# 2026-06-17 (ts=1781731123.137169 in #worldai). This detector is the
# post-write safety net: scan the last 1h of monitored channels, alert on
# the 5b signature so the operator can manually re-thread.
#
# Detection signature (mirrors CLAUDE.md "Detection signature (5b-specific)"):
#   • channel-root post (no thread_ts OR thread_ts == ts)
#   • author == hermes bot (default: U0AEZC7RX1Q)
#   • text OR emoji matches workflow signal:
#       text:  "Bring-to-green status" | "final interim summary" |
#              "Worker spawned" | "phase complete" | "Session complete" |
#              "/slack-audit" | "/skeptic"
#       emoji: ":clipboard:" | ":hourglass_flowing_sand:" |
#              ":large_green_circle:" | ":large_yellow_circle:" |
#              ":rotating_light:" | ":white_check_mark:" |
#              ":stopwatch:" | ":mag:"
#
# Inputs (env): SLACK_USER_TOKEN (req for live), SLACK_5B_CHANNELS,
#   SLACK_5B_BOT_USER_ID, SLACK_5B_STATE_FILE, SLACK_5B_LOOKBACK_SECS,
#   SLACK_5B_ALERT_CHANNEL, SLACK_5B_DRY_RUN, SLACK_5B_CURL_BIN.
# Outputs: stdout ALERT/OK lines; exit 0/1/2.
# Sourceable: IS_SOURCED=1 source scripts/slack_5b_leak_detector.sh

set -euo pipefail

# Config
SLACK_5B_CHANNELS="${SLACK_5B_CHANNELS:-C0AH3RY3DK6 C0BA4MCBPFB ${SLACK_CHANNEL_ID} ${SLACK_CHANNEL_ID}}"
SLACK_5B_BOT_USER_ID="${SLACK_5B_BOT_USER_ID:-U0AEZC7RX1Q}"
SLACK_5B_STATE_FILE="${SLACK_5B_STATE_FILE:-$HOME/.smartclaw/var/slack-5b-leak-detector.state}"
SLACK_5B_LOOKBACK_SECS="${SLACK_5B_LOOKBACK_SECS:-3600}"
SLACK_5B_ALERT_CHANNEL="${SLACK_5B_ALERT_CHANNEL:-${SLACK_CHANNEL_ID}}"
SLACK_5B_DRY_RUN="${SLACK_5B_DRY_RUN:-0}"
SLACK_5B_CURL_BIN="${SLACK_5B_CURL_BIN:-curl}"
# Slack thread state root: prod-cron lives in ~/.smartclaw_prod, so check both
# HERMES_PROD_HOME and the production default explicitly.
SLACK_5B_ANCHOR_DIRS="${SLACK_5B_ANCHOR_DIRS:-${HERMES_PROD_HOME:-$HOME/.smartclaw_prod}/var/slack ${HERMES_STATE_DIR:-$HOME/.smartclaw}/var/slack}"
DAILY_ANCHOR_GRACE_MIN="${DAILY_ANCHOR_GRACE_MIN:-10}"
# 5e: gateway-cron-LLM with deliver=local posts conversational narration at
# channel root instead of the cron job's origin thread. Cron jobs are read
# from $SLACK_5E_CRON_HOME/cron/jobs.json (default: $HERMES_PROD_HOME or
# ~/.smartclaw_prod) so the prod deployment is scanned without needing the
# staging tree.
SLACK_5E_CRON_HOME="${SLACK_5E_CRON_HOME:-${HERMES_PROD_HOME:-$HOME/.smartclaw_prod}}"
SLACK_5E_CRON_FILE="${SLACK_5E_CRON_FILE:-$SLACK_5E_CRON_HOME/cron/jobs.json}"
SLACK_5E_DISABLE_JOB_FIELD="${SLACK_5E_DISABLE_JOB_FIELD:-disable_5e_detect}"
SLACK_5E_LOOKBACK_SECS="${SLACK_5E_LOOKBACK_SECS:-7200}"
mkdir -p "$(dirname "$SLACK_5B_STATE_FILE")"
[[ -f "$SLACK_5B_STATE_FILE" ]] || : > "$SLACK_5B_STATE_FILE"

# Workflow signal regexes
_TEXT_SIGNAL_RE='(Bring-to-green status|final interim summary|Worker spawned|phase complete|Session complete|/slack-audit|/skeptic)'
_EMOJI_SIGNAL_RE='(:clipboard:|:hourglass_flowing_sand:|:large_green_circle:|:large_yellow_circle:|:rotating_light:|:white_check_mark:|:stopwatch:|:mag:)'

log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] $*" >&2; }

state_already_alerted() {
  [[ -s "$SLACK_5B_STATE_FILE" ]] && grep -Fxq "$1" "$SLACK_5B_STATE_FILE"
}

state_mark_alerted() { echo "$1" >> "$SLACK_5B_STATE_FILE"; }

match_workflow_signal() {
  local text="$1"
  if [[ "$text" =~ $_TEXT_SIGNAL_RE ]]; then REPLY="text:${BASH_REMATCH[0]}"; return 0; fi
  if [[ "$text" =~ $_EMOJI_SIGNAL_RE ]]; then REPLY="emoji:${BASH_REMATCH[0]}"; return 0; fi
  return 1
}

# is_intentional_anchor <channel_id> <ts>
#   Sub-class 5c: daily-thread-anchor first-of-day posts. Each cronjob that
#   uses lib/slack_thread_lib.sh stores its daily anchor ts in
#   ${HERMES_PROD_HOME:-$HOME/.smartclaw_prod}/var/slack/<job>/daily-thread.ts
#   (and under $HOME/.smartclaw in staging). The FIRST post of the UTC day is by
#   design a channel-root post (so the thread can be created); subsequent
#   posts in the same UTC day thread under it. To avoid a false-positive
#   leak alert on these legitimate first-of-day anchors, walk every job's
#   daily-thread.ts: if (a) mtime is within DAILY_ANCHOR_GRACE_MIN and (b) the
#   file's content equals the candidate ts, this is an intentional anchor
#   → return 0 (skip). Otherwise return 1 (treat as a real 5b leak).
#   Returns 0 on match (intentional), 1 on no match (real leak).
is_intentional_anchor() {
  local ts="$1" root job_dir anchor_file stored mtime now grace_epoch
  now=$(date +%s)
  grace_epoch=$((DAILY_ANCHOR_GRACE_MIN * 60))
  for root in $SLACK_5B_ANCHOR_DIRS; do
    [[ -d "$root" ]] || continue
    for job_dir in "$root"/*/; do
      [[ -d "$job_dir" ]] || continue
      anchor_file="${job_dir}daily-thread.ts"
      [[ -f "$anchor_file" ]] || continue
      # Portable mtime (BSD stat -f %m on macOS, GNU stat -c %Y on Linux).
      mtime=$(stat -c %Y "$anchor_file" 2>/dev/null \
        || stat -f %m "$anchor_file" 2>/dev/null \
        || echo 0)
      [[ -z "$mtime" || "$mtime" -eq 0 ]] && continue
      (( now - mtime <= grace_epoch )) || continue
      stored=$(cat "$anchor_file" 2>/dev/null | tr -d '[:space:]')
      [[ -z "$stored" ]] && continue
      if [[ "$stored" == "$ts" ]]; then
        return 0
      fi
    done
  done
  return 1
}

is_channel_root_post() {
  local msg="$1" ts thread_ts
  ts=$(printf '%s' "$msg" | jq -r '.ts // empty' 2>/dev/null)
  thread_ts=$(printf '%s' "$msg" | jq -r '.thread_ts // empty' 2>/dev/null)
  [[ -n "$ts" && -z "$thread_ts" ]] || [[ -n "$ts" && "$thread_ts" == "$ts" ]]
}

fetch_channel_history() {
  local channel="$1" oldest="$2" cursor="${3:-}" token="${SLACK_USER_TOKEN:-}"
  [[ -z "$token" ]] && { log "ERROR: SLACK_USER_TOKEN empty; skip $channel"; return 2; }
  if [[ -n "$cursor" ]]; then
    "$SLACK_5B_CURL_BIN" --silent --show-error --connect-timeout 10 --max-time 30 \
      -G "https://slack.com/api/conversations.history" \
      --data-urlencode "channel=$channel" \
      --data-urlencode "oldest=$oldest" \
      --data-urlencode "limit=100" \
      --data-urlencode "cursor=$cursor" \
      -H "Authorization: Bearer $token"
  else
    "$SLACK_5B_CURL_BIN" --silent --show-error --connect-timeout 10 --max-time 30 \
      -G "https://slack.com/api/conversations.history" \
      --data-urlencode "channel=$channel" \
      --data-urlencode "oldest=$oldest" \
      --data-urlencode "limit=100" \
      -H "Authorization: Bearer $token"
  fi
}

post_alert() {
  local channel="$1" ts="$2" reason="$3" preview="$4" token="${SLACK_USER_TOKEN:-}"
  local alert_text="*5b-leak safety-net alert* — channel <#$channel> ts=\`$ts\` reason=\`$reason\` — manual re-thread required. preview: \`$preview\`"
  [[ "$SLACK_5B_DRY_RUN" == "1" ]] && { log "[DRY_RUN] ALERT channel=$channel ts=$ts reason=$reason"; return 0; }
  [[ -z "$token" ]] && { log "ERROR: SLACK_USER_TOKEN empty; cannot post alert"; return 0; }
  "$SLACK_5B_CURL_BIN" --silent --show-error --connect-timeout 10 --max-time 30 \
    -X POST "https://slack.com/api/chat.postMessage" \
    -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
    -d "$(jq -n --arg ch "$SLACK_5B_ALERT_CHANNEL" --arg txt "$alert_text" \
      '{channel: $ch, text: $txt}')" >/dev/null 2>&1 || log "WARN: alert post failed for ts=$ts"
}

scan_channel() {
  local channel="$1" oldest="$2" history ok msg_count i msg author text reason ts preview
  local cursor="" next_cursor fetch_rc
  # Paginate via response_metadata.next_cursor until empty/null. fetch_channel_history
  # returns 2 on missing token / curl error → propagate so detect_5b_leaks can fail loud.
  while :; do
    history=$(fetch_channel_history "$channel" "$oldest" "$cursor"); fetch_rc=$?
    if [[ "$fetch_rc" -eq 2 ]]; then
      log "ERROR: history fetch failed for $channel (rc=2); aborting scan"
      return 2
    fi
    [[ -z "$history" ]] && return 2
    ok=$(printf '%s' "$history" | jq -r '.ok // false' 2>/dev/null)
    [[ "$ok" != "true" ]] && { log "ERROR: history fetch returned ok=false for $channel"; return 2; }
    msg_count=$(printf '%s' "$history" | jq -r '.messages | length' 2>/dev/null)
    [[ -z "$msg_count" || "$msg_count" == "null" ]] && msg_count=0
    for ((i=0; i<msg_count; i++)); do
      msg=$(printf '%s' "$history" | jq -c ".messages[$i]" 2>/dev/null)
      [[ -z "$msg" ]] && continue
      author=$(printf '%s' "$msg" | jq -r '.user // .bot_id // empty' 2>/dev/null)
      [[ "$author" == "$SLACK_5B_BOT_USER_ID" ]] || continue
      is_channel_root_post "$msg" || continue
      text=$(printf '%s' "$msg" | jq -r '.text // empty' 2>/dev/null)
      [[ -z "$text" ]] && continue
      if match_workflow_signal "$text"; then
        reason="$REPLY"
        ts=$(printf '%s' "$msg" | jq -r '.ts' 2>/dev/null)
        state_already_alerted "$ts" && continue
        # Sub-class 5c: skip legitimate daily-thread-anchor first-of-day posts.
        if is_intentional_anchor "$ts"; then
          log "intentional-anchor ts=$ts channel=$channel (matches recent var/slack/*/daily-thread.ts)"
          continue
        fi
        state_mark_alerted "$ts"
        preview="${text:0:140}"
        echo "ALERT ts=$ts channel=$channel author=$author reason=$reason preview=$preview"
        post_alert "$channel" "$ts" "$reason" "$preview"
      fi
    done
    next_cursor=$(printf '%s' "$history" | jq -r '.response_metadata.next_cursor // empty' 2>/dev/null)
    [[ -z "$next_cursor" || "$next_cursor" == "null" ]] && break
    cursor="$next_cursor"
  done
  return 0
}

detect_5b_leaks() {
  local oldest leak_count=0 channel line scan_rc scan_output
  local -a failed_channels=()
  oldest=$(($(date +%s) - SLACK_5B_LOOKBACK_SECS))
  for channel in $SLACK_5B_CHANNELS; do
    scan_output=$(mktemp)
    # `|| rc=$?` is required: with `set -e` from the script header, a plain
    # `; rc=$?` would abort the function before the assignment runs when
    # scan_channel exits 2, masking the error propagation path entirely.
    scan_channel "$channel" "$oldest" >"$scan_output" || scan_rc=$?
    : "${scan_rc:=0}"
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      echo "$line"
      leak_count=$((leak_count + 1))
    done < "$scan_output"
    rm -f "$scan_output"
    if [[ "$scan_rc" -eq 2 ]]; then
      failed_channels+=("$channel")
    fi
  done
  if [[ "${#failed_channels[@]}" -gt 0 ]]; then
    echo "ERROR: scan failures on channels: ${failed_channels[*]} (history fetch failed; check token/network)" >&2
    return 2
  fi
  if [[ "$leak_count" -eq 0 ]]; then
    echo "OK no leaks in last ${SLACK_5B_LOOKBACK_SECS}s across $(echo $SLACK_5B_CHANNELS | wc -w | tr -d ' ') channels"
    return 0
  fi
  return 1
}

# ─── Sub-class 5e: cron deliver=local narration leak ────────────────────────
# Signature: hermes bot posts at CHANNEL ROOT (no thread_ts) referencing
# BOTH the cron job name AND another PR/thread identifier from the cron
# job's prompt. The post should have been threaded under the job's
# `thread_ts` (origin thread). Real incident: ts 1781793603.149289
# (babysit-wa-2366-rev-5deak posting PR #7570 narration in C0AH3RY3DK6).
#
# Strategy:
#   1. Read jobs.json; keep only jobs where deliver == "local" AND
#      disable_5e_detect is not true.
#   2. For each such job, scan the job's channel history (last 2h by
#      default). A post is a leak when it (a) is at channel root, (b) is
#      authored by the bot, (c) contains the cron job name, AND (d)
#      contains at least one additional PR/thread identifier from the
#      job's prompt (extracted via simple grep — PR #NNN, bead keys, ts).
#   3. Honor the shared 5b state file for dedup and skip sub-class 5c
#      intentional-anchor posts.

extract_5e_identifiers() {
  # Echo one identifier per line from a cron job's prompt. Intentionally
  # simple regex — false positives in the test surface are acceptable as
  # long as they don't make the detector MISS real leaks.
  local prompt="$1" id
  while IFS= read -r id; do
    [[ -n "$id" ]] && printf '%s\n' "$id"
  done < <(printf '%s' "$prompt" | grep -oE 'PR #[0-9]+|rev-[a-z0-9]+|wa-[0-9]+|[a-z]{2}-[a-z0-9]{4}|[0-9]{10,}\.[0-9]{6}' | sort -u)
}

# extract_5e_channel <prompt> — best-effort Slack channel-id extraction from a
# cron job's prompt text. Real prod jobs (e.g. babysit-wa-2366-rev-5deak) do
# not always set channel_id at the JSON top level, but they typically embed
# the origin channel inline as bare C[A-Z0-9]{8,} ("C0AH3RY3DK6 / thread
# 1781477039.080969") or as Slack mention syntax "<#C0AH3RY3DK6>". The
# detector MUST scan the job's actual deliver target — silently skipping a
# job with no channel_id would leave the leak class unmonitored, so we
# derive from the prompt and return the first match. Returns 0 + prints
# channel id on success; returns 1 on no match.
extract_5e_channel() {
  local prompt="$1" chan
  chan=$(printf '%s' "$prompt" | grep -oE '<#C[A-Z0-9]{8,}>|C[A-Z0-9]{8,}' | head -n1 | tr -d '<>#')
  [[ -n "$chan" ]] || return 1
  printf '%s\n' "$chan"
}

detect_5e_for_job() {
  local job_name="$1" job_channel="$2" job_prompt="$3"
  local oldest history ok msg_count i msg author text ts thread_ts
  local identifier id_count match_count preview line found_id
  local cursor="" next_cursor fetch_rc
  local -a identifiers=()
  while IFS= read -r id; do
    [[ -n "$id" ]] && identifiers+=("$id")
  done < <(extract_5e_identifiers "$job_prompt")
  id_count="${#identifiers[@]}"
  [[ "$id_count" -ge 1 ]] || { log "5e skip job=$job_name (no identifiers extracted from prompt)"; return 0; }

  # Scan only the job's own channel (NOT the full SLACK_5B_CHANNELS list)
  # to keep the lookback budget tight per cron job. Paginate via
  # response_metadata.next_cursor so a high-traffic channel does not
  # silently truncate the scan at the first 100 messages.
  oldest=$(($(date +%s) - SLACK_5E_LOOKBACK_SECS))
  while :; do
    history=$(fetch_channel_history "$job_channel" "$oldest" "$cursor"); fetch_rc=$?
    if [[ "$fetch_rc" -eq 2 ]]; then
      log "5e history fetch failed for job=$job_name channel=$job_channel (rc=2); aborting"
      return 2
    fi
    [[ -z "$history" ]] && return 2
    ok=$(printf '%s' "$history" | jq -r '.ok // false' 2>/dev/null)
    [[ "$ok" != "true" ]] && { log "5e history fetch returned ok=false for job=$job_name channel=$job_channel"; return 2; }
    msg_count=$(printf '%s' "$history" | jq -r '.messages | length' 2>/dev/null)
    [[ -z "$msg_count" || "$msg_count" == "null" ]] && msg_count=0
    for ((i=0; i<msg_count; i++)); do
      msg=$(printf '%s' "$history" | jq -c ".messages[$i]" 2>/dev/null)
      [[ -z "$msg" ]] && continue
      author=$(printf '%s' "$msg" | jq -r '.user // .bot_id // empty' 2>/dev/null)
      [[ "$author" == "$SLACK_5B_BOT_USER_ID" ]] || continue
      is_channel_root_post "$msg" || continue
      text=$(printf '%s' "$msg" | jq -r '.text // empty' 2>/dev/null)
      [[ -z "$text" ]] && continue
      # Must mention the cron job name OR any of its hyphen-delimited parts
      # AND at least one prompt-extracted id. Many babysit job names embed
      # the bead/worker keys (e.g., "babysit-wa-2366-rev-5deak"), but the
      # narration text typically only references the bare keys ("wa-2366",
      # "rev-5deak"). Match the full name first; fall back to any part of
      # length ≥ 4 to avoid noise from common short words.
      local name_hit=0
      if [[ "$text" == *"$job_name"* ]]; then
        name_hit=1
      else
        local part
        for part in $(printf '%s' "$job_name" | tr '-' ' '); do
          [[ "${#part}" -ge 4 ]] && [[ "$text" == *"$part"* ]] && { name_hit=1; break; }
        done
      fi
      (( name_hit )) || continue
      match_count=0; found_id=""
      for id in "${identifiers[@]}"; do
        if [[ "$text" == *"$id"* ]]; then
          match_count=$((match_count + 1))
          found_id="$id"
        fi
      done
      (( match_count >= 1 )) || continue
      ts=$(printf '%s' "$msg" | jq -r '.ts' 2>/dev/null)
      state_already_alerted "$ts" && continue
      if is_intentional_anchor "$ts"; then
        log "5e intentional-anchor ts=$ts job=$job_name"
        continue
      fi
      state_mark_alerted "$ts"
      preview="${text:0:160}"
      line="5E-ALERT ts=$ts channel=$job_channel job=$job_name matched_id=$found_id id_count=$id_count preview=$preview"
      echo "$line"
      post_alert "$job_channel" "$ts" "5e-cron-deliver-local" "$preview"
    done
    next_cursor=$(printf '%s' "$history" | jq -r '.response_metadata.next_cursor // empty' 2>/dev/null)
    [[ -z "$next_cursor" || "$next_cursor" == "null" ]] && break
    cursor="$next_cursor"
  done
  return 0
}

detect_5e_local_deliver_leaks() {
  local leak_count=0 line job_count=0 failed_jobs=()
  local -a jobs=()
  if [[ ! -f "$SLACK_5E_CRON_FILE" ]]; then
    log "5e: cron file not found at $SLACK_5E_CRON_FILE; nothing to scan"
    echo "OK no 5e jobs to scan (missing $SLACK_5E_CRON_FILE)"
    return 0
  fi
  # Read jobs.json (handles both {jobs:[...]} and bare array shapes).
  while IFS= read -r line; do
    jobs+=("$line")
  done < <(jq -c '
    if type == "object" and (.jobs? | type) == "array" then .jobs[]
    elif type == "array" then .[]
    else empty
    end
    | select(.deliver == "local")
    | select((."'"$SLACK_5E_DISABLE_JOB_FIELD"'" // false) != true)
    | {name, channel_id, prompt}
  ' "$SLACK_5E_CRON_FILE" 2>/dev/null)
  job_count="${#jobs[@]}"
  if [[ "$job_count" -eq 0 ]]; then
    echo "OK no 5e-eligible jobs in $SLACK_5E_CRON_FILE"
    return 0
  fi
  for line in "${jobs[@]}"; do
    local job_name job_channel job_prompt scan_rc
    job_name=$(printf '%s' "$line" | jq -r '.name // empty')
    job_channel=$(printf '%s' "$line" | jq -r '.channel_id // empty')
    job_prompt=$(printf '%s' "$line" | jq -r '.prompt // empty')
    # job_name is required: without it the 5e name-hit branch in
    # detect_5e_for_job can never match.
    [[ -z "$job_name" ]] && { log "5e skip: job with empty name in $SLACK_5E_CRON_FILE"; continue; }
    if [[ -z "$job_channel" ]]; then
      # Fallback: extract channel id from the prompt text. Real prod jobs
      # embed the origin channel inline (e.g. "C0AH3RY3DK6 / thread …").
      job_channel=$(extract_5e_channel "$job_prompt" || true)
    fi
    if [[ -z "$job_channel" ]]; then
      # Fail loudly: silently skipping would leave this job's 5e leak
      # class unmonitored. Surface in operator-visible output and count
      # as a scan failure (rc=2 from the function).
      log "5e SCAN-GAP: job=$job_name has no channel_id and no extractable channel in prompt; cannot scan (add channel_id to jobs.json)"
      failed_jobs+=("$job_name")
      continue
    fi
    local out; out=$(mktemp)
    # Same `|| rc=$?` discipline as detect_5b_leaks.
    detect_5e_for_job "$job_name" "$job_channel" "$job_prompt" >"$out" || scan_rc=$?
    : "${scan_rc:=0}"
    while IFS= read -r alert_line; do
      [[ -z "$alert_line" ]] && continue
      echo "$alert_line"
      leak_count=$((leak_count + 1))
    done < "$out"
    rm -f "$out"
    [[ "$scan_rc" -eq 2 ]] && failed_jobs+=("$job_name")
  done
  if [[ "${#failed_jobs[@]}" -gt 0 ]]; then
    echo "ERROR: 5e scan failures on jobs: ${failed_jobs[*]} (history fetch failed; check token/network)" >&2
    return 2
  fi
  if [[ "$leak_count" -eq 0 ]]; then
    echo "OK no 5e leaks across $job_count deliver=local job(s)"
    return 0
  fi
  return 1
}

# detect_all_leaks — combined runner so a single cron invocation catches
# both 5b (workflow signal) and 5e (cron-job-name + identifier) leaks.
#
# Each detector's stdout is captured to a temp file, so its exit code
# ($? immediately after the redirect) is the real detector rc — not the
# rc of a `while read` loop or a `; true` sentinel. The captured stdout
# is then appended to the combined output stream. This is the documented
# 0/1/2 exit contract callers (launchd plist, cron jobs.json) rely on.
#
# Implementation note: each detector call uses `|| rc=$?` so a non-zero
# return from the detector (the leak/scan-failure path) does NOT trip
# `set -e` and abort the function before we can capture and propagate
# the real rc.
detect_all_leaks() {
  local rc_5b=0 rc_5e=0 out_5b out_5e line
  local -a out=()
  out_5b=$(mktemp); out_5e=$(mktemp)
  # 5b — `|| rc=$?` discipline, same as detect_5b_leaks / detect_5e_for_job.
  detect_5b_leaks >"$out_5b" 2>/dev/null || rc_5b=$?
  while IFS= read -r line; do
    [[ -n "$line" ]] && out+=("$line")
  done < "$out_5b"
  # 5e
  detect_5e_local_deliver_leaks >"$out_5e" 2>/dev/null || rc_5e=$?
  while IFS= read -r line; do
    [[ -n "$line" ]] && out+=("$line")
  done < "$out_5e"
  rm -f "$out_5b" "$out_5e"
  : "${rc_5b:=0}"; : "${rc_5e:=0}"
  printf '%s\n' "${out[@]}"
  # Return the worst rc: 2 > 1 > 0.
  if [[ "$rc_5b" -eq 2 || "$rc_5e" -eq 2 ]]; then return 2; fi
  if [[ "$rc_5b" -eq 1 || "$rc_5e" -eq 1 ]]; then return 1; fi
  return 0
}

if [[ "${IS_SOURCED:-0}" != "1" ]]; then
  if [[ -z "${SLACK_USER_TOKEN:-}" && "$SLACK_5B_DRY_RUN" != "1" ]]; then
    log "ERROR: SLACK_USER_TOKEN is required (or set SLACK_5B_DRY_RUN=1)"
    exit 2
  fi
  # Run the combined runner so a single cron invocation catches both 5b
  # (workflow signal) and 5e (cron-job-name + identifier) leaks. The
  # launchd plist + cron jobs.json both invoke this script directly, so
  # the main path MUST scan both leak classes.
  detect_all_leaks
fi
