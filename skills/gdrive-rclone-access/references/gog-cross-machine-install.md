# `gog` cross-machine install + auth (Mac & Linux)

**This reference covers the two-machine parity recipe** so a Hermes agent on Mac can re-provision Linux (or vice versa) without rediscovering the gotchas. The umbrella skill `gdrive-rclone-access` already documents `gog` for this Mac; this file extends that to a clean Linux install + the canonical OAuth dance.

## Canonical source

- **Repo:** `github.com/openclaw/gogcli` (HTTP 301 redirect from `steipete/gogcli`; both work but `openclaw/` is the canonical GitHub home)
- **Homebrew tap (Mac):** `openclaw/tap/gogcli` — formula name is `gogcli`, CLI binary installs as `gog`
- **Releases:** `https://github.com/openclaw/gogcli/releases/latest` — artifact pattern is `gogcli_<ver>_<os>_<arch>.tar.gz`

## Mac (already covered in umbrella)

- `gog` v0.10.0 via Homebrew, stable since 2026-02
- Auth in macOS Keychain (`keyring_backend: keychain` in `~/Library/Application Support/gogcli/config.json`)
- 4+ months stable as of 2026-08-22 — no re-auth needed
- `which gog` → `/opt/homebrew/bin/gog`

## Linux (Ubuntu / Debian) — bare-metal install

```bash
# Detect arch, fetch latest tarball, drop binary in ~/.local/bin
ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
VER=$(curl -fsSL https://api.github.com/repos/openclaw/gogcli/releases/latest \
        | grep '"tag_name"' | head -1 | cut -d'"' -f4 | tr -d v)
curl -fsSL -o /tmp/gogcli.tar.gz \
  "https://github.com/openclaw/gogcli/releases/download/v${VER}/gogcli_${VER}_linux_${ARCH}.tar.gz"
mkdir -p ~/.local/bin
tar -xzf /tmp/gogcli.tar.gz -C ~/.local/bin    # extracts ./gog (not gogcli)
chmod +x ~/.local/bin/gog
~/.local/bin/gog --version
```

**Pitfall — the tarball contains `./gog`, NOT `./gogcli`.** The release artifact name is `gogcli_…` but the inner binary is `gog`. Use `tar -xzf … -C ~/.local/bin` (no filename arg) and verify the file lands as `~/.local/bin/gog`.

**Pitfall — PATH must include `~/.local/bin`.** On Ubuntu 22+, this is in `~/.profile` but NOT in non-login bashrc; add `export PATH="$HOME/.local/bin:$PATH"` to `~/.bashrc` if not already there. The standard Linux bashrc on this machine already does (line 1708).

## Linux keyring gotcha — `GOG_KEYRING_BACKEND=file`

D-Bus SecretService is NOT running by default on Ubuntu/Debian server installs. `gog` defaults to a keyring backend that needs it, so any credential write (including `gog auth credentials <client_secret.json>`) will:

```
store secret: set secret: keyring connection timed out after 10s while storing
keyring item (D-Bus SecretService may be unresponsive);
set GOG_KEYRING_OPEN_TIMEOUT to allow more time,
or set GOG_KEYRING_BACKEND=file and GOG_KEYRING_PASSWORD=*** to use encrypted file storage instead
```

**Fix** — set `GOG_KEYRING_BACKEND=file` and `GOG_KEYRING_PASSWORD=<your-password>` BEFORE first auth. Add to `~/.bashrc`:

```bash
# Linux has no D-Bus SecretService by default; force encrypted-file backend.
# On Mac, leave unset (keychain backend is detected automatically).
export GOG_KEYRING_BACKEND=file
export GOG_KEYRING_PASSWORD="<your-password>"   # see below for the convention
```

**Password convention (this machine):** the existing Mac `GOG_KEYRING_PASSWORD` is `hermes-gog-2026` (line 1463 in `~/.bashrc`). Use the same value on Linux so the encrypted file is portable across machines if you ever need to `scp` it. Otherwise pick any string — `gog` will AES-encrypt the keychain with it.

**Verified 2026-08-22 on jeff-ubuntu:** after adding the two exports, `gog auth credentials ~/client_secret_*.json` succeeds immediately and writes `~/.local/share/gogcli/credentials.json`.

## OAuth dance (both machines, but mandatory on Linux)

Mac users can skip this section if `gog auth status` already shows `credentials_exists: true`. On Linux (or after a `gog` reinstall), the OAuth dance is a 2-step `--remote` flow because the agent can't open a browser itself.

### Step 1 — get the auth URL

```bash
gog auth add jleechan@gmail.com \
  --services=gmail,calendar,drive,docs,slides,sheets,tasks,contacts \
  --remote
```

Output:

```
auth_url   https://accounts.google.com/o/oauth2/auth?...&state=<state>
state_reused   false
Run again with the same root flags and --remote --step 2 --auth-url <redirect-url>
```

Paste the `auth_url` into a browser. The Google account must be added as a test user in the OAuth consent screen (Google Cloud Console → APIs & Services → OAuth consent screen → Test users → Add users) — otherwise the click returns `Error 403: access_denied`.

### Step 2 — exchange the code

After clicking Allow, the browser redirects to `http://127.0.0.1:<port>/oauth2/callback?code=...&scope=...`. Copy the ENTIRE redirected URL (or just the `code=...&scope=...` portion), then:

```bash
gog auth add jleechan@gmail.com \
  --services=gmail,calendar,drive,docs,slides,sheets,tasks,contacts \
  --remote \
  --step 2 \
  --auth-url '<redirect-url-or-code>'
```

On success, `gog auth status` shows `credentials_exists: true`.

**Pitfall — SSH transport drops the browser callback.** If you ran step 1 over `ssh jeff-ubuntu gog auth add … --remote`, the local browser callback server (`127.0.0.1:<port>`) only listens on jeff-ubuntu, not your Mac. You must complete the redirect on a browser that can reach jeff-ubuntu's loopback — either an X-forwarded browser session, an Aside/Chrome on the same host, or by manually pasting the `code=` value into step 2.

**Pitfall — `--services` must be specified.** Default preset may miss Drive/Docs/Sheets. Always pass the comma-separated list for the surfaces you'll actually use.

## Cross-machine OAuth client portability

The `client_secret_<client-id>.apps.googleusercontent.com.json` file is **per-developer, not per-machine** (the OAuth client ID is registered to the Google Cloud project, not to any individual install). The file at `~/client_secret_785368777920-5legmjp8lce83ldv413jlsjbuumaeba4.apps.googleusercontent.com.json` is the one this machine's Mac has been using since 2026-02 — it works on Linux too.

```bash
# From Mac to Linux (one-time per new machine)
scp ~/client_secret_785368777920-*.json jeff-ubuntu:~/
# Then on Linux:
gog auth credentials ~/client_secret_785368777920-*.json
```

Do NOT re-download from Google Cloud Console — that generates a new client ID and breaks any refresh tokens already issued against the old one.

## Verifying parity

After install + auth on both machines, these three probes should succeed on each:

```bash
gog --version                                 # Mac: v0.10.0 (stable); Linux: v0.37.0+ (latest)
gog auth status | grep -E 'credentials_exists|config_exists'  # both: true
gog drive ls --max 3                          # both: lists jleechan's Drive root, no auth errors
```

If `gog drive ls` returns `keyring: … not unlocked` (Mac only), unlock the login keychain in Keychain Access once and the agent will reuse it. On Linux, the file backend never locks.

## Slash command parity

Both machines already have `/google` at `~/.claude/commands/google.md` (thin dispatcher → `gog <subcommand>`). It does NOT need to be re-created — it loads the skill at `~/.claude/skills/google-workspace-via-gog/SKILL.md` on either machine. That skill is **not curator-managed** on this profile (file exists but isn't in the resolver registry) — manual `scp` of the skill markdown to Linux is required to keep them in sync.

## Common operation pitfalls (cross-machine)

| Operation | Pitfall | Fix |
|---|---|---|
| `gog drive delete <id>` | Refuses without `--force` from non-interactive shells | Always pass `--force` from cron/launchd/agent contexts |
| `gog drive trash <id>` | Subcommand does NOT exist | Use `gog drive delete [--force] <id>` (aliases: `rm`, `del`) |
| `gog docs create --file foo.md` | YAML frontmatter is imported as a literal paragraph at the top of the doc | Strip frontmatter before import: `sed '1,/^---$/d; /^---$/d' foo.md > /tmp/foo-stripped.md` |
| `gog auth login` (one-shot) | Replaces the entire token bucket — wipes per-service refresh tokens | Use `gog auth add <email> --services=…` instead; preserves existing tokens for other services |
| `gog gmail search <query>` | Query is positional, NOT `--query`; multi-word queries must be a single quoted string | `'from:boss@example.com newer_than:1d'` — never `--query "…"` |
| `gog docs create` returning wrong content | Body got YAML parsed as paragraphs (see above) | Strip frontmatter; if doc is already created, `gog drive delete --force` and recreate |
