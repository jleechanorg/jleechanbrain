#!/usr/bin/env bash
# mem0_health_check_launchd.sh — launchd wrapper for mem0 health check.
#
# Runs the mem0 health check under the orch-venv Python interpreter (the
# one that has the `groq` package installed). Writes a concise log line
# for every run; non-zero exit surfaces in the plist's StandardErrorPath
# so it can be alerted on.
#
# Why a wrapper and not the .py directly:
#   - launchd jobs do NOT source ~/.bashrc / ~/.bash_profile, so GROQ_API_KEY
#     and the orch-venv python are NOT on PATH. We hardcode the venv python
#     and read GROQ_API_KEY from launchctl getenv as a defensive fallback.
#   - Sourcing ~/.bash_profile under launchd hangs indefinitely on
#     `brew shellenv` (Homebrew line in ~/.bash_profile line 4) — bypassing
#     the profile is required for the wrapper to finish.
#   - `python3 -u` forces unbuffered stdout/stderr so launchd's log file
#     receives lines in real time instead of buffering until the 4KB flush.
#
# Schedule: every 6 hours (configured in the plist template). End-to-end
# run is 60-180s on first launch, < 5s on steady-state (cached mem0 init).
set -euo pipefail

LABEL="mem0-health-check"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
LOG_PREFIX="[$LABEL $TS]"

# 1. Resolve GROQ_API_KEY defensively. The plist already provides it via
#    EnvironmentVariables; this is a fallback in case the env is unset.
if [[ -z "${GROQ_API_KEY:-}" ]]; then
  # shellcheck disable=SC2155
  GROQ_API_KEY="$(/usr/bin/env launchctl getenv GROQ_API_KEY 2>/dev/null || true)"
  export GROQ_API_KEY
fi

# 2. Resolve script paths and pin the orch-venv python explicitly. Do NOT
#    rely on `python3` from PATH — under launchd, the first python3 in PATH
#    can resolve to homebrew python@3.14 which hangs in import_find_and_load
#    on mem0/mem0ai imports. The orch-venv python@3.13 works.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HEALTH_CHECK="$SCRIPT_DIR/mem0_health_check.py"
PYTHON_BIN="${HOME}/.local/orch-venv/bin/python3"

if [[ ! -x "$PYTHON_BIN" ]]; then
  echo "$LOG_PREFIX FATAL: $PYTHON_BIN missing or not executable" >&2
  exit 2
fi
if [[ ! -f "$HEALTH_CHECK" ]]; then
  echo "$LOG_PREFIX FATAL: $HEALTH_CHECK missing" >&2
  exit 2
fi
if [[ -z "${GROQ_API_KEY:-}" ]]; then
  echo "$LOG_PREFIX FATAL: GROQ_API_KEY not set in plist or launchd env" >&2
  exit 3
fi

echo "$LOG_PREFIX starting ($PYTHON_BIN $($PYTHON_BIN -V 2>&1 | tr -d '\n'), GROQ_API_KEY set)"

set +e
"$PYTHON_BIN" -u "$HEALTH_CHECK"
RC=$?
set -e

if [[ $RC -eq 0 ]]; then
  echo "$LOG_PREFIX OK (5/5 passed)"
else
  echo "$LOG_PREFIX FAILED (exit=$RC) — mem0 health check degraded, see /tmp output above" >&2
fi

exit $RC
