---
name: gdrive-rclone-access
version: 1.2.0
description: "Headless Drive access via rclone gdrive: remote (and gog for full-text search + Gmail)."
when_to_use: "Use when the user asks to download/upload/list files from a Google Drive folder via terminal headlessly, search Gmail for messages/threads (full-text, by sender, by entity #), or run a multi-signal forensic search across both Gmail and Drive to reconstruct the history of a real-world entity (LLC, vendor relationship, EDD matter, contract). Trigger phrases: 'download from Drive', 'pull this Drive folder', 'Drive folder <id>', 'rclone this Drive folder', 'gog drive search', 'find every Docs mention Y', 'search my Gmail for X', 'find the thread about Y', 'search Gmail and Drive', 'how did I set up my LLC', 'find all correspondence with <firm>', 'EIN lookup', 'find my entity number'. Do NOT use for browser-based Drive workflows or vendor share-links."
category: devops
last_verified: 2026-08-21
---

# Headless Google account access via rclone + gog (this Mac)

Canonical pattern for the WA / Hermes agent stack: **use `gog` for Gmail + Drive full-text search and per-file reads, `rclone gdrive:` for bulk Drive operations**. NEVER use `gws` for personal-account work — `gws` on this machine is OAuth-bound to a service account, not your personal Gmail/Drive. See `references/gws-vs-gog-auth-trap.md` for the raw diagnostic output, the silent-empty symptom table, and the worked forensic-search recipe.

For bulk folder copy/sync, recursive tree walks, and uploads: use the `rclone gdrive:` remote (NOT `gws drive` and NOT `gcloud auth login --scopes=drive.file`). The rclone remote is already authed as `jleechan@gmail.com` (refresh token in `~/.config/rclone/rclone.conf`).

## Why NOT `gws drive`

`gws` on this machine is OAuth-bound to the Firebase service account `firebase-adminsdk-fbsvc@worldarchitecture-ai.iam.gserviceaccount.com`. That service account has **no Drive storage quota** and **no shared Drive membership** → every personal Drive folder returns:

```json
{"error":{"code":404,"message":"File not found: <id>","reason":"notFound"}}
```

This is a Google design constraint, not a bug. Service accounts cannot own Drive files; they can only access Shared Drives they were granted access to. Verified 2026-08-14 on folder `1dM4qeRcKTJmRZVq1bB8wTgPhdZNgazc-` (jleechan's personal avatar folder).

Anti-pattern: do not try to "fix" `gws drive` by adding scopes. The OAuth client_id `gws` ships with has no `drive.*` scope registered in Google's consent-screen config — adding `?scope=drive.file` to a token request returns `restricted_client: Unregistered scope(s)` and cannot be retargeted.

## Why NOT `gcloud auth login --scopes=drive.file`

The default `gcloud` OAuth client (`32555940559`) has no Drive scopes registered either. Running `gcloud auth login jleechan@gmail.com --scopes=drive.file` either fails with `restricted_client: Unregistered scope(s)` or, worse, **corrupts the working `~/.config/gcloud/legacy_credentials/jleechan@gmail.com/adc.json`** if it errors mid-flight. Don't run this command.

**Pitfall — `gws` on this machine is also silently bound to a service account for the Gmail API.** Even when `gws` Drive returns errors (404 notFound is loud), `gws gmail` returns **HTTP 400 `Precondition check failed`** for almost every call — including `gws gmail users getProfile`. That looks like an auth problem, but it's actually the same root cause as Drive: `gws` is using a service-account credential (`firebase-adminsdk-fbsvc@worldarchitecture-ai.iam.gserviceaccount.com` per `gws drive about get`), which has no Gmail access. Do NOT spend cycles debugging OAuth or token refresh — switch to `gog gmail` immediately. Verified 2026-08-21.

The reliable sanity check: run `gws drive about get --params '{"fields":"user"}' --format json` and look at `user.emailAddress`. If it's a `*.iam.gserviceaccount.com` address, every `gws` call is hitting the wrong account — exit `gws` and use `gog` for the rest of the session.

## Why `gog` is also the right tool for Gmail (not just Drive)

`gog` is authed via the macOS keychain (`keyring backend: keychain` in `~/Library/Application Support/gogcli/config.json`) as `jleechan@gmail.com` — the personal account that has both Gmail and Drive. The same CLI handles both surfaces with the same auth, which is exactly what you want for cross-surface forensic searches ("find every email and Drive doc about my LLC").

```bash
# Gmail search (full Gmail query syntax: from:, to:, subject:, has:attachment, filename:, newer_than:)
gog gmail search 'LLC' --json --max 20
gog gmail search 'from:ccavazos' --json --max 20
gog gmail search 'subject:(LLC OR Formation OR "Statement of Information")' --json --max 20
gog gmail search '92-0618778' --json --max 10      # EIN lookup
gog gmail search '202252616766' --json --max 10    # CA entity number lookup

# Read a full thread (returns base64url-encoded body data in payload.body.data / payload.parts[*].body.data)
gog gmail thread get <THREAD_ID> --json > /tmp/thread.json

# Get a single message by ID
gog gmail get <MESSAGE_ID> --json
```

**Pitfall — `gog gmail search` uses positional args, NOT `--query`.** The flag is `--max`. Multi-word queries must be passed as a single quoted string; if your shell splits them, you'll get `unknown flag` errors. Verified 2026-08-21.

**Pitfall — `gog gmail thread get` body is base64url-encoded inside `payload.body.data` (and `payload.parts[*].body.data`).** Decode with:

```python
import json, base64
d = json.load(open('/tmp/thread.json'))
for m in d['thread']['messages']:
    body = m['payload'].get('body', {}).get('data', '')
    if body:
        print(base64.urlsafe_b64decode(body + '==').decode('utf-8', 'replace'))
    for part in m['payload'].get('parts', []) or []:
        if part.get('mimeType', '').startswith('text/plain'):
            data = part.get('body', {}).get('data', '')
            if data:
                print(base64.urlsafe_b64decode(data + '==').decode('utf-8', 'replace'))
```

Multi-part messages put the readable body in `parts[*].body.data`, NOT in the top-level `payload.body.data`. The top-level is usually empty for HTML+plain messages. Verified 2026-08-21.

## Cross-surface forensic search: how a real-world entity was set up

The class of question that comes up repeatedly: "how did I set up my LLC / open this vendor relationship / file this EIN matter" — the answer lives spread across Gmail threads AND Drive PDFs/Google Docs. The reliable pattern is **multi-signal convergence**:

1. **Run entity-ID searches in parallel** (single shell pass, not one-at-a-time):
   - CA entity number (e.g. `202252616766`)
   - EIN (e.g. `92-0618778`)
   - Registered agent (e.g. `Rocket Corporate`, `Rocket Lawyer`, `Structure Law`)
   - Street address from the SOS filing (e.g. `1046 Rose Ave`)
   - The owner's name as it appears on filings
2. **For each Gmail hit**, pull the full thread (`gog gmail thread get`) and decode the body — short snippets rarely contain the load-bearing detail (EIN, fax confirmation, address corrections).
3. **For each Drive hit** with the entity name or registered agent in the title, download via `gog drive download <ID>` (auto-exports Google Docs as PDF, native files as-is), then `pdftotext` for text extraction. The original formation packet is almost always in Drive under the registered agent's name (Rocket Lawyer / LegalZoom / Northwest / etc.).
4. **Cross-reference**: the Gmail threads will name a law firm or paralegal (e.g. "Cecilia Cavazos @ Structure Law"); search `from:<firm-domain>` to find EVERY thread with that firm, including 2026 follow-ups that the entity-ID search would miss.
5. **Surface dangling matters**: scan thread reply chains for unanswered "what's the next step?" or "let me know if you need..." messages — those are live items needing follow-up.

This converges in 5–8 tool calls vs. hours of guessing. Verified 2026-08-21 on Lee-Chan Consulting LLC (CA #202252616766, EIN 92-0618778) — found the original Rocket Lawyer formation PDF, the 2025 EDD registration thread with Structure Law Group, and the dangling 2026 follow-up with Jorge Martins in one cross-surface sweep.

## Why rclone works

`rclone` supports a per-remote `client_id` + `client_secret` config. The `gdrive:` remote at `~/.config/rclone/rclone.conf` uses a user-owned Desktop-app OAuth client (configured 2026-08-01 per the conf header), so its refresh token has the full `drive` scope and works for any folder jleechan@gmail.com can see.

## Why `gog` is a useful third option (for full-text search)

`rclone` and `gws` only see files **by path or folder ID**. Neither does Drive full-text search. When the task is "find every file containing *Alexiel*" or "show me every Doc that mentions *project phoenix*", you need `gog` (Google Workspace CLI, `v0.10.0+`, separate OAuth client, scope `drive.readonly`).

```bash
# Full-text search across all of jleechan's Drive
gog drive search 'Alexiel'           # returns ID, Name, Type, Size, Modified
gog drive search 'Alexiel' --page '<token>'  # paginate; first line of output is the next token

# List a folder
gog drive ls --parent <FOLDER_ID> --max 100

# Download a single file (exports Google Docs as txt/docx/pdf automatically)
gog drive download <FILE_ID> --format txt --out /tmp/alexiel_001.txt

# Get metadata
gog drive get <FILE_ID>
```

**Important — `gog` is complementary, not a replacement for `rclone`:**
- Use `rclone` for: bulk folder copy/sync, uploading local files, recursive tree walks, anything path-based
- Use `gog` for: full-text search, content-export of Google Docs (auto-handles .gdoc → .txt/.docx/.pdf), per-file metadata
- Use `gws` for: never (see "Why NOT gws" above)

**Pitfall — `gog drive search` returns at most 20 hits per page.** The first line of stdout is a `# Next page: --page <token>` comment when more results exist; pass the token verbatim to the next call. Don't grep that line as if it were a hit — it isn't.

**Pitfall — `gog drive ls` without `--parent` lists Drive root.** To recurse into a folder, pass `--parent <FOLDER_ID>`. Output is TSV: `ID  NAME  TYPE  SIZE  MODIFIED`.

**Pitfall — `--format` on `gog drive download` is only honored for Google-native types** (Docs/Sheets/Slides). For non-native files (.md, .txt, .pdf, .docx) the format flag is ignored and the file is downloaded as-is.

Verified 2026-08-17 on a 60-hit Alexiel search across 3 pages of results.

## Proven-working pattern: read a folder by ID

**The bare folder ID as a path doesn't work.** This fails with `directory not found`:

```bash
rclone lsf 'gdrive:1dM4qeRcKTJmRZVq1bB8wTgPhdZNgazc-'  # ← FAILS
```

**Use `--drive-root-folder-id <ID>` with path `gdrive:/`:**

```bash
rclone lsjson gdrive: \
  --drive-root-folder-id 1dM4qeRcKTJmRZVq1bB8wTgPhdZNgazc- \
  --max-depth 2 --files-only
# → returns full file list with Name, ID, Size, MimeType, ModTime
```

This returns everything in that folder (one level of nesting shown). Increase `--max-depth` to recurse into subfolders.

## Listing a folder

```bash
# JSON with full metadata
rclone lsjson gdrive: \
  --drive-root-folder-id <FOLDER_ID> \
  --max-depth 2 --files-only

# Plain names only
rclone lsf gdrive: --drive-root-folder-id <FOLDER_ID>

# Recursive
rclone lsf gdrive: --drive-root-folder-id <FOLDER_ID> -R
```

## Downloading files

```bash
# Whole folder to local dir
rclone copy gdrive: /tmp/my_download/ \
  --drive-root-folder-id <FOLDER_ID> \
  --max-depth 2

# Single file by ID (from the lsjson Name field)
rclone copyto gdrive:path/to/file.jpg /tmp/single.jpg \
  --drive-root-folder-id <FOLDER_ID>
```

## Filtering by extension

`--include "*.{png,jpg,jpeg,webp,gif}"` is **incomplete** — it does NOT match extensionless files (e.g. `"Ains shy lich"`, `"Nova echo "`). For folders with extensionless image files, either:

1. Drop `--include` and filter in Python afterwards (mime type from `--json`), OR
2. Use per-file `rclone copyto` from the listing with explicit names.

Verified 2026-08-14: pulling the avatar folder, `--include "*.{png,jpg,jpeg,webp,gif}"` skipped 16 of 135 image files (the ones with no extension or with `.PNG`/`.JPG` that needed case-sensitive matching). Worker had to fall back to per-file copyto for the stragglers.

## Uploading files

```bash
# Single file
rclone copyto /local/file.png gdrive:/folder-name/file.png

# Whole directory
rclone copy /local/dir/ gdrive:/folder-name/

# Get a share link for an uploaded file
rclone link gdrive:folder-name/file.png
```

## Refresh token / expiry handling

The refresh token in `rclone.conf` does NOT expire unless manually revoked. If you see `Failed to create object: unauthorized_client` or `invalid_grant`, run:

```bash
rclone config reconnect gdrive:
# → opens browser, OAuth dance, refresh token written back
```

If you're already past the OAuth dance and only the access token is stale, `rclone` auto-refreshes it transparently.

## When to verify the remote is alive

Before dispatching workers that depend on `gdrive:` access, run one cheap read:

```bash
rclone lsf gdrive: --max-depth 1 -q
```

If this errors out with auth issues, reconnect before dispatching.

## Related

- `~/llm_wiki/wiki/sources/reference-gdrive-upload-via-rclone-own-client.md` — full background on why every shared OAuth client on this machine blocks `drive.file` and the user-owned client_id path
- `auth-gated-site-read` — for reading vendor share-links (Gemini/ChatGPT/Drive share-pages) that need browser auth, not Drive API
- `cron-jobs-and-messaging-credentials` — if you need to schedule recurring Drive pulls, this is the rotation policy
- `gog` (binary at `/opt/homebrew/bin/gog`, v0.10.0+) — for full-text search across Drive (`gog drive search 'term'`), per-file content export of Google Docs, AND Gmail search/thread read (`gog gmail search`, `gog gmail thread get`). See the "Why `gog`" and "Cross-surface forensic search" sections above.
- `references/bizfile-ftb-live-check.md` — when the user asks "is my LLC still active with CA / FTB", BizFile + FTB eletter are bot-blocked from curl AND headless browser; `corporate.ai/entity/ca/<entity#>/<slug>` is the only working fallback for SOS standing, and absence of FTB correspondence in Gmail IS the signal of likely delinquency.
- `references/gog-cross-machine-install.md` — full Linux (Ubuntu/Debian) install recipe + the D-Bus keyring workaround (`GOG_KEYRING_BACKEND=file`) + the 2-step `--remote` OAuth dance + cross-machine `client_secret.json` portability. Read this BEFORE provisioning `gog` on a new Linux host or after a `gog` reinstall.