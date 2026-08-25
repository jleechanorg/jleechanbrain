#!/usr/bin/env bash
# scripts/orchestration_slack_catchup_daily.sh
#
# Wrapper for the merged daily #agent-digest rollup (PR #740 / orch-2jbg).
# Mirrors the launchd plist `ai.smartclaw.schedule.slack-digest-rollup`
# invocation exactly: the plist runs
#     launchd-env-wrapper.sh → venv python3 -m orchestration.slack_catchup
# with --hours 24, posting to the SLACK_DIGEST_CHANNEL env (default
# C0BFBCGN3HD = #agent-digest). This wrapper does the same thing from a
# shell so an operator can drive it manually and so Lane B's Linux-side
# systemd timer can copy this exact shape.
#
# Why a shell wrapper instead of invoking python directly:
#   • Resolves HERMES_HOME (default $HOME/.smartclaw).
#   • Sources ~/.bashrc for SLACK_BOT_TOKEN + ANTHROPIC_API_KEY
#     (slack_catchup calls the LLM for tier classification — needs both).
#   • Overlap lock (mkdir LOCK_DIR) — skip if previous tick still running.
#   • Idempotent: state file at ~/.smartclaw/state/slack_catchup_state.json
#     stores per-channel cursor, so re-runs only fetch new messages.
#
# Usage:
#   scripts/orchestration_slack_catchup_daily.sh              # post 24h digest to #agent-digest
#   scripts/orchestration_slack_catchup_daily.sh --dry-run    # build digest, do not post
#   scripts/orchestration_slack_catchup_daily.sh --hours 48   # widen window
#   scripts/orchestration_slack_catchup_daily.sh --post-to C0BFBCGN3HD
#
# Exit codes:
#   0 = success (digest built + posted)
#   1 = invocation error (bad HERMES_HOME, missing venv python)
#   2 = module error (import / runtime / post failure)
set -euo pipefail

HERMES_HOME="${HERMES_HOME:-$HOME/.smartclaw}"
LOG_DIR="$HERMES_HOME/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/slack-digest-rollup.log"
ERR_FILE="$LOG_DIR/slack-digest-rollup.err"
ts() { date '+%Y-%m-%dT%H:%M:%S%z'; }
log() { printf '[%s] %s\n' "$(ts)" "$*" | tee -a "$LOG_FILE" >&2; }
err() { printf '[%s] ERROR: %s\n' "$(ts)" "$*" | tee -a "$ERR_FILE" >&2; }

# Source bashrc for SLACK_BOT_TOKEN + ANTHROPIC_API_KEY, but only if
# the var isn't already in the environment (e.g. inherited from
# launchd-env-wrapper.sh, which already sourced dotfiles + extracted these
# exact vars). `bash -c 'source ~/.bashrc; ...'` (the old approach) silently
# returns empty here: ~/.bashrc's standard interactive-shell guard
# (`case $- in *i*) ;; *) return;; esac`) makes a non-interactive `bash -c`
# shell skip everything after it, so vars defined past the guard never
# reach the sourcing shell. `bash -ic` forces an interactive shell so the
# guard passes, and `printf %s "$VAR"` (vs `echo -n`) also correctly
# expands values that are themselves shell-variable-indirection (a pattern
# used elsewhere in this repo's env chain) rather than just echoing them
# literally. See scripts/launchd-env-wrapper.sh's _extract_bashrc_var()
# docstring for the same root cause documented at the wrapper level.
_extract_bashrc_var() {
  local var="$1"
  local val
  val="$(bash -c "source ~/.bashrc; printf %s \"\${${var}:-}\"" 2>/dev/null || true)"
  if [[ -z "$val" ]]; then
    val=$(grep -m1 "^export ${var}=" "$HOME/.bashrc" 2>/dev/null | sed "s/^export ${var}=//;s/^['\"]//;s/['\"]$//" | tr -d '\n' || true)
  fi
  printf %s "$val"
}

TOKEN="${SLACK_BOT_TOKEN:-}"
if [[ -z "$TOKEN" ]]; then
  TOKEN="$(_extract_bashrc_var SLACK_BOT_TOKEN)"
fi
export SLACK_BOT_TOKEN="$TOKEN"

ANTHROPIC_KEY="${ANTHROPIC_API_KEY:-}"
if [[ -z "$ANTHROPIC_KEY" ]]; then
  ANTHROPIC_KEY="$(_extract_bashrc_var ANTHROPIC_API_KEY)"
fi
export ANTHROPIC_API_KEY="$ANTHROPIC_KEY"

# Overlap lock — skip if another tick is still running. Records the
# holder's pid so a SIGKILLed previous run can be detected and cleared
# instead of wedging every future tick into a permanent no-op "SKIP".
LOCK_DIR="${TMPDIR:-/tmp}/hermes-orchestration-slack-catchup-daily.lock"
_acquire_lock() {
  mkdir "$LOCK_DIR" 2>/dev/null || return 1
  echo "$$" > "$LOCK_DIR/pid"
  return 0
}
if ! _acquire_lock; then
  stale_pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
  if [[ -n "$stale_pid" ]] && ! kill -0 "$stale_pid" 2>/dev/null; then
    log "Stale lock detected (pid=$stale_pid no longer running) — clearing and retrying"
    rm -rf "$LOCK_DIR"
  fi
  if ! _acquire_lock; then
    log "SKIP: another instance running (lock=$LOCK_DIR)"
    exit 0
  fi
fi
trap 'rm -rf "$LOCK_DIR" 2>/dev/null || true' EXIT

VENV_PY="$HERMES_HOME/.venv/bin/python3"
if [[ ! -x "$VENV_PY" ]]; then
  err "venv python not found at $VENV_PY — set HERMES_HOME or create the venv"
  exit 1
fi

if [[ ! -d "$HERMES_HOME/src/orchestration" ]]; then
  err "orchestration package not found at $HERMES_HOME/src/orchestration — wrong HERMES_HOME?"
  exit 1
fi

# Default args if none provided: 24h window, post to #agent-digest.
# These match the launchd plist exactly.
if [[ $# -eq 0 ]]; then
  set -- --hours 24
fi

log "=== start (hermes_home=$HERMES_HOME args='$*') ==="

export PYTHONPATH="$HERMES_HOME/src"
export TZ="${TZ:-America/Los_Angeles}"

cd "$HERMES_HOME"

MODULE_RC=0
"$VENV_PY" -m orchestration.slack_catchup "$@" 2>>"$ERR_FILE" | tee -a "$LOG_FILE" || MODULE_RC=$?
# slack_catchup returns 0 when no channels are configured (hermes.json
# missing or empty) — that's a benign config no-op, not a failure.
# Module rc != 0 is the python module raising or failing to post.
if [[ $MODULE_RC -ne 0 ]]; then
  err "python -m orchestration.slack_catchup exited rc=$MODULE_RC"
  exit 2
fi

log "=== done (module rc=$MODULE_RC) ==="