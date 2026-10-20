# EDD Audit Response v2 — Aug 6 Status Cron Reproduction

Concrete reproduction recipe for the canonical EDD audit response status cron pattern. Pulled from the Aug 5 + Aug 6 sessions on `C0AMM2B4319` (`#life`).

## Thread anchors

- Channel: `C0AMM2B4319` (`#life`)
- Root thread ts: `1783398269.835479`
- Jeffrey user-id: `U09GH5BR3QU`
- Hermes bot user-id: `U0AEZC7RX1Q`

## Deliverable artifacts

- Sheet v2: `1LMDvn3rbtr5PYu1FtOYQhz_a0qd3EfKKgvnhMwzxMYk`
  - URL: https://docs.google.com/spreadsheets/d/1LMDvn3rbtr5PYu1FtOYQhz_a0qd3EfKKgvnhMwzxMYk/edit
  - 9 tabs including `Per-Person Services` and `Open Items`
  - Access: anyone-with-link; Cindil = writer
- Doc v2: `14btF3zSR0Fc9z98bim8oFGQAH1jj6vX7lc38sxw-D-c`
  - URL: https://docs.google.com/document/d/14btF3zSR0Fc9z98bim8oFGQAH1jj6vX7lc38sxw-D-c/edit
  - Access: anyone-with-link; Cindil = writer

## Open Items (initial state from Aug 5)

| # | Item | Status | What is needed |
|---|------|--------|----------------|
| 1 | Sep 30, 2024 $359 Zelle to Yoni (last name unknown) - purpose | UNRESOLVED | Confirmation from Jeffrey of the purpose (likely personal). Also need full last name spelling. |
| 2 | May 2, 2024 $405 "ATM" and May 5, 2024 $150 "Air fryer" (Jake) | NEEDS CONFIRMATION | Written confirmation from Jeffrey that these are reimbursements (personal errands), not wages. |
| 3 | Check 1262-1269 payee/purpose | UNRESOLVED | Paper images, QBO check register, or written confirmation from Jeffrey per check. |
| 4 | Yoni last name spelling | UNRESOLVED | Auditor spreadsheet truncates after "Don". |
| 5 | Mizraim Morales Gonzalez (NEW Feb 2026 PA) - EDD registration | IN PROGRESS | Full legal name, SSN, DOB, mailing address, start date (Feb 22, 2026), hourly wage needed to file PA registration at eddservices.edd.ca.gov (account 244-5186-6). |
| 6 | Brian Autieri continuation beyond June 2025 | NEEDS CONFIRMATION | Jeffrey says he only worked a few days - does that mean the role ended June 22, 2025, or that the audit-relevant work was a few days even if the role continued? |
| 7 | 1099-NEC for Jake 2025 ($9,142.20 wages) | IN PROGRESS | Will be filed separately; once filed, copy will be supplied to auditor as evidence of compliance with the 2025 penalty waiver condition. |

## Jeffrey's 8/5 reply (verbatim, ts `1785998784.980619`)

```
1 construction
2 reimbursements 
3 not PA
4 yoni is his name don't know last name
5. Search gmail and my text messages and Evernote
6. He only worked a few days
7. Do not send email make a new Google sheet and Google doc
```

## Per-Person Services tab — answers applied (Aug 5 session)

- **Jake Goldberger** Notes: "2024 reimbursements (non-wage) include $405 ATM and $150 Air fryer (personal errands, not wages)"
- **Brian Autieri** Notes: "Jeffrey (8/5/26): 'He only worked a few days.'"
- **Yoni (last name unknown)** Notes: "First name is Yoni; last name unknown (auditor spreadsheet truncates after 'Don'). ... Likely personal, not a PA payment"
- **Checks 1262-1269** — implied "construction" → maps to Kevin Phan / Copy and Paste Media entry classified as "business vendor (media work)" — **BUT** "construction" is NOT the same as "media work"; this mapping may be wrong. Cron task did not surface this discrepancy explicitly.

## Cross-tab staleness (Aug 6)

After answers landed in Per-Person Notes column, the **Open Items Status column stayed UNRESOLVED/NEEDS CONFIRMATION** for items 1, 2, 3, 4, 6. This is the most useful pattern from this session: **a one-tab write can leave the cross-reference stale**. Always check both sides.

## Cron prompt premise errors (Aug 6)

The Aug 6 20m cron prompt said: "Last cron ping posted 3 unblocking questions (2026-08-06)." Actual prior ping (ts `1786000783.162909`) was a **status confirmation** ("4 answers applied"), not 3 questions. The cron also said "Brian Autieri from 'Yes - PA' to 'NOT a PA' to match Jeffrey's 8/5/26 'he only worked a few days' answer" — but Jeffrey's verbatim answer was ambiguous; the Aug 5 session correctly left Brian's classification as "Yes - PA" with the quote in Notes. **The cron was asking me to apply a substantive audit-document reclassification that Jeffrey never explicitly authorized.**

## Ping pattern that worked (Aug 6 reply, ts `1786002175.851599`)

Single concise ping with:
- Verified state recap (deliverables intact + what answers landed where)
- One inconsistency flag (Open Items status column is stale)
- ONE concrete blocking question per pending item, each with explicit reply token (`UPDATE STATUS`, `FLIP BRIAN`, `KEEP BRIAN PA`)
- No new follow-up cron created (avoided dropped-thread detector loop)
- No email sent (per Jeffrey's 8/5 "Do not send email" instruction)

## Standing constraints

- Do NOT email Jorge or the auditor (Jeffrey's 8/5 instruction still in force)
- Do NOT flip Brian Autieri's classification unilaterally — wait for "FLIP BRIAN" or "KEEP BRIAN PA"
- Do NOT create a new status cron after posting — existing cron self-cancels at `--at 20m --delete-after-run --repeat 1`
- Items #5 and #7 are on separate tracks (Mizraim EDD PA registration, Jake 1099-NEC 2025)