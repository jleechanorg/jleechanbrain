#!/bin/bash
# claw-codestandards-tuesday.sh — Weekly code-standards auditor (Tue 09:00 PT).
# Pattern: Boris Cherny "Abstraction Police" / Style-Cop routine — scan recent PRs
# AND the whole codebase for style + standards regressions; file one factory-labeled
# bead per finding.
#
# Scope (per user request 2026-08-14):
#   - PRs from the last 2 weeks across the same jleechanorg repo set
#   - Whole-codebase standards sweep (lint/typing/schema-coverage guard discipline,
#     prompt-tool-contract hash coverage, drift-detection hooks)
#
# Pipeline: /claw + /af (auto-factory drives the resulting factory-labeled beads).
#
# What it does:
#   1. Lane A — PR review (last 14 days): for each repo, fetch PRs opened in the
#      window, extract diff hunks + review-comment threads, dispatch an agent to
#      identify code-standards violations (style, naming, typing, docstring, error
#      handling, prompt-tool-contract drift). One finding per PR, cap 12 PRs.
#   2. Lane B — Whole-codebase sweep: one agent does a holistic scan across the
#      same repos for standards drift (TODO/FIXME density, naming inconsistencies,
#      missing typing, dead comments, hardcoded secrets). Cap 20 findings.
#   3. File ONE factory-labeled bead per finding.
#   4. Kick /af so the auto-factory daemon dispatches the fix PRs.
#
# Idempotent: re-runs are safe; the bead-dedup check (br ready) prevents floods.
# Exit codes: 0 = success (incl. zero findings), 1 = fatal preflight, 2 = some
# agent chunks failed (partial result posted), 3 = ALL scans failed (fatal).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERMES_HOME="${HERMES_HOME:-$HOME/.smartclaw}"
BUG_REPORTS_DIR="${CLAW_STANDARDS_OUT:-/tmp/claw-codestandards}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
REPORT_FILE="${BUG_REPORTS_DIR}/claw-standards-${TIMESTAMP}.md"

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
if ! command -v gh >/dev/null 2>&1; then
    log_err "gh CLI not found — install GitHub CLI first"
    exit 1
fi

# Source bashrc so the claudem bash function loads.
if [ -f "$HOME/.bashrc" ]; then
    # shellcheck disable=SC1090
    source "$HOME/.bashrc" 2>/dev/null || true
fi

# Strip ```json ... ``` markdown fences (same fix as the other claw-* routines —
# claudem's --output-format text sometimes wraps JSON in fences; without this
# `jq 'length'` returns 0 on a real payload).
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

# ---- Active-agent probe ----
ACTIVE_AGENTS=()
declare -A AGENT_MODELS
AGENT_MODELS[claude]="anthropic/claude-3-5-haiku"
AGENT_MODELS[gemini]="agy-shim/gpt-oss-120b-medium"
AGENT_MODELS[minimax]="MiniMax-M3"

for AGENT in claude gemini minimax; do
    MODEL="${AGENT_MODELS[$AGENT]}"
    if hermes -z "Hello" -m "$MODEL" >/dev/null 2>&1; then
        log_info "Probe OK: $AGENT ($MODEL)"
        ACTIVE_AGENTS+=("$AGENT")
    else
        log_warn "Probe FAIL: $AGENT ($MODEL) — skipping"
    fi
done
if [ "${#ACTIVE_AGENTS[@]}" -eq 0 ]; then
    log_err "No agents available — aborting"
    exit 1
fi

# ---- Lane A: PR-window review (last 14 days) ----
log_info "Lane A: PR-window review (last 14 days) per repo"
PR_FILE="${BUG_REPORTS_DIR}/claw-standards-pr-${TIMESTAMP}.json"
PR_ERR="${PR_FILE}.err"
FAILED_SCANS=0
SCAN_ATTEMPTS=0

if [ "${CLAW_SMOKE:-0}" = "1" ]; then
    log_info "CLAW_SMOKE=1 — skipping Lane A"
    PR_FILE="" ; CNT_PR=0
else
PROMPT_PR="Code-Standards review for PRs opened in the LAST 14 DAYS across these repos:
${REPOS[*]}

For each repo:
1. Pull open PRs via: gh pr list --repo OWNER/REPO --state all --limit 50 --json number,title,createdAt,author,headRefName,labels
2. Filter to PRs with createdAt within 14 days of today (date is $(date -u +%F)).
3. For up to 4 most-recent PRs, fetch the diff: gh pr diff <N> --repo OWNER/REPO
4. For each PR, classify any standards drift against this checklist:
   - Naming: snake_case vs camelCase inconsistency, mixed conventions in same file
   - Typing: missing type hints on public functions in .py, missing tsconfig strict on .ts/.tsx
   - Docstrings: missing module/function docstrings on public API surface
   - Error handling: bare except:, swallowed errors, return-None-on-error without log
   - Prompt-tool contracts: new mcp tool without schema entry in mvp_site/schemas/prompt_tool_contracts.json
   - Secrets: hardcoded tokens, raw .env values, gh_pat_<...> literals
   - Logging: print() instead of structured logger in non-script files
   - Comments: stale TODO/FIXME older than 6mo with no linked bead
5. Output JSON array: [{repo, pr_number, pr_title, file_path, line, category, finding, suggested_fix}]. Cap 12 entries total, highest-severity first.

Do NOT modify any files — read-only review. Return ONLY the JSON array."

if ! bash -lic "claudem -p \"\$1\" --output-format text --max-turns 30" _ "$PROMPT_PR" \
    > "$PR_FILE" 2> "$PR_ERR"; then
    log_warn "Lane A (PR review) failed — see $PR_ERR"
    FAILED_SCANS=$((FAILED_SCANS + 1))
    CNT_PR=0
fi
SCAN_ATTEMPTS=$((SCAN_ATTEMPTS + 1))

strip_json_fences "$PR_FILE"
CNT_PR=$(jq 'length' "$PR_FILE" 2>/dev/null || echo "0")
log_info "Lane A: $CNT_PR PR-window standards findings"
fi

# ---- Lane B: Whole-codebase sweep ----
log_info "Lane B: Whole-codebase standards sweep per repo"
BASE_FILE="${BUG_REPORTS_DIR}/claw-standards-codebase-${TIMESTAMP}.json"
BASE_ERR="${BASE_FILE}.err"

if [ "${CLAW_SMOKE:-0}" = "1" ]; then
    log_info "CLAW_SMOKE=1 — skipping Lane B"
    BASE_FILE="" ; CNT_BASE=0
else
PROMPT_BASE="Code-Standards WHOLE-CODEBASE sweep across these repos:
${REPOS[*]}

For each repo, scan the WHOLE codebase (not just recent PRs) for accumulated standards drift:
1. Naming: ripgrep for mixed snake_case + camelCase in same Python file (rg -nP 'def [a-z]+[A-Z]' .)
2. Typing: ripgrep for 'def [a-z_]+\(.*\):' with no return type annotation in public functions
3. Docstrings: find public functions/classes without docstrings (rg -L '\"\"\"' --files-without-match may help; or sample 20 random modules and check)
4. Error handling: rg -n 'except\s*:' bare except / rg -n 'except Exception' that swallows
5. Secrets: rg -nP 'gh_pat_|xox[bps]-|sk-[a-zA-Z0-9]{20,}' — any literal matches
6. Logging: rg -nL 'logger = logging.getLogger' on .py files that contain print(
7. Stale comments: rg -n 'TODO|FIXME|XXX' older than 6 months (git blame -L <line>,<line> FILE)
8. Prompt-tool contracts: diff between mcp tool definitions and mvp_site/schemas/prompt_tool_contracts.json entries
9. Drift-detection hooks: confirm scripts/check_drift*.sh / scripts/audit_*.sh exist and were touched in last 30 days

Output JSON array: [{repo, file_path, line, category, finding, suggested_fix, severity 0-3}]. Cap 20 entries, highest-severity first.

Do NOT modify any files. Read-only. Return ONLY the JSON array."

if ! bash -lic "claudem -p \"\$1\" --output-format text --max-turns 30" _ "$PROMPT_BASE" \
    > "$BASE_FILE" 2> "$BASE_ERR"; then
    log_warn "Lane B (codebase sweep) failed — see $BASE_ERR"
    FAILED_SCANS=$((FAILED_SCANS + 1))
    CNT_BASE=0
fi
SCAN_ATTEMPTS=$((SCAN_ATTEMPTS + 1))

strip_json_fences "$BASE_FILE"
CNT_BASE=$(jq 'length' "$BASE_FILE" 2>/dev/null || echo "0")
log_info "Lane B: $CNT_BASE whole-codebase standards findings"
fi

TOTAL=$((CNT_PR + CNT_BASE))

# ---- File ONE factory-labeled bead per finding ----
log_info "Filing factory-labeled beads (total findings: $TOTAL)"

FILED=0
SKIPPED=0
declare -a FINDING_REPOS=()
declare -a FINDING_COUNTS=()

# P1 #4 — bead dedup. Build a set of existing open factory-labeled bead titles
# once so per-finding lookups are O(1). We match by exact title (the canonical
# claw-standards-{pr,codebase}: <repo> <path> <cat> form) AND by path+category
# substring so a manual renumber doesn't defeat dedup.
EXISTING_BEAD_TITLES="$(br list --label factory --limit 500 --format json 2>/dev/null | jq -r '.[].title // empty' 2>/dev/null || true)"
EXISTING_DEDUP_KEYS="$(br list --label factory --limit 500 --format json 2>/dev/null \
    | jq -r '.[] | (.title // "")' 2>/dev/null \
    | grep -oE 'claw-standards-(pr|codebase): [^ ]+ [^ ]+ \([^)]+\)' \
    || true)"
bead_already_filed_pr() {
    local title="$1" repo="$2" path="$3" cat="$4"
    if [ -n "$EXISTING_DEDUP_KEYS" ] && echo "$EXISTING_DEDUP_KEYS" | grep -qF "claw-standards-pr: $repo $path ($cat)"; then
        return 0
    fi
    if [ -n "$EXISTING_BEAD_TITLES" ] && echo "$EXISTING_BEAD_TITLES" | grep -qFx "$title"; then
        return 0
    fi
    return 1
}
bead_already_filed_base() {
    local title="$1" repo="$2" path="$3" cat="$4"
    if [ -n "$EXISTING_DEDUP_KEYS" ] && echo "$EXISTING_DEDUP_KEYS" | grep -qF "claw-standards-codebase: $repo $path ($cat)"; then
        return 0
    fi
    if [ -n "$EXISTING_BEAD_TITLES" ] && echo "$EXISTING_BEAD_TITLES" | grep -qFx "$title"; then
        return 0
    fi
    return 1
}

if [ "$CNT_PR" -gt 0 ] && [ -n "$PR_FILE" ]; then
    REPO_FILED=0
    while IFS=$'\t' read -r repo pr_num pr_title file line cat finding fix; do
        # P1 #4 — skip if a matching bead already exists
        if bead_already_filed_pr "claw-standards-pr: $repo PR#$pr_num $cat" "$repo" "$file" "$cat"; then
            SKIPPED=$((SKIPPED + 1))
            continue
        fi
        BEAD_BODY="Standards drift in PR $pr_num ($pr_title) at $repo:$file:$line [$cat]. $finding. Suggested fix: $fix. Detected by claw-codestandards-tuesday Lane A $(date -u +%F). target_repo: $repo."
        if br create "claw-standards-pr: $repo PR#$pr_num $cat" \
            --type chore --priority 2 --label factory --description "$BEAD_BODY" \
            > /dev/null 2>&1; then
            FILED=$((FILED + 1))
            REPO_FILED=$((REPO_FILED + 1))
        fi
    done < <(jq -r '.[] | "\(.repo)\t\(.pr_number // "?")\t(.pr_title // "")\t\(.file_path // "?")\t\(.line // 0)\t\(.category // "unknown")\t(.finding // "")\t(.suggested_fix // "")"' "$PR_FILE" 2>/dev/null)
    if [ "$REPO_FILED" -gt 0 ]; then
        FINDING_REPOS+=("PR-window(${#REPOS[@]} repos)")
        FINDING_COUNTS+=("$REPO_FILED")
    fi
fi

if [ "$CNT_BASE" -gt 0 ] && [ -n "$BASE_FILE" ]; then
    REPO_FILED=0
    while IFS=$'\t' read -r repo file line cat finding fix sev; do
        # P1 #4 — skip if a matching bead already exists
        if bead_already_filed_base "claw-standards-codebase: $repo $file:$line ($cat)" "$repo" "$file" "$cat"; then
            SKIPPED=$((SKIPPED + 1))
            continue
        fi
        BEAD_BODY="Standards drift in $repo at $file:$line [$cat, sev=$sev]. $finding. Suggested fix: $fix. Detected by claw-codestandards-tuesday Lane B $(date -u +%F). target_repo: $repo."
        if br create "claw-standards-codebase: $repo $file:$line ($cat)" \
            --type chore --priority 2 --label factory --description "$BEAD_BODY" \
            > /dev/null 2>&1; then
            FILED=$((FILED + 1))
            REPO_FILED=$((REPO_FILED + 1))
        fi
    done < <(jq -r '.[] | "\(.repo)\t\(.file_path // "?")\t\(.line // 0)\t\(.category // "unknown")\t(.finding // "")\t(.suggested_fix // "")\t(.severity // 1)"' "$BASE_FILE" 2>/dev/null)
    if [ "$REPO_FILED" -gt 0 ]; then
        FINDING_REPOS+=("Codebase-sweep(${#REPOS[@]} repos)")
        FINDING_COUNTS+=("$REPO_FILED")
    fi
fi

# ---- /af overlay ----
DF_TICK="$HOME/projects/dark-factory/daemon/factory-af-tick.sh"
DF_BIN="$HOME/projects/dark-factory/bin/dark-factory"
if [ "${CLAW_SMOKE:-0}" = "1" ]; then
    log_info "CLAW_SMOKE=1 — skipping /af dispatch (smoke mode)"
elif [ -x "$DF_TICK" ]; then
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
    echo "*claw-codestandards-tuesday — $TIMESTAMP*"
    echo
    echo "*Repos scanned:* ${REPOS[*]}"
    echo "*Lane A (PR-window last 14d):* $CNT_PR findings"
    echo "*Lane B (whole-codebase sweep):* $CNT_BASE findings"
    echo "*Beads filed:* $FILED"
    echo "*Beads skipped (duplicate):* $SKIPPED"
    echo "*Scan attempts:* $SCAN_ATTEMPTS"
    echo "*Scan failures:* $FAILED_SCANS"
    echo "*Agents:* ${ACTIVE_AGENTS[*]}"
    echo
    if [ "$TOTAL" -eq 0 ] && [ "$FAILED_SCANS" -eq 0 ]; then
        echo "No standards drift found this week."
    elif [ "$FAILED_SCANS" -gt 0 ]; then
        echo "_Scan failures:_ $FAILED_SCANS / $SCAN_ATTEMPTS"
    fi
    if [ "$TOTAL" -gt 0 ]; then
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
    CHAN="${CLAW_STANDARDS_CHANNEL:-C0AJQ5M0A0Y}"  # #ai-general
    TEXT=$(cat "$REPORT_FILE")
    curl -fsS -X POST "https://slack.com/api/chat.postMessage" \
        -H "Authorization: Bearer ${SLACK_USER_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg c "$CHAN" --arg t "$TEXT" '{channel:$c, text:$t}')" \
        > /dev/null 2>&1 || log_warn "Slack post failed"
fi

log_info "Done. $FILED beads filed, $SKIPPED duplicates skipped, $TOTAL findings, $FAILED_SCANS/$SCAN_ATTEMPTS scans failed."

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
if [ "${CLAW_SMOKE:-0}" = "1" ]; then exit 0; fi
exit "$SCAN_EXIT"