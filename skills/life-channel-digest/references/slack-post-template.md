# Slack post template for #life digest

Canonical shell-script template that avoids every pitfall observed
to date (P2 heredoc + @-eaten, P7 execute_code env gap, P8 secret
sanitizer, P11 gog pipe failure).

## The full working script

```bash
#!/bin/bash
set -euo pipefail

# Step 1: source bashrc to get SLACK_BOT_TOKEN
# CRITICAL — do NOT skip. Cron / launchd shells don't inherit the
# user's bash env. `source ~/.bashrc` is what brings the token in.
source ~/.bashrc 2>/dev/null || true

# Step 2: build the digest text in Python
# Use single-quoted heredoc tag (<<'PY') to prevent bash from
# interpolating $variables inside the Python body. Email addresses
# with @ are safe here because bash never sees the @.
python3 <<'PY' > /tmp/digest_text.txt
from datetime import datetime
now_pt = datetime.now().astimezone()
day_label = now_pt.strftime('%a %b %d, %Y %H:%M')

text = f"""📬 *Life digest — {day_label} PT*

*Important unread emails (top 3):*
• *<subject>* — <sender> — <one-line context>.
...
"""
print(text, end='')
PY

# Step 3: build JSON payload (no token references — keeps secrets
# out of execute_code-style sandboxes and away from log scrapers)
python3 <<'PY' > /tmp/payload.json
import json
with open('/tmp/digest_text.txt') as f:
    text = f.read()
payload = {"channel": "C0AMM2B4319", "text": text}
print(json.dumps(payload))
PY

# Step 4: post via curl
# SLACK_BOT_TOKEN is expanded by bash AFTER sourcing ~/.bashrc,
# inside the SAME shell block, so the env var is in scope.
curl -fsS -X POST 'https://slack.com/api/chat.postMessage' \
  -H 'Content-Type: application/json; charset=utf-8' \
  -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
  --data-binary @/tmp/payload.json | tee /tmp/post_response.json

echo ""
echo "---"
python3 -c "import json; d=json.load(open('/tmp/post_response.json')); \
  print('ok=', d.get('ok')); print('ts=', d.get('ts'))"
```

## Why each line matters

| Step | What breaks without it | Fix |
|------|------------------------|-----|
| `source ~/.bashrc` | `curl` returns `auth_error` — token is empty | Source bashrc at the top of the script |
| `<<'PY'` heredoc tag | Bash expands `$variable` inside Python body | Single-quoted heredoc tag disables expansion |
| `> /tmp/digest_text.txt` | Pipe-to-python sometimes loses bytes | Always redirect to file first |
| `--data-binary @/tmp/payload.json` | `--data` strips newlines, mangles emoji | `--data-binary` preserves bytes verbatim |
| `Authorization: Bearer ${SLACK_BOT_TOKEN}` in bash | Token sanitizer strips it if built inside execute_code | Build Authorization header in bash, not in sandbox |

## Variations

### Inline-everything one-liner (no temp files)

```bash
source ~/.bashrc
TEXT=$(cat <<'PY'
📬 *Life digest — ...*
...
PY
)
PAYLOAD=$(python3 -c "import json,sys; print(json.dumps({'channel':'C0AMM2B4319','text':sys.argv[1]}))" "$TEXT")
curl -fsS -X POST 'https://slack.com/api/chat.postMessage' \
  -H 'Content-Type: application/json; charset=utf-8' \
  -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
  --data "$PAYLOAD"
```

This works but is harder to debug. Prefer the multi-file pattern for
cron jobs where the script will be inspected months later.

### Verify after posting

```bash
curl -fsS -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
  "https://slack.com/api/conversations.replies?channel=C0AMM2B4319&ts=<ts>&limit=1" \
  | python3 -c "import json,sys; d=json.load(sys.stdin); \
      m=d['messages'][0]; print('ok=',d['ok']); print('text head:',m['text'][:120])"
```

Expect `ok= True` and the text head matches the digest you posted.

## Common errors and what they mean

| Error | Cause | Fix |
|-------|-------|-----|
| `auth_error` | Token empty (bashrc not sourced) | Add `source ~/.bashrc 2>/dev/null \|\| true` at the top |
| `channel_not_found` | Wrong channel ID | Re-verify channel ID with `slack_thread_lib.sh` |
| `invalid_blocks` | JSON payload malformed | Check for stray quotes / unescaped newlines in text |
| `missing_scope` | Bot token lacks `chat:write` | Check `app_id` / `bot_id` in the post response |
| Empty `text` field | bash ate the `@` in an email address (P2) | Use heredoc pattern, never `python3 -c "..."` inline |

## Verified examples

- 2026-08-11 09:00 PT — ts `1786464149.641949`
- 2026-08-13 09:01 PT — ts `1786636916.998259`

Both used the multi-file bash script pattern above.