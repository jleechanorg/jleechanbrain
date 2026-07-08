#!/usr/bin/env bash
# scripts/jleechanclaw_thread_lifecycle.sh
#
# Linux-side wrapper for the merged jleechanclaw thread-lifecycle +
# auto-park job (PR #742 / orch-auo0). Mirrors the launchd plist
# `ai.hermes.schedule.slack-thread-auto-park` invocation but uses
# jleechanclaw's checked-out source on the Linux box (not a venv):
#
#     /usr/bin/env python3 -m orchestration.thread_lifecycle
#     --threshold-hours 48
# with PYTHONPATH pointed at the jleechanclaw checkout's src/ dir.
#
# Why import from the jleechanclaw checkout, not the brain repo's
# src/orchestration:
#
#   The brain repo's src/orchestration/ is a SYNC MIRROR of jleechanclaw
#   content, last refreshed 2026-06-20 (commit d3203fb5). The merged
#   triage code (PRs #740/#742) landed 2026-07-07 — too recent to be
#   in the brain mirror. Rather than copy the two .py files into brain
#   (which would require a separate sync bead to keep them current),
#   we point PYTHONPATH at the jleechanclaw checkout on this box
#   (/home/jleechan/project_jleechanclaw/jleechanclaw/src). This is
#   the same model hermes-agent already uses for jleechanclaw deps
#   (see ~/.hermes/scripts/ for symlinks into the jleechanclaw clone).
#
#   JLEEANCHAWL_HOME env var overrides the default checkout path for
#   dev / CI use.
#
# What this does NOT do:
#   • Does not post to Slack — auto-park reads local JSON state and
#     files beads via `br create`. No Slack token required.
#   • Does not write to ~/.hermes. Logs go to
#     /home/jleechan/.hermes/logs/slack-thread-auto-park.{log,err} —
#     same path the plist uses, so the existing log-rotation in
#     hermes-agent finds them.
#
# Usage (called from systemd):
#   scripts/jleechanclaw_thread_lifecycle.sh
#   scripts/jleechanclaw_thread_lifecycle.sh --dry-run-style-flags
#
# Exit codes:
#   0 = success (including "no threads parked")
#   1 = invocation error (missing JLEEANCHAWL_HOME / no src dir)
#   2 = module error
set -euo pipefail

JLEEANCHAWL_HOME="${JLEEANCHAWL_HOME:-/home/jleechan/project_jleechanclaw/jleechanclaw}"
LOG_DIR="${LOG_DIR:-/home/jleechan/.hermes/logs}"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/slack-thread-auto-park.log"
ERR_FILE="$LOG_DIR/slack-thread-auto-park.err"
ts() { date '+%Y-%m-%dT%H:%M:%S%z'; }
log() { printf '[%s] %s\n' "$(ts)" "$*" | tee -a "$LOG_FILE" >&2; }
err() { printf '[%s] ERROR: %s\n' "$(ts)" "$*" | tee -a "$ERR_FILE" >&2; }

if [[ ! -d "$JLEEANCHAWL_HOME/src/orchestration" ]]; then
  err "JLEEANCHAWL_HOME/src/orchestration not found at $JLEEANCHAWL_HOME/src/orchestration — set JLEEANCHAWL_HOME or check the checkout"
  exit 1
fi

LOCK_DIR="${TMPDIR:-/tmp}/hermes-jleechanclaw-thread-lifecycle.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  log "SKIP: another instance running (lock=$LOCK_DIR)"
  exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

export PYTHONPATH="$JLEEANCHAWL_HOME/src"
export TZ="${TZ:-America/Los_Angeles}"
# Use the system Python — no venv in the brain repo. PYTHONPATH points
# at the jleechanclaw src tree, which is what `-m orchestration.X` needs.
# PYTHON_BIN must be a single executable path (no spaces) — passing
# "/usr/bin/env python3" as one arg fails with rc=127 because bash
# doesn't split quoted vars. Override via PYTHON_BIN=/path/to/python3
# to use a venv or a non-system interpreter.
PYTHON_BIN="${PYTHON_BIN:-/usr/bin/python3}"

log "=== start (jleechanclaw_home=$JLEEANCHAWL_HOME args='$*') ==="

MODULE_RC=0
"$PYTHON_BIN" -m orchestration.thread_lifecycle "$@" 2>>"$ERR_FILE" | tee -a "$LOG_FILE" || MODULE_RC=$?
# Module rc=0 = clean pass. Module rc=1 = "no threads parked" — still
# a success for the systemd unit (the timer's contract is "run it once
# per fire"). rc>=2 is a real failure.
if [[ $MODULE_RC -ge 2 ]]; then
  err "python -m orchestration.thread_lifecycle exited rc=$MODULE_RC"
  exit 2
fi

log "=== done (module rc=$MODULE_RC) ==="