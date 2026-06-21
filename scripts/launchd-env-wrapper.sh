#!/bin/bash
# launchd-env-wrapper.sh — loads user login env before running the target command.
# Why: launchd doesn't source ~/.bashrc, so API keys defined there aren't available.
# Usage: launchd-env-wrapper.sh <command> [args...]

# Staging token references (set if not in plist to avoid TOKEN key errors)
HERMES_STAGING_SLACK_BOT_TOKEN="${HERMES_STAGING_SLACK_BOT_TOKEN:-}"
HERMES_STAGING_SLACK_APP_TOKEN="${HERMES_STAGING_SLACK_APP_TOKEN:-}"

# Snapshot plist-set Slack tokens BEFORE sourcing dotfiles, which overwrite them.
_PLIST_SLACK_BOT_TOKEN="${SLACK_BOT_TOKEN:-}"
_PLIST_SLACK_APP_TOKEN="${SLACK_APP_TOKEN:-}"

[ -f "$HOME/.bash_profile" ] && source "$HOME/.bash_profile" 2>/dev/null
[ -f "$HOME/.profile" ] && source "$HOME/.profile" 2>/dev/null

# ~/.bashrc has an interactive guard that prevents vars defined after it from
# reaching non-interactive launchd shells (even via .bash_profile → .bashrc chain).
# Explicitly extract critical API keys that may fall after the guard.
_extract_bashrc_var() {
  local var="$1"
  # Skip if already set by dotfile chain
  [ -n "${!var:-}" ] && return
  local val
  val=$(grep -m1 "^export ${var}=" "$HOME/.bashrc" 2>/dev/null \
    | sed "s/^export ${var}=//;s/^['\"]//;s/['\"]$//" \
    | tr -d '\n')
  [ -n "$val" ] && export "$var=$val"
}
_extract_bashrc_var MINIMAX_API_KEY
_extract_bashrc_var MINIMAX_BASE_URL
_extract_bashrc_var MINIMAX_MODEL
_extract_bashrc_var MINIMAX_ANTHROPIC_BASE_URL
_extract_bashrc_var ANTHROPIC_API_KEY
_extract_bashrc_var OPENAI_API_KEY
_extract_bashrc_var OPENCODE_GO_API_KEY
_extract_bashrc_var SLACK_BOT_TOKEN
_extract_bashrc_var SLACK_APP_TOKEN
_extract_bashrc_var SLACK_BOT_TOKEN
_extract_bashrc_var OPENCLAW_SLACK_BOT_TOKEN
_extract_bashrc_var SLACK_MCP_XOXB_TOKEN
_extract_bashrc_var HERMES_OPS_SLACK_CHANNEL
unset -f _extract_bashrc_var

# Plumb the umbrella ops channel through to all launchd jobs. The watchdog,
# health-guardian, and cron scripts all read HERMES_OPS_SLACK_CHANNEL as a
# fallback when their per-script env var is empty or back-ass-guarded.
# Per-plist override wins (set EnvironmentVariables.HERMES_OPS_SLACK_CHANNEL
# in the plist); per-bashrc override also wins. Default is EMPTY per the
# umbrella pattern (PR #681, #687) — the plist is the source of truth.
export HERMES_OPS_SLACK_CHANNEL="${HERMES_OPS_SLACK_CHANNEL:-}"

# If HERMES_HOME is set (by plist), select the correct Slack tokens.
# .profile exports the PROD tokens as SLACK_BOT_TOKEN/SLACK_APP_TOKEN,
# but staging gateways need their own app+bot pair.
# Restore the plist-set tokens (which were staging) since .profile overwrote them.
if [ -n "$HERMES_HOME" ] && [ "$HERMES_HOME" != "$HOME/.smartclaw_prod" ]; then
  export SLACK_BOT_TOKEN="${_PLIST_SLACK_BOT_TOKEN:-${HERMES_STAGING_SLACK_BOT_TOKEN}}"
  export SLACK_APP_TOKEN="${_PLIST_SLACK_APP_TOKEN:-${HERMES_STAGING_SLACK_APP_TOKEN}}"
  export SLACK_MCP_XOXB_TOKEN="${SLACK_BOT_TOKEN}"
  # Staging must not hold Discord — only prod may use the Discord bot token.
  unset DISCORD_BOT_TOKEN
fi

# Drift check: ~/.bashrc and ~/.profile may each export SLACK_APP_TOKEN /
# OPENCLAW_SLACK_APP_TOKEN. Sourcing order in this wrapper is
# .bash_profile → .profile → .bashrc-grep, so .bashrc wins for the
# daemon even when .profile holds the correct value. This was the
# root cause of the 2026-06-18 "xapp- invalid_auth" outage — a one-
# line drift between the two files silently broke Socket Mode
# reconnect; restart alone did not fix it because .bashrc kept
# reasserting the stale value. Warn loudly on divergence so the
# next token rotation cannot repeat the mistake.
_assert_dotfile_token_consistency() {
  local label="$1"
  local bashrc_val profile_val
  bashrc_val=$(grep -m1 "^export ${label}=" "$HOME/.bashrc" 2>/dev/null \
    | sed "s/^export ${label}=//;s/^['\"]//;s/['\"]$//" | tr -d '\n')
  profile_val=$(grep -m1 "^export ${label}=" "$HOME/.profile" 2>/dev/null \
    | sed "s/^export ${label}=//;s/^['\"]//;s/['\"]$//" | tr -d '\n')
  if [ -n "$bashrc_val" ] && [ -n "$profile_val" ] && [ "$bashrc_val" != "$profile_val" ]; then
    echo "launchd-env-wrapper: WARNING ${label} drift between ~/.bashrc and ~/.profile" >&2
    echo "  ~/.bashrc:  ${bashrc_val:0:8}... (${#bashrc_val} chars)" >&2
    echo "  ~/.profile: ${profile_val:0:8}... (${#profile_val} chars)" >&2
    echo "  Sourcing order means .bashrc wins for the gateway. To fix:" >&2
    echo "    diff <(grep '^export ${label}=' ~/.bashrc) <(grep '^export ${label}=' ~/.profile)" >&2
    return 1
  fi
  return 0
}

_DOTFILE_CONSISTENCY_FAILED=0
_assert_dotfile_token_consistency OPENCLAW_SLACK_APP_TOKEN || _DOTFILE_CONSISTENCY_FAILED=1
_assert_dotfile_token_consistency OPENCLAW_SLACK_BOT_TOKEN || _DOTFILE_CONSISTENCY_FAILED=1
unset -f _assert_dotfile_token_consistency
export LAUNCHD_WRAPPER_DOTFILE_CONSISTENCY_OK=$([ "$_DOTFILE_CONSISTENCY_FAILED" -eq 0 ] && echo 1 || echo 0)
unset _DOTFILE_CONSISTENCY_FAILED

# Do NOT exit on drift — the daemon can still come up with the .bashrc
# value (which is the wrapper's intent). The warning is loud enough to
# surface during deploys and to `launchctl print` consumers that watch
# stderr; the LAUNCHD_WRAPPER_DOTFILE_CONSISTENCY_OK env var lets
# monitoring scripts (doctor.sh, monitor-agent.sh) detect drift
# without parsing stderr.

exec "$@"
