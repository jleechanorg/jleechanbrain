#!/usr/bin/env bash
# ~/.smartclaw/scripts/auto-resolve-easy-prs.launchd.sh
# Wrapper for auto-resolve-easy-prs.sh — sources login env so MINIMAX_API_KEY,
# GH_TOKEN, SLACK_BOT_TOKEN are all in scope under launchd.
set -euo pipefail

# Source .bash_profile → .bashrc to get the full interactive env.
# launchd wrappers run under `set -u`; shell init files may reference
# optional variables that are only set in interactive tmux/cmux sessions.
# Temporarily disable nounset so a missing shell-only variable does not
# abort the scheduled job before the monitor starts.
set +u
if [[ -f "$HOME/.bash_profile" ]]; then
  source "$HOME/.bash_profile" 2>/dev/null || true
fi
if [[ -f "$HOME/.bashrc" ]]; then
  # bashrc has an interactive guard; force-source critical API keys.
  for v in GH_TOKEN GITHUB_TOKEN MINIMAX_API_KEY MINIMAX_MODEL SLACK_BOT_TOKEN SLACK_USER_TOKEN; do
    if grep -qE "^export $v=" "$HOME/.bashrc" 2>/dev/null; then
      val=$(grep -E "^export $v=" "$HOME/.bashrc" | head -1 | sed -E "s/^export $v=//; s/^['\"]//; s/['\"]$//")
      export "$v"="$val"
    fi
  done
fi
set -u

# Export plist env vars so the script can use them
for v in AO_PROJECT AGENT REPO CHANNEL_ID MAX_PRS WORK_ORDER_FILE SPAWN_LOG SLACK_BOT_TOKEN; do
  if [[ -n "${!v:-}" ]]; then
    export "$v"
  fi
done

exec "${HOME}/.smartclaw/scripts/auto-resolve-easy-prs.sh" "$@"
