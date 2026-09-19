# GCP cron test-runner failure — worked example, 2026-08-13

The "Daily Level Up Test FAIL" email arrived at `2026-08-13 00:02 PT` with subject `[GCP Cron] Daily Level Up Test - FAIL (daily-scheduled-2026-08-13)`. Cloud Run Job execution `wa-daily-level-up-test-mr6dk`. Two distinct failures, both blocking. This is the full transcript that produced the durable fix protocol reply on the Slack thread `C0BDEAJH8PK / 1786605287.481999`.

## The failure mode (root cause #1 — primary block)

The test crashed **before any scenario ran**. The `_configure_exact_head_python_runtime()` guard at `testing_mcp/core/test_level_up_organic.py:5348` runs `git rev-parse HEAD` to write a per-SHA `PYTHONPYCACHEPREFIX` and crashes immediately:

```
Firebase initialized successfully in world_logic.py
fatal: not a git repository (or any of the parent directories): .git
Traceback (most recent call last):
  File "/app/testing_mcp/core/test_level_up_organic.py", line 5399, in <module>
    _configure_exact_head_python_runtime()
  File "/app/testing_mcp/core/test_level_up_organic.py", line 5358, in _configure_exact_head_python_runtime
    head_sha = subprocess.check_output(
subprocess.CalledProcessError: Command '['git', 'rev-parse', 'HEAD']' returned non-zero exit status 128.
```

The Dockerfile.test-runner installs `git` (line 12) but never `COPY .git ./.git`. The guard works on dev laptops and CI (real checkouts) but not on Cloud Run Jobs built from source.

## The failure mode (root cause #2 — Slack side-channel dead)

Cloud Run logs at `2026-08-13T07:02:43.573973Z`:
```
Slack chat.postMessage returned status=200 body={'ok': False, 'error': 'invalid_auth'}
2026-08-13T07:02:43.644525Z  Container called exit(0).
```

The `OPENCLAW_SLACK_BOT_TOKEN` env var + the `openclaw-slack-bot-token` secret binding are both correctly wired on the live job (verified via `gcloud run jobs describe`). Slack API rejects the token, so the alert pipeline (which is the only Slack alert for this failure) is silent. The email path works.

## The diagnostic chain (the 4-layer recipe, applied)

```bash
# Step 1 — GCS evidence (read BEFORE Cloud Logging; cheaper, faster)
gsutil cat gs://wa-test-evidence/daily/2026-08-13/summary.json
# {"date": "2026-08-13", "target_server": "https://mvp-site-app-dev-i6xf2p72ka-uc.a.run.app", "test_name": "test_level_up_organic", "scenario": "all", "exit_code": 1, "status": "FAIL", "gcs_path": "gs://wa-test-evidence/daily/2026-08-13"}
gsutil cat gs://wa-test-evidence/daily/2026-08-13/test_output.log | tail -30
# (last 5 lines = the git stack trace above)

# Step 2 — Cloud Run Job logs (latest 5, freshest 2d)
gcloud logging read \
  'resource.type="cloud_run_job" AND resource.labels.job_name="wa-daily-level-up-test"' \
  --project=worldarchitecture-ai --limit=5 \
  --format='value(timestamp,severity,textPayload)' --freshness=2d
# 2026-08-13T07:02:55.987089Z  INFO
# 2026-08-13T07:02:43.644525Z  INFO  Container called exit(0).
# 2026-08-13T07:02:43.574005Z       Slack chat.postMessage returned status=200 body={'ok': False, 'error': 'invalid_auth'}
# 2026-08-13T07:02:43.573973Z       Done.
# 2026-08-13T07:02:43.442484Z       Email report sent successfully!

# Step 3 — Live job spec (env + volumes)
gcloud run jobs describe wa-daily-level-up-test \
  --project=worldarchitecture-ai --region=us-central1 \
  --format='value(spec.template.spec.template.spec.containers[0].env)' \
  | tr ',' '\n' | grep -iE 'slack|token|channel'
# {'name': 'OPENCLAW_SLACK_BOT_TOKEN' ... {'name': 'openclaw-slack-bot-token'}}
# {'name': 'SLACK_INVESTIGATOR_USER_ID' ... 'U0AEZC7RX1Q'}
# {'name': 'SLACK_CHANNEL_ID' ... 'C0BCVG4F560'}
# ↳ env wired correctly. Bug is the token itself, not the spec.

# Step 4 — Dockerfile grep for the exact-HEAD guard's missing artifact
grep -n "COPY" testing_mcp/infra/Dockerfile.test-runner
# COPY mvp_site/ ./mvp_site/
# COPY testing_mcp/ ./testing_mcp/
# COPY testing_utils/ ./testing_utils/
# COPY infrastructure/ ./infrastructure/
# COPY testing_mcp/infra/entrypoint.sh ./entrypoint.sh
# ↳ NO `COPY .git` anywhere. The runtime image is git-binary-only, no repo.
```

## The PR #7873 context (why Cloud Run exit=0 even though the test failed)

The Cloud Run Job container exited 0 because PR #7873 split the exit semantics:
- **Test/audit assertion failure** (exit 1 from the test, but no infra issue) → container exit 0 (cron stays green in Cloud Scheduler)
- **Infra failure** (OOM 137, Python crash 134, signal kill 139, GCS upload fail, `CRON_INFRA_FAIL=1`) → container exit 1 (alert fires, email subject becomes `[INFRA] FAIL` with yellow banner)

Today's failure is a *test crash*, which is technically neither a clean assertion failure nor a true infra failure — the test couldn't even start. The exit code path landed at 0 because the bash exit code propagated from the Python `subprocess.CalledProcessError` via `set -uo pipefail` (no `set -e`), so the trap fired and the email went out, but the container exit was 0. This is a subtle ambiguity in the PR #7873 contract: a test crash should arguably be `[INFRA]` (the test runner can't run, not a data problem).

## The durable fix protocol (posted to Slack thread `C0BDEAJH8PK / 1786605287.481999`)

### Short-term fix (today)

Option A (recommended): Rebuild + redeploy with the Dockerfile COPY fix.
Option B (fast bypass): Add `GIT_COMMIT_OVERRIDE=<current main HEAD>` env var to the Cloud Run Job, and make `_configure_exact_head_python_runtime()` fall back to that env var when `.git/` is absent.

### Long-term fix

Two coordinated PRs on a fresh worktree from `origin/main`:
1. `fix(cron): ship .git HEAD ref so exact-HEAD guard runs in Cloud Run` — `Dockerfile.test-runner` `COPY .git/HEAD ./.git/HEAD` + `COPY .git/refs/heads/ ./<branch>/.git/refs/heads/`, plus the env-var fallback in the guard for graceful degradation.
2. `fix(cron): refresh OPENCLAW_SLACK_BOT_TOKEN secret` — paste a fresh xoxb token into the `openclaw-slack-bot-token` GCP secret, then `gcloud run jobs update wa-daily-level-up-test --update-secrets=OPENCLAW_SLACK_BOT_TOKEN=openclaw-slack-bot-token:latest`.

A test file `testing_mcp/test_dockerfile_includes_git_ref.py` should be added to assert the built image contains `/app/.git/HEAD`, so a future Dockerfile change can't reintroduce the crash.

## The follow-up cron (created during this session)

`hermes cron job_id: fb870a6e9023` — fires at +20m, posts to `C0BDEAJH8PK / 1786605287.481999` thread, checks whether the Dockerfile PR has been opened, whether the Slack secret version is fresh, and whether the 2026-08-14 cron was green. Self-cancels when done.

## The "is this the same bug?" guardrail

If the next "Daily Level Up Test FAIL" email arrives, run steps 1-4 of the diagnostic chain first. The output shape will tell you which of the three known failure modes it is:

| Stack trace keyword | Failure mode | Fix surface |
|---|---|---|
| `git rev-parse HEAD ... returned non-zero exit status 128` | Pre-test runtime crash (missing `.git/`) | Dockerfile COPY fix |
| `level_up_available` / `rewards_box` in `test_level_up_organic.py` | 5/8 PASS assertion (canonical bug) | PR #8290 lineage |
| `Slack chat.postMessage returned ... 'invalid_auth'` | Slack side-channel dead | Token rotation |
| `malformed or missing done payload` / `stream_parser` | Streaming tolerance failure | Stream parser test fix |
| `Slack webhook 404` / `SLACK_WEBHOOK_URL not set` | Webhook fallback path dead | Webhook URL re-bind |

If the stack trace doesn't match any of the above, fall back to the wider `wa-cloud-run-deploy-failure-debug` recipe (when that skill lands) and grep for the OOM/CRON_INFRA_FAIL=1 indicators in Cloud Run logs.

## Source pointers

- `testing_mcp/core/test_level_up_organic.py:5348` — `_configure_exact_head_python_runtime()` (the guard with the missing `.git/`)
- `testing_mcp/infra/Dockerfile.test-runner` line 11-13 — `git` install, no `.git/` COPY
- `testing_mcp/infra/entrypoint.sh` — `set -uo pipefail` (no `set -e`), the `_send_email_on_exit` trap, the INFRA_FAIL translation
- `testing_mcp/infra/send_report_email.py:270-368` — `send_slack_notification()` (the bot-token path that returned `invalid_auth`)
- `testing_mcp/infra/deploy_daily_test.sh:356-368` — the env-vars + secrets wired on `gcloud run jobs create`
- Slack thread `C0BDEAJH8PK / 1786605287.481999` — the Durable Fix Protocol reply
- Prior sibling investigations: sessions `20260627_035218_f0cdaab3`, `20260613_103920_b47501dd`, `20260623_222931_99b4df`, `20260709_124855_35ec6e10`
