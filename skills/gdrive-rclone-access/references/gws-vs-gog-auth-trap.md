# Reference: `gws` vs `gog` auth-account trap on this machine (HISTORICAL)

> **Historical context (2026-08-21 incident; resolved 2026-08-22).** As of 2026-08-22 `gws` is BANNED for personal Workspace calls (SOUL.md `## COMMIT: gws-banned-for-personal-workspace`). The CLI itself was uninstalled from the Mac. This reference is preserved because it documents the SA-vs-OAuth partition that justifies the ban. **Do not invoke `gws` for personal calls.** Use `gog` instead.

Verified 2026-08-21. The TL;DR for a future session that hits the same trap: **`gws` was bound to a Firebase service account, not your personal Gmail/Drive. Don't trust its empty results. Use `gog` instead — and the trap is now permanently closed by the gws-ban COMMIT.**

## The trap, in raw output

```bash
$ gws drive about get --params '{"fields":"user,storageQuota"}' --format json
{
  "storageQuota": {"limit": "0", "usage": "0", ...},
  "user": {
    "displayName": "firebase-adminsdk-fbsvc@worldarchitecture-ai.iam.gserviceaccount.com",
    "emailAddress": "firebase-adminsdk-fbsvc@worldarchitecture-ai.iam.gserviceaccount.com",
    ...
  }
}
```

`storageQuota.limit: "0"` and `emailAddress: ...iam.gserviceaccount.com` are the two diagnostic tells. Personal Gmail accounts always have a quota limit in the GB range.

## What `gws` silently does

| Surface | Symptom | Root cause |
|---|---|---|
| `gws drive files list` | `{"files":[]}` for every query (including empty `pageSize:5`) | SA has no personal-Drive access |
| `gws drive files get <ID>` | 404 notFound for any jleechan file | SA has no shared-Drive grant to that file |
| `gws gmail users getProfile` | HTTP 400 "Precondition check failed" | SA cannot access personal Gmail |
| `gws gmail users messages list` | Same 400 even with a valid `q` filter | Same |
| `gws auth status` | Reports `auth_method: none` despite tokens existing on disk | Confusing — tokens ARE there (encrypted in `~/.config/gws/sa_token_cache.json` and `~/.config/gws/token_cache.json`) but the resolver can't read them via the `gws auth status` path |

The "auth_method: none" from `gws auth status` is **NOT** evidence the system is unauthenticated. It just means the resolver doesn't see the credentials through its status introspection. The actual API calls work (returning SA results).

## What `gog` does correctly

```bash
$ gog gmail search 'LLC' --json --max 10
{
  "nextPageToken": "01254540212579318956",
  "threads": [{"id": "1a025d8eaf9b721f", "date": "2026-08-21 12:42", "from": "...", "subject": "...", ...}]
}

$ gog drive search 'LLC' --json --max 10
{
  "files": [{"id": "1kPFn_YHS5LsWhGq0JeS4WcZ-BMORYGhkQ5GksPMrW1c", "name": "Aug 15,2026, ...", ...}]
}
```

`gog` is authed via `~/Library/Application Support/gogcli/config.json` with `keyring_backend: keychain` — the actual OAuth tokens live in macOS Keychain, which the CLI unlocks automatically on this user account. No interactive setup needed once the keychain entry exists.

## Diagnostic command sequence (copy-paste, run on entry)

```bash
# 1. Confirm gws is hitting the wrong account (run first — fast, loud failure)
gws drive about get --params '{"fields":"user.emailAddress"}' --format json

# If output shows *.iam.gserviceaccount.com:
#   → gws is bound to a service account. Switch to gog.

# 2. Confirm gog is authed to the personal account (also fast)
gog auth status 2>&1 | head -10
# OR: just try a search — a working auth returns JSON in <2s

# 3. Sanity-check both surfaces in parallel
gog gmail search 'is:unread' --json --max 5 &
gog drive search 'inbox' --json --max 5 &
wait
```

If both return JSON without error, proceed with `gog` for the rest of the session.

## Entity forensic worked example: Lee-Chan Consulting LLC

User asked: "how did I set up my LLC?" Given the SOS BizFile snapshot inline:

```
Lee-Chan Consulting LLC (202252616766)
EIN 92-0618778
Formed 09/27/2022, CA
Principal: 1046 ROSE AVE, VENICE, CA 90291
Agent: ROCKET CORPORATE SERVICES INC.
```

Searches that converged to the full setup story in 6 calls:

```bash
# Step 1 — entity # in Gmail (found: 1 thread from Structure Law)
gog gmail search '202252616766' --json --max 10

# Step 2 — EIN in Gmail (same thread, cross-confirms)
gog gmail search '92-0618778' --json --max 10

# Step 3 — registered agent in Gmail (broader: finds ALL firm correspondence)
gog gmail search 'Rocket Corporate' --json --max 10

# Step 4 — domain of the law firm that handled the EIN/EDD matter
gog gmail search 'from:structurelaw.com' --json --max 20

# Step 5 — entity # in Drive (found: original formation packet PDF)
gog drive search '202252616766' --json --max 10
# → 2 files: "Lee-Chan Consulting LLC.pdf" + "Lee-Chan consulting info"

# Step 6 — pull the formation packet + the BizFile snapshot
gog drive download '1qgWRaBqtV9FxxRKUUIJQvtvdUaxry1dq' --output /tmp/llc.pdf
gog drive download '1h2kg4bAenPDONPS0bVpKBsslSiXJlthTVCLkPlJlAwk' --output /tmp/consulting_info.pdf

# Step 7 — read the structure-law thread fully
gog gmail thread get '1998836ed25e8ed5' --json > /tmp/thread.json
python3 -c "import json,base64; ..."   # decode base64url bodies
```

Result: full LLC story (CA SOS #, EIN, formation date, agent, principal address, organizer, IRS SS-4, business start date, responsible party, EDD account number, dangling 2026 follow-up).

## Why `gws` is still on the machine

It's used by the WorldArchitect AI repo's deploy tooling for service-account operations against `worldarchitecture-ai` (Firebase Admin SDK, Cloud Run, etc.) — those calls **should** hit the service account. The trap is that a session that loads the `google-workspace` skill first will assume `gws` is the universal Google CLI for this machine, when in fact it only works against service-account-scoped resources. `gog` is the personal-account CLI; `rclone` is the personal-Drive bulk CLI.

If you need to do BOTH personal and service-account operations in the same session, use `gog` + `rclone` for personal, and `gws` only for the specific service-account calls you actually need (and verify the email each time via `gws drive about get`).
