#!/usr/bin/env bash
# Tests for bug-hunt-daily.sh helpers: classify_gh_failure + get_merged_prs fallback.
#
# Run: bash tests/test_bug_hunt_daily.sh
# Exit 0 on pass, 1 on any failure.
#
# These tests load the script's helper functions directly via awk extraction
# so we don't have to actually run the full cron entrypoint (which spawns
# hermes agents that take minutes). We mock `gh` to simulate GraphQL rate
# limiting and REST success/failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUG_HUNT_SCRIPT="${BUG_HUNT_SCRIPT:-$HOME/.smartclaw/scripts/bug-hunt-daily.sh}"

if [ ! -f "$BUG_HUNT_SCRIPT" ]; then
    echo "FAIL: bug-hunt-daily.sh not found at $BUG_HUNT_SCRIPT" >&2
    exit 1
fi

# Stub directory — we override `gh` for the duration of each test
STUB_DIR=$(mktemp -d)
trap 'rm -rf "$STUB_DIR"' EXIT

pass=0
fail=0
fail_msgs=()

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        pass=$((pass + 1))
        printf '  ✓ %s\n' "$label"
    else
        fail=$((fail + 1))
        fail_msgs+=("$label: expected=[$expected] actual=[$actual]")
        printf '  ✗ %s — expected=[%s] actual=[%s]\n' "$label" "$expected" "$actual"
    fi
}

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*) pass=$((pass + 1)); printf '  ✓ %s\n' "$label" ;;
        *) fail=$((fail + 1)); fail_msgs+=("$label: needle=[$needle] not in [$haystack]")
           printf '  ✗ %s — needle=[%s] not in haystack\n' "$label" "$needle" ;;
    esac
}

# Load the two helper functions from the script
load_helpers() {
    eval "$(awk '/^classify_gh_failure\(\)/,/^}/' "$BUG_HUNT_SCRIPT")"
    eval "$(awk '/^get_merged_prs\(\)/,/^}/' "$BUG_HUNT_SCRIPT")"
}

DAYS_LOOKBACK=2

# Make stub gh script with first-call mode (graphql then rest) and a sentinel
# marker so tests can simulate per-call state.
# Args written via printf %q so embedded single quotes / parentheses survive intact.
write_gh_stub() {
    local graphql_out="$1" graphql_err="$2" graphql_rc="$3"
    local rest_out="$4" rest_err="$5" rest_rc="$6"
    {
        printf '#!/bin/bash\n'
        printf 'case "$1" in\n'
        printf '    pr)\n'
        printf '        echo %s\n' "$(printf '%q' "$graphql_out")"
        printf '        [ -n %q ] && echo %s >&2\n' "$graphql_err" "$(printf '%q' "$graphql_err")"
        printf '        exit %s\n' "$graphql_rc"
        printf '        ;;\n'
        printf '    api)\n'
        printf '        echo %s\n' "$(printf '%q' "$rest_out")"
        printf '        [ -n %q ] && echo %s >&2\n' "$rest_err" "$(printf '%q' "$rest_err")"
        printf '        exit %s\n' "$rest_rc"
        printf '        ;;\n'
        printf '    *)\n'
        printf '        echo "stub gh: unknown subcommand $1" >&2\n'
        printf '        exit 2\n'
        printf '        ;;\n'
        printf 'esac\n'
    } > "$STUB_DIR/gh"
    chmod +x "$STUB_DIR/gh"
}

echo "=== Test 1: classify_gh_failure() classification ==="
load_helpers
assert_eq "graphql rate limit" "graphql_rate_limit" "$(classify_gh_failure 'GraphQL: API rate limit already exceeded for user ID 13840161.')"
assert_eq "graphql alt wording" "graphql_rate_limit" "$(classify_gh_failure 'You have exceeded the rate limit.')"
assert_eq "connection refused" "connection" "$(classify_gh_failure 'Could not resolve host: api.github.com')"
assert_eq "TLS handshake" "connection" "$(classify_gh_failure 'TLS handshake timeout')"
assert_eq "auth 401" "auth" "$(classify_gh_failure 'Bad credentials (HTTP 401)')"
assert_eq "auth token" "auth" "$(classify_gh_failure 'authentication failed: GITHUB_TOKEN missing')"
assert_eq "fallback other" "other" "$(classify_gh_failure 'Some weird error')"
echo

echo "=== Test 2: get_merged_prs() REST fallback on GraphQL rate-limit ==="
# GraphQL fails with rate limit; REST returns a minimal valid pull JSON.
REST_PAYLOAD='[{"number":42,"title":"rest-pr","html_url":"https://example.com/pr/42","merged_at":"2026-08-06T12:00:00Z"}]'
write_gh_stub "" "GraphQL: API rate limit already exceeded for user ID 13840161." 1 \
               "$REST_PAYLOAD" "" 0
PATH="$STUB_DIR:$PATH"
out=$(get_merged_prs "fake/repo" 2>/dev/null)
rc=$?
assert_eq "exit code 0 (fallback succeeded)" "0" "$rc"
assert_contains "PR number preserved" '"number": 42' "$out"
assert_contains "mergedAt key remapped" '"mergedAt"' "$out"
assert_contains "html_url remapped to url" '"url"' "$out"
assert_contains "repo stamped on each row" '"repo": "fake/repo"' "$out"
echo

# Helper: invoke `get_merged_prs` in the current shell (so globals set inside
# the function survive) but bypass `set -e` so a non-zero return doesn't
# terminate the test runner. Stores the exit code in the global CALL_RC and
# writes stdout to $1 (a temp file path passed by the caller).
CALL_RC=0
call_get_merged_prs() {
    local out_file="$1"
    local repo="$2"
    # Disable errexit around the call; restore afterward.
    local prev_e=""
    case $- in *e*) prev_e="e" ;; esac
    set +e
    get_merged_prs "$repo" >"$out_file" 2>/dev/null
    CALL_RC=$?
    [ -n "$prev_e" ] && set -e
}

echo "=== Test 3: get_merged_prs() gives up on auth (no fallback) ==="
write_gh_stub "" "Bad credentials (HTTP 401)" 1 "" "" 0
# Globals set inside the function survive ONLY when the function is called in
# the current shell (NOT in a $() subshell).
GET_PRS_FAIL_CLASS="" GET_PRS_FAIL_MSG=""
out_file=$(mktemp)
call_get_merged_prs "$out_file" "fake/repo"
rc=$CALL_RC
out=$(cat "$out_file")
rm -f "$out_file"
assert_eq "exit code 1 on auth" "1" "$rc"
assert_eq "fail class = auth" "auth" "${GET_PRS_FAIL_CLASS:-}"
assert_contains "fail msg mentions auth" "Bad credentials" "${GET_PRS_FAIL_MSG:-}"
echo

echo "=== Test 4: get_merged_prs() returns empty array when GraphQL succeeds with no matches ==="
write_gh_stub "[]" "" 0 "" "" 0
out=$(get_merged_prs "fake/repo" 2>/dev/null)
rc=$?
assert_eq "exit code 0 on empty success" "0" "$rc"
assert_eq "empty array" "[]" "$out"
echo

echo "=== Test 5: get_merged_prs() REST fallback returns empty when no recent merges ==="
REST_PAYLOAD='[{"number":99,"title":"old","html_url":"https://x","merged_at":"2020-01-01T00:00:00Z"}]'
write_gh_stub "" "GraphQL: API rate limit already exceeded" 1 "$REST_PAYLOAD" "" 0
GET_PRS_FAIL_CLASS="" GET_PRS_FAIL_MSG=""
out_file=$(mktemp)
call_get_merged_prs "$out_file" "fake/repo"
rc=$CALL_RC
out=$(cat "$out_file")
rm -f "$out_file"
assert_eq "exit code 0 (REST fallback)" "0" "$rc"
assert_eq "filtered empty array" "[]" "$out"
echo

echo "=== Test 6: get_merged_prs() reports when both GraphQL AND REST fail ==="
write_gh_stub "" "GraphQL: API rate limit already exceeded" 1 "" "REST: secondary rate limit" 1
GET_PRS_FAIL_CLASS="" GET_PRS_FAIL_MSG=""
out_file=$(mktemp)
call_get_merged_prs "$out_file" "fake/repo"
rc=$CALL_RC
out=$(cat "$out_file")
rm -f "$out_file"
assert_eq "exit code 1 when both fail" "1" "$rc"
assert_eq "fail class stays graphql_rate_limit" "graphql_rate_limit" "${GET_PRS_FAIL_CLASS:-}"
assert_contains "fail msg captures both phases" "GraphQL:" "${GET_PRS_FAIL_MSG:-}"
assert_contains "fail msg captures REST detail" "REST:" "${GET_PRS_FAIL_MSG:-}"
echo

echo
echo "================================================"
echo "Results: $pass passed, $fail failed"
echo "================================================"
if [ "$fail" -gt 0 ]; then
    printf 'Failing assertions:\n'
    for msg in "${fail_msgs[@]}"; do
        printf '  - %s\n' "$msg"
    done
    exit 1
fi
exit 0
