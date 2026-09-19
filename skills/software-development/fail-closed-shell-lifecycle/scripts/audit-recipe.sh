#!/usr/bin/env bash
# Diagnostic gate from the fail-closed-shell-lifecycle skill.
# Run against any shell recipe before declaring it done.
#
# Usage: audit-recipe.sh <recipe-file> [recipe-file ...]
# Exit codes:
#   0  clean (no fail-closed violations)
#   1  one or more violations found
#   2  usage error

set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "usage: $0 <recipe-file> [recipe-file ...]" >&2
  exit 2
fi

violations=0
for recipe in "$@"; do
  [ -f "$recipe" ] || { echo "not a file: $recipe" >&2; continue; }
  echo "=== auditing $recipe ==="

  if ! grep -qE '^set -euo pipefail|set -euo pipefail' "$recipe"; then
    echo "  FAIL: missing 'set -euo pipefail'"
    violations=$((violations + 1))
  fi

  if ! grep -qE '^umask 077|umask 077$' "$recipe"; then
    echo "  FAIL: missing 'umask 077'"
    violations=$((violations + 1))
  fi

  if grep -nE 'trap - .*(EXIT|INT|TERM|HUP)' "$recipe"; then
    echo "  FAIL: 'trap -' disarm line found (recipe is not fail-closed)"
    violations=$((violations + 1))
  fi

  if grep -nE 'kill -[A-Z]+ "?"\$\$"? ' "$recipe" \
       | grep -v '^[^:]*: *#'; then
    echo "  FAIL: 'kill -SIG \$\$' re-raise in signal handler (bash swallows same-signal re-raises)"
    violations=$((violations + 1))
  fi

  if grep -nE '/tmp/[a-zA-Z0-9_.-]+\.(json|txt|har|cookies|tmp)' "$recipe"; then
    echo "  FAIL: fixed '/tmp/<name>' path found (use \$TMP_* instead)"
    violations=$((violations + 1))
  fi

  if [ "$violations" -gt 0 ]; then
    echo "  recipe: NOT fail-closed"
  else
    echo "  recipe: clean"
  fi
done

[ "$violations" -eq 0 ]
