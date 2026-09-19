---
name: hermes-single-dir-pipeline
description: Operate Hermes after the single-directory runtime migration.
---

# Hermes Single-Directory Pipeline

## Scope

`~/.smartclaw` is the single canonical Hermes root for source, production runtime
state, logs, sessions, credentials references, skills, cron, and launchd
templates.

Production:
- Label: `ai.smartclaw.prod`
- Port: `8643`
- Config: `~/.smartclaw/config.yaml`
- State dir: `~/.smartclaw`

Staging is an explicit variant, not a second source tree:
- Label: `ai.smartclaw.staging`
- Port: `8644`
- Config: `~/.smartclaw/config.staging.yaml` overlay
- State dir: `~/.smartclaw`

The retired prod directory name must not be used in commands, docs, plists, or
operator workflows. A compatibility symlink may exist for old tools, but it is
not a deploy target or source of truth.

## Operating Model

```text
~/.smartclaw
  config.yaml                  production config
  config.staging.yaml          staging overlay, only when staging is loaded
  scripts/deploy.sh            pull, restart prod, verify
  scripts/staging-canary.sh    health/canary checks for selected port
  launchd/                     committed plist templates
  logs/gateway.log             prod stdout
  logs/gateway.err.log         prod stderr
```

`scripts/deploy.sh` no longer promotes from one home directory into another.
It operates on the canonical repo, restarts `ai.smartclaw.prod`, and validates the
running service. Policy and skills drift checks are same-root checks in this
model.

## Required Checks

Before claiming Hermes is healthy:

```bash
launchctl print gui/$(id -u)/ai.smartclaw.prod
curl -fsS -m 8 http://127.0.0.1:8643/health
tail -80 ~/.smartclaw/logs/gateway.err.log
```

For Slack-specific incidents, HTTP health is insufficient. Check recent logs
for Socket Mode connection/auth lines and send or observe a real Slack message
round trip when possible.

## Installation And Repair

```bash
cd ~/.smartclaw
bash scripts/install-launchagents.sh
bash scripts/deploy.sh
```

Launchd templates must live in `~/.smartclaw/launchd/` and be committed with
`@HOME@` placeholders. Do not hand-create long-lived plists directly under
`~/Library/LaunchAgents` without a matching template in the repo.

## Staging

Staging exists to test the same code and same root with a different Slack app
and overlay config. It should be loaded only for intentional tests:

```bash
launchctl print gui/$(id -u)/ai.smartclaw.staging
curl -fsS -m 8 http://127.0.0.1:8644/health
```

If staging is not loaded, that is not a production outage. Production health is
always checked through `ai.smartclaw.prod` and port `8643`.

## Troubleshooting

Gateway not responding:

```bash
lsof -nP -iTCP:8643 -sTCP:LISTEN
launchctl print gui/$(id -u)/ai.smartclaw.prod
tail -80 ~/.smartclaw/logs/gateway.err.log
```

Session lock silent failure:

```bash
find ~/.smartclaw/agents/main/sessions/ -name "*.lock" | while read f; do
  raw=$(cat "$f" 2>/dev/null)
  pid=$(echo "$raw" | python3 -c "import sys,json; print(json.load(sys.stdin)['pid'])" 2>/dev/null || echo "$raw" | tr -d '[:space:]')
  [[ "$pid" =~ ^[0-9]+$ ]] && ! kill -0 "$pid" 2>/dev/null && rm -f "$f" && echo "removed: $f"
done
launchctl kickstart -k gui/$(id -u)/ai.smartclaw.prod
```

Native module check:

```bash
GATEWAY_NODE="$HOME/.nvm/versions/node/v22.22.0/bin/node"
"$GATEWAY_NODE" -e "require('$HOME/.smartclaw/extensions/hermes-mem0/node_modules/better-sqlite3')" && echo OK
```

Duplicate gateway check:

```bash
pgrep -af "hermes gateway|bin/hermes"
lsof -nP -iTCP:8643 -sTCP:LISTEN
lsof -nP -iTCP:8644 -sTCP:LISTEN
```

Expected steady state is one production listener on `8643`. A staging listener
on `8644` is acceptable only during explicit staging tests.
