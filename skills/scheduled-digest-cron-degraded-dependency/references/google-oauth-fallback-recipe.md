# Google OAuth Re-Auth Recipe

End-to-end recipe for the recurring case where `setup.py --check` returns `NOT_AUTHENTICATED`. Two failure shapes observed:

| Shape | `~/.config/gog/credentials.json` | Recovery complexity |
|---|---|---|---|
| **Shape 1: token-only** | missing | present | 2-3 min (`setup.py --auth-url` → browser → `--auth-code`) |
| **Shape 2: token + client secret** | missing | missing | 10+ min (re-download client_secret.json from GCP, then Shape 1) |

The 2026-07-02 + 2026-08-06 incidents were both **Shape 2** — the OAuth client config itself was gone, not just the token.

## Shape 1 — token-only recovery

```bash
# 1. Generate the auth URL
python ~/.smartclaw/skills/productivity/google-workspace/scripts/setup.py \
    --auth-url --services email,calendar --format json
# Returns: {"auth_url": "https://accounts.google.com/o/oauth2/auth?...", ...}
# Also saved to: ~/.smartclaw/google_oauth_last_url.txt

# 2. Open the URL in a browser, approve the scopes.
#    After approval the browser redirects to http://localhost:1/?code=4/0A...
#    (the localhost redirect WILL fail — that's expected, copy the URL bar)

# 3. Exchange the code (paste the full URL or just the code string)
python ~/.smartclaw/skills/productivity/google-workspace/scripts/setup.py \
    --auth-code "PASTE_URL_OR_CODE_HERE" --format json

# 4. Verify
python ~/.smartclaw/skills/productivity/google-workspace/scripts/setup.py --check
# Should print: AUTHENTICATED
```

## Shape 2 — token + client_secret.json recovery

```bash
# 1. Create or select a project at Google Cloud Console
#    https://console.cloud.google.com/projectselector2/home/dashboard

# 2. Enable required APIs from the API Library:
#    https://console.cloud.google.com/apis/library
#    Enable: Gmail API, Google Calendar API, Google Drive API,
#    Google Sheets API, Google Docs API, People API

# 3. Create the OAuth client
#    https://console.cloud.google.com/apis/credentials
#    Credentials → Create Credentials → OAuth 2.0 Client ID
#    Application type: "Desktop app" → Create

# 4. If the app is still in "Testing" status, add the user as a test user:
#    https://console.cloud.google.com/auth/audience
#    Audience → Test users → Add users

# 5. Download the JSON (button at the right of the credentials row)

# 6. Save to BOTH locations the project reads from:
mkdir -p ~/.config/gog
cp ~/Downloads/client_secret_*.json ~/.config/gog/client_secret.json

# 7. Now run Shape 1 (auth-url → auth-code → check)

# 8. Verify both read paths work:
python ~/.smartclaw/skills/productivity/google-workspace/scripts/setup.py --check
# → AUTHENTICATED

gog auth status | jq '{auth_preferred, credentials_exists, accounts: .accounts | length}'
# → auth_method: "..." (NOT "none")
# → client_config_exists: true
# → plain_credentials_exists: true (or encrypted_credentials_exists: true)
```

## Verification (after either shape)

```bash
# 1. Gmail search returns real results
python ~/.smartclaw/skills/productivity/google-workspace/scripts/google_api.py \
    gmail search "is:unread newer_than:1d" --max 5
# Should return JSON array, not "Not authenticated"

# 2. Calendar list returns real events
python ~/.smartclaw/skills/productivity/google-workspace/scripts/google_api.py \
    calendar list --start 2026-08-06T00:00:00-07:00 --end 2026-08-07T23:59:59-07:00
# Should return JSON array, not "Not authenticated"

# 3. gog can reach the API directly
timeout 15 gog --account jleechan@gmail.com gmail search "is:unread" --max 3
# Should return 3 (or however many unread messages exist)

# 4. The next daily digest cron should produce a real digest (no fallback line)
```

## Common pitfalls

- **`Error 403: access_denied` during the auth-code step** → OAuth app is in "Testing" mode and the user's email is not in the test-users list. Add them at https://console.cloud.google.com/auth/audience → Audience → Test users → Add users.
- **`REFRESH_FAILED` immediately after a successful `--auth-code`** → Token was issued but the refresh token is missing/revoked. Run `setup.py --revoke` then redo Shape 1 from step 1.
- **Browser redirects to `http://localhost:1` and fails** → This is expected. The `--auth-url` step uses `http://localhost:1` as the redirect target because the OAuth flow is server-side captured; what matters is the `?code=...` query string in the redirect URL bar. Copy the FULL URL or just the `code` value.
- **`gws auth login` succeeds but `setup.py --check` still says NOT_AUTHENTICATED** → `gws` and `setup.py` write to different token paths (`~/.config/gws/token_cache.json` vs `~/.smartclaw/google_token.json`). For digest crons that call `google_api.py`, only `~/.smartclaw/google_token.json` matters. Run `setup.py` after `gws auth login` to populate both.
- **Both tokens + both client secrets are gone** → Redo Shape 2 from scratch. Verify the OAuth client wasn't deleted at https://console.cloud.google.com/apis/credentials; if it was, create a new one.

## Observability — detect the gap early

If a digest cron needs auth to function, set up a watchdog that detects the auth-out state before the operator notices a string of fallback posts:

```bash
# Add to ~/.smartclaw/scripts/auth-watchdog.sh (run via launchd every 6h)
RES=$(python ~/.smartclaw/skills/productivity/google-workspace/scripts/setup.py --check 2>&1)
if [[ "$RES" == *"NOT_AUTHENTICATED"* ]]; then
    curl -fsS -X POST "https://slack.com/api/chat.postMessage" \
        -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"channel\":\"C0AMM2B4319\",\"text\":\"⚠️ Google OAuth token missing. Daily digest cron will post fallback until re-auth.\"}"
fi
```

(Pair this with a launchd plist that runs the script on a 6h cadence; alert cooldown 6h to avoid spam. See `~/.smartclaw/skills/devops/launchd-watchdog-template/` if it exists, or `scripts/hermes-watchdog.sh` for the pattern.)