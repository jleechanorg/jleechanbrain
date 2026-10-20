# Cron / Gateway-Bypass chat.postMessage Readback

When the Hermes gateway is wedged (process alive, zero TCP LISTEN sockets — see `hermes-health-check` skill's "Hermes gateway 'running' but ZERO LISTEN sockets" section) or unavailable for any other reason, cron jobs and emergency posts can bypass the MCP/HTTP layer entirely by sourcing `SLACK_BOT_TOKEN` from `~/.bashrc` via `bash -lic` and posting with direct `curl` to `https://slack.com/api/chat.postMessage`.

This bypass is verified to deliver even when the gateway is dead (verified 2026-08-10 EA sweep, ts=1786417664.207229). But the readback pattern is slightly different from the canonical MCP one because the response body may embed large file metadata that breaks naive JSON parsing.

## Post pattern

```bash
TOKEN=$(bash -lic 'echo "$SLACK_BOT_TOKEN"')

PAYLOAD=$(jq -nc --arg text "$BRIEFING" --arg channel "$CHANNEL" \
  '{channel: $channel, text: $text, unfurl_links: false, unfurl_media: false}')

curl -fsS -X POST "https://slack.com/api/chat.postMessage" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json; charset=utf-8" \
  -d "$PAYLOAD"
```

## Verification (3 patterns, in order of robustness)

### 1. Tight-window fetch (canonical)

```bash
curl -fsS "https://slack.com/api/conversations.history?channel=$CHANNEL&limit=1" \
  -H "Authorization: Bearer $TOKEN" \
  | head -c 500
```

The newest message should have the `ts` returned by chat.postMessage. If you see a different message at the top, the channel had traffic between your post and your readback — fall back to pattern 2.

### 2. Regex extraction (when JSON.parse fails on embedded media)

```bash
curl -fsS "https://slack.com/api/conversations.history?channel=$CHANNEL&limit=20" \
  -H "Authorization: Bearer $TOKEN" \
  > /tmp/ch_history.json

grep -oE '"ts":"[0-9.]+"' /tmp/ch_history.json | head -20
# Expected: 1786417664.207229 should appear at the top (newest message first)
```

This pattern is robust to MP4 HLS metadata in `files[]` because it never tries to parse the whole payload — it just extracts ts strings.

### 3. Python with strict=False (handles control chars)

```bash
curl -fsS "https://slack.com/api/conversations.history?channel=$CHANNEL&limit=20" \
  -H "Authorization: Bearer $TOKEN" \
  > /tmp/ch_history.json

python3 -c "
import json
data = json.load(open('/tmp/ch_history.json'), strict=False)
for m in data.get('messages', [])[:5]:
    print(m.get('ts'), '-', m.get('user','')[:15], '-', (m.get('text','') or '')[:80])
"
```

`strict=False` accepts unescaped control characters (which MP4 HLS base64 produces). This works for typical channel history but breaks on some threaded replies with deeply nested attachments — pattern 2 is the fallback.

## Token source contract

```bash
# In a cron job, launchd plist, or bash -lic subshell:
TOKEN=$(bash -lic 'echo "$SLACK_BOT_TOKEN"')

# In an interactive shell that's already sourced the token:
TOKEN="$SLACK_BOT_TOKEN"
```

**Gotcha — bashrc/profile drift:** If you read `$SLACK_BOT_TOKEN` directly in a non-login shell, you may get an empty value because `.profile` overwrites the bashrc export. The `bash -lic` form forces a login shell that re-sources `.bashrc` and pulls the token fresh. This is the same trap documented in memory `bashrc-profile-xapp-drift-blocks-launchd`.

## Why this matters — the silent-outage pattern

When the gateway is wedged, ALL gateway-mediated cron delivery stalls. But cron jobs that use the `bash -lic + direct curl` pattern continue to deliver successfully — which means a successful sweep post is NOT proof that the gateway is healthy. The 2026-08-10 EA sweep was the first case that surfaced this: the cron posted normally at 16:01 PT, but `lsof -p $(pgrep -f 'hermes gateway run') | grep LISTEN` returned nothing (gateway wedged for 3h20m).

**Operational rule:** any cron sweep that posts via this bypass path should include a separate gateway health probe (`lsof` + `curl /health`) in the brief output, with `:large_red_circle:` if the gateway is wedged. The user explicitly wants this surfaced — see `finish-the-job` skill anti-pattern "Cron delivered → assume the gateway is healthy".

## Companion skills

- `hermes-health-check` — the definitive 3-point gateway health check (process / LISTEN sockets / HTTP /health) and recovery commands.
- `finish-the-job` — "no stopping halfway" contract; this verification is what makes the "the work landed" claim provable, not aspirational.
- `slack-post-via-execute_code` — alternative path when raw terminal is blocked (e.g., hermes sandbox restrictions).
