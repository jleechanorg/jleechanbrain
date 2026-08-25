#!/bin/bash
# Daily bug hunt job - runs at 9am
# Spawns multiple agents to find bugs in PRs merged in the last 2 days
# Creates bug reports, beads, and posts to #bug-hunt channel

set -euo pipefail
set -m  # enable job control so background workers get their own process groups

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH_SAFE_PUBLISH="$SCRIPT_DIR/gh-safe-publish"
OUTBOUND_SECRET_GATE="$SCRIPT_DIR/../lib/outbound_secret_gate.py"

# Configuration - output bug reports to /tmp to avoid polluting the repo
# with large agent outputs; script itself stays in scripts/
BUG_REPORTS_DIR="${BUG_REPORTS_DIR:-/tmp/hermes/bug_reports}"
REPOS=("jleechanorg/jleechanbrain" "jleechanorg/worldarchitect.ai" "jleechanorg/ai_universe" "jleechanorg/beads")
DAYS_LOOKBACK=2
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REPORT_FILE="${BUG_REPORTS_DIR}/bug-hunt-${TIMESTAMP}.md"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Attempt to salvage a valid JSON array from a truncated output file.
# Tries json_repair (if installed), then manually cuts at the last complete '}'.
# Prints repaired JSON to stdout; exits 0 on success, 1 on unrecoverable.
repair_truncated_json() {
    local file="$1"
    python3 - "$file" <<'PYEOF'
import json, sys, re

try:
    content = open(sys.argv[1]).read()
except Exception:
    sys.exit(1)

# Fast path: already valid JSON
try:
    data = json.loads(content)
    print(json.dumps(data))
    sys.exit(0)
except json.JSONDecodeError:
    pass

# Attempt json_repair if the library is installed
try:
    from json_repair import repair_json
    repaired = repair_json(content, return_objects=True)
    if isinstance(repaired, list):
        print(json.dumps(repaired))
        sys.exit(0)
except ImportError:
    pass

# Salvage: walk back from the error to the last complete object boundary '}'
try:
    json.loads(content)
except json.JSONDecodeError as err:
    truncated = content[:err.pos]
    last_brace = truncated.rfind('}')
    if last_brace < 0:
        sys.exit(1)
    candidate = re.sub(r',\s*$', '', truncated[:last_brace + 1].rstrip()) + ']'
    if not candidate.lstrip().startswith('['):
        candidate = '[' + candidate
    try:
        salvaged = json.loads(candidate)
        if isinstance(salvaged, list):
            print(json.dumps(salvaged))
            sys.exit(0)
    except json.JSONDecodeError:
        pass

sys.exit(1)
PYEOF
}

terminate_process_tree() {
    local pid="$1"
    local pgid current_pgid

    pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d '[:space:]' || true)
    current_pgid=$(ps -o pgid= -p "$$" 2>/dev/null | tr -d '[:space:]' || true)

    if [ -n "$pgid" ] && [ "$pgid" != "$current_pgid" ]; then
        kill -TERM "-$pgid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
    else
        kill -TERM "$pid" 2>/dev/null || true
    fi
}

# Ensure bug_reports directory exists
mkdir -p "$BUG_REPORTS_DIR"

log_info "Starting daily bug hunt..."

# Get PRs merged in the last N days
# Classify an `gh` failure into a short, actionable label.
# Echoes one of: "graphql_rate_limit" | "connection" | "auth" | "other".
# Reads the failure text on stdin (or "$1").
classify_gh_failure() {
    local msg="${1:-$(cat)}"
    case "$msg" in
        *"API rate limit"*|*"rate limit already exceeded"*|*"exceeded the rate limit"*)
            echo "graphql_rate_limit" ;;
        *"Could not resolve host"*|*"Connection refused"*|*"network is unreachable"*|*"connection reset"*|*"connection timed out"*|*"TLS handshake"*)
            echo "connection" ;;
        *"Bad credentials"*|*"401"*|*"authentication"*|*"GH_TOKEN"*|*"GITHUB_TOKEN"*)
            echo "auth" ;;
        *)
            echo "other" ;;
    esac
}

# Discover merged PRs in the last DAYS_LOOKBACK days for a single repo.
# Uses `gh pr list --json` (GraphQL) first; on GraphQL rate-limit failure falls
# back to REST `gh api /repos/.../pulls?state=closed` (core bucket is separate).
# Echoes JSON array of {number,title,url,mergedAt,repo}.
# On hard failure, sets GLOBAL vars:
#   GET_PRS_FAIL_CLASS  — output of classify_gh_failure
#   GET_PRS_FAIL_MSG    — first stderr line for the alert
# Returns 1 on hard failure, 0 on success (possibly empty array).
get_merged_prs() {
    local repo="$1"
    local since_date=$(date -v-${DAYS_LOOKBACK}d '+%Y-%m-%d' 2>/dev/null || date -d "${DAYS_LOOKBACK} days ago" '+%Y-%m-%d')
    local gh_out=$(mktemp)
    local gh_err=$(mktemp)
    GET_PRS_FAIL_CLASS=""
    GET_PRS_FAIL_MSG=""

    # Primary path: gh pr list --json hits GitHub GraphQL.
    if gh pr list --repo "$repo" --state merged --limit 100 --json number,title,url,mergedAt > "$gh_out" 2>"$gh_err"; then
        if jq --arg since "$since_date" --arg repo "$repo" \
            '[.[] | select(.mergedAt >= $since) | . + {repo: $repo}]' "$gh_out"; then
            rm -f "$gh_out" "$gh_err"
            return 0
        fi
        # jq filter failed — fall through to REST
    fi
    local primary_err
    primary_err=$(head -n 3 "$gh_err" 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g')
    local primary_class
    primary_class=$(classify_gh_failure "$primary_err")

    # REST fallback: pulls via REST uses the `core` bucket, separate from GraphQL.
    # Only worth retrying when the failure was a transient rate-limit or connection
    # issue. Auth / permission / "other" failures won't be fixed by switching API.
    if [ "$primary_class" != "graphql_rate_limit" ] && [ "$primary_class" != "connection" ]; then
        GET_PRS_FAIL_CLASS="$primary_class"
        GET_PRS_FAIL_MSG="$primary_err"
        rm -f "$gh_out" "$gh_err"
        return 1
    fi

    local rest_out rest_err
    rest_out=$(mktemp)
    rest_err=$(mktemp)
    if ! gh api "repos/${repo}/pulls?state=closed&sort=updated&direction=desc&per_page=100" > "$rest_out" 2>"$rest_err"; then
        local rest_err_msg
        rest_err_msg=$(head -n 3 "$rest_err" 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g')
        GET_PRS_FAIL_CLASS="$primary_class"
        GET_PRS_FAIL_MSG="GraphQL: ${primary_err}; REST fallback: ${rest_err_msg}"
        rm -f "$gh_out" "$gh_err" "$rest_out" "$rest_err"
        return 1
    fi

    # REST returns merged_at as ISO 8601; filter to merged & since_date, then
    # shape into the same {number,title,url,mergedAt,repo} objects gh pr list emits.
    local shaped
    shaped=$(jq --arg since "$since_date" --arg repo "$repo" '
        [ .[]
          | select(.merged_at != null)
          | select(.merged_at >= $since)
          | {number: .number, title: .title, url: .html_url, mergedAt: .merged_at, repo: $repo}
        ]' "$rest_out" 2>/dev/null)
    local jq_rc=$?
    if [ "$jq_rc" -ne 0 ] || [ -z "$shaped" ]; then
        GET_PRS_FAIL_CLASS="other"
        GET_PRS_FAIL_MSG="REST fallback returned but jq shape failed"
        rm -f "$gh_out" "$gh_err" "$rest_out" "$rest_err"
        return 1
    fi
    echo "$shaped"
    rm -f "$gh_out" "$gh_err" "$rest_out" "$rest_err"
    return 0
}

# Initialize report file
cat > "$REPORT_FILE" << EOF
# Bug Hunt Report - ${TIMESTAMP}

**Generated:** $(date)
**Period:** Last ${DAYS_LOOKBACK} days
**Agents:** claude, gemini, minimax

---

EOF

# Track all findings
TOTAL_PRS=0
FINDINGS=""
PRS_JSON="[]"
# Per-repo PR discovery failures (so a transient hiccup on one repo does not
# abort the whole run; the script continues with whichever repos succeed and
# reports the rest in the Slack/email/issue body).
declare -a REPO_FAIL_CLASSES=()
declare -a REPO_FAIL_REPOS=()
declare -a REPO_FAIL_MSGS=()

# Outbound publishing helper
post_report_outbound() {
    # Verification-only bypass: skip all outbound I/O when requested
    if [ "${BUG_HUNT_DISABLE_PUBLISH:-0}" = "1" ]; then
        log_info "BUG_HUNT_DISABLE_PUBLISH=1 — skipping Slack/GitHub publish"
        return 0
    fi

    # Scan the exact report once before either Slack or GitHub can transport it.
    if ! printf '%s' "$SLACK_MESSAGE" | python3 "$OUTBOUND_SECRET_GATE" check; then
        log_error "Outbound report blocked by secret gate; redact the report before retrying"
        exit 3
    fi

    # Post to Slack using user token (so Hermes gateway will react to @hermes mentions)
    local slack_posted=0
    # Only source profile when token not already set — preserves caller-provided env values
    if [ -z "${SLACK_USER_TOKEN:-}" ] && [ -f "$HOME/.profile" ]; then
        source "$HOME/.profile" 2>/dev/null || true
    fi
    # Reject redacted placeholder tokens — sending *** as a Bearer token silently fails
    if [ "${SLACK_USER_TOKEN:-}" = "***" ]; then
        log_warn "SLACK_USER_TOKEN is a redacted placeholder (***) — skipping Slack notification"
    elif [ -n "${SLACK_USER_TOKEN:-}" ]; then
        local slack_channel_id="${BUG_HUNT_SLACK_CHANNEL_ID:-C0AJQ5M0A0Y}"  # default to #ai-general
        local slack_response=""
        if slack_response=$(curl -s -X POST "https://slack.com/api/chat.postMessage" \
            -H "Authorization: Bearer $SLACK_USER_TOKEN" \
            -H "Content-Type: application/json" \
            -d "{\"channel\":\"$slack_channel_id\",\"text\":$(echo "$SLACK_MESSAGE" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')}") \
            && echo "$slack_response" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('ok') else 1)" 2>/dev/null; then
            slack_posted=1
        else
            log_warn "Failed to post to Slack: $(echo "$slack_response" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error','unknown'))" 2>/dev/null || echo "${slack_response:-curl failed}")"
        fi
    else
        log_warn "SLACK_USER_TOKEN not set — skipping Slack notification"
    fi

    # Fallback to GitHub issue only when Slack was not posted
    if [ "$slack_posted" -ne 1 ]; then
        "$GH_SAFE_PUBLISH" issue create --title "Bug Hunt Report - $TIMESTAMP" \
            --body "$SLACK_MESSAGE" \
            --repo "${REPOS[0]}" 2>/dev/null || log_warn "Failed to create GitHub issue"
    fi
}

# Process each repo
for REPO in "${REPOS[@]}"; do
    log_info "Checking $REPO for merged PRs..."
    
    REPO_PRS_FILE=$(mktemp)
    ERR_FILE_TMP=$(mktemp)
    
    if ! get_merged_prs "$REPO" > "$REPO_PRS_FILE" 2> "$ERR_FILE_TMP"; then
        ERR_MSG=$(cat "$ERR_FILE_TMP" | head -n 5)
        rm -f "$REPO_PRS_FILE" "$ERR_FILE_TMP"
        FAIL_CLASS="${GET_PRS_FAIL_CLASS:-other}"
        FAIL_DETAIL="${GET_PRS_FAIL_MSG:-$ERR_MSG}"
        log_error "Failed to discover PRs for $REPO (class=$FAIL_CLASS): $FAIL_DETAIL"

        # Record for the post-run summary; keep going with the next repo.
        REPO_FAIL_REPOS+=("$REPO")
        REPO_FAIL_CLASSES+=("$FAIL_CLASS")
        REPO_FAIL_MSGS+=("$FAIL_DETAIL")

        # Append to the markdown report file regardless of Slack post.
        cat >> "$REPORT_FILE" << EOF
## PR Discovery Failure: $REPO

- Class: \`$FAIL_CLASS\`
- Detail: \`$FAIL_DETAIL\`

EOF
        continue
    fi
    
    REPO_PRS=$(cat "$REPO_PRS_FILE")
    rm -f "$REPO_PRS_FILE" "$ERR_FILE_TMP"
    
    PRS_JSON=$(echo "$PRS_JSON" | jq --argjson new "$REPO_PRS" '. + $new')
    PR_COUNT=$(echo "$REPO_PRS" | jq 'length' 2>/dev/null || echo "0")
    
    if [ "$PR_COUNT" -eq 0 ]; then
        log_info "No PRs merged in $REPO in the last $DAYS_LOOKBACK days"
        continue
    fi
    
    log_info "Found $PR_COUNT merged PRs in $REPO"
    
    # For each PR, prepare bug-hunting task (tab-separated to handle titles with '|')
    while IFS=$'\t' read -r pr_num pr_title pr_url; do
        log_info "Preparing bug hunt for $REPO PR #$pr_num: $pr_title"

        # Add to findings (Slack mrkdwn <url|text> avoids url (url) duplication)
        FINDINGS+="- <$pr_url|$REPO PR #$pr_num>: $pr_title\n"
        TOTAL_PRS=$((TOTAL_PRS + 1))
    done < <(echo "$REPO_PRS" | jq -r '.[] | "\(.number)\t\(.title)\t\(.url)"')
done

# Build a Slack-friendly summary of any per-repo PR discovery failures so the
# human can tell at a glance whether the issue is the GraphQL bucket (transient),
# a connection problem, auth, or something else.
build_discovery_failure_summary() {
    local summary=""
    local i repo fail_class fail_msg
    for i in "${!REPO_FAIL_REPOS[@]}"; do
        repo="${REPO_FAIL_REPOS[$i]}"
        fail_class="${REPO_FAIL_CLASSES[$i]}"
        fail_msg="${REPO_FAIL_MSGS[$i]}"
        summary+="- \`$repo\` → $fail_class — $fail_msg\n"
    done
    printf '%s' "$summary"
}

# If EVERY repo failed to return PRs, post a discovery-failure alert now and
# exit cleanly (exit 4 distinguishes "all repos hit API errors" from the
# agent-failure exit 2 further down). Avoids a silent "0 PRs reviewed" report
# that masks the real reason nothing was reviewed.
REPO_COUNT="${#REPOS[@]}"
FAIL_COUNT="${#REPO_FAIL_REPOS[@]}"
if [ "$TOTAL_PRS" -eq 0 ] && [ "$FAIL_COUNT" -gt 0 ] && [ "$FAIL_COUNT" -eq "$REPO_COUNT" ]; then
    log_error "All $REPO_COUNT repos failed PR discovery — aborting before agent dispatch"

    FAILURE_SUMMARY=$(build_discovery_failure_summary)
    GRAPHQL_RL_COUNT=0
    for fc in "${REPO_FAIL_CLASSES[@]}"; do
        [ "$fc" = "graphql_rate_limit" ] && GRAPHQL_RL_COUNT=$((GRAPHQL_RL_COUNT + 1))
    done
    HEADLINE=":warning: *All $REPO_COUNT repos failed PR discovery*"
    if [ "$GRAPHQL_RL_COUNT" -gt 0 ]; then
        HEADLINE="$HEADLINE (GraphQL bucket likely exhausted — REST fallback also hit limit). Next scheduled run will retry."
    fi

    SLACK_MESSAGE="*Daily Bug Hunt Report - ${TIMESTAMP}*

*Repos scanned:* ${REPOS[*]}
*Period:* Last ${DAYS_LOOKBACK} days
*Status:* :red_circle: $HEADLINE

*Failures (${FAIL_COUNT}/${REPO_COUNT}):*
${FAILURE_SUMMARY}
Check logs in \$HOME/.smartclaw/logs/bug-hunt-daily.error.log"

    post_report_outbound
    exit 4
fi

# Truthful no-input run check
if [ "$TOTAL_PRS" -eq 0 ]; then
    log_info "No PRs found to review."
    
    cat >> "$REPORT_FILE" << EOF
## PR Findings

No merged PRs found in the last $DAYS_LOOKBACK days.

## Results

- PRs reviewed: 0
- Bugs found: 0
- Agent failures: 0/0
EOF

    # If any repos failed PR discovery while the rest returned zero PRs,
    # surface it. The "all repos failed" case has already exited above.
    DISCOVERY_BLOCK=""
    if [ "${FAIL_COUNT:-0}" -gt 0 ]; then
        DISCOVERY_BLOCK=$(build_discovery_failure_summary)
    fi

    SLACK_MESSAGE="*Daily Bug Hunt Report - ${TIMESTAMP}*

*Repos scanned:* ${REPOS[*]}
*Period:* Last ${DAYS_LOOKBACK} days
*Agents deployed:* None (no merged PRs found)

*Results:*
- PRs reviewed: 0
- Bugs found: 0
- Agent failures: 0/0"
    if [ "${FAIL_COUNT:-0}" -gt 0 ]; then
        SLACK_MESSAGE="${SLACK_MESSAGE}
- Repos failed PR discovery: ${FAIL_COUNT}/${REPO_COUNT}
${DISCOVERY_BLOCK}"
    fi
    SLACK_MESSAGE="${SLACK_MESSAGE}

*Reports:* $REPORT_FILE"

    post_report_outbound
    
    log_info "Bug hunt complete (no-input run)."
    exit 0
fi

# Preflight checks for models to deploy explicitly
if ! command -v hermes >/dev/null 2>&1; then
    log_error "hermes CLI not found. Fail closed."
    exit 1
fi

log_info "Running model preflight checks..."
ACTIVE_AGENTS=()
declare -A AGENT_MODELS
AGENT_MODELS[claude]="anthropic/claude-3-5-haiku"
AGENT_MODELS[gemini]="agy-shim/gpt-oss-120b-medium"
AGENT_MODELS[minimax]="MiniMax-M3"

for AGENT in "claude" "gemini" "minimax"; do
    MODEL="${AGENT_MODELS[$AGENT]}"
    log_info "Probing model $MODEL for $AGENT..."
    if hermes -z "Hello" -m "$MODEL" >/dev/null 2>&1; then
        log_info "Model $MODEL is available for $AGENT."
        ACTIVE_AGENTS+=("$AGENT")
    else
        log_warn "Model $MODEL is NOT available for $AGENT. Skipping."
    fi
done

if [ "${#ACTIVE_AGENTS[@]}" -eq 0 ]; then
    log_error "All model preflight checks failed. No available agents."
    exit 1
fi

# Chunk PRs and spawn one hermes call per chunk (round-robin across active agents).
# BUG_HUNT_CHUNK_SIZE caps monolithic prompts that always exceed per-lane budgets.
# July-29 incident: 32 PRs × 1 lane = 32-PR prompt, timed out every agent in 10 min.
BUG_HUNT_CHUNK_SIZE="${BUG_HUNT_CHUNK_SIZE:-10}"
log_info "Spawning bug hunt chunks (chunk_size=${BUG_HUNT_CHUNK_SIZE}, agents=${ACTIVE_AGENTS[*]})..."

AGENT_PIDS=()
CHUNK_OUTPUT_FILES=()
CHUNK_PR_COUNTS=()   # parallel: PRs in each chunk (for reviewed-vs-discovered accounting)
CHUNK_EXIT_FILES=()  # parallel: per-chunk hermes exit code files
CHUNK_MODELS=()      # parallel: model used per chunk (for proven-model detection)
CHUNK_JSONS=()       # parallel: PR JSON per chunk (needed for retry prompt)
CHUNK_IDX=0
AGENT_COUNT="${#ACTIVE_AGENTS[@]}"
TOTAL_PR_COUNT=$(echo "$PRS_JSON" | jq 'length')
TOTAL_CHUNKS=$(( (TOTAL_PR_COUNT + BUG_HUNT_CHUNK_SIZE - 1) / BUG_HUNT_CHUNK_SIZE ))

while true; do
    OFFSET=$(( CHUNK_IDX * BUG_HUNT_CHUNK_SIZE ))
    [ "$OFFSET" -ge "$TOTAL_PR_COUNT" ] && break

    CHUNK_JSON=$(echo "$PRS_JSON" | jq --argjson off "$OFFSET" --argjson sz "$BUG_HUNT_CHUNK_SIZE" '.[$off:$off+$sz]')
    CHUNK_LEN=$(echo "$CHUNK_JSON" | jq 'length')
    [ "$CHUNK_LEN" -eq 0 ] && break

    AGENT="${ACTIVE_AGENTS[$((CHUNK_IDX % AGENT_COUNT))]}"
    MODEL="${AGENT_MODELS[$AGENT]}"
    OUTPUT_FILE="${BUG_REPORTS_DIR}/bug-hunt-chunk${CHUNK_IDX}-${AGENT}-${TIMESTAMP}.json"
    ERR_FILE="${BUG_REPORTS_DIR}/bug-hunt-chunk${CHUNK_IDX}-${AGENT}-${TIMESTAMP}.err"
    EXIT_FILE="${BUG_REPORTS_DIR}/bug-hunt-chunk${CHUNK_IDX}-${AGENT}-${TIMESTAMP}.exit"
    CHUNK_OUTPUT_FILES+=("$OUTPUT_FILE")
    CHUNK_PR_COUNTS+=("$CHUNK_LEN")
    CHUNK_EXIT_FILES+=("$EXIT_FILE")
    CHUNK_MODELS+=("$MODEL")
    CHUNK_JSONS+=("$CHUNK_JSON")

    log_info "Chunk $((CHUNK_IDX+1))/${TOTAL_CHUNKS}: $CHUNK_LEN PRs → $AGENT ($MODEL)"

    TASK_PROMPT="Bug Hunt Task (chunk $((CHUNK_IDX+1)) of ${TOTAL_CHUNKS}):

Analyze these merged PRs for bugs:
$CHUNK_JSON

For each PR:
1. Use 'gh pr diff <number> --repo <repo>' to fetch the code changes
2. Examine the diff for:
   - Logic bugs (null checks missing, edge cases)
   - Error handling issues
   - Memory leaks or resource issues
   - Security vulnerabilities
   - Race conditions
   - Type errors

Return findings as structured JSON wrapped in one markdown code fence. Every
finding MUST cite evidence from the fetched diff and test surface. An empty
array is valid only after reviewing every supplied PR:
\`\`\`json
[
  {
    \"repo\": \"...\",
    \"pr\": 123,
    \"file\": \"path/to/file\",
    \"line\": 42,
    \"severity\": 1,
    \"description\": \"...\",
    \"suggested_fix\": \"...\",
    \"evidence\": {
      \"diff_excerpt\": \"exact changed-code excerpt\",
      \"test_impact\": \"specific existing or missing test and why it matters\",
      \"reproduction_or_reasoning\": \"concrete failing scenario or proof chain\"
    }
  }
]
\`\`\`
"

    (
        _hermes_rc=0
        _raw="$(mktemp)"
        hermes -z "$TASK_PROMPT" -m "$MODEL" > "$_raw" 2>>"$ERR_FILE" || _hermes_rc=$?
        echo "$_hermes_rc" > "$EXIT_FILE"
        [ "$_hermes_rc" -ne 0 ] && echo "hermes exit $_hermes_rc (chunk $((CHUNK_IDX+1)) $AGENT $MODEL)" >> "$ERR_FILE"
        perl -0777 -ne 'print $1 if /```json\n?(.*?)\n?```/s' < "$_raw" > "$OUTPUT_FILE" || true
        rm -f "$_raw"
    ) &

    AGENT_PIDS+=($!)
    CHUNK_IDX=$(( CHUNK_IDX + 1 ))
done

# Wait for ALL chunks concurrently under one global deadline.
# Sequential per-PID watchdogs caused July-29 incident: 3×10 min = 30 min worst-case.
GLOBAL_DEADLINE_SECONDS="${GLOBAL_DEADLINE_SECONDS:-600}"
if [ "${#AGENT_PIDS[@]}" -eq 0 ]; then
    log_warn "No bug hunt chunk processes were started"
else
    log_info "Waiting for ${#AGENT_PIDS[@]} chunk(s) (global deadline: ${GLOBAL_DEADLINE_SECONDS}s)..."
    (
        sleep "$GLOBAL_DEADLINE_SECONDS"
        for _PID in "${AGENT_PIDS[@]}"; do
            terminate_process_tree "$_PID" 2>/dev/null || true
        done
    ) >/dev/null 2>&1 &
    DEADLINE_PID=$!
    for _WIDX in "${!AGENT_PIDS[@]}"; do
        _WPID="${AGENT_PIDS[$_WIDX]}"
        _wrc=0
        wait "$_WPID" 2>/dev/null || _wrc=$?
        if [ "$_wrc" -ne 0 ]; then
            log_warn "Chunk $((_WIDX+1)) PID $_WPID exited $_wrc (killed by deadline or hermes error)"
        fi
    done
    kill "$DEADLINE_PID" 2>/dev/null || true
    wait "$DEADLINE_PID" 2>/dev/null || true
fi

# Second-pass retry: failed chunks re-run on the first proven surviving model.
# Set BUG_HUNT_DISABLE_RETRY=1 to skip (useful for deterministic tests / debugging).
# A chunk is "proven" if it produced non-empty output in the first pass.
# Retry writes to the same OUTPUT_FILE so the aggregation loop below is unchanged.
# BUG_HUNT_RETRY_DEADLINE_SECONDS bounds the retry pass independently.
if [ "${BUG_HUNT_DISABLE_RETRY:-0}" = "1" ]; then
    log_info "BUG_HUNT_DISABLE_RETRY=1 — skipping second-pass retry"
else
PROVEN_MODEL=""
for _CIDX in "${!CHUNK_OUTPUT_FILES[@]}"; do
    if [ -s "${CHUNK_OUTPUT_FILES[$_CIDX]}" ] && jq empty "${CHUNK_OUTPUT_FILES[$_CIDX]}" 2>/dev/null; then
        PROVEN_MODEL="${CHUNK_MODELS[$_CIDX]}"
        log_info "Proven surviving model: $PROVEN_MODEL (chunk $((_CIDX+1)) produced valid output)"
        break
    fi
done

RETRY_PIDS=()
RETRY_CHUNK_INDICES=()
if [ -n "$PROVEN_MODEL" ]; then
    BUG_HUNT_RETRY_DEADLINE_SECONDS="${BUG_HUNT_RETRY_DEADLINE_SECONDS:-$GLOBAL_DEADLINE_SECONDS}"
    for _CIDX in "${!CHUNK_OUTPUT_FILES[@]}"; do
        _retry_out="${CHUNK_OUTPUT_FILES[$_CIDX]}"
        _needs_retry=0
        if [ ! -s "$_retry_out" ]; then
            _needs_retry=1
        elif ! jq empty "$_retry_out" 2>/dev/null; then
            log_warn "Chunk $((_CIDX+1)): truncated/invalid JSON — queuing for retry on $PROVEN_MODEL"
            _needs_retry=1
        fi
        if [ "$_needs_retry" = "1" ]; then
            _retry_len="${CHUNK_PR_COUNTS[$_CIDX]:-0}"
            _retry_json="${CHUNK_JSONS[$_CIDX]}"
            _retry_err="${_retry_out%.json}-retry.err"
            _retry_exit="${_retry_out%.json}-retry.exit"
            log_info "Retry chunk $((_CIDX+1)) ($_retry_len PRs) on proven model $PROVEN_MODEL..."
            _RETRY_PROMPT="Bug Hunt Task (retry chunk $((_CIDX+1))):

Analyze these merged PRs for bugs:
$_retry_json

For each PR:
1. Use 'gh pr diff <number> --repo <repo>' to fetch the code changes
2. Examine the diff for:
   - Logic bugs (null checks missing, edge cases)
   - Error handling issues
   - Memory leaks or resource issues
   - Security vulnerabilities
   - Race conditions
   - Type errors

Return findings as structured JSON wrapped in one markdown code fence. Every
finding MUST cite evidence from the fetched diff and test surface. An empty
array is valid only after reviewing every supplied PR:
\`\`\`json
[
  {
    \"repo\": \"...\",
    \"pr\": 123,
    \"file\": \"path/to/file\",
    \"line\": 42,
    \"severity\": 1,
    \"description\": \"...\",
    \"suggested_fix\": \"...\",
    \"evidence\": {
      \"diff_excerpt\": \"exact changed-code excerpt\",
      \"test_impact\": \"specific existing or missing test and why it matters\",
      \"reproduction_or_reasoning\": \"concrete failing scenario or proof chain\"
    }
  }
]
\`\`\`
"
            (
                _hermes_rc=0
                _raw="$(mktemp)"
                hermes -z "$_RETRY_PROMPT" -m "$PROVEN_MODEL" > "$_raw" 2>>"$_retry_err" || _hermes_rc=$?
                echo "$_hermes_rc" > "$_retry_exit"
                [ "$_hermes_rc" -ne 0 ] && echo "retry hermes exit $_hermes_rc (chunk $((_CIDX+1)) on $PROVEN_MODEL)" >> "$_retry_err"
                perl -0777 -ne 'print $1 if /```json\n?(.*?)\n?```/s' < "$_raw" > "$_retry_out" || true
                rm -f "$_raw"
            ) &
            RETRY_PIDS+=($!)
            RETRY_CHUNK_INDICES+=("$_CIDX")
        fi
    done

    if [ "${#RETRY_PIDS[@]}" -gt 0 ]; then
        log_info "Waiting for ${#RETRY_PIDS[@]} retry chunk(s) (deadline: ${BUG_HUNT_RETRY_DEADLINE_SECONDS}s)..."
        (
            sleep "$BUG_HUNT_RETRY_DEADLINE_SECONDS"
            for _PID in "${RETRY_PIDS[@]}"; do
                terminate_process_tree "$_PID" 2>/dev/null || true
            done
        ) >/dev/null 2>&1 &
        RETRY_DEADLINE_PID=$!
        for _RIDX in "${!RETRY_PIDS[@]}"; do
            _RPID="${RETRY_PIDS[$_RIDX]}"
            _rrc=0
            wait "$_RPID" 2>/dev/null || _rrc=$?
            if [ "$_rrc" -ne 0 ]; then
                log_warn "Retry chunk ${RETRY_CHUNK_INDICES[$_RIDX]} PID $_RPID exited $_rrc (deadline or error)"
            fi
        done
        kill "$RETRY_DEADLINE_PID" 2>/dev/null || true
        wait "$RETRY_DEADLINE_PID" 2>/dev/null || true
    fi
else
    log_warn "No proven surviving model found in first pass — skipping retry"
fi
fi  # end BUG_HUNT_DISABLE_RETRY

# Count bugs by parsing JSON output files from all chunks.
# Track failures separately so a clean-sweep is only reported when agents actually ran.
# REVIEWED_PRS counts only PRs in chunks that produced valid output (discovered vs reviewed).
AGENT_FAILURES=0
ACTUAL_BUGS=0
REVIEWED_PRS=0
for _CIDX in "${!CHUNK_OUTPUT_FILES[@]}"; do
    OUTPUT_FILE="${CHUNK_OUTPUT_FILES[$_CIDX]}"
    _CHUNK_PRS="${CHUNK_PR_COUNTS[$_CIDX]:-0}"
    ERR_FILE="${OUTPUT_FILE%.json}.err"

    if [ ! -f "$OUTPUT_FILE" ]; then
        log_warn "chunk output file missing: $OUTPUT_FILE — chunk failed"
        AGENT_FAILURES=$((AGENT_FAILURES + 1))
        continue
    fi

    # Empty file = agent produced nothing (crashed, timeout, connection error)
    if [ ! -s "$OUTPUT_FILE" ]; then
        _exit_reason=""
        _efile="${CHUNK_EXIT_FILES[$_CIDX]:-}"
        if [ -f "$_efile" ]; then
            _exit_reason=" (hermes exit $(cat "$_efile" 2>/dev/null || echo '?'))"
        fi
        log_warn "chunk output file empty (0 bytes): $OUTPUT_FILE — chunk failed${_exit_reason}; see $ERR_FILE"
        AGENT_FAILURES=$((AGENT_FAILURES + 1))
        continue
    fi

    # Validate JSON; attempt Python repair for truncated LLM output before failing
    if ! jq empty "$OUTPUT_FILE" 2>/dev/null; then
        _repaired="${OUTPUT_FILE%.json}.repaired.json"
        if repair_truncated_json "$OUTPUT_FILE" > "$_repaired" 2>/dev/null \
                && [ -s "$_repaired" ] && jq empty "$_repaired" 2>/dev/null; then
            _recovered=$(jq 'length' "$_repaired" 2>/dev/null || echo 0)
            log_warn "Chunk $((_CIDX+1)): truncated JSON repaired — $_recovered object(s) salvaged from $OUTPUT_FILE"
            OUTPUT_FILE="$_repaired"
            CHUNK_OUTPUT_FILES[$_CIDX]="$_repaired"
        else
            log_warn "Chunk $((_CIDX+1)): invalid JSON and repair failed — skipping $OUTPUT_FILE"
            AGENT_FAILURES=$((AGENT_FAILURES + 1))
            continue
        fi
    fi

    # Check if the JSON is an array (or findings array)
    if ! jq -e 'if type == "array" or (type == "object" and (.findings | type == "array")) then true else false end' "$OUTPUT_FILE" >/dev/null 2>&1; then
        log_warn "$OUTPUT_FILE is not an array or does not contain a findings array — skipping"
        AGENT_FAILURES=$((AGENT_FAILURES + 1))
        continue
    fi

    # Top-level array, or wrapped object with a findings array (common LLM shape).
    # Severity-0 objects are "no bug found" markers — exclude them from the count.
    # Use `else empty end` so unrecognized shapes are caught by the fail-closed case below.
    AGENT_BUGS=$(
        jq '
            if type == "array" then [.[] | select((.severity // 0) >= 1)] | length
            elif type == "object" and (.findings | type == "array") then [.findings[] | select((.severity // 0) >= 1)] | length
            else empty end
        ' "$OUTPUT_FILE" 2>/dev/null
    )
    # Empty = unrecognized shape or jq error — fail closed, do not count as zero
    case "${AGENT_BUGS}" in
        '') log_warn "could not parse bug count from $OUTPUT_FILE — skipping"; AGENT_FAILURES=$((AGENT_FAILURES + 1)); continue ;;
        *[!0-9]*) log_warn "unexpected bug count '${AGENT_BUGS}' from $OUTPUT_FILE — skipping"; AGENT_FAILURES=$((AGENT_FAILURES + 1)); continue ;;
    esac
    ACTUAL_BUGS=$((ACTUAL_BUGS + AGENT_BUGS))
    REVIEWED_PRS=$((REVIEWED_PRS + _CHUNK_PRS))
done

# Fail-closed: if ALL chunks failed, this is NOT a clean sweep
ALL_AGENTS_FAILED=0
TOTAL_CHUNKS_RUN="${#CHUNK_OUTPUT_FILES[@]}"
if [ "$AGENT_FAILURES" -eq "$TOTAL_CHUNKS_RUN" ] && [ "$TOTAL_CHUNKS_RUN" -gt 0 ]; then
    log_error "All bug hunt chunks failed — 0 bugs recorded is NOT a clean sweep"
    ALL_AGENTS_FAILED=1
fi

# Create fix PRs for bugs found (after all chunks complete)
FIX_PR_COUNT=0
if [ "${BUG_HUNT_DISABLE_FIXES:-0}" = "1" ]; then
    log_info "BUG_HUNT_DISABLE_FIXES=1 — skipping fix agent spawning"
elif [ "${ACTUAL_BUGS:-0}" -gt 0 ] 2>/dev/null; then
    log_info "Creating fix PRs for $ACTUAL_BUGS bugs..."

    # Collect all findings from all chunk output files
    ALL_FINDINGS="[]"
    for OUTPUT_FILE in "${CHUNK_OUTPUT_FILES[@]}"; do
        if [ -f "$OUTPUT_FILE" ] && jq empty "$OUTPUT_FILE" 2>/dev/null; then
            AGENT_FINDINGS=$(
                jq 'if type == "array" then . elif type == "object" and (.findings | type == "array") then .findings else [] end' \
                    "$OUTPUT_FILE" 2>/dev/null
            )
            ALL_FINDINGS=$(echo "$ALL_FINDINGS" | jq --argjson new "$AGENT_FINDINGS" '. + $new' 2>/dev/null)
        fi
    done

    # Deduplicate by repo+file+line+description
    UNIQUE_FINDINGS=$(echo "$ALL_FINDINGS" | jq 'unique_by("\(.repo)\(.pr)\(.file)\(.line)\(.description)")' 2>/dev/null)

    # For each unique bug, spawn a fix agent
    FIX_BRANCH_NAME="fix/bug-hunt-$(date +%Y%m%d)"

    while IFS= read -r finding; do
        repo=$(echo "$finding" | jq -r '.repo // empty')
        pr=$(echo "$finding" | jq -r '.pr // empty')
        file=$(echo "$finding" | jq -r '.file // empty')
        line=$(echo "$finding" | jq -r '.line // empty')
        severity=$(echo "$finding" | jq -r '.severity // 3')
        description=$(echo "$finding" | jq -r '.description // empty')
        suggested_fix=$(echo "$finding" | jq -r '.suggested_fix // empty')

        # Severity 0 = "no bug found" marker — skip entirely
        if [ "${severity:-0}" -eq 0 ] 2>/dev/null; then
            log_info "Skipping severity-0 object (no-bug marker): $repo PR#$pr"
            continue
        fi
        # Only fix P1/P2 bugs (severity 1 or 2)
        if [ "$severity" -gt 2 ] 2>/dev/null; then
            log_info "Skipping severity-$severity bug (only fixing P1/P2): $repo PR#$pr $file:$line"
            continue
        fi

        FIX_TASK="Fix Bug from Bug Hunt:

Bug found in $repo PR #$pr:
- File: $file
- Line: $line
- Severity: $severity (P1/P2)
- Description: $description
- Suggested Fix: $suggested_fix

Your job:
1. Clone/checkout $repo if not already present
2. Create branch: $FIX_BRANCH_NAME-<short-hash-of-finding>
3. Apply the fix to $file around line $line
4. Write a test that reproduces the bug and verifies the fix
5. Commit with message: 'fix: patch $file:$line - <one-line-description>'
6. Push branch to origin
7. Create PR titled '[bug-hunt] fix: <brief description>' targeting main
8. In the PR body, reference: 'Found in bug hunt — $repo PR #$pr'

Return the PR URL as your final output."

        FIX_LOG="${BUG_REPORTS_DIR}/bug-hunt-fix-$(date +%s)-${RANDOM}.log"
        
        # Route fix task to the first available active agent's model.
        # NOTE: must NOT use `local` here — this runs at top level (not inside a function),
        # and `set -e` would abort the script the moment a P1/P2 bug is found.
        fix_model="${AGENT_MODELS[${ACTIVE_AGENTS[0]}]}"

        (
            hermes -z "$FIX_TASK" -m "$fix_model" >> "$FIX_LOG" 2>&1
        ) &
        FIX_PID=$!
        (
          sleep "${BUG_HUNT_FIX_TIMEOUT_SECONDS:-300}"
          terminate_process_tree "$FIX_PID"
        ) >/dev/null 2>&1 &
        watchdog_pid=$!
        FIX_SUCCEEDED=0
        if wait "$FIX_PID" 2>/dev/null; then
            FIX_SUCCEEDED=1
        else
            log_warn "fix agent failed for $repo PR#$pr; see $FIX_LOG"
        fi
        kill $watchdog_pid 2>/dev/null || true
        wait $watchdog_pid 2>/dev/null || true
        if [ "$FIX_SUCCEEDED" -eq 1 ]; then
            FIX_PR_COUNT=$((FIX_PR_COUNT + 1))
        fi
    done < <(echo "$UNIQUE_FINDINGS" | jq -r '.[] | @json' 2>/dev/null)
fi  # end BUG_HUNT_DISABLE_FIXES / ACTUAL_BUGS guard

# Append findings and totals to report file
FIX_PR_INFO=""
if [ "${FIX_PR_COUNT:-0}" -gt 0 ]; then
    FIX_PR_INFO="- Fix PRs created: $FIX_PR_COUNT"
fi

# Build failure warning block (included in report and Slack when agents failed)
FAILURE_WARNING=""
if [ "${ALL_AGENTS_FAILED:-0}" -eq 1 ]; then
    FAILURE_WARNING="

:warning: *ALL bug hunt agents failed to run.* 0 bugs recorded — this is NOT a clean sweep.
Check error logs in $BUG_REPORTS_DIR/*.err for details."
elif [ "${AGENT_FAILURES:-0}" -gt 0 ]; then
    FAILURE_WARNING="

:warning: ${AGENT_FAILURES}/${TOTAL_CHUNKS_RUN} chunks failed — bug count may be incomplete.
Check error logs in $BUG_REPORTS_DIR/*.err for details."
fi

# Surface PR discovery failures separately so the human can tell API errors
# apart from agent failures. Two reasons we only show this block when the run
# actually had PRs to review: (1) the all-repos-failed case exits earlier with
# its own dedicated post; (2) the no-PRs case isn't interesting here.
DISCOVERY_WARNING=""
if [ "${FAIL_COUNT:-0}" -gt 0 ] && [ "${TOTAL_PRS:-0}" -gt 0 ]; then
    DISCOVERY_BLOCK=$(build_discovery_failure_summary)
    DISCOVERY_WARNING="

:warning: *${FAIL_COUNT}/${REPO_COUNT} repos failed PR discovery (partial scan):*
${DISCOVERY_BLOCK}"
fi

cat >> "$REPORT_FILE" << EOF
## PR Findings

$(echo -e "$FINDINGS")

## Results

- PRs discovered: $TOTAL_PRS
- PRs reviewed: $REVIEWED_PRS
- Chunks dispatched: ${TOTAL_CHUNKS_RUN}
- Bugs found: $ACTUAL_BUGS
- Chunk failures: ${AGENT_FAILURES:-0}/${TOTAL_CHUNKS_RUN}${FIX_PR_INFO:+$'\n'$FIX_PR_INFO}
EOF

# Only ping @hermes when there is at least one counted finding (see gh #242).
HERMES_BUG_ESCALATION=""
if [ "${ACTUAL_BUGS:-0}" -gt 0 ] 2>/dev/null; then
    HERMES_BUG_ESCALATION="

@hermes Please fix these bugs using agento"
fi

# Create Slack message
SLACK_MESSAGE="*Daily Bug Hunt Report - ${TIMESTAMP}*

*Repos scanned:* ${REPOS[*]}
*Period:* Last ${DAYS_LOOKBACK} days
*Agents deployed:* ${ACTIVE_AGENTS[*]}

*PRs discovered (${TOTAL_PRS}):*
$(echo -e "$FINDINGS")

*Results:*
- PRs discovered: $TOTAL_PRS
- PRs reviewed: $REVIEWED_PRS
- Bugs found: $ACTUAL_BUGS${FIX_PR_INFO:+, Fix PRs created: $FIX_PR_COUNT}
- Chunk failures: ${AGENT_FAILURES:-0}/${TOTAL_CHUNKS_RUN}
${FAILURE_WARNING}${DISCOVERY_WARNING}
*Reports:* $REPORT_FILE${HERMES_BUG_ESCALATION}"

post_report_outbound

# Final report
log_info "Bug hunt complete!"
log_info "Total PRs discovered: $TOTAL_PRS, reviewed: $REVIEWED_PRS"
log_info "Report saved to: $REPORT_FILE"

# Print summary
echo ""
echo "============================================"
echo "         BUG HUNT SUMMARY"
echo "============================================"
echo "Timestamp:    $TIMESTAMP"
echo "PRs Discovered: $TOTAL_PRS"
echo "PRs Reviewed:   $REVIEWED_PRS"
echo "Bugs Found:   $ACTUAL_BUGS"
echo "Report:       $REPORT_FILE"
echo "============================================"

[ "${ALL_AGENTS_FAILED:-0}" -eq 1 ] && exit 2
exit 0
