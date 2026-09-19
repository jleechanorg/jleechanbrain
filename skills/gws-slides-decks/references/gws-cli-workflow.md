# `gws` CLI workflow for Google Workspace (gmail, drive, calendar, sheets, docs)

Use when the bundled `google-workspace` Python skill isn't appropriate (e.g. raw Slides API access, batchUpdate requests, anything beyond the high-level `$GAPI` wrappers).

## Canonical paths

- **CLI binary**: `${HOME}/.nvm/versions/node/v22.22.0/bin/gws` (v0.22.5+ as of 2026-08, installed via nvm node 22)
- **Auth state**: macOS Keyring (look up `~/.config/gws/` config dir for `token_cache.json` + `sa_token_cache.json`)
- **Complementary bridge** (compat only): `python ~/.smartclaw/skills/productivity/google-workspace/scripts/gws_bridge.py` — refreshes OAuth token then execs `gws` with the fresh token. Not needed for normal flow; use only if keyring creds are missing.

## When to use `gws` vs `google_api.py` wrapper

| Use case | Tool |
|---|---|
| Slides create + batchUpdate (raw API) | `gws` direct |
| Gmail send/reply (simple --to/--subject/--body) | `google_api.py` wrapper |
| Drive upload, share, convert | `gws` direct |
| Calendar event create with attendees | Either works |
| Sheets read/write | Either works |
| Reading Gmail with `is:unread` syntax | `google_api.py` |

## Auth lifecycle

```bash
gws auth status                    # check storage / credential_source / scopes
gws auth login                     # default scopes (opens browser)
gws auth login --services drive    # narrower: drive only
gws auth login --full              # incl. pubsub + cloud-platform
gws auth login --readonly          # read-only scope subset
gws auth logout                    # wipe creds
gws auth export                    # print decrypted creds (DO NOT paste outbound)
gws auth export --unmasked         # same, no masking (treat as secret)
```

## Scope pitfalls (Slide-class example)

If `gws auth status` shows the credential_source is a **service account** or a stale OAuth consent without Slides scope, `gws slides presentations create` returns `403 caller does not have permission`. Re-consent:

```bash
gws auth logout
gws auth login --services slides,drive,gmail,calendar,sheets,docs
gws slides presentations create --params '{}' --json '{"title":"probe"}'
# On success: delete the probe deck before continuing.
```

## `gcloud auth application-default login` — Slides-write scope set

A stopgap bootstrap when keyring has nothing usable. The first scope **must** be `cloud-platform`:

```bash
gcloud auth application-default login \
  --scopes="https://www.googleapis.com/auth/cloud-platform,https://www.googleapis.com/auth/drive.file,https://www.googleapis.com/auth/presentations,https://www.googleapis.com/auth/spreadsheets,https://www.googleapis.com/auth/userinfo.email,openid" \
  --no-launch-browser --quiet
```

Run in PTY/background; `process poll` after a few seconds. gcloud prints a `https://accounts.google.com/o/oauth2/auth?...` URL and waits for the `4/0A...` verification code at the redirected URL.

```
Go to the following link in your browser, and complete the sign-in prompts:
    https://accounts.google.com/o/oauth2/auth?response_type=code&client_id=...
Once finished, enter the verification code provided in your browser: _
```

Submit the code via `process action=submit data="4/0A...\n"`.

## Common recipes

### Gmail send (raw)

```bash
# gws expects base64url-encoded RFC 2822 MIME (headers + body, no attachments)
python3 -c "import base64,json; print(json.dumps({'raw': base64.urlsafe_b64encode(b'From: a@b.com\nTo: c@d.com\nSubject: hi\n\nhi').decode()}))" > /tmp/body.json
gws gmail users messages send --params '{"userId":"me"}' --json "$(cat /tmp/body.json)"
```

For the simple `--to --subject --body` form, use the wrapper instead:
```bash
GAPI=~/.smartclaw/skills/productivity/google-workspace/scripts/google_api.py
$GAPI gmail send --to user@x.com --subject "hi" --body "hi"
```

### Drive upload + share

```bash
gws drive files create --json '{"name":"report.pdf"}' --upload /path/to/report.pdf
# Returns file ID
gws drive permissions create --params '{"fileId":"<ID>"}' --json '{"role":"reader","type":"anyone"}'
```

### Calendar event

```bash
gws calendar events insert \
  --params '{"calendarId":"primary"}' \
  --json '{"summary":"Standup","start":{"dateTime":"2026-09-01T10:00:00-07:00"},"end":{"dateTime":"2026-09-01T10:30:00-07:00"}}'
```

### Slides create + populate (full pattern)

```bash
# 1. Create
gws slides presentations create --params '{}' --json '{"title":"Deck","pageSize":{"width":9144000,"height":5143500}}'
# Capture "presentationId" from the response

# 2. Add slides via batchUpdate
gws slides presentations batchUpdate --params '{"presentationId":"<ID>"}' \
  --json '{"requests":[{"createSlide":{"objectId":"slide2","slideLayoutReference":{"predefinedLayout":"TITLE_AND_BODY"}}}]}'

# 3. Insert text into placeholder shapes (objectIds returned by get after createSlide)
gws slides presentations get --params '{"presentationId":"<ID>"}'
# Inspect the response to find the title placeholder objectId

gws slides presentations batchUpdate --params '{"presentationId":"<ID>"}' \
  --json '{"requests":[{"insertText":{"objectId":"<titleShapeId>","text":"Slide 2","insertionIndex":0}}]}'

# 4. Get shareable URL
gws slides presentations get --params '{"presentationId":"<ID>"}'
# Look for "webViewLink" in the response
```

## Pitfalls

### Subcommand syntax

`gws` is SPACE-separated, not dot-separated:

```bash
# WRONG — "unrecognized subcommand 'presentations.create'"
gws slides presentations.create --params '{}'

# RIGHT
gws slides presentations create --params '{}'
```

### POST/PATCH/PUT bodies

`--json '{...}'` is REQUIRED for POST/PATCH/PUT even when the body looks empty:

```bash
# WRONG — 400 missing request body
gws slides presentations create --params '{}'

# RIGHT
gws slides presentations create --params '{}' --json '{"title":"X"}'
```

### Schema $refs

`gws schema <svc.res.method>` returns JSON Schema with `$ref` pointers (e.g. `"$ref":"Page"`). Use `--resolve-refs` to inline but the result is huge. For ad-hoc checks, search the unresolved output for the field name first.

### Never paste `--export --unmasked` output to outbound artifacts

`gws auth export --unmasked` prints full client secrets and refresh tokens. Apply `outbound-secret-publication-gate` from SOUL.md before sending anywhere — slide content, share links, etc. are fine; raw credential JSON is not.

### Pagination

```bash
gws <svc> <res> list --params '{...}' --page-all --page-limit 10
# Outputs NDJSON, one line per page
```

### Form output

```bash
--format yaml    # human-readable
--format csv     # tabular
--format table   # default-ish for some commands
```

## Verification

Before claiming any Google Workspace action is done:

1. Capture the response (not just a 200 OK) — note the ID, URL, message ID, event ID.
2. Re-fetch with `gws <svc> <res> get --params '{...}'` to confirm.
3. For send/share/post: confirm recipient + content via the corresponding `get` (e.g. `drive permissions list`).
4. Never paste `gws auth export` output into outbound artifacts.
