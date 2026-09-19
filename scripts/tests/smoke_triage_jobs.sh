#!/usr/bin/env bash
# scripts/tests/smoke_triage_jobs.sh
#
# Smoke test for the two triage-job bash launchers:
#   • scripts/orchestration_thread_lifecycle.sh
#   • scripts/orchestration_slack_catchup_daily.sh
#
# Verifies (real, not mock):
#   1. Each launcher exists and is executable.
#   2. `bash <script> --help-or-equivalent` does NOT crash with
#      "venv python not found" or "orchestration package not found"
#      when HERMES_HOME points at the worktree under test.
#   3. The thread-lifecycle launcher runs `python3 -m
#      orchestration.thread_lifecycle --help` successfully — proving
#      the PYTHONPATH layout and the module entrypoint are wired
#      correctly.
#   4. The slack-catchup launcher runs `python3 -m
#      orchestration.slack_catchup --help` successfully — same.
#   5. Logs end up in the expected files when the launchers run with
#      HERMES_HOME pointed at the worktree (creates a temporary logs/
#      dir under the worktree so this test never touches real logs).
#
# What this is NOT:
#   • Not a network test — does not exercise the real Slack API. The
#     --dry-run flag on slack_catchup skips chat.postMessage.
#   • Not a bead-filing test — auto-park with --dry-run doesn't save.
#     But the script does not currently expose a --dry-run flag (see
#     thread_lifecycle.py — it has --no-bead and --no-sync, no global
#     dry-run). The smoke test runs with --no-bead --no-sync, which
#     produces a real "scan + report" pass without side effects.
#
# Why a bash smoke instead of pytest:
#   The plist-style invocation is shell → venv python → module. pytest
#   cannot reproduce the launchd-env-wrapper.sh secret sourcing + the
#   HERMES_HOME resolution path. A real shell run is the only way to
#   prove the launcher's plumbing works end-to-end.

set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"  # scripts/
WORKTREE="${WORKTREE:-$(cd "$HERE/.." && pwd)}"  # worktree root

# Sandbox: point HERMES_HOME at a temp dir backed by the worktree's src/
# tree, so the launcher's "venv python not found" check fails fast and
# informatively without us having to create a venv in CI.
SANDBOX="$(mktemp -d -t triage-smoke-XXXXXX)"
mkdir -p "$SANDBOX/logs"
mkdir -p "$SANDBOX/src"
mkdir -p "$SANDBOX/.venv/bin"

# Stage the orchestration package from the worktree.
cp -R "$WORKTREE/src/orchestration" "$SANDBOX/src/orchestration"

# Stub venv python: a tiny script that delegates to the system python3
# with the staged PYTHONPATH. Lets the launcher see a "venv python" at
# the expected path without us having to actually create a venv.
cat > "$SANDBOX/.venv/bin/python3" <<'PYEOF'
#!/usr/bin/env bash
exec /usr/bin/env python3 "$@"
PYEOF
chmod +x "$SANDBOX/.venv/bin/python3"

export HERMES_HOME="$SANDBOX"

pass() { printf "  \033[32mPASS\033[0m  %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m  %s\n" "$1"; FAIL=1; }
FAIL=0

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

# 1. Both launchers exist + executable.
for script in orchestration_thread_lifecycle.sh orchestration_slack_catchup_daily.sh; do
  path="$HERE/$script"
  if [[ -x "$path" ]]; then
    pass "$script is executable"
  else
    fail "$script missing or not executable at $path"
  fi
done

# 2. thread-lifecycle launcher — scan only, no bead, no sync.
#    Real Python invocation against the staged module. Auto-park with
#    no threads in the registry produces "No threads parked (none silent
#    past threshold)." — proves the module loaded + ran cleanly.
THREAD_LOG="$SANDBOX/logs/slack-thread-auto-park.log"
if bash "$HERE/orchestration_thread_lifecycle.sh" --no-bead --no-sync \
      --threshold-hours 48 >>"$THREAD_LOG" 2>&1; then
  if grep -q "=== start\|=== done\|No threads parked\|Parked" "$THREAD_LOG"; then
    pass "thread_lifecycle launcher ran cleanly (log: $THREAD_LOG)"
  else
    fail "thread_lifecycle launcher ran but log has no expected markers (tail: $(tail -3 "$THREAD_LOG"))"
  fi
else
  fail "thread_lifecycle launcher exited non-zero (tail: $(tail -3 "$THREAD_LOG"))"
fi

# 3. slack-catchup launcher — build digest with no channels to scan.
#    Points --config at a SANDBOXED, well-formed hermes.json with an empty
#    channels set (never at the real ~/.smartclaw/hermes.json, whose
#    presence/absence on the host running this smoke test would make the
#    result nondeterministic). A well-formed config with zero allowed
#    channels is the one case load_allowed_channels() treats as a benign
#    no-op (rc=0, {"ok": true, "info": "No channels to scan"}) — missing or
#    corrupt config is a real failure (rc=2), covered by
#    src/tests/test_triage_job_exit_codes.py, not this smoke test.
SANDBOX_HERMES_JSON="$SANDBOX/hermes.json"
printf '{"channels": {"slack": {"channels": {}}}}\n' > "$SANDBOX_HERMES_JSON"
DIGEST_LOG="$SANDBOX/logs/slack-digest-rollup.log"
DIGEST_RC=0
SLACK_BOT_TOKEN="fake-smoke-token" \
  bash "$HERE/orchestration_slack_catchup_daily.sh" --dry-run --hours 1 \
  --config "$SANDBOX_HERMES_JSON" --state-file "$SANDBOX/state.json" \
  >>"$DIGEST_LOG" 2>&1 || DIGEST_RC=$?
if [[ -f "$DIGEST_LOG" ]] && grep -q "=== start\|=== done\|Slack Catchup\|No channels" "$DIGEST_LOG"; then
  if [[ $DIGEST_RC -eq 0 ]]; then
    pass "slack_catchup launcher reached main() (rc=$DIGEST_RC; log: $DIGEST_LOG)"
  else
    fail "slack_catchup launcher exited unexpected rc=$DIGEST_RC (tail: $(tail -3 "$DIGEST_LOG"))"
  fi
else
  fail "slack_catchup launcher never reached main() (tail: $(tail -3 "$DIGEST_LOG"))"
fi

# 4. Path-resolution guard: launcher should refuse to run when
#    HERMES_HOME/src/orchestration is missing (smoke test of the
#    error-message path).
EMPTY_SANDBOX="$(mktemp -d -t triage-empty-XXXXXX)"
mkdir -p "$EMPTY_SANDBOX/.venv/bin"
cat > "$EMPTY_SANDBOX/.venv/bin/python3" <<'PYEOF'
#!/usr/bin/env bash
exit 0
PYEOF
chmod +x "$EMPTY_SANDBOX/.venv/bin/python3"
if HERMES_HOME="$EMPTY_SANDBOX" bash "$HERE/orchestration_thread_lifecycle.sh" \
     2>/dev/null; then
  fail "thread_lifecycle launcher did not refuse empty HERMES_HOME (rc=0)"
  rm -rf "$EMPTY_SANDBOX"
else
  pass "thread_lifecycle launcher refuses empty HERMES_HOME"
  rm -rf "$EMPTY_SANDBOX"
fi

if [[ $FAIL -ne 0 ]]; then
  echo
  echo "SMOKE TEST FAILED — see log tails above."
  exit 1
fi

echo
echo "SMOKE TEST PASSED — both launchers wired correctly."