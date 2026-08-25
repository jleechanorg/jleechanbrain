#!/bin/bash
# wiki-campaign-daily-ingest.sh — Daily ingest of WA campaigns (ALL real users)
# into the LLM wiki (private repo: jleechanorg/llm-wiki).
#
# Scans WorldArchitect.AI Firestore for every real user's campaigns with
# >=50 scenes, ingests any new ones, and refreshes any existing wiki source
# pages that are missing the latest scenes. Test-user emails (containing
# "test", "anon", "dev-runner", "example.com", "jleechantest") are skipped.
# jleechan@gmail.com is INCLUDED by default.
#
# Schedule: launchd plist at ai.jleechan.wiki-campaign-daily-ingest.plist
#
# Required env (provided by plist via launchd-env-wrapper or direct export):
#   GOOGLE_APPLICATION_CREDENTIALS = ~/serviceAccountKey.json
#   WORLDAI_DEV_MODE = true
#
# Output:
#   - Wiki pages added/updated at ~/llm_wiki/wiki/sources/<slug>-<id8>.md
#     (each page's frontmatter carries user_email + user_uid for auditability)
#   - Raw archives at ~/llm_wiki/raw/campaigns/<id>/<title>_<id8>.{txt,_game_state.json}
#   - Git commit + push to https://github.com/jleechanorg/llm-wiki.git
#   - Log: ~/Library/Logs/wiki-campaign-daily-ingest.log
#   - Manifest: /tmp/campaign_ingest_manifest.jsonl
#   - Daily Gmail summary to jleechan@gmail.com
#   - Daily Slack message to #ai-general (C0AJQ5M0A0Y) via mcp_agent_mail bot
#
# Notifications:
#   On success: Gmail + Slack post with download/skip counts, push SHA, sample
#               campaigns added.
#   On error:   Gmail + Slack with the failure summary and a pointer to the log.

set -u

WIKI_DIR="${WIKI_DIR:-$HOME/llm_wiki}"
WORLDAI_REPO="${WORLDAI_REPO:-$HOME/worldarchitect.ai}"
PYTHON="${PYTHON:-$WORLDAI_REPO/.venv/bin/python}"
SCRIPT="${SCRIPT:-$HOME/.smartclaw/skills/download-campaign/scripts/download_campaign.py}"
LOG="${LOG:-$HOME/Library/Logs/wiki-campaign-daily-ingest.log}"
MANIFEST="${MANIFEST:-/tmp/campaign_ingest_manifest.jsonl}"
DAILY_RAW="${DAILY_RAW:-/tmp/campaign_daily_ingest}"
SKIP_DOWNLOAD="${SKIP_DOWNLOAD:-0}"

# Notification config
GMAIL_TO="${GMAIL_TO:-jleechan@gmail.com}"
GMAIL_ACCOUNT="${GMAIL_ACCOUNT:-jleechan@gmail.com}"
# Default to #ai-general (C0AJQ5M0A0Y) — the canonical home channel per
# SOUL.md `slack-channel-routing-policy`. The mcp_agent_mail bot IS in this
# channel (re-invited 2026-07-14) so we no longer need the #life fallback.
# Override with SLACK_CHANNEL=... to post elsewhere if needed.
# See ~/.claude/skills/slack-mcp-mail-bot-reinstall/SKILL.md §6 to re-add
# the bot to any other channel.
SLACK_CHANNEL="${SLACK_CHANNEL:-C0AJQ5M0A0Y}"
# Operator (Jeffrey) + Hermes bot user IDs. notify_error() prepends these
# so failure alerts ping both the operator and the Hermes Slack app.
# Per USER_PROFILE: tag ONLY on failure paths, not on success/probe paths.
SLACK_OPERATOR_ID="U09GH5BR3QU"
SLACK_HERMES_BOT_ID="U0AEZC7RX1Q"
LIB_SLACK_POST="$HOME/.smartclaw/scripts/lib-slack-post.sh"
OUTBOUND_SECRET_GATE="$HOME/.smartclaw/lib/outbound_secret_gate.py"

# Threshold — only meaningful campaigns (>=50 scenes)
MIN_ENTRIES=50

# Track run outcome for the trap-based error notifier
RUN_STATUS="unknown"
LAST_ERROR=""
INGEST_DOWNLOADED=0
INGEST_SKIPPED=0
INGEST_ERRORS=0
INGEST_USERS_SCANNED=0
PUSH_SHA=""
PUSH_BEFORE_SHA=""

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"
}

# notify <subject> <slack_text> [gmail_body] [gmail_body_file]
# Sends to both Slack and Gmail. Best-effort — log on failure but never
# cause the script to exit non-zero just because notification delivery
# itself failed (avoids loop where broken notifier turns a green run red).
notify() {
    local subject="$1"
    local slack_text="$2"
    local gmail_body="${3:-$slack_text}"
    local gmail_body_file="${4:-}"

    # Slack — via the shared helper, posts as the mcp_agent_mail bot
    # (U0A4G7LDJ4R / app A0A3WSV6BM1). Helper handles token resolution,
    # mcp_agent_mail wrapper fallback, and the outbound-secret gate.
    if [[ -x "$LIB_SLACK_POST" ]] || [[ -r "$LIB_SLACK_POST" ]]; then
        # shellcheck source=/dev/null
        source "$LIB_SLACK_POST"
        # Capture stdout/stderr to log WITHOUT eating the function's return code
        # — `... | tee` makes the pipeline status be tee's, not slack_post_message's.
        local slack_output
        slack_output=$(slack_post_message "$SLACK_CHANNEL" "$slack_text" 2>&1)
        local slack_rc=$?
        echo "$slack_output" | tee -a "$LOG" >/dev/null
        if [[ $slack_rc -eq 0 ]]; then
            log "Slack notification sent (channel $SLACK_CHANNEL)"
        else
            log "WARN: Slack notification failed (rc=$slack_rc) — see $LOG"
        fi
    else
        log "WARN: $LIB_SLACK_POST not found — skipping Slack notification"
    fi

    # Gmail — via gog. Send as jleechan@gmail.com (the same address as the
    # recipient so the daily recap lands in the user's primary inbox tab).
    if ! command -v gog >/dev/null 2>&1; then
        log "WARN: 'gog' CLI not found in PATH — skipping Gmail notification"
        return 0
    fi

    if ! printf '%s' "$subject" | python3 "$OUTBOUND_SECRET_GATE" check; then
        log "WARN: Gmail notification blocked by outbound secret gate"
        return 0
    fi

    local body_arg=()
    if [[ -n "$gmail_body_file" ]]; then
        local gmail_body_with_sentinel
        local gmail_body_snapshot
        if ! gmail_body_with_sentinel="$(
            python3 "$OUTBOUND_SECRET_GATE" check --file "$gmail_body_file" --emit-clean \
                && printf '\034'
        )"; then
            log "WARN: Gmail notification blocked by outbound secret gate"
            return 0
        fi
        gmail_body_snapshot="${gmail_body_with_sentinel%$'\034'}"
        body_arg=(--body "$gmail_body_snapshot")
    else
        if ! printf '%s' "$gmail_body" | python3 "$OUTBOUND_SECRET_GATE" check; then
            log "WARN: Gmail notification blocked by outbound secret gate"
            return 0
        fi
        body_arg=(--body "$gmail_body")
    fi

    if gog gmail send \
        --account "$GMAIL_ACCOUNT" \
        --to "$GMAIL_TO" \
        --subject "$subject" \
        --no-input \
        "${body_arg[@]}" >/dev/null 2>&1; then
        log "Gmail notification sent (to $GMAIL_TO, subject: $subject)"
    else
        log "WARN: Gmail notification failed — see $LOG"
    fi
    return 0
}

# Send an error notification. Called via trap on any non-zero exit so that
# even if the script bombs early, Jeffrey gets paged.
notify_error() {
    local err_msg="$1"
    local subject="[Hermes] wiki-campaign-daily-ingest FAILED — $(date '+%Y-%m-%d')"

    # Build the Slack message body via heredoc to avoid bash quoting issues
    # with markdown that contains parentheses.
    # Pin the operator + Hermes bot tags so the alert pings BOTH accounts
    # (USER_PROFILE: tag-only-on-failure-paths is a hard rule; this is the
    # single sanctioned failure-path alert site for this script).
    local slack_text
    slack_text=$(cat <<EOF
:red_circle: *wiki-campaign-daily-ingest — FAILED*
<@${SLACK_OPERATOR_ID}> <@${SLACK_HERMES_BOT_ID}>
${err_msg}

*Last log tail:* (see \`$LOG\` for full)
\`\`\`
$(tail -8 "$LOG" 2>/dev/null | sed 's/^/  /')
\`\`\`
*Run started:* ${RUN_START_DATE:-unknown}
*Wiki dir:* $WIKI_DIR
*Recourse:* \`bash $HOME/.smartclaw/scripts/wiki-campaign-daily-ingest.sh\` to retry manually.
EOF
)

    # Build the Gmail body so the error arrives even if the log was rotated.
    local gmail_body
    gmail_body=$(cat <<EOF
wiki-campaign-daily-ingest FAILED at $(date '+%Y-%m-%d %H:%M:%S')

${err_msg}

Last log lines:
$(tail -8 "$LOG" 2>/dev/null)

Run started: ${RUN_START_DATE:-unknown}
Wiki dir:    $WIKI_DIR

To retry manually:
  bash $HOME/.smartclaw/scripts/wiki-campaign-daily-ingest.sh
EOF
)
    notify "$subject" "$slack_text" "$gmail_body"
}

# Build the daily-success body (gmail + slack share the same content shape).
build_success_summary() {
    local subject="[Hermes] wiki-campaign-daily-ingest — $(date '+%Y-%m-%d')"
    local status_line
    if [[ "$ADDED" -gt 0 || "$MODIFIED" -gt 0 ]]; then
        status_line=":white_check_mark: Pushed commit \`${PUSH_SHA:0:7}\` → \`${PUSH_BEFORE_SHA:0:7}\` on \`jleechanorg/llm-wiki\`"
    else
        status_line=":zzz: No changes — wiki already up to date"
    fi

    local slack_text
    slack_text=$(cat <<EOF
:clipboard: *wiki-campaign-daily-ingest — $(date '+%Y-%m-%d')*
${status_line}

*Users scanned:* ${INGEST_USERS_SCANNED}
*Campaigns downloaded (new):* ${INGEST_DOWNLOADED}
*Campaigns skipped (existing):* ${INGEST_SKIPPED}
*Campaigns errored:* ${INGEST_ERRORS}
*Wiki files added:* ${ADDED}
*Wiki files modified:* ${MODIFIED}
*Threshold:* \`>=${MIN_ENTRIES} scenes\`
*Repo:* \`jleechanorg/llm-wiki\` (private)
*Source:* WorldArchitect.AI Firestore (all real users, test users filtered)
EOF
)

    # Sample new campaign titles (up to 5) so the summary is scannable.
    if [[ -s "$MANIFEST" ]] && [[ "$INGEST_DOWNLOADED" -gt 0 ]]; then
        local sample
        sample=$(grep -F "$RUN_START_DATE" "$MANIFEST" 2>/dev/null \
                 | tail -5 \
                 | python3 -c '
import json, sys
for line in sys.stdin:
    try:
        d = json.loads(line)
        title = d.get("title", "?")[:60]
        uid = d.get("user_email", "?")
        n = d.get("entry_count", "?")
        print(f"  - _{title}_ ({uid}, {n} scenes)")
    except Exception:
        pass
' 2>/dev/null)
        if [[ -n "$sample" ]]; then
            slack_text="${slack_text}
*Sample new campaigns:*
${sample}"
        fi
    fi

    local gmail_body
    gmail_body=$(cat <<EOF
wiki-campaign-daily-ingest — $(date '+%Y-%m-%d')

${status_line//\`/}

Users scanned:                ${INGEST_USERS_SCANNED}
Campaigns downloaded (new):   ${INGEST_DOWNLOADED}
Campaigns skipped (existing): ${INGEST_SKIPPED}
Campaigns errored:            ${INGEST_ERRORS}
Wiki files added:             ${ADDED}
Wiki files modified:          ${MODIFIED}
Threshold:                    >=${MIN_ENTRIES} scenes
Repo:                         jleechanorg/llm-wiki (private)
Source:                       WorldArchitect.AI Firestore (all real users, test users filtered)

Run started: ${RUN_START_DATE:-unknown}
Full log:    ${LOG}
EOF
)
    notify "$subject" "$slack_text" "$gmail_body"
}

# Trap ALL error paths so the error notifier fires on early failures too.
on_error() {
    local exit_code=$?
    local line=${BASH_LINENO[0]}
    LAST_ERROR="exit ${exit_code} at line ${line}"
    RUN_STATUS="error"
    log "TRAP: $LAST_ERROR"
    notify_error "$LAST_ERROR" 2>&1 | tee -a "$LOG" || true
    exit $exit_code
}
trap 'on_error' ERR
trap 'on_error' INT TERM

# Ensure log dir exists
mkdir -p "$(dirname "$LOG")"
mkdir -p "$DAILY_RAW"

log "=== Wiki Campaign Daily Ingest Starting ==="
log "Wiki dir: $WIKI_DIR"
log "WA repo:  $WORLDAI_REPO"
log "Min entries: $MIN_ENTRIES"

# Marker file — set mtime to NOW so we can later find files added during this
# run. Created BEFORE the ingest so any file written during the ingest is
# strictly newer than this timestamp. Cleaned up after the run.
RUN_START_MARKER="/tmp/wiki_campaign_ingest_run_marker"
touch "$RUN_START_MARKER"
# Store both mtime epoch (BSD find on macOS does not support -newermt @<epoch>)
# and a human-readable date string for find's -newermt.
RUN_START_TIME=$(stat -f %m "$RUN_START_MARKER")
RUN_START_DATE=$(date -r "$RUN_START_TIME" '+%Y-%m-%d %H:%M:%S')

# Venv preflight — catches a broken/missing $PYTHON (e.g. a dangling
# symlink, a deleted Homebrew python, a half-initialized venv) BEFORE
# bash tries to exec it. The trap on ERR only fires on a failing
# COMMAND; running a nonexistent binary aborts with exit 127 BEFORE the
# trap sees it, so the operator gets no Slack ping. This block both
# (a) auto-recovers a stale but recoverable venv (symlink target still
#     exists at the original path or is reachable via `which python3.x`)
#     and (b) fires notify_error() with a clear diagnostic + remediation
#     when the venv is genuinely unrecoverable.
log "Venv preflight: $PYTHON"
if [[ -L "$PYTHON" ]]; then
    # Symlink case (this repo's .venv/bin/python is a symlink).
    # `readlink -f` resolves through missing hops and reports nothing,
    # so we have to test the target path separately.
    py_target=$(readlink "$PYTHON" 2>/dev/null || echo "")
    if [[ -z "$py_target" ]] || [[ ! -e "$py_target" ]]; then
        log "WARN: venv python symlink target '$py_target' is missing — attempting repair"
        # Try to recreate from the most likely Homebrew/conda/system python
        # that the original symlink pointed at. If `basename` had a version
        # suffix (python3.12), use it; else default to system python3.
        py_basename=$(basename "$py_target")
        candidate=$(command -v "$py_basename" 2>/dev/null || command -v python3 2>/dev/null || echo "")
        if [[ -n "$candidate" ]] && [[ -e "$candidate" ]]; then
            ln -sf "$candidate" "$PYTHON" && log "Relinked $PYTHON -> $candidate"
        else
            LAST_ERROR="venv python symlink broken: $PYTHON -> '$py_target' (target missing and no candidate python found)"
            RUN_STATUS="error"
            log "ERROR: $LAST_ERROR"
            notify_error "$LAST_ERROR" 2>&1 | tee -a "$LOG" || true
            exit 127
        fi
    fi
elif [[ ! -x "$PYTHON" ]]; then
    # Direct path case (not a symlink, or no python at all).
    # Try to bootstrap from scratch — recreate .venv at $WORLDAI_REPO/.venv
    # using the system python, then verify the expected modules import.
    if [[ ! -d "$WORLDAI_REPO/.venv" ]] && command -v python3 >/dev/null 2>&1; then
        log "WARN: no venv at $WORLDAI_REPO/.venv — bootstrapping (one-time)"
        if command -v uv >/dev/null 2>&1; then
            (cd "$WORLDAI_REPO" && uv venv --python 3.12 .venv 2>&1 | tail -3) | tee -a "$LOG" || true
        else
            (cd "$WORLDAI_REPO" && python3 -m venv .venv 2>&1 | tail -3) | tee -a "$LOG" || true
        fi
    fi
    if [[ ! -x "$PYTHON" ]]; then
        LAST_ERROR="venv python missing or not executable: $PYTHON — recreate with 'python3 -m venv $WORLDAI_REPO/.venv' or relink to a system python"
        RUN_STATUS="error"
        log "ERROR: $LAST_ERROR"
        notify_error "$LAST_ERROR" 2>&1 | tee -a "$LOG" || true
        exit 127
    fi
fi

# Venv dep check (one-time bootstrap if missing)
if ! "$PYTHON" -c "import firebase_admin, firestore_service, document_generator" 2>/dev/null; then
    log "Bootstrap: installing WA .venv dependencies (one-time)"
    cd "$WORLDAI_REPO" || { log "ERROR: cannot cd to $WORLDAI_REPO"; exit 1; }
    "$PYTHON" -m ensurepip >/dev/null 2>&1 || true
    "$PYTHON" -m pip install -q firebase-admin google-cloud-firestore flask pydantic jsonschema python-docx fpdf2 2>&1 | tail -3
fi

# Clear stale credential paths and set the correct one
unset GOOGLE_APPLICATION_CREDENTIALS WORLDAI_GOOGLE_APPLICATION_CREDENTIALS
export GOOGLE_APPLICATION_CREDENTIALS="$HOME/serviceAccountKey.json"
export WORLDAI_DEV_MODE=true

cd "$WORLDAI_REPO" || { log "ERROR: cannot cd to $WORLDAI_REPO"; exit 1; }

# Run all-users batch ingest (downloads new + refreshes stale since --skip-existing
# only skips when wiki page is > 500 bytes; missing scenes are detected via
# entry_count comparison and re-download overwrites). Test users are filtered
# out by download_campaign.py's is_test_email() helper.
if [[ "$SKIP_DOWNLOAD" != "1" ]]; then
    log "Running all-users batch ingest (min-entries=$MIN_ENTRIES, --skip-existing)..."
    # Capture the human-readable summary lines (Downloaded/Skipped/Errors/Manifest
    # header + the per-user Found-N-candidates lines) so we can pull the counters
    # into the daily notification body.
    INGEST_OUT=$(mktemp)
    "$PYTHON" "$SCRIPT" \
        --mode all-users \
        --min-entries "$MIN_ENTRIES" \
        --skip-existing \
        --campaigns-dir "$DAILY_RAW" 2>&1 | tee -a "$LOG" "$INGEST_OUT" >/dev/null || true

    INGEST_EXIT=${PIPESTATUS[0]}
    if [ $INGEST_EXIT -ne 0 ]; then
        rm -f "$INGEST_OUT"
        log "ERROR: batch ingest exited with status $INGEST_EXIT"
        # Trigger ERR trap (we bypassed it via `|| true` to capture output).
        set +u
        LAST_ERROR="batch ingest exited with status $INGEST_EXIT"
        RUN_STATUS="error"
        notify_error "$LAST_ERROR" 2>&1 | tee -a "$LOG" || true
        set -u
        exit $INGEST_EXIT
    fi

    # Parse ingest counters from the captured output
    INGEST_DOWNLOADED=$(grep -E "^Downloaded:" "$INGEST_OUT" 2>/dev/null | tail -1 | awk '{print $2}' | tr -d ' ' || echo 0)
    INGEST_SKIPPED=$(grep -E "^Skipped:" "$INGEST_OUT" 2>/dev/null | tail -1 | awk '{print $2}' | tr -d ' ' || echo 0)
    INGEST_ERRORS=$(grep -E "^Errors:" "$INGEST_OUT" 2>/dev/null | tail -1 | awk '{print $2}' | tr -d ' ' || echo 0)
    INGEST_USERS_SCANNED=$(grep -E "^=== Done" "$INGEST_OUT" 2>/dev/null | tail -1 | sed -E 's/.*\[([0-9]+)\/([0-9]+)\].*/\2/' || echo 0)
    # Numeric safety: drop non-digits and default empty/non-numeric to 0
    for v in INGEST_DOWNLOADED INGEST_SKIPPED INGEST_ERRORS INGEST_USERS_SCANNED; do
        eval "val=\${$v}"
        val=$(printf '%s' "$val" | tr -cd '0-9')
        if [[ -z "$val" ]]; then val=0; fi
        eval "$v=$val"
    done
    rm -f "$INGEST_OUT"

    log "Batch ingest complete"
    log "  Downloaded=$INGEST_DOWNLOADED Skipped=$INGEST_SKIPPED Errors=$INGEST_ERRORS Users=$INGEST_USERS_SCANNED"
else
    log "SKIP_DOWNLOAD=1 — skipping Firestore batch download"
fi

# Stage all new, modified, and deleted repository files (respecting .gitignore)
log "Staging repository changes in $WIKI_DIR..."
cd "$WIKI_DIR" || { log "ERROR: cannot cd to $WIKI_DIR"; exit 1; }
git add -A 2>/dev/null || true

# Check if there's anything staged
if git diff --cached --quiet; then
    log "Nothing staged — no commit needed"
    RUN_STATUS="no-op"
    build_success_summary 2>&1 | tee -a "$LOG" || true
    rm -f "$RUN_START_MARKER" 2>/dev/null || true
    log "=== Wiki Campaign Daily Ingest Complete (no-op) ==="
    exit 0
fi

# Count what changed from the staged index
ADDED=$(git diff --cached --name-only --diff-filter=A 2>/dev/null | wc -l | tr -d ' ')
MODIFIED=$(git diff --cached --name-only --diff-filter=M 2>/dev/null | wc -l | tr -d ' ')
log "Files staged: added=$ADDED modified=$MODIFIED"

# Capture pre-push HEAD so we can show the SHA delta in the summary.
PUSH_BEFORE_SHA=$(git rev-parse origin/main 2>/dev/null || git rev-parse HEAD)

# Commit
COMMIT_MSG="wiki-ingest(daily): all real-user campaigns >=${MIN_ENTRIES} scenes — $(date '+%Y-%m-%d')

Daily cron job (wiki-campaign-daily-ingest.sh) batch-ingested new
campaigns and refreshed stale ones from WorldArchitect.AI Firestore
for every real user (test-user emails filtered out; jleechan included).

  Threshold: ${MIN_ENTRIES}+ scenes
  Scope:     all real users (auth.list_users, exclude test fixtures)
  Manifest:  ${MANIFEST}
  Raw:       ${DAILY_RAW}

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>"

git commit -m "$COMMIT_MSG" 2>&1 | tee -a "$LOG" | tail -5

# Push
log "Pushing to origin/main..."
if git push origin main 2>&1 | tee -a "$LOG" | tail -5; then
    PUSH_SHA=$(git rev-parse HEAD)
    log "Push successful: ${PUSH_BEFORE_SHA:0:7} -> ${PUSH_SHA:0:7}"
    RUN_STATUS="pushed"
    build_success_summary 2>&1 | tee -a "$LOG" || true
    rm -f "$RUN_START_MARKER" 2>/dev/null || true
    log "=== Wiki Campaign Daily Ingest Complete (pushed) ==="
    exit 0
else
    log "ERROR: git push failed — see log"
    RUN_STATUS="error"
    notify_error "git push failed (origin/main). Local commit created but not pushed. See $LOG." 2>&1 | tee -a "$LOG" || true
    rm -f "$RUN_START_MARKER" 2>/dev/null || true
    exit 1
fi
