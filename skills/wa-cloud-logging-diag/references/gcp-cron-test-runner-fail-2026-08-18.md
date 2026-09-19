# GCP cron test-runner failure — 3-day silent loop, 2026-08-16/17/18

The "Daily Level Up Test FAIL" email arrived THREE consecutive days in a row with the same stack trace. The user only noticed on day 3 when the Gmail thread piled up. This is the second observation of Failure Mode #2 (`git rev-parse HEAD … exit 128`) — the 2026-08-13 reference (`gcp-cron-test-runner-fail-2026-08-13.md`) captured the first. This reference captures the new wrinkle: the SAME bug can recur for 3 days without any automatic alarm because the failure mode is invisible to every signal channel except Gmail.

## The 3-day timeline (real data, all from the same root cause)

| Date | Execution | `summary.json` | `test_output.log` last line | Cloud Run container exit |
|---|---|---|---|---|
| 2026-08-16 | `wa-daily-level-up-test-lrdwt` | `exit_code: 1, status: FAIL`, **no scenarios** | `subprocess.CalledProcessError: ... 'git', 'rev-parse', 'HEAD' ... exit status 128` | 0 |
| 2026-08-17 | `wa-daily-level-up-test-j7ccn` | `exit_code: 1, status: FAIL`, **no scenarios** | same stack trace | 0 |
| 2026-08-18 | `wa-daily-level-up-test-w2z9l` | `exit_code: 1, status: FAIL`, **no scenarios** | same stack trace | 0 |

The recurring stack trace on each day (from `gsutil cat gs://wa-test-evidence/daily/<date>/test_output.log`):

```
Firebase initialized successfully in world_logic.py
fatal: not a git repository (or any of the parent directories): .git
Traceback (most recent call last):
  File "/app/testing_mcp/core/test_level_up_organic.py", line 5441, in <module>
    _configure_exact_head_python_runtime()
  File "/app/testing_mcp/core/test_level_up_organic.py", line 5400, in _configure_exact_head_python_runtime
    head_sha = subprocess.check_output(
               ^^^^^^^^^^^^^^^^^^^^^^^^
  File "/usr/local/lib/python3.11/subprocess.py", line 466, in check_output
    return run(*popenargs, stdout=PIPE, timeout=timeout, check=True,
  File "/usr/local/lib/python3.11/subprocess.py", line 571, in run
    raise CalledProcessError(retcode, process.args,
subprocess.CalledProcessError: Command '['git', 'rev-parse', 'HEAD']' returned non-zero exit status 128.
```

The container exit code is 0 every time — the entrypoint's `set -uo pipefail` (no `set -e`) + `_send_email_on_exit` trap catches the crash and falls through to the email path. From Cloud Scheduler's perspective, the cron is "green" every day. The Slack side-channel is ALSO dead (`Slack chat.postMessage returned status=200 body={'ok': False, 'error': 'invalid_auth'}` per the Cloud Run log). The only signal channel that works is Gmail.

## What the 2026-08-13 reference missed

The 2026-08-13 reference documents the bug class and the fix recipe (the Dockerfile `COPY .git/HEAD` line). It does NOT document the recurrence pattern — the 3-day loop went undetected for 3 days because nobody ran the recurrence sweep. The skill's "is this the same bug?" guardrail table has a row for the bug class but no row for "this bug has been failing for N days."

The skill's fix-recipe continues to be:
- `testing_mcp/infra/Dockerfile.test-runner` → add `COPY .git/HEAD ./.git/HEAD` + `COPY .git/refs/ ./.git/refs/`
- `testing_mcp/core/test_level_up_organic.py::_configure_exact_head_python_runtime` → wrap the `subprocess.check_output(["git", "rev-parse", "HEAD"])` in try/except, fall back to `GIT_COMMIT` env var
- New regression test: `testing_mcp/tests/test_dockerfile_has_git_refs.py` asserts the Dockerfile contains the COPY lines

The 2026-08-18 case adds three new wrinkles to that recipe:

### 1. The PR #7873 contract gap (the root cause of the 3-day silent loop)

PR #7873 split the cron exit semantics:
- Test/audit assertion failure → container exit 0 (cron stays green in Cloud Scheduler)
- Infra failure (OOM, signal kill, GCS upload fail, `CRON_INFRA_FAIL=1`) → container exit 1 (alert fires, email subject `[INFRA] FAIL` with yellow banner)

A **test crash** (Python `subprocess.CalledProcessError` at module-import time) is currently **NEITHER** category. The bash exit code from the `subprocess.CalledProcessError` propagates via `set -uo pipefail` (no `set -e`) → the trap fires → container exits 0 → cron "green." The result is silent failure: Cloud Scheduler is happy, the Slack alert pipeline is happy (because no alert fires), the only signal is the FAIL email in Gmail.

The 2026-08-13 reference noted this as a "subtle ambiguity" but didn't pin it as a concrete follow-up. The 2026-08-18 case proves the gap is real and silent: the same bug recurred for 3 days before the user noticed.

**Contract fix (recommended, not yet shipped):** classify test crashes as `[INFRA]` so the cron exits 1 and the Slack side-channel alerts. Implementation: in `entrypoint.sh`, when the Python entrypoint exits with a non-test exit code (e.g. `subprocess.CalledProcessError`, `ModuleNotFoundError`, `RuntimeError`), set `CRON_INFRA_FAIL=1` before the trap fires. Until that ships, the only reliable signal for pre-test crashes is the email itself + the GCS evidence.

### 2. The `.git` worktree trap (the bug-in-the-fix)

The canonical fix recipe is `COPY .git/HEAD ./.git/HEAD` + `COPY .git/refs/ ./.git/refs/`. This works on a regular `git checkout` where `.git/` is a directory. It does NOT work on a `git worktree` checkout — because the worktree's `.git` is a FILE, not a directory:

```
$ cd /tmp/wa-worktrees/wt-test  # a fresh worktree from origin/main
$ cat .git
gitdir: ${HOME}/projects/worldarchitect.ai/.git/worktrees/wt-test
$ ls .git/HEAD
ls: .git/HEAD: Not a directory
```

`COPY .git/HEAD ./.git/HEAD` from such a checkout fails at Docker build time with `ERROR: lstat .git/HEAD: not a directory`. The worker that picked up the 2026-08-18 dispatch would have hit this trap if it tried to build the image directly from the worktree — instead of the canonical pattern (build from the main repo's regular checkout, OR copy from the main repo's `.git/` in a build-time RUN).

The cleanest fix that works in BOTH worktree and regular builds is **Option C: skip the `.git/` COPY entirely** and rely solely on the `GIT_COMMIT` env-var fallback in `_configure_exact_head_python_runtime()`. That makes the Dockerfile simpler AND avoids the worktree trap. Verify the env-var path gets used by setting `GIT_COMMIT` in `deploy_daily_test.sh` as a build arg:

```bash
# In deploy_daily_test.sh, near the docker build / gcloud run jobs update step
GIT_COMMIT=$(git rev-parse HEAD)
gcloud run jobs update wa-daily-level-up-test \
  --update-env-vars="GIT_COMMIT=${GIT_COMMIT}" \
  --region=us-central1 --project=worldarchitecture-ai
```

### 3. The post-fix verification gate (the "fix didn't actually deploy" check)

After the Dockerfile/PR merge, the cron at 07:00 PT the day after the deploy must show BOTH:
- `test_output.log` contains `=== Test Complete ===`
- `summary.json` contains at least one scenario entry with `passed: true|false`

If the new summary.json still has `exit_code: 1` with no scenarios, the Dockerfile fix did NOT actually deploy. The 3-day loop is the canonical evidence: the fix was filed on 2026-08-13, the PR was discussed, but the image never got the new COPY lines. The recurrence-check one-liner in Step 0 of the recipe would have caught this on day 1 instead of day 3.

```bash
# Post-fix verification: cron at 07:00 PT the day after the deploy
gsutil cat gs://wa-test-evidence/daily/2026-08-19/summary.json
# Healthy: {"status": "PASS", "exit_code": 0, "scenarios": [{"name": "finish_intent_prompt_and_classifier", "passed": true, ...}, ...]}
# Fix didn't deploy: {"status": "FAIL", "exit_code": 1, "scenarios": []}  ← same as today, no scenarios
```

If the post-fix summary is STILL the no-scenarios shape, the deployment didn't include the fix. Reasons to check (in order):
1. Cloud Build cache drift — old image layer with no `.git/` was reused. Fix: add `--no-cache` to the `docker build` step in `deploy_daily_test.sh`, OR refactor the Dockerfile to force a layer rebuild on PR-key changes.
2. The `.git` worktree trap (above) — the COPY lines never made it into the shipped image. Fix: switch to Option C / env-var fallback.
3. The Cloud Run Job's `image` field wasn't updated to the new digest. Fix: verify `gcloud run jobs describe wa-daily-level-up-test --format='value(spec.template.spec.template.spec.containers[0].image)'` shows the new digest.

## The recurrence-check one-liner (recommended for the next agent)

When the user reports "the daily level up test is failing" (or when you see the FAIL email), DO THIS FIRST before running the full diagnostic chain:

```bash
echo "=== last 14 days of wa-daily-level-up-test status ==="
for d in $(seq -f "%Y-%m-%d" -14 -1 "$(date -u +%Y-%m-%d)"); do
  s=$(gsutil cat "gs://wa-test-evidence/daily/$d/summary.json" 2>/dev/null \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print(f"{d.get(\"status\",\"?\")} exit={d.get(\"exit_code\",\"?\")}")' 2>/dev/null)
  printf "%s  %s\n" "$d" "${s:-MISSING}"
done
```

Output shape on the 2026-08-18 case:

```
2026-08-05  status=PASS exit=0
2026-08-06  status=PASS exit=0
2026-08-07  status=PASS exit=0
2026-08-08  status=PASS exit=0
2026-08-09  status=PASS exit=0
2026-08-10  status=PASS exit=0
2026-08-11  status=PASS exit=0
2026-08-12  status=PASS exit=0
2026-08-13  status=PASS exit=0
2026-08-14  status=PASS exit=0
2026-08-15  status=PASS exit=0
2026-08-16  status=FAIL exit=1    ← bug started here
2026-08-17  status=FAIL exit=1    ← still failing
2026-08-18  status=FAIL exit=1    ← current
```

The 3-day FAIL run is the immediate "this has been ignored for 3 days" signal. It should trigger a high-priority bead + a claudem dispatch (NOT a slack-only "investigate" reply), because the recipe has been known since 2026-08-13.

## The durable fix protocol (lessons from 2026-08-18, refine the 2026-08-13 protocol)

1. **First, RECOGNIZE the 3-day loop.** The recurrence-check one-liner in Step 0 of the recipe is the canonical detection. If it returns 3+ consecutive FAIL, you have a "nobody fixed it" signal, not a fresh diagnostic.
2. **The fix is `Option C: env-var fallback only`**, not the COPY-the-git-directory fix. OPTION C IS THE RECOMMENDED CANONICAL PATH because (a) it works on worktree builds, (b) it doesn't require the `.git/` ref to be bytes-stable across deploys, (c) it's verifiable from the container env alone, and (d) it's a smaller Dockerfile diff. The COPY-the-`.git/` recipe is the secondary path — only use it if the env-var fallback fails for some reason.
3. **The PR #7873 contract gap is the real production bug.** Test crashes should not be silent. File a follow-up bead to add `CRON_INFRA_FAIL=1` for the test-crash path in `entrypoint.sh`.
4. **The Slack side-channel dead-on-arrival is a separate maintenance failure.** The `OPENCLAW_SLACK_BOT_TOKEN` was rotated upstream and the GCP secret was never updated. File a separate follow-up bead to rotate the secret.
5. **The dice audit cron is ALSO failing** (the same 3 days, but for a different reason — chi-square + unparseable notation in 2 campaigns). The level-up Dockerfile fix does NOT fix the dice cron. File a separate bead (already filed: `rev-svwob` for the level-up fix; the dice issue needs a separate bead).

## The cron-internal evidence for the 2026-08-18 case (full transcript)

From `gcloud logging read 'resource.type="cloud_run_job" AND resource.labels.job_name="wa-daily-level-up-test"' --limit=30 --format='value(timestamp,severity,textPayload)' --freshness=7d`:

```
2026-08-18T11:19:30.361567Z  INFO
2026-08-18T11:19:29.897332Z  NOTICE
2026-08-18T07:03:29.259835Z  INFO
2026-08-18T07:03:21.397033Z  INFO  Container called exit(0).
2026-08-18T07:03:21.362864Z       Done.
2026-08-18T07:03:21.362855Z       Slack chat.postMessage returned status=200 body={'ok': False, 'error': 'invalid_auth'}
2026-08-18T07:03:21.218291Z       Email report sent successfully!
2026-08-18T07:03:19.533727Z       Sending email to jleechan@gmail.com...
2026-08-18T07:03:19.386526Z       Logging in as jleechan@gmail.com...
2026-08-18T07:03:19.332783Z       Connecting to smtp.gmail.com:587...
2026-08-18T07:03:19.331509Z       === Sending Daily Test Email Report ===
2026-08-18T07:03:19.243334Z       >>> [trap] Sending email report (exit_code=1 infra_fail=0) ...
2026-08-18T07:03:19.243196Z       Cron exit code: 0 (test=1 infra_fail=0)
2026-08-18T07:03:19.243190Z       Evidence: gs://wa-test-evidence/daily/2026-08-18
2026-08-18T07:03:19.243180Z       Status: FAIL
2026-08-18T07:03:19.242603Z       === Test Complete ===
2026-08-18T07:03:19.216271Z       GCS upload completed successfully!
2026-08-18T07:03:19.157073Z       Directory uploaded to GCS successfully!
2026-08-18T07:03:18.999848Z       Uploading /tmp/evidence/daily-scheduled-2026-08-18/summary.json to gs://wa-test-evidence/daily/2026-08-18/summary.json ...
2026-08-18T07:03:18.873797Z       Uploading /tmp/evidence/daily-scheduled-2026-08-18/rss_watchdog.log to gs://wa-test-evidence/daily/2026-08-18/rss_watchdog.log ...
2026-08-18T07:03:18.873780Z       Uploading /tmp/evidence/daily-scheduled-2026-08-18/test_output.log to gs://wa-test-evidence/daily/2026-08-18/test_output.log ...
2026-08-18T07:03:18.461151Z       >>> Uploading evidence to gs://wa-test-evidence/daily/2026-08-18 ...
2026-08-18T07:03:18.435739Z       WARNING: Evidence root /tmp/worldarchitect.ai does not exist; no test artifacts to collect
2026-08-18T07:03:18.435539Z       >>> Test exit code: 1
2026-08-18T07:03:18.061310Z  ERROR  Traceback (most recent call last):
                                       File "/app/testing_mcp/core/test_level_up_organic.py", line 5441, in <module>
                                           _configure_exact_head_python_runtime()
                                       File "/app/testing_mcp/core/test_level_up_organic.py", line 5400, in _configure_exact_head_python_runtime
                                           head_sha = subprocess.check_output(
                                       ...
                                       subprocess.CalledProcessError: Command '['git', 'rev-parse', 'HEAD']' returned non-zero exit status 128.
2026-08-18T07:03:18.056973Z       fatal: not a git repository (or any of the parent directories): .git
2026-08-18T07:03:15.602309Z       2026-08-18 07:03:15,601 - root - INFO - Firebase initialized successfully in world_logic.py
2026-08-18T07:03:15.559862Z       2026-08-18 07:03:15,559 - root - INFO - Successfully loaded service account credentials
2026-08-18T07:03:15.559580Z       2026-08-18 07:03:15,558 - root - INFO - ✅ Successfully loaded credentials from file: /secrets/serviceAccountKey.json
```

Three things to note in this transcript:

1. **`Cron exit code: 0 (test=1 infra_fail=0)`** — the bash trap fires after the test crash, the `subprocess.CalledProcessError` propagates as test exit 1, but `infra_fail=0` because the entrypoint doesn't classify test crashes as infra. The container exits 0. Cloud Scheduler is "green." **This is the PR #7873 contract gap.**
2. **`Slack chat.postMessage returned status=200 body={'ok': False, 'error': 'invalid_auth'}`** — the Slack side-channel is dead. The cron has been unable to ping #worldai for an unknown duration. **This is the silent side-channel failure.**
3. **`Email report sent successfully!`** — the Gmail path works. The user gets the email. **This is the only signal that works.**

## Source pointers

- `testing_mcp/core/test_level_up_organic.py:5400` — `_configure_exact_head_python_runtime()` (the guard)
- `testing_mcp/infra/Dockerfile.test-runner` line 11-13 — `git` install, no `.git/` COPY
- `testing_mcp/infra/entrypoint.sh` — `set -uo pipefail` (no `set -e`), the `_send_email_on_exit` trap, the `infra_fail` translation
- `testing_mcp/infra/deploy_daily_test.sh:356-368` — the env-vars + secrets wired on `gcloud run jobs create`
- Slack thread `C0AH3RY3DK6 / 1787102899.025729` — the 2026-08-18 dispatch
- Bead `rev-svwob` — the fix recipe (filed 2026-08-18)
- Skill recipe: `wa-cloud-logging-diag` SKILL.md § "The 3-day silent-loop trap" pitfall
- Prior sibling: `references/gcp-cron-test-runner-fail-2026-08-13.md` (the first observation of the same bug)
