#!/bin/bash
# claw-dupunifier-wednesday.sh — Weekly duplicate-implementation-unifier (Wed 09:00 PT)
# Pattern: Boris Cherny "Abstraction Improver" routine (consolidate near-duplicates).
# Pipeline: /claw + /af (auto-factory drives resulting factory-labeled beads).
#
# What it does:
#   1. Runs cross-repo + within-repo duplicate detection (small scripts, helpers,
#      validators) — finds near-identical implementations across jleechanorg/*.
#   2. For each duplicate set, files ONE factory-labeled bead proposing a shared
#      helper location + the call-site migrations.
#   3. Kicks /af so the auto-factory daemon dispatches the unifier PR.
#
# Exit codes: 0 = success (incl. zero findings), 1 = fatal preflight, 2 = some
# agent chunks failed (partial result posted), 3 = ALL scans failed (fatal).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERMES_HOME="${HERMES_HOME:-$HOME/.smartclaw}"
BUG_REPORTS_DIR="${CLAW_DUP_OUT:-/tmp/claw-dupunifier}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
REPORT_FILE="${BUG_REPORTS_DIR}/claw-dup-${TIMESTAMP}.md"

REPOS=(
    "jleechanorg/jleechanbrain"
    "jleechanorg/worldarchitect.ai"
    "jleechanorg/ai_universe"
    "jleechanorg/beads"
)

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()  { echo -e "${RED}[ERR ]${NC} $1"; }

mkdir -p "$BUG_REPORTS_DIR"

if ! command -v hermes >/dev/null 2>&1; then
    log_err "hermes CLI not found on PATH — fail closed"
    exit 1
fi
if ! command -v br >/dev/null 2>&1; then
    log_err "br (beads CLI) not found — install beads_rust first"
    exit 1
fi
if [ -f "$HOME/.bashrc" ]; then source "$HOME/.bashrc" 2>/dev/null || true; fi

# Pull MINIMAX_API_KEY from bashrc (claudem normally does this via the function;
# we inline the wrapper here for non-TTY launchd compatibility).
if [ -z "${ANTHROPIC_AUTH_TOKEN:-}" ] && [ -f "$HOME/.bashrc" ]; then
    export ANTHROPIC_AUTH_TOKEN="$(grep -E '^export MINIMAX_API_KEY=' "$HOME/.bashrc" | head -1 | sed -E 's/^export MINIMAX_API_KEY="?([^"]*)"?$/\1/')"
    export ANTHROPIC_API_KEY="$ANTHROPIC_AUTH_TOKEN"
fi

log_info "=== claw-dupunifier-wednesday $TIMESTAMP ==="
log_info "Repos: ${REPOS[*]}"
if [ "${CLAW_SMOKE:-0}" = "1" ]; then
    log_info "CLAW_SMOKE=1 — skipping cross-repo dup scan"
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

# ---- Agent preflight (reuse same model table as Monday) ----
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
if [ "${#ACTIVE_AGENTS[@]}" -eq 0 ]; then
    log_err "No agents available"
    exit 1
fi

# ---- Pairwise cross-repo duplicate hunt (single agent, all 4 repos) ----
FAILED_SCANS=0
SCAN_ATTEMPTS=0
if [ "${CLAW_SMOKE:-0}" = "1" ]; then
    OUT_FILE=""; CNT=0
    log_info "CLAW_SMOKE=1 — skipping cross-repo dup scan"
else
AGENT="${ACTIVE_AGENTS[0]}"
MODEL="${AGENT_MODELS[$AGENT]}"
OUT_FILE="${BUG_REPORTS_DIR}/claw-dup-crossrepo-${TIMESTAMP}.json"
ERR_FILE="${OUT_FILE}.err"

PROMPT="Duplicate / near-duplicate implementation hunt across these repos:
${REPOS[*]}

For each pair (within or across repos), look for:
1. Functions with same signature + >70% identical body (token-overlap on normalized source)
2. Identical JSON-schema validators or env parsers duplicated in 2+ places
3. gh-safe-publish / slack-post / outbound-secret-gate style utilities that diverge by accident
4. launchd plists that copy-pasted env blocks but should share a templated snippet

Output JSON array: [{canonical_signature, dupes:[{repo,path,lines}], proposed_shared_location, migration_cost_days}].
Cap 12 entries, highest-savings first.

Do NOT modify files. Read-only analysis. Return ONLY the JSON array."

if ! bash -lic "claudem -p \"\$1\" --output-format text --max-turns 25" _ "$PROMPT" \
    > "$OUT_FILE" 2> "$ERR_FILE"; then
    log_warn "Cross-repo dup scan failed — see $ERR_FILE"
    FAILED_SCANS=$((FAILED_SCANS + 1))
    CNT=0
fi
SCAN_ATTEMPTS=$((SCAN_ATTEMPTS + 1))

strip_json_fences "$OUT_FILE"
CNT=$(jq 'length' "$OUT_FILE" 2>/dev/null || echo "0")
log_info "Found $CNT duplicate groups"
fi  # end CLAW_SMOKE guard

# ---- File ONE factory-labeled bead per duplicate group ----
FILED=0
SKIPPED=0
if [ "$CNT" -gt 0 ]; then
    # P1 #4 — bead dedup. Pre-fetch existing open factory-labeled bead titles
    # so per-finding lookups are O(1).
    EXISTING_BEAD_TITLES="$(br list --label factory --limit 500 --format json 2>/dev/null | jq -r '.[].title // empty' 2>/dev/null || true)"
    while IFS=$'\t' read -r sig dupes_blob proposed_loc cost; do
        BEAD_TITLE="claw-dup: $sig"
        # P1 #4 — skip if a matching bead already exists by exact signature
        if [ -n "$EXISTING_BEAD_TITLES" ] && echo "$EXISTING_BEAD_TITLES" | grep -qFx "$BEAD_TITLE"; then
            SKIPPED=$((SKIPPED + 1))
            continue
        fi
        # P2 #7 — include .dupes in the bead body so the factory worker knows
        # WHICH files to look at. dupes_blob is a compact "repo:path:Lstart-Lend;"
        # list rendered by jq below; trim further if total prompt would exceed
        # the AO spawn cap (4096 chars). The blob is already bounded to ~80
        # chars per entry by the jq expression.
        BEAD_BODY="Duplicate group '$sig'. Proposed shared location: $proposed_loc. Migration cost: $cost. Call sites: $dupes_blob Auto-detected by claw-dupunifier-wednesday $(date -u +%F)."
        if br create "$BEAD_TITLE" \
            --type chore --priority 2 --label factory --description "$BEAD_BODY" \
            > /dev/null 2>&1; then
            FILED=$((FILED + 1))
        fi
    done < <(jq -r '.[] | "\(.canonical_signature)\t((.dupes // []) | map("\(.repo | split("/")[-1]):\(.path | sub(".*/"; "")):\(.lines[0] // 0)-\(.lines[1] // .lines[0] // 0)") | join("; ") | .[0:1024])\t(.proposed_shared_location // "tbd")\t(.migration_cost_days // "unknown")"' "$OUT_FILE" 2>/dev/null)
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
    echo "*claw-dupunifier-wednesday — $TIMESTAMP*"
    echo
    echo "*Repos scanned:* ${REPOS[*]}"
    echo "*Duplicate groups:* $CNT"
    echo "*Beads filed:* $FILED"
    echo "*Beads skipped (duplicate):* $SKIPPED"
    echo "*Scan attempts:* $SCAN_ATTEMPTS"
    echo "*Scan failures:* $FAILED_SCANS"
    echo
    if [ "$CNT" -eq 0 ] && [ "$FAILED_SCANS" -eq 0 ]; then
        echo "No duplicate implementations found this week."
    elif [ "$FAILED_SCANS" -gt 0 ]; then
        echo "_Scan failures:_ $FAILED_SCANS / $SCAN_ATTEMPTS"
    fi
    echo
    echo "/af dispatched. Full report: $REPORT_FILE"
} > "$REPORT_FILE"

if [ -n "${SLACK_USER_TOKEN:-}" ] && [ "${SLACK_USER_TOKEN:-}" != "***" ]; then
    CHAN="${CLAW_DUP_CHANNEL:-C0AJQ5M0A0Y}"
    TEXT=$(cat "$REPORT_FILE")
    curl -fsS -X POST "https://slack.com/api/chat.postMessage" \
        -H "Authorization: Bearer ${SLACK_USER_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg c "$CHAN" --arg t "$TEXT" '{channel:$c, text:$t}')" \
        > /dev/null 2>&1 || log_warn "Slack post failed"
fi

log_info "Done. $FILED beads filed, $SKIPPED duplicates skipped, $CNT dup groups, $FAILED_SCANS/$SCAN_ATTEMPTS scans failed."

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