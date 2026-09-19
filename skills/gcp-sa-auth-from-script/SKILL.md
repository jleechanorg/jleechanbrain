---
name: gcp-sa-auth-from-script
version: 1.2.0
category: devops
description: 'Fix invalid_scope/SSL/403 in Python google.auth scripts.'
tags: ["gcp", "iam", "oauth", "google-auth", "service-account", "launchd", "cron", "bigquery"]
related_skills:
  - hermes-health-check
  - cron-jobs-and-messaging-credentials
  - wa-cloud-logging-diag
changelog:
  - '1.2.0 (2026-08-19 17:30 PT): Add Trap 6 — the same "BrokenPipe in oauth2 client" chain can be a launchd-side transient network failure, NOT a scope bug, when the underlying library (Firebase Admin SDK, google-cloud-bigquery, etc.) already passes correct scopes internally. Three tripwires to distinguish transient from config before applying any Trap 1/2/3 fix. Harden pattern for "library is correct, network is flaky". Worked example: 2026-08-19 wiki-campaign-daily-ingest incident (commit fd8fb85f4b).'
  - '1.1.0 (2026-08-19 20:42 UTC): Add the "two return codes" pattern (RC=2 = auth failure, RC=3 = post-authz IAM failure). They are the only programmatic disambiguator between "scope bug" and "missing role". Add the operational gap: uncommitted fixes in ~/.smartclaw/ do NOT get picked up by launchd; the script mtime is the source of truth, not `git log`. Reference the diagnose script. Confirm the trap recurs on the second day if the fix is not shipped.'
  - '1.0.0 (2026-08-19): Initial extract from the bq-coverage-watcher 2026-08-19 incident. Captures the three compounding bugs (no scopes on `default()`, missing surface-cause surfacing in alert bodies, plain `os.environ.pop("GOOGLE_APPLICATION_CREDENTIALS")` falling through to user creds), the canonical scopes-per-API table, and the alert-body pattern that surfaces the real OAuth root cause alongside any chained network error.'
---

# GCP service-account auth from a Python script

> **Load this skill BEFORE writing any `google.auth.default()` call in a script.** The single most common failure is "no `scopes=` argument", which produces a JWT without a `scope` claim, which oauth2.googleapis.com rejects with `invalid_scope`, which urllib3 chains as a misleading `SSL UNEXPECTED_EOF_WHILE_READING`. The class-level rule: **`google.auth.default(scopes=[...])` is always required for SA JWT grants** — there is no implicit default scope.

## Trigger phrases

- "My launchd script gets `invalid_scope` when calling BQ" / "BQ returns `User does not have bigquery.jobs.create`"
- "Cron job posts `SSL UNEXPECTED_EOF_WHILE_READING` / `oauth2.googleapis.com/token` to Slack"
- "My Cloud Run watcher stopped working but the SA file is still on disk"
- "Any `google.auth` + service-account JSON key" debug
- "The same script worked yesterday, now it 403s"
- Any time a GCP-API script's alert body mentions SSL/EOF/oauth2/token URL — the surface cause is misleading

## When NOT to use this skill

- Browser-side GCP auth (gapi client, OAuth2 implicit flow) → different class, no `google.auth`
- GCP service-to-service via metadata server (`metadata.google.internal`) → `google.auth.default()` works without scopes here (the metadata server returns an identity token, not a JWT grant)
- AWS auth from a script → not in scope
- Workload Identity Federation / GKE pod identity → different auth surface

## The three known trap classes (all verified 2026-08-19)

### Trap 1 — `google.auth.default()` with NO `scopes=` (the canonical bug)

Service-account JWT grant requires a `scope` claim. `google.auth.default()` loads the SA from `$GOOGLE_APPLICATION_CREDENTIALS` but does NOT attach scopes, so a bare refresh() produces a JWT without `scope` and oauth2.googleapis.com rejects it with `invalid_scope: Invalid OAuth scope or ID token audience provided.`

The surfaced error is misleading: urllib3's retry layer chains the rejection as `Max retries exceeded with url: /token (Caused by SSLError(SSLEOFError(8, '[SSL: UNEXPECTED_EOF_WHILE_READING] EOF occurred in violation of protocol (_ssl.c:1032)))))`. Operators reading the Slack alert will see "SSL error" and look at TLS certificates. The bug is OAuth scope.

**The fix is one line:**

```python
import google.auth

# Always pass scopes to google.auth.default() — there is no implicit default.
SCOPES = ("https://www.googleapis.com/auth/cloud-platform",)
creds, _ = google.auth.default(scopes=SCOPES)
```

`cloud-platform` is the right scope for almost every GCP API (BQ, GCS, Logging, Secret Manager, Pub/Sub). Use the narrower scope only when the API strictly requires it (rare).

### Trap 2 — `os.environ.pop("GOOGLE_APPLICATION_CREDENTIALS")` "for safety"

A second bug often coexists with Trap 1 in older scripts:

```python
os.environ.pop("GOOGLE_APPLICATION_CREDENTIALS", None)
import google.auth
creds, _ = google.auth.default()  # falls back to ADC user creds
```

The intent was "force ADC user creds so the env var doesn't accidentally override". The reality: `google.auth.default()` then walks the ADC fallback chain (`~/.config/gcloud/application_default_credentials.json` → GCE metadata server → GKE service account) and loads whatever it finds FIRST. On a developer laptop with `gcloud auth application-default login` configured, that is **user creds** — which have their own scope claims, often valid for `cloud-platform`, but with a refreshable access token that may have been revoked, expired, or scoped differently than the script expects.

The trap: env-var-popping scripts worked yesterday because no other ADC source existed; today they fail because the user ran `gcloud auth application-default login` (intentionally or via `gcloud init`). Removing the SA env var hides the original auth intent.

**The fix:**

```python
import google.auth
# Do NOT pop GOOGLE_APPLICATION_CREDENTIALS. If you want to FORCE user creds,
# explicitly call google.auth.load_credentials_from_file() with the SA path.
# Otherwise let the env var win and pass scopes.
creds, _ = google.auth.default(scopes=("https://www.googleapis.com/auth/cloud-platform",))
```

### Trap 3 — Alert body buries the chained exception

`urllib3` and `google.auth` wrap the OAuth rejection in a chain: `RefreshError` ← `TransportError` ← `SSLError(SSLEOFError)`. When a script catches with `except Exception as exc` and formats `f"{exc}"`, the alert body shows only the SSL bytes. Operators waste hours debugging the wrong layer.

**The fix — surface the chained exception:**

```python
try:
    creds.refresh(Request())
except Exception as exc:
    root = exc.__cause__ or exc.__context__
    msg = str(exc)
    if root and root is not exc:
        msg = f"{exc} (chained: {type(root).__name__}: {root})"
    # Post BOTH the OAuth root cause AND the network wrapper to Slack.
    _slack_post(channel, f":rotating_light: failed to auth: `{msg}` {investigator}")
```

The pattern above is what landed in `~/.smartclaw/scripts/bq_coverage_watcher.py` after the 2026-08-19 incident. Future ops will see `invalid_scope: Invalid OAuth scope... (chained: TransportError: ... SSLEOFError ...)` and recognize the trap instantly.

### Trap 4 — Auth-script "fix" was uncommitted; launchd ran the OLD version

Verified 2026-08-19 20:42 UTC (recurrence within hours of the original 16:52 UTC incident). The script fix had landed on disk (`git diff` showed the new code in `scripts/bq_coverage_watcher.py`) but was NEVER committed or pushed. The launchd scheduler runs whatever is on disk under `~/.smartclaw/scripts/`, so the new code WAS being executed. The misleading part was that the alert body string format the operator saw was the OLD tuple format because the f-string alert text was not changed when the script was edited on disk.

The trap: **`git status` says "modified" forever, but no one is alerted**. The script works because the on-disk version is correct, but ONLY for that one script invocation path. If a refactor or rollback happens, the uncommitted fix silently disappears. Conversely, the alert text may be stale because the EXCEPTION text from `google.auth` is what changes, not the script's f-string.

**The fix:**

1. Commit the script change immediately after the dev-run passes. Use the `claudem/<model-id>:` prefix per `~/.claude/CLAUDE.md` env-preferences.
2. For `~/.smartclaw/`-owned scripts, run `~/.smartclaw/scripts/deploy.sh` after the commit to ensure the running gateway / launchd picks up the change (launchd uses the script path verbatim, so a commit is sufficient for the watcher, but the rest of `~/.smartclaw/` needs redeploy).
3. Add a watchdog: if a script has uncommitted changes for >24h, alert. The `git-dirty-tree-triage` skill covers this pattern — load it when the working tree accumulates 28+ uncommitted files (the 2026-08-19 commit accidentally bundled 27 unrelated files because they were all uncommitted).

**Diagnostic to confirm this trap:** when the script's behavior doesn't match `git log -1 --format='%s' scripts/<name>.py`, the on-disk version is the source of truth. Reading the script file directly (not via `git show`) is the only reliable test:

```bash
# Check what launchd ACTUALLY runs (on-disk, not git)
sed -n '/_BQ_SCOPES/,/^    return creds.token/p' ${HOME}/.smartclaw/scripts/bq_coverage_watcher.py

# Check what git thinks the script is
git -C ${HOME}/.smartclaw show HEAD:scripts/bq_coverage_watcher.py | grep -c _BQ_SCOPES
```

If the on-disk version has the fix but `git show HEAD` does not, the fix is uncommitted and will be lost on next rebase / branch switch / worktree teardown.

### Trap 5 — RC=2 vs RC=3 distinguish auth-failure from post-authz IAM failure

The 2026-08-19 20:42 UTC alert body said `failed to auth: invalid_scope`, but the script's actual return code distinguishes the two layers:

| Return code | Catches | Alert text | Meaning |
|---|---|---|---|
| 2 | `except Exception` around `_bq_token_with_retry()` | `:rotating_light: ... failed to auth: ...` | Pre-authz: scopes / audience / grant problem. Fix `google.auth.default()` call. |
| 3 | `except Exception` around the BQ query body | `:rotating_light: ... query failed: ...` | Post-authz: token is valid but IAM role missing. Fix is `gcloud projects add-iam-policy-binding`. |

**The trap:** the operator reads the alert text and assumes "auth failed" means the scope bug. On 2026-08-19 the SECOND alert at 20:42 UTC was actually the auth branch (RC=2), and the script was running the CORRECT fixed code — but the SA's IAM role (`roles/bigquery.jobUser`) had been revoked between 2026-08-18 16:30 UTC (last green run) and 2026-08-19 20:42 UTC. The actual root cause was IAM, not auth. The alert text was misleading because the OLD format string from the uncommitted code emitted the OAuth error which dominated the tuple display.

**The fix:** when the alert body says "failed to auth: invalid_scope", verify (a) the script's return code (`echo $?` in the launchd log), AND (b) the script's mtime. If the script was modified recently and the alert text uses an old format, the fix is uncommitted. If the script is committed and the alert text is current, the IAM role is the next suspect.

Quick diagnostic that disambiguates the two bugs:

```bash
# After the alert, run the script in the same env the launchd job sees
/bin/bash ${HOME}/.smartclaw/scripts/launchd-env-wrapper.sh \
    ${HOME}/.smartclaw/scripts/bq_coverage_watcher.py
echo "RC=$?"

# RC=2 -> auth bug (re-read Trap 1+2+3, fix the script)
# RC=3 -> IAM bug (run Step 2 of the debug recipe, grant the role)
# RC=0 -> fixed
```

The bq-coverage-watcher now returns 0 (RC=0) after both the script fix AND the `gcloud projects add-iam-policy-binding worldarchitecture-ai --member='serviceAccount:firebase-adminsdk-fbsvc@worldarchitecture-ai.iam.gserviceaccount.com' --role='roles/bigquery.jobUser'` grant.

### Trap 6 — Not every "BrokenPipe in oauth2 client" is a scope bug

The 2026-08-19 17:04 PT `wiki-campaign-daily-ingest` failure had the SAME chained symptom (`BrokenPipeError: [Errno 32] Broken pipe` → `urllib3.exceptions.ProtocolError` → `requests.exceptions.ConnectionError` → `google.auth.exceptions.TransportError`) on the SAME oauth2 line (`google/oauth2/_client.py:196`) at the SAME oauth2.googleapis.com/token endpoint. But the underlying library (Firebase Admin SDK's `firebase_admin.credentials.Certificate`) **already passes the correct scopes** (`cloud-platform + datastore + devstorage + firebase + identitytoolkit + userinfo.email`) on the SA JWT grant. Trap 1 (missing scopes) does NOT apply.

The actual cause was a **launchd-side network transient** — a 6-hour `pip install` bootstrap followed by the first cold TCP handshake to `oauth2.googleapis.com:443`, after which urllib3 retried 2× and gave up. The 30-second diagnostic (run interactively in `/bin/bash ~/.smartclaw/scripts/launchd-env-wrapper.sh`) succeeded first try with the same SA + same Python venv, confirming it was not a config bug.

**The trap:** the operator applies the Trap 1/2/3 fix (add `scopes=`, remove `os.environ.pop(...)`, etc.) when the script is already correct — wastes hours and may introduce bugs into working code.

**The fix — before applying Trap 1/2/3 fixes, run the diagnostic and check these:**

1. **Is the library already passing scopes?** Open the source of whatever library the script uses. For Firebase Admin SDK: `python3 -c "from firebase_admin import credentials; import inspect; print(inspect.getsource(credentials.Certificate))"` shows line 97 `service_account.Credentials.from_service_account_info(json_data, scopes=_scopes)`. If `_scopes` is populated (it is, as `cloud-platform + ...`), Trap 1 is not the bug.
2. **Does the script even call `google.auth.default()`?** Lots of GCP-touching scripts call higher-level libraries (Firebase Admin, `google-cloud-bigquery`, `google.cloud.storage`) that handle auth internally. A chained `BrokenPipeError` then is at the library's HTTP transport layer, not at any place you can change `default(scopes=...)`.
3. **Does the 30-second diagnostic succeed interactively?** Run it under `/bin/bash ~/.smartclaw/scripts/launchd-env-wrapper.sh` (NOT your interactive shell — the wrapper sources dotfiles in launchd order). If it succeeds (`OK project=<X> token_len=1024`), it is a transient network failure, not a config bug. Rerun the launchd job directly with `bash <wiki-campaign-daily-ingest.sh>` to confirm, then harden with retry.

**The hardening pattern for "the library is correct, the network is flaky":**

```python
import time

_TRANSIENT_EXC = (ConnectionError, TimeoutError)

def init_with_retry(init_fn, *, attempts: int = 3, label: str = "init"):
    last_exc = None
    for attempt in range(attempts):
        try:
            return init_fn()
        except _TRANSIENT_EXC as exc:
            last_exc = exc
            if attempt < attempts - 1:
                time.sleep(min(2 ** attempt, 8))
                continue
        except Exception as exc:
            root = exc.__cause__ or exc.__context__
            msg = str(exc)
            if root and root is not exc:
                msg = f"{exc} (chained: {type(root).__name__}: {root})"
            print(f"[WARN] {label} attempt {attempt+1}/{attempts} failed: {msg}")
            if attempt < attempts - 1:
                time.sleep(min(2 ** attempt, 8))
    assert last_exc is not None
    raise last_exc
```

**Tripwire — distinguish transient from config before applying any "fix":**

```bash
# 1. Run the 30-second diagnostic in the launchd-env wrapper
/bin/bash ${HOME}/.smartclaw/scripts/launchd-env-wrapper.sh \
    ${HOME}/worldarchitect.ai/.venv/bin/python -u -c "
import os; os.environ['GOOGLE_APPLICATION_CREDENTIALS']='${HOME}/serviceAccountKey.json'
import google.auth
from google.auth.transport.requests import Request
SCOPES = ('https://www.googleapis.com/auth/cloud-platform',)
creds, project = google.auth.default(scopes=SCOPES)
creds.refresh(Request())
print(f'OK project={project} token_len={len(creds.token)}')"

# 2. If that prints 'OK' — transient. Rerun the launchd task directly:
bash ${HOME}/.smartclaw/scripts/wiki-campaign-daily-ingest.sh

# 3. If that prints an error, replay Step 1 of the 4-step recipe above and check the chained cause.
```

The wiki-campaign-daily-ingest 2026-08-19 incident landed both `init_firebase()` retry with chained-cause surfacing and per-campaign `download_one` chained-cause surfacing in `~/.smartclaw/skills/download-campaign/scripts/download_campaign.py` (commit fd8fb85f4b). See `references/2026-08-19-wiki-campaign-transient-network.md` for the full transcript.

## The 30-second diagnostic script (canonical entry point)

When the alert fires, run this first — it bypasses urllib3 and prints the real OAuth error (or the 403 IAM issue) directly:

```bash
python3 ~/.smartclaw/skills/gcp-sa-auth-from-script/scripts/diagnose_gcp_sa_auth.py \
    --sa ${HOME}/serviceAccountKey.json \
    --scope https://www.googleapis.com/auth/cloud-platform \
    --test-api https://bigquery.googleapis.com/bigquery/v2/projects/worldarchitecture-ai/queries
```

Exit codes:
- `0` — token minted + API call succeeded. Auth path is healthy.
- `3` — `google.auth.default()` failed (scopes, env var, or walk-the-ADC-chain).
- `4` — `creds.refresh()` raised (`invalid_scope`, `invalid_grant`, etc.). Read the chained cause printed by the script.
- `5` — HTTP error from the API call. `403` means scope bug fixed; IAM role missing. `401` means SA deleted.

This script is the canonical replacement for the inline 4-step debug recipe below. Use it before reading the recipe.

## The 4-step debug recipe (verified 2026-08-19)

When ANY GCP-API script (launchd, cron, AO worker, manual) fails to auth, run these in order:

### Step 1 — Strip the misleading surface

The Slack alert says "SSL UNEXPECTED_EOF_WHILE_READING" or "Max retries exceeded" or "403". None of these are root causes. The first job is to bypass urllib3 and call google.auth directly:

```python
# Run this in the same Python env + same SA file the script uses
import os, sys
os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = "${HOME}/serviceAccountKey.json"
import google.auth
from google.auth.transport.requests import Request
SCOPES = ("https://www.googleapis.com/auth/cloud-platform",)
try:
    creds, project = google.auth.default(scopes=SCOPES)
    creds.refresh(Request())
    print(f"OK project={project} token_len={len(creds.token)}")
except Exception as exc:
    import traceback; traceback.print_exc()
    print(f"CHAINED cause={exc.__cause__!r}")
```

**Expected output if healthy:** `OK project=worldarchitecture-ai token_len=1024`. If you get the traceback, the actual root cause is in the deepest frame — usually `_client._handle_error_response` raising `RefreshError: invalid_scope`. Read the deepest frame, not the top.

### Step 2 — Verify the SA has the IAM role it needs

A 401/403 from the GCP API AFTER successful token mint is a permissions problem, not an auth problem. The token is valid; the SA just lacks `bigquery.jobs.create` (or whichever role). Verify:

```bash
gcloud projects get-iam-policy worldarchitecture-ai \
  --flatten="bindings[].members" \
  --format='table(bindings.role)' \
  --filter="bindings.members:serviceAccount:firebase-adminsdk-fbsvc@worldarchitecture-ai.iam.gserviceaccount.com"
```

If the role is missing, the fix is an IAM grant — NOT a code change. The 2026-08-19 incident had TWO compounding issues: (1) the script's auth call was missing scopes, AND (2) the SA had lost `bigquery.jobs.create` somewhere between 2026-08-18 16:30 UTC and 2026-08-19 16:52 UTC. Fixing only (1) would have surfaced (2) clearly; the chained-exception fix made the layering visible in the same reply.

### Step 3 — Verify env vars in launchd context

launchd does NOT source `~/.bashrc` on its own. Scripts run via launchd must wrap in `~/.smartclaw/scripts/launchd-env-wrapper.sh` (or equivalent) which sources `.bash_profile → .profile → .bashrc` and extracts critical vars via grep. Verify:

```bash
/bin/bash ${HOME}/.smartclaw/scripts/launchd-env-wrapper.sh /bin/bash -c 'echo "GOOGLE_APPLICATION_CREDENTIALS=$GOOGLE_APPLICATION_CREDENTIALS"'
```

If the env var is empty in the launchd context but populated in your interactive shell, the wrapper is not extracting it. Add to the `_extract_bashrc_var` function list in `launchd-env-wrapper.sh`:

```bash
_extract_bashrc_var GOOGLE_APPLICATION_CREDENTIALS
_extract_bashrc_var WORLDARCH_SERVICE_ACCOUNT_KEY
```

The wrapper's existing grep-based extraction already handles vars defined LATE in `.bashrc` (after the interactive-only guard at line ~1615) by grepping the file directly. This was the case in the 2026-08-19 incident — `GOOGLE_APPLICATION_CREDENTIALS` is exported at `.bashrc:854`, BEFORE the guard, so the env var SHOULD propagate; the issue was the script popping it.

### Step 4 — Reproduce end-to-end with the same env the cron/launchd job sees

```bash
/bin/bash ${HOME}/.smartclaw/scripts/launchd-env-wrapper.sh \
    ${HOME}/.local/orch-venv/bin/python3 -u \
    ${HOME}/.smartclaw/scripts/your_script.py
```

This is the only way to reproduce the launchd-time env exactly. Interactive shells inherit vars differently; the wrapper sources the same dotfiles in the same order launchd would.

## Canonical scopes-per-API table

When the script talks to multiple GCP APIs, choose the narrowest scope that covers all of them:

| GCP API | OAuth scope (URL form) | Notes |
|---|---|---|
| BigQuery (queries, jobs, table reads) | `https://www.googleapis.com/auth/cloud-platform` | BQ does NOT have a narrower scope — use cloud-platform |
| Cloud Storage (buckets, objects) | `https://www.googleapis.com/auth/cloud-platform` | GCS has `devstorage.read_write` etc., but cloud-platform works for everything |
| Cloud Logging (read/write logs) | `https://www.googleapis.com/auth/cloud-platform` | Same as above |
| Secret Manager | `https://www.googleapis.com/auth/cloud-platform` | Same |
| Compute Engine | `https://www.googleapis.com/auth/cloud-platform` | Same |
| Pub/Sub | `https://www.googleapis.com/auth/cloud-platform` | Same |
| Firebase Admin SDK (Firestore, Auth) | `https://www.googleapis.com/auth/cloud-platform` | Firebase Admin SDK uses a different auth path (OAuth2 refresh token) — see `wa-prod-data-query` |
| Cloud Run admin (deploy/revisions) | `https://www.googleapis.com/auth/cloud-platform` | Same |
| Service Usage / Billing | `https://www.googleapis.com/auth/cloud-platform` | Same |

**Default to `cloud-platform` unless you have a specific reason not to.** The narrower scopes (`devstorage.read_only`, `logging.read`, etc.) work for single-API scripts but rarely save anything in practice — the token size is dominated by the JWT signature, not the scope claim.

## The pinned patterns (canonical, copy-paste)

### Pattern A — Service-account JSON, run-anywhere script

```python
import os
import google.auth
from google.auth.transport.requests import Request

# Honor $GOOGLE_APPLICATION_CREDENTIALS; do NOT pop it.
SCOPES = ("https://www.googleapis.com/auth/cloud-platform",)


def get_bq_token() -> str:
    creds, _ = google.auth.default(scopes=SCOPES)
    if not creds.valid:
        creds.refresh(Request())
    return creds.token
```

### Pattern B — Same, with retry on transient urllib errors (for BQ, GCS, Logging APIs)

```python
import time
from google.auth import exceptions as google_auth_exceptions

# Transient = safe to retry. Non-transient (invalid_scope, invalid_grant) = surface immediately.
_TRANSIENT = (
    google_auth_exceptions.TransportError,
    ConnectionError,
    TimeoutError,
)


def get_bq_token_with_retry(max_attempts: int = 4) -> str:
    last_exc: BaseException | None = None
    for attempt in range(max_attempts):
        try:
            return get_bq_token()
        except google_auth_exceptions.RefreshError as exc:
            msg = str(exc)
            if any(s in msg for s in ("invalid_scope", "invalid_grant", "invalid_request")):
                raise  # non-transient: surface immediately
            last_exc = exc
            if attempt < max_attempts - 1:
                time.sleep(min(2 ** attempt, 8))
        except _TRANSIENT as exc:
            last_exc = exc
            if attempt < max_attempts - 1:
                time.sleep(min(2 ** attempt, 8))
    assert last_exc is not None
    raise last_exc
```

### Pattern C — Surface chained exceptions in Slack alerts

```python
try:
    token = get_bq_token_with_retry()
except Exception as exc:
    root = exc.__cause__ or exc.__context__
    msg = str(exc)
    if root and root is not exc:
        msg = f"{exc} (chained: {type(root).__name__}: {root})"
    _slack_post(channel, f":rotating_light: failed to auth: `{msg}` {investigator}")
    return 2
```

## Pitfalls (verified, all true as of 2026-08-19)

- **Do NOT call `google.auth.default()` without `scopes=`** — the resulting JWT has no `scope` claim and is rejected with `invalid_scope`. This is the #1 cause of misleading "SSL error" alerts.
- **Do NOT `os.environ.pop("GOOGLE_APPLICATION_CREDENTIALS")`** — it strips the env var so `default()` falls through to ADC user creds, which often have a different (or no) service-account scope. The env var exists precisely so the script knows which SA to use; don't preempt it.
- **Do NOT trust the Slack alert body without unwrapping the chained exception** — `f"{exc}"` only shows the outermost frame. The OAuth root cause is often 2-3 frames deeper.
- **Do NOT use a narrower scope without verifying the API accepts it** — e.g. `https://www.googleapis.com/auth/bigquery` is NOT a valid scope URL (BQ shares the cloud-platform scope). When in doubt, use `cloud-platform`.
- **Do NOT retry `invalid_scope` / `invalid_grant`** — these are NOT transient. Retrying 4× with exponential backoff is wasted time and obscures the real cause. The retry-pattern above explicitly skips retry for these strings.
- **Do NOT assume the launchd-time env matches your interactive shell** — `~/.bashrc` has interactive guards that may skip late exports. Use the wrapper + reproduce step from Step 4.
- **Do NOT call `cred.refresh(Request())` multiple times in a row** — `cred.valid` will be True after the first refresh; the second call returns immediately. Cache the token.
- **Do NOT paste raw error strings into issue bodies without checking for chained exceptions** — the same applies to gcloud CLI output (`gcloud auth print-access-token` errors chain the same way).

## Tests

```bash
cd ~/.smartclaw
python3 -m pytest scripts/tests/test_bq_coverage_watcher.py -v
```

The bq_coverage_watcher test suite pins:
- `test_oauth_token_requires_cloud_platform_scope` — ensures `google.auth.default(scopes=[cloud-platform])` is always called.
- `test_auth_failure_message_includes_chained_cause` — ensures the alert body surfaces both the OAuth error AND the chained SSL cause.

These two tests are the regression-guard against re-introducing Trap 1 / Trap 3 in any watcher or cron script that uses the same pattern. Copy them when authoring new GCP-auth scripts.

## Worked example — the 2026-08-19 bq-coverage-watcher incident

`references/2026-08-19-bq-coverage-watcher-auth-failure.md` captures the full transcript:
- The misleading Slack alert body (`SSL UNEXPECTED_EOF_WHILE_READING`) that buried the real `invalid_scope` root cause.
- The two compounding script bugs (no `scopes=` + `os.environ.pop(...)`).
- The two separate IAM issue that surfaced AFTER the auth fix (`bigquery.jobs.create` revoked).
- The diff that landed: remove `pop`, add `_BQ_SCOPES`, add `_bq_token_with_retry`, add chained-cause alert format, add 2 regression tests.
- The 13/13 pytest run.

## Worked example — the 2026-08-19 wiki-campaign-daily-ingest incident (Trap 6)

`references/2026-08-19-wiki-campaign-transient-network.md` captures the duplicate-class incident that looked identical but was a launchd-side transient, not a scope bug:
- The chained `BrokenPipeError` at `google/oauth2/_client.py:196` (same line as bq-coverage-watcher).
- The library (Firebase Admin SDK) ALREADY passes `scopes=_scopes` internally — Trap 1 is NOT the bug class.
- The 6-hour `pip install` bootstrap → cold TCP → first-handshake transient.
- The 30-second diagnostic ran green first try under the launchd-env wrapper, proving no config bug.
- The durable fix: 3-attempt exponential-backoff retry on `_TRANSIENT_EXC` in `init_firebase()`, plus chained-cause surfacing on per-campaign `download_one` exceptions.
- Commit fd8fb85f4b on `jleechanorg/jleechanbrain` (pushed 2026-08-19 17:09 PT).

## Related skills — load order

1. `hermes-health-check` — when the launchd job is failing for reasons unrelated to GCP auth (Python venv, missing script, wrong wrapper).
2. `cron-jobs-and-messaging-credentials` — when the launchd job has the right GCP creds but is missing Slack/Discord/etc. tokens (different env-stripping path).
3. `wa-cloud-logging-diag` — when the GCP-API call SUCCEEDS but the returned data is unexpected (the data-class question, not the auth-class question).