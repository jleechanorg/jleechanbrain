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
_extract_bashrc_var ANTHROPIC_API_KEY
_extract_bashrc_var OPENAI_API_KEY
unset -f _extract_bashrc_var

# If HERMES_HOME is set (by plist), select the correct Slack tokens.
# .profile exports the PROD tokens as SLACK_BOT_TOKEN/SLACK_APP_TOKEN,
# but staging gateways need their own app+bot pair.
# Restore the plist-set tokens (which were staging) since .profile overwrote them.
if [ -n "$HERMES_HOME" ] && [ "$HERMES_HOME" != "$HOME/.smartclaw_prod" ]; then
  export SLACK_BOT_TOKEN="${_PLIST_SLACK_BOT_TOKEN:-${HERMES_STAGING_SLACK_BOT_TOKEN}}"
  export SLACK_APP_TOKEN="${_PLIST_SLACK_APP_TOKEN:-${HERMES_STAGING_SLACK_APP_TOKEN}}"
  # Staging must not hold Discord — only prod may use the Discord bot token.
  unset DISCORD_BOT_TOKEN
fi

exec "$@"
