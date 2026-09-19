# 2026-08-19 — wiki-campaign-daily-ingest: same chained-SSL symptom, different cause

> Companion to `references/2026-08-19-bq-coverage-watcher-auth-failure.md`. Same chained symptom (`BrokenPipeError` at `google/oauth2/_client.py:196` → `urllib3.exceptions.ProtocolError`), but the cause was NOT a missing-scopes bug — the library was already correct. The fix was transient retry, not Trap 1/2/3.

## TL;DR

| Field | Value |
|---|---|
| Slack thread | `C0AJQ5M0A0Y` (ts `1787182538.556889`) |
| Run started | 2026-08-19 09:00:13 PT |
| Failure observed | 2026-08-19 09:34:41 → 16:30:29 PT (6h+ bootstrap, then cold TCP handshake at ~15:34, urllib3 retry exhausted at 16:30) |
| Error class | `BrokenPipeError` (chained) → urllib3.ProtocolError → requests.ConnectionError → google.auth.TransportError |
| Apparent cause | "Same as bq-coverage-watcher, scope bug" |
| Actual cause | Launchd-side transient after 6h `pip install` bootstrap; cold TCP to `oauth2.googleapis.com:443`; first-handshake EOF after urllib3 retried 2× |
| Library path | `firebase_admin → google.auth.transport.requests.Request` → `google/oauth2/_client.py:196` (same as bq-coverage-watcher) |
| Library already passed scopes? | **YES** — `firebase_admin/credentials.py:27` defines `_scopes = ['cloud-platform', 'datastore', 'devstorage.read_write', 'firebase', 'identitytoolkit', 'userinfo.email']` and line 97 passes them to `service_account.Credentials.from_service_account_info(json_data, scopes=_scopes)` |
| Project mismatch risk | YES — `~/.config/gcloud/application_default_credentials.json` (user creds, project `ai-universe-2025`) shadowed `serviceAccountKey.json` (SA `worldarchitecture-ai`), but in THIS case the script pins via `credentials.Certificate(path)` not `google.auth.default()`, so the shadow did NOT win |
| Fix landed | `~/.smartclaw/skills/download-campaign/scripts/download_campaign.py` init_firebase() 3-attempt exponential-backoff retry + chained-cause surfacing; per-campaign `download_one` except handler also surfaces chained cause. Commit `fd8fb85f4b` on `jleechanorg/jleechanbrain` `auto/commit-pending` branch (pushed 2026-08-19 17:09 PT). |
| Outcome | Rerun green: `Downloaded=0 Skipped=16 Errors=1 Users=153` |

## The misleading Slack alert

```
:RED_circle: *wiki-campaign-daily-ingest — FAILED* @U09GH5BR3QU batch ingest exited with status 1

  File "${HOME}/worldarchitect.ai/.venv/lib/python3.12/site-packages/google/auth/transport/requests.py", line 195, in __call__
    raise new_exc from caught_exc
google.auth.exceptions.TransportError: ('Connection aborted.', BrokenPipeError(32, 'Broken pipe'))
```

If you only see this line and you have bq-coverage-watcher from earlier today fresh in your head, the natural reaction is: "Same root cause — apply the Trap 1 fix." **That is the trap.**

## What the trap 1/2/3 recipes would have done — and why they were wrong

Trap 1 says "add `scopes=` to `google.auth.default()`". The script calls `firebase_admin.initialize_app(cred)` not `google.auth.default()`. The Firebase Admin SDK already attaches scopes internally:

```python
# ~/.local/lib/python3.12/site-packages/firebase_admin/credentials.py:97
self._g_credential = service_account.Credentials.from_service_account_info(
    json_data, scopes=_scopes)
```

And `_scopes` is hard-coded to include `cloud-platform`:

```python
# ~/.local/lib/python3.12/site-packages/firebase_admin/credentials.py:27-33
_scopes = [
    'https://www.googleapis.com/auth/cloud-platform',
    'https://www.googleapis.com/auth/datastore',
    'https://www.googleapis.com/auth/devstorage.read_write',
    'https://www.googleapis.com/auth/firebase',
    'https://www.googleapis.com/auth/identitytoolkit',
    'https://www.googleapis.com/auth/userinfo.email'
]
```

**Adding `scopes=` to a hypothetical wrapper around `firebase_admin.initialize_app` would either be a no-op or break the initialization path. Don't do it.**

Trap 2 says "don't `os.environ.pop('GOOGLE_APPLICATION_CREDENTIALS')`". The script doesn't pop it — it sets it inside `init_firebase()`:

```python
def init_firebase():
    os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = str(CREDENTIALS)  # correct
    ...
    cred = credentials.Certificate(str(CREDENTIALS))                   # pinned, not google.auth.default()
    firebase_admin.initialize_app(cred)
```

Trap 2 doesn't apply because `credentials.Certificate(path)` directly reads the JSON; it does NOT walk the ADC chain. The shadow-ADC risk exists but is bypassed by `Certificate()`.

Trap 3 (chained-exception surfacing) **does** apply — and we patched that part. But the root cause is different.

## What the diagnostic actually showed

The 30-second diagnostic from the skill, run under the launchd-env wrapper:

```bash
/bin/bash ${HOME}/.smartclaw/scripts/launchd-env-wrapper.sh \
    ${HOME}/worldarchitect.ai/.venv/bin/python -u -c "
import os, sys
os.environ['GOOGLE_APPLICATION_CREDENTIALS'] = '${HOME}/serviceAccountKey.json'
import google.auth
from google.auth.transport.requests import Request
SCOPES = ('https://www.googleapis.com/auth/cloud-platform',)
try:
    creds, project = google.auth.default(scopes=SCOPES)
    creds.refresh(Request())
    print(f'OK project={project} token_len={len(creds.token)}')
except Exception as exc:
    import traceback; traceback.print_exc()
    print(f'CHAINED cause={exc.__cause__!r}')"
```

**Output:** `OK project=worldarchitecture-ai token_len=1024`. First-try success. No retry. No fault.

This is the unambiguous signal: **same env, same SA, same Python venv — works interactively, fails under launchd.** Therefore not a config bug.

## What actually failed at the wire level

The launchd plist started the script at 09:00:13 PT. The script ran `pip install` for ~6 hours (bootstrap). At 15:00:33 PT, the `Running all-users batch ingest` step started. At 15:34:43 PT — **34 minutes after the first GCP call** — urllib3 emitted:

```
WARNING - Retrying (Retry(total=2, connect=None, read=None, redirect=None, status=None))
  after connection broken by 'SSLError(SSLEOFError(8, ... EOF occurred in violation of protocol ...'
  : /token
```

This is the cold-TCP symptom: the urllib3 default retry policy (`total=3`, `connect=3`, `read=3`, no backoff between them except `Retry.DEFAULT_BACKOFF`) spun through, and the server-side `oauth2.googleapis.com` returned EOF on the SSL handshake (likely the 34-minute idle window broke keepalive, or the launchd process's TCP socket cache got reaped between cron phases). The 2 retries came back with the same failure.

The next day, the same script in the same env ran green first-try on the rerun. So it's transient.

## The fix that landed

The only durable fix worth shipping is **bounded retry with chained-cause surfacing** — so a future third class of failure (which we're not yet anticipating) won't be silently swallowed by "transient retry." Pattern:

```python
def init_firebase():
    os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = str(CREDENTIALS)
    os.environ["WORLDAI_DEV_MODE"] = "true"
    if not firebase_admin._apps:
        import time
        last_exc = None
        for attempt in range(3):
            try:
                cred = credentials.Certificate(str(CREDENTIALS))
                firebase_admin.initialize_app(cred)
                return firestore.client()
            except Exception as exc:
                last_exc = exc
                root = exc.__cause__ or exc.__context__
                msg = str(exc)
                if root and root is not exc:
                    msg = f"{exc} (chained: {type(root).__name__}: {root})"
                print(
                    f"  [WARN] init_firebase attempt {attempt+1}/3 failed: {msg}",
                    file=sys.stderr, flush=True,
                )
                if attempt < 2:
                    time.sleep(min(2 ** attempt, 8))
        assert last_exc is not None
        raise last_exc
```

Diffs from the prior `init_firebase()`:
- Added `import time` and 3-attempt loop with `time.sleep(min(2 ** attempt, 8))`.
- On final failure, the **chained exception** is unwrapped so the next operator sees the OAuth cause (e.g. `invalid_scope`) alongside the SSL frame, not just `BrokenPipeError`.
- Returns from inside the loop on success (the original returned the `firestore.client()` after `if not firebase_admin._apps:`, which was buggy — if the app was already initialized, we'd skip the init and return the client; the patch keeps that path).

Plus the `download_one` except handler got the same chained-cause unwrap.

## The diagnostic that distinguished transient from config (the tripwire)

Three checks, in order:

1. **Does the underlying library already pass scopes?** Inspect `firefb_admin.credentials.Certificate` source for `scopes=` argument; same for `google.cloud.bigquery.client.Client.__init__`, etc. If it does, Trap 1 doesn't apply.

2. **Does the script even call `google.auth.default()`?** If it uses Firebase Admin / google-cloud-* wrapper classes, the script doesn't make that call — the wrapper does. Trap 1 is not applicable to your code path.

3. **Does the 30-second diagnostic succeed under `/bin/bash ~/.smartclaw/scripts/launchd-env-wrapper.sh`?** If yes, it's a transient network failure. Rerun the launchd task manually (`bash ~/.smartclaw/scripts/wiki-campaign-daily-ingest.sh`). If that's green too, harden with retry. If the diagnostic prints an error, replay Step 1 of the canonical 4-step recipe and inspect the chained cause for the real bug class.

This is the third tripwire added in Trap 6. The other two are: "look at the library source for `scopes=`" and "the script may not even call `google.auth.default()`."

## Why we still got value from the skill

Even though Trap 1/2 didn't apply, the canonical 30-second diagnostic (Step 1 of the 4-step recipe) and the chained-cause unwrap pattern (Trap 3) saved significant time. The first action was NOT "look at the slack alert and try a Trap 1 patch" — it was "run the diagnostic, get the OAuth root cause in plain text." That's the value of the skill's diagnostic-first methodology, even when the actionable conclusion is "no config bug, it's transient."

## Counter-hypotheses considered and rejected

- **Hypothesis A:** "It's a stale `~/.config/gcloud/application_default_credentials.json` shadowing the SA file." Plausible because Trap 2 from bq-coverage-watcher is fresh in mind. **Rejected:** `credentials.Certificate(path)` reads JSON directly; the ADC chain is NOT walked. No shadow applies.
- **Hypothesis B:** "The script needs `scopes=` added to its `google.auth.default()` call." Plausible because the alert text fits Trap 1. **Rejected:** No `google.auth.default()` call exists in the script. `firebase_admin.credentials.Certificate` already passes scopes internally.
- **Hypothesis C (kept):** "Cold-TCP transient after a 6-hour bootstrap." Diagnostic confirmed: same env + same SA + same Python + 0 retries = works. Therefore transient.

## Followup suggestions

1. **Add a watchdog cron** that fires `bash ~/.smartclaw/scripts/wiki-campaign-daily-ingest.sh` 2h after the launchd run, and only sends a Slack alert if both runs failed. Cuts operator noise in half for transient failures. Bead: TBD.
2. **Add an "init-only" smoke check** at the top of the script that aborts with a clearer error if the SA env var points to a missing file or a non-Firebase project_id. Cheap insurance against future SA-rotation bugs. Bead: TBD.

## Files touched

| File | Change |
|---|---|
| `~/.smartclaw/skills/download-campaign/scripts/download_campaign.py` | `init_firebase()` 3-attempt retry with chained-cause surfacing + per-campaign `download_one` except chained-cause unwrap. +44 / -4 |
| `~/.smartclaw/skills/gcp-sa-auth-from-script/SKILL.md` | Added Trap 6 (this incident as a class); bumped to v1.2.0; added worked-example pointer. |
| `~/.smartclaw/skills/gcp-sa-auth-from-script/references/2026-08-19-wiki-campaign-transient-network.md` | This file (new). |
| `~/.smartclaw/Library/Logs/wiki-campaign-daily-ingest.log` | Failure transcript preserved at lines 19180-ish through 19380; no live change. |
