#!/usr/bin/env bash
# auto-push-to-main.sh
# Deterministic Git fast path for exporting a repository's tracked-file
# changes to origin/main. Runs on a schedule via launchd. On any mutating
# failure (add/commit/push/remote-verify), delegates recovery to the Go
# Agent Orchestrator adapter (scripts/ao-go-repo-recovery.sh) instead of
# calling a model CLI directly.
#
# Usage:
#   auto-push-to-main.sh <repo_path> <repo_name>
#   auto-push-to-main.sh --repo PATH:NAME [--repo PATH:NAME ...]
#
# Example: auto-push-to-main.sh ~/llm_wiki llm-wiki
#          auto-push-to-main.sh --repo ~/llm_wiki:llm-wiki --repo ~/roadmap:roadmap

set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin${PATH:+:$PATH}"

trap '' PIPE

# ── Shared Slack lib ──────────────────────────────────────────────────────────
# Source slack_thread_lib.sh so cronjob posts thread under a daily anchor instead
# of channel root. bead jleechan-ry3y follow-up to PR #615.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/lib"
# shellcheck source=lib/slack_thread_lib.sh
source "$LIB_DIR/slack_thread_lib.sh"

# ── Config ────────────────────────────────────────────────────────────────────
# AUTO_PUSH_LOG_DIR override keeps fixture tests from writing state into the
# real production log/state directory (a fixture repo name like "normal"
# would otherwise collide with real per-repo state keyed only by name).
# Deliberately NOT done by overriding $HOME: this repo's real global
# core.hooksPath (~/.gitconfig) is what proves the gitleaks pre-push guard
# actually ran during a fixture push — overriding $HOME would blind fixtures
# to that real hook and make "hooks are not bypassed" unfalsifiable.
LOG_DIR="${AUTO_PUSH_LOG_DIR:-${HOME}/.smartclaw/logs/scheduled-jobs}"
RUN_INTERVAL_SECS="${RUN_INTERVAL_SECS:-1800}"

GIT_EMAIL="${GIT_EMAIL:-$(git config user.email 2>/dev/null || echo ${GITHUB_USER}@users.noreply.github.com)}"
GIT_NAME="${GIT_NAME:-$(git config user.name 2>/dev/null || echo 'Auto-Push')}"

SLACK_CHANNEL="${SLACK_CHANNEL:-${SLACK_CHANNEL_ID}}"  # #antigravity

# AO Go recovery adapter — never a direct model CLI. Overridable for tests.
AUTO_PUSH_RECOVERY_BIN="${AUTO_PUSH_RECOVERY_BIN:-$SCRIPT_DIR/ao-go-repo-recovery.sh}"

mkdir -p "$LOG_DIR"

# ── Per-repository state (set at the top of each coordinator loop iteration) ──
REPO=""
REPO_NAME="unknown"
COMMIT_LOG=""
STATE_FILE=""

# ── Helpers ───────────────────────────────────────────────────────────────────
log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] [auto-push:${REPO_NAME}] $*" | tee -a "$COMMIT_LOG"; }

load_state() {
  if [[ -f "$STATE_FILE" ]]; then
    content="$(cat "$STATE_FILE" 2>/dev/null)" || content='{}'
    echo "$content" | jq -e '.' >/dev/null 2>&1 && echo "$content" || echo '{}'
  else
    echo '{}'
  fi
}

save_state() {
  local tmp
  tmp="$(mktemp "$STATE_FILE.XXXXXX")"
  cat > "$tmp" < /dev/stdin
  mv "$tmp" "$STATE_FILE"
}

was_run_recently() {
  local state last_ts now_sec ts_sec
  state="$(load_state)"
  last_ts="$(printf '%s' "$state" | jq -r '.last_run_ts // empty' 2>/dev/null)" || last_ts=""
  [[ -z "$last_ts" || "$last_ts" == "null" ]] && return 1
  now_sec="$(date +%s)"
  if [[ "$(uname -s)" == "Darwin" ]]; then
    ts_sec="$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_ts" '+%s' 2>/dev/null)" || return 1
  else
    ts_sec="$(date -d "$last_ts" '+%s' 2>/dev/null)" || return 1
  fi
  [[ $((now_sec - ts_sec)) -lt RUN_INTERVAL_SECS ]] && return 0
  return 1
}

record_run() {
  local now_iso
  now_iso="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  load_state | jq --arg ts "$now_iso" '.last_run_ts = $ts' | save_state
}

# ── Slack ─────────────────────────────────────────────────────────────────────
# Posts go through slack_post() from lib/slack_thread_lib.sh. The lib threads
# them under a per-job daily anchor (channel root on first post of the day,
# reply-thread on subsequent posts) and dedupes identical text within 60s.
notify() {
  local text="$1"
  # Outer wrapper [auto-push:...] goes on the slack_post side; we DO
  # NOT prepend it on the text passed in (the recovery_alert helper
  # composes its own bracketed prefix). Slack post is non-fatal.
  slack_post "auto-push-to-main" "${text}" --channel "$SLACK_CHANNEL" || \
    log "WARN: Slack notification failed"
  if [[ -n "${COMMIT_LOG:-}" ]]; then
    mkdir -p "$(dirname "$COMMIT_LOG")" 2>/dev/null || true
    printf '[%s] [notify] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$text" >>"$COMMIT_LOG" 2>/dev/null || true
  fi
}

# Defensive normalize: empty value, JSON `null`, or jq's literal
# "null" string all collapse to the placeholder "N-A". Map them all
# defensively so a missing field and a present-but-empty string both
# produce identical output.
_na() {
  local v="$1"
  case "$v" in
    ""|"null") printf 'N-A\n' ;;
    *)         printf '%s\n' "$v" ;;
  esac
}

# Read one field from a JSON state file, dropping JSON-quoted nulls
# so empty/null/present-empty/present-non-empty all reach _na cleanly.
_jq_field() {
  local path="$1" file="$2"
  jq -r "($path) // empty" "$file" 2>/dev/null || true
}

# Compose a single recovery Slack alert from the parsed AO Go state
# file. Arguments: $1=phase (added at RESTART/RECOVERY start, may be
# empty), $2=outcome (STARTED|RESOLVED|EXHAUSTED|UNAVAILABLE), $3=state
# file path (optional). Always includes the spec-required fields:
#   [auto-push:<repo>] <outcome> phase=<phase-or-N-A> session=<N-A|sid>
#   harnessTransition=<primary>-><final> finalSha=<N-A|sha>
# JSON-side empty values are normalized to the literal "N-A" -- the
# consumer never has to know which fields are unset vs. blank.
recovery_alert() {
  local phase_arg="${1:-}"
  local outcome="${2:-UNAVAILABLE}"
  local state_file="${3:-${RECOVERY_STATE_FILE:-}}"
  local phase_label session primary final_harness final_sha transition
  if [[ -n "$state_file" && -f "$state_file" ]] && command -v jq >/dev/null 2>&1; then
    local raw_phase raw_session raw_primary raw_harness raw_sha
    raw_phase="$(_jq_field '.phase'      "$state_file")"
    raw_session="$(_jq_field '.sessionId'  "$state_file")"
    raw_primary="$(_jq_field '.primaryHarness' "$state_file")"
    raw_harness="$(_jq_field '.harness'    "$state_file")"
    raw_sha="$(_jq_field '.finalSha'    "$state_file")"
    # Empty phase falls back to the caller's phase_arg so the alert
    # always carries the phase the caller intended.
    phase_label="$(_na "${raw_phase:-$phase_arg}")"
    session="$(_na "$raw_session")"
    primary="$(_na "$raw_primary")"
    final_harness="$(_na "$raw_harness")"
    final_sha="$(_na "$raw_sha")"
    if [[ "$primary" == "N-A" || "$primary" == "$final_harness" ]]; then
      transition="$final_harness"
    else
      transition="${primary}->${final_harness}"
    fi
  else
    phase_label="$(_na "$phase_arg")"
    session="N-A"
    primary="N-A"
    final_harness="N-A"
    final_sha="N-A"
    transition="N-A"
  fi
  printf '[auto-push:%s] %s phase=%s session=%s harnessTransition=%s finalSha=%s' \
    "$REPO_NAME" "$outcome" "$phase_label" "$session" "$transition" "$final_sha"
}

# Deterministic, owned-hook failure classification for a push rejection —
# matches the OWNED hook's own fixed, anchored protocol marker line, never
# an absence-based heuristic. An earlier version of this function classified
# by the ABSENCE of git's non-fast-forward hint text, on the theory that
# only a hook rejection would lack it — that is unsafe: a network/auth
# failure or any OTHER unrelated hook also lacks that hint and would be
# silently mislabeled "gitleaks". The only correct signal is the exact line
# this repo's configured secret-scan hook
# (~/.config/git/hooks/secret-scan.sh) itself emits on its own die() path —
# a stable interface contract we own, not a semantic guess at hook wording
# in general. Every other push failure (ordinary conflict, network, auth,
# an unrelated hook) stays phase "push".
classify_push_failure() {
  local push_output="$1"
  if printf '%s\n' "$push_output" | grep -qE '^git secret guard: push blocked by secret scan for origin '; then
    echo "gitleaks"
    return
  fi
  echo "push"
}

# ── AO Go recovery ────────────────────────────────────────────────────────────
# Delegates exceptional recovery (conflicts, hook failures, secret-scan
# blockers) to the Go Agent Orchestrator control plane. Never calls a model
# CLI directly. Exits 0 only when the adapter has verified fetched local
# HEAD equals origin/main; any other outcome is a failure.
run_recovery() {
  local phase="$1" error_text="$2"

  if [[ ! -x "$AUTO_PUSH_RECOVERY_BIN" ]]; then
    log "ERROR: AO Go recovery adapter not available/executable: $AUTO_PUSH_RECOVERY_BIN"
    # Inside run_recovery we have the real failed phase; preserve it
    # in the alert so operators can attribute it correctly. Static
    # pre-do_push failures (below) use phase=preflight instead.
    notify "$(recovery_alert "$phase" UNAVAILABLE)" || true
    return 1
  fi

  # PHASE must be in the exact supported set; the adapter validates it
  # independently, but validating here too avoids spawning a useless
  # subprocess when a coordinator-internal typo slipped through.
  case "$phase" in
    add|commit|push|gitleaks|verify) : ;;
    *) log "ERROR: refusing unknown phase [$phase] (not in add|commit|push|gitleaks|verify)"; return 1 ;;
  esac

  local error_file
  error_file="$(mktemp "${TMPDIR:-/tmp}/auto-push-recovery-error.XXXXXX")"
  printf '%s\n' "$error_text" >"$error_file"

  log "RECOVERY: delegating phase=${phase} to AO Go adapter"

  # Recovery adapter writes its state JSON to a path keyed by the
  # SANITIZED name, matching how the adapter itself keys STATE_FILE.
  RECOVERY_STATE_FILE="${LOG_DIR}/ao-recovery-${SAFE_REPO_NAME}-state.json"
  rm -f "$RECOVERY_STATE_FILE" 2>/dev/null || true

  # Phase start alert: composed from our local coordinator state
  # (REPO_NAME + phase only) -- the adapter state file does not yet
  # exist, so every field falls back to N-A per the spec. Two distinct
  # notifications per phase: STARTED + terminal.
  notify "$(recovery_alert "$phase" STARTED)" || true
  local rc=0
  "$AUTO_PUSH_RECOVERY_BIN" --repo "$REPO" --name "$SAFE_REPO_NAME" --phase "$phase" --error-file "$error_file" \
    2>&1 | tee -a "$COMMIT_LOG" || rc=1
  rm -f "$error_file"

  if [[ "$rc" -eq 0 ]]; then
    log "RECOVERY: adapter reported success for phase=${phase}"
    notify "$(recovery_alert "$phase" RESOLVED "$RECOVERY_STATE_FILE")" || true
  else
    log "RECOVERY: adapter did not resolve phase=${phase}"
    notify "$(recovery_alert "$phase" EXHAUSTED "$RECOVERY_STATE_FILE")" || true
  fi
  return "$rc"
}

# ── Git helpers ───────────────────────────────────────────────────────────────
has_changes() {
  cd "$REPO" || return 1
  [[ -n "$(git status --porcelain)" ]]
}

tracked_changes() {
  cd "$REPO" || return 1
  git diff --name-only HEAD 2>/dev/null
  git diff --cached --name-only HEAD 2>/dev/null
}

untracked_files() {
  cd "$REPO" || return 1
  git ls-files --others --exclude-standard 2>/dev/null
}

repo_allows_untracked() {
  local name="$1"
  case "$name" in
    llm-wiki|roadmap) return 0 ;;
    *) return 1 ;;
  esac
}

# ── Push logic ────────────────────────────────────────────────────────────────
do_push() {
  cd "$REPO" || { log "ERROR: cannot cd to $REPO"; notify "$(recovery_alert preflight UNAVAILABLE)" || true; return 1; }

  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    log "ERROR: not a git repo: $REPO"
    notify "$(recovery_alert preflight UNAVAILABLE)" || true
    return 1
  fi

  if ! git remote get-url origin >/dev/null 2>&1; then
    log "ERROR: no 'origin' remote configured for $REPO"
    notify "$(recovery_alert preflight UNAVAILABLE)" || true
    return 1
  fi

  if [[ -e .git/MERGE_HEAD || -d .git/rebase-merge || -d .git/rebase-apply ]]; then
    log "ERROR: repository is mid-merge/rebase, refusing to touch: $REPO"
    notify "$(recovery_alert preflight UNAVAILABLE)" || true
    return 1
  fi

  # C — branch invariant (skeptic round 2): fail before git add when the
  # current checkout is not symbolic main. A feature-branch or detached
  # HEAD that gets committed+pushed from this fast path would silently
  # rewrite the production branch with a commit never intended for it.
  # Recovery catches the same case, but only AFTER the agent has run --
  # catch it here so the wrong branch is never touched in the first place.
  local current_branch
  current_branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || echo detached)"
  if [[ "$current_branch" != "main" ]]; then
    log "ERROR: refusing to push: $REPO is on [$current_branch], expected main"
    notify "$(recovery_alert preflight UNAVAILABLE)" || true
    return 1
  fi

  log "Fetching origin/main..."
  local fetch_output
  fetch_output="$(git fetch --prune origin main 2>&1)" || {
    log "ERROR: git fetch failed: $(echo "$fetch_output" | tail -5)"
    # Static terminal failure (preflight): origin/main fetch is a hard
    # prerequisite for the entire run.
    notify "$(recovery_alert preflight UNAVAILABLE)" || true
    return 1
  }

  # Configure git identity if not set
  git config user.email "$GIT_EMAIL" 2>/dev/null || true
  git config user.name "$GIT_NAME" 2>/dev/null || true

  local changed_files untracked_count
  changed_files="$(tracked_changes | sort -u | sed '/^$/d')" || true
  untracked_count="$(untracked_files | wc -l | tr -d ' ' 2>/dev/null || echo '0')"

  if [[ -z "$changed_files" && "$untracked_count" == "0" ]]; then
    # Local working tree is clean AND there are no untracked files.
    # But that does NOT necessarily mean the export is finished: the
    # user may have committed locally and never pushed. Detect local-
    # ahead-of-remote (committed work that needs publication) so we
    # push it through the hook-enabled `git push` path and recover on
    # failure. A merely-behind local (cleanly fast-forwardable) needs
    # no action here.
    local local_sha remote_sha
    local_sha="$(git rev-parse HEAD)"
    remote_sha="$(git rev-parse refs/remotes/origin/main 2>/dev/null || echo "")"
    if [[ -z "$remote_sha" ]]; then
      log "No tracking branch on origin/main yet — nothing to verify"
      return 0
    fi
    if [[ "$local_sha" == "$remote_sha" ]]; then
      log "No changes — local already at origin/main"
      return 0
    fi
    if git merge-base --is-ancestor "$local_sha" "$remote_sha" 2>/dev/null; then
      log "No changes — local is behind origin/main (will catch up on next export that needs this)"
      return 0
    fi
    # Local is AHEAD or DIVERGED from origin/main and the working tree
    # is clean: this is an unpublished local commit that must be pushed.
    if git merge-base --is-ancestor "$remote_sha" "$local_sha" 2>/dev/null; then
      log "Local $local_sha is fast-forward ahead of origin/main $remote_sha; pushing"
    else
      log "Local $local_sha has diverged from origin/main $remote_sha; pushing non-FF may fail and trigger recovery"
    fi
    local push_output
    push_output="$(git push origin HEAD:main 2>&1)" || {
      log "ERROR: local-ahead push failed: $(echo "$push_output" | tail -5)"
      [[ -n "$push_output" ]] && log "push hook output: $push_output"
      run_recovery "$(classify_push_failure "$push_output")" "git push origin HEAD:main failed (local-ahead): $push_output" && return 0
      return 1
    }
    [[ -n "$push_output" ]] && log "push hook output: $push_output"
    # Confirm convergence by a FRESH fetch -- fail closed if the fetch
    # itself cannot complete (we cannot verify SHA convergence without
    # fresh data from origin).
    git fetch --prune origin main >/dev/null 2>&1 \
      || { log "ERROR: fresh git fetch failed after local-ahead push; cannot verify convergence"; return 1; }
    local local_after remote_after
    local_after="$(git rev-parse HEAD)"
    remote_after="$(git rev-parse refs/remotes/origin/main 2>/dev/null || echo "")"
    if [[ "$local_after" != "$remote_after" || "$remote_after" == "$remote_sha" ]]; then
      log "ERROR: local-ahead push completed but SHAs did NOT converge (local=$local_after remote=$remote_after)"
      return 1
    fi
    log "Push successful and verified (local=$local_after remote=$remote_after)"
    notify "[auto-push:${REPO_NAME}] RESOLVED phase=fast-path session=N-A harnessTransition=N-A finalSha=${remote_after}" || true
    return 0
  fi

  if [[ -z "$changed_files" && "$untracked_count" != "0" ]]; then
    if ! repo_allows_untracked "$REPO_NAME"; then
      # Local working tree has BOTH unpublished commits AND untracked
      # files. Push the commits first (so we don't block forever on the
      # untracked side), then emit the untracked-only warning so the
      # operator knows the untracked content was not exported.
      local untracked_remote_sha
      untracked_remote_sha="$(git rev-parse refs/remotes/origin/main 2>/dev/null || echo "")"
      local local_sha_u
      local_sha_u="$(git rev-parse HEAD)"
      if [[ -n "$untracked_remote_sha" && "$local_sha_u" != "$untracked_remote_sha" ]] \
          && ! git merge-base --is-ancestor "$local_sha_u" "$untracked_remote_sha" 2>/dev/null; then
        local u_push
        local u_push_failed=0
        u_push="$(git push origin HEAD:main 2>&1)" || u_push_failed=1
        if [[ "$u_push_failed" -eq 1 ]]; then
          log "ERROR: local-ahead push (mixed untracked) failed: $(echo "$u_push" | tail -5)"
          [[ -n "$u_push" ]] && log "push hook output: $u_push"
          if run_recovery "$(classify_push_failure "$u_push")" "git push origin HEAD:main failed (mixed untracked): $u_push"; then
            local_sha_u="$(git rev-parse HEAD)"
          else
            local recovery_rc=$?
            local final_sha_a
            final_sha_a="$(git rev-parse refs/remotes/origin/main 2>/dev/null || echo 'N-A')"
            notify "[auto-push:${REPO_NAME}] SKIPPED phase=untracked-only session=N-A harnessTransition=N-A finalSha=${final_sha_a}" || true
            return "$recovery_rc"
          fi
        fi
        if ! git fetch --prune origin main >/dev/null 2>&1; then
          log "ERROR: fresh git fetch failed after mixed-untracked push; cannot verify convergence"
          local final_sha_b
          final_sha_b="$(git rev-parse refs/remotes/origin/main 2>/dev/null || echo 'N-A')"
          notify "[auto-push:${REPO_NAME}] SKIPPED phase=untracked-only session=N-A harnessTransition=N-A finalSha=${final_sha_b}" || true
          return 1
        fi
        local fresh_remote_sha_after_push
        fresh_remote_sha_after_push="$(git rev-parse refs/remotes/origin/main 2>/dev/null || echo "")"
        if [[ "$fresh_remote_sha_after_push" != "$local_sha_u" ]]; then
          log "ERROR: SHAs did NOT converge after mixed-untracked push (local=$local_sha_u remote=$fresh_remote_sha_after_push, was=$untracked_remote_sha)"
          local final_sha_c
          final_sha_c="$(git rev-parse refs/remotes/origin/main 2>/dev/null || echo 'N-A')"
          notify "[auto-push:${REPO_NAME}] SKIPPED phase=untracked-only session=N-A harnessTransition=N-A finalSha=${final_sha_c}" || true
          return 1
        fi
      fi
      log "Only untracked files remain after pushing unpublished commits; emitting untracked-only alert"
      local final_sha_success
      final_sha_success="$(git rev-parse refs/remotes/origin/main 2>/dev/null || echo 'N-A')"
      notify "[auto-push:${REPO_NAME}] SKIPPED phase=untracked-only session=N-A harnessTransition=N-A finalSha=${final_sha_success}" || true
      return 0
    fi
  fi

  # Stage files (all files if allowlisted, tracked-only otherwise)
  if repo_allows_untracked "$REPO_NAME"; then
    log "Staging all repository changes (allowlisted: ${REPO_NAME})..."
    local add_output
    add_output="$(git add -A 2>&1)" || {
      log "ERROR: git add -A failed: $add_output"
      run_recovery "add" "git add -A failed: $add_output" && return 0
      return 1
    }
  else
    log "Staging tracked files..."
    local add_output
    add_output="$(git add -u 2>&1)" || {
      log "ERROR: git add -u failed: $add_output"
      run_recovery "add" "git add -u failed: $add_output" && return 0
      return 1
    }
  fi

  if git diff --cached --quiet 2>/dev/null; then
    log "No staged changes — up to date"
    return 0
  fi

  local file_count
  file_count="$(git diff --cached --name-only | wc -l | tr -d ' ' || echo '?')"

  local commit_msg="[Auto] Pending changes $(date '+%Y-%m-%d %H:%M')"
  log "Committing: $commit_msg ($file_count file(s))"

  local commit_output
  commit_output="$(git commit -m "$commit_msg" 2>&1)" || {
    log "ERROR: git commit failed: $(echo "$commit_output" | tail -5)"
    run_recovery "commit" "git commit failed: $commit_output" && return 0
    return 1
  }

  log "Pushing to origin main..."
  local push_output
  push_output="$(git push origin HEAD:main 2>&1)" || {
    log "ERROR: git push failed: $(echo "$push_output" | tail -5)"
    run_recovery "$(classify_push_failure "$push_output")" "git push origin HEAD:main failed: $push_output" && return 0
    return 1
  }
  # Surface hook output (e.g. the global pre-push secret-scan guard) instead
  # of silently swallowing it inside the command substitution above.
  [[ -n "$push_output" ]] && log "push hook output: $push_output"

  git fetch --prune origin main >/dev/null 2>&1 \
    || { log "ERROR: fresh git fetch failed; cannot verify convergence"; return 1; }
  local local_sha remote_sha
  local_sha="$(git rev-parse HEAD)"
  remote_sha="$(git rev-parse refs/remotes/origin/main 2>/dev/null || echo "")"
  if [[ "$local_sha" != "$remote_sha" ]]; then
    log "ERROR: remote verification failed local=$local_sha remote=$remote_sha"
    run_recovery "verify" "remote verification failed local=$local_sha remote=$remote_sha" && return 0
    return 1
  fi

  log "Push successful and verified (local=$local_sha remote=$remote_sha)"
  # Fast-path success alert: same canonical format as recovery_alert
  # uses -- repo, phase=fast-path, session=N-A, harnessTransition=N-A,
  # finalSha=<freshly fetched remote SHA>. The fetched SHA is the same
  # one used for verification two lines above, so it is verified.
  notify "[auto-push:${REPO_NAME}] RESOLVED phase=fast-path session=N-A harnessTransition=N-A finalSha=${remote_sha}" || true
  return 0
}

# ── Per-repository lock (overlap guard) ────────────────────────────────────────
declare -a ACQUIRED_LOCKS=()

cleanup_locks() {
  local d
  for d in "${ACQUIRED_LOCKS[@]:-}"; do
    [[ -n "$d" ]] && rmdir "$d" 2>/dev/null || true
  done
}
trap cleanup_locks EXIT

acquire_lock() {
  local lockdir="$1"
  if ! mkdir "$lockdir" 2>/dev/null; then
    return 1
  fi
  ACQUIRED_LOCKS+=("$lockdir")
  return 0
}

release_lock() {
  local lockdir="$1"
  rmdir "$lockdir" 2>/dev/null || true
}

# ── Argument parsing: legacy two-arg interface or --repo coordinator ──────────
declare -a REPO_SPECS=()
if [[ "${1:-}" == "--repo" ]]; then
  while [[ "${1:-}" == "--repo" ]]; do
    [[ -n "${2:-}" && "$2" == *:* ]] || { echo "--repo requires PATH:NAME" >&2; exit 2; }
    REPO_SPECS+=("$2")
    shift 2
  done
  [[ $# -eq 0 ]] || { echo "unexpected arguments: $*" >&2; exit 2; }
else
  if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <repo_path> <repo_name> | --repo PATH:NAME [--repo PATH:NAME ...]" >&2
    exit 1
  fi
  REPO_SPECS+=("$1:$2")
fi

# ── Main coordinator loop ──────────────────────────────────────────────────────

# Allowlist validation for REPO_NAME: must match exactly
# /^[A-Za-z0-9_-]+$/ with no characters removed, no lossy sanitization.
# The two production names that satisfy it today are `llm-wiki` and
# `roadmap`. Reject any name that would CHANGE under lossy
# sanitization -- silently dropping characters can mask typos and
# collide two previously-distinct names on the same LOCK_DIR. The
# adapter independently enforces this same exact allowlist as a
# defense-in-depth check on its own -- nothing here trusts the other.
safe_repo_name() {
  local raw="$1"
  if [[ -z "$raw" ]] || ! [[ "$raw" =~ ^[A-Za-z0-9_-]+$ ]]; then
    return 1
  fi
  printf '%s\n' "$raw"
}

OVERALL_FAILED=0

for spec in "${REPO_SPECS[@]}"; do
  REPO="${spec%:*}"
  REPO_NAME="${spec##*:}"
  if ! SAFE_REPO_NAME="$(LC_ALL=C safe_repo_name "$REPO_NAME")"; then
    # Print directly to stderr -- this happens BEFORE COMMIT_LOG is
    # opened, so `log ... | tee -a` would silently drop a half-line.
    # Continue the loop so a bad spec cannot abort processing of the
    # remaining specs in the same coordinator invocation.
    printf 'ERROR: refusing repo spec [%s]: REPO_NAME [%s] must match ^[A-Za-z0-9_-]+$\n' \
      "$spec" "$REPO_NAME" >&2
    OVERALL_FAILED=1
    continue
  fi
  LOCK_DIR="${TMPDIR:-/tmp}/auto-push-${SAFE_REPO_NAME}.lock"
  COMMIT_LOG="${LOG_DIR}/auto-push-${SAFE_REPO_NAME}.log"
  STATE_FILE="${LOG_DIR}/auto-push-${SAFE_REPO_NAME}-state.json"

  if ! acquire_lock "$LOCK_DIR"; then
    log "SKIP: another instance running for ${REPO_NAME}"
    continue
  fi

  log "Starting auto-push (interval=${RUN_INTERVAL_SECS}s, repo=${REPO})"

  if was_run_recently; then
    log "SKIP: ran recently (within ${RUN_INTERVAL_SECS}s)"
    release_lock "$LOCK_DIR"
    continue
  fi

  if do_push; then
    record_run
    log "Done"
  else
    log "ERROR: push failed for ${REPO_NAME}"
    OVERALL_FAILED=1
  fi

  release_lock "$LOCK_DIR"
done

exit "$OVERALL_FAILED"
