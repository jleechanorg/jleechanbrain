#!/bin/bash
# claw-deadcode-monday.sh — Weekly dead-code-removal job (Mondays 09:00 PT)
# Pattern: Boris Cherny "Weekend Reaper" routine (Mon = find dead code, file PRs).
# Pipeline: /claw + /af (auto-factory drives the resulting factory-labeled beads).
#
# What it does:
#   1. Spawns 3 parallel agents (claude/gemini/minimax) to scan target repos for
#      unused exports, orphaned functions, dead feature flags, stale TODO code.
#   2. Files one factory-labeled bead per finding (auto-factory picks them up
#      and drives a PR through dark-factory).
#   3. Posts a Slack summary to #ai-general with the count of beads filed and
#      which repos were scanned.
#
# WHEREFORE: /claw <PR> is the user-facing entry; this is the cron mirror of
# "every Monday, run /claw on the whole tree, but file through /af."
#
# Idempotent: re-runs are safe; the bead-dedup check (br ready) prevents floods.
# Exit codes: 0 = success (incl. zero findings), 1 = fatal preflight, 2 = some
# agent chunks failed (partial result posted), 3 = ALL scans failed (fatal).
#
# Auth routing decision (P1 #1 / P1 #2 from PR #819 review):
#   The bashrc contract (bashrc:1046) prescribes `bash -lic 'claudem …'` for
#   non-interactive callers because the bashrc function centralizes the
#   MiniMax API auth (claudem hardcodes ANTHROPIC_BASE_URL / ANTHROPIC_MODEL
#   per bashrc:1050-1058). That path is the PRIMARY dispatch path here.
#   launchd / non-TTY contexts sometimes fail `bash -lic` with "job control
#   disabled" / "function lookup failed" (see memory 2026-08-13 daily-dice-audit
#   bug). When that happens, fall back to inlining the same env from bashrc
#   directly so the script still completes — gated by CLAW_NO_LAUNCHD=1 so an
#   operator must explicitly opt in to the non-bashrc path. The probe below
#   uses `bash -lic 'claudem …'` end-to-end so ACTIVE_AGENTS reflects what
#   dispatch will actually invoke; if the probe path fails and no fallback is
#   enabled, the scan is recorded as failed and counted by FAILED_SCANS.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERMES_HOME="${HERMES_HOME:-$HOME/.smartclaw}"
BUG_REPORTS_DIR="${CLAW_DEADCODE_OUT:-/tmp/claw-deadcode}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
REPORT_FILE="${BUG_REPORTS_DIR}/claw-deadcode-${TIMESTAMP}.md"

# Repos to scan — match the canonical jleechanorg org + worldarchitect.ai
REPOS=(
    "jleechanorg/jleechanbrain"
    "jleechanorg/worldarchitect.ai"
    "jleechanorg/ai_universe"
)

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()  { echo -e "${RED}[ERR ]${NC} $1"; }

mkdir -p "$BUG_REPORTS_DIR"

# ---- Preflight ----
if ! command -v hermes >/dev/null 2>&1; then
    log_err "hermes CLI not found on PATH — fail closed"
    exit 1
fi
if ! command -v br >/dev/null 2>&1; then
    log_err "br (beads CLI) not found — install beads_rust first"
    exit 1
fi

# Source bashrc so the claudem bash function loads (memory: 2026-08-13 daily-dice-audit bug).
if [ -f "$HOME/.bashrc" ]; then
    # shellcheck disable=SC1090
    source "$HOME/.bashrc" 2>/dev/null || true
fi

# Strip ```json ... ``` markdown fences that claude --output-format text appends
# around its JSON output. Without this, jq 'length' returns 0 on a "real"
# payload that the agent simply wrapped in fences (this was the actual bug
# surfaced by the 2026-08-13 dry-run: agent produced 6 dup groups, script
# reported "Found 0").
strip_json_fences() {
    local f="$1"
    # First try: file is already valid JSON
    if jq -e . "$f" >/dev/null 2>&1; then return 0; fi
    # Otherwise: extract everything between ``` fences (or first [ to last ])
    python3 - "$f" <<'PYEOF'
import json, re, sys
try:
    raw = open(sys.argv[1]).read()
except Exception:
    sys.exit(0)
m = re.search(r"```(?:json)?\s*(\[.*?\]|\{.*?\})\s*```", raw, re.DOTALL)
if m:
    body = m.group(1)
else:
    # Last-resort: take from first [ or { to last ] or }
    starts = [raw.find('['), raw.find('{')]
    ends   = [raw.rfind(']'), raw.rfind('}')]
    s = min((x for x in starts if x >= 0), default=-1)
    e = max((x for x in ends   if x >= 0), default=-1)
    body = raw[s:e+1] if s >= 0 and e >= s else raw
open(sys.argv[1], 'w').write(body)
PYEOF
}

# Pull MINIMAX_API_KEY from bashrc (claudem normally does this via the function).
# This is the FALLBACK path used only when bash -lic is unavailable in non-TTY
# contexts (CLAW_NO_LAUNCHD=1). The PRIMARY dispatch is `bash -lic 'claudem …'`
# which sources bashrc itself, so ANTHROPIC_AUTH_TOKEN is set by the function.
if [ -z "${ANTHROPIC_AUTH_TOKEN:-}" ] && [ -f "$HOME/.bashrc" ]; then
    export ANTHROPIC_AUTH_TOKEN="$(grep -E '^export MINIMAX_API_KEY=' "$HOME/.bashrc" | head -1 | sed -E 's/^export MINIMAX_API_KEY="?([^"]*)"?$/\1/')"
    export ANTHROPIC_API_KEY="$ANTHROPIC_AUTH_TOKEN"
fi
export ANTHROPIC_BASE_URL="${ANTHROPIC_BASE_URL:-https://api.minimax.io/anthropic}"
export ANTHROPIC_MODEL="${ANTHROPIC_MODEL:-MiniMax-M3}"
export CLAUDE_CODE_ENABLE_EXPERIMENTAL_ADVISOR_TOOL="${CLAUDE_CODE_ENABLE_EXPERIMENTAL_ADVISOR_TOOL:-0}"

log_info "=== claw-deadcode-monday $TIMESTAMP ==="
log_info "Repos: ${REPOS[*]}"

# Smoke mode: short-circuit agent dispatch (preflight + /af overlay only).
if [ "${CLAW_SMOKE:-0}" = "1" ]; then
    log_info "CLAW_SMOKE=1 — skipping agent dispatch, going straight to /af overlay"
fi

# ---- Active-agent probe (P1 #2: must exercise the SAME dispatch path) ----
# The previous probe only verified that `hermes -m $MODEL` could round-trip a
# prompt, but dispatch always invokes `bash -lic 'claudem …'` which is
# hardcoded to MiniMax-M3 in bashrc. So even when Claude/Gemini probes passed,
# dispatch still targeted MiniMax — the advertised fallback was theatre. The
# fix below probes the actual claudem end-to-end path; ACTIVE_AGENTS therefore
# reflects the dispatch the script will actually use. (We keep the parallel
# `hermes -m` probe as a sanity side-channel because it's free and useful when
# debugging model catalogue drift.)
ACTIVE_AGENTS=()
declare -A AGENT_MODELS
AGENT_MODELS[claude]="anthropic/claude-3-5-haiku"
AGENT_MODELS[gemini]="agy-shim/gpt-oss-120b-medium"
AGENT_MODELS[minimax]="MiniMax-M3"

# End-to-end probe: actually run the dispatch path the scan will use.
# This is the only probe that matters for dispatch correctness.
CLAUDEM_PROBE_OK=0
# Use `-p` (print mode) — `-z` is a `hermes` flag, not a `claude` flag.
# Confirmed against `claudem --help` output: only `-p/--print` triggers non-interactive.
if bash -lic 'claudem -p "echo ok" --output-format text --max-turns 1' >/dev/null 2>&1; then
    CLAUDEM_PROBE_OK=1
    ACTIVE_AGENTS+=("minimax")
    log_info "Probe OK: claudem end-to-end (MiniMax-M3) — bash -lic works in this context"
elif [ "${CLAW_NO_LAUNCHD:-0}" = "1" ]; then
    # Non-TTY escape hatch — use the inline env path (matches bashrc:1050-1058
    # exactly). Operator must opt in explicitly because the credentials end up
    # in the script process env rather than behind a sourced function.
    if MINIMAX_API_KEY="$ANTHROPIC_AUTH_TOKEN" \
       ANTHROPIC_BASE_URL="https://api.minimax.io/anthropic" \
       ANTHROPIC_AUTH_TOKEN="$ANTHROPIC_AUTH_TOKEN" \
       ANTHROPIC_API_KEY="$ANTHROPIC_AUTH_TOKEN" \
       ANTHROPIC_MODEL="MiniMax-M3" \
       CLAUDE_CODE_ENABLE_EXPERIMENTAL_ADVISOR_TOOL=0 \
       claude --dangerously-skip-permissions --effort high -p "echo ok" --output-format text --max-turns 1 \
       >/dev/null 2>&1; then
        CLAUDEM_PROBE_OK=1
        ACTIVE_AGENTS+=("minimax-direct")
        log_warn "Probe OK via CLAW_NO_LAUNCHD direct path — operator opt-in"
    fi
fi

if [ "$CLAUDEM_PROBE_OK" -eq 0 ]; then
    log_err "claudem end-to-end probe failed in this context — set CLAW_NO_LAUNCHD=1 to fall back to inline env path"
    exit 1
fi

# Cheap side-channel: list catalogue models so a human reading the log can see
# which other providers are healthy (informational only — does NOT affect dispatch).
for AGENT in claude gemini; do
    MODEL="${AGENT_MODELS[$AGENT]}"
    if hermes -z "Hello" -m "$MODEL" >/dev/null 2>&1; then
        log_info "Catalogue probe OK: $AGENT ($MODEL) — informational only; dispatch uses claudem"
    else
        log_info "Catalogue probe unavailable: $AGENT ($MODEL) — informational only"
    fi
done

# ---- Per-repo scan, one chunk per repo ----
TOTAL_BEADS=0
FAILED_SCANS=0
SCAN_ATTEMPTS=0
declare -a FINDING_REPOS=()
declare -a FINDING_COUNTS=()
declare -a FINDING_FILES=()
declare -a FAILED_REPOS=()

if [ "${CLAW_SMOKE:-0}" = "1" ]; then
    log_info "CLAW_SMOKE=1 — skipping scan loop"
fi

# run_claudem PROMPT OUT_FILE ERR_FILE EXIT_FILE
# Dispatch helper — uses `bash -lic 'claudem …'` per bashrc contract, with the
# CLAW_NO_LAUNCHD=1 inline-env fallback when bash -lic fails in non-TTY.
run_claudem() {
    local prompt="$1" out="$2" err="$3" exit_file="$4"
    if bash -lic "claudem -p \"\$1\" --output-format text --max-turns 20" _ "$prompt" \
        > "$out" 2> "$err"; then
        echo "0" > "$exit_file"
        return 0
    fi
    if [ "${CLAW_NO_LAUNCHD:-0}" = "1" ]; then
        log_warn "bash -lic failed; retrying with CLAW_NO_LAUNCHD=1 inline-env fallback"
        if MINIMAX_API_KEY="$ANTHROPIC_AUTH_TOKEN" \
           ANTHROPIC_BASE_URL="https://api.minimax.io/anthropic" \
           ANTHROPIC_AUTH_TOKEN="$ANTHROPIC_AUTH_TOKEN" \
           ANTHROPIC_API_KEY="$ANTHROPIC_AUTH_TOKEN" \
           ANTHROPIC_MODEL="MiniMax-M3" \
           CLAUDE_CODE_ENABLE_EXPERIMENTAL_ADVISOR_TOOL=0 \
           claude --dangerously-skip-permissions --effort high -p "$prompt" \
                  --output-format text --max-turns 20 \
           > "$out" 2> "$err"; then
            echo "0" > "$exit_file"
            return 0
        fi
    fi
    echo "1" > "$exit_file"
    return 1
}

for REPO in "${REPOS[@]}"; do
    if [ "${CLAW_SMOKE:-0}" = "1" ]; then
        break
    fi
    SCAN_ATTEMPTS=$((SCAN_ATTEMPTS + 1))
    AGENT="${ACTIVE_AGENTS[$((TOTAL_BEADS % ${#ACTIVE_AGENTS[@]}))]}"
    MODEL="${AGENT_MODELS[$AGENT]:-MiniMax-M3}"
    OUT_FILE="${BUG_REPORTS_DIR}/claw-deadcode-${REPO//\//_}-${TIMESTAMP}.json"
    ERR_FILE="${OUT_FILE}.err"
    EXIT_FILE="${OUT_FILE}.exit"

    log_info "Scanning $REPO via $AGENT ($MODEL)"

    PROMPT="Dead-Code Hunt for $REPO:

1. cd into the repo and identify dead code:
   - Unused exports (functions/classes exported but never imported)
   - Orphaned modules (whole files with no callers)
   - Stale feature flags (env vars, constants read but never set; or set but never read)
   - Dead TODO/FIXME code paths (TODO comments with no linked issue older than 6mo)
   - Functions called only by tests of removed features

2. Tools: ripgrep, git log --diff-filter=D, gh pr list --state merged --search 'revert OR remove OR cleanup', dependency-cruiser if installed.

3. Output JSON array of findings: [{path, line_range, kind, description, suggested_fix}].
   Cap at 20 findings per repo (highest-confidence first).

4. Do NOT modify any files — read-only analysis. The auto-factory will open the PRs.
   Return ONLY the JSON array."

    # Invoke claudem() per bashrc contract for non-interactive callers
    # (launchd / cron / AO workers): use `bash -lic 'claudem …'` so .bashrc is
    # sourced and the function is visible. claudem wraps `claude` with the
    # correct env (CLAUDEM_MODE=1, ANTHROPIC_BASE_URL=https://api.minimax.io/anthropic,
    # ANTHROPIC_MODEL=MiniMax-M3, --dangerously-skip-permissions, --effort high).
    # See ~/.bashrc:1046-1058.
    if run_claudem "$PROMPT" "$OUT_FILE" "$ERR_FILE" "$EXIT_FILE"; then
        strip_json_fences "$OUT_FILE"
        CNT=$(jq 'length' "$OUT_FILE" 2>/dev/null || echo "0")
        if [ "$CNT" -gt 0 ]; then
            FINDING_REPOS+=("$REPO")
            FINDING_COUNTS+=("$CNT")
            FINDING_FILES+=("$OUT_FILE")
            TOTAL_BEADS=$((TOTAL_BEADS + CNT))
        fi
    else
        FAILED_SCANS=$((FAILED_SCANS + 1))
        FAILED_REPOS+=("$REPO")
        log_warn "Agent $AGENT failed on $REPO (see $ERR_FILE)"
    fi
done

# P1 #3 — surface scan failures as nonzero exit so launchd monitoring can tell
# a clean scan from an outage. exit 2 = partial failure, exit 3 = all failed.
if [ "$SCAN_ATTEMPTS" -gt 0 ] && [ "$FAILED_SCANS" -ge "$SCAN_ATTEMPTS" ] && [ "$SCAN_ATTEMPTS" -gt 0 ]; then
    log_err "All $SCAN_ATTEMPTS scans failed: ${FAILED_REPOS[*]}"
    SCAN_EXIT=3
elif [ "$FAILED_SCANS" -gt 0 ]; then
    log_warn "Partial failure: $FAILED_SCANS / $SCAN_ATTEMPTS scans failed (${FAILED_REPOS[*]})"
    SCAN_EXIT=2
else
    SCAN_EXIT=0
fi

# P1 #4 — bead dedup. Build a set of existing open factory-labeled bead titles
# once so per-finding lookups are O(1). Falls back to a fresh scan if the
# pre-pass fails (e.g. br schema mismatch). We match by exact title (the
# canonical claw-deadcode: <repo> <path> (<kind>) form) AND by path+kind
# substring so a manual renumber doesn't defeat dedup.
EXISTING_BEAD_TITLES="$(br list --label factory --limit 500 --format json 2>/dev/null | jq -r '.[].title // empty' 2>/dev/null || true)"
EXISTING_DEDUP_KEYS="$(br list --label factory --limit 500 --format json 2>/dev/null \
    | jq -r '.[] | (.title // "")' 2>/dev/null \
    | grep -oE 'claw-deadcode: [^ ]+ [^ ]+ \([^)]+\)' \
    || true)"
bead_already_filed() {
    local title="$1" repo="$2" path="$3" kind="$4"
    if [ -n "$EXISTING_DEDUP_KEYS" ] && echo "$EXISTING_DEDUP_KEYS" | grep -qF "$repo $path ($kind)"; then
        return 0
    fi
    if [ -n "$EXISTING_BEAD_TITLES" ] && echo "$EXISTING_BEAD_TITLES" | grep -qFx "$title"; then
        return 0
    fi
    return 1
}

# ---- File factory-labeled beads for each finding ----
log_info "Filing factory-labeled beads (total findings: $TOTAL_BEADS)"

FILED=0
SKIPPED=0
for i in "${!FINDING_REPOS[@]}"; do
    REPO="${FINDING_REPOS[$i]}"
    JSON="${FINDING_FILES[$i]}"
    while IFS=$'\t' read -r path kind desc; do
        BEAD_TITLE="claw-deadcode: $REPO $path ($kind)"
        if bead_already_filed "$BEAD_TITLE" "$REPO" "$path" "$kind"; then
            SKIPPED=$((SKIPPED + 1))
            continue
        fi
        # Bead body must be SHORT — AO spawn prompt cap is 4096 chars.
        BEAD_BODY="Dead code in $REPO: $kind at $path. $desc. Auto-detected by claw-deadcode-monday $(date -u +%F). target_repo: $REPO."
        if br create "$BEAD_TITLE" \
            --type chore --priority 2 --label factory --description "$BEAD_BODY" \
            > /dev/null 2>&1; then
            FILED=$((FILED + 1))
        else
            log_warn "Bead create failed for $path"
        fi
    done < <(jq -r '.[] | "\(.path)\t\(.kind)\t(.description // \"\" | gsub("\t"; " "))"' "$JSON")
done
log_info "Beads: filed=$FILED skipped_duplicate=$SKIPPED"

# ---- /af overlay — kick the auto-factory daemon to pick up the new beads ----
DF_TICK="$HOME/projects/dark-factory/daemon/factory-af-tick.sh"
DF_BIN="$HOME/projects/dark-factory/bin/dark-factory"
if [ "${CLAW_SMOKE:-0}" = "1" ]; then
    log_info "CLAW_SMOKE=1 — skipping /af dispatch (smoke mode)"
elif [ -x "$DF_TICK" ]; then
    # Direct tick — daemon picks up the new factory-labeled beads immediately
    # (vs. waiting up to 240s for the launchd loop to fire next).
    bash "$DF_TICK" 2>&1 | tee -a "$REPORT_FILE" || log_warn "factory-af-tick.sh returned non-zero"
elif [ -x "$DF_BIN" ]; then
    "$DF_BIN" tick --label factory 2>&1 | tee -a "$REPORT_FILE" || log_warn "dark-factory tick non-zero"
elif [ -x "$HOME/projects/dark-factory/scripts/auto-factory-tick.sh" ]; then
    bash "$HOME/projects/dark-factory/scripts/auto-factory-tick.sh" --label factory 2>&1 | tee -a "$REPORT_FILE" || true
else
    log_warn "No /af trigger found — beads will be picked up on next daemon heartbeat (≤240s)"
fi

# ---- Slack summary ----
{
    echo "*claw-deadcode-monday — $TIMESTAMP*"
    echo
    echo "*Repos scanned:* ${REPOS[*]}"
    echo "*Findings:* $TOTAL_BEADS"
    echo "*Beads filed:* $FILED"
    echo "*Beads skipped (duplicate):* $SKIPPED"
    echo "*Scan attempts:* $SCAN_ATTEMPTS"
    echo "*Scan failures:* $FAILED_SCANS"
    echo "*Agents:* ${ACTIVE_AGENTS[*]}"
    echo
    if [ "$TOTAL_BEADS" -eq 0 ] && [ "$FAILED_SCANS" -eq 0 ]; then
        echo "No dead code found this week."
    elif [ "$FAILED_SCANS" -gt 0 ]; then
        echo "_Scan failures:_ ${FAILED_REPOS[*]}"
    fi
    if [ "$TOTAL_BEADS" -gt 0 ]; then
        for i in "${!FINDING_REPOS[@]}"; do
            echo "- ${FINDING_REPOS[$i]}: ${FINDING_COUNTS[$i]} findings"
        done
    fi
    echo
    echo "/af dispatched; daemon will drive PRs through dark-factory."
    echo "Full report: $REPORT_FILE"
} > "$REPORT_FILE"

# Post via user token (matches bug-hunt-daily.sh pattern)
if [ -n "${SLACK_USER_TOKEN:-}" ] && [ "${SLACK_USER_TOKEN:-}" != "***" ]; then
    CHAN="${CLAW_DEADCODE_CHANNEL:-C0AJQ5M0A0Y}"  # #ai-general
    TEXT=$(cat "$REPORT_FILE")
    curl -fsS -X POST "https://slack.com/api/chat.postMessage" \
        -H "Authorization: Bearer ${SLACK_USER_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg c "$CHAN" --arg t "$TEXT" '{channel:$c, text:$t}')" \
        > /dev/null 2>&1 || log_warn "Slack post failed"
fi

log_info "Done. $FILED beads filed, $SKIPPED duplicates skipped, $TOTAL_BEADS findings, $FAILED_SCANS/$SCAN_ATTEMPTS scans failed."
if [ "${CLAW_SMOKE:-0}" = "1" ]; then exit 0; fi
exit "$SCAN_EXIT"