# gog CLI: Multi-Tab Sheets + Multi-Line Cells

Verified working recipes for creating Google Sheets with multiple tabs from the `gog` CLI (v0.10.0+). These are the operations you cannot do via the Sheets API web UI shortcuts — the CLI has gaps that require specific flag combinations.

## Create a Sheet with multiple tabs (one call)

```bash
GOG_KEYRING_PASSWORD=hermes-gog-2026 gog sheets create "My Title" \
  --sheets "Tab1,Tab2,Tab3" --no-input
```

Output:
```
Created spreadsheet: My Title
ID: 1viEuRlmbbWr2OFmbAoC39gakkD3N1jildfklHz6yOQ4
URL: https://docs.google.com/spreadsheets/d/1viEuRlmbbWr2OFmbAoC39gakkD3N1jildfklHz6yOQ4/edit
```

The `--sheets` flag is the **only** way to set tabs at creation. There is no `add-tab` subcommand. If you need to restructure the tab list, delete the Sheet (`gog drive trash <id>` or manually) and recreate.

If you forget `--sheets`, the Sheet is created with a single default `Sheet1`.

## Write multi-line cell values

Positional args treat `\n` as literal backslash-n. To get real newlines in cells, use `--values-json`:

```python
import subprocess, json, os

SHEET_ID = "1LMDvn3rbtr5PYu1FtOYQhz_a0qd3EfKKgvnhMwzxMYk"

data = [
    ["Name", "Service(s) provided", "Period"],
    ["Jake Goldberger",
     "Personal assistant / household manager (current, ongoing).\n"
     "- Scheduled daily/weekly shifts (typically 5 hours at $20-22/hr)\n"
     "- Errands, medical appointment accompaniment, prescription pickup\n"
     "- Dry cleaning pickup, household task support",
     "2023-01 through 2025-12 (and ongoing)"],
    ["Kou Collins",
     "Former personal assistant.\n"
     "- Hired 2022-07-31 via Venice Craigslist ad\n"
     "- Worked Dec 2022 - Jan 2023",
     "2022-12 through 2023-01"],
]

result = subprocess.run([
    'gog', 'sheets', 'update', SHEET_ID, "'Per-Person Services'!A1",
    '--values-json', json.dumps(data),
    '--input', 'USER_ENTERED',
    '--no-input'
], env={**os.environ, 'GOG_KEYRING_PASSWORD': 'hermes-gog-2026'}, timeout=60)
```

Without `--values-json` (positional args):
```bash
gog sheets update SHEET_ID "'Sheet1'!A1" "Jake Goldberger|Service|Period,Alice|Old format|2023"
```
- Cells separated by `|`
- Rows separated by `,`
- `|` in cell values must be escaped as `\|`
- `,` in cell values must be escaped as `\,`
- Newlines in cell values are NOT supported — they become literal `\n`

## Update existing ranges without recreating

```bash
# Single cell
gog sheets update SHEET_ID "Per-Person Services!A2" "New value" --no-input

# Range with values
gog sheets update SHEET_ID "Per-Person Services!A1:B5" "Header1|Header2,Row1A|Row1B,Row2A|Row2B" --no-input
```

## Share to external collaborators

```bash
# Anyone with link (works for anyone, even without Google account)
GOG_KEYRING_PASSWORD=hermes-gog-2026 gog drive share SHEET_ID \
  --to anyone --role reader --discoverable --no-input

# Specific user (must have Google account)
GOG_KEYRING_PASSWORD=hermes-gog-2026 gog drive share SHEET_ID \
  --to user --email user@gmail.com --role writer --no-input
```

For attorneys/auditors who don't have Google accounts in your domain (typical for external counsel like `jmartins@structurelaw.com`), `--to anyone` is the only path. Trying `--email` returns:
```
Google API error (400 invalidSharingRequest): Bad Request. User message: "You are trying to invite jmartins@structurelaw.com. Since there is no Google account associated with this email address, you must check the 'Notify people' box to invite this recipient."
```

## Format columns / freeze header rows

`gog sheets format` requires `--format-fields` (not freeform JSON like `--values-json`). To format, use either:
1. The Google Sheets web UI manually (Sign in + click), or
2. Direct Sheets API calls via curl with a service-account token

For automated pipelines, the format CLI is too constrained — accept default column widths and use multi-line cells to fit content visually.

## Get / verify what was written

```bash
gog sheets get SHEET_ID "Per-Person Services!A1:E10" --no-input
```

Returns TSV. Use `--json` for JSON.

## Delete a Sheet you no longer need

`gog drive` does NOT have a `trash` or `delete` subcommand in v0.10.0. To clean up:
1. Use the Google Drive web UI (Sign in → right-click → Remove)
2. Or use `gog drive` with the right flags (verify with `gog drive --help` per version)

## Verify visually

After writing, open the URL in a headless browser to confirm rendering:

```python
browser_navigate(url=f"https://docs.google.com/spreadsheets/d/{SHEET_ID}/edit?usp=drivesdk")
browser_vision(question="Is the data showing with real line breaks? List visible rows.")
```

Look for: real newlines (not literal `\n`), proper row breaks, headers in row 1, frozen pane if needed.

## Common gotchas

| Symptom | Cause | Fix |
|---|---|---|
| Cell shows literal `\n` instead of newline | Used positional args | Switch to `--values-json` |
| "Updated 1 cells" but only first cell filled | Forgot comma between rows in positional args | Add `,` between rows; or use `--values-json` |
| Cell shows `\|` instead of `\|` | Pipe escape missing in positional args | Escape as `\\|` (literal `\|`) in shell; or use `--values-json` |
| Sheet created with no tabs | Forgot `--sheets` flag | Delete and recreate with `--sheets "Tab1,Tab2,..."` |
| "no Google account" on share | Used `--to user --email` for external counsel | Use `--to anyone` instead |
| Tab names with spaces break range syntax | Range needs single quotes for spaces | Use `"'Per-Person Services'!A1"` not `"Per-Person Services!A1"` |
| `gog docs metadata <id>` returns `unexpected argument metadata` | Subcommand does NOT exist for Docs (it does for Sheets) | Use `gog docs cat <docId>` to read content; `gog docs export <docId>` for pdf/docx/txt |
| `hermes cron create "20m" --prompt "..."` fails with `unrecognized arguments: --prompt` | `--prompt` flag does not exist; prompt is positional | `hermes cron create "20m" "..."` (prompt after schedule, no flag) |
