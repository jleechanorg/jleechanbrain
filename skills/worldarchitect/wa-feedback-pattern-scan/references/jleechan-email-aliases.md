# jleechan email aliases + UIDs (verified 2026-08-17)

## Why this matters

When excluding jleechan from cross-user scans, **UID-based exclusion alone misses aliases**. The original scanner was given `EXCLUDED_UID = "vnLp2G3m21PJL6kxcuAqmWSOtm73"` (which is `jleechan@gmail.com`'s UID). On the first scan it picked `jleechan@worldarchitect.ai` as the top candidate because that email belongs to a *different* UID (`FZCUaRqs5rMvnA8A2rdGPsfLkjh2`) — same human, different login.

## Known jleechan identities (verified 2026-08-17)

| Email | UID |
|---|---|
| `jleechan@gmail.com` | `vnLp2G3m21PJL6kxcuAqmWSOtm73` |
| `jleechan@worldarchitect.ai` | `FZCUaRqs5rMvnA8A2rdGPsfLkjh2` |
| `leechanfamilyjlc@gmail.com` | `Epm5HkoUKoSj5qinCwcnRF2ftqw1` |

Note: there may be more. **Always re-verify with `auth.list_users()` when starting a new scan** — the canonical way is:

```python
import firebase_admin
from firebase_admin import auth

for u in auth.list_users().iterate_all():
    email = (u.email or "").lower()
    if "jleechan" in email or "leechan" in email:
        print(u.uid, email)
```

If you spot a new jleechan alias, add it to `EXCLUDED_EMAILS` in `scripts/scan_campaigns.py`.

## Why not a UID-only exclusion?

Two reasons:

1. **Same human, multiple UIDs** — Firebase Auth allows the same email to exist as multiple accounts (rare but happens for migrated accounts, dev sandboxes, etc.) or for the same person to use a different email on the same project.

2. **jleechan's own campaigns ARE his test bed** — jleechan is the WA developer; his campaigns are development fixtures, not real-user behavior. Excluding his data is necessary regardless of which email/UID it's under.

## The defensive pattern

```python
EXCLUDED_UID = "vnLp2G3m21PJL6kxcuAqmWSOtm73"
EXCLUDED_EMAILS = {"jleechan@worldarchitect.ai", "leechanfamilyjlc@gmail.com"}

def is_excluded_email(email):
    if not email:
        return True
    e = email.lower()
    if e in EXCLUDED_EMAILS:
        return True
    for p in ["test", "anon", "dev-runner", "example.com", "jleechantest"]:
        if p in e:
            return True
    return False

# Always check BOTH uid AND email in the user loop
if uid == EXCLUDED_UID or is_excluded_email(email):
    continue
```

The canonical WA prod-data-query helper (`~/.smartclaw/skills/wa-prod-data-query/scripts/query_real_users.py`) only has the UID + email-pattern filter. It would have the same blind spot. A future improvement is to merge these exclusion lists, but until then, run this verification pass before trusting any cross-user scan.