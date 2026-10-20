#!/usr/bin/env bash
# hermetic-gh-stub-test.sh
# Boilerplate test harness for shell scripts that call `gh`.
#
# Usage:
#   source templates/hermetic-gh-stub-test.sh
#   stub_gh_setup TMPDIR               # creates TMP/gh-stub with mode-controlled gh
#   stub_gh_set_mode "graphq-fail-rest-ok" "fixture.json"
#   run_with_stub_path script args...  # runs script with stubbed gh
#
# The stub uses $GH_STUB_MODE to decide which subcommand fails. See the
# SKILL.md "Test harness pattern: hermetic bash function testing" section
# for the full design and the four non-obvious gotchas.

set -uo pipefail

# stub_gh_setup: write a stub `gh` into a temp dir at the FRONT of PATH.
stub_gh_setup() {
  local target="${1:-/tmp/gh-stub-$$}"
  rm -rf "$target"
  mkdir -p "$target"
  cat > "$target/gh" <<'EOSH'
#!/usr/bin/env bash
case "${1:-}" in
  pr)
    if [[ "${2:-}" == "list" ]]; then
      echo "GraphQL: API rate limit already exceeded" >&2
      exit 1
    fi
    ;;
  api)
    if [[ "${GH_STUB_MODE:-}" == "both-fail" ]]; then
      echo "403 REST also exhausted" >&2; exit 1
    fi
    [[ -f "${REST_FIXTURE:-}" ]] && cat "$REST_FIXTURE"
    exit 0
    ;;
  *) echo "stub-gh: unsupported subcommand: $*" >&2; exit 2 ;;
esac
EOSH
  chmod +x "$target/gh"
  export STUB_GH_DIR="$target"
}

# stub_gh_set_mode: select behavior and (optionally) a REST fixture file.
stub_gh_set_mode() {
  local mode="$1"
  local fixture="${2:-}"
  export GH_STUB_MODE="$mode"
  if [[ -n "$fixture" ]]; then
    export REST_FIXTURE="$fixture"
  else
    unset REST_FIXTURE
  fi
}

# run_with_stub_path: run a command with the stub `gh` on PATH first.
# Usage: run_with_stub_path script arg1 arg2 ...
run_with_stub_path() {
  PATH="$STUB_GH_DIR:$PATH" "$@"
}

# Extract bash functions from a script by header name. Returns to stdout.
# Usage: extract_bash_fns "$script_path" header1 header2 ...
# NOT using nested awk functions — `next` inside an awk function is illegal.
extract_bash_fns() {
  local script="$1"; shift
  local pats
  pats="$(printf '%s\\|' "$@")"
  pats="${pats%\\|}"
  awk -v pats="$pats" '
    BEGIN {
      n = split(pats, ps, "|")
      for (i = 1; i <= n; i++) pats_re = (i == 1 ? ps[i] : pats_re "|" ps[i])
    }
    $0 ~ ("^" pats_re "[(]") { p = 1; print; next }
    p && /^}/               { print; p = 0; next }
    p                       { print }
  ' "$script"
}

# Source extracted functions into the current shell (use in `bash -c` subshell).
# Usage:
#   out=$(bash -c "$(extract_bash_fns script.sh get_merged_prs)
#                      log_warn() { :; }
#                      get_merged_prs 'owner/repo'" 2>&1)