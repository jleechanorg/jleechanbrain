#!/bin/bash
# Core markdown file health probe.
# Checks the 8 policy/identity files that openclaw reads at startup.
# Broken symlinks (pointing to non-existent workspace/ paths) are the
# primary failure mode; empty files are a secondary warning.
#
# Output format (one line each):
#   RC=<0|1|2>        0=healthy, 1=broken symlink/missing, 2=empty file
#   SUMMARY=<text>     human-readable summary

_core_md_probe() {
  local state_dir="${OPENCLAW_STATE_DIR:-$HOME/.smartclaw}"
  local rc=0
  local broken=()
  local empty=()

  # The 8 policy/identity files openclaw reads at startup.
  local core_files=(
    "CLAUDE.md"
    "AGENTS.md"
    "MEMORY.md"
    "RTK.md"
    ".cursorrules"
    "openclaw.json"
    "workspace/CLAUDE.md"
    "workspace/AGENTS.md"
  )

  for f in "${core_files[@]}"; do
    local path="$state_dir/$f"

    # Skip if file doesn't exist at all (not all 8 are required).
    [ -e "$path" ] || [ -L "$path" ] || continue

    # Broken symlink: symlink exists but target is missing.
    if [ -L "$path" ] && [ ! -e "$path" ]; then
      broken+=("$f")
      rc=1
      continue
    fi

    # Empty file: exists but has zero bytes.
    if [ -f "$path" ] && [ ! -s "$path" ]; then
      empty+=("$f")
      # Don't escalate rc from 0→2 if already 1 (broken is worse).
      [ "$rc" -eq 0 ] && rc=2
    fi
  done

  local summary="all core files healthy"
  if [ ${#broken[@]} -gt 0 ]; then
    summary="broken symlink(s): $(IFS=,; echo "${broken[*]}")"
  elif [ ${#empty[@]} -gt 0 ]; then
    summary="empty file(s): $(IFS=,; echo "${empty[*]}")"
  fi

  echo "RC=$rc"
  echo "SUMMARY=$summary"
}
