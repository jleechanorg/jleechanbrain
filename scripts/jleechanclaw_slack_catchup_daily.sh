#!/usr/bin/env bash
# scripts/jleechanclaw_slack_catchup_daily.sh
#
# Linux-side wrapper for the merged jleechanclaw daily #agent-digest
# rollup (PR #740 / orch-2jbg). Mirrors the launchd plist
# `ai.hermes.schedule.slack-digest-rollup` invocation: the plist runs
#     launchd-env-wrapper.sh → venv python3 -m orchestration.slack_catchup
# with --hours 24, posting to #agent-digest. This wrapper does the
# same thing on the Linux box, importing from the jleechanclaw
# checkout's src/ tree (NOT the brain repo's stale mirror — see
# jleechanclaw_thread_lifecycle.sh for the rationale).
#
# Environment:
#   HERMES_SLACK_BOT_TOKEN (required for live post) — sourced from
#     ~/.bashrc via the systemd EnvironmentFile= directive. Never
#     hardcoded in the service file (secrets-no-env / secrets-no-plist
#     policy).
#   ANTHROPIC_API_KEY (required for LLM tier classification) — same.
#   SLACK_DIGEST_CHANNEL (optional override; default C0BFBCGN3HD =
#     #agent-digest per slack_catchup.py DEFAULT_DIGEST_CHANNEL).
#
# Usage (called from systemd):
#   scripts/jleechanclaw_slack_catchup_daily.sh
#
# Exit codes:
#   0 = digest built + posted (or dry-run)
#   1 = invocation error (missing JLEECHANCLAW_HOME / src dir)
#   2 = module error (import / runtime / post failure)
#   rc=1 from module = "no channels configured" — still rc=0 from
#   launcher (config gap is the module's surface, not ours).
set -euo pipefail

JLEECHANCLAW_HOME="${JLEECHANCLAW_HOME:-/home/jleechan/project_jleechanclaw/jleechanclaw}"
LOG_DIR="${LOG_DIR:-/home/jleechan/.hermes/logs}"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/slack-digest-rollup.log"
ERR_FILE="$LOG_DIR/slack-digest-rollup.err"
ts() { date '+%Y-%m-%dT%H:%M:%S%z'; }
log() { printf '[%s] %s\n' "$(ts)" "$*" | tee -a "$LOG_FILE" >&2; }
err() { printf '[%s] ERROR: %s\n' "$(ts)" "$*" | tee -a "$ERR_FILE" >&2; }

if [[ ! -f "$JLEECHANCLAW_HOME/src/orchestration/slack_catchup.py" ]]; then
  err "orchestration/slack_catchup.py not found at $JLEECHANCLAW_HOME/src/orchestration/slack_catchup.py — set JLEECHANCLAW_HOME to a checkout with the merged triage module (PR #740), or check the checkout is not on a stale branch missing it"
  exit 1
fi

# Quick token sanity check — the LLM call will fail without it, and
# the slowness of the failure mode makes root-causing slow. Fail fast.
if [[ -z "${HERMES_SLACK_BOT_TOKEN:-}" ]]; then
  err "HERMES_SLACK_BOT_TOKEN is empty — systemd EnvironmentFile= must source it from ~/.bashrc (NEVER from a .env file)"
  exit 1
fi
if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
  err "ANTHROPIC_API_KEY is empty — slack_catchup's LLM tier classifier will fail without it"
  exit 1
fi

LOCK_DIR="${TMPDIR:-/tmp}/hermes-jleechanclaw-slack-catchup-daily.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  log "SKIP: another instance running (lock=$LOCK_DIR)"
  exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

export PYTHONPATH="$JLEECHANCLAW_HOME/src"
export TZ="${TZ:-America/Los_Angeles}"
# PYTHON_BIN must be a single executable path (no spaces) — see the
# thread_lifecycle wrapper for the rc=127 rationale. /usr/bin/python3
# is the default; override via env to use a venv.
PYTHON_BIN="${PYTHON_BIN:-/usr/bin/python3}"

log "=== start (jleechanclaw_home=$JLEECHANCLAW_HOME digest_channel=${SLACK_DIGEST_CHANNEL:-default-#agent-digest} hours=${HOURS:-24}) ==="

# Default --hours 24 to match the plist.
ARGS=("$@")
if [[ ${#ARGS[@]} -eq 0 ]]; then
  ARGS=(--hours 24)
fi

MODULE_RC=0
"$PYTHON_BIN" -m orchestration.slack_catchup "${ARGS[@]}" 2>>"$ERR_FILE" | tee -a "$LOG_FILE" || MODULE_RC=$?
# rc=1 = "no channels configured" — config gap, not launcher failure.
# rc>=2 = real failure (import error, post failure, etc.).
if [[ $MODULE_RC -ge 2 ]]; then
  err "python -m orchestration.slack_catchup exited rc=$MODULE_RC"
  exit 2
fi

log "=== done (module rc=$MODULE_RC) ==="