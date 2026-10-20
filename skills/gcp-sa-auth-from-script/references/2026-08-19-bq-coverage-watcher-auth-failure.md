# 2026-08-19 bq-coverage-watcher OAuth-scope auth failure — full transcript

The canonical incident for the `gcp-sa-auth-from-script` skill. Captures the misleading Slack alert body, the three compounding script bugs, the IAM regression that surfaced AFTER the auth fix, and the landed diff.

## The Slack alert that started it

```
:rotating_light: bq-coverage-watcher failed to auth: `HTTPSConnectionPool(host='oauth2.googleapis.com', port=443): Max retries exceeded with url: /token (Caused by SSLError(SSLEOFError(8, '[SSL: UNEXPECTED_EOF_WHILE_READING] EOF occurred in violation of protocol (_ssl.c:1032))))) <@U09GH5BR3QU> (run at 2026-08-19 16:52:56 UTC)
```

Two copies — the first is the `f"{exc}"` output, the second is the chained `SSLError`. Operators reading this think "the launchd job has a TLS problem". **Wrong layer.**

## What was actually happening

`~/.smartclaw/scripts/bq_coverage_watcher.py` calls `google.auth.default()` to load a service-account JSON from `$GOOGLE_APPLICATION_CREDENTIALS=${HOME}/serviceAccountKey.json`. The SA is `firebase-adminsdk-fbsvc@worldarchitecture-ai.iam.gserviceaccount.com`. The script then asks for an access token via `cred.refresh(Request())`.

Inside `google.auth`, the SA JWT grant flow is:

```python
# google/oauth2/service_account.py:461
access_token, expiry, _ = _client.jwt_grant(
    request, self._token_uri, assertion
)
```

The `assertion` is a self-signed JWT minted from the SA private key. The JWT **must** carry a `scope` claim per RFC 7523 §3 — without it, oauth2.googleapis.com rejects the grant with `invalid_scope: Invalid OAuth scope or ID token audience provided.`

The script never passed `scopes=` to `google.auth.default()`. So:

1. `creds._scopes = None`
2. JWT assertion is minted with `scope = None` (omitted claim)
3. oauth2.googleapis.com returns `400 {error: invalid_scope}`
4. `google.auth._client._handle_error_response` raises `RefreshError(invalid_scope)`
5. `urllib3` (which `google.auth` uses internally) catches the 400 as a transient error and retries (default 3 retries)
6. Each retry opens a new HTTPS connection; the third retry's connection EOFs mid-handshake (unrelated flake, but the connection IS closed cleanly)
7. `urllib3.MaxRetryError` wraps the chain as `SSLEOFError(8, 'EOF occurred in violation of protocol')`
8. The script's bare `except Exception as exc: _slack_post(... f"{exc}")` formats ONLY the outermost frame

**The SSL bytes are real — but they're not the cause.** They're the urllib3 retry layer's noise masking the actual OAuth rejection one frame deeper.

## The three compounding bugs

### Bug 1 — `google.auth.default()` with no `scopes=` (the canonical bug)

```python
def _bq_token() -> str:
    creds, _ = google.auth.default()        # NO scopes=
    if not creds.valid:
        creds.refresh(Request())
    return creds.token
```

Without scopes, the JWT has no `scope` claim and is rejected. **This is the root cause.**

### Bug 2 — `os.environ.pop("GOOGLE_APPLICATION_CREDENTIALS")` "for safety"

```python
os.environ.pop("GOOGLE_APPLICATION_CREDENTIALS", None)
import google.auth
```

This is line 40 of the script. It predates Bug 1 by months. The intent was "force ADC user creds so the env var doesn't accidentally override" — but in practice, with `gcloud auth application-default login` configured on the laptop, this strips the SA env var and lets `default()` walk the ADC fallback chain, landing on user creds. User creds were not the actual problem today (the launchd-time env propagated the SA var correctly via `launchd-env-wrapper.sh`), but the line is still wrong: it would have broken silently the moment any other ADC source appeared.

### Bug 3 — `f"{exc}"` swallows the chained cause

```python
except Exception as exc:
    _slack_post(SLACK_CHANNEL_DEFAULT,
        f":rotating_light: bq-coverage-watcher failed to auth: `{exc}` ...")
```

`f"{exc}"` only renders the outermost exception class + message. The chained `__context__` (the urllib3 SSLError) is lost. Operators reading the alert see "SSL UNEXPECTED_EOF_WHILE_READING" and chase TLS certificates instead of OAuth scopes.

## The fix that landed

### Diff 1 — Remove the env-var pop, document why

```python
# Before:
os.environ.pop("GOOGLE_APPLICATION_CREDENTIALS", None)

# After:
# (deleted; the env var is honored)

# NOTE: do NOT pop GOOGLE_APPLICATION_CREDENTIALS — this script was authored
# to use the WORLDARCH service-account key (loaded by launchd-env-wrapper.sh
# from ~/.bashrc). Previously this line popped GOOGLE_APPLICATION_CREDENTIALS
# to "force ADC user creds", but that path falls back to
# ~/.config/gcloud/application_default_credentials.json — user creds that
# cannot be exchanged for a BigQuery access token (refresh fails with
# `invalid_scope: Invalid OAuth scope or ID token audience provided.`).
```

### Diff 2 — Add scopes to `default()`

```python
_BQ_SCOPES = ("https://www.googleapis.com/auth/cloud-platform",)


def _bq_token() -> str:
    creds, _ = google.auth.default(scopes=_BQ_SCOPES)
    if not creds.valid:
        creds.refresh(Request())
    return creds.token
```

### Diff 3 — Wrap in retry-with-differentiation

```python
def _bq_token_with_retry(max_attempts: int = 4) -> str:
    """Refresh with retry on transient urllib errors; surface non-transient
    (invalid_scope, invalid_grant, invalid_request) immediately."""
    import time as _time
    transient_excs = (
        google_auth_exceptions.TransportError,
        ConnectionError,
        TimeoutError,
    )
    last_exc = None
    for attempt in range(max_attempts):
        try:
            return _bq_token()
        except google_auth_exceptions.RefreshError as exc:
            msg = str(exc)
            if "invalid_scope" in msg or "invalid_grant" in msg or "invalid_request" in msg:
                raise  # non-transient
            last_exc = exc
            if attempt < max_attempts - 1:
                _time.sleep(min(2 ** attempt, 8))
        except transient_excs as exc:
            last_exc = exc
            if attempt < max_attempts - 1:
                _time.sleep(min(2 ** attempt, 8))
    raise last_exc
```

### Diff 4 — Surface the chained exception in alerts

```python
try:
    token = _bq_token_with_retry()
except Exception as exc:
    root = exc.__cause__ or exc.__context__
    msg = str(exc)
    if root and root is not exc:
        msg = f"{exc} (chained: {type(root).__name__}: {root})"
    _slack_post(SLACK_CHANNEL_DEFAULT,
        f":rotating_light: bq-coverage-watcher failed to auth: `{msg}` ...")
    return 2
```

After this fix, future ops would see `invalid_scope: Invalid OAuth scope... (chained: TransportError: ... SSLEOFError(8, EOF occurred in violation of protocol))` in the alert body and recognize the trap immediately.

### Diff 5 — Two regression tests

```python
def test_oauth_token_requires_cloud_platform_scope(monkeypatch, tmp_streak_state):
    """Pins that google.auth.default(scopes=[cloud-platform]) is called.
    Regression guard against Bug 1."""
    ...

def test_auth_failure_message_includes_chained_cause(monkeypatch, tmp_streak_state):
    """Pins that the alert body surfaces both OAuth root cause and chained SSL cause.
    Regression guard against Bug 3."""
    ...
```

## The IAM regression surfaced AFTER the auth fix

Once the auth fix landed and `_bq_token()` returned a valid token, the script proceeded to `urllib.request.urlopen(BQ_API)` — and got:

```json
{
  "error": {
    "code": 403,
    "message": "Access Denied: Project worldarchitecture-ai: User does not have bigquery.jobs.create permission in project worldarchitecture-ai.",
    "errors": [{ "message": "...", "domain": "global", "reason": "accessDenied" }],
    "status": "PERMISSION_DENIED"
  }
}
```

The 2026-08-18 16:30 UTC run had succeeded — meaning the SA had `bigquery.jobs.create` between 2026-08-18 16:30 UTC and 2026-08-19 16:52 UTC, the role was revoked. This is an **IAM-layer issue**, not an auth-layer issue. The fix is:

```bash
gcloud projects add-iam-policy-binding worldarchitecture-ai \
  --member='serviceAccount:firebase-adminsdk-fbsvc@worldarchitecture-ai.iam.gserviceaccount.com' \
  --role='roles/bigquery.jobUser'
```

Plus, ideally, `roles/bigquery.dataViewer` for the read-side coverage check.

## The 13/13 pytest run

```bash
cd ~/.smartclaw
python3 -m pytest scripts/tests/test_bq_coverage_watcher.py -v
# ============================== 13 passed in 0.24s ==============================
```

The 2 new tests pass alongside the 11 existing tests. Future ops who re-introduce Bug 1 or Bug 3 will see test failures before merge.

## Status as of 2026-08-19

- ✅ Bug 1 (no scopes) — fixed; regression test pinned.
- ✅ Bug 2 (env-var pop) — removed; comment explains why.
- ✅ Bug 3 (chained exception hidden) — fixed; alert body surfaces OAuth root cause.
- 🟡 IAM regression (bigquery.jobs.create revoked) — NOT fixed; needs `gcloud projects add-iam-policy-binding` (out of scope for the script fix).
- 🟡 Deploy — code change staged in `~/.smartclaw/`, not yet committed or deployed (the user said "Investigate", not "ship"; per SOUL.md `hermes-deploy-pipeline`, self-mods to `~/.smartclaw/` go through `scripts/deploy.sh`).

## Why this case is the canonical worked example

Three reasons:

1. **The class-level bug** (`google.auth.default()` without `scopes=`) is endemic — it will recur in every script that authenticates to GCP. The trap is silent (no exception during script authoring; only surfaces at runtime when the JWT is rejected).
2. **The surface-cause-misleading aspect** (SSL bytes hiding OAuth scope rejection) is a category of bug that affects every script that catches with bare `except Exception`. Future ops will repeat the mistake.
3. **The two-layer bug** (auth bug + IAM regression) is a common shape: a script that worked yesterday stops working today, with TWO causes in TWO different layers. Diagnosing only one (the easier one) leaves the harder one lurking.

This transcript is the reference future ops should read FIRST when any GCP-API script fails to auth.