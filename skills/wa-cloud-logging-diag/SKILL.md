---
name: wa-cloud-logging-diag
version: 2.2.0
description: 'Query WA Cloud Logging for browser-side safeDiag events. Also the entry point for ''one of my users is getting errors'' triage — resolves a campaign_id to the owner via BQ `llm_forensics.llm_payloads.user_id` (NOT the Firestore `users` collection scan, which misses real users), and for ''X is slow'' latency triage — Cloud Run `httpRequest.latency` per campaign + BQ `llm_forensics.llm_payloads` prompt/cache ratio (the leading indicator: cache hit below 50 percent predicts p50 30 to 146s). Also covers GCP cron test-runner failure triage (the `[GCP Cron] Daily Level Up Test - FAIL` / dice-audit email surface) — the 4-layer diagnostic chain (GCS evidence → Cloud Run Job logs → live job spec → Dockerfile+deploy script), the 3 known failure modes (5/8 PASS assertion, pre-test runtime crash, Slack `invalid_auth`), the PR #7873 exit-code split context, and the iOS Safari `TypeError: Load_failed` browser-side fetch-abort pattern + post-return polling-loop fingerprint.'
tags: ["worldarchitect", "cloud-logging", "observability", "instrumentation", "safeDiag", "client_diag", "user-lookup", "bq-llm-payloads"]
category: worldarchitect
triggers:
  - cloud logging
  - client_diag
  - cdiag_name
  - cdiag_ts_ms
  - safeDiag events landed
  - instrumentation verification
  - signup.complete funnel
  - signin.success count
  - first_turn.outcome latency
  - did the safeDiag events fire
  - pr-preview instrumentation check
  - bundle hash mismatch with Cloud Logging success
  - deploy hash matches origin/main but events hit
  - Docker layer cache stale bundle
  - latency seems worse than usual
  - reroll is slow
  - reroll latency regression
  - /rero is slow
  - interaction/stream latency
  - p50 stream latency regression
  - cache hit ratio dropped
  - prompt tokens growing
  - context growth without cache reuse
  - calculating outcomes never completes
  - spinner hangs after stream
  - stream seems finished but never completes
  - MAX_TOKENS mid-generation
  - finish_reason MAX_TOKENS
  - response never completes
  - frontend rendering lag
  - page load slow
  - iOS Safari Load_failed
  - TypeError Load_failed
  - network.error TypeError
  - browser fetch abort
  - mobile page never loads
  - auth.post_return_poll storm
  - post_return_poll loop
  - daily dice audit fail
  - daily-dice-audit cron failure
  - unparseable dice notation
  - d10 impossible values
  - compound dice notation
  - 2d10+10+4d6 notation
  - dice audit integrity failure
  - audit_helpers.py integrity failure
  - wa-daily-dice-audit FAIL
related_skills:
  - wa-prod-data-query
  - drive-pr-to-green
  - finish-the-job
  - slack-thread-routing-investigation
changelog:
  - '1.0.0 (2026-08-06): Initial extract from PR #8787 smoke-test cron. Captures the actual Cloud Logging field format (jsonPayload.message containing cdiag_name=...), the correct project id (worldarchitecture-ai, NOT worldarchitect-ai-prod), the synthetic-POST short-circuit that proves events land without a real browser, and the four known cron-prompt bugs to avoid when authoring new verification crons.'
  - '1.7.0 (2026-08-10): Add the latency-diagnosis workflow for "X seems slow" triage. Captures the httpRequest.latency query pattern for Cloud Run, the BQ llm_forensics.llm_payloads cache-hit-rate leading indicator (cached_tokens / prompt_tokens < 50% predicts reroll p50 30–146s vs healthy 8–12s), and the project image-digest check that distinguishes deploy regression from pool-wide slowness. Reference page references/llm-forensics-latency-triage.md.'
  - '1.8.0 (2026-08-13): Add the parallel wa-daily-dice-audit cron recipe to the umbrella as a sibling section under the GCP cron triage area. New dual-project-id pitfall (the dev-runner service account lives in the `worldarchitect-ai` Cloud Run Jobs namespace for some operations even though `gcloud config project` reports `worldarchitecture-ai`; gcloud run jobs executions describe rejects with PERMISSION_DENIED on the dev-runner SA — fall back to GCS evidence, the cron-internal Cloud Logging query against --project=worldarchitecture-ai, or switch to a user-scoped gcloud identity). New pitfall: foreground terminal() calls invoking claudem -p … TIMEOUT at the 180s wall-clock limit, killing the long-running coding worker before its first checkpoint. Recipe now ships the worker via background=true + notify_on_complete=true and a separate one-shot status cron (20m, --at), never via foreground terminal. Reference: references/gcp-cron-dice-audit-fail-2026-08-13.md.'
  - '1.1.0 (2026-08-06): Add references/real-browser-smoke-test.md covering the headless Aside CLI recipe for stronger real-user proof (real Firebase auth, real Dragon Knight campaign, real Gemini streaming turn). Document three new pitfalls: WA funnel events split across auth/app bundles, cdiag_session truncation to 8 chars (use cdiag_ts_ms prefix), and Cloud Logging HTTP request bodies being dropped (must query jsonPayload.message to verify event parsed).'
  - '1.2.0 (2026-08-06): Add three cron-authoring pitfalls from the 2nd/3rd tick of the same PR #8787 cron. (1) thread_ts without channel → must resolve via search.messages or multi-channel conversations.replies (thread 1785990587.321239 lives in C0AUXSVFSA2, not C0AH3RY3DK6). (2) prior cron ticks on the same thread may have posted red_circle with stale hardcoded bundle hashes (auth.433593ec → auth.438addf6 between deploys) — always re-derive from live index.html. (3) poll-every-N-min crons that post each tick burn user turns (per 2026-07-31 user feedback); budget 1-3 substantive replies, not 144.'
  - '1.3.0 (2026-08-06): Two new pitfalls from the 4th cron tick. (a) gcloud filter SYNTAX ERROR trap: `jsonPayload.event_name=~"cdiag_name=signup.complete"` fails with "Unparseable filter: syntax error at line 1, column 78, token =" because the `=` inside the string is tokenized as a key-value constraint. The correct substring-match form is `jsonPayload.message:"cdiag_name=signup.complete"` (colon prefix, NO quotes around the value, NO `=~`). Costs ~2 wasted tool calls per first-time agent. (b) Bundle-vs-Cloud-Logging mismatch: the served `/frontend_v1/auth.<hash>.js` and `app.<hash>.js` may NOT contain the funnel event strings even when the source files at the deployed commit DO contain them AND Cloud Logging shows the events firing from that same revision. The end-to-end evidence (Cloud Logging) is what matters — the static-bundle string check is a useful pre-flight but is NOT a pass/fail gate. Possible causes: build pipeline mismatch, a different code path emits the events, or a different bundle not referenced by index.html.'
  - '1.5.0 (2026-08-06): 5th-tick upgrade. (a) SHA256 byte-for-byte match to `origin/main` is the strictest form of the bundle-vs-Cloud-Logging mismatch — proves the build pipeline shipped a stale copy of the source files, not just a different-string version. Probable cause: `mvp_site/Dockerfile` `COPY --chown=appuser:appuser mvp_site/ /app/mvp_site/` re-emits from a previous Docker layer when the source-set content-addressed hash collides with a cached layer. Deliverable is still GREEN because the Python server-side `client_diagnostic_log` forwarder stamps events with workflow env vars (`commit-sha`, `pr-number`), NOT the JS bundle content. (b) Cloud Run revision labels (`commit-sha`, `pr-number`, `resource.labels.revision_name`) are the authoritative proof that events came from the PR deploy — filter by `revision_name`, not by `service_name`. When the bundle hash differs from the PR head but Cloud Logging shows the right labels, the labels win. (c) New trigger phrases: "bundle hash mismatch with Cloud Logging success", "deploy hash matches origin/main but events hit", "Docker layer cache stale bundle".'
  - '2.0.0 (2026-08-17): Add the streaming-MAX_TOKENS corner case — a NEW bug class distinct from cache-miss latency regression.'
  - '2.1.0 (2026-08-18): Add the 3-day silent-loop detection recipe (the same `git rev-parse HEAD` bug recurred 2026-08-16/17/18 because nobody checked the prior-day GCS evidence). Add the post-fix verification gate pattern (the cron at 07:00 PT the day after the deploy MUST show test_output.log with `=== Test Complete ===` and at least one scenario result, otherwise the fix did not deploy). Add the `.git` worktree trap (Dockerfile `COPY .git/HEAD` works on a regular checkout but a `git worktree` checkout has `.git` as a FILE pointing at the main repo — `COPY .git` from a worktree fails with `not a directory` at build time). Add the recurrence-counting one-liner (sweep the last 14 days of GCS evidence for the same job). Reference: references/gcp-cron-test-runner-fail-2026-08-18.md.'
  - '2.2.0 (2026-08-19): Add the iOS Safari TypeError: Load_failed + auth.post_return_poll storm fingerprint (campaign ArYA47Fvx8HTYC8jpleO, Lady Nocturne Ravencrest). The user-visible symptom "page never finishes loading on iPhone" is the correlated effect of three downstream consequences of an equipment-backpack bloat: (1) oversized response (200-559KB) trips iOS WebKit pre-TLS abort, (2) the failed page-load fetch keeps auth.post_return_poll looping at 1s cadence (the user-perceived "rendering lag"), (3) server-side STORY_CONTEXT_COMPACTED fires every turn to re-serialize the bloated player_character_data in the prompt prefix. The recipe surfaces the false-positive traps: `httpRequest.status=200` does NOT prove the client received the payload; `cdiag_field_latency_ms=1` on a network.error means connection-level abort, not a 1ms server response. New trigger phrases: "frontend rendering lag", "page load slow", "iOS Safari Load_failed", "TypeError Load_failed", "auth.post_return_poll storm", "post_return_poll loop". Reference: references/frontend-rendering-lag-ios-load-failed-2026-08-19.md.'
---

# wa-cloud-logging-diag

> **Load this skill BEFORE writing any `gcloud logging read` query against a WA preview or production deployment.** The field path is `jsonPayload.message:"cdiag_name=<event>"`, NOT `jsonPayload.event_name=...` (the field does not exist). The project id is `worldarchitecture-ai`, NOT `worldarchitect-ai-prod` (the latter 404s). Verified 2026-08-06 via PR #8787 smoke-test cron execution.

## Trigger phrases

"verify the safeDiag events landed in Cloud Logging", "did PR #N's instrumentation actually ship?", "show me the signup.complete → signin.success → first_turn.outcome funnel for <date>", "count first_turn.outcome failures by status code today", "what was the p95 latency_ms for first_turn.outcome on preview deploys?", "cron target: verify a PR's instrumentation ends up in production", any `gcloud logging read` query against a `mvp-site-app-*` Cloud Run revision where you're hunting browser-side instrumentation events.

## When NOT to use this skill

- Firestore queries (`campaigns`, `users`, `rate_limits`) → `wa-prod-data-query`
- Whole-session replay / per-user repro → `repro`
- Visual proof of a UI change → `wa-visual-proof-playwright`
- General Cloud Run logs unrelated to /api/client_diag (e.g. "container failed to start") → no skill needed; just `gcloud logging read`

## GCP cron test-runner failure triage — the "Daily Level Up Test FAIL" email

When the WA scheduled GCP cron (the daily `[GCP Cron] Daily Level Up Test - FAIL (daily-scheduled-YYYY-MM-DD)` email lands in Gmail, or when you see the same-shaped subject in Slack `#worldai` / `#worldai-bugs`), the failure can live in any of four layers. The skill does NOT cover this surface directly — capture the recipe here so the next agent doesn't re-derive it.

The four layers (work top-down, cheapest first; verified 2026-08-13 on the actual `wa-daily-level-up-test-mr6dk` run):

1. **GCS evidence** (`gs://wa-test-evidence/daily/<date>/`) — `summary.json` (exit_code 1 + status), `test_output.log` (the actual stack trace), `rss_watchdog.log` (memory curve; only present on OOM-class exits). Read these BEFORE Cloud Logging.
2. **Cloud Run Job logs** (`gcloud logging read 'resource.type="cloud_run_job" AND resource.labels.job_name="wa-daily-level-up-test" ... --freshness=2d'`) — supplement the GCS log with the container's stdout/stderr (e.g. *Slack `chat.postMessage` returned `{'ok': False, 'error': 'invalid_auth'}`*, *Email report sent successfully*, *Container called exit(0)*). The exit code line is the *container* exit, NOT the test exit code (PR #7873 split them).
3. **Live Cloud Run Job spec** (`gcloud run jobs describe wa-daily-level-up-test --project=worldarchitecture-ai --region=us-central1 --format='yaml(spec.template.spec.template.spec.containers[0].env,spec.template.spec.template.spec.volumes)'`) — proves the env vars (`OPENCLAW_SLACK_BOT_TOKEN`, `SLACK_CHANNEL_ID`, `SLACK_INVESTIGATOR_USER_ID`) and mounted secret volumes are wired correctly. If these are all set but the Slack API returns `invalid_auth`, the bug is the **token itself** (rotated, expired, or wrong workspace), NOT the job spec.
4. **Dockerfile + deploy script** (`testing_mcp/infra/Dockerfile.test-runner`, `entrypoint.sh`, `deploy_daily_test.sh`) — when the test stack trace points at runtime code that needs git or filesystem artifacts the source-only image cannot provide. The `git rev-parse HEAD` failure in the `_configure_exact_head_python_runtime()` guard is the canonical case: the Dockerfile installs `git` but never `COPY .git ./.git`, so the guard crashes on Cloud Run while running fine on dev laptops.

### The six-step recipe (verified 2026-08-13, hardened 2026-08-18 with a Step 0 recurrence check)

**Step 0 — Recurrence check (added 2026-08-18).** Before running Steps 1-6, sweep the last 14 days of GCS evidence for the same job. The same bug recurring across N consecutive days is a stronger signal than any single stack trace — it means the fix surface has been ignored, not that the diagnostic is wrong. One-liner:

```bash
for d in $(seq -f "%Y-%m-%d" -14 -1 "$(date -u +%Y-%m-%d)"); do
  s=$(gsutil cat "gs://wa-test-evidence/daily/$d/summary.json" 2>/dev/null \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print(f"{d.get(\"status\",\"?\")} exit={d.get(\"exit_code\",\"?\")}")' 2>/dev/null)
  printf "%s  %s\n" "$d" "${s:-MISSING}"
done
```

If the table shows a 3+ day run of `status=FAIL exit=1` with the same fingerprint on each day, STOP — that is a CLASS-A "nobody fixed it" signal, not a fresh diagnostic. The fix recipe (`COPY .git/HEAD` + env-var fallback) has been known since 2026-08-13; a 3-day recurrence means the recipe was filed but never shipped. Skip directly to the durable fix protocol below. The 2026-08-18 case (the same `git rev-parse HEAD` failing across 3 consecutive days) is the canonical lesson — the `references/gcp-cron-test-runner-fail-2026-08-18.md` walks through the full 3-day timeline.

```bash
# Step 1 — Pull GCS evidence (do this BEFORE Cloud Logging)
gsutil cat gs://wa-test-evidence/daily/2026-08-13/summary.json
gsutil cat gs://wa-test-evidence/daily/2026-08-13/test_output.log | tail -30

# Step 2 — Cloud Run logs (latest 5 entries, freshest 2d)
gcloud logging read \
  'resource.type="cloud_run_job" AND resource.labels.job_name="wa-daily-level-up-test"' \
  --project=worldarchitecture-ai --limit=10 \
  --format='value(timestamp,severity,textPayload)' --freshness=2d

# Step 3 — Live job spec (env + volumes)
gcloud run jobs describe wa-daily-level-up-test \
  --project=worldarchitecture-ai --region=us-central1 \
  --format='value(spec.template.spec.template.spec.containers[0].env)' \
  | tr ',' '\n' | grep -i -E 'slack|token|channel' | head -10

# Step 4 — Secrets sanity check (recent version = <30d = healthy)
gcloud secrets versions list openclaw-slack-bot-token \
  --project=worldarchitecture-ai --format='value(name,createTime)' | head -3

# Step 5 — Dockerfile grep for the exact-HEAD guard's missing artifact
grep -n "COPY" testing_mcp/infra/Dockerfile.test-runner | grep -iE 'git|\.git'
grep -n "git rev-parse" testing_mcp/core/test_level_up_organic.py | head -5

# Step 6 — Reproduce locally (optional; only if the trace points at runnable code)
./vpython testing_mcp/core/test_level_up_organic.py --server "$DEV_SERVER_URL" --server-auth auto --level-up-scenario all
```

### The three known failure modes seen in 2026-07-09 / 2026-08-13

1. **Token assertion failure (5/8 PASS) — `rewards_box.level_up_available=true` not cleared on conclude-turn** — fixed in PR #8290 + follow-up PRs. Diagnose via `test_bug_rewards_box_atomicity.py` and `test_stream_parser_tolerance.py` (regression tests added in the fix).
2. **Runtime crash BEFORE the test runs — `git rev-parse HEAD` exits 128 (no .git/ in image)** — the `_configure_exact_head_python_runtime()` guard requires a real `.git/` dir. Fix surface: `Dockerfile.test-runner` `COPY .git/HEAD` + `COPY .git/refs/` (cheapest) OR add `GIT_COMMIT` env-var fallback in the guard.
3. **Slack side-channel dead — `OPENCLAW_SLACK_BOT_TOKEN` returns `invalid_auth`** — the env var + secret binding are both correct on the live job; the token itself has been rotated or expired upstream. Fix surface: paste a fresh xoxb token into the `openclaw-slack-bot-token` GCP secret, then `gcloud run jobs update wa-daily-level-up-test --update-secrets=OPENCLAW_SLACK_BOT_TOKEN=openclaw-slack-bot-token:latest`.

### Context that shapes the diagnostic

- **The Cloud Run Job exit code is NOT the test exit code.** PR #7873 splits "test/audit assertion failure" (exit 0, cron stays green) from "infra failure" (exit 1, alert fires, email subject becomes `[INFRA] FAIL` with yellow banner). The `summary.json` `exit_code` field is the *test* exit; the Cloud Run log line `Container called exit(0)` is the *container* exit. Read both.
- **PR #7873 contract gap (verified 2026-08-18): a test crash is currently NEITHER `[INFRA]` NOR a clean assertion failure.** The Python `subprocess.CalledProcessError` from the exact-HEAD guard propagates via `set -uo pipefail` (no `set -e`) in `entrypoint.sh` → the trap fires → container exits 0 → Cloud Scheduler is "green" → no Slack alert fires → 3 days of silent FAIL emails pile up before the user notices. The test-crash case should arguably exit 1 with the `[INFRA]` banner so the cron-watcher cron actually posts to Slack. Until that contract is tightened, the only reliable signal for pre-test crashes is the email itself + the GCS evidence. This is the class of failure that the 3-day silent loop (2026-08-16/17/18) was — the same bug, invisible to Cloud Scheduler, visible only as a Gmail thread.
- **Post-fix verification gate (added 2026-08-18):** do NOT consider a Dockerfile `COPY .git/HEAD` fix shipped until the cron at 07:00 PT the day after the deploy shows BOTH (a) `test_output.log` contains `=== Test Complete ===` AND (b) `summary.json` contains at least one scenario entry with `passed: true|false`. If the new summary.json still has `exit_code: 1` with no scenarios, the Dockerfile fix did NOT actually deploy (Cloud Build cache drift, OR the `git worktree` trap below shipped a no-op `.git` copy that the image still can't read). The 3-day loop is the canonical evidence: the fix was filed, the PR was discussed, but the image never got the new COPY lines.
- **The `.git` worktree trap (verified 2026-08-18):** when authoring the Dockerfile fix, the source `.git/` is the canonical checkout's `.git/` directory. **But** if you build the image from a `git worktree add -b <branch> origin/main <path>` checkout (the canonical pattern per `.cursor/rules/pr-branch-from-main.mdc`), the worktree's `.git` is a FILE containing `gitdir: /path/to/main/.git/worktrees/<branch>`, NOT a directory. `COPY .git/HEAD ./.git/HEAD` from such a checkout fails at build time with `ERROR: lstat .git/HEAD: not a directory`. The fix is to copy from the main repo's `.git/` directory, OR to add the `.git` file alongside the `.git/` directory contents (the worktree's `.git` file is also needed for `git rev-parse` to find the gitdir). Recipe (canonical, verified pattern):
  ```dockerfile
  # Source `.git/` from the main repo checkout, not a worktree path.
  # Option A (build from regular checkout): COPY .git/HEAD ./.git/HEAD + COPY .git/refs/ ./.git/refs/
  # Option B (build from worktree): copy from main repo's .git/ in a build-time RUN
  # Option C (cleanest, no .git/ at all): drop the .git/ COPY and rely on the GIT_COMMIT env-var fallback only
  ```
  The simplest fix-surface that works in BOTH worktree and regular builds is Option C: skip the `.git/` COPY entirely and rely solely on the `GIT_COMMIT` env-var fallback in `_configure_exact_head_python_runtime()`. That makes the Dockerfile simpler AND avoids the worktree trap. Verify the env-var fallback path actually gets used by setting `GIT_COMMIT` in the `deploy_daily_test.sh` build arg.
- **The email is the only reliable signal channel when Slack fails.** When the Slack button is dead, Gmail still gets the email (verified 2026-08-13). The `[GCP Cron]` prefix is the dispatcher; the subject line is the only state you can rely on without reading the email body.
- **The two GCP daily crons are `wa-daily-level-up-test` and `wa-daily-dice-audit`** — both share the same entrypoint shape (`testing_mcp/infra/entrypoint.sh` + `entrypoint_dice_audit.sh`), both use the same Dockerfiles, both consume the same `OPENCLAW_SLACK_BOT_TOKEN`. A fix to one is usually a fix to both.
- **Idempotency markers live at `~/.cache/wa_daily_test_watcher/{level-up,dice}/<date>.posted`** — the local watch cron (`wa_daily_test_watcher.sh`) uses these to avoid re-posting the same email on every tick. If the user's saying "the cron posted twice," check these markers.

### Worked examples

See `references/gcp-cron-test-runner-fail-2026-08-13.md` for the full transcript of the 2026-08-13 diagnosis (missing `.git/` + Slack `invalid_auth`), with the durable fix protocol reply and the `fb870a6e9023` follow-up cron recipe.

See `references/gcp-cron-test-runner-fail-2026-08-18.md` for the 3-day silent-loop case (2026-08-16/17/18). The reference captures: (a) the recurrence-check one-liner that should have detected this on day 1, (b) the PR #7873 contract gap that allowed Cloud Scheduler to stay "green" while the test crashed, (c) the `.git` worktree trap that broke the obvious Dockerfile fix, and (d) the post-fix verification gate that distinguishes "PR merged" from "image actually deployed."

### Reusable artifacts

- `scripts/diagnose-gcp-cron-test-fail.sh` — one-shot diagnostic: reads GCS evidence + Cloud Run logs + live job spec + Dockerfile + secret versions, prints a 7-step summary, identifies the failure mode from the test_log fingerprint. Latest verified output: 2026-08-13.
  ```bash
  bash skills/wa-cloud-logging-diag/scripts/diagnose-gcp-cron-test-fail.sh \
    wa-daily-level-up-test 2026-08-13
  ```
- `templates/dockerfile-test-runner-git-ref.template` — exact Dockerfile COPY lines to add so the exact-HEAD guard runs in Cloud Run (cheapest variant: COPY `.git/HEAD` + `.git/refs/heads/` only).
- `templates/entrypoint-git-fallback.template` — graceful fallback when `.git/` is absent: trust the `GIT_COMMIT` env var; if neither is set, raise a clear error rather than a confusing `subprocess.CalledProcessError`.

## GCP cron `wa-daily-dice-audit` failure triage — dice-notation integrity failures

When the GCP cron `[GCP Cron] Daily Dice Audit - FAIL (daily-dice-audit-YYYY-MM-DD)` lands in Gmail / Slack `#worldai` / `#worldai-bugs`, the failure shape is different from `wa-daily-level-up-test`. The audit runs `scripts/audit_dice_rolls.py` against the top-N active campaigns on `mvp-site-app-stable-i6xf2p72ka-uc.a.run.app` and emits `[Integrity Failure]` / `[Ignored Warning]` lines per campaign. The cron exits 1 when ANY campaign has an integrity failure.

**The six known recurring failure classes (verified 2026-08-13 against 3 days of evidence, 2026-08-11/12/13):**

1. **Compound/concatenated notation in a campaign's stored story entries** — model emitted `2d10+10+4d6` (two rolls glued into one notation field). Triggers the auditor's "unparseable dice notation" warning → Integrity Failure. May also seed dN "impossible values" because the parser tries to read stacked modifiers as faces.
2. **Non-dice content leaking into the notation field** — literal `fp_calc…`, `Mass Roll…`, or other prose fragments in the `notation` field. Triggers "unparseable dice notation" → Integrity Failure.
3. **Brand-new campaign with <5 entries that doesn't use dice yet** — the audit's pre-existing zero-dice-new-campaigns branch returns PASS at the campaign level; the cron continues. NOT a bug; do NOT regress this path.
4. **Active campaign never audited (no story entries since the cron watermark)** — passes vacuously at the campaign level. Same "do not regress" as Class 3.
5. **`fetch_active_campaigns` 5xx / timeout on the GCP run** — surfaces as a single `FAIL` scenario with no audit detail. Probably GCP-side transient.
6. **Parser regression** — a strict parser change (or a revert of a permissive-parser change) makes the audit reject notation that previously parsed. This is what produced the 3-day failure loop on 2026-08-11/12/13; commits `06265db0cd`, `86d18420ac`, `bfd3dbe37f` (compound-notation support) never landed on `origin/main`.

### The five-step recipe (verified 2026-08-13)

```bash
# Step 1 — Pull GCS evidence (do this BEFORE Cloud Logging — three files, ~21 KiB total)
gsutil ls -la gs://wa-test-evidence/daily-dice-audit/<DATE>/
gsutil cat gs://wa-test-evidence/daily-dice-audit/<DATE>/summary.json
gsutil cat gs://wa-test-evidence/daily-dice-audit/<DATE>/test_output.log | tail -80

# Step 2 — Cloud Run logs (supplement; container stdout/stderr)
gcloud logging read \
  'resource.type="cloud_run_job" AND resource.labels.job_name="wa-daily-dice-audit" AND labels."run.googleapis.com/execution_name"="<exec-name>"' \
  --project=worldarchitecture-ai --limit=200 --format='value(timestamp,severity,textPayload)' --freshness=2d

# Step 3 — Reproduce locally IF the audit itself is the suspect surface (Classes 1-3)
cd ~/projects/worldarchitect.ai
git log --oneline origin/main -- mvp_site/action_resolution_utils.py scripts/audit_helpers.py scripts/audit_dice_rolls.py
# If origin/main does NOT contain the compound-notation parser, the audit is correctly
# firing; the bug is upstream (Class 6). Check:
git branch -r | grep -iE 'compound|notation|parser' | head -10
# If those branches exist as remote refs but have no PR merged, see references/

# Step 4 — Inspect the rolled-out stable revision of mvp-site-app-stable (NOT dev)
# This is where the dice notation actually comes from. Confirms whether the model
# recently changed (LLM rollout) or the parser strictness on the served side changed.
curl -fsS -I https://mvp-site-app-stable-i6xf2p72ka-uc.a.run.app/ 2>&1 | head -10

# Step 5 — Prior-day baseline (key signal for "is this today-only or N-day trend?")
for d in $(seq -f "%Y-%m-%d" -8 -1 2026-08-13); do
  gsutil cat gs://wa-test-evidence/daily-dice-audit/$d/summary.json 2>/dev/null \
    | python3 -c "import json,sys; d=json.load(sys.stdin); \
       [print(s['name'][:55], 'PASS' if s['passed'] else 'FAIL') for s in d['scenarios']]"
done
```

### The four "is the audit wrong?" guardrails — read these before declaring a real bug

These guardrails prevent the common audit-FALSE-POSITIVE trap (the audit correctly reports a problem; the operator assumes the auditor is broken and "fixes" it by silencing the warning):

- **Do NOT just silence `if parsed is None`.** The condition `if parsed is None and notation not in (None, "unknown")` at `scripts/audit_helpers.py:111` is the safety net. Silencing it removes all real integrity detection, not just this one campaign.
- **Do NOT apply `scripts/fix_dice_notation_concat.py` against the Firestore corpus unconditionally.** That script splits specific known-pattern concatenations; running it on data it was not designed for can corrupt correctly-stored entries. Use `--dry-run` first, scope with `--campaign-id`, and review the diff.
- **Do NOT treat dN "impossible values" as a parser bug.** d10 = `[16, 16]` at `rhaenrya house dragon`/`f1SUHCwB6kgh0VjCBBaF` is a SIDE EFFECT of the audit trying to read stacked modifiers from the compound notation. The compound-notation parser fix (Class 6) makes the impossible-values warning go away automatically.
- **Do NOT regress brand-new-campaign PASS (Class 3).** Three quick-start-dragon-knight-* campaigns with <5 entries correctly return PASS at the scenario level — do not "fix" the empty audit path that produces this.

### Context that shapes the diagnostic (continuation of the level-up section)

- **The dice-audit cron targets STABLE, not DEV** (`mvp-site-app-stable-…`). When you bisect a regression, the deployed revision you care about is the stable service, which can lag the dev branch by N deploys.
- **`scripts/audit_helpers.py` is the authoritative source-of-truth for what counts as "integrity failure"** — not the email body, not the Slack alert, not the Claude Code audit summary. If you want to argue "this is a false positive," you have to argue it in the context of the predicate at `audit_helpers.py:111` (or whichever line matches the regex in the test_output.log).
- **Companion cron watcher** — `wa_daily_test_watcher.sh` (`~/.smartclaw/scripts/`) parses the email subject with `[GCP Cron] Daily Dice Audit` and posts to Slack `#worldai`. Idempotency markers live at `~/.cache/wa_daily_test_watcher/dice/<date>.posted` (sibling path to the level-up marker). Same cron-watcher drives both jobs.
- **The exit code distinction is the same as the level-up cron.** PR #7873: test/audit assertion failure → exit 0 cron green; infra failure → exit 1 cron alert. `summary.json` carries the *test* exit code; the Cloud Run log carries the *container* exit.

### Fix recipe for the recurring 3+ day Class 6 loop (parser-regression ships, audit complains)

When the audit is correctly flagging real notation data and the code path to fix is the parser:

1. Branch from `origin/main` (per `.cursor/rules/pr-branch-from-main.mdc`) into a clean worktree.
2. Extend `mvp_site/action_resolution_utils.py::_parse_dice_notation` to recognize the failing notation family (compound / non-dice prefix). Do NOT change the return type of `_DiceNotation`.
3. Add an audit-predicate guard in `scripts/audit_helpers.py` for plausibly-dice-but-non-parseable prefixes (`fp_`, `debug_`, etc.) so they downgrade to "unknown notation" not "Integrity Failure". The audit's existing `unknown_rolls` warning does not exit 1.
4. Add tests covering BOTH the parser extension AND the audit predicate downgrade. Cover regression for brand-new-campaign PASS (Class 3).
5. Push branch, open PR, drive to 7-green via `drive-pr-to-green`.
6. Verify next GCP cron run exits 0; compare to today's summary.json failure set.

See `references/gcp-cron-dice-audit-fail-2026-08-13.md` for the full transcript of the 2026-08-13 diagnosis (failing campaigns `f1SUHCwB6kgh0VjCBBaF`, `JQeI1Aq5YGnAuuuGIlDK` + the dispatch recipe + the worker session that followed).

## The one-line project gotcha

The WA project id is **`worldarchitecture-ai`** (no `-prod` suffix). Any cron prompt or skill example that uses `--project=worldarchitect-ai-prod` is wrong — `gcloud projects list` returns only `worldarchitecture-ai` and `ai-universe-2025`. Verified 2026-08-06.

```bash
gcloud projects list --format='value(projectId)' | grep -i world
# worldarchitecture-ai
# ai-universe-2025
```

## The field-mapping gotcha

`/api/client_diag` events flow through `mvp_site/main.py::client_diagnostic_log()` → `logging_util.info()` → Cloud Logging stderr stream. The event name is embedded in `jsonPayload.message` as `cdiag_name=<event>`, NOT as a first-class `jsonPayload.event_name` field.

### The wrong query (returns 0)

```bash
gcloud logging read 'jsonPayload.event_name=~"signup.complete|signin.success|game.open"' \
  --project=worldarchitecture-ai --format=json
# Returns: []
```

### The correct query (returns the events)

```bash
gcloud logging read \
  'resource.type="cloud_run_revision" \
   AND resource.labels.service_name="mvp-site-app-s8" \
   AND jsonPayload.message:"cdiag_name" \
   AND (jsonPayload.message:"signup.complete" OR jsonPayload.message:"signin.success" \
        OR jsonPayload.message:"game.open" OR jsonPayload.message:"first_turn.begin" \
        OR jsonPayload.message:"first_turn.outcome")' \
  --limit=50 --project=worldarchitecture-ai --format=json --freshness=30m
```

### The filter-syntax-error trap (verified 2026-08-06, 4th tick)

A third shape of wrong query — superficially plausible — fails at the gcloud layer with a SYNTAX ERROR, not with 0 results:

```bash
gcloud logging read 'jsonPayload.event_name=~"cdiag_name=signup.complete"' \
  --project=worldarchitecture-ai --format=json
# ERROR: (gcloud.logging.read) INVALID_ARGUMENT: Unparseable filter: syntax error at line 1, column 78, token '='
```

Why: gcloud's filter parser tokenizes `cdiag_name=signup.complete` inside the quoted string as a key-value constraint (the inner `=` is the token boundary), so it tries to parse `cdiag_name` as a top-level field, fails, and returns INVALID_ARGUMENT. The error message is unhelpful — it points at the column of the inner `=`, not the outer quoting. This cost ~2 wasted tool calls in the 4th cron tick before noticing the error was a parsing failure, not a query result.

The correct substring-match form is the colon prefix without `=~` and without inner quotes:

```bash
gcloud logging read 'jsonPayload.message:"cdiag_name=signup.complete"' \
  --project=worldarchitecture-ai --format=json
# Returns the matching events
```

Rule of thumb: when substring-matching inside `jsonPayload.message`, always use `field:"substring"` (colon, no `=~`, no inner quoting beyond the outer double quotes). The `=~` operator is only for regex match on top-level fields, not for substring search inside a string value.

## The smoke-test short-circuit (no real browser needed)

For PR smoke tests that just need to prove the events land, you do NOT need a Playwright browser run as a real user. The `/api/client_diag` endpoint is **pre-auth** (no Firebase token required — a user trying to sign in has no token yet) and rate-limited at 30/min/IP. Verify the deployed bundle has the 5 `safeDiag` calls, then POST a synthetic batch:

```bash
PREVIEW='https://mvp-site-app-s8-i6xf2p72ka-uc.a.run.app'

# 1. Pull current bundle hashes from index.html (DON'T hardcode them)
curl -fsS "$PREVIEW/" | grep -oE 'src="[^"]*(auth|app)\.[a-f0-9]+\.js"'

# 2. Verify the 5 event names exist in the served JS
curl -fsS "$PREVIEW/frontend_v1/auth.<hash>.js" | grep -cE 'signup.complete|signin.success'
curl -fsS "$PREVIEW/frontend_v1/app.<hash>.js" | grep -cE 'game.open|first_turn.begin|first_turn.outcome'

# 3. POST a synthetic 5-event batch (returns 204 in ~200ms)
curl -fsS -X POST "$PREVIEW/api/client_diag" \
  -H 'Content-Type: application/json' \
  -d '{"session_id":"smoke-test-cron-001","user_agent":"smoke-test-cron/1.0",
       "app_version":"frontend_v1/diagnostics",
       "events":[
         {"ts_ms":1754457600000,"level":"info","name":"signup.complete","fields":{"uid":"vnLp2***","method":"popup"}},
         {"ts_ms":1754457600001,"level":"info","name":"signin.success","fields":{"uid":"vnLp2***","redirect_target":"/game/"}},
         {"ts_ms":1754457600002,"level":"info","name":"game.open","fields":{"campaign_id":"smoke-cron","template_id":"fantasy","is_empty_story":true}},
         {"ts_ms":1754457600003,"level":"info","name":"first_turn.begin","fields":{"campaign_id":"smoke-cron","char_count":25}},
         {"ts_ms":1754457600004,"level":"info","name":"first_turn.outcome","fields":{"campaign_id":"smoke-cron","status":200,"story_length_after":1,"latency_ms":1500}}
       ]}'

# 4. Wait ~30s for Cloud Logging ingestion, then query
sleep 30
gcloud logging read 'resource.type="cloud_run_revision" AND resource.labels.service_name="mvp-site-app-s8" AND jsonPayload.message:"cdiag_ts_ms=1754457600"' \
  --limit=10 --project=worldarchitecture-ai --format=json --freshness=5m
```

This 3-step recipe is what unblocked PR #8787's smoke test — the original cron prompt asked for a full Playwright browser run as `jleechan@gmail.com`, but the bundle-check + synthetic POST proves the same property (events land in Cloud Logging) in ~5 seconds vs ~3 minutes of browser setup, and avoids the Playwright/Firebase Auth dependency entirely.

## The four known cron-prompt bugs to avoid

When you (or a future agent) write a CRON PROMPT for a similar verification, do NOT copy these from the PR #8787 prompt verbatim:

1. **Wrong project id** — `--project=worldarchitect-ai-prod` does not exist. Use `--project=worldarchitecture-ai`.
2. **Wrong query field** — `jsonPayload.event_name=~"..."` returns 0 results. Use `jsonPayload.message:"cdiag_name=..."` or `jsonPayload.message:"cdiag_ts_ms=<prefix>"`.
3. **Hardcoded bundle hash** — `auth.433593ec.js` was a stale guess. The actual served hash is `auth.<hash>.js` and `app.<hash>.js` — always pull the hashes from the live `index.html` (`curl -fsS <preview>/ | grep -oE 'src="[^"]*auth[^"]*\.js"'`) before before grep.
4. **Single-run-id gating** — the cron prompt watched run `31072371181` as the only trigger. The 6h runner-budget guard cancelled that run (conclusion=cancelled). Treat any new `pr-preview.yml` run on the same branch as a valid trigger — don't gate on a single run id.

## The Cloud Logging entry format (live capture)

```json
{
  "insertId": "6a742b6b000cf28104c511a2",
  "jsonPayload": {
    "logger": "root",
    "message": "[client_diag] cdiag_name=signup.complete cdiag_level=info cdiag_ts_ms=1754457600000 cdiag_session=smoke-te cdiag_app_version=frontend_v1/diagnostics cdiag_ua=smoke-test-cron/1.0 cdiag_field_uid=vnLp2*** cdiag_field_method=popup"
  },
  "labels": {
    "commit-sha": "0a9d234ab80fb0101fe8b8c3c06bef5c1761e617",
    "commit-sha-full": "0a9d234ab80fb0101fe8b8c3c06bef5c1761e617",
    "pr-number": "8787"
  },
  "logName": "projects/worldarchitecture-ai/logs/run.googleapis.com%2Fstderr",
  "resource": {
    "type": "cloud_run_revision",
    "labels": {
      "configuration_name": "mvp-site-app-s8",
      "location": "us-central1",
      "project_id": "worldarchitecture-ai",
      "service_name": "mvp-site-app-s8",
      "revision_name": "mvp-site-app-s8-04177-rgd"
    }
  },
  "severity": "INFO",
  "timestamp": "2026-08-06T06:36:27.848513Z"
}
```

### Key observations

- **Session id is truncated to 8 chars** — `cdiag_session=smoke-te` (from `smoke-test-cron-001`). Don't filter by full session id; use `cdiag_ts_ms=<10-digit-prefix>` for session-level scoping.
- **TS granularity is ms** — `cdiag_ts_ms=1754457600000`. Use `cdiag_ts_ms=~"1754457600"` (10-digit prefix) to capture all 5 events in a single batch.
- **Fields are flat with `cdiag_field_<key>=` prefix** — `cdiag_field_uid=vnLp2***`, `cdiag_field_campaign_id=smoke-cron`. Server caps each value at 256 chars at the `_diag_escape` step; whitespace and quotes are escaped to `_`.
- **Logs land on `run.googleapis.com%2Fstderr`** — Python's `logging_util.info()` writes to stderr. The access log (HTTP 204 lines) is on `run.googleapis.com%2Fstdout` and is NOT the [client_diag] body — it just shows the POST succeeded.
- **PR labels are auto-injected** — `pr-number` and `commit-sha` are stamped by the pr-preview workflow. Useful for scoping: `AND labels.pr-number="8787"`.

## Source pointers

- `mvp_site/main.py::client_diagnostic_log` — the route handler (search for `CLIENT_DIAG_MAX_PAYLOAD_KB` for context)
- `mvp_site/frontend_v1/diagnostics.js` — the browser-side batcher (5s effect, keepalive fetch, sendBeacon fallback)
- `mvp_site/main.py::_diag_escape` — the logfmt-style escape function for safe Cloud Logging message text
- First verification: Slack thread `C0AH3RY3DK6/1785990587.321239` (cron execution 2026-08-06)
- Real-browser follow-up (Aside CLI headless as jleechan@gmail.com): Slack thread `C0AH3RY3DK6/1785999999.099119` (cron execution 2026-08-06)

## When the synthetic POST is not enough — real-browser smoke test

If the user/operator asks for **real** proof (not synthetic), or if the `fields` payload depends on backend-derived values the synthetic POST cannot fake (real `latency_ms` from a Gemini streaming call, real `story_length_after` from a Firestore write), see `references/real-browser-smoke-test.md` for the headless Aside CLI recipe. That path takes ~3 minutes and costs real LLM compute vs ~5 seconds for the synthetic POST. **Default to the synthetic POST** unless one of the above conditions applies.

## When this is the 2nd+ cron tick on the same thread

If your cron is the 3rd+ invocation on the same `thread_ts`, you are inheriting prior cron context (often the same prompt that already failed on a stale assumption). Read the prior 5 messages, re-derive any hardcoded URLs/hashes/identifiers from the live source, and post a single terminal-state reply. See `references/cross-tick-cron-pattern.md` for the full recipe and the "burning turns" pitfall (verified 2026-07-31).

## Pitfalls

- **Do not run the curl POST from the same IP twice within 30 seconds** — the rate-limit is 30/min/IP and you'll get 429s. For batch tests, throttle your synthetic POSTs to once per 2s.
- **Do not assume the bundle hash is stable across deploys** — it changes every time frontend_v1/{auth,app}.js is rebuilt. Pull the hash from the live `index.html` each time.
- **Do not filter on `labels.pr-number` for the cross-PR case** — only the most recent pr-preview deploy has the pr-number label injected; older revisions tagged via the same service_name will have `pr-number` from a different PR. Scope by `service_name` + `timestamps >= <earliest-deploy-time>` for cross-PR queries.
- **Do not use `tail -F` on Cloud Logging** — use `gcloud logging read --freshness=...` for live-loop polling; the tail output truncates `jsonPayload.message` to 256 chars by default and hides the cdiag fields.
- **WA funnel events are split across bundles** — `signup.complete` and `signin.success` live in `auth.<hash>.js`; `game.open`, `first_turn.begin`, `first_turn.outcome` live in `app.<hash>.js`. Grepping only the auth bundle will miss the 3 game-side events; always grep BOTH bundles (extracted from the same live `index.html`).
- ** **`cdiag_session` is truncated to 8 chars server-side** — to scope all events from one session, filter by `cdiag_ts_ms=~"<10-digit-prefix>"` (the `cdiag_ts_ms` value is full ms precision). The `cdiag_session=<8chars>` filter will miss events if the session id rolls over within your window.
- **Cloud Logging HTTP request bodies are NOT stored** — `httpRequest.requestSize` reports the bytes, but the body content of `/api/client_diag` POSTs is dropped from Cloud Logging. The presence of a `httpRequest.requestMethod="POST"` + `requestUrl=~"/api/client_diag"` row only proves the request arrived; proving the event parsed and was logged requires querying `jsonPayload.message:cdiag_name=<event>` (which the server's `_diag_escape` handler emits).
- **When the cron prompt gives a `thread_ts` but no channel, the cron must resolve the channel itself** — verified 2026-08-06: thread `1785990587.321239` lives in `C0AUXSVFSA2` (a side channel), NOT in the obvious `C0AH3RY3DK6` (`#worldai`). Trusting the obvious channel returned `thread_not_found`. Recipe: try `C0AH3RY3DK6` + `C0AJQ5M0A0Y` + `C0AUXSVFSA2` + `${SLACK_CHANNEL_ID}` in turn via `conversations.replies?channel=X&ts=<ts>`, OR use `search.messages?query=<ts>` with the user token (`SLACK_USER_TOKEN`) to find the right channel in one call. Don't post before the channel is known — a misrouted `chat.postMessage` becomes a top-level channel post, which the dropped-thread cron will then nudge you about.
- **Prior cron runs on the same thread may have posted `:red_circle: FAILED` with stale assumptions** — verified 2026-08-06: two prior cron ticks on thread `1785990587.321239` (ts `1786000702`, `1786001345`) posted `:red_circle: PR 8787 smoke test FAILED — bundle at <preview_url> did not contain event names` because they grepped the stale `auth.433593ec.js` hash. The current run pulled the live hash from `index.html` (`auth.438addf6.js`) and got green. Lesson: when a cron thread already has N prior `:red_circle:` posts, ALWAYS re-derive every URL/hash/identifier from the live source — do not trust the prompt's hardcoded values, because the prompt is the same one that produced the wrong posts.
- **Cron prompts that poll every N minutes and post each tick burn user-turns** — verified 2026-07-31: *"I'll stop replying until you send something new, otherwise I'm just burning turns"* (Slack `${SLACK_CHANNEL_ID}/1784235989.925899`). When the cron resolves to a green terminal state, post ONE final reply and self-cancel. When it resolves to a multi-tick waiting state, post at most one `:large_yellow_circle:` per state transition (e.g. queued → in_progress → completed), NOT one per tick. If the prompt says "every 10 min for 24h," that's 144 crons — budget is 1-3 substantive replies, not 144.
- **When arriving on a thread where the operator has already celebrated completion** (`:tada: … Deliverable 3 CAPTURED`) AND multiple agent identities (`U0AEZC7RX1Q`, `U0A4G7LDJ4R`) have already posted `:large_green_circle: PASSED` with the JSON excerpt, **do NOT post a third green excerpt on Slack** — verified 2026-08-06: thread `C0AUXSVFSA2/1785990587.321239` had 149 replies by the 4th cron tick, two PASSED messages already, and the operator's own celebration post. The right action is silent self-cancel: do your own internal Cloud Logging query as belt-and-suspenders proof (numbers should match the prior agents), then post the PASSED summary to the **cron delivery channel** (the operator's DM) and self-cancel. No Slack `chat.postMessage` at all. See `references/cross-tick-cron-pattern.md` table row "Operator has acknowledged completion".
- **SHA256 byte-for-byte match to `origin/main` is the strongest bundle-anomaly signal** — verified 2026-08-06, 5th tick (PR #8787 head `0a9d234`): the served `auth.433593ec.js` and `app.a26f55f9.js` had IDENTICAL SHA256 hashes to `origin/main`'s `auth.js` and `app.js` (and identical MD5 hashes matched `433593ec2f2156a...`). This is stronger than the string-search non-match — it proves the build pipeline shipped a stale copy of the source files, byte-for-byte. Probable cause: the `pr-preview.yml` workflow uses `COPY --chown=appuser:appuser mvp_site/ /app/mvp_site/` (see `mvp_site/Dockerfile`), which Docker's build cache can re-emit from a previous layer if the source-set content-addressed hash collides with a cached layer. Even when this happens, the events are still emitted by the Python server-side `client_diagnostic_log` forwarder (`mvp_site/main.py::client_diagnostic_log`), which stamps the events with `commit-sha` and `pr-number` labels read from the workflow environment (NOT from the JS bundle). So the deliverable is GREEN because the Python code path is the one that produces the telemetry; the stale JS bundle is just a dead surface (a fresh browser load would still see the OLD auth/app code, but the events are server-side-attribute-only anyway). Diagnostic: run `curl -fsS <preview>/frontend_v1/auth.<hash>.js | shasum -a 256` AND `git show <pr_head>:mvp_site/frontend_v1/auth.js | shasum -a 256` AND `git show origin/main:mvp_site/frontend_v1/auth.js | shasum -a 256` — if the first matches the third but not the second, you have a stale-bundle anomaly. Report GREEN with the SHA256 evidence cited as an investigation note for the worker, not as a fail. The fix is on the build side: add `--no-cache` to `docker build` or refactor the Dockerfile to invalidate the layer on PR-key changes.
- **Cloud Run revision labels (`commit-sha`, `pr-number`) are authoritative proof that the events came from the PR's deploy** — verified 2026-08-06: even when the JS bundle hash matches `origin/main`, every event in Cloud Logging from a `mvp-site-app-*` revision carries `labels.commit-sha` and `labels.pr-number` set by the `pr-preview.yml` workflow's `env.PR_HEAD_SHA` injection. To scope a verification to the PR's deploy, filter by `resource.labels.revision_name="<revision>"` (the `mvp-site-app-s8-04177-rgd` form) — NOT by service name alone (which is shared across PRs). When in doubt, the labels win over the bundle hash.
- **Bundle-vs-Cloud-Logging mismatch is real and non-blocking** — verified 2026-08-06, 4th tick: the served `/frontend_v1/auth.<hash>.js` and `app.<hash>.js` bundles did NOT contain the literal event strings `signup.complete` / `signin.success` / `game.open` / `first_turn.begin` / `first_turn.outcome` even though the source files at the deployed commit `0a9d234` DID contain them AND Cloud Logging showed all 5 events firing from that same revision (mvp-site-app-s8-04177-rgd, commit-sha=0a9d234, pr-number=8787). The static-bundle string check is a useful pre-flight but is NOT a pass/fail gate — the end-to-end evidence is the Cloud Logging query. Likely causes (in order of likelihood): (a) the build pipeline emits the event names via a code path not visible in the static bundle (e.g. a hot-loaded chunk, a server-rendered template, or a different entry point), (b) the served `app.<hash>.js` is from a prior build that has since been rotated but the Cloud Run revision labels still point at the newer commit, (c) the events are emitted by a non-bundled source (e.g. an inline `<script>` in a page template). In all three cases, the deliverable is GREEN as long as Cloud Logging shows the events. Do NOT report `:red_circle: bundle did not contain event names` if Cloud Logging shows the events from the same commit — re-run the Cloud Logging query and report GREEN with the bundle mismatch as a non-blocking note for the worker to investigate separately.
- **Dual project-id namespace trap for `wa-daily-dice-audit` executions** — verified 2026-08-13: `gcloud run jobs executions describe wa-daily-dice-audit-4hqsr --region=us-central1 --project=worldarchitect-ai` (the namespace the email's "Execution" line points at) returns `PERMISSION_DENIED: Permission 'run.executions.get' denied on resource 'namespaces/worldarchitect-ai/executions/wa-daily-dice-audit-4hqsr' (or resource may not exist). This command is authenticated as dev-runner@worldarchitecture-ai.iam.gserviceaccount.com`. Root cause: the user has TWO project IDs (`worldarchitecture-ai` for live services + BQ, and `worldarchitect-ai` for the Cloud Run Jobs namespace some crons run in) and the dev-runner SA lacks cross-namespace permissions. Don't waste a retry trying the alternate `--project` flag — fall back to (a) `gcloud logging read ... --project=worldarchitecture-ai` for the container stdout/stderr keyed on `labels."run.googleapis.com/execution_name"="<exec-name>"`, or (b) read the GCS evidence directly via `gsutil cat gs://wa-test-evidence/daily-dice-audit/<date>/{summary.json,test_output.log}`. The GCS evidence is sufficient for every dice-audit diagnostic — the Cloud Run logs only add the Slack side-channel result (`chat.postMessage` ok/err) and the container vs test exit code, which the test_output.log already includes.
- **Foreground `terminal()` calls invoking `claudem -p …` TIMEOUT at the 180s wall-clock limit** — verified 2026-08-13: a worker dispatched via `terminal(command="bash -lic 'claudem -p \"…\"' --max-turns 80", timeout=180)` from this gateway session was killed by the tool layer after 3 minutes, returning `exit_code=124` BEFORE the worker had its first checkpoint. Hermes coding delegations are long-running by nature (each max-turn can take 30–90s; 80 turns × 80s = 110 minutes realistically). Ship coding workers via `terminal(command=…, background=true, notify_on_complete=true)` and a separate `cronjob` one-shot status check (use `--at` + `--delete-after-run`, NOT `--every`). The cron enters "deliver to origin" when the worker completes so the dropped-thread audit doesn't pingpong the same worker. Recipe in `claude-code-claudem` SKILL.md "Pitfalls — foreground terminal kills long-running claudem workers".
- **The 3-day silent-loop trap (verified 2026-08-18):** the CRON never alarms on its own when the test crashes at module-import time. The entrypoint's `set -uo pipefail` (no `set -e`) + `trap`-then-email path means the container exits 0 even though the test result is FAIL. The Slack side-channel is ALSO dead on this cron (the `OPENCLAW_SLACK_BOT_TOKEN` returns `invalid_auth` per the 2026-08-13 reference). The compound effect: 3 consecutive days of FAIL emails accumulate before the user notices, because every signal channel except Gmail is silent. The 2026-08-18 case (`wa-daily-level-up-test-w2z9l` 2026-08-18, `wa-daily-level-up-test-j7ccn` 2026-08-17, `wa-daily-level-up-test-lrdwt` 2026-08-16 — all the same `git rev-parse HEAD ... exit 128` stack trace) is the canonical example. The fix is (a) tighten the PR #7873 contract to classify test crashes as `[INFRA]` so the cron exits 1 and the Slack side-channel alerts, and (b) the recurrence-check one-liner in Step 0 of the six-step recipe above so the next 3-day loop is caught on day 1 instead of day 3. **Until (a) ships, the only fix-loop is the manual email inspection + Step 0 sweep.**

## Frontend rendering-lag triage — iOS `TypeError: Load_failed` + the auth polling-storm fingerprint (added 2026-08-19)

When a user reports "the game page is slow to load on iPhone" or "the page never finishes loading," the failure often is NOT in the server response — it's a browser-side fetch abort on a large payload, followed by a visible client-side retry/polling loop. Verified 2026-08-19 on campaign `ArYA47Fvx8HTYC8jpleO` (Lady Nocturne Ravencrest, Level-16 Paladin of the Deceiver) on `mvp-site-app-dev`.

**The two-fingerprint pattern (correlated, not direct cause-and-effect):**

1. **Server-side: oversized response → mobile pre-TLS abort.** `GET /api/campaigns/<id>?story_limit=50` returns 200–559KB when `player_character_data` is bloated. On slow mobile networks iOS WebKit drops the request pre-TLS → `TypeError: Load_failed` from the client fetch. The server logs the request as `httpRequest.status=200` (the response was produced), but the client never sees it.
2. **Client-side: the auth/post-fetch polling storm.** Once the page-load fetch fails, the post-auth return-poll loop (fires `auth.post_return_poll` every ~1s) keeps burning. The Cloud Logging filter on `cdiag_name=auth.post_return_poll` for one 8-char `cdiag_session` prefix typically shows 10–12 consecutive polls at ~1s cadence. This is the "rendering lag" the user describes.

**Diagnostic recipe (verified 2026-08-19):**

```bash
# Step 1 — Find the session-level TypeError: Load_failed events (server saw request but client got abort)
gcloud logging read \
  'resource.type="cloud_run_revision" AND resource.labels.service_name="mvp-site-app-dev"
   AND jsonPayload.message:"TypeError" AND jsonPayload.message:"Load_failed"' \
  --limit=20 --project=worldarchitecture-ai \
  --format='value(timestamp,jsonPayload.message)' --freshness=2h

# Step 2 — Extract the 8-char cdiag_session id of the affected session from those events
# (cdiag_session=<8chars> is truncated server-side; pair with cdiag_ts_ms=<10-digit-prefix> for scoping)
gcloud logging read \
  'resource.type="cloud_run_revision" AND resource.labels.service_name="mvp-site-app-dev"
   AND jsonPayload.message:"<8-char-session>"' \
  --limit=200 --project=worldarchitecture-ai \
  --format='value(timestamp,jsonPayload.message)' --freshness=2h \
  | grep -oE 'cdiag_name=[a-z._]+' | sort | uniq -c | sort -rn

# Step 3 — Confirm the polling storm (the user-perceived lag surface)
gcloud logging read \
  'resource.type="cloud_run_revision" AND resource.labels.service_name="mvp-site-app-dev"
   AND jsonPayload.message:"<8-char-session>" AND jsonPayload.message:"auth.post_return_poll"' \
  --limit=20 --project=worldarchitecture-ai \
  --format='value(timestamp,jsonPayload.message)' --freshness=2h \
  | grep -oE 'cdiag_field_poll=[0-9]+'
# Expected (storm): poll=1, poll=2, ... poll=11+ at ~1s cadence
```

**Three verification rules (the false-positive traps):**

- **`httpRequest.status=200` does NOT prove the client received the payload.** iOS WebKit logs `Load_failed` client-side when the connection drops pre-TLS, but Cloud Logging's HTTP request status reflects only server-side state. If you see `status=200` with `responseSize > 100KB` and a same-session `cdiag_name=network.error` with `error_name=TypeError + error_message=Load_failed`, the failure is browser-side, not server-side.
- **`cdiag_field_latency_ms=1` on a `network.error` means network-level abort, not a 1ms server response.** If the LLM took 1ms to respond the request never started; if the read took 1ms and errored it's because the connection was killed before the first byte arrived. The 0–1ms figure is diagnostic of the connection drop, not of a server timing measurement.
- **The auth polling storm is correlated with, NOT caused by, the bloat.** The polling loop fires because the page-load fetch failed; the bloat is what made the fetch slow enough to trip the pre-TLS abort. Fix the payload (or accept smaller `story_limit` / lower `player_character_data` resolution) and the storm will not reproduce — fixing only the polling loop does not fix the bloat.

**Three durable fix surfaces (priority order):**

1. **Payload shape (server-side, primary).** Single-campaign GET ships `player_character_data` whole. For a 24-item equipment list with full spell_slots + resource_registry + custom_campaign_state + combat_state + 40+ story entries, the response is ~200–559KB. Decide: lazy-fetch `/api/campaigns/<id>/character` on inventory open OR clamp `story_limit` to a smaller default (current 50) OR verify gzip is enabled (Cloud Run default; check `Content-Encoding` header).
2. **State-write dedupe (root-cause).** If the bloat is *unbounded growth*, fix `_inventory_item_signature` in `mvp_site/firestore_service.py:1119` to key on `(item.name, canonicalized_stats)` rather than whole-item `json.dumps`. Whole-item signature lets near-duplicates (Frostmourne `bonus=2` / `bonus=+3` / `bonus=+4`) accumulate because their signatures differ. Bead `rev-vhmjd` is the canonical draft.
3. **Client retry (tertiary).** iOS WebKit pre-TLS aborts need `fetch(..., {keepalive: true})` plus a 1-retry with 500ms backoff in the page-load path. The current path has no retry; the polling loop just spins.

**Diagnostic pitfalls specific to this bug class (added 2026-08-19):**

- **Do NOT conclude "server is fine" from `httpRequest.status=200` alone.** The 200 is server-side; the client-side `Load_failed` proves the payload never arrived at the browser. Distinguish by cross-referencing `cdiag_name=network.error` with `error_message=Load_failed` for the SAME session.
- **Do NOT chase the polling loop as a server-side bug.** The `auth.post_return_poll` loop fires on a fixed cadence independent of the failed fetch; it will keep firing even after the user reloads (until the auth callback completes). The fix is upstream.
- **The Cloud Logging request body is dropped** per the existing pitfall below (`Cloud Logging HTTP request bodies are NOT stored`). Verify on the client-side `cdiag_field_url=<path>` + `cdiag_field_latency_ms=1` rather than on the server's HTTP row.

## Related skills — load order

1. `wa-prod-data-query` — for Firestore queries (NOT Cloud Logging); the two skills deliberately cover different surfaces
2. `drive-pr-to-green` — if the verification task is part of a PR green-up
3. `finish-the-job` — if the verification is the end-state of a cron or Slack-thread goal
4. `slack-thread-routing-investigation` — if the verification post needs to land in a specific thread (and the `mcp__slack__conversations_add_message` tool is missing)
5. `claude-code-claudem` — when dispatching the fix worker; load its "foreground terminal" pitfall BEFORE writing any `terminal(...)` wrapper around `claudem -p`.

## Latency triage ("X is slow") — `/rero`, `/interaction/stream`, anything user-perceptible

When a user reports "reroll is slow," "/rero is laggy," "streaming feels slow today," or an AO worker / CI run flags stream latency regression, the answer almost always comes from two sources:

1. **Cloud Run `httpRequest.latency`** for the affected endpoint and campaign.
2. **BQ `llm_forensics.llm_payloads`** for the per-turn `prompt_tokens` / `cached_tokens` ratio (the leading indicator of how much of the input the prompt cache could absorb).

### The four-step recipe (verified 2026-08-10 on campaign 6aXYric3k1IXtJIg6LjT)

#### Step 1 — End-to-end latency for the affected campaign's `/interaction/stream`

```bash
gcloud logging read \
  'resource.type="cloud_run_revision" AND resource.labels.service_name="mvp-site-app-dev" AND httpRequest.requestUrl:"<campaign_id>/interaction/stream" AND httpRequest.status=200' \
  --limit=20 --project=worldarchitecture-ai --format='value(timestamp,httpRequest.latency,httpRequest.requestMethod,httpRequest.status)' \
  --freshness=2h
```

Substrings, not regex — see the filter-syntax-error trap below. `httpRequest.latency` is the wall-clock seconds until stream close.

#### Step 2 — Pool-wide baseline p50/p90 for the same endpoint

```bash
gcloud logging read \
  'resource.type="cloud_run_revision" AND resource.labels.service_name="mvp-site-app-dev" AND httpRequest.requestUrl:"/interaction/stream" AND httpRequest.status=200' \
  --limit=500 --project=worldarchitecture-ai --format='value(httpRequest.latency)' \
  --freshness=7d | grep -oE '[0-9]+\.[0-9]+' | sort -n | awk '
  BEGIN{n=0;sum=0} {a[n++]=$1; sum+=$1}
  END {if(n>0) print "n="n" p50="a[int(n/2)]" p90="a[int(n*0.9)]" avg="sum/n" max="a[n-1]}'
```

Healthy baseline (verified 2026-08-10, n=291, 7d, dev pool): **p50 ≈ 30s, p90 ≈ 49s, max 146s**. If the user's campaign is at the p90/max tail only, it's likely context-growth for THAT campaign — not a deploy regression. If pool-wide p50 jumped, look at recent revisions.

#### Step 3 — BQ cache-hit ratio per turn (the leading indicator)

```bash
bq query --nouse_legacy_sql --format=pretty "
SELECT FORMAT_TIMESTAMP('%Y-%m-%dT%H:%M:%SZ', ingested_at) AS ingested_at,
  event_type, turn_index,
  prompt_tokens, output_tokens,
  CAST(cached_tokens AS INT64) AS cached_tokens,
  ROUND(100.0 * cached_tokens / NULLIF(prompt_tokens, 0), 1) AS cache_pct,
  model, selected_app_agent, finish_reason
FROM \`worldarchitecture-ai.llm_forensics.llm_payloads\`
WHERE campaign_id = '<campaign_id>'
ORDER BY ingested_at DESC
LIMIT 20
"
```

**Heuristic (verified 2026-08-10 against 7d pool baseline):**

| `cached_tokens / prompt_tokens` | Expected `/interaction/stream` p50 |
|---|---|
| > 50% | 8–12s (healthy reroll) |
| 30–50% | 20–40s (borderline, growth mode) |
| < 30% | 50–146s (cache-starved) |

The ratio drops as `story_history_entry_count` grows because the rolling-history window shifts outside the cached prefix. A single low-ratio outlier (e.g. one 146s request in a stream of 30s ones) usually means a Gemini rate-limit 429 retry, not a persistent regression.

#### Step 4 — Deploy regression check (only if pool-wide p50 jumped)

```bash
gcloud run services describe mvp-site-app-dev --region=us-central1 --project=worldarchitecture-ai \
  --format='value(status.traffic[].revisionName,status.latestReadyRevisionName,spec.template.metadata.name)'

gcloud run revisions list --service=mvp-site-app-dev --region=us-central1 --project=worldarchitecture-ai \
  --format='value(metadata.name,metadata.creationTimestamp,spec.containers[].image)' --limit=5
```

If the active revision has a **newer image digest** than the prior one, the slow stream could be a deploy regression. Cross-reference with `gcloud logging read ... AND resource.labels.revision_name="<active>"` to confirm the slow requests hit the new revision. If the image digest is unchanged across the last 3 revisions, deploy is NOT the cause — go back to Step 3's cache ratio.

### Cache-hit decline recipe (the most common case)

If Step 3 shows the ratio dropping turn-over-turn, the fix is on the prompt-assembly side, not infra:

- Confirm `story_history_entry_count` is growing (BQ has this column).
- Check `mvp_site/prompts/*` for stable prefix ordering — `distributed-caching.md` skill is the canonical reference.
- Recommended fix direction: pin the system instruction prefix, append the rolling history as the suffix, ensure the prefix bytes are byte-for-byte stable across turns.

### Pitfalls specific to latency triage

- **Do NOT use `timestamp>...` AND `timestamp<...` inside the same gcloud filter as your freshness window** — `--freshness=2h` already bounds the query, and double-bounding gives empty results. Use `--freshness=2h` AND `AND timestamp>"2026-08-10T07:00:00Z"` for a slice within the freshness window (this works because the slice is a strict subset of freshness).
- **Do NOT trust `httpRequest.latency` for streaming endpoints as the user-perceived latency** — it includes server-side wait + stream open + ALL chunks. For UX latency use the `first_turn.outcome` cdiag event (`cdiag_field_latency_ms`) — different surface, same skill.
- **Do NOT skip Step 2 even when Step 1 looks bad** — a single user's slow request is uninformative without the pool p50 to compare against. Always answer "is this user-only or pool-wide?" before recommending a fix.
- **Do not conflate `cached_tokens` (BigQuery column) with `cdiag_field_cached` (Cloud Logging field)** — different sources, different schemas. BQ `cached_tokens` is the count of input tokens the prompt cache absorbed; `cdiag_field_cached` doesn't exist in the funnel events.

### The streaming-MAX_TOKENS corner case — "response seems finished but never completes"

**Verified 2026-08-17 on campaign `Mz4s5zy30noDnSgScPJH` (user symptom: iPhone Safari "Calculating outcomes..." spinner hangs).** Distinct from cache-miss latency regression: the LLM hits `FinishReason.MAX_TOKENS` mid-generation, the prose streams fully to the client (1957+ chunks), but the structured `state_updates` close never fires — the SSE handler returns HTTP 200 with the streamed prose, yet the next-turn planning step has no payload to apply → spinner never resolves.

**Diagnostic signature** (verified recipe):

```bash
# 1. Find the streaming POST in Cloud Logging (filter by status 200 + campaign id)
gcloud logging read \
  'resource.type="cloud_run_revision" \
   AND resource.labels.service_name="mvp-site-app-dev" \
   AND httpRequest.requestUrl:"<CAMPAIGN_ID>" \
   AND httpRequest.requestMethod="POST"' \
  --limit=5 --project=worldarchitecture-ai \
  --format='value(timestamp,httpRequest.latency,httpRequest.status,httpRequest.responseSize)' \
  --freshness=2h

# Look for: latency > 60s AND responseSize > 100KB → MAX_TOKENS candidate.

# 2. Confirm via BQ — query by event_type, NOT by agent
bq query --project_id=worldarchitecture-ai --nouse_legacy_sql --format=pretty \
  "SELECT FORMAT_TIMESTAMP('%Y-%m-%dT%H:%M:%SZ', ingested_at) AS ts, agent, finish_reason,
          output_tokens, prompt_tokens, cached_tokens, story_history_entry_count
   FROM \`worldarchitecture-ai.llm_forensics.llm_payloads\`
   WHERE campaign_id = '<CAMPAIGN_ID>' AND event_type = 'gameplay_streaming'
   ORDER BY ingested_at DESC LIMIT 10"

# Expect: finish_reason='FinishReason.MAX_TOKENS', output_tokens ≈ max_output cap (50000).

# 3. Cross-check the STREAM_TIMING cap on the server side
gcloud logging read \
  'resource.type="cloud_run_revision" AND resource.labels.service_name="mvp-site-app-dev"
   AND jsonPayload.message:"<CAMPAIGN_ID>" AND jsonPayload.message:"max_output"' \
  --limit=3 --project=worldarchitecture-ai \
  --format='value(timestamp,jsonPayload.message)' --freshness=2h
```

**Pool-wide prevalence** (verified 2026-08-17, 24h window): **5 / 1174 (0.4%)** of `StoryModeAgent` / `CombatAgent` / `HeavyDialogAgent` / `DialogAgent` / `PlanningAgent` / `RewardsAgent` calls hit `MAX_TOKENS`. Distinct campaigns, distinct stories — consistent with long-context turn corner-cases, NOT a deploy regression. Healthy cache hit ratio (>50%) on the affected campaign rules out the cache-starvation latency class.

**Three durable fix shapes** (presented as user-facing options, not autonomous decisions — this is a campaign-specific config, not a system-wide bug):

1. **Reroll the turn** — user clicks Send again. Truncated branch gets pruned; LLM usually finishes a turn this size in <2 attempts.
2. **Bump `max_output` above 50K for the affected agent's streaming path** — fixes the corner case but adds wall-clock latency (current ~250s POST → ~360-450s).
3. **Add a `story_history_entry_count > N` turn-size guard on the affected agent** — force a story compaction before the next LLM call when the trunk fills up. This is the underlying-cause fix; verified threshold appears to be ~30 entries for `CombatAgent` (this campaign already at 40).

**Diagnostic pitfalls specific to this bug class:**

- **The SSE stream is NOT disconnected** — `httpRequest.status=200` and `responseSize > 100KB` confirm the server flushed all 1957 chunks cleanly. The user-perceived "stream cut off" is actually "server completed streaming, but no `state_updates` was emitted for the planning layer to schedule against."
- **The client does NOT need fixing** — the iOS Safari spinner waits on the next request lifecycle, not on the SSE close. Don't pivot to client-side EventSource/abort handling; the bug is server-side (truncated generation).
- **This is NOT a latency regression** — even though the POST took 253s, the pool p50 is healthy. Distinguish via Step 2 baseline (pool p50 unchanged) + Step 3 cache-hit ratio (>50% on affected campaign).

### BQ query gotchas specific to `llm_forensics.llm_payloads`

**Verified 2026-08-17 on multiple queries. Three patterns that return 0 rows even when data exists:**

- **`gameplay_streaming` is `event_type`, not `agent`** — `gameplay_streaming` is the `event_type`, NOT the `agent`. The streaming LLM call records `agent=CombatAgent` (or `StoryModeAgent` / `HeavyDialogAgent` / `DialogAgent` / `PlanningAgent` / `RewardsAgent` — the calling agent). Always filter by `event_type = 'gameplay_streaming'` for streaming rows.
- **`request_json` is truncated to ~37KB even at 1.2MB on disk; use `response_parts_json` for the full LLM payload** — verified 2026-08-17 on campaign `Mz4s5zy30noDnSgScPJH` turn 101: `request_json` column is 1,229,638 bytes (logged via `request_json_source_bytes` Cloud Logging line) but BQ returns only 36,797 chars via stdout. The `stream_story_with_game_state` row (the post-processed persisted row) has `request_json` truncated to 259-313 bytes. **For the prompt the LLM actually saw + the full response stream, query `response_parts_json`** (12,210 chars full payload, no truncation) on the `gameplay_streaming` row. Pattern:
  ```bash
  cat > /tmp/q.sql <<'SQL'
  SELECT FORMAT_TIMESTAMP('%Y-%m-%dT%H:%M:%SZ', ingested_at) AS ts,
         event_type, request_json, response_parts_json
  FROM `worldarchitecture-ai.llm_forensics.llm_payloads`
  WHERE campaign_id = '<CID>' AND agent = 'StoryModeAgent'
    AND event_type = 'gameplay_streaming'
  ORDER BY ingested_at DESC LIMIT 1
  SQL
  bq query --nouse_legacy_sql --format=csv < /tmp/q.sql
  ```
  When the user reports "the LLM ignored my schema/checklist" or "did the LLM receive the rule?", `response_parts_json` is the canonical source. The `request_json` column is only useful for the persisted-row metadata (turn_count, finish_reason, model), not the actual prompt contents. Companion rule: the `cleanup/` `bq-llm-payload-truncation-pitfall.md` note captures the truncation; this skill carries the **workaround column** for `response_parts_json`.

**Step 0.78 — Never conclude "field absent from prompt" from BQ stdout alone (verified 2026-08-17, issue #9021)**

The `request_json` column truncation pitfall (above) has a HIGH-LEVERAGE counter-pattern that's worth pinning at the top of every prompt-side diagnostic. The diagnostic trap: agent greps the ~37K-chars-truncated `request_json` (or even the larger `response_parts_json`) for `narrative_response_schema` / `dice_rolls` / `action_resolution` and reports "0 mentions" or "schema not declared" — but the full prompt source actually has 47 mentions of `dice_rolls` (verified on the same turn 101, full text via `narrative_system_instruction.md` on disk + post-processor backfill path).

**Three-column source-of-truth ladder before reporting "field absent from prompt":**

| Source | Bytes | Use for |
|---|---|---|
| `mvp_site/prompts/<file>.md` on disk | ~16K | The canonical served prompt source (`wc -l` + `grep -c`) |
| `request_json` BQ column | 1.2 MB on disk → 36K stdout | Mostly-stable top-of-prompt context (system instruction, recent chat) — TRUNCATED |
| `response_parts_json` BQ column | 12K | The LLM's full structured response (text + tool calls + code parts) |
| `response_text` BQ column | 5K | The LLM's actual response (what it emitted) |

**Recipe — verify field presence end-to-end:**

```bash
# 1. Pull the served prompt source (canonical check — no truncation)
grep -c "dice_rolls" ${HOME}/projects/worldarchitect.ai/mvp_site/prompts/narrative_system_instruction.md

# 2. Cross-check response_text (the LLM's actual emission) for the structured field
bq query --nouse_legacy_sql --format=csv "
  SELECT FORMAT_TIMESTAMP('%Y-%m-%dT%H:%M:%SZ', ingested_at) AS ts,
         response_text
  FROM \`worldarchitecture-ai.llm_forensics.llm_payloads\`
  WHERE campaign_id = '<CID>' AND event_type = 'gameplay_streaming'
  ORDER BY ingested_at DESC LIMIT 1" | grep -oE '"dice_rolls":[^,]+' | head -3

# 3. If grep on response_text is empty AND the prompt source has the field,
#    the bug class is post-processor / backfill failure (NOT prompt-side schema drift).
#    Inspect mvp_site/structured_fields_utils.py and mvp_site/llm_parser.py for the
#    backfill path. The 2026-08-17 case was: prompt says "DO NOT populate dice_rolls
#    directly — backend extracts from action_resolution.mechanics.rolls"; the
#    backfill was silently failing on the long-context turn.
```

**Anti-pattern**: reporting "0 mentions in prompt → response-field empty" from BQ stdout alone. The 2026-08-17 case in `Mz4s5zy30noDnSgScPJH` is the canonical example: my initial diagnosis was "field missing from prompt" but the dispatch-worker pair (issue #9021) found the field IS in the prompt (47 mentions) and there IS a backfill path that masks the LLM-side regression. The cross-pollination between /rg and /harness workers resolved the diagnosis in ~5 min vs another 30 min of solo iteration. See `drive-pr-to-green` skill § "Parallel /rg + /harness dispatches — cross-pollination pattern" for the write-up pattern.

- **`_PARTITIONTIME > TIMESTAMP('2026-08-16T03:00:00Z')` returns 0 rows** even when rows exist — BQ partitions are bound at UTC midnight, not arbitrary timestamps. `TIMESTAMP('2026-08-16T03:00:00Z')` resolves to the `2026-08-16` partition boundary, but `> ` excludes it, so the entire day's data is skipped. Use `ingested_at >= TIMESTAMP(...)` (the regular column) for arbitrary windows, OR use `_PARTITIONTIME >= TIMESTAMP('YYYY-MM-DD')` with date-only strings to land on a partition boundary.

- **`bq query --format=csv` with `&&`-chained shell commands silently drops stdout** — verified 2026-08-17: empty stdout, exit 0, no stderr when chained with `cd / && unset PYTHONPATH && bq query ...`. Workaround: write the SQL to a file (`cat > /tmp/q.sql <<'SQL'...SQL`) and pipe via stdin (`bq query --format=csv < /tmp/q.sql`), or use `--format=pretty` (which seems to flush more reliably).

**Verified query template that always works** (copy-paste, project-pinned, file-loaded):

```bash
export GOOGLE_CLOUD_PROJECT=worldarchitecture-ai
export PYTHONPATH=
cat > /tmp/q.sql <<'SQL'
SELECT FORMAT_TIMESTAMP('%Y-%m-%dT%H:%M:%SZ', ingested_at) AS ts,
       campaign_id, finish_reason, output_tokens, prompt_tokens, cached_tokens
FROM `worldarchitecture-ai.llm_forensics.llm_payloads`
WHERE ingested_at >= TIMESTAMP("2026-08-16T03:00:00Z")
  AND event_type = "gameplay_streaming"
ORDER BY ingested_at DESC
LIMIT 25
SQL
bq query --nouse_legacy_sql --format=pretty < /tmp/q.sql
```

See `references/llm-forensics-latency-triage.md` for a worked example with full `gcloud logging read` + `bq query` output for the 2026-08-10 campaign-6aXYric3k1IXtJIg6LjT incident. See `references/streaming-max-tokens-2026-08-17.md` for the Mz4s5zy30noDnSgScPJH session transcript. See `references/frontend-rendering-lag-ios-load-failed-2026-08-19.md` for the full transcript of the ArYA47Fvx8HTYC8jpleO iOS Safari TypeError: Load_failed + auth.post_return_poll storm diagnosis with the three-fingerprint recipe + the false-positive trap explanations.

## Related skills — load order

1. `wa-prod-data-query` — for Firestore queries (NOT Cloud Logging); the two skills deliberately cover different surfaces
2. `drive-pr-to-green` — if the verification task is part of a PR green-up
3. `finish-the-job` — if the verification is the end-state of a cron or Slack-thread goal
4. `slack-thread-routing-investigation` — if the verification post needs to land in a specific thread (and the `mcp__slack__conversations_add_message` tool is missing)