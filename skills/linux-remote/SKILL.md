---
name: linux-remote
description: "Operate jeff-ubuntu via SSH. Use on /linux or Jeff-Ubuntu."
---

# Linux Remote — Operating on jeff-ubuntu

The user has a Linux box at `192.168.254.128` (hostname `Jeff-Ubuntu`, referred to in chat as **jeff-ubuntu**), configured as a `~/.ssh/config` alias for passwordless SSH from the MacBook. The `/linux` slash command resolves here. This skill is the canonical recipe for any work that should run on that machine.

The session may be running:
- **On the MacBook** (most common) — `ssh jeff-ubuntu` first, then execute
- **On jeff-ubuntu itself** — skip SSH, run commands directly
- **On a third host** — chain through jeff-ubuntu (less common, only when the user asks)

## Auto-detect loop (run before the first command)

```bash
# Am I already on the box?
uname -a
hostname
# If hostname == Jeff-Ubuntu OR ip == 192.168.254.128 → local, skip SSH
# Otherwise → ssh jeff-ubuntu first
```

When SSHing from the MacBook, use the passwordless alias `ssh jeff-ubuntu`. If the alias is missing (fresh install, lost `~/.ssh/config`), see `references/jeff-ubuntu-ssh-setup.md`.

## The 5-step "is the box healthy" probe

Run these in parallel via the terminal after connecting. **Do not skip even if the user's task is small** — Linux boxes drift from launchd-managed MacBook state in ways that break the wrong-line-of-investigation:

```bash
# 1. Connectivity
ping -c 1 -W 2 192.168.254.128 2>&1 | head -3

# 2. User identity (Linux user may differ from MacBook user)
whoami
id -un
ls -la ~/ 2>&1 | head -5

# 3. Is the gateway service running? (Linux uses systemd --user, NOT launchd)
systemctl --user is-active hermes-gateway
systemctl --user status hermes-gateway --no-pager 2>&1 | head -10

# 4. systemd env vs launchd env distinction
# Linux gateway uses EnvironmentFile= from systemd drop-in:
cat /home/$USER/.config/systemd/user/hermes-gateway.service.d/*.conf 2>/dev/null
# The actual env-var source is /home/$USER/.config/hermes/hermes-gateway.env
# Bashrc is NOT loaded by systemd units — `~/.bashrc` exports are invisible
# to the running gateway even when set in the user's shell.

# 5. Bashrc has the LOCAL-machine shell-session env vars
# Convert SLACK_BOT_TOKEN / OPENROUTER_API_KEY / HERMES_PC_SLACK_BOT_TOKEN
# expectations from "bashrc" to "EnvironmentFile" — same shape as macOS launchd
# gateway-env wrapper but on Linux it's a systemd EnvironmentFile.
grep -E "^(export )?(SLACK_BOT_TOKEN|OPENCLAW_SLACK_BOT_TOKEN|OPENROUTER_API_KEY|HERMES_PC_SLACK_BOT_TOKEN)" /home/$USER/.bashrc
```

If `bashrc` has the tokens but the systemd unit doesn't reference them, **the cron tick will fail with "SLACK_BOT_TOKEN not set"** even though `bash -l -c 'echo $SLACK_BOT_TOKEN'` shows them. This is the most common Linux-specific footgun. Fix: copy the relevant lines into `~/.config/hermes/hermes-gateway.env` and `systemctl --user daemon-reload && systemctl --user restart hermes-gateway`.

## Probing long-running HTTP daemons (ao-go, sidecars)

When a cron reporter / health check needs to know whether a long-running HTTP daemon on /linux is alive, **db-file mtime is the wrong signal** — a healthy-but-idle daemon legitimately doesn't write the file for hours/days. The canonical probe is `/healthz` over SSH, kept short so a network blip doesn't stall the parent:

```bash
# ao-go on default port 3001; substitute the real port + URL for other daemons
ssh -o ConnectTimeout=4 -o BatchMode=yes jeff-ubuntu \
  "curl -fsS -m 2 'http://127.0.0.1:3001/healthz' 2>/dev/null | grep -q '\"status\":\"ok\"' && echo up || echo down"
# exit code 0 with stdout "up"  → daemon alive and serving
# stdout "down"                 → daemon NOT responding (may be dead, starting, or port mismatched)
# non-zero exit                 → SSH itself failed (host unreachable, auth)
```

For daemons with no HTTP listener but a pidfile / runfile, fall back to `kill -0` on the recorded pid:

```bash
pid=$(ssh -o ConnectTimeout=4 -o BatchMode=yes jeff-ubuntu \
  "jq -r '.pid' ~/.ao/running.json 2>/dev/null" 2>/dev/null)
if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
  echo "alive (pid $pid)"
else
  echo "DEAD — run-file points to a stale pid"
fi
```

The full diagnostic for why this matters (mtime-based "stale db" warnings hiding a dead Mac daemon for 10 days while the false positive fired every 30 min) is in `~/.smartclaw/skills/devops/slack-cron-report-health/references/2026-08-13-aopr-true-stuck-vs-false-stale.md`. The pattern generalizes: probe `/linux` daemons the same way you probe localhost daemons, just with one extra SSH hop.

## Linux-vs-MacBook differences that bite

| Behavior | MacBook (launchd) | Linux (systemd) |
|---|---|---|
| User service runtime | `~/Library/LaunchAgents/<label>.plist` | `~/.config/systemd/user/<label>.service` (+ drop-ins in `.d/`) |
| Env-var source for shared creds | `~/Library/LaunchAgents/<svc>.plist` `EnvironmentFile` | `~/.config/systemd/user/<svc>.service.d/*.conf` `EnvironmentFile` |
| Bashrc seen by service? | No (service runs without sourcing bashrc) | No (same — systemd units don't source bashrc) |
| Restart command | `launchctl kickstart -k gui/$(id -u)/<label>` | `systemctl --user restart <label>` |
| Inspect env at runtime | `ps -p <PID> -o pid,cmd` + `lsof -p <PID> -E` | `cat /proc/<PID>/environ` (NULL-separated, pipe to `tr '\0' '\n'`) |
| Cron job storage | `~/.smartclaw/cron/jobs.json` | `~/.smartclaw/cron/jobs.json` (same) |
| Hermes venv | `~/.smartclaw/hermes-agent/venv` | `~/.smartclaw/hermes-agent/venv` (same) |
| Cron ticker heartbeat file | `~/.smartclaw/cron/ticker_heartbeat` | `~/.smartclaw/cron/ticker_heartbeat` (same) |
| Socket-mode Slack availability | yes for prod | yes (Linux runs socket-mode the same way) |

## The heredoc-less pattern for multi-step SSH work

Avoid running 6 separate `ssh jeff-ubuntu '...'` calls when 1 will do. Pattern:

```bash
ssh jeff-ubuntu 'set -o pipefail; step1; step2; step3' 2>&1 | head -100
```

For longer commands, write a script to `/tmp/hermes_pc_<ts>.sh` on the remote, scp it up, then `ssh jeff-ubuntu 'bash /tmp/hermes_pc_<ts>.sh'`. This:
- Avoids shell-quoting hell from nested quotes
- Lets you re-run the same probe later without re-typing
- Makes the audit trail durable (the script file is on the box)

## What NOT to do

- **Don't run `hermes cron run <job_id>` from a non-systemd shell** — the gateway env (EnvironmentFile) doesn't load automatically. Either source `/home/$USER/.config/hermes/hermes-gateway.env` first or run the tick via the Python tool API directly.
- **Don't assume cron jobs are healthy just because `last_status: ok`** — the LLM may have fabricated the response. Read the output md in `~/.smartclaw/cron/output/<job_id>/` and verify the LLM actually called the platform tools rather than hallucinated an "X not set" answer.
- **Don't trust cron `last_status: ok` from the gateway's last run** — the agent.log may show the LLM's "I can't find SLACK_BOT_TOKEN" text even when status=ok. Cross-check `last_run_at` vs `last_error` separately.
- **Don't skip the `systemctl --user status` check** — if the gateway is down, no cron ticks will fire no matter how correctly the jobs.json is written.

## Quick run-anyway playbook

If the user just wants to run a single command, the fastest path is:

```bash
ssh jeff-ubuntu 'set -o pipefail; <command>' 2>&1 | head -50
```

For multi-step work, see `references/linux-remote-patterns.md` for the longer-form patterns (Python inline scripts, file transfers, gateway restarts).

## Installing a package / prerequisite on jeff-ubuntu

When the user asks to install or provision a tool or skill on BOTH machines (e.g. "install /plan-micro on this machine and /linux"), the macOS half is straightforward; the Linux half has three recurring pitfalls that bite installs every time.

**Pitfall 1 — `claude` CLI is NOT pre-installed on jeff-ubuntu.** The MacBook has `claude` at `~/.local/bin/claude` (verified 2026-08-13: v2.1.229). The Linux box has only the canonical Ubuntu `node` + `npm`. To install:

```bash
# jeff-ubuntu already has node v24.15.0 at /usr/bin/node and npm at /usr/bin/npm
# npm global prefix is /home/jleechan/.npm-global (NOT /usr/local)
ssh jeff-ubuntu '
  export PATH=/home/jleechan/.npm-global/bin:$PATH
  npm install -g @anthropic-ai/claude-code 2>&1 | tail -5
  which claude
  claude --version
'
# After install: claude lives at /home/jleechan/.npm-global/bin/claude
# Either add it to PATH every time, or symlink into ~/.local/bin which IS on PATH
ssh jeff-ubuntu 'ln -sf /home/jleechan/.npm-global/bin/claude ~/.local/bin/claude'
```

Verify before assuming the install worked — `npm install` exits 0 silently but the binary may land elsewhere. Always `which claude` + `claude --version` after install.

**Pitfall 2 — `beads` CLI (`br`) is at `~/.local/bin/br`, NOT on default PATH.** `which br` returns nothing on a fresh shell. Either `export PATH="$HOME/.local/bin:$PATH"` at the top of every SSH block, or call the full path: `~/.local/bin/br`. The legacy `bd` Cargo binary is NOT installed — `beads-rs` is the canonical CLI on this machine.

**Pitfall 3 — macOS resource forks (`._*` files) survive `scp` into Linux.** When scp'ing a tarball created on macOS, the `._SKILL.md`, `._commands/`, etc. files come along. They appear in `find` output and inflate the file count by 2x. Strip them after unpacking:

```bash
ssh jeff-ubuntu '
  tar -xzf /tmp/pkg.tar.gz -C /tmp/ 2>/dev/null  # "Ignoring unknown extended header" warnings are harmless
  find ~/.claude/skills/<name> -name "._*" -delete
  find ~/.claude/skills/<name> -type f | sort   # verify clean count
'
```

**Transfer-then-install pattern (canonical for slash-command / skill packages).** Don't run 6 separate SSH commands — push the tarball in one shot, then run the install unpack in one ssh block:

```bash
# 1. Push the tarball (faster than scp'ing individual files)
scp /path/to/pkg.tar.gz jeff-ubuntu:/tmp/pkg.tar.gz

# 2. Single ssh block does: unpack → strip resource forks → install → verify
ssh jeff-ubuntu 'set -euo pipefail
  rm -rf /tmp/pkg && mkdir -p /tmp/pkg
  tar -xzf /tmp/pkg.tar.gz -C /tmp/pkg 2>/dev/null || true
  find /tmp/pkg -name "._*" -delete
  mkdir -p ~/.claude/commands
  cp /tmp/pkg/commands/<cmd>.md ~/.claude/commands/
  if [ -d ~/.claude/skills/<name> ] && [ ! -e ~/.claude/skills/<name>.bak ]; then
    cp -R ~/.claude/skills/<name> ~/.claude/skills/<name>.bak
  fi
  rm -rf ~/.claude/skills/<name>
  cp -R /tmp/pkg/skills/<name> ~/.claude/skills/<name>
  find ~/.claude/commands/<cmd>.md ~/.claude/skills/<name> -type f | sort
  find ~/.claude/commands/<cmd>.md ~/.claude/skills/<name> -type f | wc -l
'
```

**Hash parity proof when auth blocks the runtime smoke test.** If the install is correct but `claude -p "/<cmd> test scope"` fails on OAuth (user's session expired, or no auth on the box at all), **hash parity across both machines + file integrity IS a valid install proof**. Don't fabricate "smoke test passed" — explicitly state: "install verified by hash parity; runtime smoke test blocked on OAuth refresh wall, which requires the user's interactive browser session."

```bash
# macOS:
md5 -q ~/.claude/commands/<cmd>.md ~/.claude/skills/<name>/SKILL.md ...

# jeff-ubuntu:
ssh jeff-ubuntu 'md5sum ~/.claude/commands/<cmd>.md ~/.claude/skills/<name>/SKILL.md ...'
# Compare: hashes MUST match across both machines.
```

When reporting this state, label the blocker explicitly: "Install complete and verified. Runtime smoke test blocked on auth — open a terminal and run `claude auth login` (~30s browser flow) to enable `/<cmd>`. The user has the same view the report claims."

**Don't punt with "you can run X" — first run the 4-step diagnostic in `references/claude-auth-wall-diagnostic.md` to PROVE the wall is real.** Dropped-thread followup flags insufficient OAuth-wall handoffs; cheap probes (`claude auth status` + keychain + `--non-interactive` flag check + bashrc audit) take <10 seconds and produce evidence-backed blocker reports instead of punt-as-handoff.

## References

- `references/jeff-ubuntu-ssh-setup.md` — how to set up the passwordless SSH alias when this skill is first adopted.
- `references/linux-remote-patterns.md` — ready-to-copy recipes for common Linux-on-jeff-ubuntu tasks (gateway restart, cron job diagnosis, log inspection, file transfers).
- `references/systemd-gateway-env-vs-bashrc.md` — the canonical "why doesn't my bashrc export show up in the gateway process" recipe, with the exact `EnvironmentFile` migration steps.
- `references/claude-auth-wall-diagnostic.md` — 4-step cheap probe (`claude auth status` → keychain → `--non-interactive` flag check → bashrc fallback audit) to distinguish OAuth-wall from install-break. **Use this BEFORE reporting "blocked on user auth"** — dropped-thread followup flags insufficient punts.
