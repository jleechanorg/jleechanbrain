---
name: systemd-gateway-env-vs-bashrc
description: "Why ~/.bashrc exports are invisible to the gateway process on Linux, and how to migrate them to the systemd EnvironmentFile."
---

# systemd Gateway Environment vs bashrc — the migration recipe

The Linux-side `hermes-gateway` runs as a `systemd --user` unit. systemd units do **not** source `~/.bashrc` — the unit starts in a stripped shell that has only the env vars from:
1. The `Environment=` lines in the unit file itself
2. The `EnvironmentFile=` directives (typically a drop-in `*.conf` in `.service.d/`)
3. The systemd manager's default env (NOT including login-shell exports)

This is the same as launchd on the MacBook, but the env-var storage location differs:

| Pattern | MacBook (launchd) | Linux (systemd) |
|---|---|---|
| Per-service env file | `~/Library/LaunchAgents/<svc>.plist` `EnvironmentVariables` | `~/.config/systemd/user/<svc>.service.d/<name>.conf` `EnvironmentFile=` |
| Plain env file referenced | `EnvironmentVariables` inline KV pairs | `EnvironmentFile=/path/to/file` (separate file with `KEY=VALUE` lines) |
| Shell-session env vars | `~/.bashrc` / `~/.zshrc` (only available in interactive shell) | `~/.bashrc` (only available in interactive shell, NEVER in services) |

## Symptom (the trap)

A user adds `export SLACK_BOT_TOKEN="xoxb-..."` to `~/.bashrc`:

```bash
$ bash -l -c 'echo "$SLACK_BOT_TOKEN"'
xoxb-...

# But the cron tick fails with:
# RuntimeError: No LLM provider configured.
# ...or the LLM response says "SLACK_BOT_TOKEN not set"
```

The cron tick runs in the gateway's process tree, NOT in a login shell. bashrc never gets sourced.

## The fix (the recipe)

Three steps — always in this order:

### Step 1: write the env to a flat file

```bash
# Reuse the gateway env file systemd already points at
# (typically /home/$USER/.config/hermes/hermes-gateway.env)
# Add/update the keys you need

KEY="xoxb-..."
# Append or replace existing entries (preserve comments)
echo "SLACK_BOT_TOKEN=$KEY" >> /home/$USER/.config/hermes/hermes-gateway.env
chmod 600 /home/$USER/.config/hermes/hermes-gateway.env
```

### Step 2: verify the systemd drop-in points to it

```bash
systemctl --user cat hermes-gateway
# Should show under [Service] drop-in:
#   EnvironmentFile=/home/$USER/.config/hermes/hermes-gateway.env
```

If the drop-in doesn't exist, create one:

```bash
sudo mkdir -p /home/$USER/.config/systemd/user/hermes-gateway.service.d
cat > /home/$USER/.config/systemd/user/hermes-gateway.service.d/10-env-file.conf << 'EOF'
[Service]
EnvironmentFile=/home/$USER/.config/hermes/hermes-gateway.env
EOF
```

### Step 3: reload and restart

```bash
systemctl --user daemon-reload
systemctl --user restart hermes-gateway
sleep 3
# Verify
systemctl --user status hermes-gateway --no-pager | head -10
# Spot-check: env is now visible to the process
cat /proc/$(systemctl --user show -p MainPID --value hermes-gateway)/environ | tr '\0' '\n' | grep SLACK_BOT_TOKEN | head -1
```

### Step 4: trigger a cron tick and verify

```bash
# Don't run from a non-systemd shell (it won't see the env).
# Run via the cron job's natural schedule, OR run the gateway tick internally:
ssh jeff-ubuntu 'set -o pipefail; set -o allexport; source /home/$USER/.config/hermes/hermes-gateway.env; set +o allexport; /home/$USER/.smartclaw/hermes-agent/venv/bin/python -c "import os; print(\"SLACK_BOT_TOKEN set:\", bool(os.environ.get(\"SLACK_BOT_TOKEN\")))"'
```

## Common gotchas

- **`daemon-reload` is mandatory.** The cached unit config in systemd is read once on plist load. Editing the `.conf` file does nothing until `daemon-reload`.
- **Restart, don't just reload.** `systemctl --user reload hermes-gateway` sends SIGHUP, but the env-var change requires a full process restart to re-exec the children.
- **Check that the env file is 0600.** systemd logs a warning if the file is world-readable. `chmod 600` it.
- **Don't `echo` secrets to the env file when running over an SSH session that gets logged.** Use the SSH `~/secrets/hermes-gateway.env` indirection pattern if shell history is a concern.
- **The bashrc export stays useful** for interactive shells (you still want `bash -l` to see `OPENROUTER_API_KEY` for ad-hoc curl). Just don't expect it to reach the gateway.
- **OPENROUTER_API_KEY in bashrc, but OpenRouter key died** — different failure mode (auth dead, not env missing). The diagnostic output here is "User not found" / 401, not "SLACK_BOT_TOKEN not set". Run `curl -fsS -H "Authorization: Bearer $OPENROUTER_API_KEY" https://openrouter.ai/api/v1/auth/key` to verify the key is alive.

## Why this trap bites Linux sessions specifically

On the MacBook, launchd agents can read `~/.bashrc` via `Source /path/to/.bashrc` (rare but supported). On Linux, systemd units have NO option to source a shell init file — it's a hardening feature, not a bug. The migration from bashrc to EnvironmentFile is therefore unavoidable when moving from "I export keys in my shell" to "I run a long-lived service that needs those keys."

If a user reports "cron failed because X is not set" and the env var is in bashrc, this is the recipe. Always.
