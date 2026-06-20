#!/usr/bin/env bash
# deploy.sh — Deploy Hermes changes to production.
#
# Architecture:
#   ~/.smartclaw/      = staging repo (git checkout)
#   ~/.smartclaw_prod/ = production runtime dir (port 8643)
#
# Flow:
#   1. Print banner (timestamp, branch, remote)
#   2. Git pull on ~/.smartclaw/ (fail if uncommitted changes)
#   3. Pre-deploy health check (warn, don't block)
#   4. Restart prod Hermes gateway via launchd (ai.smartclaw.prod)
#   4.5. Sync policy files (CLAUDE.md/SOUL.md/TOOLS.md/HEARTBEAT.md) from
#        staging to prod so the running gateway reads the latest rules.
#        Skipped with --no-sync. Drift is the jleechan-pcah class of
#        silent policy degradation.
#   5. Run canary — fail deploy if canary fails
#   6. Print success with HEAD SHA
#
# Usage:
#   ./scripts/deploy.sh                # full deploy
#   ./scripts/deploy.sh --skip-pull    # skip git pull
#   ./scripts/deploy.sh --skip-restart # skip gateway restart, run canary only
#   ./scripts/deploy.sh --no-sync      # skip Stage 4.5 policy-file sync
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# Live prod gateway binds 8643 (PR #619 corrected the port mapping 2026-06-13);
# override via PROD_PORT env variable. Matches hermes-canary.sh / hermes-health.sh.
PROD_PORT="${PROD_PORT:-8643}"
LAUNCHD_LABEL="ai.smartclaw.prod"
RESTART_TIMEOUT=30
SKIP_PULL=0
SKIP_RESTART=0
SKIP_SYNC=0

# Policy files that the gateway reads at startup; must match between staging
# and prod so the agent sees the latest rules on the very next restart.
POLICY_FILES=(CLAUDE.md SOUL.md TOOLS.md HEARTBEAT.md)
PROD_DIR="$HOME/.smartclaw_prod"

for arg in "$@"; do
  case "$arg" in
    --skip-pull)    SKIP_PULL=1 ;;
    --skip-restart) SKIP_RESTART=1 ;;
    --no-sync)      SKIP_SYNC=1 ;;
    -h|--help)
      echo "Usage: $0 [--skip-pull] [--skip-restart] [--no-sync]"
      echo "  --skip-pull     skip git pull on ~/.smartclaw/"
      echo "  --skip-restart  skip gateway restart, run canary only"
      echo "  --no-sync       skip Stage 4.5 policy-file sync"
      exit 0
      ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

ts()      { date '+%Y-%m-%d %H:%M:%S'; }
section() { echo ""; echo "=== $1 ==="; echo "$(ts)"; echo ""; }
die()     { echo "DEPLOY FAILED: $1" >&2; exit 1; }

# ── Stage 1: Banner ────────────────────────────────────────────────────────────
section "Hermes Deploy"
BRANCH="$(git -C "$REPO_DIR" branch --show-current 2>/dev/null || echo 'unknown')"
REMOTE="$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || echo 'unknown')"
echo "  Repo   : $REPO_DIR"
echo "  Branch : $BRANCH"
echo "  Remote : $REMOTE"
echo "  Prod   : $HOME/.smartclaw_prod  (port $PROD_PORT)"
echo "  Label  : $LAUNCHD_LABEL"

# ── Stage 2: Git pull ──────────────────────────────────────────────────────────
if [[ "$SKIP_PULL" -eq 1 ]]; then
  echo ""
  echo "[skip-pull] Skipping git pull."
else
  section "Stage 2: Git Pull"

  if ! git -C "$REPO_DIR" diff --quiet || ! git -C "$REPO_DIR" diff --cached --quiet; then
    die "Uncommitted changes in $REPO_DIR — stash or commit before deploying."
  fi

  echo "Pulling latest from origin/$BRANCH ..."
  git -C "$REPO_DIR" pull --ff-only origin "$BRANCH" \
    || die "git pull failed — resolve conflicts or use --skip-pull."
  echo "Pull complete."
fi

# ── Stage 3: Pre-deploy health check ──────────────────────────────────────────
section "Stage 3: Pre-deploy Health Check"
if HERMES_HEALTH_PORT="$PROD_PORT" bash "$SCRIPT_DIR/hermes-health.sh"; then
  echo "Health check passed."
else
  echo "WARNING: Health check reported issues — proceeding anyway." >&2
fi

# ── Stage 4: Restart prod gateway ─────────────────────────────────────────────
if [[ "$SKIP_RESTART" -eq 1 ]]; then
  section "Stage 4: Gateway Restart (skipped)"
  echo "[skip-restart] Skipping gateway restart."
else
  section "Stage 4: Restart Prod Gateway ($LAUNCHD_LABEL)"

  DOMAIN="gui/$(id -u)"

  # Multi-source pid detection: cross-check lsof (port-bound), launchctl (managed),
  # and pgrep (process-running). The old `grep '^ *pid' | awk '{print $3}'` silently
  # failed because launchctl's `pid = NNNN` line is tab-indented (not space) and the
  # PID is field 4 (after `pid = `), not field 3. See jleechan-dc17.
  LSOF_PID="$(lsof -nP -iTCP:"$PROD_PORT" -sTCP:LISTEN -t 2>/dev/null | head -1 || true)"
  LAUNCHCTL_PID="$(launchctl print "${DOMAIN}/${LAUNCHD_LABEL}" 2>/dev/null \
    | awk '/^[[:space:]]+pid[[:space:]]+= / {print $NF; exit}' || true)"
  # Scoped pgrep fallback: a bare `pgrep -f "hermes gateway"` would match the
  # staging gateway (ai.smartclaw.staging on 8644) when prod is down — see
  # jleechan-dc17 review. Filter candidates by requiring the candidate to be
  # bound to PROD_PORT, which is the only authoritative prod signal.
  PGREP_PID="$(pgrep -f "hermes gateway" 2>/dev/null | while read -r candidate_pid; do
    if lsof -nP -p "$candidate_pid" -iTCP:"$PROD_PORT" -sTCP:LISTEN 2>/dev/null \
        | grep -q "(LISTEN)"; then
      echo "$candidate_pid"
      break
    fi
  done || true)"

  # Prefer lsof (most authoritative: process bound to prod port). Fall back to
  # launchctl then pgrep so a gateway bound but untracked, or untracked but
  # running, is still found.
  GATEWAY_PID="${LSOF_PID:-${LAUNCHCTL_PID:-${PGREP_PID:-}}}"

  # Test hook: allow tests to stub liveness so a synthetic pid can simulate
  # "process exists" without a real process. Production callers leave this
  # unset, so `kill -0` runs as usual.
  if [[ -n "${FAKE_PID_ALIVE:-}" ]]; then
    pid_alive() { [[ "$1" == "$FAKE_PID_ALIVE" ]]; }
  else
    pid_alive() { kill -0 "$1" 2>/dev/null; }
  fi

  if [[ -n "$GATEWAY_PID" ]] && pid_alive "$GATEWAY_PID"; then
    echo "Sending SIGTERM to pid $GATEWAY_PID (lsof=${LSOF_PID:-?} launchctl=${LAUNCHCTL_PID:-?} pgrep=${PGREP_PID:-?}) ..."
    kill -TERM "$GATEWAY_PID" 2>/dev/null || true
  else
    echo "No running pid found — launchd will start a fresh instance."
  fi

  echo "Waiting up to ${RESTART_TIMEOUT}s for gateway to come back on port $PROD_PORT ..."
  DEADLINE=$(( $(date +%s) + RESTART_TIMEOUT ))
  READY=0
  while [[ $(date +%s) -lt $DEADLINE ]]; do
    if curl -sf --max-time 3 "http://127.0.0.1:${PROD_PORT}/health" >/dev/null 2>&1; then
      READY=1
      break
    fi
    sleep 2
  done

  if [[ "$READY" -eq 0 ]]; then
    die "Gateway did not come up on port $PROD_PORT within ${RESTART_TIMEOUT}s."
  fi
  echo "Gateway is up on port $PROD_PORT."
fi

# ── Stage 4.5: Policy-file sync (staging → prod) ─────────────────────────────
# Auto-syncs CLAUDE.md/SOUL.md/TOOLS.md/HEARTBEAT.md from staging
# (~/.smartclaw/<file>) to prod (~/.smartclaw_prod/<file>) when they differ.
# Solves jleechan-pcah class: rule lands in main → deploys to staging → but
# the running prod gateway keeps reading the old prod copy. Skipped with
# --no-sync. Runs after Stage 4 restart so the canary in Stage 5 validates
# the post-sync state — i.e. tests what the gateway will read on next read.
if [[ "$SKIP_SYNC" -eq 1 ]]; then
  section "Stage 4.5: Policy Sync (skipped)"
  echo "[no-sync] Skipping policy-file sync to ~/.smartclaw_prod/."
else
  section "Stage 4.5: Policy Sync → $PROD_DIR"
  SYNCED=0
  SKIPPED=0
  FAILED=0
  for f in "${POLICY_FILES[@]}"; do
    src="$REPO_DIR/$f"
    dst="$PROD_DIR/$f"
    if [[ ! -f "$src" ]]; then
      echo "  [skip] $f (not in staging)"
      SKIPPED=$((SKIPPED + 1))
      continue
    fi
    if [[ ! -f "$dst" ]]; then
      echo "  [skip] $f (not in prod — first deploy?)"
      SKIPPED=$((SKIPPED + 1))
      continue
    fi
    if diff -q "$src" "$dst" >/dev/null 2>&1; then
      echo "  [ok]   $f (in sync)"
      SKIPPED=$((SKIPPED + 1))
      continue
    fi
    src_size=$(wc -c < "$src" 2>/dev/null || echo 0)
    dst_size=$(wc -c < "$dst" 2>/dev/null || echo 0)
    if cp "$src" "$dst"; then
      echo "  [sync] $f (staging ${src_size}B → prod ${dst_size}B)"
      SYNCED=$((SYNCED + 1))
    else
      echo "  [FAIL] $f cp failed" >&2
      FAILED=$((FAILED + 1))
    fi
  done
  echo ""
  echo "  Summary: synced=$SYNCED  unchanged=$SKIPPED  failed=$FAILED"
  if [[ "$FAILED" -gt 0 ]]; then
    die "Stage 4.5 policy sync had $FAILED failure(s) — aborting deploy."
  fi
fi

# ── Stage 5: Canary ────────────────────────────────────────────────────────────
# Canary races documented (all transient, LLM pipeline healthy on retry):
#   - hermes-canary.sh cron posts its daily-thread anchor simultaneously,
#     competing for the bot's first response slot. Manual retry at 2026-06-17
#     18:41:19Z returned the exact nonce in 7.3s.
#   - SlackSocket event-loop saturation under gateway restart.
# One retry with 30s backoff absorbs these without false-positive deploy
# failures. If the second attempt also fails, the gateway is genuinely
# unhealthy and the deploy must halt.
section "Stage 5: Canary Check"
if HERMES_CANARY_PORT="$PROD_PORT" bash "$SCRIPT_DIR/hermes-canary.sh"; then
  echo "Canary passed."
else
  echo "Canary failed on first attempt — waiting 30s before retry (race recovery)."
  sleep 30
  if HERMES_CANARY_PORT="$PROD_PORT" bash "$SCRIPT_DIR/hermes-canary.sh"; then
    echo "Canary passed on retry."
  else
    die "Canary failed twice — production gateway may be unhealthy. Check logs."
  fi
fi

# ── Stage 5.5: Policy-file drift warning (non-blocking) ──────────────────────
# The 5th-misroute sub-class 5b leak (2026-06-14) was caused by prod CLAUDE.md
# drifting 29 days behind staging. Emit a visible WARN if any policy file
# (CLAUDE.md, SOUL.md, TOOLS.md, HEARTBEAT.md) differs between staging
# ~/.smartclaw and prod ~/.smartclaw_prod. Do NOT auto-cp — drift must be visible.
section "Stage 5.5: Policy-File Drift Warning"
STAGING_DIR="$REPO_DIR"
PROD_DIR="$HOME/.smartclaw_prod"
DRIFT_FOUND=0
for POLICY_FILE in CLAUDE.md SOUL.md TOOLS.md HEARTBEAT.md; do
  STAGING_FILE="$STAGING_DIR/$POLICY_FILE"
  PROD_FILE="$PROD_DIR/$POLICY_FILE"
  if [[ -f "$STAGING_FILE" && -f "$PROD_FILE" ]]; then
    if ! diff -q "$STAGING_FILE" "$PROD_FILE" >/dev/null 2>&1; then
      echo "WARN: $POLICY_FILE differs between staging and prod." >&2
      echo "  staging: $STAGING_FILE" >&2
      echo "  prod   : $PROD_FILE" >&2
      echo "  -> run: cp $STAGING_FILE $PROD_FILE  (then restart prod gateway)" >&2
      DRIFT_FOUND=1
    fi
  fi
done
if [[ "$DRIFT_FOUND" -eq 0 ]]; then
  echo "Policy files in sync between staging and prod."
fi
# Non-blocking — deploy continues. Drift is a WARN, not a die.

# ── Stage 5.6: Cron jobs + launchd plist drift warning (non-blocking) ──────────
# 3rd drift class (project_2026-06-18_investigation_5b_detector_log_missing):
# staging cron/jobs.json had slack-5b-leak-detector but prod didn't, AND the
# matching launchd plist was never rendered+installed on prod. Extend the
# drift detector to also flag missing staging→prod cron entries and missing
# launchd plists (template exists in repo but no rendered file in
# ~/Library/LaunchAgents/).
section "Stage 5.6: Cron + launchd drift warning"
STAGING_CRON_JOBS="$STAGING_DIR/cron/jobs.json"
PROD_CRON_JOBS="$PROD_DIR/cron/jobs.json"
CRON_DRIFT_FOUND=0
CRON_CHECK_UNCERTAIN=0
# Drift emits two signal classes:
#   - missing IDs in prod (jobs added to staging but not prod)
#   - changed definitions (same id, different schedule/command/payload) — catch by stable hash
#   Filesystem or parse failures fall through as WARN, NOT as silent "in sync".
if [[ -f "$STAGING_CRON_JOBS" && -f "$PROD_CRON_JOBS" ]]; then
  CRON_DIFF="$(python3 - "$STAGING_CRON_JOBS" "$PROD_CRON_JOBS" <<'PY'
import hashlib, json, sys
try:
    s = json.load(open(sys.argv[1]))
    p = json.load(open(sys.argv[2]))
except Exception as e:
    print("PARSE_ERROR\t" + str(e), file=sys.stderr)
    sys.exit(2)

def _stable(job):
    # Compare the operator-visible fields only. Drop volatile noise
    # (lastRun, history, ephemeral metadata) so deployment timestamps
    # do not produce false drift.
    keep = ('id', 'name', 'schedule', 'command', 'payload', 'enabled',
            'timezone', 'description', 'tags')
    return {k: job.get(k) for k in keep if k in job}

def _hash(job):
    return hashlib.sha256(json.dumps(_stable(job), sort_keys=True, separators=(',', ':')).encode()).hexdigest()

sj = {j.get('id') or j.get('name'): j for j in s.get('jobs', [])}
pj = {j.get('id') or j.get('name'): j for j in p.get('jobs', [])}

missing = sorted(set(sj) - set(pj))
changed = sorted(
    k for k in set(sj) & set(pj)
    if _hash(sj[k]) != _hash(pj[k])
)

print('\n'.join(['MISSING\t' + k for k in missing] +
               ['CHANGED\t' + k for k in changed]))
PY
)" || CRON_RC=$?
  if [[ ${CRON_RC:-0} -ne 0 ]]; then
    echo "WARN: unable to compare cron drift (parse error or non-zero exit rc=$CRON_RC)" >&2
    CRON_CHECK_UNCERTAIN=1
  elif [[ -n "$CRON_DIFF" ]]; then
    while IFS=$'\t' read -r kind mid; do
      [[ -z "$mid" ]] && continue
      if [[ "$kind" == "CHANGED" ]]; then
        echo "WARN: cron entry '$mid' definition differs between staging and prod (schedule/command/payload)" >&2
        echo "  -> reconcile via install-launchagents.sh re-render, or mirror the JSON edit" >&2
      else
        echo "WARN: cron entry '$mid' present in staging $STAGING_CRON_JOBS but missing from prod $PROD_CRON_JOBS" >&2
        echo "  -> install-launchagents.sh will auto-propagate on next run; or manually mirror the entry" >&2
      fi
      CRON_DRIFT_FOUND=1
    done <<< "$CRON_DIFF"
  fi
else
  echo "WARN: cron drift check skipped; missing $STAGING_CRON_JOBS or $PROD_CRON_JOBS" >&2
  CRON_CHECK_UNCERTAIN=1
fi

# Launchd plist drift: template in repo but no rendered file under ~/Library/LaunchAgents/
PLIST_DRIFT_FOUND=0
for tmpl in "$STAGING_DIR"/launchd/ai.smartclaw.schedule.*.plist.template; do
  [[ -f "$tmpl" ]] || continue
  base="$(basename "$tmpl" .plist.template)"
  rendered="$HOME/Library/LaunchAgents/$base.plist"
  if [[ ! -f "$rendered" ]]; then
    echo "WARN: plist template present but no rendered plist: $rendered" >&2
    echo "  -> run: scripts/install-launchagents.sh (will render + bootstrap)" >&2
    PLIST_DRIFT_FOUND=1
  fi
done

if [[ "$CRON_DRIFT_FOUND" -eq 0 && "$PLIST_DRIFT_FOUND" -eq 0 && "$CRON_CHECK_UNCERTAIN" -eq 0 ]]; then
  echo "Cron + launchd plists in sync between staging and prod."
fi
# Non-blocking — deploy continues. Drift is a WARN, not a die.

# ── Stage 6: Success ───────────────────────────────────────────────────────────
section "Deploy Complete"
HEAD_SHA="$(git -C "$REPO_DIR" rev-parse HEAD)"
echo "  SHA    : $HEAD_SHA"
echo "  Branch : $BRANCH"
echo "  Time   : $(ts)"
echo ""
echo "Hermes deploy succeeded."
