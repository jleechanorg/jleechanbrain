---
name: cron-jobs-and-messaging-credentials
description: Use when a cron job that needs Slack/Telegram/Discord/email credentials fails with "no token set" or "credential missing" — the cron subprocess has those vars stripped by `_sanitize_subprocess_env`, so LLM-driven cron jobs CANNOT access messaging credentials. Fix: convert to no-agent script mode.
---

# Cron jobs and messaging credentials

## The trap

Hermes cron jobs (`hermes cron`) run in the gateway process. When the cron tick spawns a child process (either the LLM agent's `terminal` tool, or a `--no-agent` script), the child goes through `_sanitize_subprocess_env` in `tools/environments/local.py`. That function strips:

- All provider API keys (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `OPENROUTER_API_KEY`, …)
- All messaging-platform tokens (`SLACK_BOT_TOKEN`, `SLACK_APP_TOKEN`, `TELEGRAM_HOME_CHANNEL`, `DISCORD_HOME_CHANNEL`, …)
- A handful of other "private" env vars

This is **deliberate** — it's a security feature to prevent the LLM from accidentally pasting tokens into file writes or web requests. As a result:

- An LLM-driven cron job that asks the LLM to "call Slack with curl" will *correctly* report `SLACK_BOT_TOKEN: not set` — that's not a hallucination, the token really is stripped.
- A `--no-agent` script that calls `os.getenv("SLACK_BOT_TOKEN")` will also get `None`.

## The fix

For cron jobs that need messaging credentials, convert to **no-agent mode** with a script that reads the token from the gateway env file directly:

```bash
# 1. Write the script
cat > ~/.smartclaw/scripts/slack_digest.py <<'EOF'
#!/usr/bin/env python3
import os
from pathlib import Path
from slack_sdk.web.async_client import AsyncWebClient

ENV_FILE = Path("/home/jleechan/.config/hermes/hermes-gateway.env")
# On prod installations the env file path may differ; check `launchctl print`
# for the gateway's `EnvironmentFile=` value.

def _load_token():
    token = os.getenv("SLACK_BOT_TOKEN")
    if token:
        return token
    for line in ENV_FILE.read_text().splitlines():
        if line.startswith("SLACK_BOT_TOKEN="):
            return line.split("=", 1)[1].strip().strip('"').strip("'")
    raise RuntimeError("SLACK_BOT_TOKEN not found")

async def main():
    client = AsyncWebClient(token=_load_token())
    # ... rest of the script
    resp = await client.conversations_history(channel="C0000000", oldest="...")
    # ... format and post
    await client.chat_postMessage(channel="...", text=..., thread_ts="...")
EOF
chmod +x ~/.smartclaw/scripts/slack_digest.py

# 2. Convert the cron job to no-agent mode
hermes cron edit <job_id> --script slack_digest.py --no-agent
```

The script runs as the same user as the gateway, so it has read permission on the env file. The env file is also referenced by the gateway's `EnvironmentFile=` in systemd/launchd, so the script doesn't need to import the gateway's process env — it just reads the file.

## Why token-in-env-file is OK here

The script's stdout is **redacted** by `agent.redact.redact_sensitive_text` before delivery. The token is read from the file once and never leaves the script. This is the same security boundary as the LLM-driven cron path — the script never sees the token being broadcast through `print()` or written to a file.

## Path gotcha: HERMES_HOME

If the gateway runs with `HERMES_HOME=/home/jleechan/.smartclaw/hermes` (or any non-default), then `~/.smartclaw/scripts/` resolves to `~/.smartclaw/hermes/scripts/`. Always put the script in BOTH paths or check the actual `HERMES_HOME`:

```bash
hermes_home=$(launchctl print gui/$(id -u)/ai.smartclaw.gateway 2>/dev/null \
              | grep -E "EnvironmentFile|HERMES_HOME" | head -5)
# Or from the running gateway process:
cat /proc/$(pgrep -f "hermes_cli.main gateway")/environ | tr '\0' '\n' | grep HERMES_HOME
```

## Alternative: pass-through

For non-messaging, non-provider vars (e.g. `TENOR_API_KEY`, third-party API keys): register via `tools.env_passthrough.register_env_passthrough([name])` or add to `terminal.env_passthrough` in config.yaml. **Do NOT** try to pass through `SLACK_BOT_TOKEN` or any other key in `_HERMES_PROVIDER_ENV_BLOCKLIST` — that path is gated by `GHSA-rhgp-j443-p4rf` to prevent skill-based bypass.

## Verification

After the fix:

```bash
hermes cron run <job_id>  # manual trigger
cat ~/.smartclaw/cron/jobs.json | python3 -c \
  'import json,sys; j=[x for x in json.load(sys.stdin)["jobs"] if x["id"]=="<job_id>"][0]; print({"last_status":j["last_status"],"last_error":j["last_error"]})'
```

Expect `last_status: ok`, `last_error: null`. The script's stdout will appear in the cron delivery target (Slack thread, Telegram, etc.).

## When this DOESN'T apply

- LLM-driven cron job that needs the LLM to think about the data but not to send anything → fine, just don't ask the LLM to call external APIs
- LLM-driven cron job that produces text only (no Slack/Telegram send) → fine, no credentials needed
- Script-mode cron that uses only internal resources (no external API) → fine, no blocklist hit
