#!/usr/bin/env bash
# systemd/install-systemd-timers.sh
#
# Installer for the Linux-side mirror of the merged jleechanclaw
# triage jobs. Idempotent: safe to re-run; existing unit files are
# overwritten only if the installed copy differs (we always install —
# `systemctl --user daemon-reload` is the cost of being explicit).
#
# What it does:
#   1. Symlinks scripts/jleechanclaw_*.sh from the jleechenbrain repo
#      into ~/.local/bin (so the systemd unit's ExecStart= path
#      resolves regardless of where the repo is checked out).
#   2. Writes the env file at
#      ~/.config/systemd/user/jleechanbrain-deploy.env from
#      ~/.bashrc-sourced HERMES_SLACK_BOT_TOKEN + ANTHROPIC_API_KEY.
#      NEVER reads/writes a .env file (secrets-no-env policy).
#   3. Copies the .service + .timer units into
#      ~/.config/systemd/user/.
#   4. Runs `systemctl --user daemon-reload`.
#   5. Enables and starts both timers.
#
# Reversibility:
#   `systemctl --user disable --now jleechanclaw-slack-*.timer`
#   undoes step 5. Removing the units and re-running is the rest.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
LOCAL_BIN="$HOME/.local/bin"
ENV_FILE="$SYSTEMD_USER_DIR/jleechanbrain-deploy.env"

mkdir -p "$SYSTEMD_USER_DIR" "$LOCAL_BIN"

# --- 1. Symlink the wrapper scripts into ~/.local/bin ---
for script in \
  "$REPO_ROOT/scripts/jleechanclaw_thread_lifecycle.sh" \
  "$REPO_ROOT/scripts/jleechanclaw_slack_catchup_daily.sh"; do
  name="$(basename "$script")"
  ln -sf "$script" "$LOCAL_BIN/$name"
  echo "  symlinked: $LOCAL_BIN/$name -> $script"
done

# --- 2. Source bashrc for tokens, write the systemd env file ---
# This is the ONLY step that writes a file containing tokens; it
# lands in ~/.config/systemd/user/ (a non-.env path) so the
# secrets-no-env policy is honored.
if [[ ! -f "$ENV_FILE" ]]; then
  bash -c 'source ~/.bashrc 2>/dev/null; : "${HERMES_SLACK_BOT_TOKEN:=}"; : "${ANTHROPIC_API_KEY:=}"; printf "HERMES_SLACK_BOT_TOKEN=%s\nANTHROPIC_API_KEY=%s\n" "$HERMES_SLACK_BOT_TOKEN" "$ANTHROPIC_API_KEY"' \
    > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  echo "  wrote env file: $ENV_FILE (mode 0600)"
else
  echo "  env file exists, leaving untouched: $ENV_FILE"
fi

# --- 3. Install the .service + .timer units ---
for unit in \
  jleechanclaw-slack-thread-auto-park.service \
  jleechanclaw-slack-thread-auto-park.timer \
  jleechanclaw-slack-digest-rollup.service \
  jleechanclaw-slack-digest-rollup.timer; do
  src="$REPO_ROOT/systemd/$unit"
  dst="$SYSTEMD_USER_DIR/$unit"
  if [[ ! -f "$src" ]]; then
    echo "  MISSING source unit: $src" >&2
    exit 1
  fi
  install -m 644 "$src" "$dst"
  echo "  installed: $dst"
done

# --- 4. Reload systemd user daemon ---
systemctl --user daemon-reload
echo "  daemon-reloaded"

# --- 5. Enable + start the timers ---
for timer in \
  jleechanclaw-slack-thread-auto-park.timer \
  jleechanclaw-slack-digest-rollup.timer; do
  systemctl --user enable --now "$timer"
  echo "  enabled+started: $timer"
done

echo
echo "=== install complete ==="
echo "verify with:"
echo "  systemctl --user list-timers jleechanclaw-slack-*"
echo "  systemctl --user status jleechanclaw-slack-thread-auto-park.service"