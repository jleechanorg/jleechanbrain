---
name: audit-response-packet-review
description: "Second-opinion review of a regulator response packet."
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [macos, linux]
metadata:
  hermes:
    tags: [audit, EDD, IRS, regulator, response-packet, second-opinion, review, google-sheets, deliverable-verification]
    related_skills: [advice, google-workspace, finish-the-job, requesting-code-review]
---

# Audit Response Packet Review

**Senior-engineer second opinion on a regulator/auditor response packet before send.**

Trigger when:
- User is preparing a response to a tax auditor (EDD, IRS, FTB, state labor board), a securities regulator (SEC, FINRA), or any government auditor.
- The deliverable is a multi-tab spreadsheet (Google Sheet, Excel, Notion DB, Airtable) with summary claims on a Cover tab and detailed line items on subsequent tabs.
- User says "review my packet", "check this is ready", "second opinion", "is the auditor going to accept this", "verify the totals match", or stages a draft and asks for review before the email goes out.

**Skip for:** single-tab deliverables, in-code audit assertions, security review of a PR, or general "is this email good" review.

## Why this skill exists

The 2026-08-04 EDD Personal Assistant audit review session surfaced a class-level bug pattern that almost shipped:

> The **Cover & Summary** tab claimed "Jake 2024 Venmo Total = $13,569.00" with a Source column citing `docs/2024-1099-prep-jake.csv`. That file did not exist on disk. The detailed **Venmo Transactions** tab actually summed to $19,294 across 160 rows (or $13,956 if restricted to "Jake Goldberger" payee rows). The auditor would have read both numbers and flagged the discrepancy.

This is a **cross-tab consistency bug** — the most common and most consequential failure mode in regulator response packets. The audit packet review pattern (multi-tab deliverable + summary claim + detailed rows + cited source files) repeats for every EDD/IRS/auditor response, and the failure mode repeats. Capture it.

## Review procedure (5 phases, no skips)

### Phase 1 — Identify the auditor's questions

The auditor's questions are the acceptance criteria. Every tab and every row should map back to answering at least one question.

- Extract the questions verbatim from the auditor's letter / email / screenshot.
- For each question, locate the tab(s) that answer it. If a tab answers no question, it's dead weight. If a question has no tab, that's a gap.

**Common 4-question pattern (EDD PA audit):**
1. Why is Column D blank for Venmo payments posted from Venmo balance? → Bank Transactions + Venmo Transactions (Funding Source column).
2. Payee + memo for each Venmo/Zelle payment in 2024. → Venmo Transactions + Bank Transactions Response Memo.
3. Identity and role for each person the auditor named. → Personnel Provenance.
4. First time you had a personal assistant that should have been a household employee. → Cover & Summary (direct quote from prior response).

### Phase 2 — Cross-check summary claims vs. row data

This is the critical phase. **For every dollar amount, headcount, date range, or count that appears on the Cover/Summary tab, recompute it from the detailed rows and confirm it matches.**

```python
import csv
with open(detailed_csv) as f:
    rows = list(csv.DictReader(f))
total = sum(float(r['amount']) for r in rows if condition)
print(f"Detailed tab sum: ${total:,.2f}")
print(f"Cover/Summary claim: ${cover_claim:,.2f}")
assert abs(total - cover_claim) < 0.01, "MISMATCH"
```

Common mismatches to look for:
- **Cash vs. accrual:** Venmo pay date in 2023 vs. posted date in 2024 vs. work date in the memo. Choose one and be consistent.
- **Wages vs. reimbursements vs. advances:** A 1099-NEC total should exclude reimbursements and advances. A "Venmo total" might include all three. The Cover claim must specify.
- **Source files that don't exist:** If the Source column cites `docs/2024-1099-prep-jake.csv`, open it. If it's missing, that's a fact error.
- **Hardcoded numbers without derivation:** If a cover figure isn't reproducible from the detailed rows, flag it as "needs reconciliation" before send.

### Phase 3 — Verify category maps (BANK_MEMO, payee classifier, etc.)

If the deliverable contains a mapping dictionary (e.g. `BANK_MEMO = {'2024-01-08|2092': 'Michael Cieslak – ...'}`), verify:

1. **Every key matches a row in the source data** — date + amount must be exact. Float precision matters (`82.78` not `82.7`).
2. **Every memo is correct** — payee name spelled right, purpose correctly characterized, no hallucinated categories.
3. **No unmapped rows** — any source row that doesn't appear in the map is a missed item. Run:
   ```python
   unmapped = [r for r in source_rows if key(r) not in BANK_MEMO]
   ```
4. **No duplicate keys** — duplicate dict keys in Python silently keep the last value, which can mask a bug.
5. **Sensitive rows are flagged UNRESOLVED, not silently categorized** — when the agent has to guess, the auditor will spot the guess. Better to explicitly say "purpose UNKNOWN".

### Phase 4 — Check unresolved-item completeness

The auditor's standard for a complete response: every gap the agent couldn't fill must be explicitly listed, not silently omitted.

For each unresolved item, the sheet should say:
- **What** is unresolved (specific date + amount + payee or check #)
- **Why** it's unresolved (no memo in source, check payee not in bank CSV, etc.)
- **What action the user must take** (ask CPA for QBO register, scan paper checks, confirm purpose in writing)

**Common missed unresolved items:**
- Zelle payments with no memo in the recipient-add alert.
- Checks where the bank CSV lists check # + amount but not payee.
- Reimbursements / advances that look like wages because they appear in the Venmo-to-employee history.
- "First time" question — easy to forget to re-confirm the user's prior answer.
- **Discrepancies between cover claims and detailed row sums** — this should itself be an unresolved item (or fixed before send), not silently left as a mismatch.

### Phase 5 — Output format (mandatory)

Return the review in this exact 5-line shape. The user is reviewing a deliverable before send; they need a binary verdict, not prose.

```
VERDICT: [APPROVED | NEEDS FIXES] — one line
REASONING: [3-4 sentences]
KEY ISSUES: [If NEEDS FIXES, list each. If APPROVED, write "none significant."]
CONFIDENCE: [high / medium / low]
TOOL / METHOD: senior-engineer-second-opinion
```

### Phase 6 — Fix-verification pass (when the user says "the fix has been applied")

A different shape of review: the user has already applied a fix from a prior NEEDS FIXES verdict and is asking you to confirm the fix landed. This is **mandatory verification, not code review** — you must read back the live state, not the fix script.

Procedure:

1. **Read the fix script** (`fix_personnel.py` or similar) to learn:
   - The exact OAuth constants (CLIENT_ID / CLIENT_SECRET / REFRESH_TOKEN).
   - The SHEET_ID and the range that was written.
   - The intended new values for every cell.
2. **Re-read the affected tabs via the API.** Don't re-execute the script's PUTs — they may already be done. Do a GET on each affected range and print the rows. Compare cell-by-cell to the intended values.
3. **Recompute the source xlsx totals independently.** Use openpyxl in read-only mode. Don't trust the fix script's claimed totals — verify the row sum, the per-category breakdown, and the cross-year sum yourself. They must match the sheet to the cent.
4. **Grep the reply draft for any leftover hardcoded contradiction.** A common failure mode is that the fix updated the sheet but the reply draft still has the old number. Use `grep -n -E "<old_number>|<new_number>" reply.txt` for every changed number; an empty result is the goal.
5. **Run the openpyxl verification script** at `scripts/verify_xlsx_totals.py` — it loads the xlsx, filters rows by year, buckets amounts by memo keyword, and exits non-zero unless the grand total matches `--expected-total` to the cent. Usage:

   ```bash
   python3 scripts/verify_xlsx_totals.py \
     --xlsx "/tmp/jorge-auditor/Jeffrey Nicholas Lee-Chan - 2025 Year Examination.xlsx" \
     --sheet "Venmo Transactions" \
     --year 2024 \
     --amount-column 1 --date-column 0 --memo-column 2 \
     --expected-total 19294.00
   ```

   Exit code 0 = match. Non-zero = print the bucket breakdown and mismatch to stderr.

If any of (2), (3), (4) fail: **NEEDS FIXES**, list exactly which cell / row / line in the reply still has the old number.

If the reply draft has *no* hardcoded numbers for the changed field (e.g. it refers to "see attached xlsx"), that's actually the cleanest outcome — the fix is durable because there's nothing to drift. Note that explicitly in REASONING.

**Reference example — 2026-08-04 EDD audit, Jake 2024 fix-verification pass:**
- Fix script: `/tmp/jorge-auditor/fix_personnel.py` (personnel + cover + unresolved tabs).
- API read-back of `Personnel Provenance!A1:J6` returned Jake row with `$19,294.00 / $14,106.00 / $1,927.00 / $3,201.00` — match.
- openpyxl re-summation of `Jeffrey Nicholas Lee-Chan - 2025 Year Examination.xlsx → Venmo Transactions`: 160 rows, $19,294.00 — match to the cent.
- Consolidated CSV (`venmo_pa_all_transactions.csv`): 76 Jake 2025 rows → $9,142.20 — match.
- Cover & Summary read-back: now says "Jake (active, 2024 total $19,294 / 2025 $9,142)" — match.
- Unresolved Items: $405 ATM (5/3/2024) and $150 Air Fryer (5/7/2024) preserved.
- Grep on `PAUDIT_RESPONSE_READY.txt` for any of the changed numbers: zero matches — the reply has no hardcoded Jake total, so it cannot contradict the corrected sheet.
- Verdict returned: **APPROVED**, confidence high.

## Pitfalls (learned 2026-08-04 EDD audit review)

1. **Don't trust the cover.** The cover tab is written by an LLM or a tired human; the detailed rows are the source of truth. Always recompute cover claims from rows.
2. **Float math hides bugs.** A $0.02 difference between tab sums can indicate a missed reimbursement or a duplicated row. Don't round cover claims without checking what got dropped.
3. **Payee labels can be inconsistent.** "Jake Goldberger", "Jake", and "See notes" all referring to the same person is confusing for the auditor. Either label consistently or split into "Wages" and "Reimbursements" blocks.
4. **Source citations must be verifiable.** If the Source column says `docs/2024-1099-prep-jake.csv`, that file must exist on disk. A non-existent source is a factual error, not a minor citation issue.
5. **Default: don't run the deliverable API.** The user already built the Google Sheet. For the *initial* review, you're inspecting the files, not regenerating them. The instructions are usually "Do NOT run the actual Google Sheet API yourself — just review the files and report." **Exception — fix-verification passes:** if the user asks you to verify a specific fix was applied (e.g. "Jake 2024 Venmo Total is now $19,294 in the sheet"), then reading back from the live API is the only way to prove the fix landed. In that case, refresh the OAuth token from the existing fix script's constants (CLIENT_ID / CLIENT_SECRET / REFRESH_TOKEN / SHEET_ID) and PUT/GET the affected range — don't regenerate the data, just confirm it.
6. **Reply drafts must cite what the user already said.** If the auditor asked "first time" and the user already answered "since 2013", the reply should quote that prior answer, not invent a new one.
7. **Excel and CSV data quirks bite silent sum bugs.**
   - xlsx Pay Date columns come back as `datetime.datetime` (not Excel serial integers) when read with openpyxl `data_only=True`. Don't apply the 1900-epoch conversion when the values are already datetimes — you'll silently exclude every row.
   - Consolidated Venmo CSVs (Venmo statement exports) use ISO timestamps with a leading `- $` on the Amount column. A naive `float(row["Amount"])` will return a negative; `float(s.replace("$","").replace(",","").lstrip("-"))` is the right pattern.
   - When bucketing by memo keyword, the classifier will always miss a few rows ("h hrs" typos, "Mexico cash in pesos", "Car wash"). Print an "unclassified" list — don't silently drop them. The grand total must still match the expected to the cent.

## Verification commands

Quick verification recipes you can paste into a terminal session:

```bash
# 1. Recompute tab totals and compare to cover claim
python3 -c "
import csv
with open('tab1_venmo_transactions.csv') as f:
    rows = list(csv.DictReader(f))
print(sum(float(r['Payment Amount']) for r in rows))
"

# 2. Find unmapped BANK_MEMO rows
python3 -c "
import csv
with open('tab2_bank_transactions.csv') as f:
    rows = list(csv.DictReader(f))
empty = [r for r in rows if not r['Response Memo (verified)'].strip()]
print(f'{len(empty)} unmapped rows')
for r in empty: print(r)
"

# 3. Verify every cited source file exists
for f in $(grep -oE 'docs/[^,]*' tab3_personnel.csv | sort -u); do
  test -f "/tmp/jorge-auditor/$f" && echo "OK   $f" || echo "MISS $f"
done

# 4. Find duplicate map keys
python3 -c "
import re
src = open('build_upload_csvs.py').read()
keys = re.findall(r\"'[^']+'\", src)
from collections import Counter
dupes = {k:v for k,v in Counter(keys).items() if v > 1}
print(dupes)
"
```

## Pointers

- `references/edd-audit-timeline-and-lessons-2026-08-05.md` — full session timeline + canonical file locations for the EDD PA audit thread (Jorge Martins, EDD account 244-5186-6). Load when this skill fires for the EDD thread specifically.

## Reference: the 2026-08-04 EDD audit incident

The packet had been built, the user had not yet hit "EMAIL APPROVED", and the senior engineer review caught:

| # | Severity | Issue |
|---|----------|-------|
| 1 | must-fix | Cover claimed Jake 2024 Venmo Total = $13,569; tab1 summed to $19,294 (full) or $13,956 (Jake-Goldberger payee). No source file on disk produced $13,569. |
| 2 | must-fix | Source column cited `docs/2024-1099-prep-jake.csv` — that file did not exist (only the 2025 version). |
| 3 | should-fix | Payee column used 3 labels for the same person (Jake Goldberger / Jake / See notes) — auditor will read this as 3 different recipients. |
| 4 | should-fix | Duplicate key `'1264|2024-04-22|3600'` in CHECK_MEMO dict (lines 43-44 of build_upload_csvs.py) — harmless but indicates a sloppy copy-paste. |
| 5 | missed unresolved | The cover-vs-tab discrepancy itself should have been an unresolved item, or fixed before the "ready for review" gate. |

Verdict returned: **NEEDS FIXES**. Without that review the packet would have shipped to Jorge with an internally inconsistent $387 gap between the cover and the line items.

## Phase 0.5 — Check `/tmp/<topic>/` for prior work (added 2026-08-05)

Before doing anything else in Phase 1, **search the user's ad-hoc staging directories** for prior versions of the packet or its components. The pattern:

```bash
# 1. Look for staging directories
ls /tmp/ | grep -iE "<topic>|<entity>|<attorney-name>"
ls ${HOME}/Desktop/ | grep -iE "<topic>|<entity>"
ls ~/Downloads/ 2>/dev/null | grep -iE "<topic>|<entity>"

# 2. If anything matches, scan it for previously-built artifacts
ls -la /tmp/<topic>/
find /tmp/<topic> -name "*packet*" -o -name "*response*" -o -name "*auditor*" 2>/dev/null

# 3. Read the most recent version before regenerating
ls -lt /tmp/<topic>/*.pdf /tmp/<topic>/*.txt 2>/dev/null | head -10
```

The 2026-08-05 EDD audit incident proves this is not theoretical. The agent was rebuilding a 6-section PDF from the data in the current Slack message. A single `ls /tmp/jorge-auditor/` revealed:

- A complete Aug 4 21:00 prior session had **already built the packet** and run it through `/advice` (verdict: APPROVED)
- The actual PA list was 4 distinct people (Jake Goldberger, **Kou Collins** not "Kou Shane", Brian Autieri, Irwin Morales)
- **Mizraim — the name in the daily cron — was a NEW PA hired Feb 22, 2026, NOT in the 2023-2025 audit window at all**
- Kevin Phan $5,000 was a business invoice (Copy and Paste Media invoice 1018), not a personal payment
- The full 2024 Venmo/Zelle line list with verified memos was already in `PAUDIT_RESPONSE_READY.txt`

If the agent had grepped `/tmp/` before building, the first-pass PDF (which contained factual errors on Mizraim, Kou's name, and the Kevin Phan classification) would never have shipped — even as a draft. The cost of the missed check was one full PDF rebuild.

**Trigger heuristic:** if the recurring daily-reminder cron for this task has been firing for >7 days with the same stale text, that's a strong signal the thread has unresolved history. Always `ls /tmp/<topic>/` and `session_search` for prior session attempts first.

## Reference: the 2026-08-05 EDD follow-up incident

The agent received "drive this without Mizraim and ask questions as needed" and built a 6-section PDF that miscategorized the people in the auditor's view (called Kou Collins "Kou Shane", called Mizraim an existing PA, classified Kevin Phan $5,000 as personal). The `/tmp/jorge-auditor/` discovery triggered a complete rebuild. Final packet added to the prior session's draft with correct identification:

| # | Severity | Issue caught after `/tmp/` discovery |
|---|----------|-------|
| 1 | must-fix | Mizraim is a NEW Feb 2026 hire — not in the 2023-2025 audit window. The packet had treated Mizraim as if their records should be in the auditor's review. |
| 2 | must-fix | Kou Shane is actually Kou Collins (koushanecollins4@gmail.com) — hired via Venice Craigslist ad 2022-07-31. The "Shane" handle is a Venmo display name; the legal/hiring name is Collins. |
| 3 | must-fix | Kevin Phan $5,000 Zelle is invoice 1018 from Copy and Paste Media (a vendor), with QuickBooks receipt on file (ref 18d627497ea90001). Not a personal payment. |
| 4 | should-fix | The packet listed Jake Goldberger's 2024 total as $14,883 raw CSV; the audit xlsx says $19,234 ($14,106 wages + $1,927 reimbursements + $3,201 advances). Difference is Venmo-balance funded payments not on Chase 3357. |
| 5 | process | The original packet had a 1st pass built before `/tmp/` discovery that should have been thrown away, not patched in place. Lesson: Phase 0.5 should run before any artifact generation, not after. |

**Correct lesson:** Phase 0.5 (grep `/tmp/<topic>/` for prior work) must run BEFORE the agent generates any deliverable. If it finds a prior version, the new work must be a delta against that prior version, not a fresh generation.
