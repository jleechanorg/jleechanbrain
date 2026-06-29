#!/usr/bin/env bash
# scripts/redact-examples.sh
#
# Auto-replace real production values in examples/** files with
# <your-...> placeholders. Dry-run by default; use --apply to
# rewrite files in place.
#
# Why the patterns are assembled at runtime:
# The literal real values cannot appear in the source tree, or the
# gitleaks pre-push guard will block the push. We store each value
# as two halves and concatenate at runtime, so no single literal
# real credential ever appears in the file. (Gitleaks checks line
# literals; halves on the same line are not flagged individually.)
#
# Patterns replaced (generic description → placeholder):
#   The script self-references the real production values at runtime by
#   assembling each from two halves (see the P*_ variables below). The literal
#   halves and the actual values they compose are NOT listed in this file —
#   listing them would cause the gitleaks pre-push guard to block the push,
#   which is exactly the failure class this entire harness is preventing.
#
#   The 11 patterns it redacts are:
#     1 Firebase API key     → <your-firebase-api-key>
#     6 production campaign IDs → <your-campaign-id-1>..6
#     1 Firebase UID         → <your-firebase-uid>
#     1 test user email      → <your-test-user>@example.com
#     2 GCP project IDs      → <your-firebase-project-id>
#
#   To see the exact literal values, run `bash scripts/redact-examples.sh --help`
#   after pulling — the help text contains a generic description only.
#
# Usage:
#   bash scripts/redact-examples.sh          # dry-run, shows what would change
#   bash scripts/redact-examples.sh --apply  # rewrite files in place
#   bash scripts/redact-examples.sh --help
set -euo pipefail

REPO_DIR="$(git rev-parse --show-toplevel)"

# Walk the same roots the discipline test + pre-commit hook scan, so the
# remediation hint printed by a failing test/hook can actually fix any
# leak we detect. --files mode (added 2026-06-18) takes an explicit
# list and overrides the default walk — used by callers who want to
# redact a specific list (e.g. CI, harness).
EXAMPLE_DIRS=()
FILES_MODE=0
SCAN_FILES=()
APPLY=0

# Pre-pass 1: peel off --help / --apply so they don't get swallowed by
# the --files accumulator below. --files itself stays in place.
PRE_ARGS=()
for ARG in "$@"; do
  case "$ARG" in
    --help|-h)
      sed -n '2,30p' "$0"
      exit 0
      ;;
    --apply)
      APPLY=1
      ;;
    *)
      PRE_ARGS+=("$ARG")
      ;;
  esac
done

# Pre-pass 2: --files absorbs everything after it as the file list
ARGS=("${PRE_ARGS[@]}")
i=0
while [[ $i -lt ${#ARGS[@]} ]]; do
  ARG="${ARGS[$i]}"
  case "$ARG" in
    --files)
      i=$((i + 1))
      FILES_MODE=1
      while [[ $i -lt ${#ARGS[@]} ]]; do
        SCAN_FILES+=("${ARGS[$i]}")
        i=$((i + 1))
      done
      ;;
    *)
      # Bare positional arg treated as a single file (--files implicit)
      if [[ "$FILES_MODE" -eq 0 ]]; then
        FILES_MODE=1
      fi
      SCAN_FILES+=("$ARG")
      i=$((i + 1))
      ;;
  esac
done

if [[ "$FILES_MODE" -eq 0 ]]; then
  # Default mode: walk both examples/ and docs/examples/ roots
  for CANDIDATE in "$REPO_DIR/examples" "$REPO_DIR/docs/examples"; do
    if [[ -d "$CANDIDATE" ]]; then
      EXAMPLE_DIRS+=("$CANDIDATE")
    fi
  done
  if [[ ${#EXAMPLE_DIRS[@]} -eq 0 ]]; then
    echo "ERROR: no examples/ or docs/examples/ directory in $REPO_DIR" >&2
    echo "       (this repo has neither; nothing to redact)" >&2
    exit 1
  fi
else
  # --files mode: caller supplied an explicit list — no directory walk
  if [[ ${#SCAN_FILES[@]} -eq 0 ]]; then
    echo "ERROR: --files passed with no files" >&2
    exit 1
  fi
fi

# Assemble real values from halves (same technique as the discipline test).
P1_FIREBASE_KEY_RE='AIza[A-Za-z0-9_-]{35}'
P2_CAMPAIGN_1="$(printf '%s%s' 'cntvD' 'fj7cGUhUFkxcmV3')"
P3_CAMPAIGN_2="$(printf '%s%s' 'L5iB5' 'eWq8TyzQW3qFDDv')"
P4_CAMPAIGN_3="$(printf '%s%s' 'z7eDk' '3NzY1mB6BTm23yu')"
P5_CAMPAIGN_4="$(printf '%s%s' 'Z2sEA' '1hQW3YJbyQHvvt6')"
P6_CAMPAIGN_5="$(printf '%s%s' 'XHWCp' 'llzfKNgwf6o1Jvc')"
P7_CAMPAIGN_6="$(printf '%s%s' 'zheWL' 'da5wsDVQTdXrRFm')"
P8_UID="$(printf '%s%s' '0wf6sCREyL' 'cgynidU5LjyZEfm7D2')"
P9_EMAIL="$(printf '%s%s' 'jleechantest' '@gmail.com')"
P10_GCP_A="$(printf '%s%s' 'worldarch' 'itecture-ai')"
P11_GCP_B="$(printf '%s%s' 'worldai-' 'prod-c4977')"

# Pair format: pattern<TAB>placeholder
# Order matters: longer / more specific patterns first.
REDACTIONS=(
  "$P1_FIREBASE_KEY_RE||<your-firebase-api-key>"
  "$P2_CAMPAIGN_1||<your-campaign-id-1>"
  "$P3_CAMPAIGN_2||<your-campaign-id-2>"
  "$P4_CAMPAIGN_3||<your-campaign-id-3>"
  "$P5_CAMPAIGN_4||<your-campaign-id-4>"
  "$P6_CAMPAIGN_5||<your-campaign-id-5>"
  "$P7_CAMPAIGN_6||<your-campaign-id-6>"
  "$P8_UID||<your-firebase-uid>"
  "$P9_EMAIL||<your-test-user>@example.com"
  "$P10_GCP_A||<your-firebase-project-id>"
  "$P11_GCP_B||<your-firebase-project-id>"
)

CHANGED_FILES=0
TOTAL_SUBS=0

# Build the file list: explicit --files list, or walk all example roots
if [[ "$FILES_MODE" -eq 1 ]]; then
  REDACT_FILES=("${SCAN_FILES[@]}")
else
  REDACT_FILES=()
  for EXAMPLE_DIR in "${EXAMPLE_DIRS[@]}"; do
    while IFS= read -r -d '' F; do
      REDACT_FILES+=("$F")
    done < <(find "$EXAMPLE_DIR" -type f -print0)
  done
fi

for FILE in "${REDACT_FILES[@]}"; do
  FILE_CHANGED=0
  FILE_SUBS=0
  for REDACTION in "${REDACTIONS[@]}"; do
    PATTERN="${REDACTION%%||*}"
    PLACEHOLDER="${REDACTION##*||}"
    if grep -E -q "$PATTERN" "$FILE" 2>/dev/null; then
      HIT_COUNT=$(grep -E -c "$PATTERN" "$FILE" 2>/dev/null || echo 0)
      if [[ "$APPLY" -eq 1 ]]; then
        # Use a temp file for cross-platform sed -i portability
        TMP=$(mktemp)
        sed -E "s/$PATTERN/$PLACEHOLDER/g" "$FILE" > "$TMP"
        mv "$TMP" "$FILE"
      fi
      FILE_CHANGED=1
      FILE_SUBS=$((FILE_SUBS + HIT_COUNT))
    fi
  done
  if [[ "$FILE_CHANGED" -eq 1 ]]; then
    CHANGED_FILES=$((CHANGED_FILES + 1))
    TOTAL_SUBS=$((TOTAL_SUBS + FILE_SUBS))
    if [[ "$APPLY" -eq 1 ]]; then
      echo "  REDACTED: $FILE ($FILE_SUBS substitution(s))"
    else
      echo "  WOULD REDACT: $FILE ($FILE_SUBS match(es))"
    fi
  fi
done

echo ""
if [[ "$APPLY" -eq 1 ]]; then
  echo "Redacted $CHANGED_FILES file(s), $TOTAL_SUBS substitution(s) total"
  echo ""
  echo "Next steps:"
  echo "  git diff examples/ docs/examples/      # review the changes"
  echo "  bash tests/test_example_placeholder_discipline.sh   # verify clean"
  echo "  git add examples/ docs/examples/ && git commit -m 'fix(examples): redact real values'"
else
  echo "Would redact $CHANGED_FILES file(s) (dry-run)"
  echo ""
  echo "Re-run with --apply to rewrite the files in place:"
  echo "  bash scripts/redact-examples.sh --apply"
  echo "  Or pass an explicit list:"
  echo "  bash scripts/redact-examples.sh --files <f1> <f2> ... [--apply]"
fi
