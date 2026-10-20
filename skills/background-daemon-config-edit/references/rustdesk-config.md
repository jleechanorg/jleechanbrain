# RustDesk Config (background-daemon-config-edit reference)

## Paths

| File | macOS | Linux | Purpose |
|---|---|---|---|
| Identity / keys | `~/Library/Preferences/com.carriez.RustDesk/RustDesk.toml` | `~/.config/rustdesk/RustDesk.toml` | Server identity, key pair, encrypted password — DO NOT edit |
| **Runtime options** | `~/Library/Preferences/com.carriez.RustDesk/RustDesk2.toml` | `~/.config/rustdesk/RustDesk2.toml` | **Edit this for feature toggles** |
| Local UI state | `~/Library/Preferences/com.carriez.RustDesk/RustDesk_local.toml` | `~/.config/rustdesk/RustDesk_local.toml` | Address book, window positions |

IPC socket: `/tmp/RustDesk/ipc` (Unix domain socket; CLI tools and IPC clients connect here).

## Canonical option keys (verified 2026-08-06 via `strings -a` on `service` binary, RustDesk 1.4.6)

Toggle permissions / features:
- `enable-clipboard = 'Y'` — incoming connections may use clipboard sync
- `enable-file-transfer = 'Y'` — file copy between peers
- `enable-keyboard = 'Y'`, `enable-audio = 'Y'`, `enable-remote-restart = 'Y'`, `enable-record-session = 'Y'`, `enable-block-input = 'Y'`
- `enable-directx-capture`, `enable-android-software-encoding-half-scale`
- `one-way-clipboard-redirection`, `one-way-file-transfer`, `sync-init-clipboard`

Connection policy:
- `allow-remote-config-modification = 'Y'` — peer can change your settings remotely (default ON)
- `allow-only-conn-window-open = 'N'`
- `allow-hostname-as-id`, `allow-numeric-one-time-password`, `allow-remove-wallpaper`, `allow-always-software-render`
- `allow-insecure-tls-fallback`, `allow-websocket`, `allow-auto-update`, `allow-ask-for-note`

Approval / auth:
- `verification-method = 'use-permanent-password'`
- `approve-mode = 'password'`
- `temporary-password-length`, `proxy-url`, `proxy-username`, `proxy-password`

Network:
- `direct-server = 'Y'`
- `local-ip-addr = '<lan-ip>'`
- `rendezvous_server` (in RustDesk.toml, not RustDesk2.toml — don't move it)
- `disable-udp`, `allow-websocket`, `ice-servers`

UI:
- `theme`, `swap-left-right-mouse`, `zoom-cursor`, `touch-mode`, `edge-scroll-edge-thickness`
- `hide-security-settings`, `hide-network-settings`, `hide-server-settings`
- `main-window-always-on-top`, `disable-floating-window`

**Confusable UI i18n keys (NOT config keys — they're in translation tables):**
- `disable_clipboard`, `enable-file-copy-paste`, `show_remote_cursor`, `sync-init-clipboard`, `follow_remote_cursor`, `follow_remote_window`, `show_quality_monitor`, `terminal-persistent`, `lock_after_session_end`

These appear adjacent to the real config keys in `strings` output but are NOT settable in the TOML.

## Why direct edits don't take effect immediately

The RustDesk server daemon:
1. Reads `RustDesk2.toml` once on startup into memory
2. Exposes config via GUI and IPC pipe (`/tmp/RustDesk/ipc`, line-based JSON envelopes)
3. Writes back to `RustDesk2.toml` whenever any setting changes via those channels, normalizing and dropping keys it doesn't recognize

If you edit the file while the daemon runs:
- Your edits stay on disk briefly
- The daemon does NOT auto-reload from disk (no inotify watcher)
- The next time anything changes the in-memory state (connection accepted, GUI toggle, IPC write), the daemon rewrites the file and **wipes your unknown keys**

So you MUST restart the daemon to apply changes.

## Restart recipes

### macOS

Two daemons, two launchd jobs:
- `gui/<uid>/com.carriez.RustDesk_server` — user-level, runs `RustDesk --server`
- `system/com.carriez.RustDesk_service` — root-level, runs `RustDesk/service` (PID 502 by default, root-owned — can't `pkill` without sudo)

```bash
# Stop user-level server (no sudo)
launchctl bootout gui/$(id -u)/com.carriez.RustDesk_server

# Stop root service (sudo)
sudo launchctl bootout system/com.carriez.RustDesk_service
# If bootout fails (some installs only have the user-level job):
sudo kill -TERM $(pgrep -f 'com.carriez.RustDesk/service')

# Edit RustDesk2.toml
# ... python upsert ...

# Restart — relaunch the app, it respawns both daemons
open -a RustDesk
```

Verify: `pgrep -fl RustDesk` should show `service` and `RustDesk --server` both running, and `grep enable-clipboard ~/Library/Preferences/com.carriez.RustDesk/RustDesk2.toml` should return your value.

### Linux

Server runs under `sudo -E XDG_RUNTIME_DIR=/run/user/<uid> -u <user> /usr/share/rustdesk/rustdesk --server`. Tray is regular user. Service is `rustdesk --service` running as root.

```bash
# Stop everything
sudo systemctl restart 'rustdesk*' 2>/dev/null || true
sudo pkill -TERM -f 'rustdesk --server'
sudo pkill -TERM -f 'rustdesk --tray'

# Edit RustDesk2.toml
# ...

# Respawn tray (daemon is restarted by udev/systemd hooks)
( setsid /usr/share/rustdesk/rustdesk </dev/null >/dev/null 2>&1 & )
```

If `sudo -n` reports "a password is required" → sudoers is not passwordless for this user. **Don't prompt**; report blocker with the exact restart block, confirm the TOML file is staged on disk, and let the user run it in their own shell.

## "Always allow paste" recipe (controlled + controlling)

Add to `[options]` in `RustDesk2.toml` on **both** machines (clipboard is per-side):

```toml
[options]
enable-clipboard = 'Y'
enable-file-transfer = 'Y'
allow-remote-config-modification = 'Y'
```

Then restart the daemon on both ends. Paste will work from either direction without per-connection prompts.

## Discovery workflow (when you forget the key names)

```bash
# Find the binary and bundle ID
pgrep -fa rustdesk

# Confirm key names from the binary, not from memory
strings -a /usr/share/rustdesk/rustdesk | grep -E "^enable-|^allow-|^disable_" | sort -u

# Look up current effective config
cat ~/.config/rustdesk/RustDesk2.toml
```