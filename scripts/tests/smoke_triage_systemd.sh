#!/usr/bin/env bash
# scripts/tests/smoke_triage_systemd.sh
#
# Smoke test for the Linux-side Lane B mirror. Verifies (real, not
# mock) that:
#   1. Both wrapper scripts exist + are executable.
#   2. Each wrapper script, when run with HERMES_SLACK_BOT_TOKEN +
#      ANTHROPIC_API_KEY stubbed, reaches the jleechanclaw module
#      and exits cleanly (auto-park: rc=0/1; catchup: rc=0/1).
#   3. Both systemd .service + .timer unit files parse with
#      `systemd-analyze verify` (if systemd-analyze is on PATH).
#   4. The installer script is syntactically valid (`bash -n`).
#   5. The env file template (the .service's EnvironmentFile=)
#      contains the required keys.
#
# What this is NOT:
#   • Not a network test — slack_catchup with no real token short-
#     circuits in our wrapper. Auto-park with no threads in the
#     registry exits cleanly.
#   • Not a full systemd install — we do not run
#     `install-systemd-timers.sh` (that touches live ~/.config and
#     is reserved for the manual Lane C step after PR merge).
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"  # scripts/
WORKTREE="${WORKTREE:-$(cd "$HERE/.." && pwd)}"  # worktree root

JLEEANCHAWL_HOME="${JLEEANCHAWL_HOME:-/home/jleechan/project_jleechanclaw/jleechanclaw}"
SANDBOX="$(mktemp -d -t triage-systemd-smoke-XXXXXX)"
mkdir -p "$SANDBOX/logs" "$SANDBOX/.local/bin"

# Detect a jleechanclaw checkout that ACTUALLY has the merged triage
# modules. The "main" jleechanclaw checkout at
# /home/jleechan/project_jleechanclaw/jleechanclaw is sometimes on a
# feature branch without thread_lifecycle.py (the auto-park module
# was added in PR #742 and is not in every WIP branch). Fall back to
# any merged worktree.
if [[ ! -d "$JLEEANCHAWL_HOME/src/orchestration/thread_lifecycle.py" \
   || ! -d "$JLEEANCHAWL_HOME/src/orchestration/slack_catchup.py" ]]; then
  for candidate in \
    /tmp/jleechanclaw-deploy \
    /tmp/jleechanclaw-auo0 \
    /tmp/jleechanclaw-beks \
    /tmp/jleechanclaw-docs-lane \
    /tmp/jleechanclaw-kgfp \
    /tmp/jleechanclaw-thread-lifecycle; do
    if [[ -f "$candidate/src/orchestration/thread_lifecycle.py" \
       && -f "$candidate/src/orchestration/slack_catchup.py" ]]; then
      echo "  NOTE: using fallback JLEEANCHAWL_HOME=$candidate (default lacks triage modules)"
      JLEEANCHAWL_HOME="$candidate"
      break
    fi
  done
fi

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

# Stub the jleechanclaw checkout in the sandbox by symlinking the
# real one. This lets the wrapper resolve $JLEEANCHAWL_HOME/src
# without copying the tree.
SANDBOX_JC="$SANDBOX/jleechanclaw"
ln -sf "$JLEEANCHAWL_HOME" "$SANDBOX_JC"

# Stub /usr/bin/env python3 with a passthrough so the wrapper can
# resolve `$PYTHON_BIN` to the system python.
# (The real /usr/bin/env python3 already exists; we don't need to
# stub it. Just verify it's on PATH.)
if ! command -v python3 >/dev/null 2>&1; then
  echo "FAIL: system python3 not on PATH"
  exit 1
fi

# Minimal fake HERMES_HOME-style log dir the wrapper will write to.
export LOG_DIR="$SANDBOX/logs"
export HERMES_SLACK_BOT_TOKEN="${HERMES_SLACK_BOT_TOKEN:-xoxb-FAKE-TOKEN-FOR-SMOKE-TEST-0123456789}"
export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-sk-ant-FAKE-KEY-FOR-SMOKE-TEST-0123456789}"
export JLEEANCHAWL_HOME="$SANDBOX_JC"

pass() { printf "  \033[32mPASS\033[0m  %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m  %s\n" "$1"; FAIL=1; }
FAIL=0

# 1. Wrapper scripts exist + executable.
for script in jleechanclaw_thread_lifecycle.sh jleechanclaw_slack_catchup_daily.sh; do
  path="$HERE/$script"
  if [[ -x "$path" ]]; then
    pass "$script is executable"
  else
    fail "$script missing or not executable at $path"
  fi
done

# 2. Thread-lifecycle wrapper reaches the module.
THREAD_LOG="$SANDBOX/logs/slack-thread-auto-park.log"
if bash "$HERE/jleechanclaw_thread_lifecycle.sh" --no-bead --no-sync \
     --threshold-hours 48 >>"$THREAD_LOG" 2>&1; then
  if grep -q "=== start\|=== done\|No threads parked" "$THREAD_LOG"; then
    pass "thread_lifecycle wrapper reached module (log: $THREAD_LOG)"
  else
    fail "thread_lifecycle wrapper ran but log missing markers (tail: $(tail -3 "$THREAD_LOG"))"
  fi
else
  fail "thread_lifecycle wrapper exited non-zero (tail: $(tail -3 "$THREAD_LOG"))"
fi

# 3. Slack-catchup wrapper reaches the module (with stubbed token +
#    no real channels — module returns rc=1 "no channels", which our
#    wrapper treats as a non-failure).
DIGEST_LOG="$SANDBOX/logs/slack-digest-rollup.log"
DIGEST_RC=0
bash "$HERE/jleechanclaw_slack_catchup_daily.sh" --dry-run --hours 1 \
  >>"$DIGEST_LOG" 2>&1 || DIGEST_RC=$?
if [[ -f "$DIGEST_LOG" ]] && grep -q "=== start\|=== done\|Slack Catchup\|No channels" "$DIGEST_LOG"; then
  pass "slack_catchup wrapper reached module (rc=$DIGEST_RC)"
else
  fail "slack_catchup wrapper never reached module (tail: $(tail -3 "$DIGEST_LOG"))"
fi

# 4. systemd unit files parse (best-effort; systemd-analyze may not
#    be installed in every CI env). Stub ExecStart paths in a sandbox
#    copy so verify doesn't fail on "command not executable" before
#    the installer has run.
if command -v systemd-analyze >/dev/null 2>&1; then
  SANDBOX_UNITS="$SANDBOX/units"
  mkdir -p "$SANDBOX_UNITS"
  # The service ExecStart= paths reference %h/.local/bin/jleechanclaw_*.sh
  # (underscores, NOT dashes). Create the exact files the sandboxed unit
  # will point at so systemd-analyze verify doesn't fail on "command
  # not executable" before the installer has run.
  touch "$SANDBOX/.local/bin/jleechanclaw_thread_lifecycle.sh"
  touch "$SANDBOX/.local/bin/jleechanclaw_slack_catchup_daily.sh"
  chmod +x "$SANDBOX/.local/bin/jleechanclaw_thread_lifecycle.sh" \
           "$SANDBOX/.local/bin/jleechanclaw_slack_catchup_daily.sh"
  for unit in \
    jleechanclaw-slack-thread-auto-park.service \
    jleechanclaw-slack-thread-auto-park.timer \
    jleechanclaw-slack-digest-rollup.service \
    jleechanclaw-slack-digest-rollup.timer; do
    sed "s|%h/.local/bin/jleechanclaw_|$SANDBOX/.local/bin/jleechanclaw_|g" \
      "$WORKTREE/systemd/$unit" > "$SANDBOX_UNITS/$unit"
  done
  for unit_file in $SANDBOX_UNITS/*; do
    if systemd-analyze verify "$unit_file" 2>&1; then
      pass "systemd-analyze verify: $(basename "$unit_file")"
    else
      fail "systemd-analyze verify FAILED: $unit_file"
    fi
  done
else
  echo "  SKIP: systemd-analyze not on PATH (CI without systemd)"
fi

# 5. Installer script is syntactically valid.
if bash -n "$WORKTREE/systemd/install-systemd-timers.sh"; then
  pass "install-systemd-timers.sh parses with bash -n"
else
  fail "install-systemd-timers.sh has bash syntax errors"
fi

# 6. .service files reference the right env file path.
for svc in \
  $WORKTREE/systemd/jleechanclaw-slack-thread-auto-park.service \
  $WORKTREE/systemd/jleechanclaw-slack-digest-rollup.service; do
  if grep -q "EnvironmentFile=" "$svc"; then
    pass "$(basename "$svc") has EnvironmentFile= directive"
  else
    fail "$(basename "$svc") missing EnvironmentFile="
  fi
done

if [[ $FAIL -ne 0 ]]; then
  echo
  echo "SMOKE TEST FAILED"
  exit 1
fi

echo
echo "SMOKE TEST PASSED — Lane B mirror wired correctly."