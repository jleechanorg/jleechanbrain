---
name: legal-audit-packet-deliverables
description: Use when building attorney/auditor documentation packets.
---

# Legal / Audit / CPA Packet Deliverables

Jeffrey Lee-Chan's strong preference for legal/audit/CPA packet format: **Google Sheet + Google Doc**, NOT PDF + email. Confirmed 2026-08-05 in the EDD auditor response thread when he rejected a drafted PDF + email with "Do not send email make a new Google sheet and Google doc."

## Why this preference exists

- **Live editing** — auditors/lawyers/CPAs add notes, mark items, return annotated versions; PDFs are write-once artifacts that get fragmented into v2/v3/final chains
- **Shareable without Google account** — `--to anyone` works for external counsel and EDD staff who don't have Google accounts in your domain (sharing by exact email fails with "no Google account associated with this email address")
- **No PDF lock-in** — when the packet evolves (new asks, new data), the same Sheet/Doc updates without a versioning mess
- **Mobile-friendly** — Jeffrey checks Slack on mobile which doesn't load threaded replies by default; shareable links are easier to forward than email threads

## Trigger phrases

- "send the auditor the records"
- "build a packet for my lawyer / Jorge / counsel"
- "respond to [auditor / lawyer / CPA]"
- "draft the auditor response"
- "send the documentation to [recipient]"
- ANY session where the deliverable is going to an attorney, auditor, CPA, tax advisor, regulator, or other professional recipient

## Workflow

1. **Decode the ask first** — read the latest email/letter from the advisor, identify the exact items requested (typically 3-5 things)
2. **Pull data from sources**:
   - Venmo/CSV exports from `~/Downloads/`
   - Email history from `gog gmail search` / `gog gmail thread`
   - Calendar entries from `gog calendar`
   - Resumes/Docs from `gog drive download`
   - Text/iMessage via `imsg` (when responding)
   - Evernote `.enex` files via `search_files pattern=<keyword> file_glob=*.enex`
   - Local artifact dirs like `/tmp/jorge-auditor/` from prior sessions
3. **Build a multi-tab Google Sheet** via `gog sheets create --sheets "Tab1,Tab2,Tab3"` with all tabs at creation time (the CLI cannot add tabs to an existing Sheet). Use `--values-json` for cell data so multi-line strings preserve real newlines. See `references/gog-multi-tab-sheets.md` for the exact recipe.
4. **Build a Google Doc** with the executive narrative that references the Sheet URL. Use `gog docs write <id> <content>`.
5. **Share**:
   - External collaborators (auditors, lawyers): `gog drive share <id> --to anyone --role reader --discoverable --no-input`
   - Internal collaborators (Cindil, etc.): `gog drive share <id> --to user --email <addr> --role writer --no-input`
6. **Surface both URLs in the Slack reply** with a per-person summary table so Jeffrey can review without opening the docs.
7. **DO NOT send email.** Even if a draft email is staged locally, the user has explicitly rejected this pattern. Skip email entirely for this class of deliverable.

## Follow-up cron pattern (post-delivery status pings)

After delivering the Sheet+Doc, Jeffrey usually goes quiet for hours/days while the auditor/counsel reviews. SOUL.md `one-time-status-cron-after-every-task` requires a 20-min one-time follow-up cron. Use this exact recipe (verified 2026-08-06 against the EDD v2 packet):

```bash
# 1. Verify deliverables still alive (do this BEFORE posting)
gog sheets metadata <sheet_id>          # tab titles + sheetId map
gog docs cat <doc_id>                  # NOT "gog docs metadata" — that subcommand does not exist
# optional: curl Slack conversations.replies to confirm latest thread ts

# 2. Post a tight status reply in the original thread (Slack conversations.add_message,
#    thread_ts = the original Jeffrey parent message ts, NOT the session context header).
#    Format: Healthy / Risky / Blocked / Next actions, plus 2-3 sharp unblocking questions.

# 3. Queue the next 20-min one-time cron. Note the trap:
#        `hermes cron create` does NOT have `--prompt`. Prompt is a POSITIONAL arg after schedule.
hermes cron create "20m" \
  --name "EDD audit v2 status (20m)" \
  --deliver "slack:<channel_id>:<thread_ts>" \
  --repeat 1 \
  "<self-contained follow-up prompt>"
```

Common follow-up questions worth pre-staging (these are the ones Jeffrey has actually answered historically):
- "Flip X from 'Yes - PA' to 'NOT a PA' to match your answer?" (when a one-word answer wasn't fully propagated to every tab)
- "Generic placeholder, or do you have paper images / QBO register from <bookkeeper>?" (for items missing source documents)
- "Any last name now, or confirm first-name only?" (for partial-name entries the auditor will flag)

Do NOT modify the Sheet's Open Items tab unilaterally to mark items resolved based on inferred answers — Jeffrey may want them as a pending record. **Exception:** when Jeffrey answers directly in the current session ("this is construction", "personal ATM", "household appliance"), write the verbatim answer into the row marked RESOLVED with date so next-session re-asks don't happen. See Pitfall "Persisted answers live in the Sheet, not memory" below.

## Pitfalls

- **Don't auto-draft PDF + email.** Jeffrey will say "do not send email — make a Google sheet and Google doc" and you'll waste the work. Build the Sheet+Doc from the start when the audience is an attorney/auditor/CPA. The `email-approved-gate` SOUL commitment requires explicit "EMAIL APPROVED" before any send, and the legal-packet pattern is "do not send" entirely.
- **`hermes cron create` has no `--prompt` flag.** Prompt is a POSITIONAL arg after the schedule string. `hermes cron create "20m" --prompt "..."` fails with "unrecognized arguments: --prompt". Correct: `hermes cron create "20m" "..."` (prompt last). Cost: one failed command per session until internalized.
- **`gog docs metadata` does NOT exist.** Only `gog docs cat <docId>` and `gog docs export <docId>` are valid. Trying `metadata` returns `unexpected argument metadata`. For Sheets, `gog sheets metadata <id>` DOES work (returns tab IDs + titles), but the parallel Docs command doesn't exist — use `cat` to read content.
- **Don't add tabs after Sheet creation.** `gog sheets create --sheets "..."` is the ONLY way to set tabs. The CLI has no `add-tab` command. To restructure tabs, delete the Sheet and recreate.
- **`--values-json` for proper newlines.** Positional args (`gog sheets update <id> <range> cell1|cell2,cell3|cell4`) treat `\n` as literal backslash-n. Use `--values-json` with a JSON 2D array to get real newlines in cells.
- **Pipe and comma escaping in positional args.** Cells containing `|` must be escaped as `\|` and `,` must be escaped as `\,` when using positional args. JSON mode doesn't have this constraint — prefer JSON for multi-line or special-character cells.
- **Column widths default to ~100px.** Long content gets truncated visually. Either use multi-line cells with bullet points, or accept the visual truncation (most cells in legal packets are long-form text). The `gog sheets format` CLI requires `--format-fields` (not freeform JSON) so width tweaks are limited.
- **Don't share by exact email to external counsel.** Most attorneys don't have Google accounts in your domain. Use `--to anyone` instead. Trying `--to user --email jmartins@structurelaw.com` returns "no Google account associated with this email address."
- **Verify the Sheet visually after writing.** Open the URL in a headless browser (`browser_navigate`) and `browser_vision` the screenshot to confirm newlines rendered correctly and the data is readable.
- **Capture OCR'd content from attachments before discarding.** The auditor often attaches screenshots (image008/009/010-style) that contain their actual questions. Download via `gog gmail attachment <messageId> <attachmentId> --output <path>` (BOTH ids are required, not just attachmentId) and OCR via `vision_analyze` so the packet answers the actual question, not a paraphrased version.
- **Older prior-session work lives at `/tmp/jorge-auditor/` (or similar).** Before building from scratch, `ls /tmp/jorge-auditor/` — the Aug 4 21:00 session built a /advice-approved audit packet with a Google Sheet at `1c22XEtQSOwnLQjPWW4bIv4SgSNJ3twEOk7eLADWPJ5w` that may already cover 80% of what the user is asking for now.
- **Personnel / Roster tabs are for employees only.** A vendor (LabCorp, plumber, contractor) is NOT staff even if a single payment appears in the same ledger year. Verified 2026-08-17 EDD audit round 2: Rosemary Mata ($350 LabCorp phlebotomy for Cindil) was on the Personnel tab; user reply "she is not a PA." Triage rule: if the person is paid for a service rendered (medical draw, repair, install) with no employment relationship, they belong on a separate "Vendors / non-employee payments" tab or just in the ledger with a `medical / contract` memo flag. Vendors on a roster tab = guaranteed correction.
- **"I've answered this a million times" is a persistence bug, not just frustration.** When Jeffrey gives one-by-one answers to Unresolved Items and signals prior answers are getting lost, the bug is that the prior answers did not survive compaction (memory hit 1,219/1,375 on 2026-08-17 and a new write was rejected as overflow). The durable location for these answers is the **Sheet + the staged reply draft at `/tmp/<topic>/<REPLY>.txt`**, NOT memory. Before closing the session: (a) write the locked answer into the Sheet's Unresolved Items cell directly, (b) update the draft reply file with the verbatim answer, (c) only attempt memory as a secondary cache. Next session that opens the Sheet first will see the locked answer; no re-ask required.
- **Update Cover & Summary row counts alongside tab edits.** If the Personnel tab drops a row (e.g. Rosemary), update the Cover & Summary line that says "5 people" to "4 people" in the same session — otherwise the next read looks stale. Same for "5 unresolved items" → "0 items remaining" once items resolve.
- **Mark resolved items RESOLVED with date + verbatim answer; do not delete.** Deleting removes the audit trail and breaks your own ability to draft the reply. Use the format `RESOLVED <YYYY-MM-DD> (Jeff): <verbatim answer>` in the Status cell.
- **Missing `gog` CLI? Direct Sheets API works in `execute_code`.** When the gog CLI is unavailable (different machine, sandbox, or rate-limited), `python3 -c "import urllib.request; ..."` with `values:batchUpdate` and `valueInputOption=USER_ENTERED` works exactly like `gog sheets update ... --values-json`. Refreshing the OAuth token via POST `/oauth2.googleapis.com/token` with `grant_type=refresh_token` is straightforward when the client_id/secret/refresh_token are available from the same Google account. See `references/sheets-batchupdate-direct-api.md` for the verified recipe.

## Outbound email draft — "narrow it" pattern

The audience may eventually want an email to the advisor/auditor/lawyer (e.g. a one-paragraph reply linking the Sheet+Doc). When they pivot from "do not send" to "draft the email," always produce a **TIGHT, NARROW** draft:

- **Default length: 1 screen, ~10-15 lines.** Anything longer is rejected with "narrow it."
- **No preamble.** Do not say "Here's the draft" or "What I cut from the v3 draft." The user is going to copy-paste; they need the email itself, not commentary.
- **No diff blocks.** Do not show what was removed from the prior draft as a separate bulleted list — the user knows what's in the Sheet, they don't need a side-by-side.
- **No "let me know if you want anything changed" boilerplate.** The user is the one sending; they decide whether to change.
- **No additional closing question.** "Let me know if anything else needs clarification" is the kind of fluff that gets cut.

The user's typical follow-up sequence when a draft is too long: "narrow it" → "(X is fine, don't worry about Y)" → "just draft the email and I will send it." Treat "just draft the email" as a hard signal that the draft text alone is the deliverable — not a request for a full review/QA pass with reasoning.

After the narrow draft, close with the **send handoff** (the only useful follow-up): the Gmail thread ID + the literal approval signal the system accepts. Example close: "Reply `EMAIL APPROVED` and I'll fire `gog gmail reply` to thread `<id>`. Or paste-back edits if you want to tweak." That is the entire reply — no status table, no "What I did" recap, no further questions.

**Confirmed 2026-08-17**: user replied "narrw it / just dont worry about $60 gap / just draft the email and i wil send it" after a 33-line draft that included a "What I cut" section. The narrow 25-line version with the sheet link and a single-thread-ID close was the accepted shape. Treat any future draft in this class that exceeds ~1 screen as needing a pre-emptive trim before showing.

## Acceptance signals

- Two URLs (Sheet + Doc) in the Slack reply, both `anyone-with-link` accessible
- Per-person summary table in the reply so Jeffrey can review without opening
- "Open Items" tab in the Sheet listing what still needs confirmation from Jeffrey
- NO email draft staged on Desktop or anywhere (per Jeffrey's "Do not send email")
- The Mizraim / new-hire EDD-registration fields are a SEPARATE tab (not embedded in the auditor-response Sheet), since the registration is a different workflow

## Reference

- `references/gog-multi-tab-sheets.md` — exact CLI recipe for multi-tab Sheet creation, multi-line cell writes, and external sharing
- `references/sheets-batchupdate-direct-api.md` — direct Sheets API via `execute_code` when the `gog` CLI is unavailable; OAuth refresh + `values:batchUpdate` with `USER_ENTERED` + read-back verification + the locked-fact (RESOLVED <date>) row schema for Unresolved Items tabs
