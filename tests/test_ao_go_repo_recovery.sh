#!/usr/bin/env bash
# test_ao_go_repo_recovery.sh
#
# Deterministic state-machine coverage for scripts/ao-go-repo-recovery.sh
# using a fake Go AO CLI (argv-logging, counter-controlled). Proves the
# spawn/poll/switch/verify contract without a real AO daemon or provider.
# Real Go AO spawn/switch evidence lives in
# testing_llm/daily_repo_export_real_ao.md.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
RECOVERY="$REPO_ROOT/scripts/ao-go-repo-recovery.sh"

[[ -f "$RECOVERY" ]] || { echo "FAIL: recovery script not found at $RECOVERY"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test_ao_recovery.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

PASSED=0
FAILED=0
pass() { echo "PASS: $1"; PASSED=$((PASSED + 1)); }
fail() { echo "FAIL: $1"; FAILED=$((FAILED + 1)); }

run_test() {
  local name="$1" fn="$2"
  if "$fn" >"$TMP/$name.out" 2>&1; then
    pass "$name"
  else
    fail "$name"
    sed 's/^/    /' "$TMP/$name.out"
  fi
}

assert_contains() {
  local file="$1" needle="$2"
  grep -qF -- "$needle" "$file" || { echo "expected [$file] to contain: $needle"; cat "$file" >&2; return 1; }
}

assert_not_contains() {
  local file="$1" needle="$2"
  ! grep -qF -- "$needle" "$file" || { echo "expected [$file] to NOT contain: $needle"; cat "$file" >&2; return 1; }
}

# ─── Fake Go AO CLI ─────────────────────────────────────────────────────────
# Controlled via env: AO_FAKE_LOG (argv log), AO_FAKE_DAEMON_STATE
# (running|stale), AO_FAKE_PROJECT_EXISTS, AO_FAKE_SESSION_ID,
# AO_FAKE_SPAWN_FAIL, AO_FAKE_TERMINATED_AFTER (poll-call count at which
# isTerminated flips true; unset = never terminated).
write_fake_ao() {
  cat >"$FAKE_AO_SCRIPT" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
: "${AO_FAKE_LOG:?AO_FAKE_LOG required}"
printf '%s\n' "$*" >>"$AO_FAKE_LOG"

case "${1:-}" in
  version)
    exit 0
    ;;
  status)
    # Real "ao status --json" reports "ready" when healthy (verified live
    # against a real headless `ao daemon` in this session) — never "running".
    state="${AO_FAKE_DAEMON_STATE:-ready}"
    printf '{"state":"%s"}\n' "$state"
    exit 0
    ;;
  project)
    case "${2:-}" in
      get) [[ "${AO_FAKE_PROJECT_EXISTS:-1}" == "1" ]] && exit 0 || exit 1 ;;
      add) exit 0 ;;
      *) exit 1 ;;
    esac
    ;;
  spawn)
    if [[ "${AO_FAKE_SPAWN_FAIL:-0}" == "1" ]]; then
      echo "spawn: AO capacity rejected" >&2
      exit 1
    fi
    sid="${AO_FAKE_SESSION_ID:-fixture-1}"
    echo "spawned session ${sid} (idle)"
    exit 0
    ;;
  session)
    case "${2:-}" in
      get)
        sid="${3:-}"
        countfile="${AO_FAKE_LOG}.getcount.${sid}"
        count=0
        [[ -f "$countfile" ]] && count="$(cat "$countfile")"
        count=$((count + 1))
        echo "$count" >"$countfile"
        terminated="false"
        if [[ -n "${AO_FAKE_TERMINATED_AFTER:-}" && "$count" -ge "${AO_FAKE_TERMINATED_AFTER}" ]]; then
          terminated="true"
        fi
        printf '{"session":{"id":"%s","status":"working","isTerminated":%s}}\n' "$sid" "$terminated"
        exit 0
        ;;
      switch) exit 0 ;;
      *) exit 1 ;;
    esac
    ;;
  send)
    exit 0
    ;;
  *)
    echo "fake-ao: unknown command $*" >&2
    exit 1
    ;;
esac
FAKE
  chmod +x "$FAKE_AO_SCRIPT"
}

build_fake_ao_binary() {
  local module_path="$1" output="$2" root="$3"
  mkdir -p "$root/cmd/ao"
  printf 'module %s\ngo 1.21\n' "$module_path" >"$root/go.mod"
  cat >"$root/cmd/ao/main.go" <<'GO'
package main
import (
  "os"
  "syscall"
)
func main() {
  script := os.Getenv("FAKE_AO_SCRIPT")
  if script == "" { os.Exit(2) }
  argv := append([]string{script}, os.Args[1:]...)
  if err := syscall.Exec(script, argv, os.Environ()); err != nil { os.Exit(126) }
}
GO
  ( cd "$root" && "$GO_FIXTURE_BIN" build -o "$output" ./cmd/ao )
}

new_repo_fixture() {
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

common_env() {
  local d="$1"
  # Test functions all run in this same shell process, so `export`ed fake-CLI
  # knobs from a prior test leak forward unless explicitly reset here.
  unset AO_FAKE_DAEMON_STATE AO_FAKE_TERMINATED_AFTER AO_FAKE_SPAWN_FAIL \
        AO_FAKE_PROJECT_EXISTS AO_FAKE_SESSION_ID 2>/dev/null || true
  export AO_GO_BIN="$FAKE_AO"
  export FAKE_AO_SCRIPT
  export AO_FAKE_LOG="$d/fake.log"
  : >"$AO_FAKE_LOG"
  export AO_PRIMARY_HARNESS=codex
  export AO_FALLBACK_HARNESS=claude-code
  export AO_RECOVERY_TIMEOUT_SECS=3
  export AO_POLL_SECS=0
  export AUTO_PUSH_LOG_DIR="$d/state"
  mkdir -p "$AUTO_PUSH_LOG_DIR"
}

# ─── Test cases ───────────────────────────────────────────────────────────

test_primary_success_no_switch() {
  local d="$TMP/success"
  mkdir -p "$d"
  new_repo_fixture "$d"
  write_fake_ao "$FAKE_AO"
  common_env "$d"

  local err="$d/err.txt"
  printf 'push rejected (non-fast-forward)\n' >"$err"

  # Remote already matches local: recovery's first remote_matches_local()
  # check should succeed immediately, before any switch.
  bash "$RECOVERY" --repo "$d/work" --name fixture --phase push --error-file "$err"

  assert_contains "$AO_FAKE_LOG" "spawn" && \
  assert_contains "$AO_FAKE_LOG" "codex" && \
  assert_not_contains "$AO_FAKE_LOG" "session switch"
}

test_session_name_stays_within_ao_limit() {
  # Real `ao spawn --name` rejects anything over 20 characters ("--name must
  # be 20 characters or fewer") — caught live against a real daemon, not by
  # this fixture, since the fake CLI never validated it. Regression-locks
  # the fix: a long --name PATH:NAME repo name must not overflow the limit.
  local d="$TMP/long-name"
  mkdir -p "$d"
  new_repo_fixture "$d"
  write_fake_ao "$FAKE_AO"
  common_env "$d"

  local err="$d/err.txt"
  printf 'push rejected\n' >"$err"

  bash "$RECOVERY" --repo "$d/work" --name "a-very-long-repository-name-that-overflows" \
    --phase push --error-file "$err"

  local logged_name
  logged_name="$(grep -oE -- '--name [^ ]+' "$AO_FAKE_LOG" | head -1 | cut -d' ' -f2)"
  [[ -n "$logged_name" ]] || { echo "no --name found in spawn argv"; return 1; }
  [[ "${#logged_name}" -le 20 ]] || { echo "--name '$logged_name' is ${#logged_name} chars, exceeds AO's 20-char limit"; return 1; }
}

test_primary_timeout_switches_to_fallback() {
  local d="$TMP/timeout"
  mkdir -p "$d"
  new_repo_fixture "$d"
  write_fake_ao "$FAKE_AO"
  common_env "$d"
  # Never terminated, never resolves remote -> must time out and switch.
  unset AO_FAKE_TERMINATED_AFTER 2>/dev/null || true

  # Diverge local from remote so remote_matches_local() never trivially passes.
  printf 'local-only\n' >>"$d/work/tracked.txt"
  git -C "$d/work" commit -am "local only" >/dev/null

  local err="$d/err.txt"
  printf 'push rejected (non-fast-forward)\n' >"$err"

  bash "$RECOVERY" --repo "$d/work" --name fixture --phase push --error-file "$err" && return 1

  assert_contains "$AO_FAKE_LOG" "spawn" && \
  assert_contains "$AO_FAKE_LOG" "codex" && \
  assert_contains "$AO_FAKE_LOG" "session switch fixture-1" && \
  assert_contains "$AO_FAKE_LOG" "claude-code"
}

test_primary_terminated_switches_to_fallback() {
  local d="$TMP/terminated"
  mkdir -p "$d"
  new_repo_fixture "$d"
  write_fake_ao "$FAKE_AO"
  common_env "$d"
  export AO_FAKE_TERMINATED_AFTER=1

  printf 'local-only\n' >>"$d/work/tracked.txt"
  git -C "$d/work" commit -am "local only" >/dev/null

  local err="$d/err.txt"
  printf 'push rejected (non-fast-forward)\n' >"$err"

  bash "$RECOVERY" --repo "$d/work" --name fixture --phase push --error-file "$err" && return 1

  assert_contains "$AO_FAKE_LOG" "session switch fixture-1" && \
  assert_contains "$AO_FAKE_LOG" "claude-code"
}

test_success_via_separate_worktree_syncs_repo() {
  # AO always works in its OWN worktree, never inside $REPO (verified live:
  # a real recovery run created /data/worktrees/<project>/<session> and left
  # $REPO's own checkout on its old, now-superseded commit). A naive
  # "$REPO local HEAD == origin/main" check would therefore NEVER resolve
  # even after a real, successful push — because $REPO's HEAD never moves on
  # its own.
  #
  # Success requires PROOF the pending local commit was actually
  # incorporated: git merge-base --is-ancestor <baseline local HEAD> <new
  # origin/main>. That is only true for a real merge — a cherry-pick or
  # rebase produces a different SHA and correctly does NOT satisfy this. Once
  # proven, $REPO is synced with `git merge --ff-only` only (never `git
  # reset --hard`, which would be able to discard commits).
  local d="$TMP/separate-worktree"
  mkdir -p "$d"
  new_repo_fixture "$d"
  write_fake_ao "$FAKE_AO"
  common_env "$d"
  export AO_FAKE_TERMINATED_AFTER=1

  # $REPO gets a local, unpushed, committed change (same state do_push()
  # leaves it in before calling recovery: clean working tree, one commit
  # ahead that failed to push).
  printf 'local-only\n' >>"$d/work/tracked.txt"
  git -C "$d/work" commit -am "local only" >/dev/null
  local baseline_local_head
  baseline_local_head="$(git -C "$d/work" rev-parse HEAD)"

  # An unrelated remote advance happens independently (clone B), same as any
  # real conflict scenario.
  git clone "$d/origin.git" "$d/clone-b" >/dev/null 2>&1
  git -C "$d/clone-b" config user.name "Fixture"
  git -C "$d/clone-b" config user.email "${GITHUB_USER}@users.noreply.github.com"
  printf 'remote-advance\n' >>"$d/clone-b/tracked.txt"
  git -C "$d/clone-b" commit -am "remote advance" >/dev/null
  git -C "$d/clone-b" push origin main >/dev/null 2>&1

  # Simulate the real agent: a SEPARATE clone (standing in for AO's own
  # worktree) fetches the pending local commit directly from $REPO (as AO's
  # worktree, sharing the registered project's object store, would see it)
  # and MERGES it — never cherry-picks — so the original commit stays a real
  # ancestor of the result. $REPO/work is never touched directly.
  git clone "$d/origin.git" "$d/ao-worktree" >/dev/null 2>&1
  git -C "$d/ao-worktree" config user.name "Fixture"
  git -C "$d/ao-worktree" config user.email "${GITHUB_USER}@users.noreply.github.com"
  git -C "$d/ao-worktree" fetch "$d/work" "$baseline_local_head" >/dev/null 2>&1
  git -C "$d/ao-worktree" merge --no-ff FETCH_HEAD -m "merge pending local commit" >/dev/null 2>&1 || {
    # Both branches appended to the same line — resolve like a real agent
    # would (keep both), then finish the merge commit.
    printf 'base\nremote-advance\nlocal-only\n' >"$d/ao-worktree/tracked.txt"
    git -C "$d/ao-worktree" add tracked.txt
    git -C "$d/ao-worktree" commit --no-edit >/dev/null
  }
  git -C "$d/ao-worktree" push origin main >/dev/null 2>&1
  local resolved_remote_sha
  resolved_remote_sha="$(git -C "$d/ao-worktree" rev-parse HEAD)"

  local err="$d/err.txt"
  printf 'push rejected (non-fast-forward)\n' >"$err"

  bash "$RECOVERY" --repo "$d/work" --name fixture --phase push --error-file "$err"

  local synced_head
  synced_head="$(git -C "$d/work" rev-parse HEAD)"
  [[ "$synced_head" == "$resolved_remote_sha" ]] || {
    echo "expected \$REPO synced to $resolved_remote_sha, got $synced_head (baseline was $baseline_local_head)"
    return 1
  }
  git -C "$d/work" merge-base --is-ancestor "$baseline_local_head" HEAD || {
    echo "pending local commit $baseline_local_head is not an ancestor of synced HEAD $synced_head"
    return 1
  }
  [[ -z "$(git -C "$d/work" status --porcelain)" ]]
}

test_unrelated_remote_advance_does_not_discard_or_succeed() {
  # Negative regression: origin/main moves, but WITHOUT incorporating the
  # pending local commit (a plain unrelated push, not a merge of it). This
  # must fail closed — never report success, and never lose the pending
  # local commit (no git reset --hard, no discard).
  local d="$TMP/unrelated-advance"
  mkdir -p "$d"
  new_repo_fixture "$d"
  write_fake_ao "$FAKE_AO"
  common_env "$d"
  unset AO_FAKE_TERMINATED_AFTER 2>/dev/null || true

  printf 'local-only\n' >>"$d/work/tracked.txt"
  git -C "$d/work" commit -am "local only" >/dev/null
  local baseline_local_head
  baseline_local_head="$(git -C "$d/work" rev-parse HEAD)"

  local err="$d/err.txt"
  printf 'push rejected (non-fast-forward)\n' >"$err"

  # Advance origin/main with something totally unrelated WHILE recovery is
  # (about to be) polling — never merges baseline_local_head at all.
  (
    sleep 1
    git clone "$d/origin.git" "$d/unrelated" >/dev/null 2>&1
    git -C "$d/unrelated" config user.name "Fixture"
    git -C "$d/unrelated" config user.email "${GITHUB_USER}@users.noreply.github.com"
    printf 'unrelated-change\n' >>"$d/unrelated/tracked.txt"
    git -C "$d/unrelated" commit -am "unrelated, does not include the pending commit" >/dev/null
    git -C "$d/unrelated" push origin main >/dev/null 2>&1
  ) &
  local bg_pid=$!

  bash "$RECOVERY" --repo "$d/work" --name fixture --phase push --error-file "$err" && { wait "$bg_pid"; return 1; }
  wait "$bg_pid"

  local head_after
  head_after="$(git -C "$d/work" rev-parse HEAD)"
  [[ "$head_after" == "$baseline_local_head" ]] || {
    echo "pending local commit was discarded: expected HEAD=$baseline_local_head, got $head_after"
    return 1
  }
  git -C "$d/work" cat-file -e "$baseline_local_head" || {
    echo "pending local commit object $baseline_local_head no longer exists"
    return 1
  }
}

test_remote_mismatch_after_claim_is_failure() {
  local d="$TMP/mismatch"
  mkdir -p "$d"
  new_repo_fixture "$d"
  write_fake_ao "$FAKE_AO"
  common_env "$d"
  export AO_FAKE_TERMINATED_AFTER=1

  printf 'local-only\n' >>"$d/work/tracked.txt"
  git -C "$d/work" commit -am "local only" >/dev/null

  local err="$d/err.txt"
  printf 'push rejected (non-fast-forward)\n' >"$err"

  # Worker "claims" done (isTerminated=true) but never actually pushed —
  # remote_matches_local() must stay false, so this must fail non-zero.
  bash "$RECOVERY" --repo "$d/work" --name fixture --phase push --error-file "$err" && return 1
  return 0
}

test_node_shebang_ao_binary_rejected() {
  local d="$TMP/node"
  mkdir -p "$d"
  new_repo_fixture "$d"

  local fake_node_ao="$d/node-ao"
  cat >"$fake_node_ao" <<'NODE'
#!/usr/bin/env node
console.log("not the real thing");
NODE
  chmod +x "$fake_node_ao"

  common_env "$d"
  export AO_GO_BIN="$fake_node_ao"

  local err="$d/err.txt"
  printf 'push rejected\n' >"$err"

  local out
  out="$(bash "$RECOVERY" --repo "$d/work" --name fixture --phase push --error-file "$err" 2>&1)" && return 1
  printf '%s\n' "$out" | grep -qi "Node AO CLI is not accepted" && \
  [[ ! -s "$AO_FAKE_LOG" ]]  # must reject before ever invoking the (fake) binary
}

test_ao_daemon_unavailable_fails_without_direct_cli() {
  local d="$TMP/daemon-down"
  mkdir -p "$d"
  new_repo_fixture "$d"
  write_fake_ao "$FAKE_AO"
  common_env "$d"
  export AO_FAKE_DAEMON_STATE=stale

  local err="$d/err.txt"
  printf 'push rejected\n' >"$err"

  bash "$RECOVERY" --repo "$d/work" --name fixture --phase push --error-file "$err" && return 1

  assert_not_contains "$AO_FAKE_LOG" "spawn" && \
  ! grep -qiE 'codex exec|claude ' "$RECOVERY"
}

test_gitleaks_prompt_has_invariants_and_sanitized_error() {
  local d="$TMP/gitleaks"
  mkdir -p "$d"
  new_repo_fixture "$d"
  write_fake_ao "$FAKE_AO"
  common_env "$d"

  local err="$d/err.txt"
  # A fake, obviously-synthetic 40-char token-shaped string standing in for
  # a real secret. Never a real credential.
  printf 'pre-push hook blocked: potential secret ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n' >"$err"

  bash "$RECOVERY" --repo "$d/work" --name fixture --phase gitleaks --error-file "$err"

  assert_contains "$AO_FAKE_LOG" "never force-push" && \
  assert_contains "$AO_FAKE_LOG" "never bypass" && \
  assert_not_contains "$AO_FAKE_LOG" "ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
}

test_harnesses_exhausted_nonzero_and_state_preserved() {
  local d="$TMP/exhausted"
  mkdir -p "$d"
  new_repo_fixture "$d"
  write_fake_ao "$FAKE_AO"
  common_env "$d"
  unset AO_FAKE_TERMINATED_AFTER 2>/dev/null || true

  printf 'local-only\n' >>"$d/work/tracked.txt"
  git -C "$d/work" commit -am "local only" >/dev/null

  local err="$d/err.txt"
  printf 'push rejected\n' >"$err"

  bash "$RECOVERY" --repo "$d/work" --name fixture --phase push --error-file "$err" && return 1

  local state_file="$AUTO_PUSH_LOG_DIR/ao-recovery-fixture-state.json"
  [[ -f "$state_file" ]] || { echo "expected state file at $state_file"; return 1; }
  jq -e '.status == "exhausted"' "$state_file" >/dev/null
}

# Build an AKIA-shaped test string at runtime (never as a contiguous literal
# in this tracked source file) so this test script itself never trips the
# real outgoing secret guard on push, while the FIXTURE content it writes to
# disposable /tmp repos is realistic enough for the REAL secret scanner
# (this machine's configured pre-push hook) to actually detect.
synth_secret() {
  printf '%s%s\n' "AKIA" "ABCDEFGHIJKLMNOP"
}

# Extracts ONLY independent_secret_scan_clean() and its scanner-pinning
# dependencies (pin/verify helpers + the env vars they read) from the
# recovery script, so it can be unit-tested directly without sourcing
# the whole script's top-level argument parsing (which would `exit 1`
# the test runner's own shell on missing --repo).
source_secret_scan_fn() {
  local target="$1"
  {
    echo 'unset TRUSTED_SCANNER_BIN TRUSTED_SCANNER_CHECKSUM TRUSTED_SCANNER_DIR'
    sed -n '/^clean_trusted_scanner() {/,/^}/p; /^pin_trusted_secret_scanner() {/,/^}/p; /^verify_trusted_secret_scanner_unmodified() {/,/^}/p; /^independent_secret_scan_clean() {/,/^}/p' "$RECOVERY"
    echo 'AUTO_PUSH_SECRET_SCAN_BIN="${AUTO_PUSH_SECRET_SCAN_BIN:-$HOME/.config/git/hooks/secret-scan.sh}"'
  } >"$target"
}

test_secret_scan_hook_invoked_with_correct_protocol() {
  # Skeptic round 2/A: the scanner is now the PINNED-TRUSTED SNAPSHOT
  # (not the live hook), invoked directly with secret-scan.sh's CLI:
  # mode <remote-name> <remote-url>, plus ref-update lines on stdin.
  # This regression locks the protocol: argc=3, mode=pre-push,
  # remote-name=origin, remote-url is the real one from $REPO.
  local d="$TMP/hook-protocol"
  mkdir -p "$d"
  new_repo_fixture "$d"

  mkdir -p "$d/scanner_src"
  cat >"$d/scanner_src/secret-scan.sh" <<'SCAN'
#!/usr/bin/env bash
LOG="${SCAN_LOG:?}"
if [[ $# -ne 3 ]]; then
  echo "BAD_ARGC=$#" >> "$LOG"
  exit 1
fi
if [[ "$1" != "pre-push" ]]; then
  echo "BAD_MODE=$1" >> "$LOG"
  exit 1
fi
if [[ "$2" != "origin" ]]; then
  echo "BAD_REMOTE_NAME=$2" >> "$LOG"
  exit 1
fi
if [[ "$3" != "${EXPECTED_REMOTE_URL:-}" ]]; then
  echo "BAD_REMOTE_URL=$3" >> "$LOG"
  exit 1
fi
echo "OK argc=$# mode=$1 remote_name=$2 remote_url=$3" >> "$LOG"
exit 0
SCAN
  chmod +x "$d/scanner_src/secret-scan.sh"

  local fn_snippet="$d/fn.sh"
  source_secret_scan_fn "$fn_snippet"

  local base_sha head_sha
  base_sha="$(git -C "$d/work" rev-parse HEAD)"
  printf 'extra\n' >>"$d/work/tracked.txt"
  git -C "$d/work" commit -am extra >/dev/null
  head_sha="$(git -C "$d/work" rev-parse HEAD)"

  EXPECTED_REMOTE_URL="$(git -C "$d/work" remote get-url origin)" \
    SCAN_LOG="$d/scanner.log" \
    AUTO_PUSH_SECRET_SCAN_BIN="$d/scanner_src/secret-scan.sh" \
    REPO="$d/work" bash -c "
      source '$fn_snippet'
      pin_trusted_secret_scanner
      independent_secret_scan_clean '$base_sha' '$head_sha'
    "
  local rc=$?

  assert_contains "$d/scanner.log" "OK argc=3 mode=pre-push remote_name=origin" && \
  [[ "$rc" -eq 0 ]]
}

test_real_configured_hook_integration_clean_and_dirty_ranges() {
  # Integration check against THIS MACHINE'S actual secret-scan.sh
  # (not a fixture-local fake) — proves the pinned-snapshot invocation
  # really works end to end with the real tool, in both directions.
  local d="$TMP/real-hook-integration"
  mkdir -p "$d"
  new_repo_fixture "$d"

  local real_scanner="$HOME/.config/git/hooks/secret-scan.sh"
  [[ -x "$real_scanner" ]] || {
    echo "SKIP: no real secret-scan.sh configured at $real_scanner"
    return 0
  }

  local fn_snippet="$d/fn.sh"
  source_secret_scan_fn "$fn_snippet"

  local base_sha clean_head_sha
  base_sha="$(git -C "$d/work" rev-parse HEAD)"
  printf 'perfectly ordinary content\n' >>"$d/work/tracked.txt"
  git -C "$d/work" commit -am "clean change" >/dev/null
  clean_head_sha="$(git -C "$d/work" rev-parse HEAD)"

  AUTO_PUSH_SECRET_SCAN_BIN="$real_scanner" REPO="$d/work" bash -c "
    source '$fn_snippet'
    pin_trusted_secret_scanner
    independent_secret_scan_clean '$base_sha' '$clean_head_sha'
  " || { echo "expected the real scanner to pass clean content"; return 1; }

  synth_secret >>"$d/work/tracked.txt"
  git -C "$d/work" commit -am "leaked change" >/dev/null
  local dirty_head_sha
  dirty_head_sha="$(git -C "$d/work" rev-parse HEAD)"

  AUTO_PUSH_SECRET_SCAN_BIN="$real_scanner" REPO="$d/work" bash -c "
    source '$fn_snippet'
    pin_trusted_secret_scanner
    independent_secret_scan_clean '$base_sha' '$dirty_head_sha'
  " && { echo "expected the real scanner to reject the leaked range"; return 1; }
  return 0
}

test_gitleaks_success_does_not_require_baseline_ancestor() {
  # Codex review P1 + follow-up correction: BASELINE_LOCAL_HEAD for a
  # gitleaks-phase failure is the commit that CONTAINS the blocked secret.
  # A correct fix rewrites/amends it out of $REPO's OWN checked-out branch
  # in place (not a push from a separate AO worktree branch, which would
  # leave $REPO's own main still on the secret commit and repeat the leak
  # on the next run) — the fixed commit must never be required to descend
  # from the blocked one.
  local d="$TMP/gitleaks-rewrite"
  mkdir -p "$d"
  new_repo_fixture "$d"
  write_fake_ao "$FAKE_AO"
  common_env "$d"
  unset AO_FAKE_TERMINATED_AFTER 2>/dev/null || true

  synth_secret >>"$d/work/tracked.txt"
  git -C "$d/work" commit -am "local commit containing a secret" >/dev/null
  local baseline_local_head
  baseline_local_head="$(git -C "$d/work" rev-parse HEAD)"

  local err="$d/err.txt"
  printf 'push rejected by secret scan\n' >"$err"

  # Simulate the real agent: operates directly on $REPO's own checked-out
  # branch (not a separate worktree) shortly after recovery captures its
  # initial state, amending the commit in place to remove the secret.
  (
    sleep 1
    printf 'safe-redacted-fix\n' >"$d/work/tracked.txt"
    git -C "$d/work" add tracked.txt
    git -C "$d/work" commit --amend -m "safe fix, no secret" >/dev/null
  ) &
  local bg_pid=$!

  bash "$RECOVERY" --repo "$d/work" --name fixture --phase gitleaks --error-file "$err"
  local rc=$?
  wait "$bg_pid"
  [[ "$rc" -eq 0 ]] || { echo "expected recovery to succeed via the in-place rewrite"; return 1; }

  ! git -C "$d/work" merge-base --is-ancestor "$baseline_local_head" refs/remotes/origin/main 2>/dev/null || {
    echo "test setup invariant broken: baseline should NOT be an ancestor of the safe fix"
    return 1
  }

  local final_local final_remote
  final_local="$(git -C "$d/work" rev-parse HEAD)"
  git -C "$d/work" fetch origin main >/dev/null 2>&1
  final_remote="$(git -C "$d/work" rev-parse refs/remotes/origin/main)"
  [[ "$final_local" == "$final_remote" ]] || {
    echo "expected \$REPO's own checked-out main to equal origin/main after gitleaks recovery"
    return 1
  }
  [[ -z "$(git -C "$d/work" status --porcelain)" ]]
}

test_gitleaks_second_run_is_a_noop_after_recovery() {
  # A second daily run against the SAME repo, after a successful gitleaks
  # recovery, must be a no-op: local main already equals origin/main, clean
  # tree, nothing left to export or re-block.
  local d="$TMP/gitleaks-second-run"
  mkdir -p "$d"
  new_repo_fixture "$d"
  write_fake_ao "$FAKE_AO"
  common_env "$d"
  unset AO_FAKE_TERMINATED_AFTER 2>/dev/null || true

  synth_secret >>"$d/work/tracked.txt"
  git -C "$d/work" commit -am "local commit containing a secret" >/dev/null

  local err="$d/err.txt"
  printf 'push rejected by secret scan\n' >"$err"

  (
    sleep 1
    printf 'safe-redacted-fix\n' >"$d/work/tracked.txt"
    git -C "$d/work" add tracked.txt
    git -C "$d/work" commit --amend -m "safe fix, no secret" >/dev/null
  ) &
  local bg_pid=$!

  bash "$RECOVERY" --repo "$d/work" --name fixture --phase gitleaks --error-file "$err"
  local rc=$?
  wait "$bg_pid"
  [[ "$rc" -eq 0 ]] || { echo "setup: expected the first gitleaks recovery to succeed"; return 1; }

  # Second run: the coordinator's own fast path (no working-tree diff,
  # local already equals origin/main) must be a clean no-op — never a
  # repeated push-blocked/recovery cycle.
  local second_run_out
  second_run_out="$(RUN_INTERVAL_SECS=0 bash "$REPO_ROOT/scripts/auto-push-to-main.sh" "$d/work" gitleaks-second-run 2>&1)"
  local second_rc=$?
  [[ "$second_rc" -eq 0 ]] || { echo "expected second run to succeed (no-op); got rc=$second_rc: $second_run_out"; return 1; }
  printf '%s\n' "$second_run_out" | grep -q "No changes" || {
    echo "expected second run to report no changes; got: $second_run_out"
    return 1
  }

  local final_local final_remote
  final_local="$(git -C "$d/work" rev-parse HEAD)"
  git -C "$d/work" fetch origin main >/dev/null 2>&1
  final_remote="$(git -C "$d/work" rev-parse refs/remotes/origin/main)"
  [[ "$final_local" == "$final_remote" ]]
}

test_gitleaks_fails_closed_if_published_range_still_has_secret() {
  # Negative case: the "fix" (amended in place on $REPO's own checked-out
  # branch, matching real agent behavior) still contains the secret. Must
  # fail closed — proves the independent secret scan is genuinely enforced,
  # not just "the commit changed".
  local d="$TMP/gitleaks-still-leaked"
  mkdir -p "$d"
  new_repo_fixture "$d"
  write_fake_ao "$FAKE_AO"
  common_env "$d"
  unset AO_FAKE_TERMINATED_AFTER 2>/dev/null || true

  synth_secret >>"$d/work/tracked.txt"
  git -C "$d/work" commit -am "local commit containing a secret" >/dev/null

  local err="$d/err.txt"
  printf 'push rejected by secret scan\n' >"$err"

  (
    sleep 1
    synth_secret >"$d/work/tracked.txt"
    git -C "$d/work" add tracked.txt
    git -C "$d/work" commit --amend -m "did not actually remove the secret" >/dev/null
  ) &
  local bg_pid=$!

  bash "$RECOVERY" --repo "$d/work" --name fixture --phase gitleaks --error-file "$err"
  local rc=$?
  wait "$bg_pid"
  [[ "$rc" -ne 0 ]] || { echo "expected recovery to fail closed on a still-leaked fix"; return 1; }
  return 0
}

test_add_commit_phase_does_not_trivially_succeed_when_head_unchanged() {
  # Codex review P2: for an "add"/"commit" failure, BASELINE_LOCAL_HEAD is
  # the OLD head (nothing was ever committed) — so local_sha == remote_sha
  # can be trivially true from the very first poll, before AO has done any
  # work. Must not report success on that alone; the intended pending
  # content must actually reach the remote.
  local d="$TMP/add-commit-trivial"
  mkdir -p "$d"
  new_repo_fixture "$d"
  write_fake_ao "$FAKE_AO"
  common_env "$d"
  unset AO_FAKE_TERMINATED_AFTER 2>/dev/null || true

  # $REPO local HEAD already equals origin/main (do_push's git add/commit
  # itself failed, so nothing new was ever committed) — but there is a
  # pending uncommitted change that was never exported anywhere.
  printf 'pending-not-exported\n' >>"$d/work/tracked.txt"

  local err="$d/err.txt"
  printf 'git add -u failed\n' >"$err"

  bash "$RECOVERY" --repo "$d/work" --name fixture --phase add --error-file "$err" && return 1
  return 0
}

test_add_commit_phase_succeeds_once_pending_content_exported() {
  # The pending content exists ONLY in $REPO's own working tree (worktrees
  # never share working-tree/index state) — a correct agent operates
  # directly on $REPO itself, so the simulated fix commits+pushes FROM
  # $REPO, never a separate clone/worktree.
  local d="$TMP/add-commit-exported"
  mkdir -p "$d"
  new_repo_fixture "$d"
  write_fake_ao "$FAKE_AO"
  common_env "$d"
  unset AO_FAKE_TERMINATED_AFTER 2>/dev/null || true
  export AO_RECOVERY_TIMEOUT_SECS=10

  printf 'pending-content\n' >>"$d/work/tracked.txt"

  local err="$d/err.txt"
  printf 'git add -u failed\n' >"$err"

  (
    sleep 1
    git -C "$d/work" add tracked.txt
    git -C "$d/work" commit -m "exported the pending content" >/dev/null
    git -C "$d/work" push origin main >/dev/null 2>&1
  ) &
  local bg_pid=$!

  bash "$RECOVERY" --repo "$d/work" --name fixture --phase add --error-file "$err"
  local rc=$?
  wait "$bg_pid"
  return "$rc"
}

test_add_commit_phase_worktree_only_advance_fails() {
  # Negative case for the same fix: worktrees share committed history but
  # never working-tree/index state, so a "fix" landed in a SEPARATE clone
  # (standing in for AO's own worktree) can advance origin/main without ever
  # touching $REPO's own pending content. add_commit_resolved() must reject
  # this — $REPO's working tree must still be dirty with the untouched
  # pending change, so recovery must fail closed rather than report success.
  local d="$TMP/add-commit-worktree-only"
  mkdir -p "$d"
  new_repo_fixture "$d"
  write_fake_ao "$FAKE_AO"
  common_env "$d"
  export AO_FAKE_TERMINATED_AFTER=1
  export AO_RECOVERY_TIMEOUT_SECS=3

  printf 'pending-content\n' >>"$d/work/tracked.txt"

  local err="$d/err.txt"
  printf 'git add -u failed\n' >"$err"

  # Simulate AO's own worktree as a SEPARATE clone that pushes SOME change to
  # origin/main -- but never the actual pending content sitting in $REPO.
  git clone "$d/origin.git" "$d/ao-worktree" >/dev/null 2>&1
  git -C "$d/ao-worktree" config user.name "Fixture"
  git -C "$d/ao-worktree" config user.email "${GITHUB_USER}@users.noreply.github.com"
  printf 'unrelated-change\n' >>"$d/ao-worktree/other.txt"
  git -C "$d/ao-worktree" add other.txt
  git -C "$d/ao-worktree" commit -m "unrelated worktree-only change" >/dev/null
  git -C "$d/ao-worktree" push origin main >/dev/null 2>&1

  bash "$RECOVERY" --repo "$d/work" --name fixture --phase add --error-file "$err" && return 1

  # $REPO's own working tree must still show the untouched pending change.
  git -C "$d/work" status --porcelain | grep -q "tracked.txt" || {
    echo "expected \$REPO's pending change to remain untouched after a worktree-only advance"
    return 1
  }
  return 0
}

test_add_commit_phase_rejects_divergent_sha_same_content() {
  # A content-only match is not proof the fix actually landed FROM $REPO:
  # an independent actor could publish an equivalent-content commit (same
  # bytes, different SHA/author/timestamp/message) to origin/main by pure
  # coincidence or race, while $REPO's own HEAD never advances at all.
  # add_commit_resolved() must require $REPO's own local HEAD to equal the
  # fetched origin/main SHA exactly, not just match content per pending file.
  local d="$TMP/add-commit-divergent-sha"
  mkdir -p "$d"
  new_repo_fixture "$d"
  write_fake_ao "$FAKE_AO"
  common_env "$d"
  export AO_FAKE_TERMINATED_AFTER=1
  export AO_RECOVERY_TIMEOUT_SECS=3

  printf 'pending-content\n' >>"$d/work/tracked.txt"

  local err="$d/err.txt"
  printf 'git add -u failed\n' >"$err"

  # Independent actor: separate clone commits the SAME final file content
  # under a different commit (different message/author date -> different
  # SHA) and pushes it to origin/main. $REPO's own working tree still has
  # the identical pending edit sitting uncommitted -- content matches, but
  # $REPO's own HEAD was never advanced to this SHA.
  git clone "$d/origin.git" "$d/independent-actor" >/dev/null 2>&1
  git -C "$d/independent-actor" config user.name "Other Fixture"
  git -C "$d/independent-actor" config user.email "other@users.noreply.github.com"
  printf 'pending-content\n' >>"$d/independent-actor/tracked.txt"
  git -C "$d/independent-actor" commit -am "independently published equivalent content" >/dev/null
  git -C "$d/independent-actor" push origin main >/dev/null 2>&1

  bash "$RECOVERY" --repo "$d/work" --name fixture --phase add --error-file "$err" && return 1
  return 0
}

test_add_commit_phase_preexisting_untracked_file_preserved() {
  # A pre-existing untracked file in $REPO (e.g. a local scratch/wiki draft
  # that predates this run and is not gitignored) must never block success
  # or pressure the agent to stage/delete it -- only the TRACKED pending
  # content and the absence of NEW untracked paths matter.
  local d="$TMP/add-commit-preexisting-untracked"
  mkdir -p "$d"
  new_repo_fixture "$d"
  write_fake_ao "$FAKE_AO"
  common_env "$d"
  unset AO_FAKE_TERMINATED_AFTER 2>/dev/null || true
  export AO_RECOVERY_TIMEOUT_SECS=10

  printf 'pre-existing scratch content\n' >"$d/work/scratch.txt"
  printf 'pending-content\n' >>"$d/work/tracked.txt"

  local err="$d/err.txt"
  printf 'git add -u failed\n' >"$err"

  (
    sleep 1
    git -C "$d/work" add tracked.txt
    git -C "$d/work" commit -m "exported the pending content" >/dev/null
    git -C "$d/work" push origin main >/dev/null 2>&1
  ) &
  local bg_pid=$!

  bash "$RECOVERY" --repo "$d/work" --name fixture --phase add --error-file "$err"
  local rc=$?
  wait "$bg_pid"
  [[ "$rc" -eq 0 ]] || { echo "expected success despite pre-existing untracked file"; return 1; }

  [[ -f "$d/work/scratch.txt" ]] || { echo "pre-existing untracked file was removed"; return 1; }
  [[ "$(cat "$d/work/scratch.txt")" == "pre-existing scratch content" ]] || {
    echo "pre-existing untracked file was modified"
    return 1
  }
  git -C "$d/work" status --porcelain -- scratch.txt | grep -q '^??' || {
    echo "pre-existing scratch file should still be untracked, not staged"
    return 1
  }
  return 0
}

test_add_commit_phase_fails_if_new_untracked_file_appears() {
  # If the fix drops a brand-new untracked path that was not present at
  # recovery's start, that is exactly the "stray file" case the untracked
  # baseline comparison exists to catch -- must fail closed even though the
  # pending tracked content was correctly committed and pushed.
  local d="$TMP/add-commit-new-untracked"
  mkdir -p "$d"
  new_repo_fixture "$d"
  write_fake_ao "$FAKE_AO"
  common_env "$d"
  export AO_FAKE_TERMINATED_AFTER=1
  export AO_RECOVERY_TIMEOUT_SECS=3

  printf 'pending-content\n' >>"$d/work/tracked.txt"

  local err="$d/err.txt"
  printf 'git add -u failed\n' >"$err"

  (
    sleep 0.2
    git -C "$d/work" add tracked.txt
    git -C "$d/work" commit -m "exported the pending content" >/dev/null
    git -C "$d/work" push origin main >/dev/null 2>&1
    printf 'stray output\n' >"$d/work/stray.tmp"
  ) &
  local bg_pid=$!

  bash "$RECOVERY" --repo "$d/work" --name fixture --phase add --error-file "$err"
  local rc=$?
  wait "$bg_pid"
  [[ "$rc" -ne 0 ]] || { echo "expected failure when a new untracked path appears"; return 1; }
  return 0
}

test_initial_fetch_failure_dies_closed() {
  # A silently-swallowed initial fetch failure (the old `|| true`) leaves
  # INITIAL_REMOTE_SHA stale/empty, and both resolvers only check
  # "remote_sha != INITIAL_REMOTE_SHA" -- an unverified baseline makes
  # almost any real remote SHA look like genuine progress. Must fail closed
  # before ever spawning an agent, not proceed on a guess.
  local d="$TMP/initial-fetch-failure"
  mkdir -p "$d"
  new_repo_fixture "$d"
  write_fake_ao "$FAKE_AO"
  common_env "$d"

  git -C "$d/work" remote set-url origin "$d/does-not-exist.git"

  local err="$d/err.txt"
  printf 'git add -u failed\n' >"$err"

  bash "$RECOVERY" --repo "$d/work" --name fixture --phase add --error-file "$err" 2>"$d/stderr.txt" && return 1

  assert_contains "$d/stderr.txt" "initial git fetch of origin/main failed" && \
  assert_not_contains "$AO_FAKE_LOG" "spawn"
}

test_pending_manifest_round_trip_odd_filename() {
  # Skeptic round 2/B NUL-framing contract: paths containing space, tab,
  # or newline bytes must round-trip through the manifest exactly, so
  # the verifier's `git ls-tree -- :(literal)$path` query resolves them
  # at the new origin/main. Files are tracked at baseline (so the
  # recovery prompt's `git add -u` operation is the canonical export
  # shape -- no new untracked files slip in), then modified in place.
  local d="$TMP/odd-filename"
  mkdir -p "$d"
  new_repo_fixture "$d"

  # Create the odd-named tracked files and push them to origin so they
  # are part of the BASELINE (not untracked) before any pending state.
  # Use Python so the actual TAB and LF bytes land inside the filename
  # bytes -- shell quoting cannot carry a literal LF through $(). The
  # Python process owns the byte identity; we do NOT share it through
  # shell argv.
  python3 - "$d/work" <<'PY'
import os, subprocess, sys
base = sys.argv[1]
names = ["odd name.txt", "tab\tinside.txt", "with\nnewline.txt"]
for n in names:
    p = os.path.join(base, n)
    os.makedirs(os.path.dirname(p) or base, exist_ok=True)
    with open(p, "wb") as f:
        f.write(b"baseline " + n.encode("utf-8") + b"\n")
subprocess.check_call(["git", "-C", base, "add", "-A"])
subprocess.check_call(["git", "-C", base, "commit", "-m", "baseline odd-name tracked files"])
subprocess.check_call(["git", "-C", base, "push", "origin", "main"])
PY

  write_fake_ao "$FAKE_AO"
  common_env "$d"
  unset AO_FAKE_TERMINATED_AFTER 2>/dev/null || true
  export AO_RECOVERY_TIMEOUT_SECS=10

  # Modify each tracked file's bytes in place -- the pending state is
  # exactly the modifications, with no new untracked paths.
  python3 - "$d/work" <<'PY'
import os, sys
base = sys.argv[1]
names = ["odd name.txt", "tab\tinside.txt", "with\nnewline.txt"]
for n in names:
    p = os.path.join(base, n)
    with open(p, "wb") as f:
        f.write(b"PENDING " + n.encode("utf-8") + b"\n")
PY

  local err="$d/err.txt"
  printf 'git add -u failed\n' >"$err"

  (
    sleep 1
    git -C "$d/work" add -u
    git -C "$d/work" commit -m "exported odd-filename pending content" >/dev/null
    git -C "$d/work" push origin main >/dev/null 2>&1
  ) &
  local bg_pid=$!

  bash "$RECOVERY" --repo "$d/work" --name fixture --phase add --error-file "$err"
  local rc=$?
  wait "$bg_pid"
  [[ "$rc" -eq 0 ]] || { echo "expected recovery to succeed with odd filenames in manifest"; return 1; }

  # Verify each odd-named path resolves at the new origin/main with a
  # NON-EMPTY ls-tree entry (a missing path returns exit 0 with empty
  # stdout -- never accept that as success). Pass bytes from Python
  # to `git ls-tree` directly via argv; do NOT echo them through shell.
  python3 - "$d/work" <<'PY'
import os, subprocess, sys
repo = sys.argv[1]
names = ["odd name.txt", "tab\tinside.txt", "with\nnewline.txt"]
for n in names:
    r = subprocess.run(
        ["git", "-C", repo, "ls-tree", "refs/remotes/origin/main", "--", f":(literal){n}"],
        capture_output=True, text=True
    )
    assert r.returncode == 0, f"ls-tree failed for {n!r}: {r.stderr}"
    assert r.stdout.strip() != "", f"missing non-empty entry for {n!r}: stdout={r.stdout!r}"
    assert "\t" in r.stdout, f"no entry line for {n!r}: stdout={r.stdout!r}"
    print(f"ok {n!r} -> {r.stdout.strip()}")
PY
  return 0
}

test_pending_manifest_deletion_path_preserved() {
  # Deletion rows in the manifest must be reflected on origin/main as
  # path-absent at the literal pathspec; a same-name blob getting
  # re-added must fail the verifier. The bg-job MUST restore the path
  # ONLY after AO has spawned and the manifest has been snapshotted
  # (the spawn is the moment the adapter finishes pre-spawn git
  # inspection). Otherwise the snapshot records M (the deleted
  # file's empty blob?) or sees an unstaged modification that becomes
  # legitimate, masking the bug. Anchor on the spawned session line
  # in the fake-AO argv log so we deterministically verify a D row
  # resolved at pre-spawn time against a post-spawn re-add.
  local d="$TMP/pending-deletion"
  mkdir -p "$d"
  new_repo_fixture "$d"
  write_fake_ao "$FAKE_AO"
  common_env "$d"
  unset AO_FAKE_TERMINATED_AFTER 2>/dev/null || true
  export AO_RECOVERY_TIMEOUT_SECS=5

  # Pending state: tracked.txt deleted from $REPO entirely.
  rm -f "$d/work/tracked.txt"

  local err="$d/err.txt"
  printf 'git add -u failed\n' >"$err"

  # Wait until AO_FAKE_LOG contains the matched anchor for the
  # `ao spawn` argv -- this is the boundary between pre-spawn
  # snapshotting and post-spawn resolution. Bounded yet FAIL-CLOSED:
  # if the spawn anchor never appears, the bg-job writes a marker
  # and exits nonzero WITHOUT touching tracked.txt, and the parent
  # test treats a non-empty bg.err as a failure.
  (
    for _ in $(seq 1 50); do
      grep -q 'spawn' "$AO_FAKE_LOG" 2>/dev/null && break
      sleep 0.05
    done
    if ! grep -q 'spawn' "$AO_FAKE_LOG" 2>/dev/null; then
      echo "SPAWN_NOT_OBSERVED" >"$d/bg.err"
      exit 1
    fi
    printf 'unrelated-blob\n' >"$d/work/tracked.txt"
    git -C "$d/work" add tracked.txt
    git -C "$d/work" commit -m "wrongly restored tracked.txt as blob" >/dev/null 2>/dev/null
    if ! git -C "$d/work" push origin main >"$d/bg.out" 2>"$d/bg.err"; then
      echo "PUSH_FAILED:$?" >"$d/bg.err"
    else
      : >"$d/bg.err"
    fi
  ) &
  local bg_pid=$!

  bash "$RECOVERY" --repo "$d/work" --name fixture --phase add --error-file "$err" >"$d/run.out" 2>"$d/run.err"
  local rc=$?
  wait "$bg_pid" 2>/dev/null || true

  if [[ -s "$d/bg.err" ]]; then
    echo "background PUSH failed: $(cat "$d/bg.err")"
    return 1
  fi

  [[ "$rc" -ne 0 ]] || {
    echo "expected rc != 0, got rc=$rc"
    echo "--- run.out ---"; cat "$d/run.out"
    echo "--- run.err ---"; cat "$d/run.err"
    return 1
  }
  return 0
}

test_pending_manifest_executable_and_symlink_modes() {
  # Both the executable (100755) and symlink (120000) mode cases must
  # round-trip through manifest snapshotting and the verifier. Files
  # are tracked at baseline (so the recovery prompt's `git add -u`
  # operation is the canonical export shape -- no new untracked paths
  # slip in), then their mode/symlink-target changes become the
  # pending state.
  local d="$TMP/pending-modes"
  mkdir -p "$d"
  new_repo_fixture "$d"

  # Baseline: tracked exec.sh (initially NOT executable so the pending
  # change is to chmod +x it; and tracked symlink-to-tracked initially
  # pointing at a different target so the pending change is to re-point).
  cat >"$d/work/exec.sh" <<'SH'
#!/usr/bin/env bash
echo baseline
SH
  chmod 0644 "$d/work/exec.sh"
  ln -s nonexistent-baseline "$d/work/symlink-to-tracked"
  git -C "$d/work" add -A
  git -C "$d/work" commit -m "baseline exec/symlink files" >/dev/null
  git -C "$d/work" push origin main >/dev/null 2>&1

  # Pending state: chmod +x exec.sh and re-point the symlink. No new
  # untracked paths; only modifications to existing tracked entries.
  chmod +x "$d/work/exec.sh"
  ln -sfn tracked.txt "$d/work/symlink-to-tracked"

  write_fake_ao "$FAKE_AO"
  common_env "$d"
  unset AO_FAKE_TERMINATED_AFTER 2>/dev/null || true
  export AO_RECOVERY_TIMEOUT_SECS=10

  local err="$d/err.txt"
  printf 'git add -u failed\n' >"$err"

  (
    sleep 1
    git -C "$d/work" add -u
    git -C "$d/work" commit -m "exported executable + symlink pending content" >/dev/null
    git -C "$d/work" push origin main >/dev/null 2>&1
  ) &
  local bg_pid=$!

  bash "$RECOVERY" --repo "$d/work" --name fixture --phase add --error-file "$err"
  local rc=$?
  wait "$bg_pid"
  [[ "$rc" -eq 0 ]] || { echo "expected recovery to succeed preserving 100755/120000 modes"; return 1; }

  # Require NON-EMPTY ls-tree output for both modes -- an empty ls-tree
  # would falsely indicate the path is absent, not "preserved with mode".
  local exec_line sym_line
  exec_line="$(git -C "$d/work" ls-tree "refs/remotes/origin/main" -- ":(literal)exec.sh")"
  sym_line="$(git -C "$d/work" ls-tree "refs/remotes/origin/main" -- ":(literal)symlink-to-tracked")"
  [[ -n "$exec_line" ]] || { echo "exec.sh missing on remote"; return 1; }
  [[ -n "$sym_line" ]] || { echo "symlink-to-tracked missing on remote"; return 1; }
  [[ "$exec_line" == 100755* ]] || { echo "exec.sh mode not 100755: $exec_line"; return 1; }
  [[ "$sym_line"  == 120000* ]] || { echo "symlink mode not 120000: $sym_line"; return 1; }
  return 0
}

test_pending_manifest_hash_failure_dies_closed() {
  # Skeptic round 2/B fail-closed contract: a `git hash-object` failure
  # during pre-spawn snapshot MUST die closed before AO is spawned,
  # never silently continue past the pending path (which would let
  # the agent satisfy the gate by making one of its pending paths
  # unhashable). We forge a fixture `git` shim that delegates every
  # subcommand to the captured real `git` except `hash-object`, which
  # exits 42 with a clearly recognizable error line.
  local d="$TMP/pending-hash-fail"
  mkdir -p "$d"
  new_repo_fixture "$d"

  local real_git
  real_git="$(command -v git)"

  mkdir -p "$d/shim"
  cat >"$d/shim/git" <<SHIM
#!/usr/bin/env bash
# Fake git: forward every subcommand to the real one. If \$1 == "hash-object",
# refuse with a recognizable error line and exit 42.
if [[ "\${1:-}" == "hash-object" ]]; then
  echo "fake-hash-object-intentional-failure" >&2
  exit 42
fi
exec "$real_git" "\$@"
SHIM
  chmod +x "$d/shim/git"

  # Any pending change must trigger the hash-object branch.
  printf 'pending-to-hash\n' >>"$d/work/tracked.txt"

  write_fake_ao "$FAKE_AO"
  common_env "$d"

  local err="$d/err.txt"
  printf 'git add -u failed\n' >"$err"

  PATH="$d/shim:$PATH" \
    bash "$RECOVERY" --repo "$d/work" --name fixture --phase add \
      --error-file "$err" 2>"$d/stderr.txt" && return 1

  assert_contains "$d/stderr.txt" "fake-hash-object-intentional-failure" && \
  assert_contains "$d/stderr.txt" "git hash-object failed for" && \
  assert_not_contains "$AO_FAKE_LOG" "spawn"
}

test_pending_manifest_symlink_target_vs_file_content_diverges() {
  # Manifest symlink OID must be hash(target_string) -- NOT
  # hash(target_file_contents). git itself stores the literal link
  # target string as the 120000 blob content; hashing the wrong one
  # guarantees the verifier will reject the post-fix remote SHA even
  # when the fix is correct. We baseline a tracked file whose content
  # IS the symlink target string, then change the pending symlink to
  # point at a sibling file whose content is totally different; the
  # manifest must agree with what git ls-tree returns on the new
  # origin/main after the fix.
  local d="$TMP/symlink-divergence"
  mkdir -p "$d"
  new_repo_fixture "$d"

  # Baseline: tracked sibling file and a real symlink that points at
  # it. After the pending state replaces both, the 120000 blob OID
  # must be hash("different-target.txt") -- not hash(contents of
  # different-target.txt) -- because git itself stores the literal
  # target string as the 120000 blob content.
  printf 'first-real-bytes\n' >"$d/work/sibling-baseline.txt"
  ln -s sibling-baseline.txt "$d/work/symlink-pending.txt"
  git -C "$d/work" add -A
  git -C "$d/work" commit -m "baseline symlink and sibling" >/dev/null
  git -C "$d/work" push origin main >/dev/null 2>&1

  # Pending state: REPLACE sibling-target bytes with content
  # entirely different from any valid target string, and re-point the
  # symlink so its NEW target string ("different-target.txt") does
  # not even match the content of its actual target. Both files now
  # diverge by construction; the 120000 blob OID must come from the
  # target string, not the target file's content.
  printf 'completely-different-content\n' >"$d/work/sibling-baseline.txt"
  ln -sfn different-target.txt "$d/work/symlink-pending.txt"

  write_fake_ao "$FAKE_AO"
  common_env "$d"
  unset AO_FAKE_TERMINATED_AFTER 2>/dev/null || true
  export AO_RECOVERY_TIMEOUT_SECS=10

  local err="$d/err.txt"
  printf 'git add -u failed\n' >"$err"

  (
    sleep 1
    git -C "$d/work" add -u
    git -C "$d/work" commit -m "divergent symlink target vs target file content" >/dev/null
    git -C "$d/work" push origin main >/dev/null 2>&1
  ) &
  local bg_pid=$!

  bash "$RECOVERY" --repo "$d/work" --name fixture --phase add --error-file "$err"
  local rc=$?
  wait "$bg_pid"
  [[ "$rc" -eq 0 ]] || { echo "expected recovery to succeed even when symlink target string and target file content diverge"; return 1; }

  # Independently derive the expected 120000 OID from the literal
  # symlink target string (matching how git itself stores the blob).
  local expected_oid
  expected_oid="$(printf '%s' "different-target.txt" | git -C "$d/work" hash-object --stdin)"
  local remote_line
  remote_line="$(git -C "$d/work" ls-tree refs/remotes/origin/main -- ":(literal)symlink-pending.txt")"
  [[ -n "$remote_line" ]] || { echo "symlink-pending.txt missing on remote"; return 1; }
  local remote_oid
  remote_oid="$(printf '%s\n' "$remote_line" | awk '{print $3}')"
  [[ "$remote_oid" == "$expected_oid" ]] \
    || { echo "remote 120000 OID $remote_oid disagrees with hash(target_string) $expected_oid"; return 1; }
  return 0
}

test_scanner_snapshot_cleaned_on_early_exit() {
  local d="$TMP/scanner-cleanup"
  mkdir -p "$d/snaproot"
  cat >"$d/scanner.sh" <<'SCAN'
#!/usr/bin/env bash
exit 0
SCAN
  chmod +x "$d/scanner.sh"
  {
    sed -n '/^AUTO_PUSH_SECRET_SCAN_BIN=/,/^TRUSTED_SCANNER_DIR=/p' "$RECOVERY"
    sed -n '/^clean_trusted_scanner() {/,/^}/p' "$RECOVERY"
    sed -n '/^pin_trusted_secret_scanner() {/,/^}/p' "$RECOVERY"
  } >"$d/helper.sh"

  TMPDIR="$d/snaproot" AUTO_PUSH_SECRET_SCAN_BIN="$d/scanner.sh" \
    bash -c 'set -euo pipefail; source "$1"; pin_trusted_secret_scanner; printf "%s" "$TRUSTED_SCANNER_DIR" >"$2"; exit 23' \
    _ "$d/helper.sh" "$d/snapshot-path" >/dev/null 2>&1
  local rc=$?
  [[ "$rc" -eq 23 ]] || { echo "early-exit fixture rc=$rc"; return 1; }
  local snapshot
  snapshot="$(cat "$d/snapshot-path")"
  [[ -n "$snapshot" && ! -e "$snapshot" ]] \
    || { echo "trusted scanner snapshot leaked: $snapshot"; return 1; }

  TMPDIR="$d/snaproot" AUTO_PUSH_SECRET_SCAN_BIN="$d/scanner.sh" \
    bash -c 'set -euo pipefail; source "$1"; pin_trusted_secret_scanner; printf "%s" "$TRUSTED_SCANNER_DIR" >"$2"; kill -TERM $$' \
    _ "$d/helper.sh" "$d/signal-snapshot-path" >/dev/null 2>&1
  rc=$?
  [[ "$rc" -eq 143 ]] || { echo "TERM cleanup fixture rc=$rc"; return 1; }
  snapshot="$(cat "$d/signal-snapshot-path")"
  [[ -n "$snapshot" && ! -e "$snapshot" ]] \
    || { echo "trusted scanner snapshot leaked after TERM: $snapshot"; return 1; }
}

test_ao_module_provenance_wrong_path_rejected() {
  local d="$TMP/provenance-bad"
  mkdir -p "$d"
  new_repo_fixture "$d"
  write_fake_ao "$FAKE_AO"
  common_env "$d"
  local bad_ao="$d/bad-ao"
  build_fake_ao_binary "github.com/example/not-ao" "$bad_ao" "$d/bad-module"
  export AO_GO_BIN="$bad_ao"
  printf 'push rejected\n' >"$d/err.txt"

  if bash "$RECOVERY" --repo "$d/work" --name fixture --phase push --error-file "$d/err.txt" >"$d/out" 2>&1; then
    echo "wrong Go module path was accepted"
    return 1
  fi
  grep -q "module provenance check FAILED" "$d/out"
  assert_not_contains "$AO_FAKE_LOG" "status --json"
}

# ─── Run suite ──────────────────────────────────────────────────────────
GO_FIXTURE_BIN=""
for candidate in /opt/homebrew/bin/go /usr/local/go/bin/go /usr/local/bin/go; do
  if [[ -x "$candidate" ]]; then GO_FIXTURE_BIN="$candidate"; break; fi
done
[[ -n "$GO_FIXTURE_BIN" ]] || { echo "FAIL: Go toolchain required for AO provenance fixtures"; exit 1; }
FAKE_AO_SCRIPT="$TMP/fake-ao-script.sh"
FAKE_AO="$TMP/fake-ao"
export FAKE_AO_SCRIPT
build_fake_ao_binary "github.com/aoagents/agent-orchestrator/backend" "$FAKE_AO" "$TMP/fake-module" \
  || { echo "FAIL: could not build canonical Go AO fixture"; exit 1; }

run_test primary_success_no_switch test_primary_success_no_switch
run_test session_name_stays_within_ao_limit test_session_name_stays_within_ao_limit
run_test primary_timeout_switches_to_fallback test_primary_timeout_switches_to_fallback
run_test primary_terminated_switches_to_fallback test_primary_terminated_switches_to_fallback
run_test success_via_separate_worktree_syncs_repo test_success_via_separate_worktree_syncs_repo
run_test unrelated_remote_advance_does_not_discard_or_succeed test_unrelated_remote_advance_does_not_discard_or_succeed
run_test remote_mismatch_after_claim_is_failure test_remote_mismatch_after_claim_is_failure
run_test node_shebang_ao_binary_rejected test_node_shebang_ao_binary_rejected
run_test ao_daemon_unavailable_fails_without_direct_cli test_ao_daemon_unavailable_fails_without_direct_cli
run_test gitleaks_prompt_has_invariants_and_sanitized_error test_gitleaks_prompt_has_invariants_and_sanitized_error
run_test secret_scan_hook_invoked_with_correct_protocol test_secret_scan_hook_invoked_with_correct_protocol
run_test real_configured_hook_integration_clean_and_dirty_ranges test_real_configured_hook_integration_clean_and_dirty_ranges
run_test gitleaks_success_does_not_require_baseline_ancestor test_gitleaks_success_does_not_require_baseline_ancestor
run_test gitleaks_second_run_is_a_noop_after_recovery test_gitleaks_second_run_is_a_noop_after_recovery
run_test gitleaks_fails_closed_if_published_range_still_has_secret test_gitleaks_fails_closed_if_published_range_still_has_secret
run_test add_commit_phase_does_not_trivially_succeed_when_head_unchanged test_add_commit_phase_does_not_trivially_succeed_when_head_unchanged
run_test add_commit_phase_succeeds_once_pending_content_exported test_add_commit_phase_succeeds_once_pending_content_exported
run_test add_commit_phase_worktree_only_advance_fails test_add_commit_phase_worktree_only_advance_fails
run_test add_commit_phase_rejects_divergent_sha_same_content test_add_commit_phase_rejects_divergent_sha_same_content
run_test add_commit_phase_preexisting_untracked_file_preserved test_add_commit_phase_preexisting_untracked_file_preserved
run_test add_commit_phase_fails_if_new_untracked_file_appears test_add_commit_phase_fails_if_new_untracked_file_appears
run_test initial_fetch_failure_dies_closed test_initial_fetch_failure_dies_closed
run_test pending_manifest_round_trip_odd_filename test_pending_manifest_round_trip_odd_filename
run_test pending_manifest_deletion_path_preserved test_pending_manifest_deletion_path_preserved
run_test pending_manifest_executable_and_symlink_modes test_pending_manifest_executable_and_symlink_modes
run_test pending_manifest_symlink_target_vs_file_content_diverges test_pending_manifest_symlink_target_vs_file_content_diverges
run_test pending_manifest_hash_failure_dies_closed test_pending_manifest_hash_failure_dies_closed
run_test harnesses_exhausted_nonzero_and_state_preserved test_harnesses_exhausted_nonzero_and_state_preserved
run_test scanner_snapshot_cleaned_on_early_exit test_scanner_snapshot_cleaned_on_early_exit
run_test ao_module_provenance_wrong_path_rejected test_ao_module_provenance_wrong_path_rejected

echo ""
echo "Passed: $PASSED, Failed: $FAILED"
[[ "$FAILED" -eq 0 ]]
