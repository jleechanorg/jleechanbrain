---
name: background-daemon-config-edit
description: Edit config of a daemon like RustDesk or Syncthing.
---

# Background Daemon Config Edit

When a user asks to change a setting on a long-running background service, the naive approach (open the file, add the key, save) often silently fails. Background daemons typically:

1. **Read config once at startup** into an in-memory cache
2. **Own the file** — write it back whenever a setting changes (via GUI / IPC / auto-save), normalizing keys and dropping any key it does not recognize
3. **Run as root** (LaunchAgent on macOS, system systemd unit on Linux) so you cannot SIGTERM them without sudo

Two consequences: edits while the daemon is running are wiped the next time the daemon re-saves; applying edits requires a restart that needs elevated privileges.

## Procedure

1. **Locate the config file.** macOS: `~/Library/Preferences/<bundle-id>/` or `/Library/Application Support/<name>/`. Linux: `~/.config/<name>/` or `~/.local/share/<name>/`. Confirm with `pgrep -fa <daemon>` to find both the binary and the bundle ID.

2. **Confirm canonical option keys by grepping the binary.** Do not guess key names from docs alone — the binary often has both a hyphenated form (config key) and an underscored form (UI/i18n key) sitting adjacent in `strings` output.
   ```bash
   strings -a <daemon-binary> | grep -E "^enable-|^disable_|^allow-" | sort -u
   ```
   Pick the ones that match the doc table, not the ones adjacent to a translation key.

3. **Edit using an upsert helper, not sed.** sed works for flat keys but breaks on TOML section ordering. Use a Python upsert that preserves `[options]` placement:
   ```python
   import re, pathlib
   p = pathlib.Path('<config-path>')
   t = p.read_text()
   pat = rf"^{re.escape(key)}\s*=.*$"
   if re.search(pat, t, flags=re.M):
       t = re.sub(pat, f'{key} = {val!r}', t, count=1, flags=re.M)
   # else insert into existing [options] section, or append new [options]
   p.write_text(t)
   ```
   Back up the file first: `cp <config> <config>.bak`.

4. **Stop the daemon — required before edit if the daemon is root-owned; always before restart:**
   - macOS user-level LaunchAgent: `launchctl bootout gui/$(id -u)/<label>` (then relaunch the GUI app, which respawns the daemon)
   - macOS root-level LaunchDaemon/Agent: `sudo launchctl bootout system/<label>`; if bootout fails (root-owned process), `sudo kill -TERM <pid>` after locating via `pgrep -fl <daemon>`
   - Linux user systemd: `systemctl --user stop <unit>` then `start`
   - Linux system systemd: `sudo systemctl stop <unit>`
   - Linux ad-hoc launchers (e.g. RustDesk uses `sudo -E XDG_RUNTIME_DIR=/run/user/<uid> -u <user> /usr/share/<name>/<binary> --server`): `sudo pkill -TERM -f "<binary> --server"`

5. **If passwordless sudo is not configured** (`sudo -n true` returns "a password is required"), **stop and report**: do not invent an interactive prompt. Provide the exact one-shot shell block for the user to paste, identify which process is the blocker, and confirm the config file is correctly staged on disk so the restart alone finishes the job.

6. **Restart + verify.** After restart, `grep <new_key> <config>` should show the key present and the daemon should NOT have rewritten it (compare file mtime to restart time).

## Pitfalls

- "I edited the file but the setting did not take effect" — almost always because the daemon has not restarted. Edits to a running daemon's config are decorative until the daemon re-reads them.
- "The setting keeps disappearing" — the daemon re-saved the file after your edit, dropping the key. Always restart before editing root-owned daemons; the running daemon's in-memory state is the source of truth until restart.
- `sed -i` on TOML — corrupts section ordering and section header parsing. Use Python upsert.
- Wrong key name — `enable-clipboard` (config, hyphens) vs `disable_clipboard` (UI translation key, underscore) are two different strings in the binary. Always grep.
- Two config files per service — RustDesk has `RustDesk.toml` (server identity, do not touch) and `RustDesk2.toml` (runtime options, what you want). Edit only the options file.
- Forgetting which machine is controlled vs controlling — paste/clipboard permission is per-side. Both ends need `enable-clipboard=Y` if you want paste from either direction.
- macOS root-owned service — `pkill` returns "Operation not permitted". Need `sudo launchctl bootout system/<label>` or `sudo kill`. Try `sudo -n` first to detect the passwordless case.

## Known daemons (with reference docs)

| Daemon | Reference | Notes |
|---|---|---|
| RustDesk | `references/rustdesk-config.md` | Two configs; root-owned macOS service |

When you work on a new daemon (Syncthing, autossh, mpd, Transmission, etc.), add a `references/<name>-config.md` with its paths, canonical keys, restart recipe, and gotchas — and link it from this table.