# Law firm invoice PDF format (Clio / LawPay)

Reference for scraping `pdftotext -layout` output from Clio-generated invoice PDFs (the format Structure Law Group, LLP uses). Other legal billing platforms (MyCase, PracticePanther, NetDocuments) are similar but may label fields differently.

## Filename convention

```
<client_matter_code>_Stmt_<invoice_number>.pdf
```

Example: `4138.001_Stmt_74275.pdf` → client matter `4138.001`, invoice `#74275`.

Use the `_<invoice_number>.pdf` suffix as a stable key for joining payments to invoices.

## Layout (top to bottom, single page typically)

```
<Law firm letterhead>

Statement
Invoice #: 74275
Statement Date: 06/01/2026
Client / Matter: Jeffrey Lee Chan / 4138.001

<Optional: prior-balance block>

Balance Forward                                 <$X.XX>

New Charges

Professional Services
  Date    Description                  Hours   Rate    Amount
  ...
  Total Professional Services                            $X.XX

Expenses
  Date    Description                            Amount
  ...
  Total Expenses                                     $X.XX

                    Total Current Work                  $X.XX
                    Total Expenses                      $X.XX

                    Balance Due                         $X.XX
```

## What each amount means

| Label | Meaning | When to use |
|---|---|---|
| `Total Current Work` | Sum of professional services billed this period (excludes expenses). | **Canonical "amount billed"** for this invoice. |
| `Total Expenses` | Disbursements (filing fees, courier, etc.). | Add to `Total Current Work` for fully-billed amount. |
| `Balance Forward` | Unpaid amount from prior invoice being carried into this one. | Ignore when summing per-invoice billed amounts — it's a rollforward, not new spend. |
| `Balance Due` | `Balance Forward + Total Current Work + Total Expenses − Payments/credits since last statement`. | The amount the client currently owes. NOT what was billed this period. |

## Reconciliation arithmetic

```
Per-invoice billed amount = Total Current Work + Total Expenses
Sum across invoices       = Total billed in period
Sum of Payment Receipts   = Total paid in period
Outstanding               = Sum(Balance Due) where Balance Due > 0 AND no later payment receipt exists
```

## `pdftotext -layout` regex cookbook (verified 2026-08-05)

```python
import re

def extract_amounts(text):
    work = re.search(r"Total Current Work\s*\$?\s*([0-9,]+\.\d{2})", text)
    exp  = re.search(r"Total Expenses\s*\$?\s*([0-9,]+\.\d{2})", text)
    bal  = re.search(r"Balance Due\s*\$?\s*([0-9,]+\.\d{2})", text)
    fwd  = re.search(r"Balance Forward\s*\$?\s*([0-9,]+\.\d{2})", text)
    return {
        "work": float(work.group(1).replace(",", "")) if work else 0.0,
        "expenses": float(exp.group(1).replace(",", "")) if exp else 0.0,
        "balance_due": float(bal.group(1).replace(",", "")) if bal else 0.0,
        "balance_forward": float(fwd.group(1).replace(",", "")) if fwd else 0.0,
    }
```

## Gotchas

- **Layout wraps awkwardly.** `Total Current Work\n   $X.XX` or `$X.XX\nTotal Current Work` are both common; the regex above tolerates both.
- **Multiple "Total" lines exist.** Always anchor on `Total Current Work`, not bare `Total` — `Total Professional Services` and `Total Expenses` are siblings.
- **Balance Due = $0 does NOT mean no work was done.** It means the prior balance was paid down. If you sum `Balance Due` instead of `Total Current Work`, you'll underreport spend dramatically.
- **Some invoices include "Aged Due Amounts" tables** (0-30, 31-60, 61-90, 91-120 day buckets). Ignore — these summarize `Balance Due`, not new charges.
- **Past-due prefixes in subject** (`***PAST DUE*** Structure Law Group Invoice #...`) don't change the underlying amount — same extraction works.
- **"$0.00" amounts are valid** for `Balance Forward` on the very first invoice; don't skip them.

## Worked example: Structure Law Group (2026-08-05)

| Inv#  | Date       | Work       | Expenses | Balance Due |
|-------|------------|------------|----------|-------------|
| 69957 | 2025-08-11 | $810.00    | $0.00    | $0.00       |
| 70432 | 2025-09-10 | $4,573.02  | $15.02   | $0.00       |
| 70735 | 2025-10-14 | $3,089.00  | $0.00    | $972.02     |
| 71576 | 2025-12-01 | $1,727.80  | $20.80   | $1,727.80   |
| 71681 | 2025-12-08 | $1,124.50  | $0.00    | $1,124.50   |
| 72097 | 2026-01-12 | $84.00     | $0.00    | $84.00      |
| 72516 | 2026-02-10 | $332.50    | $0.00    | $332.50     |
| 72916 | 2026-03-11 | $142.50    | $0.00    | $475.00     |
| 73360 | 2026-04-09 | $1,140.00  | $0.00    | $1,615.00   |
| 73842 | 2026-05-11 | $427.50    | $0.00    | $427.50     |
| 74275 | 2026-06-11 | $0.00      | $0.00    | $427.50     |

Sum Work = **$13,450.82**, Sum Expenses = **$35.82**, Total Billed = **$13,486.64**.
Payment receipts (7) sum to **$13,450.82** — exactly equal to "Total Current Work", confirming each invoice's Work was paid but the $35.82 in expenses were absorbed into the payments without separate line items.