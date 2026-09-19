---
name: vendor-spend-reconciliation
description: "Mine Gmail for 'how much have I spent on X' vendor totals."
---

# Vendor spend reconciliation from Gmail

Use when the user asks how much money they've spent on a named vendor / payee / subscription. The canonical answer is **money actually paid** (sum of payment receipts), optionally cross-checked against **money billed** (sum of invoice amounts).

## When to load

Triggers:
- "How much have I spent on / paid to <vendor>"
- "What's my total bill from <vendor>"
- "Show me all payments to <vendor>"
- "Reconcile payments vs invoices for <vendor>"
- "What do I owe <vendor>"

Don't load for: drafting replies, scheduling with a vendor, or generic email triage. This skill is **read-only spend mining**.

## Which CLI on this Mac

Use **`gog`** (the Google CLI built on go-gmail), NOT `gws`. Verified 2026-08-05:

- `gog gmail search '<query>' --max N --json` — returns structured thread list with id/date/from/subject/labels. Supports Gmail query operators: `from:`, `subject:`, `before:YYYY/MM/DD`, `after:YYYY/MM/DD`, exact phrases, `OR`, `-`negation.
- `gws gmail` returns 403 "insufficient authentication scopes" on this machine — do not use it for Gmail queries even though `gws` works for Calendar/Drive/etc.

## 5-step workflow

### Step 1 — Cast a wide net with the vendor name

Try several queries because each captures a different signal:

```
gog gmail search '<vendor name>'               --max 50 --json   # broadest
gog gmail search 'from:<vendor-domain>'        --max 100 --json  # anything from them
gog gmail search 'from:accounting@<vendor>'    --max 100 --json  # invoices specifically
gog gmail search 'subject:("Payment Receipt from <vendor>")' --max 100 --json
gog gmail search 'subject:("Invoice from <vendor>") OR subject:("Statement from <vendor>")' --max 100 --json
```

A vendor's invoice emails typically come from `accounting@<domain>` (LawPay, Clio, NetSuite, QuickBooks); payment receipts come from `no-reply-notification@lawpay.com` or similar. The exact sender pattern is vendor-specific — try both `<vendor-domain>` and any payment-processor domain they use.

If the user only gives a colloquial name ("structure law firm") but invoices come from "Structure Law Group, LLP", cast a wide net first, then narrow.

### Step 2 — Deduplicate into two streams

Classify every returned thread into exactly one of:

1. **Payment receipt** — `Payment Receipt from <vendor> for $X.XX` in subject, OR a no-reply notification from a payment processor (lawpay.com, square.com, stripe.com, etc.)
2. **Invoice / statement** — sent by `accounting@<vendor>` or includes a PDF attachment named like `*_Stmt_*.pdf` or `Invoice*.pdf`
3. **Other** — DocuSign envelopes, intro/intake emails, replies, contracts. Not bill-relevant. Ignore unless explicitly relevant.

Pay attention to **retainer / upfront payments** that may predate the first invoice — these are real spend and belong in bucket 1.

### Step 3 — Sum payments from receipts

For payment receipts, the dollar amount is usually in the **subject line**: `Payment Receipt from X for $1,234.56`. Extract with:

```python
import re
m = re.search(r"\$([0-9,]+\.\d{2})", subject)
amt = float(m.group(1).replace(",", "")) if m else 0
```

Sum across all receipts. **This is the user's "money spent" answer** — what they actually paid.

If the receipt subject doesn't include the amount (LawPay sometimes sends bare receipts), fetch the message body via `gog gmail thread <threadId> --json` and grep for amounts.

### Step 4 — Extract invoice totals from PDFs

Invoice bodies are typically empty — the amount lives in the attached PDF. Recipe:

```bash
mkdir -p /tmp/<vendor>_invoices
gog gmail get <msgId> --json   # find attachmentId + filename
gog gmail attachment <msgId> <attachmentId> --output /tmp/<vendor>_invoices/<filename>
pdftotext -layout /tmp/<vendor>_invoices/<filename> -  # extract text
```

Then grep for totals. Law-firm / accounting PDFs typically label amounts as:
- `Balance Due` (what's still owed after credits)
- `Total Current Work` (the amount billed this period — the canonical "amount billed")
- `Total Expenses`

**Prefer "Total Current Work" over "Balance Due"** for the per-invoice billed amount — "Balance Due" can be $0 on invoices where the prior balance carried forward, even though work was performed. Sum "Total Current Work" + "Total Expenses" across invoices for total billed.

### Step 5 — Reconcile

Build a 3-column reconciliation:

| Stream | Source | Total |
|---|---|---|
| Paid (payment receipts) | subjects with `$X.XX` | sum |
| Billed (invoices) | "Total Current Work" + "Total Expenses" from PDFs | sum |
| Outstanding | Billed − Paid | computed |

The two streams usually reconcile to the cent if all invoices and all payments were captured. If they don't, the gap is either:
- An invoice that was sent but not yet paid (Balance Due > 0, no receipt)
- A payment receipt with no matching invoice (retainer, fee, deposit)
- Missing email (older than Gmail retention, in trash, in another account)

Report each of these explicitly — don't hide the gap.

## Pitfalls

- **`gws gmail` is broken** on this Mac (403 insufficient scopes). Use `gog`.
- **Gmail search doesn't search PDF bodies**. The invoice subject rarely has the dollar amount; you must download the PDF and `pdftotext` it.
- **`Balance Due` is not the invoice amount** — it's what remained after credits/prior payments. Use `Total Current Work` for the actual billed amount.
- **Retainers are spend but may have no invoice**. The first $7,500 payment to Structure Law Group was a retainer signed the same day as the engagement letter, with no corresponding invoice email. Include it — it's real spend.
- **Inbox coverage starts at "earliest email"** — not at the engagement start. If the user has been with the vendor longer than their Gmail history, say so explicitly. Pre-Gmail spend isn't recoverable here.
- **Email is one signal** — confirm with bank/card statements before treating this as final. Don't claim "lifetime spend"; claim "spend visible in this Gmail account over this date range".
- **`from:"Structure Law"` (without .com) misses structurelaw.com emails.** Always try the bare domain `from:structurelaw.com` too.
- **Don't trust `nextPageToken` defaults.** Pass `--max 100` and paginate explicitly; default `--max` is small and you miss the tail.

## Output format

Return a 3-line summary first, then a per-event table. Format that has worked:

```
**Vendor**: <canonical name>
**Money paid**: $X across N payments (<date range>)
**Money billed**: $Y across M invoices (<date range>)  ← if extracted
**Outstanding**: $Z  ← computed
**Caveat**: <Gmail coverage limits, missing pre-inbox spend, etc.>
```

Then a per-event markdown table (date, amount, note), then ask if they want line-item detail on any specific invoice or to check older accounts.

## Verification

Before claiming completion:

- `[ ]` Sum of payment receipts ≥ number of distinct payment events returned by Gmail search.
- `[ ]` If invoices were extracted, "Total Current Work" + "Total Expenses" per invoice agrees with "Balance Due" + subsequent payment receipts (to the cent).
- `[ ]` Reply names the exact Gmail query used and the date range searched.
- `[ ]` Reply flags any pre-inbox spend or other gaps explicitly.

## Example (verified 2026-08-05)

User: "How much money have I spent on structure law firm"

```
gog gmail search 'from:structurelaw.com OR from:"Structure Law"' --max 100 --json   → 46 threads
gog gmail search 'from:accounting@structurelaw.com subject:("Structure Law Group Invoice")' --max 100 --json   → 11 invoices
gog gmail search 'subject:("Payment Receipt from Structure Law Group, LLP")' --max 100 --json   → 7 receipts
# Sum receipts: $13,450.82
# Sum invoice PDFs (Total Current Work + Total Expenses): $13,486.64
# Gap $35.82 = unbilled expenses on invoice #71576 (Total Expenses $20.80 + earlier)
# 7 payments ≠ 11 invoices because retainer $7,500 + 6 monthly payments ≠ 11 invoices
```

## Support files

- `references/law-firm-pdf-format.md` — what to expect from Clio/LawPay-generated invoice PDFs (Total Current Work, Balance Due, Total Expenses labels) when scraping a law firm.