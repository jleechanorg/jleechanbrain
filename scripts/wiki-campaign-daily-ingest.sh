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
DAILY_RAW="${DAILY_RAW:-$WIKI_DIR/raw/campaigns}"
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
MANIFEST_LINE_COUNT_BEFORE=0
# Initialize file-change counters early so build_success_summary() can run
# in the no-op branch (called at line 434 before ADDED/MODIFIED get assigned
# at lines 441-442). Without this, `set -u` triggers ADDED: unbound variable
# on quiet days and the daily Gmail/Slack notification never goes out —
# leaving the operator without visibility into no-op runs (the 2026-09-13
# incident: "Make sure the export for campaigns to LLM wiki repo is working
# think it's a launchd haven't seen the email in awhile").
ADDED=0
MODIFIED=0
# Campaign-level breakdown — distinct from file-level ADDED/MODIFIED.
# ADDED counts every staged file (wiki sources + raw archives), but the
# operator only cares about *campaigns*: NEW_CAMPAIGNS = wiki sources that
# didn't exist before this run; REFRESHED_CAMPAIGNS = wiki sources that
# existed but were updated with new entries. (2026-09-13 request:
# "show how many campaigns are brand new and uploaded versus existing
# campaign with new entries".)
NEW_CAMPAIGNS=0
REFRESHED_CAMPAIGNS=0

log() {
    local line="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$line" >> "$LOG"
    [[ -t 1 ]] && echo "$line"
    return 0
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
*Brand-new campaigns uploaded today:* ${NEW_CAMPAIGNS}
*Existing campaigns refreshed with new entries:* ${REFRESHED_CAMPAIGNS}
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
        sample=$(tail -n +"$((MANIFEST_LINE_COUNT_BEFORE + 1))" "$MANIFEST" 2>/dev/null \
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
Brand-new campaigns uploaded: ${NEW_CAMPAIGNS}
Existing campaigns refreshed: ${REFRESHED_CAMPAIGNS}
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

# Automated wiki index and log updater:
# Appends/updates newly downloaded campaigns in $WIKI_DIR/wiki/index.md under
# ## Campaigns (batch ingest) and records them in $WIKI_DIR/wiki/log.md.
update_wiki_index_and_log() {
    log "Running automated wiki index updater..."
    "$PYTHON" - "$WIKI_DIR" "$MANIFEST" "$MANIFEST_LINE_COUNT_BEFORE" "$RUN_START_MARKER" << 'PYEOF'
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

wiki_dir = Path(sys.argv[1])
manifest_path = Path(sys.argv[2])
manifest_lines_before = int(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[3].isdigit() else 0
run_start_marker = Path(sys.argv[4]) if len(sys.argv) > 4 and sys.argv[4] else None

index_file = wiki_dir / "wiki" / "index.md"
log_file = wiki_dir / "wiki" / "log.md"

new_campaigns = []
if manifest_path.exists():
    with open(manifest_path, "r", encoding="utf-8", errors="replace") as f:
        all_lines = f.readlines()
    new_lines = all_lines[manifest_lines_before:]
    for line in new_lines:
        line = line.strip()
        if not line:
            continue
        try:
            data = json.loads(line)
            new_campaigns.append(data)
        except Exception:
            pass

# Fallback: scan wiki/sources for files newer than run start marker
if not new_campaigns and run_start_marker and run_start_marker.exists():
    marker_mtime = run_start_marker.stat().st_mtime
    sources_dir = wiki_dir / "wiki" / "sources"
    if sources_dir.exists():
        for mf in sources_dir.glob("*.md"):
            if mf.stat().st_mtime >= marker_mtime:
                try:
                    text = mf.read_text(encoding="utf-8", errors="replace")
                    if text.startswith("---\n"):
                        end = text.find("\n---\n", 4)
                        if end != -1:
                            fm = text[4:end]
                            title_m = re.search(r'^title:\s*"(.*)"\s*$', fm, re.MULTILINE)
                            cid_m = re.search(r'^campaign_id:\s*([A-Za-z0-9]+)\s*$', fm, re.MULTILINE)
                            ec_m = re.search(r'^entry_count:\s*(\d+)\s*$', fm, re.MULTILINE)
                            email_m = re.search(r'^user_email:\s*"(.*)"\s*$', fm, re.MULTILINE)
                            uid_m = re.search(r'^user_uid:\s*"(.*)"\s*$', fm, re.MULTILINE)
                            new_campaigns.append({
                                "title": title_m.group(1) if title_m else mf.stem,
                                "campaign_id": cid_m.group(1) if cid_m else "",
                                "entry_count": int(ec_m.group(1)) if ec_m else 0,
                                "user_email": email_m.group(1) if email_m else "",
                                "user_uid": uid_m.group(1) if uid_m else "",
                                "wiki_path": str(mf),
                                "raw_path": "",
                            })
                except Exception:
                    pass

if not new_campaigns:
    print("No new campaign records found for index/log update.")
    sys.exit(0)

# Update wiki/index.md
if index_file.exists():
    content = index_file.read_text(encoding="utf-8", errors="replace")
    lines = content.splitlines()

    target_section_idx = -1
    max_camps = -1
    for i, line in enumerate(lines):
        if line.strip() == "## Campaigns (batch ingest)":
            c = 0
            for j in range(i + 1, len(lines)):
                if lines[j].startswith("## "):
                    break
                if lines[j].strip().startswith("- [") and "sources/" in lines[j] and "entries" in lines[j]:
                    c += 1
            if c > max_camps:
                max_camps = c
                target_section_idx = i

    for camp in new_campaigns:
        title = camp.get("title") or "Untitled"
        wiki_path = camp.get("wiki_path") or ""
        wiki_filename = Path(wiki_path).name if wiki_path else ""
        if not wiki_filename:
            continue
        entry_count = camp.get("entry_count") or 0
        new_entry_line = f"- [{title}](sources/{wiki_filename}) — {entry_count} entries"

        existing_idx = -1
        if target_section_idx != -1:
            for j in range(target_section_idx + 1, len(lines)):
                if lines[j].startswith("## "):
                    break
                if f"sources/{wiki_filename}" in lines[j]:
                    existing_idx = j
                    break

        if existing_idx != -1:
            lines[existing_idx] = new_entry_line
            print(f"Updated index entry: {new_entry_line}")
        else:
            if target_section_idx != -1:
                last_camp_idx = target_section_idx
                insert_idx = -1
                for j in range(target_section_idx + 1, len(lines)):
                    if lines[j].startswith("## "):
                        break
                    m = re.search(r"-\s*\[.*?\]\(sources/.*?\)\s*—\s*(\d+)\s*entries", lines[j])
                    if m:
                        last_camp_idx = j
                        cur_count = int(m.group(1))
                        if insert_idx == -1 and entry_count >= cur_count:
                            insert_idx = j
                if insert_idx != -1:
                    lines.insert(insert_idx, new_entry_line)
                    print(f"Inserted into index at line {insert_idx+1}: {new_entry_line}")
                else:
                    lines.insert(last_camp_idx + 1, new_entry_line)
                    print(f"Appended to index at line {last_camp_idx+2}: {new_entry_line}")
            else:
                lines.append("")
                lines.append("## Campaigns (batch ingest)")
                target_section_idx = len(lines) - 1
                lines.append(new_entry_line)
                print(f"Created section and appended to index: {new_entry_line}")

    index_file.write_text("\n".join(lines) + "\n", encoding="utf-8")

# Update wiki/log.md
if log_file.exists():
    log_content = log_file.read_text(encoding="utf-8", errors="replace")
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    log_append_entries = []

    for camp in new_campaigns:
        title = camp.get("title") or "Untitled"
        cid = camp.get("campaign_id") or ""
        wiki_path = camp.get("wiki_path") or ""
        wiki_slug = Path(wiki_path).stem if wiki_path else cid
        entry_count = camp.get("entry_count") or 0
        email = camp.get("user_email") or ""
        uid = camp.get("user_uid") or ""

        if f"Source: [[{wiki_slug}]]" in log_content or (cid and f"campaign ID: {cid}" in log_content):
            print(f"Skipping log entry (already logged): {wiki_slug}")
            continue

        user_display = email.split("@")[0].capitalize() if email and "@" in email else (email or uid[:8] or "Unknown")
        user_info = f"{user_display} ({email}, UID: {uid}, campaign ID: {cid}, title: '{title}', {entry_count} scenes)" if email else f"UID: {uid}, campaign ID: {cid}, title: '{title}', {entry_count} scenes"

        entry_text = (
            f"\n## [{today}] ingest | {title} campaign ({user_display}, {entry_count} scenes)\n\n"
            f"Source: [[{wiki_slug}]]. Ingested campaign played by {user_info} into wiki source and raw archive.\n"
        )
        log_append_entries.append(entry_text)
        print(f"Added to log: {wiki_slug} ({title})")

    if log_append_entries:
        if not log_content.endswith("\n"):
            log_content += "\n"
        log_content += "".join(log_append_entries)
        log_file.write_text(log_content, encoding="utf-8")
PYEOF
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
if ! PYTHONPATH="$WORLDAI_REPO/mvp_site:$WORLDAI_REPO" "$PYTHON" -c "import firebase_admin, firestore_service, document_generator" 2>/dev/null; then
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
    MANIFEST_LINE_COUNT_BEFORE=0
    if [[ -f "$MANIFEST" ]]; then
        MANIFEST_LINE_COUNT_BEFORE=$(wc -l < "$MANIFEST" | tr -d ' ')
    fi

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

cd "$WIKI_DIR" || { log "ERROR: cannot cd to $WIKI_DIR"; exit 1; }

# Update wiki index and log, then perform targeted staging only when campaigns were downloaded
if [[ "$INGEST_DOWNLOADED" -gt 0 ]]; then
    update_wiki_index_and_log 2>&1 | tee -a "$LOG" || true

    log "Staging targeted changes in $WIKI_DIR (wiki/sources/, raw/campaigns/, wiki/index.md, wiki/log.md)..."
    git add wiki/sources/ raw/campaigns/ wiki/index.md wiki/log.md 2>/dev/null || true
else
    log "0 campaigns downloaded — skipping staging to preserve uncommitted working tree files"
fi

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
NEW_CAMPAIGNS=$(git diff --cached --name-only --diff-filter=A -- 'wiki/sources/*.md' 2>/dev/null | wc -l | tr -d ' ')
REFRESHED_CAMPAIGNS=$(git diff --cached --name-only --diff-filter=M -- 'wiki/sources/*.md' 2>/dev/null | wc -l | tr -d ' ')
log "Files staged: added=$ADDED modified=$MODIFIED (campaigns: new=$NEW_CAMPAIGNS refreshed=$REFRESHED_CAMPAIGNS)"

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
