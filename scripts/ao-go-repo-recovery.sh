#!/usr/bin/env bash
# ao-go-repo-recovery.sh
#
# Narrow shell boundary around the verified Go Agent Orchestrator CLI. Never
# invokes a model CLI (codex/claude) directly. Delegates exceptional Git
# export recovery (conflicts, hook failures, secret-scan blockers) to a
# durable AO session, polling the real remote-head exit criterion, and
# switching that SAME session to a fallback harness when the current harness
# stalls, terminates, or times out without satisfying it.
#
# Verified Go AO CLI contract (against a local `cmd/ao` build of the Go
# Agent Orchestrator backend — repository-neutral: do not hardcode a source
# checkout path here; only AO_GO_BIN, the installed binary, is a runtime
# dependency):
#   - `ao spawn --project P --harness H --name N --prompt TEXT` has no JSON
#     flag; on success it prints exactly one line to stdout:
#       spawned session <id> (<status>)
#   - `ao session get <id> --json --project P` prints {"session": {...}}
#     with .session.status (string) and .session.isTerminated (bool).
#   - `ao session switch <id> --harness H --project P` switches a LIVE
#     session's agent in place (same worktree, same session id).
#   - `ao send --session <id> --message TEXT` sends a follow-up message.
#   - `ao status --json` prints {"state": "ready"|"stopped"|"stale"|
#     "unhealthy"|"not_ready", ...}; only "ready" means the daemon is
#     actually reachable and healthy (the CLI itself can exit 0 even when
#     stale, so the JSON "state" field is authoritative, not the exit code).
#     Verified live against a real headless `ao daemon` process in this
#     session — a healthy daemon reports "ready", never "running".
#
# Usage:
#   ao-go-repo-recovery.sh --repo PATH --name NAME --phase PHASE --error-file PATH
#
# Exits 0 ONLY when a freshly fetched local HEAD equals origin/main. Any
# other outcome (spawn failure, daemon unavailable, harnesses exhausted,
# remote still diverged) is a non-zero exit with a preserved state file.
#
# Phase "gitleaks" uses a DIFFERENT, stricter contract than ordinary
# conflicts: a secret must never reach origin/main even transiently, so a
# post-publication scan of what the agent already pushed is not an
# acceptable safety gate. The prompt instructs the agent to remediate
# in-place (its worktree shares the registered project's object database —
# `git worktree`, not a disconnected clone — so `git log`/reflog there can
# already see $REPO's local history) and explicitly forbids it from
# pushing. This adapter is the ONLY thing that ever pushes for this phase:
# it locates the agent's worktree branch (the Go AO CLI's own default,
# `ao/<session-id>/root`, since --branch is never overridden), independently
# scans the exact candidate range with this machine's real configured
# pre-push hook BEFORE pushing, and only then performs a normal, non-force,
# hook-enabled push itself.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

AO_GO_BIN="${AO_GO_BIN:-$HOME/.local/bin/ao-go}"
AO_PRIMARY_HARNESS="${AO_PRIMARY_HARNESS:-codex}"
AO_FALLBACK_HARNESS="${AO_FALLBACK_HARNESS:-claude-code}"
AO_RECOVERY_TIMEOUT_SECS="${AO_RECOVERY_TIMEOUT_SECS:-1800}"
AO_POLL_SECS="${AO_POLL_SECS:-15}"
# Shares auto-push-to-main.sh's log-dir override: this adapter's state is
# conceptually part of the same scheduled-job's log directory, and the
# override keeps fixture tests from writing into the real production dir.
LOG_DIR="${AUTO_PUSH_LOG_DIR:-${HOME}/.smartclaw/logs/scheduled-jobs}"

die() {
  echo "ao-go-repo-recovery: $*" >&2
  exit 1
}

REPO=""
NAME=""
PHASE=""
ERROR_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --phase) PHASE="$2"; shift 2 ;;
    --error-file) ERROR_FILE="$2"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$REPO" ]] || die "--repo is required"
[[ "$REPO" == /* ]] || die "--repo must be an absolute path: $REPO"
[[ -d "$REPO" ]] || die "--repo does not exist: $REPO"
[[ -n "$NAME" ]] || die "--name is required"
# Defense-in-depth NAME allowlist (CodeRabbit round 2 / item 3 + 6): the
# coordinator already enforces this exact allowlist on its REPO_NAME
# before passing it in as --name, but the adapter independently
# re-checks in case the caller is some other consumer. The contract
# is "name must MATCH exactly ^[A-Za-z0-9_-]+$" -- no lossy sanitization,
# no character removal, because silent dropping can mask typos and let
# two previously-distinct names collide on the same log/state file.
if ! [[ "$NAME" =~ ^[A-Za-z0-9_-]+$ ]]; then
  die "--name must match ^[A-Za-z0-9_-]+$ (got [$NAME])"
fi

# PHASE must be in the exact supported set; any other value would
# route to the wrong dispatch (gitleaks/add/commit/push/verify) or
# sit silently as an unknown phase, breaking the verifier contract.
case "$PHASE" in
  add|commit|push|gitleaks|verify) : ;;
  *) die "--phase must be one of: add commit push gitleaks verify (got [$PHASE])" ;;
esac
[[ -n "$ERROR_FILE" && -f "$ERROR_FILE" ]] || die "--error-file must reference an existing file: $ERROR_FILE"

PROJECT_ID="${NAME}-auto-export"
# `ao spawn --name` rejects anything over 20 characters (verified live
# against a real daemon in this session: "--name must be 20 characters or
# fewer"). Truncate NAME so the "-rec" suffix always fits.
SESSION_NAME="${NAME:0:16}-rec"

mkdir -p "$LOG_DIR"
STATE_FILE="${LOG_DIR}/ao-recovery-${NAME}-state.json"

# ── Sanitization ───────────────────────────────────────────────────────────
# Redact token-shaped substrings before they reach a prompt or a log. Never
# includes file contents — only the caller's already-captured stderr text.
sanitize_text() {
  sed -E \
    -e 's/(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}/[REDACTED_GH_TOKEN]/g' \
    -e 's/sk-[A-Za-z0-9]{20,}/[REDACTED_KEY]/g' \
    -e 's/xox[abpr]-[A-Za-z0-9-]{10,}/[REDACTED_SLACK_TOKEN]/g' \
    -e 's/AKIA[A-Z0-9]{16}/[REDACTED_AWS_KEY]/g' \
    -e 's/[A-Za-z0-9_-]{32,}/[REDACTED_TOKEN_LIKE]/g'
}

atomic_write_state() {
  local tmp
  tmp="$(mktemp "${STATE_FILE}.XXXXXX")"
  cat >"$tmp"
  mv "$tmp" "$STATE_FILE"
}

write_state() {
  local status="$1" session_id="$2" harness="$3"
  local final_sha="${4:-}"
  # Normalize empty values to literal "N-A" so the consumer-side
  # recovery_alert helper never has to know which fields are empty
  # vs. unset. This keeps the JSON document self-describing.
  [[ -n "$session_id" ]] || session_id="N-A"
  [[ -n "$harness"     ]] || harness="N-A"
  [[ -n "$final_sha"   ]] || final_sha="N-A"
  jq -n --arg name "$NAME" \
        --arg phase "$PHASE" \
        --arg st "$status" \
        --arg sid "$session_id" \
        --arg hn "$harness" \
        --arg fsha "$final_sha" \
        --arg ph "$AO_PRIMARY_HARNESS" \
        --arg fh "$AO_FALLBACK_HARNESS" \
        '{name:$name,phase:$phase,status:$st,sessionId:$sid,harness:$hn,finalSha:$fsha,primaryHarness:$ph,fallbackHarness:$fh}' \
    | atomic_write_state
}

# Read the most recently fetched origin/main SHA. Forces a fresh
# `git fetch --prune origin main` so the value is never a stale
# tracking ref from before the verification loop ran. Returns empty
# on fetch failure so callers must `[[ -n ... ]]` before treating it
# as authoritative.
read_final_remote_sha() {
  local fetched
  ( cd "$REPO" && git fetch --prune origin main >/dev/null 2>&1 \
    && git rev-parse refs/remotes/origin/main 2>/dev/null ) || return 1
}

# ── Provenance / daemon validation ──────────────────────────────────────────
# Check a real Go binary's module provenance through a separate
# inspector CLI. The legitimate Go AO binary's `go version -m` output
# lists `path github.com/aoagents/agent-orchestrator/backend/cmd/ao`.
# Anything else (Node CLI, random Go binary, a copy of `ao` from a
# different project) fails closed. The inspector resolves only from fixed
# install paths; there is no runtime bypass or test-mode override.
EXPECTED_AO_MODULE_PATH="github.com/aoagents/agent-orchestrator/backend/cmd/ao"
AO_GO_INSPECT_BIN=""
for go_candidate in /opt/homebrew/bin/go /usr/local/go/bin/go /usr/local/bin/go; do
  if [[ -x "$go_candidate" ]]; then AO_GO_INSPECT_BIN="$go_candidate"; break; fi
done

validate_ao_binary() {
  [[ -x "$AO_GO_BIN" ]] || die "Go AO binary is not executable: $AO_GO_BIN"
  if head -c 64 "$AO_GO_BIN" 2>/dev/null | grep -Eq '^#!.*(node|env node)'; then
    die "Node AO CLI is not accepted: $AO_GO_BIN"
  fi
  "$AO_GO_BIN" version >/dev/null 2>&1 || die "Go AO version check failed: $AO_GO_BIN"

  # Provenance gate: ALWAYS run, NEVER disable. The inspector
  # command must exist; the inspector's `version -m` output must
  # contain a `path <EXPECTED_AO_MODULE_PATH>` line, matched
  # exactly (whitespace-tolerant). Mismatch => fail closed; no
  # alternative registry / path allowlist / fallback policy.
  [[ -x "$AO_GO_INSPECT_BIN" ]] \
    || die "Cannot verify Go AO module provenance: inspector is not executable: $AO_GO_INSPECT_BIN"
  local build_info
  build_info="$("$AO_GO_INSPECT_BIN" version -m "$AO_GO_BIN" 2>/dev/null)" \
    || die "Go AO module provenance inspector failed: $AO_GO_INSPECT_BIN version -m $AO_GO_BIN"
  if ! printf '%s\n' "$build_info" \
      | awk '/^[[:space:]]*path[[:space:]]+/ {print $2}' \
      | grep -Fxq "$EXPECTED_AO_MODULE_PATH"; then
    die "Go AO module provenance check FAILED for $AO_GO_BIN (expected path $EXPECTED_AO_MODULE_PATH)"
  fi
}

ao_daemon_healthy() {
  local status_json state
  status_json="$("$AO_GO_BIN" status --json 2>/dev/null)" || return 1
  state="$(printf '%s' "$status_json" | jq -r '.state // empty' 2>/dev/null)" || return 1
  [[ "$state" == "ready" ]]
}

ensure_project_registered() {
  "$AO_GO_BIN" project get "$PROJECT_ID" >/dev/null 2>&1 && return 0
  "$AO_GO_BIN" project add --id "$PROJECT_ID" --path "$REPO" >/dev/null 2>&1
}

# ── Git remote verification ─────────────────────────────────────────────────
# The sole source of truth for "resolved" — never trust a session's
# self-reported status alone.
#
# AO always resolves the export in its OWN worktree
# ($AO_DATA_DIR/worktrees/<project>/<session>), never inside $REPO (verified
# live: a real recovery run left $REPO's own checkout on its old,
# now-superseded commit while the fix landed on origin/main from a separate
# worktree). So $REPO's local HEAD never advances on its own — a naive SHA
# comparison would never resolve, even after a real, successful push.
#
# Success requires PROOF the pending local commit was actually incorporated,
# not just that origin/main moved: $BASELINE_LOCAL_HEAD (captured once,
# before spawning) must be a real ancestor of the new origin/main. That is
# only true for a genuine merge — a cherry-pick or rebase produces a
# different commit SHA and correctly fails this check, and an unrelated
# remote advance that never touches the pending commit fails it too. Once
# proven, $REPO is synced with `git merge --ff-only` only — never `git
# reset --hard`, which could silently discard the pending commit if this
# check were ever wrong. `merge --ff-only` cannot lose data: it only
# succeeds when $REPO's current HEAD is already an ancestor of the target.
remote_matches_local() {
  ( cd "$REPO" && git fetch --prune origin main ) >/dev/null 2>&1 || return 1
  local local_sha remote_sha
  local_sha="$(cd "$REPO" && git rev-parse HEAD 2>/dev/null)" || return 1
  remote_sha="$(cd "$REPO" && git rev-parse refs/remotes/origin/main 2>/dev/null)" || return 1
  [[ -n "$remote_sha" ]] || return 1

  [[ "$local_sha" == "$remote_sha" ]] && return 0

  if (cd "$REPO" && git merge-base --is-ancestor "$BASELINE_LOCAL_HEAD" refs/remotes/origin/main) 2>/dev/null; then
    (cd "$REPO" && git merge --ff-only origin/main) >/dev/null 2>&1 || return 1
    local_sha="$(cd "$REPO" && git rev-parse HEAD 2>/dev/null)" || return 1
    [[ "$local_sha" == "$remote_sha" ]]
    return $?
  fi

  return 1
}

# ── Independent secret scan (gitleaks phase) ────────────────────────────────
# Reuses THIS MACHINE'S OWN real configured pre-push hook via GIT'S OWN
# real pre-push hook protocol: Git invokes the hook as
# `<hook> <remote-name> <remote-url>` with ref-update lines on stdin
# ("<local ref> <local sha> <remote ref> <remote sha>") — never a
# hardcoded tool name, never a reimplementation of detection logic. The
# hook at core.hooksPath/pre-push on this machine is itself a thin wrapper
# that forwards to secret-scan.sh, prepending its OWN "pre-push" mode
# argument internally — callers of the hook must NOT also pass "pre-push"
# themselves, or the wrapper's fixed 2-arg forwarding shifts everything by
# one position (remote-name lands in the mode slot, remote-url lands in
# the remote-name slot, and the real remote-url is silently dropped).
# Fails closed (returns 1) if no scanner is configured at all: an
# unscannable range is never treated as clean.
# Pinned trusted scanner (skeptic round 2/A): the live pre-push hook under
# core.hooksPath lives in a directory the worker can freely read and
# mutate from inside its shell session. A agent-controlled hooksPath
# rewrite (or a mere edit of the hook file itself) would change what
# "passes the scan" before it has even been run, so we never trust the
# live hook for this scan. Instead: pin a trusted scanner at
# $AUTO_PUSH_SECRET_SCAN_BIN (default: ~/.config/git/hooks/secret-scan.sh,
# the real machine-global scanner OUTSIDE $REPO), validate it, copy it
# to a private random temp path under $TMPDIR BEFORE AO gets a shell,
# record the checksum, and invoke that snapshot directly with mode
# "pre-push" + git's real remote args + stdin ref-update lines.
# IMPORTANT: the snapshot is owned by the same UID as this script (we
# are not root and cannot change owner). Same-UID mode bits are NOT a
# real isolation boundary against a malicious same-UID process; the
# checksum/random unshared path only protects against accidental live-
# hook mutation (e.g. the worker edits its own hooksPath or the file
# under $REPO/.git/hooks). Do not advertise it as stronger than that.
# Both TRUSTED_SCANNER_BIN and TRUSTED_SCANNER_CHECKSUM are explicitly
# RESET before pinning so a caller that pre-set them (or that put them
# in the inherited environment for the AO child) cannot bypass the
# snapshot creation -- they are stored as shell-local variables, NEVER
# exported, so the AO child never inherits the snapshot path either.
# The checksum is re-verified IMMEDIATELY BEFORE every invocation, not
# just at pin time. The normal non-force push later in
# gitleaks_resolved() still goes through the live hook as a second
# independent defense. Fail closed when pinned scanner is missing,
# unreadable, unexecutable, or its checksum changed since pin time --
# never silently fall through to the live hook as a substitute.
AUTO_PUSH_SECRET_SCAN_BIN="${AUTO_PUSH_SECRET_SCAN_BIN:-$HOME/.config/git/hooks/secret-scan.sh}"
TRUSTED_SCANNER_BIN=""
TRUSTED_SCANNER_CHECKSUM=""
TRUSTED_SCANNER_DIR=""

clean_trusted_scanner() {
  [[ -n "${TRUSTED_SCANNER_DIR:-}" && -d "$TRUSTED_SCANNER_DIR" ]] \
    && rm -rf "$TRUSTED_SCANNER_DIR" 2>/dev/null || true
  TRUSTED_SCANNER_DIR=""
  TRUSTED_SCANNER_BIN=""
  TRUSTED_SCANNER_CHECKSUM=""
}

pin_trusted_secret_scanner() {
  # Install the cleanup trap BEFORE pinning, so the snapshot dir is
  # always cleaned on natural exit, die, or any of the early returns
  # below. The trap is installed on EXIT/HUP/INT/TERM specifically so
  # external signals do not leak the temp dir.
  trap 'clean_trusted_scanner' EXIT
  trap 'clean_trusted_scanner; exit 129' HUP
  trap 'clean_trusted_scanner; exit 130' INT
  trap 'clean_trusted_scanner; exit 143' TERM

  # Reset so a caller-supplied env cannot bypass snapshot creation.
  clean_trusted_scanner

  local src="$AUTO_PUSH_SECRET_SCAN_BIN"
  [[ -f "$src" && -r "$src" && -x "$src" ]] \
    || { echo "trusted scanner missing or not executable: $src" >&2; return 1; }

  local snapdir
  snapdir="$(mktemp -d "${TMPDIR:-/tmp}/ao-trusted-scanner.XXXXXX")" \
    || return 1
  chmod 0700 "$snapdir" 2>/dev/null || true
  cp "$src" "$snapdir/secret-scan.sh" \
    || { rm -rf "$snapdir"; return 1; }
  chmod 0500 "$snapdir/secret-scan.sh" \
    || { rm -rf "$snapdir"; return 1; }

  # Stored as LOCAL shell variables, not exported (the AO child must NOT
  # inherit the snapshot path -- it would defeat the point of pinning).
  TRUSTED_SCANNER_DIR="$snapdir"
  TRUSTED_SCANNER_BIN="$snapdir/secret-scan.sh"
  TRUSTED_SCANNER_CHECKSUM="$(shasum -a 256 "$TRUSTED_SCANNER_BIN" 2>/dev/null | awk '{print $1}')"
  [[ -n "$TRUSTED_SCANNER_CHECKSUM" ]] \
    || { rm -rf "$snapdir"; TRUSTED_SCANNER_BIN=""; TRUSTED_SCANNER_DIR=""; return 1; }
  return 0
}

verify_trusted_secret_scanner_unmodified() {
  [[ -x "$TRUSTED_SCANNER_BIN" ]] || return 1
  local current
  current="$(shasum -a 256 "$TRUSTED_SCANNER_BIN" 2>/dev/null | awk '{print $1}')"
  [[ -n "$current" && "$current" == "$TRUSTED_SCANNER_CHECKSUM" ]]
}

# Independent scan using ONLY the pinned-trusted snapshot, never the live
# hook. secret-scan.sh on this machine reads its mode argument as $1
# (e.g. "pre-push"), then git's real <remote-name> as $2 and
# <remote-url> as $3 -- matching the pre-push hook protocol exactly so
# the scanner gets the same inputs it would during a real push. The
# checksum is re-checked immediately before invocation, so a mid-flight
# swap cannot satisfy the gate.
independent_secret_scan_clean() { # independent_secret_scan_clean <base_sha> <head_sha>
  local base_sha="$1" head_sha="$2"

  [[ -x "$TRUSTED_SCANNER_BIN" ]] || return 1
  verify_trusted_secret_scanner_unmodified || return 1

  local remote_url
  remote_url="$(cd "$REPO" && git remote get-url origin 2>/dev/null || echo "")"
  [[ -n "$remote_url" ]] || return 1

  ( cd "$REPO" && printf 'refs/heads/main %s refs/heads/main %s\n' "$head_sha" "$base_sha" \
      | "$TRUSTED_SCANNER_BIN" pre-push origin "$remote_url" ) >/dev/null 2>&1
}

# ── Worktree cleanliness that tolerates pre-existing untracked files ───────
# A bare `git status --porcelain` treats any untracked path as "dirty" —
# including files that were untracked in $REPO long before this run started
# (scratch notes, local wiki drafts, anything not gitignored). Gating success
# on THOSE never being present would make recovery permanently unresolvable
# for a repo that legitimately carries such files, and would pressure the
# agent to "clean up" by staging or deleting content it was never asked to
# touch (banned: "never stage unrelated files"). So cleanliness is judged in
# two independent parts: the TRACKED index/worktree must be fully clean
# (no staged or unstaged changes to tracked files), and the set of untracked
# paths must be byte-for-byte IDENTICAL to $BASELINE_UNTRACKED captured once
# at the very start of recovery — pre-existing untracked files are always
# allowed to remain exactly as they were; any newly-created untracked path
# (a stray temp/log file the fix accidentally dropped) still fails closed.
worktree_is_clean_and_untracked_unchanged() {
  [[ -z "$(cd "$REPO" && git status --porcelain --untracked-files=no 2>/dev/null)" ]] || return 1
  local current_untracked
  current_untracked="$(cd "$REPO" && git status --porcelain --untracked-files=all 2>/dev/null \
    | awk '$1=="??"{ sub(/^\?\? /,""); print }' | sort)" || return 1
  [[ "$current_untracked" == "$BASELINE_UNTRACKED" ]]
}

# ── Gitleaks phase: scan-then-push is owned by THIS adapter, never the
# agent ────────────────────────────────────────────────────────────────────
# A secret must never reach origin/main even transiently, so accepting
# whatever the agent already pushed (a post-publication scan) is not a safe
# gate — and neither is accepting a push from the agent's own separate
# AO worktree branch: that would leave $REPO's own checked-out `main` still
# sitting on the secret-bearing commit, so the NEXT day's run repeats the
# identical leak and $REPO's local HEAD stays permanently diverged from
# origin/main. The prompt instead explicitly instructs the agent to `cd`
# into $REPO itself (not just operate in its default AO worktree — it has
# ordinary shell access) and rewrite/amend the checked-out `main` branch
# there IN PLACE, without pushing. This function polls $REPO's OWN local
# HEAD directly: requires it to have moved past $BASELINE_LOCAL_HEAD with a
# clean working tree, independently scans exactly the candidate outgoing
# range BEFORE ever pushing, and only on a clean scan performs the actual
# push itself (normal, non-force, hook-enabled — the real global pre-push
# hook also runs naturally here, a second independent check). Finishes only
# once $REPO's local HEAD equals the fetched remote, the remote has
# genuinely advanced past $INITIAL_REMOTE_SHA, and the original
# secret-bearing commit is NOT an ancestor of the shipped result (true for
# a genuine amend/rewrite; false only if it were somehow still included).
gitleaks_resolved() {
  local current_local_sha
  current_local_sha="$(cd "$REPO" && git rev-parse HEAD 2>/dev/null)" || return 1
  [[ -n "$current_local_sha" && "$current_local_sha" != "$BASELINE_LOCAL_HEAD" ]] || return 1

  worktree_is_clean_and_untracked_unchanged || return 1

  independent_secret_scan_clean "$INITIAL_REMOTE_SHA" "$current_local_sha" || return 1

  ( cd "$REPO" && git push origin HEAD:main ) >/dev/null 2>&1 || return 1

  ( cd "$REPO" && git fetch --prune origin main ) >/dev/null 2>&1 || return 1
  local remote_sha local_sha_after
  remote_sha="$(cd "$REPO" && git rev-parse refs/remotes/origin/main 2>/dev/null)" || return 1
  local_sha_after="$(cd "$REPO" && git rev-parse HEAD 2>/dev/null)" || return 1
  [[ "$local_sha_after" == "$remote_sha" && "$remote_sha" != "$INITIAL_REMOTE_SHA" ]] || return 1

  ! (cd "$REPO" && git merge-base --is-ancestor "$BASELINE_LOCAL_HEAD" refs/remotes/origin/main) 2>/dev/null
}

# ── Add/commit phase: no new commit exists yet at spawn time ────────────────
# For an "add" or "commit" failure, do_push() never successfully created a
# new commit — $BASELINE_LOCAL_HEAD is just the OLD head, so
# local_sha == remote_sha can already be trivially true before AO does any
# work at all (Codex review P2). Success instead requires: the remote has
# genuinely advanced past $INITIAL_REMOTE_SHA, $REPO's own local HEAD is
# EXACTLY the fetched origin/main (not merely equivalent content published
# by some other, independent commit — a content-only match would falsely
# succeed even though $REPO's own branch never actually landed on the
# remote, which is exactly the failure the corrected prompt is designed to
# prevent: the fix must be committed and pushed FROM $REPO itself), $REPO's
# working tree is clean, and every originally-pending file's CURRENT
# on-disk content in $REPO (untouched since the failed add/commit never
# reverted it) exactly matches what the new origin/main now publishes for
# that same file.
add_commit_resolved() {
  ( cd "$REPO" && git fetch --prune origin main ) >/dev/null 2>&1 || return 1
  local remote_sha local_sha
  remote_sha="$(cd "$REPO" && git rev-parse refs/remotes/origin/main 2>/dev/null)" || return 1
  [[ -n "$remote_sha" && "$remote_sha" != "$INITIAL_REMOTE_SHA" ]] || return 1

  local_sha="$(cd "$REPO" && git rev-parse HEAD 2>/dev/null)" || return 1
  [[ "$local_sha" == "$remote_sha" ]] || return 1

  worktree_is_clean_and_untracked_unchanged || return 1

  [[ -s "$PENDING_MANIFEST_FILE" ]] || return 1

  # Manifest check (skeptic round 2/B): for every pre-spawn snapshot row,
  # origin/main must declare EXACTLY that mode and OID at that path (or
  # be tree-absent for D rows). We read the NUL-framed manifest with
  # FOUR successive `read -r -d ''` lookups -- one read per field --
  # so paths containing any byte (LF/tab/`*`/backslash) round-trip
  # correctly without ever touching command substitution.
  local kind path mode oid
  exec 9<"$PENDING_MANIFEST_FILE"
  while :; do
    if ! IFS= read -r -d '' kind <&9; then break; fi
    if ! IFS= read -r -d '' path <&9; then exec 9>&-; return 1; fi
    if ! IFS= read -r -d '' mode <&9; then exec 9>&-; return 1; fi
    if ! IFS= read -r -d '' oid  <&9; then exec 9>&-; return 1; fi

    if [[ "$kind" == "D" ]]; then
      # Path must be flat-out tree-absent at the remote SHA.
      ( cd "$REPO" && git cat-file -e "${remote_sha}:${path}" ) 2>/dev/null \
        && { exec 9>&-; return 1; }
      continue
    fi

    # For M rows we require the EXACT (mode, type, OID) tuple at the
    # remote. Use the canonical `git ls-tree <remote> -- <path>` query
    # with a LITERAL pathspec `:(literal)$path` so paths containing
    # spaces, tabs, or newlines (or quote-like characters) are matched
    # exactly as bytes -- never via awk field-reconstruction that would
    # collapse or mis-split unusual path bytes. We do NOT parse the
    # returned path back from the line; the query already selected
    # exactly the path we asked for, so any return that names the
    # wrong path is impossible at the query layer.
    #
    # The query returns either empty (path absent) or exactly one
    # line: "<mode> <type> <oid>\t<path>". The literal pathspec
    # guarantees the path is the one we asked for, so we never parse
    # the path bytes back out. We split ONLY the metadata portion
    # (everything before the first TAB) into the three fields.
    local actual actual_meta actual_mode actual_type actual_oid extra
    actual="$(cd "$REPO" && git ls-tree "$remote_sha" -- ":(literal)$path" 2>/dev/null)" \
      || { exec 9>&-; return 1; }
    [[ "$actual" == *$'\t'* ]] || { exec 9>&-; return 1; }
    actual_meta="${actual%%$'\t'*}"
    read -r actual_mode actual_type actual_oid extra <<<"$actual_meta" \
      || { exec 9>&-; return 1; }
    [[ -n "$actual_mode" && -n "$actual_type" && -n "$actual_oid" ]] \
      || { exec 9>&-; return 1; }
    [[ -z "$extra" ]] || { exec 9>&-; return 1; }
    [[ "$actual_type" == "blob" ]] || { exec 9>&-; return 1; }
    [[ "$actual_mode" == "$mode" ]] || { exec 9>&-; return 1; }
    [[ "$actual_oid"  == "$oid"  ]] || { exec 9>&-; return 1; }
  done
  exec 9>&-
  return 0
}

# ── AO command wrappers ─────────────────────────────────────────────────────
ao_spawn() { # ao_spawn <harness> <prompt_file>; echoes session id on stdout
  local harness="$1" prompt_file="$2"
  local output session_id
  output="$("$AO_GO_BIN" spawn --project "$PROJECT_ID" --harness "$harness" \
    --name "$SESSION_NAME" --prompt "$(cat "$prompt_file")" 2>&1)" || {
    echo "$output" >&2
    return 1
  }
  session_id="$(printf '%s\n' "$output" | sed -nE 's/^spawned session ([^ ]+) \([^)]*\)$/\1/p')"
  [[ -n "$session_id" ]] || { echo "$output" >&2; return 1; }
  printf '%s\n' "$session_id"
}

ao_session_json() { # ao_session_json <session_id>
  local session_id="$1"
  "$AO_GO_BIN" session get "$session_id" --json --project "$PROJECT_ID" 2>/dev/null
}

ao_session_is_terminated() { # ao_session_is_terminated <session_id>
  local session_id="$1" json
  json="$(ao_session_json "$session_id")" || return 1
  [[ "$(printf '%s' "$json" | jq -r '.session.isTerminated // false' 2>/dev/null)" == "true" ]]
}

ao_switch() { # ao_switch <session_id> <harness>
  local session_id="$1" harness="$2"
  "$AO_GO_BIN" session switch "$session_id" --harness "$harness" --project "$PROJECT_ID"
}

ao_send() { # ao_send <session_id> <message_file>
  local session_id="$1" message_file="$2"
  "$AO_GO_BIN" send --session "$session_id" --message "$(cat "$message_file")"
}

# ── Prompt construction ──────────────────────────────────────────────────────
build_prompt() {
  local target="$1"
  local sanitized_error git_status local_sha remote_sha phase_invariant phase_task
  sanitized_error="$(sanitize_text <"$ERROR_FILE" | tail -n 80)"
  git_status="$(cd "$REPO" && git status --short 2>/dev/null | sanitize_text)"
  local_sha="$(cd "$REPO" && git rev-parse HEAD 2>/dev/null || echo unknown)"
  remote_sha="$(cd "$REPO" && git rev-parse refs/remotes/origin/main 2>/dev/null || echo unknown)"

  if [[ "$PHASE" == "gitleaks" ]]; then
    phase_invariant="- operate directly on the ORIGINAL repository at ${REPO} (cd there — you
  have ordinary shell access; do not use a different default worktree for
  this fix) and rewrite/amend its checked-out main branch IN PLACE so the
  fixed commit replaces the blocked one; do NOT run git push yourself —
  the export automation independently scans the exact candidate outgoing
  range at ${REPO} and only then performs the actual push itself, so a
  secret can never reach origin/main even transiently"
    phase_task="This phase is \"gitleaks\": the pre-push secret guard is a security
boundary, never bypass it. In ${REPO} itself (the original repository, not
a separate worktree), redact the real secret, remove an accidentally
generated credential file from the export scope, or make a narrowly
evidenced false-positive correction — using git commit --amend or an
interactive rebase so the blocked commit ${local_sha} is replaced, not
merely followed by a new one. Preserve any unrelated pending changes and
leave the working tree clean; do not introduce new untracked files. Stop
once committed — do not push."
  elif [[ "$PHASE" == "add" || "$PHASE" == "commit" ]]; then
    phase_invariant="- the pending changes that failed to ${PHASE} exist ONLY in the working
  tree of the ORIGINAL repository at ${REPO} — your default AO worktree is
  a SEPARATE checkout that does not see them (worktrees share committed
  history but never working-tree/index state). Operate directly on
  ${REPO} itself (cd there): do not recreate the change anywhere else"
    phase_task="This phase is \"${PHASE}\": diagnose why git ${PHASE} failed in ${REPO}
itself, preserve the exact pending content already sitting there
(git status --short above shows what is pending), fix whatever blocked the
${PHASE}, then commit and push FROM ${REPO} to origin main using normal Git
commands only. Leave ${REPO}'s working tree clean when done."
  else
    phase_invariant="- if a local commit at ${local_sha} needs to reach origin/main, MERGE it
  (git merge, keeping it as a real parent of the result) — do not
  cherry-pick or rebase it. Verification requires
  \"git merge-base --is-ancestor ${local_sha} origin/main\" to be true; a
  cherry-pick or rebase produces a different commit and will be treated as
  unresolved even if the file content looks identical"
    phase_task='Task: diagnose and fix the export failure above, then commit and push to
origin main using normal Git commands only.'
  fi

  cat >"$target" <<PROMPT
Repository export recovery needed for "${NAME}" at ${REPO}.

Failure phase: ${PHASE}
Local HEAD: ${local_sha}
Fetched origin/main: ${remote_sha}

Sanitized git status:
${git_status}

Sanitized error (last 80 lines):
${sanitized_error}

Invariants (the run only counts as successful if ALL hold):
- never force-push
- never use --no-verify, disable gitleaks, or add a broad allowlist
- never bypass a security hook — diagnose and fix, do not route around it
- preserve unrelated local changes
- do not delete files merely to make the export pass
- finish only when fetched origin/main equals the intended local result
- commit after a green unit of work so a crash does not lose the fix
${phase_invariant}

${phase_task}
PROMPT
}

build_continuation() {
  local target="$1"
  if [[ "$PHASE" == "gitleaks" ]]; then
    cat >"$target" <<PROMPT
Switching harness for repository export recovery of "${NAME}" at ${REPO}.
The previous harness did not satisfy the exit criterion: fetch and check
whether ${REPO}'s own checked-out main branch (not a separate worktree) has
been rewritten/amended to remove the blocked commit, with a clean working
tree. A real, independent scan of that exact candidate range must come back
clean, and only the export automation performs the actual push. Continue
operating directly in ${REPO} itself. Do NOT push yourself. Same invariants
apply: never force-push, never --no-verify, never bypass a security hook,
preserve unrelated changes.
PROMPT
  elif [[ "$PHASE" == "add" || "$PHASE" == "commit" ]]; then
    cat >"$target" <<PROMPT
Switching harness for repository export recovery of "${NAME}" at ${REPO}.
The previous harness did not satisfy the exit criterion. The pending
changes exist ONLY in ${REPO}'s own working tree — a separate default AO
worktree never sees them. Continue operating directly in ${REPO} itself:
commit and push the pending content from there to origin main. Same
invariants apply: never force-push, never --no-verify, never bypass a
security hook, preserve unrelated changes.
PROMPT
  else
    cat >"$target" <<PROMPT
Switching harness for repository export recovery of "${NAME}" at ${REPO}.
The previous harness did not satisfy the exit criterion: a freshly fetched
origin/main must equal local HEAD. Continue from the current worktree state.
Same invariants apply: never force-push, never --no-verify, never bypass a
security hook, preserve unrelated changes, finish only when origin/main
matches local HEAD.
PROMPT
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────
validate_ao_binary

ao_daemon_healthy || die "AO daemon unavailable (ao status --json state != ready)"
ensure_project_registered || die "failed to register AO project ${PROJECT_ID} for ${REPO}"

# C — fail closed unless the symbolic branch about to be exported is
# exactly "main". A checkout on e.g. a feature branch or detached HEAD
# would be silently published to origin/main on the push, rewriting the
# production branch with a commit never intended for it. Verified BEFORE
# any scanner pin or AO spawn.
current_branch="$(cd "$REPO" && git symbolic-ref --quiet --short HEAD 2>/dev/null || echo "")"
[[ "$current_branch" == "main" ]] || die "refusing recovery: $REPO HEAD is on [${current_branch:-detached}], expected main"

# A — pin the trusted scanner BEFORE AO gets a shell, but only for the
# gitleaks phase (scope correction: ordinary conflict/add/commit recovery
# must not fail solely because the optional independent scanner is
# absent; the eventual normal push in those phases still runs the
# configured live Git hooks naturally as a second defense). The worker
# can mutate $REPO's core.hooksPath or freely edit the live hook file,
# so independent_secret_scan_clean() must invoke the snapshot only,
# with checksum verification on every use.
if [[ "$PHASE" == "gitleaks" ]]; then
  pin_trusted_secret_scanner || die "failed to pin trusted secret scanner at $AUTO_PUSH_SECRET_SCAN_BIN; refusing gitleaks recovery without it"
fi

# The commit remote_matches_local() proves is an ancestor of the new
# origin/main before syncing $REPO (ordinary phases), or that
# gitleaks_resolved() proves is NOT an ancestor (gitleaks phase) — see each
# function's comment.
BASELINE_LOCAL_HEAD="$(cd "$REPO" && git rev-parse HEAD 2>/dev/null || echo "")"
[[ -n "$BASELINE_LOCAL_HEAD" ]] || die "cannot resolve local HEAD in $REPO"

# The remote state at spawn time — add_commit_resolved() and
# gitleaks_resolved() both require the remote to have genuinely advanced
# past this, not merely equal $REPO's own (possibly already-matching)
# local HEAD. A silently-swallowed failure here would leave
# INITIAL_REMOTE_SHA stale (or empty), and both resolvers only require
# "remote_sha != INITIAL_REMOTE_SHA" — an empty/stale baseline makes almost
# any real remote SHA look like genuine progress, so a failed fetch must
# fail the whole run closed rather than proceed on a guess.
( cd "$REPO" && git fetch --prune origin main ) >/dev/null 2>&1 \
  || die "initial git fetch of origin/main failed for $REPO; refusing to proceed without a verified baseline remote SHA"
INITIAL_REMOTE_SHA="$(cd "$REPO" && git rev-parse refs/remotes/origin/main 2>/dev/null || echo "")"

# Untracked-file baseline — see worktree_is_clean_and_untracked_unchanged()
# for why pre-existing untracked files must never block success.
BASELINE_UNTRACKED="$(cd "$REPO" && git status --porcelain --untracked-files=all 2>/dev/null \
  | awk '$1=="??"{ sub(/^\?\? /,""); print }' | sort)"

# For "add"/"commit" phases: snapshot the EXACT intended state of every
# pending file BEFORE spawning (skeptic round 2/B). A pure filename list
# catches only "agent never re-saw this path"; a strict superset checks
# each pending path's blob OID and mode at the recovered origin/main,
# which is independent of $REPO's post-fix working tree (the agent
# cannot satisfy the gate by discarding $REPO's pending content while
# some unrelated remote advance publishes the same filename with any
# other bytes -- the OID/mode check fails closed).
#
# Single trusted source of paths, NUL-safe end to end:
#   `git -c core.quotepath=off diff --name-only -z HEAD`
# which is canonical and UNIQUE for the final staged+unstaged intended
# commit (it already covers both stages in one ordered enumeration --
# there is no need to union `diff --cached` with `diff`; doing so
# duplicates entries and breaks the per-row OID check). Note: git paths
# support any byte EXCEPT NUL itself (no real tree ever contains one),
# so per-path NUL framing is sufficient for transport; we still write
# the NUL stream to a private temp file first so the diff exit status
# is observable (process substitution would otherwise swallow a
# non-zero exit from the diff command).
#
# Manifest frame is four NUL-terminated fields per entry:
#   `<kind>\0<path>\0<mode>\0<oid>\0`
# kind ∈ {M, D}; for D rows the mode and oid fields are the literal
# string "<absent>". `git hash-object --path="$path" -- "$path"` is
# what Git itself does at commit time, so OID parity with the future
# commit is guaranteed (clean/smudge attributes stay matched).
#
# add_commit_resolved() verifies with FOUR successive NUL-framed
# `read -r -d ''` lookups against the new origin/main -- one read per
# field per row. No sort, no base64, no PENDING_FILES.
PENDING_MANIFEST_FILE="$(mktemp "${TMPDIR:-/tmp}/ao-pending-manifest.XXXXXX")"
: >"$PENDING_MANIFEST_FILE"
PENDING_PATHS_FILE="$(mktemp "${TMPDIR:-/tmp}/ao-pending-paths.XXXXXX")"
trap 'rm -f "$PENDING_MANIFEST_FILE" "$PENDING_PATHS_FILE" "$PENDING_PATHS_FILE.hash_err"; clean_trusted_scanner' EXIT

( cd "$REPO" && git -c core.quotepath=off diff --name-only -z HEAD >"$PENDING_PATHS_FILE" 2>/dev/null ) \
  || die "git diff --name-only -z HEAD failed for $REPO; refusing to snapshot an unscannable pending state"

# All expansions in the loop body are fully-quoted; we DO NOT toggle the
# shell's `noglob` option globally because any early return from this
# block (e.g. die) would leak the option to whatever shell inherits the
# trap. The loop body just uses `"$REPO/$path"` with quotes, which is
# the standard safe pattern for paths containing glob characters.
while IFS= read -r -d '' path; do
  [[ -n "$path" ]] || continue
  # `[[ -e ]]` returns false on broken symlinks; `[[ -L ]]` is true even
  # when the target is missing. Use the union -- a broken symlink is a
  # real pending change the user intended to include.
  if [[ -e "$REPO/$path" || -L "$REPO/$path" ]]; then
    if [[ -L "$REPO/$path" ]]; then
      mode=120000
    elif [[ -x "$REPO/$path" ]]; then
      mode=100755
    else
      mode=100644
    fi
    # `git hash-object` errors must FAIL CLOSED -- a missing or
    # unreadable blob is a snapshot defect, not a row we silently drop;
    # silently omitting the path would let the agent satisfy the gate
    # by making $REPO's pending content unhashable. Capture stderr to
    # a per-PATHS companion file so the die message can quote it back,
    # then drop the file on success to avoid leaking temp files in the
    # common path. The EXIT trap still owns it for the failure path.
    #
    # CRITICAL subtlety for symlinks: git hash-object --path=symlink
    # -- symlink FOLLOWS the symlink at read time and hashes the
    # TARGET FILE CONTENTS, while git itself stores the symlink
    # TARGET STRING as the 120000 blob content. The two are wildly
    # different OIDs whenever the target string and the target file's
    # content diverge. Match git's own on-disk representation by
    # hashing via --stdin from `readlink -n -- $path`: macOS/Linux
    # `readlink -n` prints the literal target WITHOUT a trailing
    # newline, so command substitution's newline-stripping cannot
    # corrupt the result. We pipe straight into `git hash-object
    # --stdin` (no intermediate variable), and rely on readlink's
    # non-zero exit status if the symlink has no readable target --
    # an empty target is a valid one (git can store it) and must
    # not be rejected. Regular files keep --path / --.
    if [[ "$mode" == "120000" ]]; then
      oid="$(cd "$REPO" && {
        set -o pipefail
        readlink -n -- "$path" | git hash-object --stdin
      } 2>"$PENDING_PATHS_FILE.hash_err")" || {
        hash_err_msg="$(tr -d '\000\r' <"$PENDING_PATHS_FILE.hash_err" 2>/dev/null \
          | tr '\n' ' ' | cut -c1-200)"
        die "git hash-object --stdin failed for symlink [$path] in $REPO; refusing to snapshot a partial pending state (hash-object stderr: $hash_err_msg)"
      }
    else
      oid="$(cd "$REPO" && git hash-object --path="$path" -- "$path" 2>"$PENDING_PATHS_FILE.hash_err")" || {
        hash_err_msg="$(tr -d '\000\r' <"$PENDING_PATHS_FILE.hash_err" 2>/dev/null \
          | tr '\n' ' ' | cut -c1-200)"
        die "git hash-object failed for pending path [$path] in $REPO; refusing to snapshot a partial pending state (hash-object stderr: $hash_err_msg)"
      }
    fi
    rm -f "$PENDING_PATHS_FILE.hash_err" 2>/dev/null || true
    [[ -n "$oid" ]] || die "git hash-object produced empty OID for pending path [$path] in $REPO"
    kind=M
  else
    kind=D
    mode="<absent>"
    oid="<absent>"
  fi
  printf '%s\0%s\0%s\0%s\0' "$kind" "$path" "$mode" "$oid" \
    >>"$PENDING_MANIFEST_FILE"
done <"$PENDING_PATHS_FILE"

# Exit-criterion note: the new origin/main's tree must declare every
# pending path's exact (mode, OID) pair, or be tree-absent for D rows.
# $REPO's post-fix working tree is NEVER consulted for content -- only
# origin/main is.

is_resolved() {
  case "$PHASE" in
    gitleaks) gitleaks_resolved ;;
    add|commit) add_commit_resolved ;;
    *) remote_matches_local ;;
  esac
}

PROMPT_FILE="$(mktemp "${TMPDIR:-/tmp}/ao-recovery-prompt.XXXXXX")"
build_prompt "$PROMPT_FILE"

declare -a HARNESSES=("$AO_PRIMARY_HARNESS" "$AO_FALLBACK_HARNESS")
SESSION_ID=""
FINAL_HARNESS=""
SUCCESS=0

for harness in "${HARNESSES[@]}"; do
  FINAL_HARNESS="$harness"

  if [[ -z "$SESSION_ID" ]]; then
    if ! SESSION_ID="$(ao_spawn "$harness" "$PROMPT_FILE")"; then
      rm -f "$PROMPT_FILE"
      write_state "spawn_failed" "" "$harness"
      die "AO spawn failed for harness=${harness}"
    fi
  else
    CONT_FILE="$(mktemp "${TMPDIR:-/tmp}/ao-recovery-continuation.XXXXXX")"
    build_continuation "$CONT_FILE"
    ao_switch "$SESSION_ID" "$harness" >/dev/null 2>&1 || true
    ao_send "$SESSION_ID" "$CONT_FILE" >/dev/null 2>&1 || true
    rm -f "$CONT_FILE"
  fi

  write_state "running" "$SESSION_ID" "$harness"

  DEADLINE=$(( $(date +%s) + AO_RECOVERY_TIMEOUT_SECS ))
  while [[ "$(date +%s)" -lt "$DEADLINE" ]]; do
    if is_resolved; then
      SUCCESS=1
      break
    fi
    if ao_session_is_terminated "$SESSION_ID"; then
      break
    fi
    sleep "$AO_POLL_SECS"
  done

  # Final check regardless of why the loop exited (timeout vs terminated) —
  # the remote may have converged concurrently with the last poll.
  if [[ "$SUCCESS" -eq 1 ]] || is_resolved; then
    SUCCESS=1
    break
  fi
done

rm -f "$PROMPT_FILE"

if [[ "$SUCCESS" -eq 1 ]]; then
  FINAL_SHA="$(read_final_remote_sha || echo "")"
  [[ -n "$FINAL_SHA" ]] || echo "WARN: could not resolve final remote SHA at write_state(resolved) for ${NAME} (${PHASE})" >&2
  write_state "resolved" "$SESSION_ID" "$FINAL_HARNESS" "$FINAL_SHA"
  exit 0
fi

FINAL_SHA="$(read_final_remote_sha || echo "")"
[[ -n "$FINAL_SHA" ]] || echo "WARN: could not resolve final remote SHA at write_state(exhausted) for ${NAME} (${PHASE})" >&2
write_state "exhausted" "$SESSION_ID" "$FINAL_HARNESS" "$FINAL_SHA"
die "harnesses exhausted without resolving ${NAME} (${PHASE}); AO session ${SESSION_ID} preserved"
