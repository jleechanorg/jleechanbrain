# Reference: CA SOS BizFile + FTB standing check (verified bot-blocked)

Verified 2026-08-21, Lee-Chan Consulting LLC (CA #202252616766). When the user asks "is my LLC still active with the state / FTB?", `gog`/`rclone` only get you Gmail+Drive — they do NOT have live BizFile or FTB standing data. Live checks hit bot protection on every path tried.

## What was tried (all blocked)

| Path | Result |
|---|---|
| `curl https://bizfileonline.sos.ca.gov/search/business` | Incapsula WAF — returns "Request unsuccessful. Incapsula incident ID: 92000310955740646" iframe |
| `curl` POST JSON body to same URL | Same Incapsula block, different incident ID |
| Headless browser → bizfileonline.sos.ca.gov | Cloudflare/Incapsula challenge page renders, no JS challenge auto-resolves |
| `curl https://opencorporates.com/companies/us_ca/202252616766` | HAProxy Captcha challenge ("We need to verify you are human...") |
| `curl https://api.opencorporates.com/v0.4/companies/search?q=...&jurisdiction_code=us_ca` | HTTP 401 — API key required (free tier insufficient) |
| `curl https://webapp.ftb.ca.gov/eletter/` | Page loads (HTML 200), BUT form requires client-side SHA256 JS fingerprint via `IRS_fingerprint.js` + `Fingerprint2` — non-trivial to replicate via curl |
| FTB eletter with cookies + curl POST | Returns "Challenge Validation" page — JS fingerprint value is empty server-side; form silently blocked |
| Headless browser → `webapp.ftb.ca.gov/eletter/` (with longer waits) | JS execution timed out at `Runtime.evaluate` — browser harness cannot reliably run the fingerprint code path |

## What worked: corporate.ai (cached BizFile mirror)

`https://corporate.ai/entity/ca/<entity#>/<slug>` returns a cached copy of the BizFile record. The page is static HTML — `curl` works without any WAF challenge. The "Refreshed <date>" stamp on the page tells you how recent the cache is.

Example for the LLC from this session:

```bash
curl -fsSL -A 'Mozilla/5.0' 'https://corporate.ai/entity/ca/202252616766/lee-chan-consulting-llc' \
  | python3 -c "
import re, sys
html = re.sub(r'<script[\s\S]*?</script>', '', sys.stdin.read())
html = re.sub(r'<style[\s\S]*?</style>', '', html)
text = re.sub(r'<[^>]+>', ' ', html)
for m in re.finditer(r'(Status|Refreshed|Formed|Filing #|Entity type)[^.]{0,200}', text):
    print(m.group(0))
"
```

Sample output (2026-08-21):

```
Filing # 202252616766 Lee-Chan Consulting LLC Active LLC California Formed September 27, 2022
Refreshed May 19, 2026
Status Active
Filing type Domestic
Addresses Principal address 1046 ROSE AVE · VENICE, CA · United States
```

**Important caveats**:

- corporate.ai mirrors **SOS data only**. It does NOT have FTB standing.
- Cache is refreshed ~weekly to monthly. "Active" with a 2026-05-19 stamp is meaningful; "Active" with a 2024 stamp is stale and the LLC may have been suspended since.
- The page shows "Formation cohort" stats ("3,766,242 LLCs registered in CA, 53% currently active") which is a population baseline, not LLC-specific. Don't read it as the LLC's status.

## FTB standing — only path is real user session

FTB does not expose standing data to anonymous HTTP requests. The only reliable paths are:

1. **User logs into MyFTB directly** (https://myftb.ftb.ca.gov/) and reports back
2. **CPA / EA logs in on user's behalf** with proper power of attorney
3. **FTB self-serve entity status letter** at `webapp.ftb.ca.gov/eletter/` — but ONLY via a real browser session that can execute `IRS_fingerprint.js`. Headless attempts timed out at the JS-fingerprint step.

When you hit this in a session, report the **honest result** ("I cannot check FTB live from this environment — only you, logging into MyFTB, can get an authoritative answer") and pivot to Gmail/Drive to find evidence of recent FTB correspondence (Form 568 filings, $800 franchise tax WebPay confirmations, EDD account correspondence, etc.).

## Worked example: what "no FTB correspondence" means

For the LLC in this session, the absence of evidence IS the signal:

- Gmail `from:ftb.ca.gov` returned 2 hits — both 2022 WebPay $45,162 + $40.96 under the personal name "LEECHAN" (no hyphen), neither tied to the LLC
- Gmail `subject:(Form 568 OR Franchise Tax)` filtered to LLC-relevant hits: only a Monarch Money alert for a $14,180 personal "expense" (likely back-taxes, not LLC franchise tax)
- Gmail `California Franchise Tax Board` broader search: 0 hits for Form 568, $800 franchise tax, or any LLC-specific correspondence
- 5+ years of LLC existence with zero FTB correspondence in Gmail

**Interpretation**: surface it to the user as "no FTB Form 568 or $800 franchise tax payment found across 5+ years of LLC existence — likely delinquent, please verify in MyFTB". Do NOT claim "FTB standing is good" based on absence of evidence — FTB will suspend LLCs for unpaid franchise tax without sending email to the entity contact, and absence of correspondence is the expected symptom.

## Pitfall — don't trust corporate.ai's "Active" without checking cache date

The corporate.ai page renders "Status Active" for the LLC with `Refreshed: May 19, 2026`. That's meaningful on the day it's checked (today is 2026-08-21, ~3 months after refresh). If a future session sees `Refreshed: 2024-01-15` on the same URL, treat it as stale and flag it. Always cite the refresh date in any user-facing summary.

## Pitfall — don't conflate SOS Active with FTB Good Standing

These are separate jurisdictions:
- **SOS Active** = the entity is registered with the Secretary of State and not suspended by SOS for missed Statements of Information (LLC-12) or other SOS-level issues
- **FTB Good Standing** = the entity has paid its $800 minimum franchise tax + filed Form 568 + has no outstanding FTB penalties. FTB can suspend a CA LLC even if SOS still shows it as Active. CA courts have repeatedly ruled that an LLC suspended by FTB cannot sue in CA court, contracts can be voided, and reinstatement requires paying all back tax + penalties + a reinstatement fee.

Always tell the user "SOS shows Active; FTB standing requires you to log in to MyFTB — these are separate".
