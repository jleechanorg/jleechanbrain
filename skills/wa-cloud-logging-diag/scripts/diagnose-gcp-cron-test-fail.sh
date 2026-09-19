#!/usr/bin/env bash
# Quick diagnostic for the "Daily Level Up Test / Dice Audit FAIL" cron email.
# Reads GCS evidence + Cloud Run logs + live job spec + Dockerfile + deploy script,
# prints a compact summary, and exits 0 (always -- this is a diagnostic, not a gate).
#
# Usage:
#   bash skills/wa-cloud-logging-diag/scripts/diagnose-gcp-cron-test-fail.sh \
#     <job-name> <date-stamp-YYYY-MM-DD>
#
# Example:
#   bash skills/wa-cloud-logging-diag/scripts/diagnose-gcp-cron-test-fail.sh \
#     wa-daily-level-up-test 2026-08-13
#
# Verified 2026-08-13 on the wa-daily-level-up-test-mr6dk run.

set -uo pipefail

JOB_NAME="${1:-wa-daily-level-up-test}"
DATE="${2:-$(date -u +%Y-%m-%d)}"
PROJECT="${PROJECT:-worldarchitecture-ai}"
REGION="${REGION:-us-central1}"
BUCKET="${BUCKET:-wa-test-evidence}"

echo "=== GCP cron test-runner diagnostic for $JOB_NAME on $DATE ==="
echo "=== Project: $PROJECT    Region: $REGION    Bucket: $BUCKET ==="
echo

# Step 1 -- GCS evidence
echo "--- Step 1: GCS evidence ---"
for f in summary.json test_output.log rss_watchdog.log; do
    if gsutil -q stat "gs://$BUCKET/daily/$DATE/$f" 2>/dev/null; then
        echo "  gs://$BUCKET/daily/$DATE/$f  <- exists"
    else
        echo "  gs://$BUCKET/daily/$DATE/$f  <- MISSING"
    fi
done
echo

SUMMARY=$(gsutil cat "gs://$BUCKET/daily/$DATE/summary.json" 2>/dev/null || echo "{}")
echo "  summary.json:"
echo "$SUMMARY" | sed 's/^/    /'
echo

# Step 2 -- Tail of test_output.log
echo "--- Step 2: Last 12 lines of test_output.log ---"
gsutil cat "gs://$BUCKET/daily/$DATE/test_output.log" 2>/dev/null | tail -12 | sed 's/^/    /'
echo

# Step 3 -- Cloud Run Job logs (last 5 entries, freshest 2d)
echo "--- Step 3: Cloud Run Job logs (last 5, 2d) ---"
gcloud logging read \
  "resource.type=cloud_run_job AND resource.labels.job_name=$JOB_NAME" \
  --project="$PROJECT" --limit=5 \
  --format='value(timestamp,severity,textPayload)' --freshness=2d 2>/dev/null \
  | head -5 | sed 's/^/    /'
echo

# Step 4 -- Live job spec -- Slack env wiring
echo "--- Step 4: Live job spec (Slack env vars) ---"
gcloud run jobs describe "$JOB_NAME" \
  --project="$PROJECT" --region="$REGION" \
  --format='value(spec.template.spec.template.spec.containers[0].env)' 2>/dev/null \
  | tr ',' '\n' | grep -iE 'slack|token|channel' | head -10 | sed 's/^/    /'
echo

# Step 5 -- Slack secret recent versions
echo "--- Step 5: openclaw-slack-bot-token versions (last 3) ---"
gcloud secrets versions list openclaw-slack-bot-token \
  --project="$PROJECT" --format='value(name,createTime)' 2>/dev/null \
  | head -3 | sed 's/^/    /'
echo

# Step 6 -- Dockerfile grep for the exact-HEAD guard's missing artifact
echo "--- Step 6: Dockerfile.test-runner COPY lines (looking for missing .git) ---"
DOCKERFILE="${DOCKERFILE:-testing_mcp/infra/Dockerfile.test-runner}"
if [ -f "$DOCKERFILE" ]; then
    grep -n "COPY" "$DOCKERFILE" | sed 's/^/    /'
    echo
    if grep -q "COPY .git\|COPY \\.git" "$DOCKERFILE"; then
        echo "    + .git COPY present"
    else
        echo "    X NO .git COPY -- exact-HEAD guard will crash on git rev-parse HEAD"
    fi
else
    echo "    $DOCKERFILE not found (skip; may be running out-of-tree)"
fi
echo

# Step 7 -- Identify the failure mode
echo "--- Step 7: Failure-mode fingerprint ---"
TEST_LOG=$(gsutil cat "gs://$BUCKET/daily/$DATE/test_output.log" 2>/dev/null || echo "")
CR_LOG=$(gcloud logging read \
  "resource.type=cloud_run_job AND resource.labels.job_name=$JOB_NAME" \
  --project="$PROJECT" --limit=10 \
  --format='value(textPayload)' --freshness=2d 2>/dev/null || echo "")

if echo "$TEST_LOG" | grep -q "git rev-parse HEAD.*returned non-zero exit status 128"; then
    echo "    -> Pre-test runtime crash (missing .git/ in image)"
    echo "    Fix: Dockerfile COPY fix + env-var fallback in the guard"
elif echo "$TEST_LOG" | grep -qE "level_up_available|rewards_box"; then
    echo "    -> 5/8 PASS assertion (rewards_box / level_up_available canonical)"
    echo "    Fix: PR #8290 lineage (canonicalize_rewards + clear level_up_available)"
elif echo "$CR_LOG" | grep -q "'invalid_auth'"; then
    echo "    -> Slack side-channel dead (OPENCLAW_SLACK_BOT_TOKEN rejected)"
    echo "    Fix: rotate the openclaw-slack-bot-token secret"
elif echo "$TEST_LOG" | grep -qE "malformed or missing done payload|stream_parser"; then
    echo "    -> Streaming tolerance failure"
    echo "    Fix: PR #8290 lineage (Content-Type check + synthesize done_payload)"
elif echo "$CR_LOG" | grep -qE "CRON_INFRA_FAIL|exit code 137"; then
    echo "    -> True infra failure (OOM / signal kill / GCS upload fail)"
    echo "    Fix: PR #7873 INFRA_FAIL path; investigate RSS watchdog log"
else
    echo "    -> Fingerprint did not match any known failure mode"
    echo "    Action: read full test_output.log + Cloud Run logs for the actual trace"
fi

echo
echo "=== Diagnostic complete (informational only -- not a fail/pass gate) ==="
