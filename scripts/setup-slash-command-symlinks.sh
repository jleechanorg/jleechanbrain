#!/usr/bin/env bash
# scripts/setup-slash-command-symlinks.sh — Create symlinks in ~/.claude/commands
# and ~/.codex/commands/ pointing to the canonical sources in
# ~/.smartclaw/.claude/commands/. Idempotent. Run once per host or after `deploy.sh`
# to make `/a`, `/fullrun`, and `/launchd-autonomy-report` resolvable by Claude
# Code (user-scope) and Codex.
#
# Why this exists: ~/.claude/commands/ and ~/.codex/commands/ are user-scope
# command directories for Claude Code and Codex respectively. The canonical
# source for hermes commands is ~/.smartclaw/.claude/commands/. Without symlinks,
# Claude Code and Codex won't see the new /a, /fullrun, or /launchd-autonomy-
# report slash commands.
#
# Idempotent: re-running is safe; existing symlinks pointing to the right
# target are skipped; broken or wrong symlinks are recreated; regular files
# are backed up before being replaced.

set -euo pipefail

CANONICAL_ROOT="${HOME}/.smartclaw/.claude/commands"
COMMANDS=(a fullrun launchd-autonomy-report)

# Host-level user-scope command directories
TARGETS=(
  "${HOME}/.claude/commands"
  "${HOME}/.codex/commands"
)

create_link() {
  local target_dir="$1"
  local cmd="$2"
  local link="${target_dir}/${cmd}.md"
  local target="${CANONICAL_ROOT}/${cmd}.md"

  mkdir -p "$target_dir"

  if [[ -L "$link" ]]; then
    local current
    current=$(readlink "$link")
    if [[ "$current" == "$target" ]]; then
      echo "  EXISTS ${link} → ${target}"
      return 0
    fi
    echo "  RELINK  ${link} (was → ${current})"
    rm "$link"
  elif [[ -e "$link" ]]; then
    # Regular file — back up before replacing
    local backup="${link}.bak.$(date +%s)"
    mv "$link" "$backup"
    echo "  BACKED UP ${link} → ${backup}"
  fi

  ln -s "$target" "$link"
  echo "  CREATED ${link} → ${target}"
}

main() {
  if [[ ! -d "$CANONICAL_ROOT" ]]; then
    echo "FATAL: canonical root not found: $CANONICAL_ROOT" >&2
    exit 1
  fi
  for target_dir in "${TARGETS[@]}"; do
    echo "=== ${target_dir} ==="
    for cmd in "${COMMANDS[@]}"; do
      if [[ -f "${CANONICAL_ROOT}/${cmd}.md" ]]; then
        create_link "$target_dir" "$cmd"
      else
        echo "  SKIP ${cmd} (no source file at ${CANONICAL_ROOT}/${cmd}.md)"
      fi
    done
  done
  echo
  echo "Setup complete. Verify with:"
  echo "  ls -la ~/.claude/commands/{a,fullrun,launchd-autonomy-report}.md"
  echo "  ls -la ~/.codex/commands/{a,fullrun,launchd-autonomy-report}.md"
}

main "$@"
