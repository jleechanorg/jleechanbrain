#!/usr/bin/env bash
# systemd/install-systemd-timers.sh
#
# Installer for the Linux-side mirror of the merged jleechanclaw
# triage jobs. Idempotent: safe to re-run; existing unit files are
# overwritten only if the installed copy differs (we always install —
# `systemctl --user daemon-reload` is the cost of being explicit).
#
# What it does:
#   1. Symlinks scripts/jleechanclaw_*.sh from the jleechanbrain repo
#      into ~/.local/bin (so the systemd unit's ExecStart= path
#      resolves regardless of where the repo is checked out).
#   2. Writes the token file at
#      ~/.config/systemd/user/jleechanbrain-deploy-tokens.conf from
#      ~/.bashrc-sourced HERMES_SLACK_BOT_TOKEN + ANTHROPIC_API_KEY,
#      resolved via an INTERACTIVE shell (bash -ic) so ~/.bashrc's
#      interactive guard doesn't skip the token exports and any
#      variable-indirection exports (e.g. HERMES_SLACK_BOT_TOKEN=
#      "$HERMES_PC_SLACK_BOT_TOKEN") are expanded. Fails loudly (exit 1)
#      if either resolves empty rather than writing a broken file.
#      NEVER writes a `.env`-named file (secrets-no-env policy).
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
ENV_FILE="$SYSTEMD_USER_DIR/jleechanbrain-deploy-tokens.conf"

mkdir -p "$SYSTEMD_USER_DIR" "$LOCAL_BIN"

# --- 1. Symlink the wrapper scripts into ~/.local/bin ---
for script in \
  "$REPO_ROOT/scripts/jleechanclaw_thread_lifecycle.sh" \
  "$REPO_ROOT/scripts/jleechanclaw_slack_catchup_daily.sh"; do
  name="$(basename "$script")"
  ln -sf "$script" "$LOCAL_BIN/$name"
  echo "  symlinked: $LOCAL_BIN/$name -> $script"
done

# --- 2. Source bashrc for tokens, write the systemd token file ---
# This is the ONLY step that writes a file containing tokens; it
# lands in ~/.config/systemd/user/*.conf (never a `.env`-named path)
# so the secrets-no-env policy is honored.
#
# `bash -c '...'` runs a NON-interactive shell — ~/.bashrc's standard
# interactive guard (`case $- in *i*) ;; *) return;; esac`) returns
# BEFORE the token exports, so both vars would resolve empty. Use
# `bash -ic` instead: an interactive shell auto-sources ~/.bashrc,
# passes the guard, AND expands variable-indirection exports (e.g.
# `export HERMES_SLACK_BOT_TOKEN="$HERMES_PC_SLACK_BOT_TOKEN"`) that a
# grep-based literal extraction would miss.
regenerate_needed=1
if [[ -f "$ENV_FILE" ]]; then
  if grep -q '^HERMES_SLACK_BOT_TOKEN=$' "$ENV_FILE"; then
    echo "  token file exists but contains an empty value — regenerating: $ENV_FILE"
  else
    echo "  token file exists and looks populated, leaving untouched: $ENV_FILE"
    regenerate_needed=0
  fi
fi

if [[ "$regenerate_needed" -eq 1 ]]; then
  HERMES_SLACK_BOT_TOKEN="$(bash -ic 'printf %s "$HERMES_SLACK_BOT_TOKEN"' 2>/dev/null || true)"
  ANTHROPIC_API_KEY="$(bash -ic 'printf %s "$ANTHROPIC_API_KEY"' 2>/dev/null || true)"

  # HERMES_SLACK_BOT_TOKEN is mandatory — the digest cannot post without it.
  if [[ -z "$HERMES_SLACK_BOT_TOKEN" ]]; then
    echo "  FATAL: could not resolve a non-empty HERMES_SLACK_BOT_TOKEN via 'bash -ic'." >&2
    echo "    Check that ~/.bashrc exports it (directly or via indirection) for an interactive, non-login shell." >&2
    exit 1
  fi
  # ANTHROPIC_API_KEY is optional — llm_call_util falls back to the
  # `claude -p` CLI subprocess when the SDK has no key (the digest wrapper
  # extends PATH so the CLI resolves under systemd). Warn, don't abort:
  # a box with only claude-CLI subscription auth is a supported deploy.
  if [[ -z "$ANTHROPIC_API_KEY" ]]; then
    echo "  WARN: ANTHROPIC_API_KEY resolved empty — tier classification will use the claude CLI fallback (requires 'claude' on PATH)." >&2
    if ! bash -ic 'command -v claude' >/dev/null 2>&1; then
      echo "  FATAL: no ANTHROPIC_API_KEY AND no 'claude' CLI found — the LLM classifier has no working path." >&2
      exit 1
    fi
  fi

  printf 'HERMES_SLACK_BOT_TOKEN=%s\nANTHROPIC_API_KEY=%s\n' \
    "$HERMES_SLACK_BOT_TOKEN" "$ANTHROPIC_API_KEY" > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  echo "  wrote token file: $ENV_FILE (mode 0600)"
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