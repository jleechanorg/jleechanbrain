# Hermes Agent — Primary AI Agent

**Hermes Agent** (Nous Research) is the primary AI agent. Hermes is **disabled** unless explicitly re-enabled.

## Architecture

| | Hermes Staging | Hermes Prod |
|---|---|---|
| **Directory** | `~/.smartclaw/` (git repo) | `~/.smartclaw_prod/` |
| **Launchd** | `ai.smartclaw-staging` | `ai.smartclaw.prod` |
| **Slack bot** | Staging app (`xoxb-...roQR...`) | Prod app (`xoxb-...L1ZG...`) |
| **Model** | `minimax-portal/MiniMax-M2.7` | `minimax-portal/MiniMax-M2.7` |
| **HERMES_HOME** | `~/.smartclaw/` | `~/.smartclaw_prod/` |
| **Tokens** | Staging Slack | Prod Slack |

**Directory structure:**
```
~/.smartclaw/          ← git repo root (jleechanbrain), Hermes staging
~/.smartclaw/        ← symlink → ~/.smartclaw/ (backward compat)
~/.smartclaw_prod/     ← Hermes prod (separate runtime data)
```

**Hermes is disabled** — set `HERMES_ENABLED=1` in the monitor to re-enable AO checks.

## Quick Start

### Run Hermes Monitor

```bash
bash ~/.smartclaw/scripts/hermes-monitor.sh
```

### Check Status

```bash
hermes status                        # staging
HERMES_HOME=~/.smartclaw_prod hermes status   # prod
```

### Start/Stop Gateways

```bash
launchctl start gui/$(id -u)/ai.smartclaw-staging   # start staging
launchctl stop gui/$(id -u)/ai.smartclaw-staging    # stop staging
launchctl start gui/$(id -u)/ai.smartclaw.prod     # start prod
launchctl stop gui/$(id -u)/ai.smartclaw.prod      # stop prod
```

Or manually:
```bash
HERMES_HOME=~/.smartclaw hermes gateway run        # staging (foreground)
HERMES_HOME=~/.smartclaw_prod hermes gateway run  # prod (foreground)
```

### Restart a Gateway

```bash
launchctl kickstart -kp gui/$(id -u)/ai.smartclaw-staging
launchctl kickstart -kp gui/$(id -u)/ai.smartclaw.prod
```

## Gateway Details

| | Hermes Staging | Hermes Prod |
|---|---|---|
| **Launchd label** | `ai.smartclaw-staging` | `ai.smartclaw.prod` |
| **Slack tokens** | Staging | Prod |
| **Memory** | `~/.smartclaw/memories/` | `~/.smartclaw_prod/memories/` |
| **Sessions** | `~/.smartclaw/sessions/` | `~/.smartclaw_prod/sessions/` |
| **Skills** | `~/.smartclaw/skills/` | `~/.smartclaw_prod/skills/` |

## Configuration Files

### Staging `.env` (`~/.smartclaw/.env`)

```bash
HERMES_ENABLED=true
HERMES_ENV=staging
HERMES_HOME=${HOME}/.smartclaw

# Slack — STAGING tokens
SLACK_BOT_TOKEN=&lt;SLACK_BOT_TOKEN&gt;
SLACK_APP_TOKEN=&lt;SLACK_APP_TOKEN&gt;

HERMES_STATE_DIR=${HOME}/.smartclaw/
HERMES_CONFIG_PATH=${HOME}/.smartclaw/config.yaml
GATEWAY_ALLOW_ALL_USERS=true
```

### Prod `.env` (`~/.smartclaw_prod/.env`)

```bash
HERMES_ENABLED=true
HERMES_ENV=prod
HERMES_HOME=${HOME}/.smartclaw_prod

# Slack — PROD tokens
SLACK_BOT_TOKEN=&lt;SLACK_BOT_TOKEN&gt;
SLACK_APP_TOKEN=&lt;SLACK_APP_TOKEN&gt;

HERMES_STATE_DIR=${HOME}/.smartclaw_prod/
HERMES_CONFIG_PATH=${HOME}/.smartclaw_prod/config.yaml
GATEWAY_ALLOW_ALL_USERS=true
```

## Known Issues

### Discord/Telegram token conflicts

Both Hermes instances share the same `auth.json` for Discord/Telegram, causing "token already in use" warnings. **Non-critical** — Slack works correctly on both since they use separate Slack apps/tokens.

## Troubleshooting

### Gateway won't start

```bash
hermes gateway status                    # staging
HERMES_HOME=~/.smartclaw_prod hermes gateway status  # prod
hermes doctor
cat ~/.smartclaw/logs/gateway.log         # staging
cat ~/.smartclaw_prod/logs/gateway.log    # prod
```

### Slack not responding

```bash
hermes status                        # check Slack ✓
# Verify tokens:
rg 'SLACK_BOT_TOKEN' ~/.smartclaw/.env        # staging
rg 'SLACK_BOT_TOKEN' ~/.smartclaw_prod/.env  # prod
```

### Re-enable Hermes (AO path)

Hermes AO is currently disabled. To re-enable:

```bash
HERMES_ENABLED=1 bash ~/.smartclaw/scripts/hermes-monitor.sh
```

Launchd services to load:
```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/ai.smartclaw.prod.plist
launchctl start gui/$(id -u)/ai.smartclaw.prod
```
