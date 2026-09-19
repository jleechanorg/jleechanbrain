# Direct Google Sheets API via `execute_code` (gog CLI unavailable)

Verified 2026-08-17 against Sheet `1c22XEtQSOwnLQjPWW4bIv4SgSNJ3twEOk7eLADWPJ5w` (EDD audit v2 packet, Jorge Martins round 2). Use this when the `gog sheets` CLI is unavailable (different machine, sandbox, daemon down, rate-limited). Same OAuth refresh + `values:batchUpdate` recipe also works in raw `terminal()` if `gcloud` is present.

## When to use this instead of `gog`

- `gog` CLI not on PATH in this sandbox
- `gog sheets update` returns `unexpected error` mid-session
- You want one Python call to update multiple non-contiguous ranges atomically (atomicity > 0 cross-cell-write)
- You need conditional updates that the CLI doesn't expose (e.g. USER_ENTERED interprets `2026-08-17` as date, not string)

## OAuth refresh — exact recipe

```python
import json, urllib.request

CLIENT_ID = '<client_id>.apps.googleusercontent.com'
CLIENT_SECRET = 'GOCSPX-...'
REFRESH_TOKEN = '1//05BDwdb...'

req = urllib.request.Request(
    'https://oauth2.googleapis.com/token',
    data=f'client_id={CLIENT_ID}&client_secret={CLIENT_SECRET}&refresh_token={REFRESH_TOKEN}&grant_type=refresh_token'.encode(),
)
tok = json.loads(urllib.request.urlopen(req).read())
access_token = tok['access_token']
```

Credentials are interchangeable with `gog`'s keyring-backed OAuth client (`~/.config/gog/credentials.json` or `GOG_KEYRING_PASSWORD`-decrypted blob). If `gog sheets get <id>` returns data, the same OAuth identity works via the direct API.

## Batch update — multiple ranges in one call

```python
SHEET_ID = '1c22XEtQSOwnLQjPWW4bIv4SgSNJ3twEOk7eLADWPJ5w'

body = {
    "valueInputOption": "USER_ENTERED",   # CRITICAL — interprets dates/numbers
    "data": [
        {"range": "Unresolved Items!A1:C7", "values": [...]},
        {"range": "Personnel Provenance!A6:J7", "values": [["" for _ in range(10)]]},
        {"range": "'Cover & Summary'!A4:B6", "values": [...]},
    ]
}

req = urllib.request.Request(
    f"https://sheets.googleapis.com/v4/spreadsheets/{SHEET_ID}/values:batchUpdate",
    data=json.dumps(body).encode(),
    headers={
        'Authorization': f'Bearer {access_token}',
        'Content-Type': 'application/json',
    },
    method='POST'
)
result = json.loads(urllib.request.urlopen(req).read())
# Returns: totalUpdatedRows, totalUpdatedColumns, totalUpdatedCells, per-range updatedRange
```

`USER_ENTERED` vs `RAW`:
- `USER_ENTERED` (default) — interprets input: `"2026-08-17"` becomes a date, `"=A1+1"` becomes a formula, leading `'` is stripped
- `RAW` — writes literal text; useful for IDs like `=abc123` when you don't want formula evaluation

For audit packets, **always `USER_ENTERED`** — Jeff expects dates to render as dates in the response to the auditor.

## Range quoting — gotcha

Tab names containing spaces MUST be single-quoted inside the `range` value:

```python
# CORRECT
"range": "'Cover & Summary'!A4:B6"
"range": "Personnel Provenance!A6:J7"     # no quoting needed for no-space tabs

# WRONG — http.client raises InvalidURL
"range": "Cover & Summary!A4:B6"
```

In Python the `&` and space together are fine — the issue is only when the raw unquoted range has a space. Quotes must survive into the URL though, so use `urllib.parse.quote` on the whole range:

```python
import urllib.parse
range_quoted = urllib.parse.quote(f"'{tab}'!A1:J15")
url = f"https://sheets.googleapis.com/v4/spreadsheets/{SHEET_ID}/values/{range_quoted}"
```

## Delete-row pattern — clearing rather than deleting

The Sheets API has `spreadsheets.batchUpdate` with `deleteDimension` for true row deletion, but it's separate from `values:batchUpdate`. For packet work, **clearing values via overwriting with empty rows is simpler and equivalent for downstream consumers**:

```python
# Clear rows 6-10 on Personnel Provenance (deletes the visual content but keeps structure)
{"range": "Personnel Provenance!A6:J10", "values": [["" for _ in range(10)] for _ in range(5)]}
```

For one-row deletion of row 6, write an empty row to A6:J6 AND shift any rows below it up by overwriting A7:J7 with A6:J6's prior values. The simpler path for an audit packet:

```python
# Overwrite the row with a single explanatory note row instead of empty
{"range": "Personnel Provenance!A6:J7", "values": [
    ["", "", "", "", "", "", "", "", "", ""],
    ["Note: Rosemary Mata removed — see Unresolved Items tab.", "", "", "", "", "", "", "", "", ""]
]}
```

This preserves the audit trail and keeps column widths intact.

## Read-back verification

After the batch update returns success, READ THE TABS BACK to confirm the write actually landed (Network shows 200s, but `valueInputOption=USER_ENTERED` can silently reject values that look like formulas or that conflict with data-validation rules):

```python
for tab in ['Unresolved Items', 'Personnel Provenance', 'Cover & Summary']:
    range_quoted = urllib.parse.quote(f"'{tab}'!A1:J15")
    req = urllib.request.Request(
        f"https://sheets.googleapis.com/v4/spreadsheets/{SHEET_ID}/values/{range_quoted}",
        headers={'Authorization': f'Bearer {access_token}'}
    )
    data = json.loads(urllib.request.urlopen(req).read())
    for row in data.get('values', []):
        print(' | '.join(c[:60] for c in row))
```

If a value did not land (e.g. an apostrophe tripped parsing), the read-back will show empty cells where you expected content. Re-write those with `RAW` input option.

## Unresolved Items locked-fact pattern (audit round 2)

When the user gives answer-by-answer confirmations for items on the Unresolved Items tab, persist each immediately into the Sheet using this row schema (verified 2026-08-17):

| Column | Value |
|---|---|
| A (Item) | Original wording (verbatim from round 1) |
| B (Status) | `RESOLVED <YYYY-MM-DD> (Jeff): <verbatim answer>` |
| C (Action) | Concrete downstream effect — how to classify the line in the response |

Examples (verbatim from 2026-08-17 EDD audit v2):
- `"2024-09-30 Zelle $359 to Yoni Ben Donel"` → `RESOLVED 2026-08-17 (Jeff): This is construction — Yoni Ben Donel is a contractor. ...` → `Reflect as construction expense in response to Jorge.`
- `"2024-05-03 Venmo $405 'ATM' (Jake)"` → `RESOLVED 2026-08-17 (Jeff): This is ATM cash for Jeff personally ...` → `Classify as personal ATM cash withdrawal, not wages.`

Always include the date stamp — it's the only way the next session (which has no memory of this one) knows the answer is current and not stale.

See umbrella SKILL.md Pitfall "Persisted answers live in the Sheet, not memory" for why this is required.
