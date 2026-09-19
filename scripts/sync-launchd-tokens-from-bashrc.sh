#!/bin/bash
# sync-launchd-tokens-from-bashrc.sh
#
# Re-substitutes @SLACK_BOT_TOKEN@ (and other token-ish placeholders)
# in tracked plist templates into ~/Library/LaunchAgents/<label>.plist whenever
# the bashrc token diverges from the baked-in token.
#
# Why this exists:
#   `install-hermes-scheduled-jobs.sh` substitutes @SLACK_BOT_TOKEN@
#   from $SLACK_BOT_TOKEN (or $SLACK_BOT_TOKEN) at install time. The
#   result is then baked into ~/Library/LaunchAgents/<label>.plist. If the
#   token in ~/.bashrc later rotates (Slack OAuth refresh, manual revoke +
#   re-issue, or a different env layering), every plist that was installed
#   before the rotation keeps the OLD token. launchd does NOT re-read
#   .bashrc. The result is silent `invalid_auth` from every scheduled job
#   that hits Slack — and the only visible symptom is "no alerts / no
#   nudges", with no error surfacing anywhere the operator will look.
#
#   Verified 2026-08-04: 5 launchd jobs (dropped-thread-followup,
#   finish-the-job-autoarm, ms-proactive-firing-audit, ao-progress-reporter,
#   auto-resolve-easy-prs) were all silently broken for ~weeks because the
#   bashrc token was rotated but the plists were not. dropped-thread-followup
#   logged "Failed to fetch threads for $channel" every 30 min without ever
#   recovering a dropped message.
#
# What this script does:
#   1. Read current SLACK_BOT_TOKEN from ~/.bashrc (live source of truth).
#   2. For each plist template in launchd/ tracked by git:
#        a. If the corresponding ~/Library/LaunchAgents/<label>.plist doesn't
#           exist, skip (not installed yet — let install-hermes-scheduled-jobs.sh
#           handle).
#        b. If the installed plist's SLACK_BOT_TOKEN env var already
#           equals the bashrc token, skip (no drift).
#        c. Otherwise re-render the template using the SAME substitution
#           pipeline as install-hermes-scheduled-jobs.sh (line ~296), plutil
#           -lint the result, atomic mv into place, launchctl bootout +
#           bootstrap to re-exec.
#   3. Post a single Slack alert to HERMES_OPS_SLACK_CHANNEL if any drift was
#      corrected (rate-limited to 1 alert per 6h to avoid spam).
#
# Exit codes:
#   0 = no drift OR drift successfully corrected
#   1 = bashrc token not set OR all drift-correction attempts failed
#
# Idempotency: running twice in a row is safe; second run no-ops (drift
# already corrected).
#
# Tested manually on 2026-08-04 to recover all 5 broken jobs.

set -uo pipefail

HERMES_HOME="${HERMES_HOME:-$HOME/.smartclaw}"
LAUNCHD_DIR="$HOME/Library/LaunchAgents"
TEMPLATES_DIR="$HERMES_HOME/launchd"
STATE_FILE="$HERMES_HOME/logs/sync-launchd-tokens-state.json"
ALERT_COOLDOWN_SECS="${ALERT_COOLDOWN_SECS:-21600}"  # 6h
LOG_DIR="$HERMES_HOME/logs"
LOG_FILE="$LOG_DIR/sync-launchd-tokens.log"

mkdir -p "$LOG_DIR" "$(dirname "$STATE_FILE")"

log() { echo "[$(date -Iseconds)] $*" | tee -a "$LOG_FILE" >&2; }

# ── 1. Pull live token from bashrc ──────────────────────────────────────────
# Prefer the per-user ~/.bashrc; fall back to the original $HOME bashrc if
# HOME has been overridden (test/CI environments) so this script works under
# `env -i HOME=...` launchd-style invocations.
bashrc_path="$HOME/.bashrc"
[[ -f "$bashrc_path" ]] || bashrc_path="${REAL_HOME:-$HOME}/.bashrc"
bashrc_token=$(grep -m1 '^export SLACK_BOT_TOKEN=' "$bashrc_path" 2>/dev/null \
               | sed -E 's/^export SLACK_BOT_TOKEN=//; s/^"//; s/"$//' \
               | tr -d '\n' || true)
if [[ -z "$bashrc_token" ]]; then
  log "ERROR: SLACK_BOT_TOKEN not set in ~/.bashrc; aborting"
  exit 1
fi
if [[ ! "$bashrc_token" =~ ^xoxb- ]]; then
  log "ERROR: bashrc token doesn't look like an xoxb- token (prefix=${bashrc_token:0:5}); aborting"
  exit 1
fi

# ── 2. Iterate plist templates ──────────────────────────────────────────────
drift_count=0
corrected=()
failed=()

shopt -s nullglob
for src in "$TEMPLATES_DIR"/ai.smartclaw.*.plist "$TEMPLATES_DIR"/ai.smartclaw.*.plist.template; do
  # Derive label (the basename without .plist.template or .plist)
  base=$(basename "$src")
  if [[ "$base" == *.plist.template ]]; then
    label="${base%.plist.template}"
  else
    label="${base%.plist}"
  fi

  dst="$LAUNCHD_DIR/$label.plist"
  [[ -f "$dst" ]] || continue   # not installed; let install-hermes-scheduled-jobs.sh handle

  # If the source template never bakes a static Slack bot token at all (e.g.
  # ai.smartclaw.prod pulls SLACK_BOT_TOKEN/SLACK_BOT_TOKEN fresh from
  # ~/.bashrc at process launch via launchd-env-wrapper.sh — see
  # scripts/launchd-env-wrapper.sh), there is nothing to sync. Comparing an
  # always-empty "baked" value against bashrc_token produced a false
  # "drift detected" on EVERY run for such labels, silently rebooting
  # ai.smartclaw.prod roughly every 30-40 minutes forever — this was the real
  # root cause of the 2026-08-04 prod outage(s), not a one-off race.
  if ! grep -q '@SLACK_BOT_TOKEN@' "$src" 2>/dev/null; then
    continue
  fi

  # Read current baked-in token via plutil (binary or XML-safe)
  baked=$(plutil -extract EnvironmentVariables.SLACK_BOT_TOKEN raw "$dst" 2>/dev/null || echo "")
  if [[ -z "$baked" ]]; then
    # Older plist may have it as a top-level EnvironmentVariables string — try XML parse
    baked=$(python3 -c "
import plistlib, sys
try:
    with open('$dst','rb') as f:
        d = plistlib.load(f)
    print(d.get('EnvironmentVariables',{}).get('SLACK_BOT_TOKEN',''))
except Exception:
    sys.exit(0)
" 2>/dev/null)
  fi

  if [[ "$baked" == "$bashrc_token" ]]; then
    continue   # no drift
  fi

  # Drift detected — re-render
  log "drift detected: $label  baked=${baked:0:5}...  bashrc=${bashrc_token:0:5}..."

  tmp=$(mktemp "$LAUNCHD_DIR/.${label}.XXXXXX.plist")
  if ! sed \
      -e "s|@HOME@|$HOME|g" \
      -e "s|@SLACK_BOT_TOKEN@|$bashrc_token|g" \
      -e "s|@OPENCLAW_SLACK_BOT_TOKEN@|${OPENCLAW_SLACK_BOT_TOKEN:-${SLACK_BOT_TOKEN:-}}|g" \
      -e "s|@SLACK_USER_TOKEN@|${SLACK_USER_TOKEN:-}|g" \
      "$src" > "$tmp"; then
    rm -f "$tmp"
    failed+=("$label (sed failed)")
    continue
  fi

  # plutil -lint BEFORE touching the live plist (matches install-hermes-scheduled-jobs.sh guard)
  if ! plutil -lint "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    failed+=("$label (plutil -lint failed)")
    continue
  fi

  # Backup + atomic replace + launchctl re-register (only if launchd is reachable)
  cp "$dst" "$dst.bak.$(date +%s)"
  mv "$tmp" "$dst"
  uid=$(id -u)
  domain_target="gui/${uid}/$label"

  # bootout is best-effort: a not-yet-loaded service returns non-zero, which
  # must NOT skip bootstrap — root cause of the 2026-08-04 ai.smartclaw.prod
  # outage was this exact "if bootout succeeds then bootstrap" gating: bootout
  # succeeded, bootstrap silently failed under load (41 plists rebooted in
  # ~14s), and the label was still recorded as corrected because the
  # bootstrap exit code was masked by `2>/dev/null` inside an `if` that never
  # ran when bootout itself failed. Always attempt bootstrap regardless.
  launchctl bootout "$domain_target" 2>/dev/null
  sleep 0.5
  launchctl bootstrap "gui/${uid}" "$dst" 2>/dev/null

  # bootstrap can return 0 even when the job immediately fails, and under
  # load bootstrap has been observed to silently no-op. Verify the service
  # actually re-registered before declaring success — poll with retries
  # instead of trusting the exit code alone.
  verified=0
  for attempt in 1 2 3; do
    if launchctl print "$domain_target" >/dev/null 2>&1; then
      verified=1
      break
    fi
    sleep 1
  done

  if [[ $verified -eq 1 ]]; then
    corrected+=("$label")
    drift_count=$((drift_count + 1))
  else
    # launchctl can also be genuinely unreachable in test/CI sandboxes (no
    # GUI session) — but that means `launchctl print` fails for EVERY label,
    # not just one. A single-label verification failure with launchd
    # otherwise reachable is a real outage and must be reported as failed
    # (drives exit code 1 + Slack alert), not silently downgraded.
    failed+=("$label (bootstrap unverified: launchctl print found no registered service after 3 retries)")
  fi
done

# ── 3. Post Slack alert (rate-limited) ──────────────────────────────────────
post_alert() {
  local msg=":*sync-launchd-tokens* drift-corrected: ${corrected[*]:-(none)}; failed: ${failed[*]:-(none)}"
  local token="$bashrc_token"
  local channel="${HERMES_OPS_SLACK_CHANNEL:-${HERMES_OPS_CHANNEL:-}}"
  [[ -z "$channel" ]] && return 0  # no alert channel configured → silent no-op
  local now=$(date +%s)
  local last=0
  [[ -f "$STATE_FILE" ]] && last=$(python3 -c "
import json, sys
try:
    with open('$STATE_FILE') as f:
        d = json.load(f)
    print(d.get('last_alert_ts', 0))
except Exception:
    print(0)
" 2>/dev/null || echo 0)
  if (( now - last < ALERT_COOLDOWN_SECS )); then
    log "alert suppressed (cooldown): last=$last now=$now"
    return 0
  fi
  local payload
  payload=$(python3 -c "
import json
print(json.dumps({'channel': '$channel', 'text': '''$msg'''}))
")
  curl --silent --show-error --connect-timeout 5 --max-time 15 \
    -X POST "https://slack.com/api/chat.postMessage" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "$payload" >/dev/null 2>&1 || true
  python3 -c "
import json
with open('$STATE_FILE','w') as f:
    json.dump({'last_alert_ts': $now, 'last_corrected': '''${corrected[*]:-(none)}'''}, f)
"
}

if (( drift_count > 0 )) || (( ${#failed[@]} > 0 )); then
  log "summary: corrected=${#corrected[@]}  failed=${#failed[@]}"
  post_alert || true
fi

# ── 4. Final exit code ──────────────────────────────────────────────────────
if (( ${#failed[@]} > 0 )); then
  exit 1
fi
exit 0