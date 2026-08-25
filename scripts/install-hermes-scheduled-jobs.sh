#!/usr/bin/env bash
# Install Hermes scheduled jobs as launchd plists (macOS).
# Migrates infrastructure/health jobs from gateway-cron to launchd.
# See scripts/daily-hermes-research.sh for the research job script.
#
# live-vs-tracked distinction:
#   ~/.smartclaw/cron/jobs.json  -- LIVE, gitignored; gateway-managed PR automation jobs
#                                  (e.g. thread-followup-*, pr-monitor-*). These stay in
#                                  gateway cron and are NOT migrated to launchd.
#   launchd/                     -- TRACKED in repo; infrastructure/health/scheduled
#                                  review jobs (morning-log-review, weekly-error-trends,
#                                  docs-drift-review, cron-backup-sync, daily-research,
#                                  bug-hunt, harness-analyzer, orch-health-weekly).
#
# The gateway-cron jobs that remain live (NOT migrated):
#   - thread-followup-ao263      (ad-hoc, short-lived; gateway owns lifecycle)
#   - Any future pr-automation jobs (managed by AO lifecycle-worker)
set -euo pipefail

# OS detection -- Linux delegates to install-launchagents.sh Linux path
case "$(uname -s)" in
  Darwin) OS="macos" ;;
  Linux)  OS="linux" ;;
  *) echo "Unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Default-preserving seams: callers (including tests) can override by
# exporting LAUNCHD_TEMPLATES_DIR / LAUNCHD_DIR BEFORE running this
# script. These are the ONLY installer-side seams -- CRON_JOBS_FILE /
# HERMES_OPS_DIR are LIVE production paths that must NEVER be
# redirectable for tests; any installer run that touches them is a
# live migration.
LAUNCHD_TEMPLATES_DIR="${LAUNCHD_TEMPLATES_DIR:-$REPO_ROOT/launchd}"
LAUNCHD_DIR="${LAUNCHD_DIR:-$HOME/Library/LaunchAgents}"
LIVE_DIR="$HOME/.smartclaw"
LIVE_JOBS="$LIVE_DIR/cron/jobs.json"
SCHEDULED_LOG_DIR="$LIVE_DIR/logs/scheduled-jobs"

# Non-mutating test seam: render + lint every plist into an isolated $HOME
# without calling launchctl, mutating live cron JSON, or signaling the
# gateway. Used to prove the daily-repo-export template renders correctly
# before any production installation.
INSTALL_DRY_RUN="${INSTALL_DRY_RUN:-0}"
INSTALL_READY_MAX_POLLS="${INSTALL_READY_MAX_POLLS:-5}"
INSTALL_CANARY_MAX_POLLS="${INSTALL_CANARY_MAX_POLLS:-60}"

# AO Go binary used by the daily repository export job's recovery adapter
# (scripts/ao-go-repo-recovery.sh). Resolved from an explicit environment
# value or the stable default install path; validated before the daily
# plist is rendered so a missing/wrong binary fails loudly at install time
# instead of silently at 3:20am.
AO_GO_BIN="${AO_GO_BIN:-$HOME/.local/bin/ao-go}"
EXPECTED_AO_MODULE_PATH="github.com/aoagents/agent-orchestrator/backend/cmd/ao"
AO_GO_INSPECT_BIN=""
for go_candidate in /opt/homebrew/bin/go /usr/local/go/bin/go /usr/local/bin/go; do
  if [[ -x "$go_candidate" ]]; then AO_GO_INSPECT_BIN="$go_candidate"; break; fi
done

ao_go_bin_valid() {
  [[ -x "$AO_GO_BIN" ]] || return 1
  if head -c 64 "$AO_GO_BIN" 2>/dev/null | grep -Eq '^#!.*(node|env node)'; then
    return 1
  fi
  [[ -x "$AO_GO_INSPECT_BIN" ]] || return 1
  local build_info
  build_info="$("$AO_GO_INSPECT_BIN" version -m "$AO_GO_BIN" 2>/dev/null)" || return 1
  printf '%s\n' "$build_info" \
    | awk '/^[[:space:]]*path[[:space:]]+/ {print $2}' \
    | grep -Fxq "$EXPECTED_AO_MODULE_PATH"
}

# Job IDs migrated from gateway cron to launchd (will be disabled in jobs.json).
# Format: parallel indexed arrays, NOT a bash-4 associative array, so
# the script stays compatible with macOS /bin/bash 3.2.
#
# DEFAULT_* arrays are IMMUTABLE in this script -- they back the ID-to-
# plist mapping exposed by migrated_target() and the iteration in
# default_migrated_job_ids(). Mutating them from any read-from-live-
# JSON code path would silently break index alignment between IDs and
# target plists.
#
# The LIVE/OVERRIDE list is MIGRATED_JOB_IDS (mutable; populated by
# load_migrated_job_ids() to the IDs actually present in the user's
# live jobs.json so the disable step touches only what exists).
DEFAULT_MIGRATED_JOB_IDS=(
  "c0accca2-3b58-4da6-ba84-e8c929387e30"
  "4ec2aa58-5c97-4c46-8775-a7f030d1dec6"
  "95f858df-0fe8-4434-90c9-c5c89f61889e"
  "d6bb3693-9f5c-4a4e-99ed-bc56eb33e35c"
  "abf80788-7bb0-4ce7-9e09-6c1a97faa5cd"
)
DEFAULT_MIGRATED_TARGET_PLISTS=(
  "ai.smartclaw.schedule.morning-log-review"
  "ai.smartclaw.schedule.weekly-error-trends"
  "ai.smartclaw.schedule.docs-drift-review"
  "ai.smartclaw.schedule.cron-backup-sync"
  "ai.smartclaw.schedule.daily-research"
)
# Mutable: populated by load_migrated_job_ids().
MIGRATED_JOB_IDS=()

# Resolve a gateway job ID -> its launchd target plist basename. Reads
# ONLY the immutable defaults, never the live override list.
migrated_target() {
  local id="$1"
  local i
  for i in "${!DEFAULT_MIGRATED_JOB_IDS[@]}"; do
    if [[ "${DEFAULT_MIGRATED_JOB_IDS[$i]}" == "$id" ]]; then
      printf '%s\n' "${DEFAULT_MIGRATED_TARGET_PLISTS[$i]}"
      return 0
    fi
  done
  return 1
}

default_migrated_job_ids() {
  local id
  for id in "${DEFAULT_MIGRATED_JOB_IDS[@]}"; do
    echo "$id"
  done
}

load_migrated_job_ids() {
  MIGRATED_JOB_IDS=()
  local live_ids=""
  # Read migrated IDs from the live jobs.json (gitignored -- the canonical source)
  live_ids="$(jq -r '.migratedLaunchdJobIds[]?' "$LIVE_JOBS" 2>/dev/null || true)"
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    if ! migrated_target "$id" >/dev/null; then
      echo "Error: refusing unknown migratedLaunchdJobId: $id" >&2
      return 1
    fi
    MIGRATED_JOB_IDS+=("$id")
  done <<<"$live_ids"

  if [[ -z "$live_ids" ]]; then
    while IFS= read -r id; do
      [[ -n "$id" ]] && MIGRATED_JOB_IDS+=("$id")
    done < <(default_migrated_job_ids)
  fi
}

export_repo_converged() {
  local repo="$1"
  [[ "$(git -C "$repo" symbolic-ref --quiet --short HEAD 2>/dev/null || true)" == "main" ]] || return 1
  git -C "$repo" fetch --prune origin main >/dev/null 2>&1 || return 1
  [[ -z "$(git -C "$repo" status --porcelain --untracked-files=no 2>/dev/null)" ]] || return 1
  [[ "$(git -C "$repo" rev-parse HEAD 2>/dev/null || true)" \
      == "$(git -C "$repo" rev-parse refs/remotes/origin/main 2>/dev/null || true)" ]]
}

detect_local_timezone() {
  local target
  target="$(readlink /etc/localtime 2>/dev/null || true)"
  if [[ "$target" == *"/zoneinfo/"* ]]; then
    echo "${target##*/zoneinfo/}"
    return 0
  fi
  echo "${TZ:-unknown}"
}

# Validate required tools before mutating anything (avoids half-migrated state)
if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required but not installed. Install with: brew install jq (macOS) or apt install jq (Linux)" >&2
  exit 1
fi
if [[ "$OS" == "macos" ]] && ! command -v launchctl >/dev/null 2>&1; then
  echo "Error: launchctl is required on macOS" >&2
  exit 1
fi
if [[ "$OS" == "linux" ]]; then
  echo "Note: On Linux, scheduled jobs are installed via install-launchagents.sh (systemd timers)."
  echo "This script manages the launchd-to-gateway-cron migration step only."
fi

# Detect hermes binary location so launchd PATH gets the right dir injected.
# launchd does not inherit the user's shell PATH, so nvm/pyenv/bun-installed
# binaries are invisible unless we add their directory explicitly here.
detect_hermes_extra_path() {
  local bin_path bin_dir
  bin_path="$(command -v hermes 2>/dev/null || true)"
  if [[ -z "$bin_path" ]]; then
    echo ""
    return
  fi
  bin_dir="$(dirname "$bin_path")"
  case ":$HOME/.bun/bin:$HOME/.local/bin:$HOME/bin:$HOME/Library/pnpm:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" in
    *":${bin_dir}:"*) echo "" ;;
    *)                echo "${bin_dir}:" ;;
  esac
}

HERMES_EXTRA_PATH="$(detect_hermes_extra_path)"
# Normalize: strip any trailing colon, then add exactly one so the PATH concat is safe
if [[ -n "$HERMES_EXTRA_PATH" ]]; then
  HERMES_EXTRA_PATH="${HERMES_EXTRA_PATH%:}:"
fi

# Detect gog binary location — required by gmail-daily-recap.sh
detect_gog_extra_path() {
  local bin_path bin_dir
  bin_path="$(command -v gog 2>/dev/null || true)"
  if [[ -z "$bin_path" ]]; then
    echo ""
    return
  fi
  bin_dir="$(dirname "$bin_path")"
  case ":$HOME/.bun/bin:$HOME/.local/bin:$HOME/bin:$HOME/Library/pnpm:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" in
    *":${bin_dir}:"*) echo "" ;;
    *)                echo "${bin_dir}:" ;;
  esac
}

GOG_EXTRA_PATH="$(detect_gog_extra_path)"
if [[ -n "$GOG_EXTRA_PATH" ]]; then
  GOG_EXTRA_PATH="${GOG_EXTRA_PATH%:}:"
fi

if [[ "$OS" == "linux" ]]; then
  echo "Linux: scheduled jobs handled by install-launchagents.sh (systemd timers)."
  exit 0
fi

printf 'Installing Hermes launchd scheduled jobs\n'
printf 'Repo: %s\n\n' "$REPO_ROOT"

mkdir -p "$LAUNCHD_DIR" "$LIVE_DIR" "$LIVE_DIR/cron" "$LIVE_DIR/scripts" "$SCHEDULED_LOG_DIR"

# Install job scripts (morning-log-review, weekly-error-trends, etc.)
echo "Installing job scripts..."
declare -a JOB_SCRIPTS=(
  "$REPO_ROOT/scripts/morning-log-review.sh"
  "$REPO_ROOT/scripts/weekly-error-trends.sh"
  "$REPO_ROOT/scripts/docs-audit.sh"
  "$REPO_ROOT/scripts/cron-backup-sync.sh"
  "$REPO_ROOT/scripts/docs-drift-review.sh"
  "$REPO_ROOT/scripts/daily-hermes-research.sh"
  "$REPO_ROOT/scripts/bug-hunt-daily.sh"
  "$REPO_ROOT/scripts/harness-analyzer.sh"
  "$REPO_ROOT/scripts/gmail-daily-recap.sh"
  "$REPO_ROOT/scripts/composio-upstream-reminder.sh"
  "$REPO_ROOT/scripts/commit-pending-changes.sh"
  "$REPO_ROOT/scripts/hermes-canary.sh"
  "$REPO_ROOT/scripts/hermes-health.sh"
  "$REPO_ROOT/scripts/gh-actions-cost-monitor.sh"
  "$REPO_ROOT/scripts/spend-alert-daily.sh"
  "$REPO_ROOT/scripts/beads-conflict-resolver.sh"
  "$REPO_ROOT/scripts/beads-conflict-resolver.launchd.sh"
  "$REPO_ROOT/scripts/orchestration_slack_catchup_daily.sh"
  "$REPO_ROOT/scripts/orchestration_thread_lifecycle.sh"
  "$REPO_ROOT/scripts/auto-push-to-main.sh"
  "$REPO_ROOT/scripts/ao-go-repo-recovery.sh"
)
for script in "${JOB_SCRIPTS[@]}"; do
  if [[ ! -f "$script" ]]; then
    echo "ERROR: required script missing: $script" >&2
    exit 1
  fi
  if [[ ! -x "$script" ]]; then
    echo "ERROR: script is not executable: $script" >&2
    exit 1
  fi
  dst="$LIVE_DIR/scripts/$(basename "$script")"
  # When the repo lives at ~/.smartclaw, REPO_ROOT/scripts and LIVE_DIR/scripts are the same path;
  # BSD install(1) errors with "same file" and a non-zero exit.
  if [[ "$(realpath "$script" 2>/dev/null)" != "$(realpath "$dst" 2>/dev/null)" ]]; then
    install -m 755 "$script" "$dst"
  fi
  echo "  - installed $(basename "$script")"
done

# Render and load each scheduled plist template (or standalone .plist without .template)
_install_plist() {
  local src="$1"
  local label
  if [[ "$src" == *.plist.template ]]; then
    label="$(basename "$src" .plist.template)"
  else
    label="$(basename "$src" .plist)"
  fi

  # Fail fast (not at 3:20am) if the daily export job's AO Go binary is
  # missing or is the rejected Node CLI. Every other job is unaffected.
  if [[ "$label" == "ai.smartclaw.schedule.daily-repo-export" || "$label" == "ai.agento.ao-go-daemon" ]] \
      && ! ao_go_bin_valid; then
    echo "  ✗ $label SKIPPED — AO_GO_BIN invalid or missing: $AO_GO_BIN" >&2
    return 1
  fi

  local dst="$LAUNCHD_DIR/$label.plist"
  local tmp
  tmp="$(mktemp "$LAUNCHD_DIR/.${label}.XXXXXX.plist")" || return 1

  if ! sed \
      -e "s|@HOME@|$HOME|g" \
      -e "s|@HERMES_EXTRA_PATH@|${HERMES_EXTRA_PATH}|g" \
      -e "s|@GOG_EXTRA_PATH@|${GOG_EXTRA_PATH}|g" \
      -e "s|@REPO_ROOT@|$REPO_ROOT|g" \
      -e "s|@SLACK_BOT_TOKEN@|${SLACK_BOT_TOKEN:-${SLACK_BOT_TOKEN:-}}|g" \
      -e "s|@OPENCLAW_SLACK_BOT_TOKEN@|${OPENCLAW_SLACK_BOT_TOKEN:-${SLACK_BOT_TOKEN:-}}|g" \
      -e "s|@SLACK_USER_TOKEN@|${SLACK_USER_TOKEN:-}|g" \
      -e "s|@DAILY_TRIAGE_CHANNEL@|${DAILY_TRIAGE_CHANNEL:-C0ALSKLU9KM}|g" \
      -e "s|@AO_GO_BIN@|${AO_GO_BIN}|g" \
      "$src" >"$tmp"; then
    rm -f "$tmp"
    echo "  ✗ $label render FAILED for $src" >&2
    return 1
  fi

  # plutil -lint is the canonical post-render validator. Render to a
  # temp file, lint, and ONLY if it passes do we atomic-mv into the
  # real destination. A malformed plist MUST NEVER overwrite a working
  # existing $dst; the temp file is unlinked on lint failure so
  # ~/Library/LaunchAgents never holds a broken plist, only an absent
  # one (or a still-working previous one).
  if ! plutil -lint "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    echo "  ✗ $label plutil -lint FAILED for $tmp" >&2
    return 1
  fi

  # True dry-run path: be strictly non-mutating. Remove the rendered
  # temp file, report what would have happened, return BEFORE any
  # backup snapshot, mv, bootout, or launchctl invocation. The
  # test suite relies on this to assert zero destination writes.
  if [[ "$INSTALL_DRY_RUN" == "1" ]]; then
    rm -f "$tmp" 2>/dev/null || true
    echo "  - (dry-run) would render $label — no destination write, no launchctl"
    return 0
  fi

  # Capture was_loaded + take the snapshot BEFORE the mv so the
  # backup holds the predecessor's bytes (NOT the just-rendered
  # new plist). Both cp/mv are explicitly guarded because the
  # surrounding call site is `if ! _install_plist`, where errexit is
  # locally disabled.
  local was_loaded=0
  if launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; then
    was_loaded=1
  fi
  local backup=""
  if [[ -f "$dst" ]]; then
    backup="$(mktemp "${dst}.bak.XXXXXX")" \
      || { rm -f "$tmp"; echo "  ✗ $label mktemp FAILED" >&2; return 1; }
    if ! cp "$dst" "$backup"; then
      rm -f "$tmp" "$backup"
      echo "  ✗ $label backup cp FAILED for $dst -> $backup" >&2
      return 1
    fi
  elif [[ "$was_loaded" -eq 1 ]]; then
    # The label IS loaded but we have no on-disk predecessor (e.g.
    # the file was deleted under us). Rollback would be impossible,
    # so refuse before touching live state -- abort the install
    # rather than silently remove the running service.
    rm -f "$tmp"
    echo "  ✗ $label was_loaded=1 but no $dst on disk; cannot safely upgrade" >&2
    return 1
  fi
  if ! mv "$tmp" "$dst"; then
    rm -f "$tmp" "${backup:-}" 2>/dev/null || true
    echo "  ✗ $label atomic-mv FAILED for $tmp -> $dst" >&2
    return 1
  fi

  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  sleep 0.35
  local _attempt=1
  local _succeeded=0
  while [[ "$_attempt" -le 3 ]]; do
    if launchctl bootstrap "gui/$(id -u)" "$dst"; then
      _succeeded=1
      break
    fi
    if [[ "$_attempt" -lt 3 ]]; then
      sleep 0.5
      launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
      sleep 0.35
    else
      _attempt=4
    fi
    _attempt=$((_attempt + 1))
  done

  if [[ "$_succeeded" -eq 0 ]]; then
    # Bootstrap exhausted retries. ROLL BACK so this label is NOT
    # silently absent from launchd after the failed upgrade. Restore
    # the prior file with atomic mv (not cp) so the restore cannot be
    # a partial write; re-bootstrap only when the predecessor was
    # actually loaded (was_loaded=1), because an unloaded predecessor
    # means no live state to recreate.
    if [[ -n "$backup" && -f "$backup" ]]; then
      if ! mv "$backup" "$dst"; then
        echo "  ✗ $label rollback mv FAILED; manual intervention required" >&2
      else
        if [[ "$was_loaded" -eq 1 ]]; then
          if launchctl bootstrap "gui/$(id -u)" "$dst"; then
            echo "  ✗ $label FAILED to load new plist; rolled back to prior plist" >&2
          else
            echo "  ✗ $label rollback restore OK but re-bootstrap FAILED; manual intervention required" >&2
          fi
        else
          echo "  ✗ $label FAILED to load new plist; restored prior plist file (label was not loaded)" >&2
        fi
      fi
    else
      echo "  ✗ $label FAILED to load after 3 attempts (no prior plist to roll back to)" >&2
    fi
    return 1
  fi

  # Success path: drop the snapshot, then enable.
  rm -f "${backup:-}" 2>/dev/null || true
  launchctl enable "gui/$(id -u)/$label" || true
  echo "  - loaded $label"
}

echo "Installing launchd scheduled job plists..."

# macOS /bin/bash 3.2 compatible dedup: the template loop is unique by
# glob already (template is the canonical source); the standalone loop
# skips any ${base}.plist that has a corresponding .plist.template twin
# because that label was already installed in the template pass. The
# memory-sync plist is outside the ai.smartclaw.schedule.* prefix and so
# cannot collide with either glob. No state-tracking needed.
#
# Failures are accumulated in INSTALL_FAILED across ALL loops (template,
# standalone, memory-sync) so one bad plist does not abort the rest of
# the run. After every loop, we set the script's exit code from this
# counter -- operators see the full list of failures plus the overall
# nonzero exit on which CI / operators can alert.

INSTALL_FAILED=0

# Install the persistent Go AO daemon before the calendar-triggered exporter.
AO_GO_DAEMON_PLIST="$LAUNCHD_TEMPLATES_DIR/ai.agento.ao-go-daemon.plist.template"
if [[ -f "$AO_GO_DAEMON_PLIST" ]]; then
  if ! _install_plist "$AO_GO_DAEMON_PLIST"; then
    echo "  ! ai.agento.ao-go-daemon failed to install, continuing"
    INSTALL_FAILED=$((INSTALL_FAILED + 1))
  fi
fi

for plist in "$LAUNCHD_TEMPLATES_DIR"/ai.smartclaw.schedule.*.plist.template; do
  [[ -f "$plist" ]] || continue
  # A single job failing to install (e.g. daily-repo-export's AO_GO_BIN not
  # yet set up, or a malformed plist that plutil -lint rejects) must not
  # abort every other scheduled job under `set -e`.
  if ! _install_plist "$plist"; then
    echo "  ! $(basename "$plist") failed to install, continuing"
    INSTALL_FAILED=$((INSTALL_FAILED + 1))
  fi
done

# Standalone .plist (no .template). When a `.plist.template` for the
# same base label exists in this directory, the template pass above
# already installed it -- skip the standalone so launchd never gets
# TWO plists registered under one Label key.
for plist in "$LAUNCHD_TEMPLATES_DIR"/ai.smartclaw.schedule.*.plist; do
  [[ -f "$plist" ]] || continue
  [[ "$plist" == *.plist.template ]] && continue
  _base="${plist%.plist}"
  [[ -f "${_base}.plist.template" ]] && continue
  if ! _install_plist "$plist"; then
    echo "  ! $(basename "$plist") failed to install, continuing"
    INSTALL_FAILED=$((INSTALL_FAILED + 1))
  fi
done

# Also install ai.smartclaw.claude-memory-sync (background sync service).
# Does not use the ai.smartclaw.schedule.* pattern — it's a persistent service, not
# a cron-style scheduled job — but is installed alongside them for discoverability.
# The template is named ai.smartclaw.claude-memory-sync.plist.template so that
# _install_plist derives label=ai.smartclaw.claude-memory-sync, matching the plist
# <string>ai.smartclaw.claude-memory-sync</string> (launchctl enable/disable work).
#
# Note: install-launchagents.sh also installs this plist as part of infrastructure.
# Both paths use _install_plist / install_plist with @HERMES_EXTRA_PATH@ substitution,
# so double-install is safe (same result each time). This is intentional redundancy for
# standalone-vs-central-installer portability.
MEMORY_SYNC_PLIST="$LAUNCHD_TEMPLATES_DIR/ai.smartclaw.claude-memory-sync.plist.template"
if [[ -f "$MEMORY_SYNC_PLIST" ]]; then
  if ! _install_plist "$MEMORY_SYNC_PLIST"; then
    echo "  ! ai.smartclaw.claude-memory-sync failed to install, continuing"
    INSTALL_FAILED=$((INSTALL_FAILED + 1))
  fi
fi

# Registration alone is not readiness: `ao status` may exit zero while its
# JSON state is stale. Preserve every predecessor unless the daemon service is
# registered and reports the authoritative ready state.
DAILY_EXPORT_PLIST="$LAUNCHD_TEMPLATES_DIR/ai.smartclaw.schedule.daily-repo-export.plist.template"
if [[ "$INSTALL_DRY_RUN" != "1" && "$INSTALL_FAILED" -eq 0 && -f "$DAILY_EXPORT_PLIST" ]]; then
  daemon_ready=0
  readiness_attempt=1
  while [[ "$readiness_attempt" -le "$INSTALL_READY_MAX_POLLS" ]]; do
    daemon_service="$(launchctl print "gui/$(id -u)/ai.agento.ao-go-daemon" 2>/dev/null || true)"
    daemon_launchd_pid="$(printf '%s\n' "$daemon_service" | awk '/^[[:space:]]*pid = [0-9]+/ {print $3; exit}')"
    daemon_status="$("$AO_GO_BIN" status --json 2>/dev/null || true)"
    daemon_state="$(printf '%s\n' "$daemon_status" | jq -r '.state // empty' 2>/dev/null || true)"
    daemon_status_pid="$(printf '%s\n' "$daemon_status" | jq -r '.pid // empty' 2>/dev/null || true)"
    if [[ -n "$daemon_launchd_pid" && "$daemon_state" == "ready" && "$daemon_status_pid" == "$daemon_launchd_pid" ]]; then
      daemon_ready=1
      break
    fi
    sleep 1
    readiness_attempt=$((readiness_attempt + 1))
  done
  if [[ "$daemon_ready" -ne 1 ]]; then
    echo "  ✗ ai.agento.ao-go-daemon is not registered and ready; preserving predecessor jobs" >&2
    INSTALL_FAILED=$((INSTALL_FAILED + 1))
  else
    echo "  - ai.agento.ao-go-daemon registered and ready"
  fi
fi

# Functional canary: a registered calendar label is not proof that its script,
# paths, Git hooks, or credentials work. Run it once and require both a new
# successful launchd run and fresh local/origin-main SHA convergence for every
# configured export repo before predecessor retirement.
if [[ "$INSTALL_DRY_RUN" != "1" && "$INSTALL_FAILED" -eq 0 && -f "$DAILY_EXPORT_PLIST" ]]; then
  daily_label="ai.smartclaw.schedule.daily-repo-export"
  daily_before="$(launchctl print "gui/$(id -u)/$daily_label" 2>/dev/null || true)"
  daily_runs_before="$(printf '%s\n' "$daily_before" | awk '/^[[:space:]]*runs = [0-9]+/ {print $3; exit}')"
  daily_runs_before="${daily_runs_before:-0}"
  canary_ok=0
  if launchctl kickstart -k "gui/$(id -u)/$daily_label" >/dev/null 2>&1; then
    canary_attempt=1
    while [[ "$canary_attempt" -le "$INSTALL_CANARY_MAX_POLLS" ]]; do
      daily_after="$(launchctl print "gui/$(id -u)/$daily_label" 2>/dev/null || true)"
      daily_runs_after="$(printf '%s\n' "$daily_after" | awk '/^[[:space:]]*runs = [0-9]+/ {print $3; exit}')"
      daily_last_exit="$(printf '%s\n' "$daily_after" | awk '/^[[:space:]]*last exit code = / {print $5; exit}')"
      daily_pid="$(printf '%s\n' "$daily_after" | awk '/^[[:space:]]*pid = [0-9]+/ {print $3; exit}')"
      if [[ -n "$daily_runs_after" && "$daily_runs_after" -gt "$daily_runs_before" \
          && -z "$daily_pid" && "$daily_last_exit" == "0" ]]; then
        canary_ok=1
        break
      fi
      sleep 1
      canary_attempt=$((canary_attempt + 1))
    done
  fi
  if [[ "$canary_ok" -eq 1 ]]; then
    for export_repo in "$HOME/llm_wiki" "$HOME/roadmap"; do
      if ! export_repo_converged "$export_repo"; then
        canary_ok=0
        echo "  ✗ daily exporter canary did not converge $export_repo to origin/main" >&2
      fi
    done
  fi
  if [[ "$canary_ok" -ne 1 ]]; then
    echo "  ✗ daily exporter functional canary failed; preserving predecessor jobs" >&2
    INSTALL_FAILED=$((INSTALL_FAILED + 1))
  else
    echo "  - daily exporter functional canary passed for llm_wiki and roadmap"
  fi
fi

# Validate gateway-cron migration coverage before any live schedule is
# disabled. Every ID must be known and its mapped replacement registered.
if [[ "$INSTALL_DRY_RUN" != "1" && "$INSTALL_FAILED" -eq 0 ]]; then
  if ! load_migrated_job_ids; then
    INSTALL_FAILED=$((INSTALL_FAILED + 1))
  else
    for migrated_id in "${MIGRATED_JOB_IDS[@]}"; do
      migrated_label="$(migrated_target "$migrated_id" || true)"
      if [[ -z "$migrated_label" ]] \
          || ! launchctl print "gui/$(id -u)/$migrated_label" >/dev/null 2>&1; then
        echo "Error: replacement label is not registered for migrated job $migrated_id: ${migrated_label:-unknown}" >&2
        INSTALL_FAILED=$((INSTALL_FAILED + 1))
      fi
    done
  fi
fi

if [[ "$INSTALL_DRY_RUN" == "1" ]]; then
  echo "  - (dry-run) skipping live cron JSON mutation, gateway reload, boot-out, and launchctl verification"
elif [[ "${INSTALL_FAILED:-0}" -gt 0 ]]; then
  # Coverage contract: when ANY replacement failed validation, do NOT
  # mutate live cron JSON, HUP the gateway, or retire legacy exporters.
  # Individual labels installed successfully earlier remain upgraded.
  echo "  ! install FAILURES detected (${INSTALL_FAILED}); leaving gateway cron," \
    "legacy plists, and live exporter state UNTOUCHED"
else
  # Disable migrated jobs in live gateway cron (leave them in jobs.json -- gitignored locally)
  if [[ -f "$LIVE_JOBS" ]]; then
    if [[ "${#MIGRATED_JOB_IDS[@]}" -gt 0 ]]; then
      ids_json="$(printf '%s\n' "${MIGRATED_JOB_IDS[@]}" | jq -R . | jq -s .)"
    else
      ids_json="[]"
    fi
    tmp_jobs="$LIVE_JOBS.tmp"
    if jq --argjson ids "$ids_json" '
      .jobs = ((.jobs // []) | map(
        if (.id as $id | ($ids | index($id)) != null)
        then .enabled = false
        else .
        end
      ))
    ' "$LIVE_JOBS" >"$tmp_jobs"; then
      mv "$tmp_jobs" "$LIVE_JOBS"
      echo "  - disabled migrated gateway cron jobs in $LIVE_JOBS"
    else
      rm -f "$tmp_jobs"
      echo "  - failed to update $LIVE_JOBS" >&2
    fi

    # Signal gateway to reload jobs.json
    gateway_pid="$(pgrep -f 'hermes.*gateway' | head -n1 || true)"
    if [[ -n "$gateway_pid" ]]; then
      kill -HUP "$gateway_pid" 2>/dev/null || true
      echo "  - signaled gateway reload (pid=$gateway_pid)"
    else
      echo "  ! no running gateway pid found for HUP reload"
    fi
  else
    echo "  ! live cron file missing: $LIVE_JOBS (skipping disable step)"
  fi

  # Boot out and remove the two per-repository jobs that
  # ai.smartclaw.schedule.daily-repo-export now supersedes for llm_wiki. Only
  # the exact named legacy labels are touched — user-scope schedules and any
  # roadmap-specific label (none currently exists) are left alone, since
  # they are outside this job's llm_wiki+roadmap allowlist.
  if launchctl print "gui/$(id -u)/ai.smartclaw.schedule.daily-repo-export" >/dev/null 2>&1; then
    for legacy_label in ai.smartclaw.schedule.auto-push-llm-wiki com.jleechan.git-push-llm-wiki; do
      launchctl bootout "gui/$(id -u)/$legacy_label" 2>/dev/null && \
        echo "  - booted out superseded label $legacy_label" || \
        echo "  - $legacy_label was not loaded"
      legacy_plist="$LAUNCHD_DIR/$legacy_label.plist"
      if [[ -f "$legacy_plist" ]]; then
        rm -f "$legacy_plist"
        echo "  - removed superseded plist $legacy_plist"
      fi
    done
  else
    echo "  ! ai.smartclaw.schedule.daily-repo-export is not loaded — leaving superseded labels in place"
  fi

  printf '\nVerifying loaded labels...\n'
  # Same dedup shape as the install pass so the verification path
  # cannot disagree with what was actually installed. Template glob
  # is unique; standalone glob skips when its template twin exists.
  for plist in "$LAUNCHD_TEMPLATES_DIR"/ai.smartclaw.schedule.*.plist.template; do
    [[ -f "$plist" ]] || continue
    label="$(basename "$plist" .plist.template)"
    if launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; then
      echo "  - $label registered"
    else
      echo "  - $label not registered"
    fi
  done
  for plist in "$LAUNCHD_TEMPLATES_DIR"/ai.smartclaw.schedule.*.plist; do
    [[ -f "$plist" ]] || continue
    [[ "$plist" == *.plist.template ]] && continue
    _base="${plist%.plist}"
    [[ -f "${_base}.plist.template" ]] && continue
    label="$(basename "$plist" .plist)"
    if launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; then
      echo "  - $label registered"
    else
      echo "  - $label not registered"
    fi
  done
fi

# Smoke-test: verify hermes is callable via the launchd PATH
printf '\nSmoke-testing launchd PATH for hermes and gog...\n'
if command -v hermes >/dev/null 2>&1; then
  echo "  - hermes found at $(command -v hermes) -- PATH injection successful"
else
  echo "  - hermes not found in launchd PATH (expected in ~/.bun/bin or PATH)"
fi
if command -v gog >/dev/null 2>&1; then
  echo "  - gog found at $(command -v gog) -- PATH injection successful"
else
  echo "  - gog not found in launchd PATH (expected in ~/.bun/bin or PATH)"
fi

echo
echo "Done. Scheduled Hermes jobs now run via launchd labels ai.smartclaw.schedule.*"
echo ""
echo "Migration status:"
echo "  Migrated to launchd (disabled in gateway cron):"
for id in "${MIGRATED_JOB_IDS[@]-}"; do
  [[ -n "$id" ]] || continue
  target="$(migrated_target "$id" || true)"
  echo "    - $id -> ${target:-?}"
done
echo ""
echo "  Remaining in gateway cron (live, gitignored):"
echo "    - thread-followup-ao263 (ad-hoc, short-lived)"
echo "    - Any future pr-automation / AO lifecycle jobs"

# Surface overall result to operators. The per-label fail lines are
# already echoed above; this exit code is what CI / monitoring should
# alert on.
if [[ "${INSTALL_FAILED:-0}" -gt 0 ]]; then
  echo ""
  echo "FAILED: ${INSTALL_FAILED} plist(s) did not install cleanly"
  exit 1
fi
exit 0
