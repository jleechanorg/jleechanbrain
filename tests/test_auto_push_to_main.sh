#!/usr/bin/env bash
# test_auto_push_to_main.sh
#
# Fixture-based tests for scripts/auto-push-to-main.sh's deterministic Git
# fast path: the legacy two-argument interface, the new multi-repository
# `--repo PATH:NAME` coordinator interface, remote-SHA verification, and the
# security invariants (no --force, no --no-verify, no direct provider CLI).
#
# Layer: 1 (fixture, disposable bare-remote repos). Real Go AO recovery
# scenarios live in testing_llm/daily_repo_export_real_ao.md.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/auto-push-to-main.sh"

[[ -f "$SCRIPT" ]] || { echo "FAIL: script not found at $SCRIPT"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test_auto_push.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

PASSED=0
FAILED=0
pass() { echo "PASS: $1"; PASSED=$((PASSED + 1)); }
fail() { echo "FAIL: $1"; FAILED=$((FAILED + 1)); }

# Keep the fixture runs black-box safe: no real Slack network calls, no
# recovery adapter unless a test explicitly points AUTO_PUSH_RECOVERY_BIN
# at a fake, and no state written into the real production log directory
# (fixture repo names like "normal"/"legacy" would otherwise collide with
# real per-repo state files keyed only by name). Deliberately NOT done by
# overriding $HOME — the real global core.hooksPath under the real $HOME is
# what proves the gitleaks pre-push guard isn't bypassed (see the
# normal_commit_runs_hooks test below).
unset SLACK_BOT_TOKEN SLACK_BOT_TOKEN HERMES_OPS_SLACK_CHANNEL 2>/dev/null || true
export AUTO_PUSH_LOG_DIR="$TMP/logs"
mkdir -p "$AUTO_PUSH_LOG_DIR"

# Test isolation: every state directory that the production scripts
# consult (Hermes's canonical state dir, Slack's per-thread dedupe
# state, Slack's cross-thread dedupe state) is pointed under $TMP for
# the duration of this suite. Production defaults like
# $HOME/.smartclaw/state are NEVER read or written by these fixture
# runs -- making any future call into those paths safely capture-only.
export HERMES_STATE_DIR="$TMP/hermes-state"
export SLACK_THREAD_STATE_DIR="$TMP/hermes-state/slack-thread"
export SLACK_DEDUPE_STATE_DIR="$TMP/hermes-state/slack-dedupe"
mkdir -p "$HERMES_STATE_DIR" "$SLACK_THREAD_STATE_DIR" "$SLACK_DEDUPE_STATE_DIR"

GO_FIXTURE_BIN=""
for candidate in /opt/homebrew/bin/go /usr/local/go/bin/go /usr/local/bin/go; do
  if [[ -x "$candidate" ]]; then GO_FIXTURE_BIN="$candidate"; break; fi
done
[[ -n "$GO_FIXTURE_BIN" ]] || { echo "FAIL: Go toolchain required for AO provenance fixtures"; exit 1; }
export FAKE_AO_GO="$TMP/fake-ao-go"
mkdir -p "$TMP/fake-ao-module/cmd/ao"
cat >"$TMP/fake-ao-module/go.mod" <<'GOMOD'
module github.com/aoagents/agent-orchestrator/backend
go 1.21
GOMOD
cat >"$TMP/fake-ao-module/cmd/ao/main.go" <<'GO'
package main
import (
  "fmt"
  "os"
)
func main() {
  if len(os.Args) < 2 { os.Exit(2) }
  switch os.Args[1] {
  case "version", "daemon":
    return
  case "status":
    value := os.Getenv("AO_FAKE_STATUS_JSON")
    if value == "" { value = "{\"state\":\"stale\"}" }
    fmt.Println(value)
    return
  }
  os.Exit(1)
}
GO
( cd "$TMP/fake-ao-module" && "$GO_FIXTURE_BIN" build -o "$FAKE_AO_GO" ./cmd/ao ) \
  || { echo "FAIL: could not build canonical Go AO fixture"; exit 1; }

run_test() {
  local name="$1" fn="$2"
  if "$fn" >"$TMP/$name.out" 2>&1; then
    pass "$name"
  else
    fail "$name"
    sed 's/^/    /' "$TMP/$name.out"
  fi
}

# ─── Fixture helper ───────────────────────────────────────────────────────
new_fixture() {
  local root="$1"
  git init --bare "$root/origin.git" >/dev/null
  git clone "$root/origin.git" "$root/work" >/dev/null 2>&1
  git -C "$root/work" config user.name "Fixture"
  git -C "$root/work" config user.email "${GITHUB_USER}@users.noreply.github.com"
  printf 'base\n' >"$root/work/tracked.txt"
  git -C "$root/work" add tracked.txt
  git -C "$root/work" commit -m base >/dev/null
  git -C "$root/work" branch -M main
  git -C "$root/work" push -u origin main >/dev/null
}

# ─── Test cases ───────────────────────────────────────────────────────────
test_normal_export_reaches_remote_main() {
  new_fixture "$TMP/normal"
  printf 'changed\n' >>"$TMP/normal/work/tracked.txt"
  RUN_INTERVAL_SECS=0 bash "$SCRIPT" "$TMP/normal/work" normal
  git --git-dir="$TMP/normal/origin.git" show main:tracked.txt | grep -q changed
}

test_legacy_two_argument_interface() {
  new_fixture "$TMP/legacy"
  printf 'legacy-changed\n' >>"$TMP/legacy/work/tracked.txt"
  RUN_INTERVAL_SECS=0 bash "$SCRIPT" "$TMP/legacy/work" legacy
  git --git-dir="$TMP/legacy/origin.git" show main:tracked.txt | grep -q legacy-changed
}

test_coordinator_exports_two_repositories() {
  new_fixture "$TMP/coord_a"
  new_fixture "$TMP/coord_b"
  printf 'coord-a-changed\n' >>"$TMP/coord_a/work/tracked.txt"
  printf 'coord-b-changed\n' >>"$TMP/coord_b/work/tracked.txt"
  RUN_INTERVAL_SECS=0 bash "$SCRIPT" \
    --repo "$TMP/coord_a/work:coord-a" \
    --repo "$TMP/coord_b/work:coord-b"
  git --git-dir="$TMP/coord_a/origin.git" show main:tracked.txt | grep -q coord-a-changed && \
  git --git-dir="$TMP/coord_b/origin.git" show main:tracked.txt | grep -q coord-b-changed
}

test_untracked_files_are_not_committed() {
  new_fixture "$TMP/untracked"
  printf 'new-file\n' >"$TMP/untracked/work/new_untracked.txt"
  RUN_INTERVAL_SECS=0 bash "$SCRIPT" "$TMP/untracked/work" untracked
  ! git --git-dir="$TMP/untracked/origin.git" show main:new_untracked.txt >/dev/null 2>&1
}

test_llm_wiki_untracked_files_are_committed() {
  new_fixture "$TMP/llm_wiki_fixture"
  printf 'new wiki concept\n' >"$TMP/llm_wiki_fixture/work/new_concept.md"
  RUN_INTERVAL_SECS=0 bash "$SCRIPT" "$TMP/llm_wiki_fixture/work" llm-wiki
  git --git-dir="$TMP/llm_wiki_fixture/origin.git" show main:new_concept.md | grep -q "new wiki concept"
}

test_normal_commit_runs_hooks() {
  # The machine's global core.hooksPath (~/.config/git/hooks) shadows any
  # per-repo .git/hooks/ dir, so a fake local hook would never fire and
  # silently prove nothing. Instead assert the REAL global pre-push secret
  # guard (secret-scan.sh) actually ran and was not bypassed with --no-verify
  # — this is the actual security boundary the design doc requires stays
  # intact (git secret guard: ... is that hook's own stderr marker).
  new_fixture "$TMP/hooks"
  printf 'hook-changed\n' >>"$TMP/hooks/work/tracked.txt"
  local out
  out="$(RUN_INTERVAL_SECS=0 bash "$SCRIPT" "$TMP/hooks/work" hooks 2>&1)"
  printf '%s\n' "$out"
  printf '%s\n' "$out" | grep -q "git secret guard"
}

test_no_force_or_no_verify_flags() {
  local out
  out="$(rg -n -- '--force|--no-verify|codex exec|claude' "$SCRIPT" 2>/dev/null || true)"
  [[ -z "$out" ]]
}

test_remote_advanced_triggers_recovery_not_direct_cli() {
  new_fixture "$TMP/divergent"
  # Advance the remote independently of the local clone so the deterministic
  # push is a guaranteed non-fast-forward.
  git clone "$TMP/divergent/origin.git" "$TMP/divergent/other" >/dev/null 2>&1
  git -C "$TMP/divergent/other" config user.name "Fixture"
  git -C "$TMP/divergent/other" config user.email "${GITHUB_USER}@users.noreply.github.com"
  printf 'remote-advanced\n' >>"$TMP/divergent/other/tracked.txt"
  git -C "$TMP/divergent/other" commit -am "remote advance" >/dev/null
  git -C "$TMP/divergent/other" push origin main >/dev/null

  printf 'local-changed\n' >>"$TMP/divergent/work/tracked.txt"

  local fake_recovery="$TMP/divergent/fake-recovery.sh"
  cat >"$fake_recovery" <<'FAKE'
#!/usr/bin/env bash
echo "FAKE_RECOVERY_CALLED $*" >> "${FAKE_RECOVERY_LOG:?}"
exit 1
FAKE
  chmod +x "$fake_recovery"

  FAKE_RECOVERY_LOG="$TMP/divergent/recovery.log" \
    AUTO_PUSH_RECOVERY_BIN="$fake_recovery" \
    RUN_INTERVAL_SECS=0 \
    bash "$SCRIPT" "$TMP/divergent/work" divergent && return 1

  grep -q "FAKE_RECOVERY_CALLED" "$TMP/divergent/recovery.log"
}

test_ordinary_conflict_classified_as_push_phase() {
  new_fixture "$TMP/classify-push"
  git clone "$TMP/classify-push/origin.git" "$TMP/classify-push/other" >/dev/null 2>&1
  git -C "$TMP/classify-push/other" config user.name "Fixture"
  git -C "$TMP/classify-push/other" config user.email "${GITHUB_USER}@users.noreply.github.com"
  printf 'remote-advanced\n' >>"$TMP/classify-push/other/tracked.txt"
  git -C "$TMP/classify-push/other" commit -am "remote advance" >/dev/null
  git -C "$TMP/classify-push/other" push origin main >/dev/null

  printf 'local-changed\n' >>"$TMP/classify-push/work/tracked.txt"

  local fake_recovery="$TMP/classify-push/fake-recovery.sh"
  cat >"$fake_recovery" <<'FAKE'
#!/usr/bin/env bash
echo "PHASE_ARG=$6" >> "${FAKE_RECOVERY_LOG:?}"
exit 1
FAKE
  chmod +x "$fake_recovery"

  FAKE_RECOVERY_LOG="$TMP/classify-push/recovery.log" \
    AUTO_PUSH_RECOVERY_BIN="$fake_recovery" \
    RUN_INTERVAL_SECS=0 \
    bash "$SCRIPT" "$TMP/classify-push/work" classify-push && return 1

  grep -q "PHASE_ARG=push" "$TMP/classify-push/recovery.log"
}

test_secret_scan_hook_rejection_classified_as_gitleaks_phase() {
  new_fixture "$TMP/classify-hook"
  # A fixture-local pre-push hook emitting the EXACT, anchored marker line
  # this repo's real configured secret-scan hook
  # (~/.config/git/hooks/secret-scan.sh) itself prints on its own die()
  # path — never relies on the machine's real global hook, so this is
  # deterministic and portable. The classifier must match this owned
  # protocol marker positively, not infer from the absence of git's
  # non-fast-forward hint (that absence-based heuristic was rejected as
  # unsafe: network/auth failures and unrelated hooks also lack it).
  mkdir -p "$TMP/classify-hook/work-hooks"
  cat >"$TMP/classify-hook/work-hooks/pre-push" <<'HOOK'
#!/usr/bin/env bash
echo "git secret guard: scanning outgoing range abc123..def456 for refs/heads/main" >&2
echo "git secret guard: push blocked by secret scan for origin fixture-origin" >&2
exit 1
HOOK
  chmod +x "$TMP/classify-hook/work-hooks/pre-push"
  git -C "$TMP/classify-hook/work" config core.hooksPath "$TMP/classify-hook/work-hooks"

  printf 'local-changed\n' >>"$TMP/classify-hook/work/tracked.txt"

  local fake_recovery="$TMP/classify-hook/fake-recovery.sh"
  cat >"$fake_recovery" <<'FAKE'
#!/usr/bin/env bash
echo "PHASE_ARG=$6" >> "${FAKE_RECOVERY_LOG:?}"
exit 1
FAKE
  chmod +x "$fake_recovery"

  FAKE_RECOVERY_LOG="$TMP/classify-hook/recovery.log" \
    AUTO_PUSH_RECOVERY_BIN="$fake_recovery" \
    RUN_INTERVAL_SECS=0 \
    bash "$SCRIPT" "$TMP/classify-hook/work" classify-hook && return 1

  grep -q "PHASE_ARG=gitleaks" "$TMP/classify-hook/recovery.log"
}

test_unrelated_hook_rejection_stays_push_phase() {
  # A DIFFERENT local hook (not the secret scanner) also rejects the push
  # and also lacks git's non-fast-forward hint text — must NOT be
  # misclassified as gitleaks. This is exactly the case the old
  # absence-of-hint heuristic got wrong.
  new_fixture "$TMP/classify-unrelated-hook"
  mkdir -p "$TMP/classify-unrelated-hook/work-hooks"
  cat >"$TMP/classify-unrelated-hook/work-hooks/pre-push" <<'HOOK'
#!/usr/bin/env bash
echo "some-other-policy-hook: commit message format invalid" >&2
exit 1
HOOK
  chmod +x "$TMP/classify-unrelated-hook/work-hooks/pre-push"
  git -C "$TMP/classify-unrelated-hook/work" config core.hooksPath "$TMP/classify-unrelated-hook/work-hooks"

  printf 'local-changed\n' >>"$TMP/classify-unrelated-hook/work/tracked.txt"

  local fake_recovery="$TMP/classify-unrelated-hook/fake-recovery.sh"
  cat >"$fake_recovery" <<'FAKE'
#!/usr/bin/env bash
echo "PHASE_ARG=$6" >> "${FAKE_RECOVERY_LOG:?}"
exit 1
FAKE
  chmod +x "$fake_recovery"

  FAKE_RECOVERY_LOG="$TMP/classify-unrelated-hook/recovery.log" \
    AUTO_PUSH_RECOVERY_BIN="$fake_recovery" \
    RUN_INTERVAL_SECS=0 \
    bash "$SCRIPT" "$TMP/classify-unrelated-hook/work" classify-unrelated-hook && return 1

  grep -q "PHASE_ARG=push" "$TMP/classify-unrelated-hook/recovery.log"
}

test_network_auth_shaped_failure_stays_push_phase() {
  # A push failure that looks like a transport/permission error at the
  # remote (no hook involved, no non-fast-forward) must also stay phase
  # "push" — must NOT be misclassified as gitleaks merely because it lacks
  # git's non-fast-forward hint text. `git fetch` must still succeed (a
  # fetch failure is handled separately, before recovery is ever invoked,
  # as static misconfiguration) — only the push itself must fail.
  new_fixture "$TMP/classify-network"
  chmod -R a-w "$TMP/classify-network/origin.git"

  printf 'local-changed\n' >>"$TMP/classify-network/work/tracked.txt"

  local fake_recovery="$TMP/classify-network/fake-recovery.sh"
  cat >"$fake_recovery" <<'FAKE'
#!/usr/bin/env bash
echo "PHASE_ARG=$6" >> "${FAKE_RECOVERY_LOG:?}"
exit 1
FAKE
  chmod +x "$fake_recovery"

  FAKE_RECOVERY_LOG="$TMP/classify-network/recovery.log" \
    AUTO_PUSH_RECOVERY_BIN="$fake_recovery" \
    RUN_INTERVAL_SECS=0 \
    bash "$SCRIPT" "$TMP/classify-network/work" classify-network
  local run_rc=$?
  chmod -R u+w "$TMP/classify-network/origin.git"
  [[ "$run_rc" -ne 0 ]] || { echo "expected the permission-denied push to fail"; return 1; }

  grep -q "PHASE_ARG=push" "$TMP/classify-network/recovery.log"
}

# ─── Task 3: daily LaunchAgent template + installer assertions ───────────
DAILY_PLIST="$REPO_ROOT/launchd/ai.smartclaw.schedule.daily-repo-export.plist.template"
AO_DAEMON_PLIST="$REPO_ROOT/launchd/ai.agento.ao-go-daemon.plist.template"
INSTALLER="$REPO_ROOT/scripts/install-hermes-scheduled-jobs.sh"

test_daily_plist_template_is_valid_and_complete() {
  [[ -f "$DAILY_PLIST" ]] || { echo "missing $DAILY_PLIST"; return 1; }
  plutil -lint "$DAILY_PLIST" && \
  grep -q '<key>StartCalendarInterval</key>' "$DAILY_PLIST" && \
  grep -q '@HOME@/llm_wiki:llm-wiki' "$DAILY_PLIST" && \
  grep -q '@HOME@/roadmap:roadmap' "$DAILY_PLIST" && \
  grep -q '@AO_GO_BIN@' "$DAILY_PLIST"
}

test_ao_daemon_plist_is_valid_and_persistent() {
  [[ -f "$AO_DAEMON_PLIST" ]] && \
  plutil -lint "$AO_DAEMON_PLIST" && \
  grep -q '<string>@AO_GO_BIN@</string>' "$AO_DAEMON_PLIST" && \
  grep -q '<string>daemon</string>' "$AO_DAEMON_PLIST" && \
  grep -A1 -q '<key>KeepAlive</key>' "$AO_DAEMON_PLIST" && \
  grep -A1 -q '<key>RunAtLoad</key>' "$AO_DAEMON_PLIST"
}

test_installer_wires_ao_go_bin_and_recovery_script() {
  grep -q 'ao-go-repo-recovery.sh' "$INSTALLER" && \
  grep -q '@AO_GO_BIN@' "$INSTALLER"
}

test_installer_boots_out_only_named_legacy_labels() {
  grep -q 'ai\.smartclaw\.schedule\.auto-push-llm-wiki' "$INSTALLER" && \
  grep -q 'com\.jleechan\.git-push-llm-wiki' "$INSTALLER" && \
  ! grep -qiE 'auto-push-roadmap|git-push-roadmap' "$INSTALLER"
}

test_failed_functional_canary_preserves_legacy_exporters() {
  local d="$TMP/install-stale-daemon"
  mkdir -p "$d/templates" "$d/fake-home/Library/LaunchAgents" "$d/shimbin"
  cp "$AO_DAEMON_PLIST" "$d/templates/"
  cp "$DAILY_PLIST" "$d/templates/"

  cat >"$d/shimbin/launchctl" <<'LAUNCHCTL'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${LAUNCHCTL_TRACE:?}"
case "${1:-}" in
  print)
    label="${2##*/}"
    grep -Fxq "$label" "${LAUNCHCTL_STATE:?}" 2>/dev/null || exit 1
    case "$label" in
      ai.agento.ao-go-daemon) printf '    pid = 123\n' ;;
      ai.smartclaw.schedule.daily-repo-export) printf '    runs = 1\n    last exit code = 1\n' ;;
    esac
    exit 0
    ;;
  bootstrap)
    label="$(awk '/<key>Label<\/key>/{getline; gsub(/^ +<string>|<\/string>$/,""); print; exit}' "$3")"
    grep -Fxq "$label" "${LAUNCHCTL_STATE:?}" 2>/dev/null || printf '%s\n' "$label" >>"$LAUNCHCTL_STATE"
    exit 0
    ;;
  bootout|enable|kickstart) exit 0 ;;
esac
exit 1
LAUNCHCTL
  chmod +x "$d/shimbin/launchctl"

  local rc=0
  PATH="$d/shimbin:$PATH" \
    HOME="$d/fake-home" \
    AO_GO_BIN="$FAKE_AO_GO" \
    AO_FAKE_STATUS_JSON='{"state":"ready","pid":123}' \
    LAUNCHCTL_TRACE="$d/launchctl.trace" \
    LAUNCHCTL_STATE="$d/launchctl.state" \
    INSTALL_READY_MAX_POLLS=1 \
    INSTALL_CANARY_MAX_POLLS=1 \
    LAUNCHD_TEMPLATES_DIR="$d/templates" \
    LAUNCHD_DIR="$d/fake-home/Library/LaunchAgents" \
    bash "$INSTALLER" >"$d/run.out" 2>"$d/run.err" || rc=$?

  [[ "$rc" -ne 0 ]] || { echo "failed canary installer unexpectedly succeeded"; return 1; }
  grep -q 'functional canary failed; preserving predecessor jobs' "$d/run.err" || {
    echo "missing canary failure: $(cat "$d/run.err")"; return 1;
  }
  ! grep -q 'bootout gui/.*/ai.smartclaw.schedule.auto-push-llm-wiki' "$d/launchctl.trace" || return 1
  ! grep -q 'bootout gui/.*/com.jleechan.git-push-llm-wiki' "$d/launchctl.trace" || return 1
}

test_unknown_migration_id_fails_closed() {
  local d="$TMP/unknown-migration-id"
  mkdir -p "$d"
  printf '%s\n' '{"migratedLaunchdJobIds":["unknown-job-id"]}' >"$d/jobs.json"
  {
    sed -n '/^DEFAULT_MIGRATED_JOB_IDS=(/,/^MIGRATED_JOB_IDS=()/p' "$INSTALLER"
    sed -n '/^migrated_target() {/,/^}/p' "$INSTALLER"
    sed -n '/^default_migrated_job_ids() {/,/^}/p' "$INSTALLER"
    sed -n '/^load_migrated_job_ids() {/,/^}/p' "$INSTALLER"
  } >"$d/helper.sh"

  if LIVE_JOBS="$d/jobs.json" /bin/bash -c 'set -uo pipefail; source "$1"; load_migrated_job_ids' _ "$d/helper.sh" >"$d/out" 2>"$d/err"; then
    echo "unknown migratedLaunchdJobId was accepted"
    return 1
  fi
  grep -q 'refusing unknown migratedLaunchdJobId: unknown-job-id' "$d/err"
}

test_export_repo_convergence_rejects_dirty_tracked_file() {
  local d="$TMP/dirty-convergence"
  mkdir -p "$d"
  new_fixture "$d"
  printf 'pending tracked export\n' >>"$d/work/tracked.txt"
  sed -n '/^export_repo_converged() {/,/^}/p' "$INSTALLER" >"$d/helper.sh"
  if /bin/bash -c 'set -uo pipefail; source "$1"; export_repo_converged "$2"' _ "$d/helper.sh" "$d/work"; then
    echo "dirty tracked worktree incorrectly passed convergence"
    return 1
  fi
}

# Black-box dry-run uniqueness (CodeRabbit round 2 / item 8): stand up
# a fake LAUNCHD_TEMPLATES_DIR containing one TEMPLATE plist, one
# STANDALONE plist for a different label, and one STANDALONE plist
# whose .plist.template twin exists. Run the installer in dry-run and
# capture the rendered labels. Each effective label MUST appear
# exactly once; standalone-with-template-twin MUST be skipped.
#
# Safety: HOME and AO_GO_BIN are explicitly overridden so the test
# cannot touch the real ~/Library/LaunchAgents or whatever real AO
# binary is on PATH. The installer exits 0 on a clean dry run.
test_installer_dry_run_uniqueness() {
  local d="$TMP/install-dryrun"
  mkdir -p "$d/templates" "$d/fake-home/Library/LaunchAgents" "$d/fake-state/cron"

  cat >"$d/templates/ai.smartclaw.schedule.daily-repo-export.plist.template" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>ai.smartclaw.schedule.daily-repo-export</string>
</dict></plist>
PLIST

  cat >"$d/templates/ai.smartclaw.schedule.standalone-only.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>ai.smartclaw.schedule.standalone-only</string>
</dict></plist>
PLIST

  # Standalone whose .plist.template twin exists -> MUST be skipped
  # (so it is NOT installed under its label twice).
  cat >"$d/templates/ai.smartclaw.schedule.shadow-target.plist.template" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>ai.smartclaw.schedule.shadow-target</string>
</dict></plist>
PLIST
  cp "$d/templates/ai.smartclaw.schedule.shadow-target.plist.template" "$d/templates/ai.smartclaw.schedule.shadow-target.plist"

  INSTALL_DRY_RUN=1 \
    HOME="$d/fake-home" \
    AO_GO_BIN="$FAKE_AO_GO" \
    LAUNCHD_TEMPLATES_DIR="$d/templates" \
    LAUNCHD_DIR="$d/fake-home/Library/LaunchAgents" \
    CRON_JOBS_FILE="$d/fake-state/cron/jobs.json" \
    HERMES_OPS_DIR="$d/fake-state" \
    /bin/bash "$INSTALLER" >"$d/run.out" 2>"$d/run.err"
  local rc=$?
  [[ "$rc" -eq 0 ]] || { echo "expected rc=0 on clean dry-run, got rc=$rc; err=$(cat "$d/run.err")"; return 1; }

  # Each effective label MUST appear exactly once. `daily-repo-export`
  # and `standalone-only` come from unique sources; `shadow-target`
  # comes ONLY from its .plist.template (the standalone twin is
  # skipped because its template twin exists).
  local daily_count standalone_count shadow_count
  daily_count=$(grep -c 'ai\.smartclaw\.schedule\.daily-repo-export' "$d/run.out" || true)
  standalone_count=$(grep -c 'ai\.smartclaw\.schedule\.standalone-only' "$d/run.out" || true)
  shadow_count=$(grep -c 'ai\.smartclaw\.schedule\.shadow-target' "$d/run.out" || true)
  [[ "$daily_count" == "1" ]] || { echo "daily-repo-export rendered $daily_count times, expected 1"; return 1; }
  [[ "$standalone_count" == "1" ]] || { echo "standalone-only rendered $standalone_count times, expected 1"; return 1; }
  [[ "$shadow_count" == "1" ]] || { echo "shadow-target rendered $shadow_count times (standalone+template twin), expected 1"; return 1; }

  # STRICTLY non-mutating dry-run: zero destination writes.
  local written
  written="$(find "$d/fake-home/Library/LaunchAgents" -maxdepth 1 -name '*.plist' 2>/dev/null || true)"
  [[ -z "$written" ]] || { echo "dry-run wrote to LaunchAgents: $written"; return 1; }
  local stray
  stray="$(find "$d/fake-home/Library/LaunchAgents" -maxdepth 1 -name '.ai.smartclaw.schedule.*.plis*' 2>/dev/null || true)"
  [[ -z "$stray" ]] || { echo "dry-run leaked a render temp: $stray"; return 1; }
  return 0
}

# Black-box plutil failure propagation (CodeRabbit round 2 / item 7):
# a malformed plist must cause the install to fail LOUDLY, not silently.
# The installer must track INSTALL_FAILED across loops and exit
# nonzero, NOT return 0 with the bad plist silently accepted.
test_installer_propagates_plutil_failure() {
  # NON-dry-run plutil failure path: the installer MUST install the
  # later clean plist, MUST NOT install the broken plist, and MUST
  # NOT touch any live state outside the fake HOME (no real launchctl,
  # no real cron HUP). Run under a stub launchctl that succeeds
  # trivially and a fake HOME whose jobs.json is absent so the no-down-
  # time gate skips the entire migration block.
  local d="$TMP/install-plutil-fail"
  mkdir -p "$d/templates" "$d/fake-home/Library/LaunchAgents" \
           "$d/fake-home/.smartclaw/cron" "$d/shimbin"

  # Fake launchctl: starts with NO labels loaded (print returns 1)
  # so the plutil failure test does not falsely report every label
  # as was_loaded=1 before backup exists. `bootstrap` succeeds and
  # records the actual Label key (extracted from $3) into a state
  # file so subsequent `print` calls would return 0 for that label.
  # `bootout` removes a previously-bootstrapped label so a re-install
  # path sees it as unloaded again.
  cat >"$d/shimbin/launchctl" <<'STUB'
#!/usr/bin/env bash
state="${LAUNCHCTL_STATE:-/tmp/.launchctl-state}"
case "$1" in
  print)
    label="$(printf '%s' "$2" | awk -F/ '{print $NF}')"
    if [[ -f "$state" ]] && grep -qx "$label" "$state"; then
      exit 0
    fi
    exit 1
    ;;
  bootout)
    label="$(printf '%s' "$2" | awk -F/ '{print $NF}')"
    if [[ -f "$state" ]] && grep -qx "$label" "$state"; then
      grep -vx "$label" "$state" >"$state.tmp" && mv "$state.tmp" "$state"
    fi
    exit 0
    ;;
  bootstrap)
    # In real launchctl's CLI: `launchctl bootstrap <domain> <path>`.
    # The plist path is the THIRD argument (not the second).
    echo "bootstrap $3" >>"${LAUNCHD_DIR}/.trace"
    if [[ -f "$3" ]]; then
      label="$(awk '/<key>Label<\/key>/{getline; gsub(/^ +<string>|<\/string>$/,""); print; exit}' "$3")"
      if [[ -n "$label" ]]; then
        mkdir -p "$(dirname "$state")"
        grep -qx "$label" "$state" 2>/dev/null || echo "$label" >>"$state"
      fi
    fi
    exit 0
    ;;
  enable) exit 0 ;;
esac
exit 0
STUB
  chmod +x "$d/shimbin/launchctl"

  cat >"$d/templates/ai.smartclaw.schedule.broken.plist.template" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>Label</key><string>ai.smartclaw.schedule.broken</string>
PLIST

  cat >"$d/templates/ai.smartclaw.schedule.clean.plist.template" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>ai.smartclaw.schedule.clean</string>
</dict></plist>
PLIST

  # No LIVE_JOBS file present => migration block never runs.
  PATH="$d/shimbin:$PATH" \
    HOME="$d/fake-home" \
    REPO_ROOT="$d" \
    AO_GO_BIN=/usr/bin/true \
    LAUNCHD_TEMPLATES_DIR="$d/templates" \
    LAUNCHD_DIR="$d/fake-home/Library/LaunchAgents" \
    bash "$INSTALLER" >"$d/run.out" 2>"$d/run.err"
  local rc=$?
  [[ "$rc" -ne 0 ]] || { echo "installer returned 0 for malformed plist (silent swallow regression); out=$(cat "$d/run.out")"; return 1; }
  { grep -q 'plutil -lint FAILED' "$d/run.err" || grep -q 'plutil -lint FAILED' "$d/run.out"; } \
    || { echo "expected plutil -lint FAILED marker; err=$(cat "$d/run.err") out=$(cat "$d/run.out")"; return 1; }

  # No broken plist must reach the destination. The INSTALL_FAILED
  # counter must be > 0 and overall rc must reflect it.
  [[ ! -f "$d/fake-home/Library/LaunchAgents/ai.smartclaw.schedule.broken.plist" ]] \
    || { echo "broken plist leaked into LaunchAgents (fail-closed mv regression)"; return 1; }
  # The later clean plist MUST have been installed: failure-isolation
  # contract ("one bad plist does not abort every other label") means
  # the well-known clean plist filename DOES exist.
  [[ -f "$d/fake-home/Library/LaunchAgents/ai.smartclaw.schedule.clean.plist" ]] \
    || { echo "later clean plist was NOT installed despite failure isolation"; ls "$d/fake-home/Library/LaunchAgents"; return 1; }
  plutil -lint "$d/fake-home/Library/LaunchAgents/ai.smartclaw.schedule.clean.plist" \
    || { echo "installed clean plist failed plutil -lint"; return 1; }
  # No render temp leftover.
  local stray
  stray="$(find "$d/fake-home/Library/LaunchAgents" -maxdepth 1 -name '.ai.smartclaw.schedule.*.plis*' 2>/dev/null || true)"
  [[ -z "$stray" ]] || { echo "render temp leaked: $stray"; return 1; }
  # No-down-time gate: when any plist install failed the migration
  # block MUST NOT touch jobs.json (caller explicitly did not provide
  # one) and the printed message MUST say so.
  grep -q 'install FAILURES detected' "$d/run.out" \
    || { echo "expected install FAILURES detected marker; out=$(cat "$d/run.out")"; return 1; }
  return 0
}

# No-downtime / rollback: when an already-loaded label's new plist
# fails to bootstrap, the previous plist MUST be restored so the label
# never silently disappears from launchd. We drive the helper with
# stub launchctl + pre-existing $dst contents.
test_installer_rolls_back_on_bootstrap_exhaustion() {
  # Use a NON-daily-repo-export label so the install function does
  # not hit the ao_go_bin_valid precheck that early-exits before
  # reaching the bootstrap loop. Drive _install_plist with a launchctl
  # stub that:
  #   - reports the label as LOADED (so was_loaded=1 triggers
  #     re-bootstrap on rollback);
  #   - FAILS every NEW bootstrap attempt for the new plist (forcing
  #     the retry loop to exhaust);
  #   - SUCCEEDS only the rollback re-bootstrap (so we observe the
  #     restore path was taken);
  #   - records every bootstrap invocation in a trace file we can assert
  #     on with EXACT counts (3 failed new attempts + 1 successful
  #     prior attempt).
  local d="$TMP/install-rollback"
  mkdir -p "$d/fake-home/Library/LaunchAgents"

  # A NON-daily label so we do not hit the ao_go_bin_valid skip
  # branch in _install_plist.
  local label="ai.smartclaw.schedule.rollback-fixture"
  local dst="$d/fake-home/Library/LaunchAgents/$label.plist"
  cat >"$dst" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>ai.smartclaw.schedule.rollback-fixture</string>
  <key>Marker</key><string>prior-plist</string>
</dict></plist>
PLIST

  # New template, well-formed, with a DIFFERENT Marker so a successful
  # rollback overwrites the new plist back to the old marker (and
  # also proves that backup was captured BEFORE the mv, not after).
  # Filename MUST derive the label the same way as the destination
  # plist (basename $src, strip .plist.template), so the installer
  # gets label=ai.smartclaw.schedule.rollback-fixture and not label=new.
  cat >"$d/${label}.plist.template" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>Label</key><string>${label}</string>
  <key>Marker</key><string>new-attempt</string>
</dict></plist>
PLIST

  local helper="$d/helper.sh"
  {
    sed -n '/^_install_plist() {/,/^}/p' "$INSTALLER"
    cat <<'STUB'
launchctl() {
  case "$1" in
    print)  return 0 ;;  # was_loaded check returns true -> re-bootstrap path
    bootout) return 0 ;;
    bootstrap)
      # $3 is the plist path. Mark new-attempt plists as failed and
      # the prior-plist backup as the rollback success. Log the
      # MARKER (extracted via grep) rather than the raw path, so the
      # test can count occurrences of each marker deterministically
      # rather than wrestling with NULs or whitespace in paths.
      local marker=""
      if [[ -f "$3" ]]; then
        marker="$(grep -o 'new-attempt\|prior-plist' "$3" | head -1)"
      fi
      : "${marker:=none}"
      echo "bootstrap:${marker}" >>"${LAUNCHD_DIR}/.trace"
      case "$marker" in
        new-attempt) return 1 ;;
        prior-plist) return 0 ;;
        *)           return 1 ;;  # unknown marker -- fail closed
      esac
      ;;
    enable) return 0 ;;
  esac
  return 0
}
export -f launchctl
STUB
  } >"$helper"

  # Capture real rc from the inner bash without toggling the
  # suite's global `set -e`/`set +e` (the suite intentionally runs
  # without errexit; toggling it here would leak to later tests).
  local rc=0
  if bash -c '
    set -uo pipefail
    d="$1"
    label="$2"
    HOME="$d/fake-home"
    LAUNCHD_DIR="$d/fake-home/Library/LaunchAgents"
    LAUNCHD_TEMPLATES_DIR="$d"
    REPO_ROOT="$d"
    HERMES_EXTRA_PATH=""
    GOG_EXTRA_PATH=""
    SLACK_BOT_TOKEN=""
    OPENCLAW_SLACK_BOT_TOKEN=""
    SLACK_USER_TOKEN=""
    INSTALL_DRY_RUN=0
    AO_GO_BIN=/usr/bin/true
    export HOME LAUNCHD_DIR LAUNCHD_TEMPLATES_DIR REPO_ROOT \
           HERMES_EXTRA_PATH GOG_EXTRA_PATH \
           SLACK_BOT_TOKEN OPENCLAW_SLACK_BOT_TOKEN \
           SLACK_USER_TOKEN INSTALL_DRY_RUN AO_GO_BIN label
    source "'"$helper"'"
    _install_plist "$d/${label}.plist.template"
    rc=$?
    echo "$rc"
    exit "$rc"
  ' _ "$d" "$label" >"$d/run.out" 2>"$d/run.err"; then
    rc=0
  else
    rc=$?
  fi

  [[ "$rc" -ne 0 ]] || { echo "expected installer to fail when all bootstrap attempts fail (got rc=$rc)"; cat "$d/run.out" >>"$d/run.err"; return 1; }

  # Restored content equals the OLD marker.
  grep -q 'prior-plist' "$dst" || {
    echo "rollback did NOT restore prior plist (regression: backup taken AFTER mv)"
    echo "current dst content: $(cat "$dst")"
    return 1
  }
  ! grep -q 'new-attempt' "$dst" || {
    echo "post-rollback dst still contains new-attempt marker (no-op rollback)"
    return 1
  }
  # EXACT bootstrap trace assertion: 3 new-attempt boots (all of which
  # were rejected by the stub) + 1 prior-plist boot (the rollback
  # restore). Distinguishing by Markers matters -- a generic >=4
  # count could be reached without a real rollback.
  local trace="$d/fake-home/Library/LaunchAgents/.trace"
  [[ -f "$trace" ]] || { echo "expected bootstrap trace at $trace"; return 1; }
  local new_count prior_count
  new_count=$(grep -c 'new-attempt' "$trace" || true)
  prior_count=$(grep -c 'prior-plist' "$trace" || true)
  [[ "$new_count" -eq 3 ]] \
    || { echo "expected 3 new-attempt boots, got $new_count"; cat "$trace"; return 1; }
  [[ "$prior_count" -eq 1 ]] \
    || { echo "expected exactly 1 prior-plist rollback boot, got $prior_count"; cat "$trace"; return 1; }
  return 0
}

# NOTE: real notifications regression tests deliberately live alongside
# the recovery adapter, where the AO state JSON is written. See
# test_recovery_state_file_contains_phase_session_harness_finalsha
# in tests/test_ao_go_repo_recovery.sh for the adapter-side coverage.
# The coordinator-side coverage here is structural: the script must
# contain a `recovery_alert` helper that pulls from a parseable state
# file, must NOT echo raw error_text, and must never double-prefix
# `[auto-push:...]`.
test_recovery_alert_helper_composes_required_fields() {
  grep -qE 'recovery_alert\(\)' "$SCRIPT" || return 1
  # Must NOT pass `error_text` directly to notify().
  if grep -nE 'notify ".*\$error_text"' "$SCRIPT"; then
    echo "raw \$error_text leaks to Slack"; return 1
  fi
  # Must NOT double-prefix `[auto-push:` on the recovery_alert output.
  if grep -nE 'recovery_alert.*\[auto-push:' "$SCRIPT"; then
    echo "double-prefix of [auto-push:...] detected"; return 1
  fi
  return 0
}

# Extracts the three functions recovery_alert depends on, in a self-
# contained helper file. Used by every recovery_alert black-box test
# so the execution includes _na and _jq_field too. The extraction
# picks up each function's whole body via sed between the open `{` and
# the matching closing `}` at column 0.
_extract_recovery_alert() {
  local target="$1"
  {
    sed -n '/^_na() {/,/^}/p'         "$SCRIPT"
    sed -n '/^_jq_field() {/,/^}/p'    "$SCRIPT"
    sed -n '/^recovery_alert() {/,/^}/p' "$SCRIPT"
  } >"$target"
}

test_unsafe_repo_name_sanitized_and_rejected() {
  # REPO_NAME that fails the exact-allowlist ^[A-Za-z0-9_-]+$ must be
  # refused (NOT lossy-sanitized) and the coordinator must exit
  # non-zero. The refusal message lands on stderr directly because
  # COMMIT_LOG has not yet been opened.
  bash "$SCRIPT" --repo "/tmp/some/repo:!!!" 2>"$TMP/empty.err"
  local rc=$?
  [[ "$rc" -ne 0 ]] || { echo "expected unsafe name to exit non-zero; rc=$rc"; return 1; }
  grep -q 'must match ' "$TMP/empty.err" || \
    { echo "expected explicit allowlist refusal; got: $(cat "$TMP/empty.err")"; return 1; }
  return 0
}

test_unsafe_repo_name_does_not_abort_subsequent_specs() {
  # When one spec has an unsafe REPO_NAME and a later spec is valid,
  # the unsafe spec must NOT cause `tee -a` on an empty COMMIT_LOG
  # nor abort the loop. The second valid spec must still be
  # processed (acquire lock → do_push → log written).
  new_fixture "$TMP/first"
  new_fixture "$TMP/second"
  printf 'changed\n' >>"$TMP/first/work/tracked.txt"
  printf 'changed\n' >>"$TMP/second/work/tracked.txt"

  bash "$SCRIPT" \
    --repo "$TMP/first/work:bad name!!" \
    --repo "$TMP/second/work:good-name" \
    2>"$TMP/multi.err"
  local rc=$?
  [[ "$rc" -ne 0 ]] || { echo "expected overall non-zero due to first spec"; return 1; }
  grep -q 'must match ' "$TMP/multi.err" || \
    { echo "expected allowlist refusal in stderr"; return 1; }

  # The second spec is good-name: its log file MUST have been written.
  [[ -f "$AUTO_PUSH_LOG_DIR/auto-push-good-name.log" ]] || \
    { echo "expected second spec's log at $AUTO_PUSH_LOG_DIR/auto-push-good-name.log"; return 1; }
  # And the bad-name spec must NOT have written any log/state file at
  # all (it never reached the LOCK_DIR step).
  [[ ! -f "$AUTO_PUSH_LOG_DIR/auto-push-bad name!!.log" ]] || \
    { echo "bad spec leaked log file"; return 1; }
  return 0
}

test_safe_repo_name_uses_exact_allowlist() {
  # Two production names: llm-wiki and roadmap. Both pass exactly.
  # Any attempt to silently sanitize a single mis-typed name must fail.
  local d="$TMP/allowlist"
  mkdir -p "$d"

  # Extract safe_repo_name in isolation (so test does not depend on
  # the full coordinator setup). Pass helper path as $0 (bash -c
  # positional 0) and value as $1.
  local helper="$d/helper.sh"
  sed -n '/^safe_repo_name() {/,/^}/p' "$SCRIPT" >"$helper"

  # Legitimate names must be accepted verbatim (no lossy drop).
  local got_llm got_road
  got_llm="$(LC_ALL=C bash -c '. "$0"; safe_repo_name "$1"' "$helper" 'llm-wiki')"
  got_road="$(LC_ALL=C bash -c '. "$0"; safe_repo_name "$1"' "$helper" 'roadmap')"
  [[ "$got_llm"  == "llm-wiki"  ]] || { echo "llm-wiki not accepted verbatim: [$got_llm]"; return 1; }
  [[ "$got_road" == "roadmap"   ]] || { echo "roadmap not accepted verbatim: [$got_road]"; return 1; }

  # Each unsafe variation must fail (no lossy sanitization).
  local bad
  for bad in 'Bad Name' 'has space' 'a/b' '../etc/passwd' 'foo.bar' 'with/slash' '' 'foo!bar'; do
    if LC_ALL=C bash -c '. "$0"; safe_repo_name "$1"' "$helper" "$bad" >/dev/null 2>&1; then
      echo "unsafe name [$bad] was accepted (allowlist regression)"
      return 1
    fi
  done
  return 0
}

test_recovery_alert_executes_with_real_state_file() {
  # Execute the `recovery_alert` helper for real, NOT source-grep.
  # Builds a JSON state file with controlled fields, sources the
  # helper in isolation (extracted by sed), invokes it, and asserts
  # EXACT output for every spec-required field.
  local d="$TMP/alert-helper"
  mkdir -p "$d"

  # JSON state with both primaryHarness and a different final harness
  # so the transition arrow must appear.
  cat >"$d/state.json" <<'JSON'
{"name":"myrepo","phase":"add","status":"resolved","sessionId":"sess-42","harness":"claude-code","finalSha":"deadbeefcafe0011","primaryHarness":"codex","fallbackHarness":"claude-code"}
JSON

  local helper="$d/helper.sh"
  _extract_recovery_alert "$helper"
  # The helper uses $REPO_NAME when composing [auto-push:...]
  local actual
  actual="$(REPO_NAME=myrepo RECOVERY_STATE_FILE="$d/state.json" \
    bash -c "source '$helper'; recovery_alert add RESOLVED '$d/state.json'")"

  local expected="[auto-push:myrepo] RESOLVED phase=add session=sess-42 harnessTransition=codex->claude-code finalSha=deadbeefcafe0011"
  [[ "$actual" == "$expected" ]] || {
    echo "expected: [$expected]"
    echo "actual:   [$actual]"
    return 1
  }
  return 0
}

test_recovery_alert_no_state_file_uses_na_placeholders() {
  # When no state file exists (e.g. adapter missing), the helper
  # must still produce [auto-push:...] with N-A placeholders and a
  # finalSha=N-A marker so operators see unambiguously that the
  # recovery never reported a final remote SHA.
  local helper="$TMP/helper-nostate.sh"
  _extract_recovery_alert "$helper"

  local actual
  actual="$(REPO_NAME=myrepo bash -c "source '$helper'; recovery_alert push UNAVAILABLE")"
  local expected="[auto-push:myrepo] UNAVAILABLE phase=push session=N-A harnessTransition=N-A finalSha=N-A"
  [[ "$actual" == "$expected" ]] || {
    echo "expected: [$expected]"
    echo "actual:   [$actual]"
    return 1
  }
  return 0
}

test_recovery_alert_started_phase_uses_na_placeholders() {
  # STARTED alert fires before the adapter produces its state file
  # (or when the adapter is missing). The repo MUST still be in the
  # [auto-push:...] prefix; session/harnessTransition/finalSha all
  # fall back to N-A as the spec requires.
  local helper="$TMP/helper-started.sh"
  _extract_recovery_alert "$helper"

  local actual
  actual="$(REPO_NAME=myrepo bash -c "source '$helper'; recovery_alert push STARTED")"
  local expected="[auto-push:myrepo] STARTED phase=push session=N-A harnessTransition=N-A finalSha=N-A"
  [[ "$actual" == "$expected" ]] || {
    echo "expected: [$expected]"
    echo "actual:   [$actual]"
    return 1
  }
  return 0
}

test_recovery_alert_state_file_with_empty_fields_uses_na() {
  # Defensive normalization at BOTH boundaries (adapter write_state
  # AND consumer-side recovery_alert): even an existing state file
  # that has been hand-crafted or corrupted to contain literal
  # empty strings or `null` for sessionId / harness /
  # primaryHarness / finalSha must collapse to "N-A" in the alert.
  # Phase value provided (push) is used; absent phase falls back to
  # the caller's arg.
  local d="$TMP/empty-fields"
  mkdir -p "$d"

  cat >"$d/state.json" <<'JSON'
{"name":"myrepo","phase":"push","status":"exhausted","sessionId":"","harness":"","primaryHarness":"","finalSha":""}
JSON

  local helper="$d/helper.sh"
  _extract_recovery_alert "$helper"

  local actual
  actual="$(REPO_NAME=myrepo bash -c '. "$0"; recovery_alert push EXHAUSTED "$1"' "$helper" "$d/state.json")"
  local expected="[auto-push:myrepo] EXHAUSTED phase=push session=N-A harnessTransition=N-A finalSha=N-A"
  [[ "$actual" == "$expected" ]] || {
    echo "expected: [$expected]"
    echo "actual:   [$actual]"
    return 1
  }
  return 0
}

# Black-box: stand up a real fixture repo whose `origin` remote is
# intentionally broken so `git fetch` fails inside do_push. Capture
# the COMMIT_LOG and assert a preflight UNAVAILABLE alert lands with
# the canonical format. Run via `slack_post` stubbing so we can read
# the exact text -- this exercises the alert path end-to-end through
# `notify`, NOT by grepping the script source.
test_git_fetch_failure_emits_preflight_terminal_alert() {
  local d="$TMP/fetch-fail"
  mkdir -p "$d"
  new_fixture "$d"

  # Point origin at a definitely-nonexistent local path for an
  # IMMEDIATE, deterministic fetch failure (no DNS / network noise).
  # `git fetch origin main` returns 128 right away.
  git -C "$d/work" remote set-url origin "$d/does-not-exist.git"

  bash "$SCRIPT" "$d/work" "fetch-fail" 2>"$d/run.err"
  local rc=$?
  [[ "$rc" -ne 0 ]] || { echo "expected non-zero on fetch failure"; return 1; }

  local log="$AUTO_PUSH_LOG_DIR/auto-push-fetch-fail.log"
  [[ -f "$log" ]] || { echo "expected per-repo log at $log"; ls "$AUTO_PUSH_LOG_DIR"; return 1; }

  # Find the exact [notify] line emitted by recovery_alert and assert
  # the canonical field set. Raw error text is allowed in the local
  # log (that's what `log` does), but it must NEVER enter the [notify]
  # payload -- compare ONLY the [notify] line below for any leak.
  local notify_line
  notify_line="$(grep '\[notify\] ' "$log" | head -1)"
  [[ "$notify_line" == *'[auto-push:fetch-fail] UNAVAILABLE phase=preflight session=N-A harnessTransition=N-A finalSha=N-A'* ]] \
    || { echo "preflight terminal alert mismatch: [$notify_line]"; return 1; }
  if printf '%s' "$notify_line" | grep -qE 'does-not-exist\.git|run\.err|tail -5|invalid'; then
    echo "raw error text leaked into [notify] line: [$notify_line]"; return 1
  fi
  return 0
}

# ─── Run suite ──────────────────────────────────────────────────────────
run_test normal_export_reaches_remote_main test_normal_export_reaches_remote_main
run_test legacy_two_argument_interface test_legacy_two_argument_interface
run_test coordinator_exports_two_repositories test_coordinator_exports_two_repositories
run_test untracked_files_are_not_committed test_untracked_files_are_not_committed
run_test llm_wiki_untracked_files_are_committed test_llm_wiki_untracked_files_are_committed
run_test normal_commit_runs_hooks test_normal_commit_runs_hooks
run_test no_force_or_no_verify_flags test_no_force_or_no_verify_flags
run_test remote_advanced_triggers_recovery_not_direct_cli test_remote_advanced_triggers_recovery_not_direct_cli
run_test ordinary_conflict_classified_as_push_phase test_ordinary_conflict_classified_as_push_phase
run_test secret_scan_hook_rejection_classified_as_gitleaks_phase test_secret_scan_hook_rejection_classified_as_gitleaks_phase
run_test unrelated_hook_rejection_stays_push_phase test_unrelated_hook_rejection_stays_push_phase
run_test network_auth_shaped_failure_stays_push_phase test_network_auth_shaped_failure_stays_push_phase
run_test daily_plist_template_is_valid_and_complete test_daily_plist_template_is_valid_and_complete
run_test ao_daemon_plist_is_valid_and_persistent test_ao_daemon_plist_is_valid_and_persistent
run_test installer_wires_ao_go_bin_and_recovery_script test_installer_wires_ao_go_bin_and_recovery_script
run_test installer_boots_out_only_named_legacy_labels test_installer_boots_out_only_named_legacy_labels
run_test failed_functional_canary_preserves_legacy_exporters test_failed_functional_canary_preserves_legacy_exporters
run_test unknown_migration_id_fails_closed test_unknown_migration_id_fails_closed
run_test export_repo_convergence_rejects_dirty_tracked_file test_export_repo_convergence_rejects_dirty_tracked_file
run_test recovery_alert_helper_composes_required_fields test_recovery_alert_helper_composes_required_fields
run_test unsafe_repo_name_sanitized_and_rejected test_unsafe_repo_name_sanitized_and_rejected
run_test unsafe_repo_name_does_not_abort_subsequent_specs test_unsafe_repo_name_does_not_abort_subsequent_specs
run_test safe_repo_name_uses_exact_allowlist test_safe_repo_name_uses_exact_allowlist
run_test recovery_alert_executes_with_real_state_file test_recovery_alert_executes_with_real_state_file
run_test recovery_alert_no_state_file_uses_na_placeholders test_recovery_alert_no_state_file_uses_na_placeholders
run_test recovery_alert_started_phase_uses_na_placeholders test_recovery_alert_started_phase_uses_na_placeholders
run_test recovery_alert_state_file_with_empty_fields_uses_na test_recovery_alert_state_file_with_empty_fields_uses_na
run_test git_fetch_failure_emits_preflight_terminal_alert test_git_fetch_failure_emits_preflight_terminal_alert
run_test installer_dry_run_uniqueness test_installer_dry_run_uniqueness
run_test installer_propagates_plutil_failure test_installer_propagates_plutil_failure
run_test installer_rolls_back_on_bootstrap_exhaustion test_installer_rolls_back_on_bootstrap_exhaustion

test_local_clean_ahead_pushes_and_converges() {
  # Fresh-CB: local working tree is clean (no tracked changes, no
  # untracked), but a local commit has never been pushed (local HEAD
  # is fast-forward ahead of origin/main). The exporter MUST detect
  # this and run a normal hook-enabled `git push origin HEAD:main`,
  # then fresh-fetch and verify the SHAs converge. The remote must
  # advance to the local HEAD.
  local d="$TMP/local-ahead"
  mkdir -p "$d"
  new_fixture "$d"

  # A real local commit that the prior setup did NOT push. This is
  # the canonical "I committed but never pushed" state the
  # coordinator must handle.
  printf 'local-unpushed\n' >>"$d/work/tracked.txt"
  git -C "$d/work" commit -am "local unpublished commit" >/dev/null
  local local_sha
  local_sha="$(git -C "$d/work" rev-parse HEAD)"

  RUN_INTERVAL_SECS=0 bash "$SCRIPT" "$d/work" "fixture"
  local rc=$?
  [[ "$rc" -eq 0 ]] || { echo "exporter failed on local-ahead; rc=$rc"; cat "$d/logs/auto-push-fixture.log" 2>/dev/null || true; return 1; }

  # local SHA unchanged (no new commits were made by the exporter).
  local after_local_sha after_remote_sha
  after_local_sha="$(git -C "$d/work" rev-parse HEAD)"
  after_remote_sha="$(git --git-dir="$d/origin.git" show-ref --hash refs/heads/main)"

  [[ "$after_local_sha" == "$local_sha" ]] \
    || { echo "local HEAD moved unexpectedly: $after_local_sha vs $local_sha"; return 1; }
  [[ "$after_remote_sha" == "$local_sha" ]] \
    || { echo "origin/main did NOT advance to local HEAD: $after_remote_sha vs $local_sha"; return 1; }
  # Fresh-fetch SHA equality -- the verifier fetched origin and computed
  # remote_sha; they must equal $local_sha.
  git -C "$d/work" fetch --prune origin main >/dev/null 2>&1
  local fetched_remote
  fetched_remote="$(git -C "$d/work" rev-parse refs/remotes/origin/main)"
  [[ "$fetched_remote" == "$local_sha" ]] \
    || { echo "fetched remote $fetched_remote != local $local_sha"; return 1; }
  return 0
}

test_mixed_untracked_recovery_recomputes_local_head() {
  local d="$TMP/mixed-untracked-recovery"
  mkdir -p "$d"
  new_fixture "$d"
  git clone "$d/origin.git" "$d/other" >/dev/null 2>&1
  git -C "$d/other" config user.name Fixture
  git -C "$d/other" config user.email ${GITHUB_USER}@users.noreply.github.com
  printf 'remote\n' >"$d/other/remote.txt"
  git -C "$d/other" add remote.txt
  git -C "$d/other" commit -m "remote advance" >/dev/null
  git -C "$d/other" push origin main >/dev/null

  printf 'local\n' >>"$d/work/tracked.txt"
  git -C "$d/work" commit -am "local unpublished" >/dev/null
  printf 'leave me untracked\n' >"$d/work/untracked.txt"

  cat >"$d/recover.sh" <<'RECOVER'
#!/usr/bin/env bash
set -euo pipefail
repo=""
while [[ $# -gt 0 ]]; do
  case "$1" in --repo) repo="$2"; shift 2 ;; *) shift ;; esac
done
git -C "$repo" fetch origin main >/dev/null
git -C "$repo" rebase refs/remotes/origin/main >/dev/null
git -C "$repo" push origin HEAD:main >/dev/null
RECOVER
  chmod +x "$d/recover.sh"

  AUTO_PUSH_RECOVERY_BIN="$d/recover.sh" RUN_INTERVAL_SECS=0 \
    bash "$SCRIPT" "$d/work" mixed-recovery
  local local_sha remote_sha
  local_sha="$(git -C "$d/work" rev-parse HEAD)"
  remote_sha="$(git --git-dir="$d/origin.git" rev-parse refs/heads/main)"
  [[ "$local_sha" == "$remote_sha" ]] && [[ -f "$d/work/untracked.txt" ]]
}

run_test local_clean_ahead_pushes_and_converges test_local_clean_ahead_pushes_and_converges
run_test mixed_untracked_recovery_recomputes_local_head test_mixed_untracked_recovery_recomputes_local_head

echo ""
echo "Passed: $PASSED, Failed: $FAILED"
[[ "$FAILED" -eq 0 ]]
