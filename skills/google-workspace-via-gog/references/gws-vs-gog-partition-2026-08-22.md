# `gws` vs `gog` partition + the 2026-08-22 ban (incident record)

> **Status as of 2026-08-22:** `gws` is **BANNED for personal Workspace calls** (Gmail, Drive, Docs, Slides, Sheets, Calendar, Tasks, Contacts, People, Classroom, Chat, Groups, Forms, Keep). Canonical CLI for personal Workspace is `gog` (v0.37.0+). `gws` is still **PERMITTED** for service-account operations against `worldarchitecture-ai` (Firebase Admin SDK, Cloud Run admin, GCP project ops).
>
> Enforcement: SOUL.md `## COMMIT: gws-banned-for-personal-workspace` (added 2026-08-22, scans every session-init).
>
> This file is the canonical session-specific detail for the ban. SKILL.md (`google-workspace-via-gog/SKILL.md`) has the why; this file has the how-the-ban-shipped and the migration recipe.

## Why a partition (not a blanket ban)

`gws` (`@googleworkspace/cli`) has two failure modes on this machine:

1. **Personal-Workspace trap (CLOSED by the ban):** `gws` is wired to `firebase-adminsdk-fbsvc@worldarchitecture-ai.iam.gserviceaccount.com` which has zero personal Gmail/Drive/Docs scopes. Every personal call returned `401 unauthorized_client` or `{files:[]}` silently. Agents saw "auth lost" and tried re-login, which made things worse (revoked the still-valid OAuth token).
2. **Service-account operations (STILL PERMITTED):** WorldArchitect.AI deploy tooling relies on `gws` for Firebase Admin SDK calls, Cloud Run admin reads, and other GCP-project ops that the SA JSON legitimately authenticates. Banning `gws` outright would break the WA backend.

The partition is: **personal OAuth vs service-account JSON**. The ban disables the former (because it returns silent 401s) while leaving the latter intact (because it's the only CLI that talks to the SA).

**Detection rule:** run `gws auth status` — if it reports `auth_method: service_account` (or `auth_preferred: service_account`), the call is a SA op and `gws` is permitted. If it reports `auth_method: oauth`, it is a personal call and the agent MUST rewrite to `gog`.

## What shipped on 2026-08-22

| Layer | Change |
|---|---|
| **SOUL.md** | Added `## COMMIT: gws-banned-for-personal-workspace` (Promise Gate compliant: trigger-based, references files + sections, scoped exception for SA ops). Scanned at session-init by every agent. |
| **`~/.claude/commands/google.md`** | Bumped to `GOOGLE_COMMAND_V4`; added explicit ban clause: "`gws` is BANNED for any personal Gmail/Drive/Docs/Sheets/Slides/Calendar call." Only Firebase Admin SDK / Cloud Run admin / GCP project ops against `worldarchitecture-ai` SA are still permitted. |
| **Mac** | `gws` uninstalled: `npm uninstall -g @googleworkspace/cli` then `rm` the symlink at `${HOME}/.nvm/versions/node/v22.22.0/bin/gws` and the package at `${HOME}/.nvm/versions/node/v22.22.0/lib/node_modules/@googleworkspace/`. Verified `which gws` returns nothing. |
| **Linux (jeff-ubuntu)** | `gws` was never installed there. `gog` v0.37.0 already canonical at `/home/jleechan/.local/bin/gog`. No install/uninstall action needed. |
| **`gog` upgrade** | Mac: `brew upgrade openclaw/tap/gogcli` → v0.10.0 → **v0.37.0** (build 45b5d766, 2026-08-14). Linux: already at v0.37.0. |
| **`gws_bridge.py`** | Deleted from `~/.smartclaw/skills/productivity/google-workspace/scripts/` on both machines (rsync). |
| **Skill rewrites (12 files)** | All active `gws` calls replaced with `gog` equivalents; deprecated skills marked explicitly (see "Migration map" below). |
| **Python wrapper `google_api.py`** | `_gws_binary()` now ALWAYS returns `None` so all paths fall through to the Python client (google-api-python-client) which uses the same OAuth token at `~/.smartclaw/google_token.json`. |
| **`tax/scripts/upload_tax_docs.py`** | Rewritten to use `gog --account jleechan@gmail.com drive upload --file <local> --parent <folder>` (was `gws drive files create`). |
| **`tax/scripts/fetch_tax_season_history.sh`** | Error message fixed: was "Install gws + run gws auth login first." (now says install `gog` via `brew install openclaw/tap/gogcli` or curl release). |

## Migration map — every `gws` substitution made on 2026-08-22

| Old (`gws`) | New (`gog` v0.37.0+) | Where |
|---|---|---|
| `gws auth status` | `gog auth status` | everywhere |
| `gws auth login --readonly --services gmail,calendar` | `gog login <email> --services gmail,calendar --drive-scope full --remote --force-consent --no-input --step 1` (then step 2 with redirect URL) | scheduled-digest-cron-degraded-dependency, OAuth re-consent recipe |
| `gws gmail users threads list --user=me --q="..."` | `gog --account <email> gmail search "<query>"` | bluesky-signup, social-account-fanout |
| `gws gmail users messages list --params '{"userId":"me","maxResults":3}'` | `gog --account <email> gmail search "is:unread" --max 3` | scheduled-digest-cron-degraded-dependency/references/google-oauth-fallback-recipe |
| `gws drive ls` | `gog --account <email> drive ls --max 3` | auth-degradation recipes |
| `gws drive files create --params '{...}' --json '{body}' --upload '<file>'` | `gog --account <email> drive upload --file <local> --parent <folderId>` | tax/scripts/upload_tax_docs.py |
| `gws drive search "name = 'X'"` | `gog --account <email> drive search "name = 'X'" --json` | verify-a-doc recipes |
| `gws docs create "Title" --parent <id> --file foo.md` | `gog --account <email> docs create "Title" --parent <id> --file foo.md --no-input --json` | blog-post-to-gdoc |
| `gws docs documents batchUpdate` | `gog --account <email> slides batch-update <id> --file <requests.json>` (or `docs batch-update`) | gws-slides-decks |
| `gws about get` | `gog --account <email> drive get <id> --json --no-input` | social-poster diagnostic |

## Deprecated skills (kept as historical reference, NOT for active use)

| Skill | Status | Reason |
|---|---|---|
| `~/.smartclaw/skills/gws-slides-decks/` | DEPRECATED 2026-08-22 | `gws` is banned; replaced by `gog slides create` + `gog slides batch-update`. SKILL.md rewritten with deprecation banner pointing at `gog`. The `references/gws-cli-workflow.md` file is preserved as historical context only. |
| `~/.smartclaw/skills/productivity/google-workspace/` | LEGACY (gog is canonical) | The Python wrapper (`google_api.py`) still works — `_gws_binary()` now returns None and code falls through to the Python client. New work should use `gog` directly via `~/.smartclaw/skills/google-workspace-via-gog/SKILL.md`. |
| `~/.smartclaw/skills/gdrive-rclone-access/references/gws-vs-gog-auth-trap.md` | HISTORICAL (preserved) | Documents the 2026-08-21 trap that motivated the ban. Annotated as HISTORICAL; the trap is now closed by SOUL.md COMMIT. |

## What still uses `gws` legitimately (NOT banned)

Per the SOUL.md COMMIT exception list:
- Firebase Admin SDK calls (`firebase-admin` Node + Python tools)
- Cloud Run admin / GCP project ops against `worldarchitecture-ai`
- Bulk SA-scoped Firestore admin reads
- Anything where `gws auth status` reports `auth_method: service_account`

If a future task needs `gws` for one of these, reinstall via `npm install -g @googleworkspace/cli` — it will land at `${HOME}/.nvm/versions/node/v22.22.0/bin/gws` again. The ban does not apply.

## How a future session detects "did I forget the ban?"

Three signals in order of reliability:

1. **SOUL.md session-init scan fires** — `## COMMIT: gws-banned-for-personal-workspace` lists the partition rule and the file:line. Read it before invoking `gws` for any non-`service_account` call.
2. **`gws auth status` returns `auth_method: oauth`** — this is the diagnostic that decides which CLI to use. If `oauth` → rewrite to `gog`; if `service_account` → `gws` is fine.
3. **The 401/silent-empty symptom** — `gws drive files list` returns `{files:[]}` or `gws docs documents get` returns `401 unauthorized_client`. This is the historical trap. Stop, route to `gog`, don't try to fix `gws`.

## Cross-references

- SOUL.md `## COMMIT: gws-banned-for-personal-workspace` — the rule itself (Promise Gate compliant, scans every session)
- `~/.smartclaw/skills/google-workspace-via-gog/SKILL.md` — canonical `gog` how-to (curator-managed)
- `~/.claude/commands/google.md` — `/google <gog-subcommand>` slash command (V4, 2026-08-22)
- `~/.smartclaw/skills/gdrive-rclone-access/references/gws-vs-gog-auth-trap.md` — the 2026-08-21 raw diagnostic that motivated the ban
- Mac keychain entry (ground truth): `gogcli / token:default:jleechan@gmail.com`
- Mac install: `brew install openclaw/tap/gogcli` (or `brew upgrade` to get latest)
- Linux install: `curl -L https://github.com/openclaw/gogcli/releases/latest | bash`
- OAuth re-consent flow (canonical): see `google-workspace-via-gog/SKILL.md` "OAuth re-consent flow" section
