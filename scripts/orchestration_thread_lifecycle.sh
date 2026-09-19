#!/usr/bin/env bash
# scripts/orchestration_thread_lifecycle.sh
#
# Wrapper for the merged thread-lifecycle + auto-park job (PR #742 / orch-auo0).
# Mirrors the launchd plist `ai.smartclaw.schedule.slack-thread-auto-park`
# invocation exactly: the plist runs
#     launchd-env-wrapper.sh → venv python3 -m orchestration.thread_lifecycle
# with --threshold-hours 48. This wrapper does the same thing from a shell
# (interactive / cron / smoke test) so an operator can drive it manually
# without going through launchd, and so the Linux-side Lane B can copy
# the same shape when wiring systemd.
#
# Why a shell wrapper instead of invoking python directly:
#   • Resolves HERMES_HOME (default $HOME/.smartclaw) so the same
#     script works on the Mac production host AND in CI / on Linux.
#   • Sources ~/.bashrc for SLACK_BOT_TOKEN + ANTHROPIC_API_KEY
#     (auto-park needs ANTHROPIC_API_KEY? no — auto-park is timestamp-only,
#     no LLM call. But the bashrc source is the repo-wide convention so
#     both jobs have the same shape.)
#   • Overlap lock (mkdir LOCK_DIR) — if a previous tick is still running,
#     skip cleanly. Same pattern as slack-thread-roadmap-report.sh.
#   • Idempotent: auto-park skip threads already at status=parked.
#
# Usage:
#   scripts/orchestration_thread_lifecycle.sh              # auto-park (>48h silent)
#   scripts/orchestration_thread_lifecycle.sh --no-bead --no-sync
#                                                           # scan without filing
#                                                           # beads or syncing
#   scripts/orchestration_thread_lifecycle.sh --threshold-hours 24
#
# Exit codes:
#   0 = success (including "no threads parked")
#   1 = invocation error (bad HERMES_HOME, missing venv python)
#   2 = module error (import / runtime exception)
set -euo pipefail

HERMES_HOME="${HERMES_HOME:-$HOME/.smartclaw}"
LOG_DIR="$HERMES_HOME/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/slack-thread-auto-park.log"
ERR_FILE="$LOG_DIR/slack-thread-auto-park.err"
ts() { date '+%Y-%m-%dT%H:%M:%S%z'; }
log() { printf '[%s] %s\n' "$(ts)" "$*" | tee -a "$LOG_FILE" >&2; }
err() { printf '[%s] ERROR: %s\n' "$(ts)" "$*" | tee -a "$ERR_FILE" >&2; }

# Source the same env the launchd wrapper would source (bashrc only,
# not .env — secrets-no-env / secrets-no-plist policy). Only fall back to
# sourcing when the var isn't already in the environment (e.g. inherited
# from launchd-env-wrapper.sh, which already sourced dotfiles for this
# exact var). `bash -c 'source ~/.bashrc; ...'` (the old approach) silently
# returns empty here: ~/.bashrc's standard interactive-shell guard
# (`case $- in *i*) ;; *) return;; esac`) makes a non-interactive `bash -c`
# shell skip everything after it. `bash -ic` forces an interactive shell so
# the guard passes, and `printf %s "$VAR"` correctly expands
# variable-indirection values (vs `echo -n`, which does not). See
# scripts/launchd-env-wrapper.sh's _extract_bashrc_var() docstring for the
# same root cause documented at the wrapper level.
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

# Overlap lock — skip if another tick is still running. Records the
# holder's pid so a SIGKILLed previous run can be detected and cleared
# instead of wedging every future tick into a permanent no-op "SKIP".
LOCK_DIR="${TMPDIR:-/tmp}/hermes-orchestration-thread-lifecycle.lock"
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

log "=== start (hermes_home=$HERMES_HOME args='$*') ==="

# Mirror the plist's PYTHONPATH exactly: $HERMES_HOME/src
# The plist also sets TZ=America/Los_Angeles; we honor that.
export PYTHONPATH="$HERMES_HOME/src"
export TZ="${TZ:-America/Los_Angeles}"

cd "$HERMES_HOME"

MODULE_RC=0
"$VENV_PY" -m orchestration.thread_lifecycle "$@" 2>>"$ERR_FILE" | tee -a "$LOG_FILE" || MODULE_RC=$?
# Module rc=0 is "no threads parked (or some parked) — clean pass".
# Module rc != 0 is the python module raising — the launcher is broken.
if [[ $MODULE_RC -ne 0 ]]; then
  err "python -m orchestration.thread_lifecycle exited rc=$MODULE_RC"
  exit 2
fi

log "=== done (module rc=$MODULE_RC) ==="