#!/usr/bin/env bash
# Safe-bash-template.sh — copy and modify for any cron job that calls hermes CLIs.
#
# What this template encodes:
#   1. set -euo pipefail (strict mode) + trap on error
#   2. Every external command has its own || fallback that returns valid defaults
#   3. Every variable read uses ${VAR:-} (default-on-read) for safety under set -u
#   4. Pre-baked "?" fallback pattern is REPLACED with explicit log + degraded-mode
#   5. --dry-run mode for safe manual testing
#   6. VERIFY-CLI-FLAGS section as a pre-flight check before the script does anything
#
# Anti-patterns NOT in this template:
#   - `|| echo "?"` (hides real failures)
#   - `RAW=$(cmd --json) || true` (propagates garbage downstream)
#   - assignment under `|| VAR=default` without pre-defaulting
#   - `[[ -n "$VAR" ]]` for variables that may not be set

set -euo pipefail

# === Configuration ===
SCRIPT_NAME="${SCRIPT_NAME:-$(basename "$0")}"
DRY_RUN="${DRY_RUN:-false}"
HERMES="${HERMES:-hermes}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
err() { log "ERROR: $*" >&2; }

# === Pre-flight: verify every CLI flag the script uses actually exists ===
# Run this before any work. If --help doesn't list a flag, the script will
# silently produce garbage output (Pattern A from SKILL.md).
preflight() {
  local cmd="$1"; shift
  local missing=0
  for flag in "$@"; do
    if ! "$cmd" --help 2>&1 | grep -qE "(^|[[:space:]])${flag}([[:space:]]|$)"; then
      err "Flag '$flag' not in '$cmd --help' output. Verify it exists before relying on it."
      missing=$((missing + 1))
    fi
  done
  if [[ "$missing" -gt 0 ]]; then
    err "Preflight found $missing missing flag(s). Refusing to run."
    return 1
  fi
}

# === Trap for set -u + cleanup ===
cleanup() {
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    err "$SCRIPT_NAME failed with exit $rc"
  fi
  exit $rc
}
trap cleanup EXIT

# === Example: parse hermes cron list safely (Pattern A applied) ===
get_cron_counts() {
  # Pre-flight: verify the CLI flags we use exist
  if ! preflight "$HERMES cron" "--all"; then
    log "WARN: hermes cron preflight failed; using defaults"
    echo "0 0"   # total active
    return 0
  fi

  # Capture each piece independently. Each capture has its own || fallback that
  # returns a valid empty default, not the usage text.
  local table status
  table=$("$HERMES" cron list --all 2>/dev/null) || table=""
  status=$("$HERMES" cron status 2>/dev/null) || status=""

  # Parse both inputs in one python heredoc. Each input is quoted so an
  # empty value passes through cleanly.
  python3 - "$table" "$status" <<'PY' 2>/dev/null || echo "0 0"
import re, sys
table, status = sys.argv[1], sys.argv[2]
active_match = re.search(r"(\d+)\s+active\s+job", status)
active = int(active_match.group(1)) if active_match else 0
total = len(re.findall(r"^\s+[0-9a-f]{12,}\s+\[", table, re.MULTILINE))
print(f"{total} {active}")
PY
}

# === Example: safe Slack post (Pattern D applied — no subshell scope leak) ===
post_slack() {
  local msg="$1"
  local channel="${2:-${SLACK_REVIEW_CHANNEL_ID:-C0AJQ5M0A0Y}}"
  local token="${SLACK_USER_TOKEN:-}"

  if [[ -z "$token" ]]; then
    err "SLACK_USER_TOKEN not set; skipping Slack post"
    log "  message would have been: $msg"
    return 0
  fi

  local payload
  payload=$(python3 -c "import json,sys; print(json.dumps({'channel': '$channel', 'text': sys.stdin.read().strip()}))" <<< "$msg")
  curl -fsS -X POST "https://slack.com/api/chat.postMessage" \
    -H "Authorization: Bearer ***" \
    -H "Content-Type: application/json" \
    -d "$payload" >/dev/null 2>&1 || err "Slack post failed (continuing)"
}

# === Main ===
main() {
  if [[ "$DRY_RUN" == "true" ]]; then
    log "DRY-RUN mode: would do the work but skipping all side effects"
  fi

  log "Starting $SCRIPT_NAME"

  # Read counts
  read -r TOTAL ACTIVE < <(get_cron_counts)
  log "Cron: total=$TOTAL active=$ACTIVE"

  if [[ "$DRY_RUN" == "true" ]]; then
    log "DRY-RUN complete"
    return 0
  fi

  # Compose message. Under set -u, even safe reads should default.
  post_slack "Cron sweep: $ACTIVE of $TOTAL jobs active."

  log "Done."
}

# === Argument parsing ===
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help)
      echo "Usage: $0 [--dry-run]"
      echo "  --dry-run   Capture counts and log them, but skip all side effects."
      exit 0
      ;;
    *) err "Unknown arg: $1"; exit 1 ;;
  esac
done

main "$@"