#!/usr/bin/env bash
# test_wiki_campaign_daily_ingest.sh
# Tests that wiki-campaign-daily-ingest.sh stages and pushes ALL valid repo files
# (including raw/, wiki/concepts/, wiki/entities/, wiki/sources/, etc.) to origin/main.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/wiki-campaign-daily-ingest.sh"

[[ -f "$SCRIPT" ]] || { echo "FAIL: script not found at $SCRIPT"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test_wiki_ingest.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

PASSED=0
FAILED=0
pass() { echo "PASS: $1"; PASSED=$((PASSED + 1)); }
fail() { echo "FAIL: $1"; FAILED=$((FAILED + 1)); }

# Test environment isolation
export GMAIL_TO="test@example.com"
export SLACK_CHANNEL=""
export WORLDAI_DEV_MODE=true

new_fixture() {
  local root="$1"
  mkdir -p "$root"
  git init --bare "$root/origin.git" >/dev/null
  git clone "$root/origin.git" "$root/work" >/dev/null 2>&1
  git -C "$root/work" config user.name "Fixture"
  git -C "$root/work" config user.email "${GITHUB_USER}@users.noreply.github.com"
  
  # Initial commit
  mkdir -p "$root/work/wiki/sources" "$root/work/wiki/concepts" "$root/work/wiki/entities" "$root/work/raw"
  printf '# Index\n' >"$root/work/wiki/index.md"
  printf '# Log\n' >"$root/work/wiki/log.md"
  printf 'initial\n' >"$root/work/wiki/concepts/ArmyFactionPower.md"
  
  git -C "$root/work" add -A
  git -C "$root/work" commit -m "init" >/dev/null
  git -C "$root/work" branch -M main
  git -C "$root/work" push -u origin main >/dev/null 2>&1
}

test_full_repo_files_committed_and_pushed() {
  local root="$TMP/full_repo"
  new_fixture "$root"

  # Add modified and untracked files across different dirs
  printf 'modified concept\n' >>"$root/work/wiki/concepts/ArmyFactionPower.md"
  printf 'new concept\n' >"$root/work/wiki/concepts/NewConcept.md"
  printf 'new entity\n' >"$root/work/wiki/entities/NewEntity.md"
  mkdir -p "$root/work/raw/campaigns/test1234"
  printf 'raw campaign\n' >"$root/work/raw/campaigns/test1234/test1234.txt"
  printf 'raw feedback\n' >"$root/work/raw/feedback_2026-08-23.md"
  printf '<html>wiki article</html>\n' >"$root/work/wiki/TestArticle.html"
  printf 'new source\n' >"$root/work/wiki/sources/new-source.md"
  printf 'log update\n' >>"$root/work/wiki/log.md"
  printf 'index update\n' >>"$root/work/wiki/index.md"

  # Run the script pointing to our fixture wiki dir and skipping live firestore batch
  WIKI_DIR="$root/work" \
  LOG="$TMP/test.log" \
  MANIFEST="$TMP/manifest.jsonl" \
  DAILY_RAW="$TMP/daily_raw" \
  SKIP_DOWNLOAD=1 \
  bash "$SCRIPT" >"$TMP/run.out" 2>&1 || {
    echo "Script returned non-zero:"
    cat "$TMP/run.out"
    return 1
  }

  # Verify all files exist in origin.git on branch main
  local missing=0
  for path in \
    "wiki/concepts/ArmyFactionPower.md" \
    "wiki/concepts/NewConcept.md" \
    "wiki/entities/NewEntity.md" \
    "raw/campaigns/test1234/test1234.txt" \
    "raw/feedback_2026-08-23.md" \
    "wiki/TestArticle.html" \
    "wiki/sources/new-source.md" \
    "wiki/log.md" \
    "wiki/index.md"; do
    if ! git --git-dir="$root/origin.git" show "main:$path" >/dev/null 2>&1; then
      echo "  MISSING from remote main: $path"
      missing=$((missing + 1))
    fi
  done

  [[ "$missing" -eq 0 ]]
}

run_test() {
  local name="$1" fn="$2"
  if "$fn" >"$TMP/$name.out" 2>&1; then
    pass "$name"
  else
    fail "$name"
    sed 's/^/    /' "$TMP/$name.out"
  fi
}

run_test full_repo_files_committed_and_pushed test_full_repo_files_committed_and_pushed

echo ""
echo "Passed: $PASSED, Failed: $FAILED"
exit "$FAILED"
