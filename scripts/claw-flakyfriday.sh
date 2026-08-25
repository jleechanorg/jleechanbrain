#!/bin/bash
# claw-flakyfriday.sh — Friday: dead-code rev2 + flaky-CI root-cause + fix PRs.
# Pattern: Boris Cherny "Flaky Test Fixer" routine + the second-pass dead-code
# reaper from the Monday findings (some files you shouldn't touch, others need
# logging before deletion).
# Pipeline: /claw + /af (auto-factory drives the resulting factory-labeled beads).
#
# Exit codes: 0 = success (incl. zero findings), 1 = fatal preflight, 2 = some
# agent chunks failed (partial result posted), 3 = ALL scans failed (fatal).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERMES_HOME="${HERMES_HOME:-$HOME/.smartclaw}"
BUG_REPORTS_DIR="${CLAW_FRI_OUT:-/tmp/claw-flakyfriday}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
REPORT_FILE="${BUG_REPORTS_DIR}/claw-flaky-${TIMESTAMP}.md"

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

if ! command -v hermes >/dev/null 2>&1; then log_err "no hermes"; exit 1; fi
if ! command -v br >/dev/null 2>&1; then log_err "no br"; exit 1; fi
if [ -f "$HOME/.bashrc" ]; then source "$HOME/.bashrc" 2>/dev/null || true; fi

# Pull MINIMAX_API_KEY from bashrc (claudem normally does this via the function;
# we inline the wrapper here for non-TTY launchd compatibility).
if [ -z "${ANTHROPIC_AUTH_TOKEN:-}" ] && [ -f "$HOME/.bashrc" ]; then
    export ANTHROPIC_AUTH_TOKEN="$(grep -E '^export MINIMAX_API_KEY=' "$HOME/.bashrc" | head -1 | sed -E 's/^export MINIMAX_API_KEY="?([^"]*)"?$/\1/')"
    export ANTHROPIC_API_KEY="$ANTHROPIC_AUTH_TOKEN"
fi

log_info "=== claw-flakyfriday $TIMESTAMP ==="
if [ "${CLAW_SMOKE:-0}" = "1" ]; then
    log_info "CLAW_SMOKE=1 — skipping both lanes"
fi

# Strip ```json ... ``` markdown fences that claude --output-format text appends
# around its JSON output (same logic as monday — see bug note there).
strip_json_fences() {
    local f="$1"
    if jq -e . "$f" >/dev/null 2>&1; then return 0; fi
    python3 - "$f" <<'PYEOF'
import json, re, sys
try: raw = open(sys.argv[1]).read()
except Exception: sys.exit(0)
m = re.search(r"```(?:json)?\s*(\[.*?\]|\{.*?\})\s*```", raw, re.DOTALL)
if m: body = m.group(1)
else:
    starts = [raw.find('['), raw.find('{')]
    ends   = [raw.rfind(']'), raw.rfind('}')]
    s = min((x for x in starts if x >= 0), default=-1)
    e = max((x for x in ends   if x >= 0), default=-1)
    body = raw[s:e+1] if s >= 0 and e >= s else raw
open(sys.argv[1], 'w').write(body)
PYEOF
}

ACTIVE_AGENTS=()
declare -A AGENT_MODELS
AGENT_MODELS[claude]="anthropic/claude-3-5-haiku"
AGENT_MODELS[gemini]="agy-shim/gpt-oss-120b-medium"
AGENT_MODELS[minimax]="MiniMax-M3"
for AGENT in claude gemini minimax; do
    MODEL="${AGENT_MODELS[$AGENT]}"
    if hermes -z "Hello" -m "$MODEL" >/dev/null 2>&1; then
        ACTIVE_AGENTS+=("$AGENT")
    else
        log_warn "Probe FAIL: $AGENT — skipping"
    fi
done
if [ "${#ACTIVE_AGENTS[@]}" -eq 0 ]; then log_err "no agents"; exit 1; fi

FAILED_SCANS=0
SCAN_ATTEMPTS=0

# ---- Lane 1: flaky-CI root-cause scan ----
SMOKE_LANE1=0
SMOKE_LANE2=0
if [ "${CLAW_SMOKE:-0}" = "1" ]; then
    FLAKY_FILE=""; FLAKY_ERR=""
    FLAKY_CNT=0
    log_info "CLAW_SMOKE=1 — skipping Lane 1 flaky-CI scan"
    SMOKE_LANE1=1
else
FLAKY_FILE="${BUG_REPORTS_DIR}/claw-flaky-${TIMESTAMP}.json"
FLAKY_ERR="${FLAKY_FILE}.err"
PROMPT_FLAKY="Flaky CI detection for these repos:
${REPOS[*]}

For each repo, do the following:
1. Pull the last 100 GitHub Actions runs (gh api repos/OWNER/REPO/actions/runs?per_page=100).
2. Identify tests whose conclusion flipped (success → failure → success) in the last 14 days.
3. For each flaky test, fetch the failure log via gh api repos/OWNER/REPO/actions/jobs/<job_id>/logs and classify:
   - timing-dependent (race / timeout / network)
   - state-leak (test mutates global state, doesn't reset)
   - ordering-dependent (depends on prior test side-effect)
   - external-dependency (third-party API flake)
4. Output JSON: [{repo, test_path, flake_class, suggested_fix, severity(0-3)}]. Cap 15.

Do NOT modify any files. Return ONLY the JSON array."

if bash -lic "claudem -p \"\$1\" --output-format text --max-turns 25" _ "$PROMPT_FLAKY" \
    > "$FLAKY_FILE" 2> "$FLAKY_ERR"; then
    strip_json_fences "$FLAKY_FILE"
    FLAKY_CNT=$(jq 'length' "$FLAKY_FILE" 2>/dev/null || echo "0")
    log_info "Lane 1: $FLAKY_CNT flaky tests detected"
else
    FLAKY_CNT=0
    log_warn "Lane 1 (flaky scan) failed — see $FLAKY_ERR"
    FAILED_SCANS=$((FAILED_SCANS + 1))
fi
SCAN_ATTEMPTS=$((SCAN_ATTEMPTS + 1))
fi

# ---- Lane 2: dead-code rev2 (re-check Monday's findings with logging context) ----
# P1 #5 — Point at Monday's actual artifacts.
#   - CLAW_MON_OUT_DIR defaults to /tmp/claw-deadcode (matches Monday's BUG_REPORTS_DIR).
#   - Glob the .json files Monday actually wrote (under that directory, not /tmp
#     directly).
#   - Pull the matching factory-labeled beads via `br list --label factory`
#     instead of `gh issue list` (Monday files beads, not issues).
if [ "${CLAW_SMOKE:-0}" = "1" ]; then
    DEAD_FILE=""; DEAD_ERR=""
    DEAD_CNT=0
    log_info "CLAW_SMOKE=1 — skipping Lane 2 dead-code-rev2 scan"
    SMOKE_LANE2=1
else
DEAD_FILE="${BUG_REPORTS_DIR}/claw-deadcode-rev2-${TIMESTAMP}.json"
DEAD_ERR="${DEAD_FILE}.err"
MON_OUT_DIR="${CLAW_MON_OUT_DIR:-/tmp/claw-deadcode}"
# Collect Monday's analysis files (the JSON outputs Monday wrote per-repo).
# Use a glob inside MON_OUT_DIR so we get Monday's artifacts, not stray
# /tmp/claw-deadcode-*.json files left over from elsewhere.
MON_ANALYSIS_FILES=( $(ls -1 "${MON_OUT_DIR}"/claw-deadcode-*.json 2>/dev/null | head -20) )
# Also gather the open factory-labeled bead IDs Monday produced so Lane 2 has
# concrete IDs to attach classifications to (not just titles).
MON_BEAD_IDS=( $(br list --label factory --limit 500 --format json 2>/dev/null \
    | jq -r '.[] | select(.title | startswith("claw-deadcode:")) | .id' 2>/dev/null \
    | head -100) )
PROMPT_DEAD="Dead-code second pass for these repos:
${REPOS[*]}

The Monday claw-deadcode-monday job already filed factory-labeled beads AND wrote
per-repo analysis files. Your job is the second-pass re-classification:

1. Pull all open factory-labeled beads from Monday via: br list --label factory --limit 500 --format json
2. Read Monday's analysis files from this directory (do NOT use /tmp directly):
   MON_OUT_DIR='${MON_OUT_DIR}'
   Analysis files available:
$(for f in "${MON_ANALYSIS_FILES[@]:-}"; do echo "   - $f"; done)
4. For each Monday finding, classify as:
   - SAFE_DELETE: no callers, no dynamic use, safe to remove
   - NEEDS_LOGGING: delete with a one-line deprecation log + 2-week soft-delete
   - KEEP: dynamic import, plugin system, or runtime-loaded
5. Output JSON: [{finding_id, repo, path, classification, rationale}]. Cap 25.
   Set finding_id to the matching Monday bead ID when one exists in:
$(for id in "${MON_BEAD_IDS[@]:-}"; do echo "   - $id"; done)"

if bash -lic "claudem -p \"\$1\" --output-format text --max-turns 25" _ "$PROMPT_DEAD" \
    > "$DEAD_FILE" 2> "$DEAD_ERR"; then
    strip_json_fences "$DEAD_FILE"
    DEAD_CNT=$(jq 'length' "$DEAD_FILE" 2>/dev/null || echo "0")
    log_info "Lane 2: $DEAD_CNT dead-code findings re-classified"
else
    DEAD_CNT=0
    log_warn "Lane 2 (dead-code rev2) failed — see $DEAD_ERR"
    FAILED_SCANS=$((FAILED_SCANS + 1))
fi
SCAN_ATTEMPTS=$((SCAN_ATTEMPTS + 1))
fi

# ---- File beads ----
FILED=0
SKIPPED=0
KEPT=0
# P1 #4 — pre-fetch open factory-labeled bead titles for dedup.
EXISTING_BEAD_TITLES="$(br list --label factory --limit 500 --format json 2>/dev/null | jq -r '.[].title // empty' 2>/dev/null || true)"
bead_already_filed() {
    local title="$1"
    if [ -n "$EXISTING_BEAD_TITLES" ] && echo "$EXISTING_BEAD_TITLES" | grep -qFx "$title"; then
        return 0
    fi
    return 1
}

if [ "$FLAKY_CNT" -gt 0 ]; then
    while IFS=$'\t' read -r repo test cls fix sev; do
        BEAD_TITLE="claw-flaky: $repo $test"
        if bead_already_filed "$BEAD_TITLE"; then
            SKIPPED=$((SKIPPED + 1))
            continue
        fi
        BEAD_BODY="Flaky test in $repo: $test [$cls, sev=$sev]. Suggested fix: $fix. Detected by claw-flakyfriday $(date -u +%F)."
        if br create "$BEAD_TITLE" \
            --type bug --priority 1 --label factory --description "$BEAD_BODY" \
            > /dev/null 2>&1; then
            FILED=$((FILED + 1))
        fi
    done < <(jq -r '.[] | "\(.repo)\t\(.test_path)\t\(.flake_class)\t(.suggested_fix // \"\")\t(.severity // 1)"' "$FLAKY_FILE" 2>/dev/null)
fi

if [ "$DEAD_CNT" -gt 0 ]; then
    while IFS=$'\t' read -r fid repo path cls rat; do
        # P2 #6 — KEEP classifications are an explicit do-not-change result.
        # Do NOT file a factory-labeled bead for them — that would convert
        # "don't touch" into implementation work. Track them separately so
        # the summary still shows the Lane 2 hit rate.
        if [ "$cls" = "KEEP" ]; then
            KEPT=$((KEPT + 1))
            continue
        fi
        BEAD_TITLE="claw-deadcode-rev2: $repo $path ($cls)"
        if bead_already_filed "$BEAD_TITLE"; then
            SKIPPED=$((SKIPPED + 1))
            continue
        fi
        BEAD_BODY="Dead-code rev2 [$cls] for $repo $path (Monday finding_id=${fid:-?}). Rationale: $rat. Re-classified by claw-flakyfriday $(date -u +%F)."
        if br create "$BEAD_TITLE" \
            --type chore --priority 2 --label factory --description "$BEAD_BODY" \
            > /dev/null 2>&1; then
            FILED=$((FILED + 1))
        fi
    done < <(jq -r '.[] | "\(.finding_id // \"?\")\t\(.repo)\t\(.path)\t\(.classification)\t(.rationale // \"\")"' "$DEAD_FILE" 2>/dev/null)
fi

# ---- /af overlay ----
DF_TICK="$HOME/projects/dark-factory/daemon/factory-af-tick.sh"
if [ "${CLAW_SMOKE:-0}" = "1" ]; then
    log_info "CLAW_SMOKE=1 — skipping /af dispatch (smoke mode)"
elif [ -x "$DF_TICK" ]; then
    bash "$DF_TICK" 2>&1 | tee -a "$REPORT_FILE" || log_warn "factory-af-tick.sh non-zero"
elif [ -x "$HOME/projects/dark-factory/scripts/auto-factory-tick.sh" ]; then
    bash "$HOME/projects/dark-factory/scripts/auto-factory-tick.sh" --label factory 2>&1 | tee -a "$REPORT_FILE" || true
fi

# ---- Slack summary ----
{
    echo "*claw-flakyfriday — $TIMESTAMP*"
    echo
    echo "*Repos scanned:* ${REPOS[*]}"
    echo "*Flaky tests:* $FLAKY_CNT"
    echo "*Dead-code rev2 reclassifications:* $DEAD_CNT"
    echo "*KEEP (no bead, do-not-touch):* $KEPT"
    echo "*Beads filed:* $FILED"
    echo "*Beads skipped (duplicate):* $SKIPPED"
    echo "*Scan attempts:* $SCAN_ATTEMPTS"
    echo "*Scan failures:* $FAILED_SCANS"
    echo
    if [ "$FLAKY_CNT" -eq 0 ] && [ "$DEAD_CNT" -eq 0 ] && [ "$FAILED_SCANS" -eq 0 ]; then
        echo "No flaky tests / reclassifications this week."
    elif [ "$FAILED_SCANS" -gt 0 ]; then
        echo "_Scan failures:_ $FAILED_SCANS / $SCAN_ATTEMPTS"
    fi
    echo
    echo "/af dispatched. Full report: $REPORT_FILE"
} > "$REPORT_FILE"

if [ -n "${SLACK_USER_TOKEN:-}" ] && [ "${SLACK_USER_TOKEN:-}" != "***" ]; then
    CHAN="${CLAW_FRI_CHANNEL:-C0AJQ5M0A0Y}"
    TEXT=$(cat "$REPORT_FILE")
    curl -fsS -X POST "https://slack.com/api/chat.postMessage" \
        -H "Authorization: Bearer ${SLACK_USER_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg c "$CHAN" --arg t "$TEXT" '{channel:$c, text:$t}')" \
        > /dev/null 2>&1 || log_warn "Slack post failed"
fi

log_info "Done. Lane 1=$FLAKY_CNT flaky, Lane 2=$DEAD_CNT deadcode ($KEPT KEEP / no bead), $FILED beads filed, $SKIPPED duplicates skipped, $FAILED_SCANS/$SCAN_ATTEMPTS scans failed."

# P1 #3 — exit 2 for partial, exit 3 for all-failed
if [ "$SCAN_ATTEMPTS" -gt 0 ] && [ "$FAILED_SCANS" -ge "$SCAN_ATTEMPTS" ]; then
    log_err "All $SCAN_ATTEMPTS scans failed"
    SCAN_EXIT=3
elif [ "$FAILED_SCANS" -gt 0 ]; then
    log_warn "Partial failure: $FAILED_SCANS / $SCAN_ATTEMPTS scans failed"
    SCAN_EXIT=2
else
    SCAN_EXIT=0
fi
exit "$SCAN_EXIT"