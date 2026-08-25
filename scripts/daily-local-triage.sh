#!/usr/bin/env bash
# ~/.smartclaw/scripts/daily-local-triage.sh
#
# Daily launchd job — invoked by ai.smartclaw.schedule.daily-local-triage.
# Loads /ms context via the memory_search skill, then triages the
# ~/.smartclaw working tree so `git status` ends empty (or PRs are opened).
#
# Policy (Jeffrey, 2026-07-05, thread C0ALSKLU9KM ts 1782939949):
#   1. Load /ms context: search memory for prior art on "daily local file
#      triage", "git status cleanup", and any prior merges to origin/main.
#   2. Classify each modified or untracked file in ~/.smartclaw:
#        (A) RUNTIME ARTIFACT  — *.db, *.sqlite*, *.lock, *.pid, *.sqlite3,
#                                kanban.db*, verification_evidence.db*,
#                                *.dispatch.lock, anything with SQLite
#                                header   → add to .gitignore
#        (B) NESTED GIT REPO   — directory with its own .git/ subdir
#                                (e.g. rtk/) → add the whole tree to
#                                .gitignore AND surface as a finding
#                                (same hazard class as workspace/ git-clone
#                                ban in ~/.smartclaw/CLAUDE.md)
#        (C) SIMPLE CLEAN EDIT — single-file doc / skill / config edit,
#                                no secrets, no merge risk      → commit
#                                + push to origin main (DRY_RUN=0 only)
#        (D) COMPLEX           — multi-file, conflict risk, requires
#                                review                          → open PR
#   3. End state: `git status` MUST be empty OR open PRs MUST be reported.
#
# Safety:
#   DRY_RUN=1 (default) — preview only; no commit, no push, no PR.
#   DRY_RUN=0           — execute the policy; only safe in unattended
#                         daily runs (plist sets DRY_RUN=0).
#
# Logs:
#   ~/.smartclaw/logs/daily-local-triage.log   (human-readable)
#   ~/.smartclaw/logs/daily-local-triage.err   (errors)
#   ~/.smartclaw/logs/daily-local-triage.jsonl (one JSON record per tick)
#
# Sourceable: IS_SOURCED=1 source daily-local-triage.sh
#
# Exit codes:
#   0 = clean (nothing to do OR all changes triaged successfully)
#   1 = findings to surface (review needed)
#   2 = scan failure (hermes call crashed)

set -euo pipefail

# ── Force bash 4+ on macOS where /bin/bash is 3.2 ─────────────────────────
if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash "$HOME/.nvm/versions/node"/*/bin/bash; do
    if [[ -x "$candidate" ]]; then
      exec "$candidate" "$0" "$@"
    fi
  done
  echo "daily-local-triage: bash 4+ required (have bash ${BASH_VERSION}); no candidate found" >&2
  exit 2
fi

# ── Config ────────────────────────────────────────────────────────────────
HERMES_HOME="${HERMES_HOME:-${HOME}/.smartclaw}"
DRY_RUN="${DRY_RUN:-1}"
DAILY_TRIAGE_CHANNEL="${DAILY_TRIAGE_CHANNEL:-C0ALSKLU9KM}"
DAILY_TRIAGE_MAX_TURNS="${DAILY_TRIAGE_MAX_TURNS:-12}"
DAILY_TRIAGE_SKILLS="${DAILY_TRIAGE_SKILLS:-memory-search}"
DAILY_TRIAGE_CURL_BIN="${DAILY_TRIAGE_CURL_BIN:-curl}"
DAILY_TRIAGE_BOT_TOKEN="${DAILY_TRIAGE_BOT_TOKEN:-${SLACK_BOT_TOKEN:-${SLACK_BOT_TOKEN:-}}}"

LOG_DIR="$HERMES_HOME/logs"
JSONL="$LOG_DIR/daily-local-triage.jsonl"
LOG_FILE="$LOG_DIR/daily-local-triage.log"
ERR_FILE="$LOG_DIR/daily-local-triage.err"
mkdir -p "$LOG_DIR"
touch "$JSONL" "$LOG_FILE" "$ERR_FILE"

ts() { date '+%Y-%m-%dT%H:%M:%S%z'; }
log() { printf '[%s] %s\n' "$(ts)" "$*" >> "$LOG_FILE"; }
err() { printf '[%s] ERROR %s\n' "$(ts)" "$*" >> "$ERR_FILE" >&2; }

# ── Pre-flight ────────────────────────────────────────────────────────────
if [[ ! -d "$HERMES_HOME/.git" ]]; then
  err "preflight: $HERMES_HOME is not a git working tree"
  exit 2
fi
cd "$HERMES_HOME"

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo detached)"
GIT_IDENTITY_NAME="$(git config user.name 2>/dev/null || true)"
log "tick start: branch=$CURRENT_BRANCH identity=$GIT_IDENTITY_NAME dry_run=$DRY_RUN"

# Bail early if tree is already clean — no hermes call needed.
if git status --porcelain | grep -q .; then
  DIRTY_COUNT="$(git status --porcelain | wc -l | tr -d ' ')"
  log "tree is dirty: $DIRTY_COUNT entries"
else
  log "tree clean — nothing to do"
  jq -nc \
    --arg ts "$(ts)" \
    --arg branch "$CURRENT_BRANCH" \
    --argjson dry_run "$DRY_RUN" \
    '{ts, branch, dry_run, action: "noop_clean"}' >> "$JSONL"
  exit 0
fi

# ── Build the prompt ──────────────────────────────────────────────────────
read -r -d '' PROMPT <<PROMPT_EOF || true
You are running as an unattended daily launchd job in $HERMES_HOME.

STEP 1 — Context load (REQUIRED first step):
Use the memory_search skill to find prior art on:
  • "daily local file triage"
  • "git status cleanup hermes"
  • "merge straight to origin main" policy
  • "rtk nested git repo"
Quote any prior decisions that constrain what you do today.

STEP 2 — Inventory:
Run these and read carefully:
  cd $HERMES_HOME
  git status --porcelain --branch --untracked-files=all
  git diff --stat
  git rev-parse --abbrev-ref HEAD
  git config user.name && git config user.email

STEP 3 — Classify each modified/untracked entry as ONE of:

(A) RUNTIME ARTIFACT — *.db / *.sqlite / *.sqlite3 / *.lock / *.pid / *.dispatch.lock / kanban.db* / verification_evidence.db / any file with a SQLite magic header → append a gitignore line under a "# Runtime artifacts" block; do NOT commit.

(B) NESTED GIT REPO — a directory entry whose path is itself a git working tree (e.g. rtk/, anything with a nested .git/). Treat this as a HAZARD: the inner .git can shadow parent git operations. Add the whole directory to .gitignore AND emit a "HAZARD" finding.

(C) SIMPLE CLEAN EDIT — single-file edit in docs/, scripts/, skills/, launchd/, .claude/, SOUL.md/CLAUDE.md/, or any tracked text file; small diff; no secrets; no merge conflict potential → git add <file> && git commit -m "<type>: <short>" && git push origin HEAD:main. ONLY when DRY_RUN=0.

(D) COMPLEX — multi-file change, conflict risk, requires review → create branch triage/$(date +%Y%m%d)-<slug>, commit, push, gh pr create --base main, report PR URL.

STEP 4 — Finalize:
  • git status must be empty when you finish (modulo anything you intentionally left for the human).
  • Append ONE JSONL record to $JSONL using:
      jq -nc --arg ts "\$(date -Iseconds)" --argjson changes '<n>' --argjson actions '[...]' '{ts, changes, actions}' >> $JSONL
  • Exit 0 if everything triaged, exit 1 if anything needs human review.

PROTECTED PATHS — DO NOT TOUCH (always classify as a finding, never commit/push):
  • skills/.bundled_manifest
  • skills/.hub/lock.json
  • Any file under skills/ that contains the substring "auto-curated" or shows only
    hash/manifest-style diffs (this is hermes skill-curator output, not user work).
  • Any file added/updated by hermes mid-run (timestamp within last 30m and only
    the current process is the writer).
  → When you see these, classify as (E) HERMES_CURATED and emit a finding.

HARD CONSTRAINTS:
  • DRY_RUN=$DRY_RUN — if 1, do NOT commit, push, merge, or open PRs. Just classify + plan.
  • Never force-push.
  • Never edit SOUL.md or CLAUDE.md from this job (they are policy files; changes go through PR review).
  • Never touch cron/jobs.json or any tracked runtime artifact path.
  • If `git push origin HEAD:main` is rejected (e.g., requires review on protected branch), downgrade that file from (C) to (D) and open a PR instead.
  • Branch MUST be on a clean base (no upstream drift). If `git status --branch --porcelain` shows "behind", stop and emit a "behind origin" finding; do not push.
  • Identity MUST be ${GITHUB_USER} <${GITHUB_USER}@users.noreply.github.com>. If not, fix with `git config --local user.name ...` (do NOT touch global config).
  • When ambiguous, SURFACE the finding; do not invent intent.
PROMPT_EOF

# ── Invoke hermes ─────────────────────────────────────────────────────────
HERMES_RUN_LOG="$LOG_DIR/daily-local-triage-hermes.log"
log "calling hermes chat: skills=$DAILY_TRIAGE_SKILLS max_turns=$DAILY_TRIAGE_MAX_TURNS"

set +e
hermes chat \
  -q "$PROMPT" \
  --skills "$DAILY_TRIAGE_SKILLS" \
  --max-turns "$DAILY_TRIAGE_MAX_TURNS" \
  --accept-hooks \
  > "$HERMES_RUN_LOG" 2>&1
HERMES_EXIT=$?
set -e

if [[ $HERMES_EXIT -ne 0 ]]; then
  err "hermes chat exited $HERMES_EXIT; tail of run log:"
  tail -n 30 "$HERMES_RUN_LOG" >> "$ERR_FILE"
  jq -nc \
    --arg ts "$(ts)" \
    --arg branch "$CURRENT_BRANCH" \
    --argjson dry_run "$DRY_RUN" \
    --argjson hermes_exit "$HERMES_EXIT" \
    '{ts, branch, dry_run, action: "hermes_failed", hermes_exit}' >> "$JSONL"
  exit 2
fi

log "hermes chat completed"

# ── Post-state check ─────────────────────────────────────────────────────
POST_DIRTY="$(git status --porcelain | wc -l | tr -d ' ')"
POST_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo detached)"

jq -nc \
  --arg ts "$(ts)" \
  --arg branch "$POST_BRANCH" \
  --argjson dry_run "$DRY_RUN" \
  --argjson post_dirty "$POST_DIRTY" \
  '{ts, branch, dry_run, action: "ran", post_dirty}' >> "$JSONL"

log "tick end: branch=$POST_BRANCH post_dirty=$POST_DIRTY"

# Exit 1 if anything left dirty (review needed), 0 if clean.
if [[ "$POST_DIRTY" -gt 0 ]]; then
  exit 1
fi
exit 0