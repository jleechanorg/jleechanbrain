#!/usr/bin/env bash
# slack-thread-roadmap-report.sh
#
# Every 4 hours between 8am and midnight, audit recent Slack threads for
# actionable work that Jeffrey (or the agent) could drive next, run the
# actionable threads through a direct LLM call for a judgment, then
# commit a detailed markdown report to jleechanorg/roadmap (origin main).
#
# Pipeline (per tick):
#   1. Run dropped-thread-followup.sh in DRY_RUN mode → list of "would nudge"
#      threads (actionable per the dropped-thread criteria).
#   2. For each actionable thread, fetch last 50 messages via Slack API.
#   3. Bundle all threads into a single LLM prompt that asks the model to:
#        - summarize each thread's current state in 1-2 lines
#        - judge whether /a or /auto could drive it next
#        - propose the exact next command Jeffrey could run
#   4. Render the LLM output into a single markdown file:
#        <roadmap>/YYYY-MM-DD-HHMM-slack-thread-roadmap.md
#   5. git worktree at ~/.worktrees/roadmap-<timestamp>, cp file in, commit
#      to origin main, push. (Worktree pattern per worldarchitect: primary
#      checkout is untouchable, ALWAYS worktree for PR/push work.)
#   6. Log final report path + commit SHA. If the script runs at 00:00
#      local it produces a "midnight sweep" report covering the whole day.
#
# Env (optional, with defaults):
#   ROADMAP_REPO    default: jleechanorg/roadmap (cloned fresh per tick via worktree)
#   ROADMAP_BRANCH  default: main
#   DROP_SCRIPT     default: ~/.smartclaw/scripts/dropped-thread-followup.sh
#   DROP_CHANNELS   default: $AUTOARM_CHANNELS (C0AH3RY3DK6 ${SLACK_CHANNEL_ID})
#   DROP_LOOKBACK_H default: 48  (matches dropped-thread-followup default)
#   THREAD_REPLY_LIMIT default: 50
#   CODEX_PROJECT   default: "slack-thread-roadmap-report"
#   DRY_RUN         1 = audit + codex call + write file, but SKIP git push
#   SKIP_CODEX      1 = use a heuristic summary instead of codex (fallback if codex
#                     is unavailable; rare — codex is installed at /opt/homebrew/bin/codex)
#   DAILY_ANCHOR_CHANNEL  default: C0AJQ5M0A0Y (=#ai-general). Where the
#                         single top-level daily-anchor digest is posted.
#                         Per-channel summaries are still fanned out as
#                         threaded REPLIES under each originating thread.
#   DAILY_ANCHOR_GRACE_MIN default: 60. Skip per-thread replies for threads
#                         younger than this (the daily anchor already
#                         lists them — avoids double-coverage). Matches
#                         the 5b-leak-detector.sh grace window.
#
# Logs: ~/.smartclaw/logs/slack-thread-roadmap-report.{log,err}
# Idempotency: each tick produces a new timestamped file, so no clobbering.
# Failure isolation: a per-thread codex parse error skips that thread, doesn't
#                    abort the whole report.
set -euo pipefail

# Force bash 4+ on macOS where /bin/bash is 3.2 (hermes pattern).
if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash "$HOME/.nvm/versions/node"/*/bin/bash; do
    if [[ -x "$candidate" ]]; then
      exec "$candidate" "$0" "$@"
    fi
  done
  echo "slack-thread-roadmap-report: bash 4+ required (have bash ${BASH_VERSION}); no candidate found" >&2
  exit 1
fi

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin${PATH:+:$PATH}"

# ── Config ────────────────────────────────────────────────────────────────────
# Hardcode HERMES_HOME to ~/.smartclaw (the user's git-tracked repo where
# launchd plists + scripts live). The Hermes/openclaw gateway runs from
# ~/.smartclaw and may set $HOME to that path, so we cannot rely on
# the ${HOME:-...} defaulting pattern alone.
HERMES_HOME="${HERMES_HOME:-${HOME}/.smartclaw}"
OUTBOUND_SECRET_GATE="${OUTBOUND_SECRET_GATE:-$HERMES_HOME/lib/outbound_secret_gate.py}"
LOG_DIR="$HERMES_HOME/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/slack-thread-roadmap-report.log"
ERR_FILE="$LOG_DIR/slack-thread-roadmap-report.err"
ts() { date '+%Y-%m-%dT%H:%M:%S%z'; }
# SECURITY: use the shared outbound sanitizer so logs and public bodies use
# the same credential families and redaction behavior.
scrub_token() {
  local input="$1"
  printf '%s' "$input" | python3 "$OUTBOUND_SECRET_GATE" redact
}
log() { scrub_token "[$(ts)] $*" | tee -a "$LOG_FILE" >&2; }
err() { scrub_token "[$(ts)] ERROR: $*" | tee -a "$ERR_FILE" >&2; }

DROP_SCRIPT="${DROP_SCRIPT:-$HERMES_HOME/scripts/dropped-thread-followup.sh}"
ROADMAP_REPO="${ROADMAP_REPO:-jleechanorg/roadmap}"
ROADMAP_BRANCH="${ROADMAP_BRANCH:-main}"
# Channels: by default we let dropped-thread-followup.sh pick its own
# (DROP_PRIORITY_CHANNELS + DM = 5 operator channels). Set DROP_CHANNELS
# env var to override. DO NOT default to a narrow 2-channel set — that
# hides actionable threads in ai-slack-test/jleechanbrain/agent-orchestrator.
# Empty string here means "use followup.sh default"; we keep the variable
# set to stay bash set -u safe.
DROP_CHANNELS="${DROP_CHANNELS:-}"
DROP_LOOKBACK_H="${DROP_LOOKBACK_H:-48}"
THREAD_REPLY_LIMIT="${THREAD_REPLY_LIMIT:-50}"
CODEX_PROJECT="${CODEX_PROJECT:-slack-thread-roadmap-report}"
DRY_RUN="${DRY_RUN:-0}"
# Pre-default env capture (diagnose unexpected SKIP_CODEX inheritance).
# Captures whether SKIP_CODEX/HERMES_HOME were already set in the inherited
# env before the script's own default kicks in. Lets the next SKIP_CODEX=1
# occurrence be traceable to its source (cron env, launchd plist, wrapper, etc.).
# parent_comm / parent_cmd identify the immediate caller of this script so the
# DIAG log self-attributes its source (cron → launchd → hermes gateway → this
# script). Without these, every SKIP_CODEX=1 incident requires a manual
# `ps -p $PPID` cross-reference, which is lost by the time the log is triaged.
# Default to <unset> when PPID is unreachable (orphaned, race, or `ps` missing
# from PATH — extremely rare on macOS but the script also runs under launchd
# where $PATH is intentionally narrow).
_parent_comm="$(command -v ps >/dev/null 2>&1 && ps -o comm= -p "$PPID" 2>/dev/null | tr -d '\n' || true)"
_parent_cmd="$(command -v ps >/dev/null 2>&1 && ps -o args= -p "$PPID" 2>/dev/null | tr -d '\n' || true)"
: "${_parent_comm:=<unset>}"
: "${_parent_cmd:=<unset>}"
log "DIAG: pre-default SKIP_CODEX='${SKIP_CODEX:-<unset>}' HERMES_HOME='${HERMES_HOME:-<unset>}' PPID=$PPID parent_comm='${_parent_comm}' parent_cmd='${_parent_cmd}'"
SKIP_CODEX="${SKIP_CODEX:-0}"
unset _parent_comm _parent_cmd

# Load Slack token from interactive shell (launchd doesn't source ~/.bashrc).
TOKEN="${SLACK_BOT_TOKEN:-}"
if [[ -z "$TOKEN" ]]; then
  TOKEN="$(bash -c 'source ~/.bashrc 2>/dev/null; echo -n "${SLACK_BOT_TOKEN:-}"' 2>/dev/null || true)"
fi
if [[ -z "$TOKEN" && -z "$DRY_RUN" ]]; then
  # Try the value already in the env (we may be running via the env-wrapper
  # which exports it directly).
  TOKEN="${SLACK_BOT_TOKEN:-}"
fi

# Overlap lock — skip if another tick is still running.
LOCK_DIR="${TMPDIR:-/tmp}/hermes-slack-thread-roadmap-report.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  log "SKIP: another instance running (lock=$LOCK_DIR)"
  exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

log "=== start (channels='$DROP_CHANNELS' lookback=${DROP_LOOKBACK_H}h dry_run=$DRY_RUN skip_codex=$SKIP_CODEX token=${TOKEN:+set}${TOKEN:-MISSING}) ==="

# ── Step 1: dropped-thread audit (DRY_RUN) ─────────────────────────────────────
AUTO_RESOLVE_SCRIPT="${AUTO_RESOLVE_SCRIPT:-$HERMES_HOME/scripts/dropped-thread-auto-resolve.sh}"
if [[ -x "$AUTO_RESOLVE_SCRIPT" ]]; then
  log "  running dropped-thread-auto-resolve.sh (pre-cleanup)"
  bash "$AUTO_RESOLVE_SCRIPT" >> "$LOG_FILE" 2>&1 || log "  auto-resolve: exited non-zero (continuing)"
fi

if [[ ! -x "$DROP_SCRIPT" ]]; then
  err "dropped-thread-followup.sh not found at $DROP_SCRIPT — cannot scan. Bailing."
  exit 1
fi

TMPDIR_LOCAL=$(mktemp -d -t roadmap-report.XXXXXX)
trap 'rm -rf "$TMPDIR_LOCAL"; rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

DRY_RUN=1 \
  DROP_LOOKBACK_HOURS="$DROP_LOOKBACK_H" \
  DROP_CHANNELS="$DROP_CHANNELS" \
  DROP_THREAD_REPLY_LIMIT="$THREAD_REPLY_LIMIT" \
  DROP_PROGRESS_STALE_MINUTES=10 \
  bash "$DROP_SCRIPT" > "$TMPDIR_LOCAL/audit.txt" 2>&1 || {
    err "dropped-thread-followup.sh exited non-zero; bailing. Tail: $(tail -5 "$TMPDIR_LOCAL/audit.txt")"
    exit 1
  }

# Parse "DRY_RUN: would nudge <chan> <ts>" lines.
mapfile -t NUDGE_LINES < <(grep -E "DRY_RUN: would nudge" "$TMPDIR_LOCAL/audit.txt" || true)
log "  audit: ${#NUDGE_LINES[@]} actionable threads"

if [[ ${#NUDGE_LINES[@]} -eq 0 ]]; then
  log "  no actionable threads; writing 'all-clear' report and exiting"
  NUDGE_LINES=()
fi

# ── Step 2: per-thread message fetch ──────────────────────────────────────────
slack_thread_replies() {
  # slack_thread_replies <channel> <thread_ts>  → JSON list of messages on stdout
  local channel="$1" thread_ts="$2"
  [[ -z "$TOKEN" ]] && { echo "[]"; return 0; }
  # NOTE: the token is bound to the curl Authorization header at call time.
  # We do NOT scrub it here because curl sees the literal value. The token
  # is held only in the variable $TOKEN for the lifetime of this process.
  curl --silent --show-error --connect-timeout 10 --max-time 30 \
    -X POST "https://slack.com/api/conversations.replies" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "channel=${channel}" \
    --data-urlencode "ts=${thread_ts}" \
    --data-urlencode "limit=${THREAD_REPLY_LIMIT}" \
    | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
    print(json.dumps(d.get("messages") or []))
except Exception:
    print("[]")
' 2>/dev/null || echo "[]"
}

slack_user_info() {
  # slack_user_info <user_id>  → "Name" on stdout (best effort; cached locally).
  # NOT USED in the report itself — kept here as a stub for future enhancement
  # where we want to render "@Jeffrey Lee-Chan" instead of "U09GH5BR3QU" in
  # the executive summary. Disabled to avoid extra API calls per thread.
  local uid="$1"
  echo "$uid"
}

declare -a THREAD_REPORTS
THREAD_REPORTS_COUNT=0  # set -u safe counter, incremented in the for-loop

for line in "${NUDGE_LINES[@]}"; do
  chan=$(echo "$line" | grep -oE "nudge [A-Z0-9]+ [0-9.]+" | awk '{print $2}' || echo "")
  ts_id=$(echo "$line" | grep -oE "nudge [A-Z0-9]+ [0-9.]+" | awk '{print $3}' || echo "")
  if [[ -z "$chan" || -z "$ts_id" ]]; then
    err "  could not parse nudge line: $line"
    continue
  fi

  # The dropped-thread-followup's nudge line uses the format:
  #   "DRY_RUN: would nudge CHAN TS (open operator ask (KIND, AGEm): <text>): <message>"
  # KIND is one of: unanswered, partial-pending-agent, partial-pending-user,
  # partial-no-delivery, timeout, gave-up, cold-thread, etc.
  # AGE is in minutes (e.g. "380m"). We convert to hours for the report.
  kind=$(echo "$line" | grep -oE "operator ask \([^,]+," | sed -E 's/operator ask \(([^,]+),.*/\1/' | tr '-' '_' || echo "unknown")
  age_min=$(echo "$line" | grep -oE ", [0-9]+m\)" | grep -oE "[0-9]+" | head -1 || echo "0")
  if [[ -n "$age_min" && "$age_min" -gt 0 ]]; then
    age=$(awk -v m="$age_min" 'BEGIN{printf "%.1f", m/60}')
  else
    age="?"
  fi
  # Reason (text after "operator ask (KIND, AGEm): " up to first '"' or '`')
  reason=$(echo "$line" | sed -E 's/.*operator ask \([^,]+, [0-9]+m\): //' | sed -E 's/["`].*//' | head -c 200 || echo "")

  # SKIP safety-net automated alerts: they're internal monitoring noise, not
  # real operator asks. Pattern: "*5b-leak safety-net alert*" or
  # "Reaction 'skeptic-advice' escalated after N attempts".
  if echo "$reason" | grep -qiE "5b-leak safety-net alert|skeptic-advice.*escalated after [0-9]+ attempt"; then
    log "  skipping safety-net noise: $chan/$ts_id"
    continue
  fi

  log "  fetching thread $chan/$ts_id (kind=$kind age=${age}h)"
  messages_json=$(slack_thread_replies "$chan" "$ts_id")

  # Build a compact thread digest for the LLM: per-message (user, time, text).
  # We use a one-shot python3 -c with the script as a string. The bash
  # heredoc+command-substitution combo is fragile and the error message
  # ("syntax error near token (") points to the wrong line.
  # NOTE: do NOT add a `--` separator before the JSON arg. With
  # `python3 -c SCRIPT -- "$messages_json"`, sys.argv[1] is the literal
  # string "--" (the option-list terminator) and sys.argv[2] is the JSON.
  # Reading sys.argv[1] silently fails JSON parse and falls through to the
  # "[parse error]" branch, which is the source of every thread showing
  # "Digest failed to parse" / "unreadable" in the LLM judgment.
  PY_DIGEST_SCRIPT='import json, sys
msgs = json.loads(sys.argv[1]) if sys.argv[1] else []
out = []
for m in msgs[-30:]:
    u = m.get("user") or m.get("bot_id") or "?"
    txt = (m.get("text") or "").replace("\n", " ").strip()
    if len(txt) > 280: txt = txt[:280] + "\u2026"
    ts_str = m.get("ts", "")
    out.append(f"[{ts_str}] <{u}> {txt}")
print("\n".join(out))
'
  if ! digest=$(python3 -c "$PY_DIGEST_SCRIPT" "$messages_json" 2>/dev/null); then
    digest="[parse error]"
  fi

  # Truncate digest so the codex prompt doesn't blow the context window.
  digest_truncated=$(echo "$digest" | head -c 8000)
  thread_url="https://jleechanai.slack.com/archives/${chan}/p${ts_id//./}"

  THREAD_REPORTS+=("CHANNEL=$chan
THREAD_TS=$ts_id
THREAD_URL=$thread_url
KIND=$kind
AGE_HOURS=$age
REASON=$reason
DIGEST_START
$digest_truncated
DIGEST_END")
  THREAD_REPORTS_COUNT=$((THREAD_REPORTS_COUNT + 1))
done

# ── Step 3: LLM judgment via shared helper (lib-llm-judgment.sh) ──────────────
# DRY: prompt template, JSON request body, curl invocation, and response
# parser all live in lib-llm-judgment.sh. If the LLM provider or model
# changes, edit there once.
NOW_LOCAL=$(date '+%Y-%m-%d %H:%M:%S %Z')
NOW_ISO=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

# Source the shared helper. The lib is non-fatal to source (no set -e at
# top level that would abort the caller).
# Try $HERMES_HOME first (set in launchd), then fall back to the git-tracked
# location, then to the prod deploy path.
LIB=""
for candidate in \
  "$HERMES_HOME/scripts/lib-llm-judgment.sh" \
  "$HOME/.smartclaw/scripts/lib-llm-judgment.sh" \
  "$HOME/.smartclaw/scripts/lib-llm-judgment.sh"; do
  if [[ -f "$candidate" ]]; then
    LIB="$candidate"
    break
  fi
done
if [[ -n "$LIB" ]]; then
  # shellcheck disable=SC1090
  source "$LIB"
else
  err "lib-llm-judgment.sh not found at any candidate path; SKIP_CODEX=1 (HEURISTIC FALLBACK). LLM judgment will be SKIPPED. candidates_searched: $HERMES_HOME/scripts/lib-llm-judgment.sh | $HOME/.smartclaw/scripts/lib-llm-judgment.sh | $HOME/.smartclaw/scripts/lib-llm-judgment.sh"
  SKIP_CODEX=1
  # Note: a Slack alert for the missing-lib case is intentionally not
  # emitted from this branch because lib-slack-post.sh hasn't been sourced
  # yet, and we don't want to duplicate alert paths. The SKIP_CODEX=1
  # branch below will fire the alert using the sourced lib.
fi

# Source lib-slack-post.sh early so we can fire a one-line Slack alert when
# the LLM call fails (root-cause fix for the 2026-06-21 0820 incident where
# 29 threads were silently judged as "no LLM judgment available" because
# lib-llm-judgment.sh was killed by SIGTERM → KeyboardInterrupt at 180s;
# the cron swallowed the failure and the report went out with placeholders).
# Source path: the LIB fallback chain above picks the first candidate that
# exists (staging $HERMES_HOME/scripts → ~/.smartclaw/scripts → ~/.smartclaw/scripts).
# Step 6 (Slack post) does NOT re-source — it checks function presence via
# `declare -f slack_post_message` to avoid double-sourcing. The lib itself
# is idempotent under double-source (it guards with set +u/function redefine),
# but using `declare -f` keeps the call site explicit and avoids surprises.
SLACK_LIB=""
for candidate in \
  "$HERMES_HOME/scripts/lib-slack-post.sh" \
  "$HOME/.smartclaw/scripts/lib-slack-post.sh" \
  "$HOME/.smartclaw/scripts/lib-slack-post.sh"; do
  if [[ -f "$candidate" ]]; then
    SLACK_LIB="$candidate"
    break
  fi
done
if [[ -n "$SLACK_LIB" ]]; then
  # shellcheck disable=SC1090
  source "$SLACK_LIB"
fi
# Channel for failure alerts. Same default as the daily-anchor channel so
# operators see it in the same stream. Override via SLACK_FAILURE_ALERT_CHANNEL
# if you want a dedicated oncall channel.
FAILURE_ALERT_CHANNEL="${SLACK_FAILURE_ALERT_CHANNEL:-${DAILY_ANCHOR_CHANNEL:-C0AJQ5M0A0Y}}"

# THREAD_REPORTS_COUNT is incremented in the for-loop above (set -u safe).
if [[ $THREAD_REPORTS_COUNT -eq 0 ]]; then
  log "  no threads to judge; skipping LLM call"
  LLM_JUDGMENT="(no actionable threads in last ${DROP_LOOKBACK_H}h; all-clear report)"
elif [[ "$SKIP_CODEX" == "1" ]]; then
  log "WARN: SKIP_CODEX=1 → using heuristic summary (NO LLM JUDGMENT). Next run should configure SKIP_CODEX=0 via environment variable defaults (according to the in-repo tunable policy) instead of modifying launchd config."
  log "WARN: Pre-default DIAG was: $(grep "DIAG: pre-default" "$LOG_FILE" 2>/dev/null | tail -1)"
  LLM_JUDGMENT="(LLM unavailable (SKIP_CODEX=$SKIP_CODEX); this is a heuristic-only report — see raw thread digests below)"
  # Fire a one-line alert so a misconfigured cron is visible immediately.
  # Same channel as LLM-failure alerts; the home channel is fine.
  if declare -f slack_post_message >/dev/null 2>&1; then
    diag_line=$(grep "DIAG: pre-default" "$LOG_FILE" 2>/dev/null | tail -1 | head -c 700)
    alert_text="⚠️ slack-thread-roadmap-report SKIP_CODEX=1 — ${#THREAD_REPORTS[@]} threads judged heuristically (no LLM). diag: $diag_line"
    if ! slack_post_message "$FAILURE_ALERT_CHANNEL" "$alert_text" >>"$LOG_FILE" 2>&1; then
      err "  SKIP_CODEX alert Slack post failed (continuing)"
    else
      log "  SKIP_CODEX alert posted to $FAILURE_ALERT_CHANNEL"
    fi
  fi
else
  # Concatenate thread reports with delimiters.
  THREADS_BUNDLE=$(printf '\n\n---\n\n%s\n' "${THREAD_REPORTS[@]}")

  log "  invoking LLM for ${#THREAD_REPORTS[@]} threads (via lib-llm-judgment.sh)"
  if LLM_JUDGMENT=$(llm_judgment_for_threads "$TMPDIR_LOCAL" "${#THREAD_REPORTS[@]}" "$THREADS_BUNDLE" 2>"$TMPDIR_LOCAL/llm.err"); then
    log "  LLM call succeeded ($(echo -n "$LLM_JUDGMENT" | wc -c) bytes)"
  else
    local_rc=$?
    err "  LLM call failed (rc=$local_rc): $(tail -3 "$TMPDIR_LOCAL/llm.err")"
    LLM_JUDGMENT="(LLM call failed; raw thread digests below)"
    # Fire a one-line Slack alert to the home channel so the failure is
    # visible immediately — not buried inside the per-thread placeholder
    # text. Caps at ~700 chars to stay under Slack's 4000-char message
    # ceiling. Idempotent: alerts only on actual failure, not on heuristic
    # fallback (SKIP_CODEX=1 above). Uses FAILURE_ALERT_CHANNEL default.
    if declare -f slack_post_message >/dev/null 2>&1; then
      err_tail=$(tail -c 700 "$TMPDIR_LOCAL/llm.err" 2>/dev/null | tr '\n' ' ')
      alert_text="⚠️ slack-thread-roadmap-report LLM judgment FAILED at $(date '+%H:%M:%S %Z') — ${#THREAD_REPORTS[@]} threads will be posted with 'no LLM judgment' placeholder. rc=$local_rc. tail: $err_tail"
      if ! slack_post_message "$FAILURE_ALERT_CHANNEL" "$alert_text" >>"$LOG_FILE" 2>&1; then
        err "  failure-alert Slack post failed (continuing; report still committed)"
      else
        log "  failure alert posted to $FAILURE_ALERT_CHANNEL"
      fi
    else
      log "  slack_post_message unavailable; skipping failure alert (report still committed)"
    fi
  fi
fi

# Persist thread + judgment state for Step 6 (Slack post). We rebuild
# `chan|ts|url|kind` rows from THREAD_REPORTS so the post step doesn't
# have to re-parse the LLM bundle.
THREADS_CSV="$TMPDIR_LOCAL/threads.csv"
: > "$THREADS_CSV"
for report in "${THREAD_REPORTS[@]}"; do
  chan=$(printf '%s' "$report" | awk -F= '/^CHANNEL=/{print $2; exit}')
  ts=$(printf '%s' "$report" | awk -F= '/^THREAD_TS=/{print $2; exit}')
  url=$(printf '%s' "$report" | awk -F= '/^THREAD_URL=/{print $2; exit}')
  kind=$(printf '%s' "$report" | awk -F= '/^KIND=/{print $2; exit}')
  [[ -z "$chan" || -z "$url" ]] && continue
  printf '%s|%s|%s|%s\n' "$chan" "$ts" "$url" "$kind" >> "$THREADS_CSV"
done
JUDGMENT_FILE="$TMPDIR_LOCAL/judgment.md"
printf '%s' "$LLM_JUDGMENT" > "$JUDGMENT_FILE"
log "  persisted ${THREAD_REPORTS_COUNT} threads → $THREADS_CSV"

# ── Step 4: render markdown report ────────────────────────────────────────────
REPORT_DATE=$(date '+%Y-%m-%d')
REPORT_TIME=$(date '+%H%M')
REPORT_FILE="${REPORT_DATE}-${REPORT_TIME}-slack-thread-roadmap.md"
ROADMAP_LOCAL_DIR="$HERMES_HOME/state/roadmap-report"
mkdir -p "$ROADMAP_LOCAL_DIR"
REPORT_LOCAL_PATH="$ROADMAP_LOCAL_DIR/$REPORT_FILE"

cat > "$REPORT_LOCAL_PATH" <<EOF
# Slack thread roadmap — $REPORT_DATE $REPORT_TIME

*Generated by* \`ai.smartclaw.schedule.slack-thread-roadmap-report\`
*Lookback*: last ${DROP_LOOKBACK_H}h
*Channels*: \`$DROP_CHANNELS\`
*Actionable threads*: ${THREAD_REPORTS_COUNT}

## Executive summary

$LLM_JUDGMENT

## Raw thread digests (fallback if LLM was unavailable)

These digests are what was sent to the LLM. If the LLM section is unavailable
or stale, Jeffrey can read these directly.

EOF

# Append each thread digest as a collapsible block.
for report in "${THREAD_REPORTS[@]}"; do
  echo "" >> "$REPORT_LOCAL_PATH"
  echo "<details>" >> "$REPORT_LOCAL_PATH"
  echo "" >> "$REPORT_LOCAL_PATH"
  echo "$report" | sed 's/^/    /' >> "$REPORT_LOCAL_PATH"
  echo "" >> "$REPORT_LOCAL_PATH"
  echo "</details>" >> "$REPORT_LOCAL_PATH"
done

cat >> "$REPORT_LOCAL_PATH" <<'EOF'

---

*Cron*: `ai.smartclaw.schedule.slack-thread-roadmap-report` — every 12h at 08:00 + 20:00 local (reduced from 4h/5x on 2026-06-23 per Jeffrey)
*Log*: `~/.smartclaw/logs/slack-thread-roadmap-report.log`
EOF

log "  report written: $REPORT_LOCAL_PATH ($(wc -c < "$REPORT_LOCAL_PATH") bytes)"

# ── Step 5: commit to jleechanorg/roadmap via worktree ────────────────────────
if [[ "$DRY_RUN" == "1" ]]; then
  log "  DRY_RUN=1: skipping git push. Report at: $REPORT_LOCAL_PATH"
  log "=== done (dry run) ==="
  exit 0
fi

WORKTREE_BASE="$HOME/.worktrees/roadmap-$(date '+%Y%m%d-%H%M%S')"
mkdir -p "$(dirname "$WORKTREE_BASE")"

# Clone the repo into a fresh worktree (worldarchitect pattern: primary
# checkout is untouchable, always worktree for push work).
# --depth 1 keeps the clone fast but means we MUST rebase before push
# to handle the case where another tick (or a manual push) landed first.
REPO_URL="https://github.com/${ROADMAP_REPO}.git"
log "  cloning $REPO_URL → $WORKTREE_BASE"
if ! git clone --depth 1 --branch "$ROADMAP_BRANCH" "$REPO_URL" "$WORKTREE_BASE" \
     >> "$LOG_FILE" 2>&1; then
  err "git clone failed; report stays at $REPORT_LOCAL_PATH (Jeffrey can copy manually)"
  log "=== done (clone failed) ==="
  exit 1
fi

cp "$REPORT_LOCAL_PATH" "$WORKTREE_BASE/$REPORT_FILE"
cd "$WORKTREE_BASE"

# Fetch full history and rebase before push. Multiple cron runs (or manual
# pushes) can land between our clone and push; --depth 1 + a fast-forward
# merge from origin is the simplest race fix. --unshallow so rebase has
# context if our commit is non-fast-forward.
git -C "$WORKTREE_BASE" fetch --unshallow origin "$ROADMAP_BRANCH" >> "$LOG_FILE" 2>&1 || \
  log "  unshallow fetch failed (continuing; will retry on push)"
if ! git -C "$WORKTREE_BASE" rebase "origin/$ROADMAP_BRANCH" >> "$LOG_FILE" 2>&1; then
  err "git rebase onto origin/$ROADMAP_BRANCH failed; aborting push to avoid divergence"
  git -C "$WORKTREE_BASE" rebase --abort >> "$LOG_FILE" 2>&1 || true
  log "=== done (rebase failed) ==="
  exit 1
fi

# Commit. -c user.email uses the canonical email per launchd-job-authoring
# env-preferences (never @example.com).
COMMIT_MSG="chore(roadmap): slack thread action plan — $REPORT_DATE $REPORT_TIME

Auto-generated by ai.smartclaw.schedule.slack-thread-roadmap-report.
Covers last ${DROP_LOOKBACK_H}h; ${#NUDGE_LINES[@]} actionable threads."

if ! git -C "$WORKTREE_BASE" -c user.email=${GITHUB_USER}@users.noreply.github.com \
       -c user.name=${GITHUB_USER} \
       add "$REPORT_FILE" >> "$LOG_FILE" 2>&1; then
  err "git add failed in $WORKTREE_BASE"
  log "=== done (git add failed) ==="
  exit 1
fi

if ! git -C "$WORKTREE_BASE" -c user.email=${GITHUB_USER}@users.noreply.github.com \
       -c user.name=${GITHUB_USER} \
       commit -m "$COMMIT_MSG" >> "$LOG_FILE" 2>&1; then
  err "git commit failed (no changes? race?): $(tail -5 "$LOG_FILE")"
  log "=== done (git commit failed) ==="
  exit 1
fi

# Push with one retry on non-fast-forward. After a successful rebase the
# push should be fast-forward, but a parallel manual push could still race.
PUSH_OK=0
for push_attempt in 1 2 3; do
  if git -C "$WORKTREE_BASE" push origin "$ROADMAP_BRANCH" >> "$LOG_FILE" 2>&1; then
    PUSH_OK=1
    break
  fi
  log "  push attempt $push_attempt failed; rebasing and retrying"
  git -C "$WORKTREE_BASE" fetch origin "$ROADMAP_BRANCH" >> "$LOG_FILE" 2>&1 || true
  git -C "$WORKTREE_BASE" rebase "origin/$ROADMAP_BRANCH" >> "$LOG_FILE" 2>&1 || {
    err "rebase on push retry failed; aborting"
    git -C "$WORKTREE_BASE" rebase --abort >> "$LOG_FILE" 2>&1 || true
    break
  }
done

if [[ $PUSH_OK -ne 1 ]]; then
  err "git push failed after 3 attempts. Worktree left at $WORKTREE_BASE for manual recovery."
  log "=== done (git push failed) ==="
  exit 1
fi

COMMIT_SHA=$(git -C "$WORKTREE_BASE" rev-parse HEAD)
REPORT_URL="https://github.com/${ROADMAP_REPO}/blob/${ROADMAP_BRANCH}/${REPORT_FILE}"
log "  pushed: $REPORT_URL (commit $COMMIT_SHA)"

# Cleanup worktree (rm -rf is safe here: it's a throwaway clone).
rm -rf "$WORKTREE_BASE"

# ── Step 6: post per-thread summary to each watched channel ──────────────────
# We post a single message in each watched channel that links the full
# report and includes the per-thread judgment (8-line excerpt) so Jeffrey
# can scan in-context. Failures here do not fail the run — the report is
# already committed.
if [[ -f "$THREADS_CSV" && -f "$JUDGMENT_FILE" && -s "$THREADS_CSV" ]]; then
  log "=== step 6: slack per-thread summary ==="
  # lib-slack-post.sh was sourced at the top of this script (Step 3) so we
  # could fire a one-line failure alert on LLM errors. Re-sourcing here
  # would be redundant; check that the function is present and skip if so.
  if ! declare -f slack_post_daily_anchor >/dev/null 2>&1; then
    err "  lib-slack-post.sh functions unavailable; skipping slack post (functions missing despite earlier source)"
  else
    log "  using already-sourced lib-slack-post.sh"
    REPORT_DT="$REPORT_DATE $REPORT_TIME"
    THREADS_CSV_TXT=$(cat "$THREADS_CSV")
    JUDGMENT_TXT=$(cat "$JUDGMENT_FILE")
    # Derive the channel list from threads we have (col 1 of THREADS_CSV,
    # unique). Used by the per-thread reply filter — we only post into
    # channels we actually have threads in, never silently widen.
    POST_CHANNELS=$(awk -F'|' 'NF>=1 && $1 != "" {print $1}' "$THREADS_CSV" | sort -u | tr '\n' ' ')
    # Step A: daily anchor → ONE channel only (default #ai-general =
    # C0AJQ5M0A0Y). This replaces the prior 3-channel leak where the same
    # ":clipboard: Slack thread roadmap" digest was posted at channel root
    # in every channel with active threads.
    ANCHOR_TARGET="${DAILY_ANCHOR_CHANNEL:-C0AJQ5M0A0Y}"
    log "  posting daily anchor to: $ANCHOR_TARGET"
    if slack_post_daily_anchor "$ANCHOR_TARGET" "$REPORT_URL" "$REPORT_DT" "$JUDGMENT_TXT" "$THREADS_CSV_TXT" >> "$LOG_FILE" 2>&1; then
      log "  daily anchor posted"
    else
      err "  daily anchor post failed (continuing; per-thread replies still attempted)"
    fi
    # Step B: per-thread REPLIES (threaded under the originating thread_ts,
    # never at channel root). Threads within DAILY_ANCHOR_GRACE_MIN
    # (default 60) are skipped — the daily anchor above already lists them
    # to avoid double-coverage on the first-of-day tick.
    # shellcheck disable=SC2086
    if slack_post_per_thread_summary "$POST_CHANNELS" "$REPORT_URL" "$REPORT_DT" "$JUDGMENT_TXT" "$THREADS_CSV_TXT" >> "$LOG_FILE" 2>&1; then
      log "  per-thread replies posted"
    else
      err "  per-thread reply post failed (continuing; report is committed)"
    fi
  fi
else
  log "  no threads to post (THREADS_CSV empty or missing)"
fi

log "=== done ==="
