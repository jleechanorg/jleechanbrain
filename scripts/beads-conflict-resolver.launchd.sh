#!/usr/bin/env bash
# beads-conflict-resolver.launchd.sh — Wrapper for beads-conflict-resolver.sh run under launchd
# Sources full shell environment, then resolves GH_TOKEN via gh auth before
# invoking the main conflict resolver script.
set -euo pipefail

# 1. Source user profile and bashrc with nounset temporarily disabled
#    to avoid launchd aborts from unbound optional variables.
#    Per /launchd skill: always source bashrc to ensure all env vars are set.
for rc in ~/.bash_profile ~/.bashrc; do
  if [[ -f "$rc" ]]; then
    set +u
    source "$rc" 2>/dev/null || true
    set -u
  fi
done

# 2. Dynamic credential resolution fallbacks
if [[ -z "${GH_TOKEN:-}" ]]; then
  RESOLVED_TOKEN="$(gh auth token 2>/dev/null || true)"
  if [[ -n "$RESOLVED_TOKEN" ]]; then
    export GH_TOKEN="$RESOLVED_TOKEN"
  fi
else
  export GH_TOKEN
fi

# 3. Export other required environment variables if set in profile
if [[ -n "${AO_BIN:-}" ]]; then
  export AO_BIN
fi
if [[ -n "${AO_DIR:-}" ]]; then
  export AO_DIR
fi

# 4. Pre-check: verify AO is running, attempt start if not
if ! ao session ls -p worldarchitect >/dev/null 2>&1; then
  echo "[$(date '+%Y-%m-%dT%H:%M:%S%z')] WARN: AO not running, attempting to start worldarchitect project..."
  ao start worldarchitect >/dev/null 2>&1 &
  # Give it a few seconds to initialize
  sleep 5
fi

# 5. Invoke the main beads conflict resolver script
exec "${HOME}/.smartclaw/scripts/beads-conflict-resolver.sh" "$@"
