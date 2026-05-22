#!/usr/bin/env bash
# setup-launchd.sh — Hermes launchd installer (replaces all stale/openclaw plists)
#
# Usage:
#   ./setup-launchd.sh              # dry-run: show what would happen
#   ./setup-launchd.sh --apply      # apply: unload+delete stale plists
#   ./setup-launchd.sh --status     # show current loaded state
#
# NOTE: Phase 2 (install) substitutes @HOME@/@HERMES_BIN@/@REPO_ROOT@ placeholders
# inline at install time. Source templates live in ~/.smartclaw/launchd/*.template.
# Phase 1 removes stale openclaw/agento-era plists.

set -euo pipefail

HERMES_REPO="${HERMES_HOME_REPO:-$HOME/.smartclaw}"
HERMES_PROD="$HOME/.smartclaw_prod"
LAUNCHD_DIR="$HOME/Library/LaunchAgents"
USER_ID=$(id -u)
DRY_RUN=true
DELETE_ONLY=false
STATUS_ONLY=false

# ─── CLI args ─────────────────────────────────────────────────────────────────
for arg in "$@"; do
  case "$arg" in
    --apply)       DRY_RUN=false ;;
    --delete-only) DRY_RUN=false; DELETE_ONLY=true ;;
    --status)      STATUS_ONLY=true ;;
  esac
done

# ─── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YLW='\033[0;33m'; GRN='\033[0;32m'; BLU='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${BLU}[INFO]${NC}  $*"; }
warn()  { echo -e "${YLW}[WARN]${NC}  $*"; }
ok()    { echo -e "${GRN}[ OK ]${NC}  $*"; }
err()   { echo -e "${RED}[ERR ]${NC}  $*"; }
dry()   { echo -e "${YLW}[DRY ]${NC}  $*"; }

# ─── Status ───────────────────────────────────────────────────────────────────
if $STATUS_ONLY; then
  echo "=== Hermes launchd status ==="
  launchctl list 2>/dev/null | grep -E "hermes|agento|mctrl|com\.agentorchestrator" \
    | awk '{printf "%-55s PID=%-8s exit=%s\n", $3, $1, $2}' | sort || true
  echo ""
  echo "=== Plists in LaunchAgents ==="
  ls "$LAUNCHD_DIR" | grep -E "hermes|agento|mctrl|agentorchestrator" | sort || true
  exit 0
fi

# ─── Stale plists to REMOVE ───────────────────────────────────────────────────
# These reference ~/.openclaw (dead), project_agento (dead), or are duplicate .disabled
STALE_PLISTS=(
  # OpenClaw-era / dead scripts
  "ai.agento.backfill.plist.disabled"           # refs .openclaw; script missing
  "ai.agento.dashboard.plist"                   # refs project_agento (dead)
  "ai.agento.health.plist"                      # refs .openclaw + project_agento
  "ai.agento.notifier.plist"                    # refs project_agento
  "ai.agento.novel-daily.plist"                 # refs .openclaw + project_agento
  "ai.agento.orchestrators.plist"               # refs project_agento
  "ai.agento.orchestrators.plist.bak-20260329134852"  # backup file
  "ai.mctrl.supervisor.plist"                   # script at .openclaw (missing)
  "com.agentorchestrator.lifecycle-agent-orchestrator.plist"  # .openclaw + project_agento
  "com.jleechan.harness-analyzer.plist"         # script at .openclaw (missing)
  "com.jleechanorg.gh-actions-cost-monitor.plist"  # script at .openclaw (missing)
  "com.worldai.bg3.server.plist"                # refs .openclaw; tsx missing
  "com.jleechanorg.spend-alert-daily.plist"      # refs .openclaw (missing)
  # Duplicate hermes plists
  "ai.smartclaw.prod.plist.disabled"               # duplicate of ai.smartclaw.prod.plist
)

echo ""
echo "════════════════════════════════════════════════════════"
echo "  Hermes launchd setup $([ "$DRY_RUN" = true ] && echo '(DRY RUN — pass --apply to execute)' || echo '(APPLY MODE)')"
echo "════════════════════════════════════════════════════════"
echo ""

# ─── PHASE 1: Remove stale plists ─────────────────────────────────────────────
echo "── Phase 1: Remove stale/openclaw plists ──"
for plist_file in "${STALE_PLISTS[@]}"; do
  full_path="$LAUNCHD_DIR/$plist_file"
  if [ ! -f "$full_path" ]; then
    info "  skip (not found): $plist_file"
    continue
  fi

  # Extract label from plist for unloading
  label=$(python3 -c "import plistlib; f=open('$full_path','rb'); d=plistlib.load(f); f.close(); print(d.get('Label',''))" 2>/dev/null || echo "")

  if $DRY_RUN; then
    dry "  would unload: $label"
    dry "  would delete: $plist_file"
  else
    if [ -n "$label" ]; then
      launchctl bootout "gui/$USER_ID/$label" 2>/dev/null && warn "  unloaded: $label" || true
    fi
    rm -f "$full_path"
    ok "  deleted: $plist_file"
  fi
done

if $DELETE_ONLY; then
  echo ""
  ok "Delete-only mode complete."
  exit 0
fi

# ─── PHASE 2: Install canonical Hermes plists ─────────────────────────────────
# Placeholder substitution (@HOME@/@HERMES_BIN@/@REPO_ROOT@/@HERMES_EXTRA_PATH@)
# is performed inline at install time. Templates are read-only; substituted output
# is written to ~/Library/LaunchAgents/ only in --apply mode.
echo ""
echo "── Phase 2: Install canonical Hermes plists ──"

PLISTS_SRC="$HERMES_REPO/launchd"

# Core services (non-schedule)
CORE_PLISTS=(
  "ai.smartclaw.prod.plist"
  "ai.smartclaw-watchdog.plist.template"
  "ai.smartclaw.claude-memory-sync.plist.template"
  "ai.smartclaw-mem0-server.plist.template"
  "ai.smartclaw.ao-notifier.plist.template"
)

# Schedule plists — install from templates (strip .template suffix for dest)
SCHEDULE_PLISTS=(
  "ai.smartclaw.schedule.ao-progress-reporter.plist.template"
  "ai.smartclaw.schedule.bug-hunt-9am.plist.template"
  "ai.smartclaw.schedule.canary-periodic.plist.template"
  "ai.smartclaw.schedule.commit-pending.plist.template"
  "ai.smartclaw.schedule.composio-upstream-reminder.plist.template"
  "ai.smartclaw.schedule.cron-backup-sync.plist.template"
  "ai.smartclaw.schedule.daily-research.plist.template"
  "ai.smartclaw.schedule.docs-drift-review.plist.template"
  "ai.smartclaw.schedule.gh-actions-cost-monitor.plist.template"
  "ai.smartclaw.schedule.gmail-daily-recap.plist.template"
  "ai.smartclaw.schedule.harness-analyzer-9am.plist.template"
  "ai.smartclaw.schedule.living-blog-status.plist.template"
  "ai.smartclaw.schedule.morning-log-review.plist.template"
  "ai.smartclaw.schedule.orch-health-weekly.plist.template"
  "ai.smartclaw.schedule.qdrant-backup.plist.template"
  "ai.smartclaw.schedule.spend-alert-daily.plist.template"
  "ai.smartclaw.schedule.weekly-error-trends.plist.template"
  "ai.smartclaw.schedule.workspace-report-weekly.plist.template"
)

_install_plist() {
  local src="$1"
  local src_file
  src_file="$(basename "$src")"
  # strip .template for dest name
  local dest_file="${src_file%.template}"
  local dest="$LAUNCHD_DIR/$dest_file"
  local label
  label=$(python3 -c "import plistlib; f=open('$src','rb'); d=plistlib.load(f); f.close(); print(d.get('Label',''))" 2>/dev/null || echo "")

  if [ ! -f "$src" ]; then
    warn "  skip (template not found): $src_file"
    return
  fi

  if $DRY_RUN; then
    dry "  would install: $src_file → $dest_file (label=$label)"
    return
  fi

  # Substitute placeholders and write to destination
  local HERMES_BIN_PATH
  HERMES_BIN_PATH=$(hermes_path=$(command -v hermes 2>/dev/null) && readlink -f "$hermes_path" 2>/dev/null || echo /opt/homebrew/bin/hermes)
  sed \
    -e "s|@HOME@|$HOME|g" \
    -e "s|@HERMES_BIN@|$HERMES_BIN_PATH|g" \
    -e "s|@REPO_ROOT@|$HERMES_REPO|g" \
    -e "s|@HERMES_EXTRA_PATH@||g" \
    "$src" > "$dest.tmp" && mv "$dest.tmp" "$dest" || { rm -f "$dest.tmp"; warn "  substitution failed: $src_file"; return; }

  # Unload existing if loaded
  if [ -n "$label" ]; then
    launchctl bootout "gui/$USER_ID/$label" 2>/dev/null || true
  fi

  # Load unless it's a schedule-only plist (launchd loads them by StartCalendarInterval)
  launchctl bootstrap "gui/$USER_ID" "$dest" 2>/dev/null && ok "  loaded: $dest_file" \
    || warn "  installed but load failed (may already be loaded): $dest_file"
}

echo "  Core services:"
for p in "${CORE_PLISTS[@]}"; do
  _install_plist "$PLISTS_SRC/$p"
done

echo "  Schedule services:"
for p in "${SCHEDULE_PLISTS[@]}"; do
  _install_plist "$PLISTS_SRC/$p"
done

# ─── PHASE 3: Verify ──────────────────────────────────────────────────────────
if ! $DRY_RUN; then
  echo ""
  echo "── Phase 3: Verify ──"
  sleep 1

  # Check prod gateway
  GW_PID=$(launchctl list 2>/dev/null | grep "ai.smartclaw.prod$" | awk '{print $1}' || true)
  PORT_PID=$(lsof -t -i :"${PROD_PORT:-8642}" 2>/dev/null | head -1 || echo "")

  if [ -n "$GW_PID" ] && [ "$GW_PID" != "-" ]; then
    if [ "$PORT_PID" = "$GW_PID" ]; then
      ok "  Gateway: PID=$GW_PID bound to :${PROD_PORT:-8642} ✓"
    else
      warn "  Gateway: PID=$GW_PID but port ${PROD_PORT:-8642} bound by PID=${PORT_PID:-none}"
    fi
  else
    err "  Gateway: NOT loaded (ai.smartclaw.prod missing from launchctl list)"
  fi

  # Check no openclaw refs still loaded
  OPENCLAW_LOADED=$(launchctl list 2>/dev/null | grep -E "agento|mctrl|agentorchestrator" || true)
  if [ -n "$OPENCLAW_LOADED" ]; then
    warn "  Still-loaded openclaw-era services:"
    echo "$OPENCLAW_LOADED" | awk '{print "    "$3}'
  else
    ok "  No openclaw-era services loaded ✓"
  fi

  echo ""
  ok "Setup complete. Run './setup-launchd.sh --status' to see full state."
fi

if $DRY_RUN; then
  echo ""
  echo "── Dry run complete. Re-run with --apply to execute. ──"
fi
