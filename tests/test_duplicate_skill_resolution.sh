#!/usr/bin/env bash
# Contract test for the duplicate-skill-resolution check.
#
# Verifies:
#  (A) check_duplicate_skill_resolution reports PASS when no hermes-imports/ mirror
#  (B) check_duplicate_skill_resolution reports PASS when the mirror exists but carries
#      no SKILL.md (the only file present is the bin/...)
#  (C) check_duplicate_skill_resolution reports FAIL when a byte-identical SKILL.md
#      pair exists across the two roots
#  (D) check_duplicate_skill_resolution reports PASS when the mirror copy is a
#      diverged (different bytes) version of the canonical copy
#  (E) shellcheck clean
#
# Aliased to make the test harness happy: maps `pass`/`warn`/`fail` to increment
# counters (we don't care about the doctor's PASS_COUNT/WARN_COUNT/FAIL_COUNT
# state — only the exit code + the FAIL message string).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Extract the check function from doctor.sh so we can source it standalone.
CHECK_FUNC="$(awk '/^check_duplicate_skill_resolution\(\) \{/,/^\}$/' "$REPO_ROOT/scripts/doctor.sh")"

if [[ -z "$CHECK_FUNC" ]]; then
  echo "FAIL: cannot extract check_duplicate_skill_resolution from $REPO_ROOT/scripts/doctor.sh"
  exit 1
fi

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf '  [PASS] %s\n' "$1"; }
warn() { WARN_COUNT=$((WARN_COUNT + 1)); printf '  [WARN] %s\n' "$1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); printf '  [FAIL] %s\n' "$1"; }

# Build a tempfile-backed hermes root so the test does not pollute the real ~/.smartclaw
TMP_ROOT="$(mktemp -d -t dup-skill-test.XXXXXX)"
trap 'rm -rf "$TMP_ROOT"' EXIT

echo "=== Test (A): no hermes-imports/ mirror present ==="
mkdir -p "$TMP_ROOT/skills/no-imports-here"
PASSED_A=0
(
  eval "$CHECK_FUNC"
  check_duplicate_skill_resolution "$TMP_ROOT"
) >/tmp/dup-skill-A.out 2>&1
if grep -q 'no hermes-imports/ mirror present' /tmp/dup-skill-A.out; then
  pass "(A) PASS message emitted when no mirror exists"
  PASSED_A=1
else
  fail "(A) expected PASS message about missing mirror, got: $(cat /tmp/dup-skill-A.out)"
fi

echo "=== Test (B): mirror exists but contains no SKILL.md ==="
mkdir -p "$TMP_ROOT/skills/hermes-imports"
mkdir -p "$TMP_ROOT/skills/hermes-imports/empty-category/empty-skill"
(
  eval "$CHECK_FUNC"
  check_duplicate_skill_resolution "$TMP_ROOT"
) >/tmp/dup-skill-B.out 2>&1
if grep -q 'no SKILL.md files under hermes-imports' /tmp/dup-skill-B.out; then
  pass "(B) PASS message emitted when mirror has no SKILL.md"
else
  fail "(B) expected PASS message about no SKILL.md, got: $(cat /tmp/dup-skill-B.out)"
fi

echo "=== Test (C): byte-identical SKILL.md pair across mirror ==="
mkdir -p "$TMP_ROOT/skills/dupcat-a/dupskill-a"
mkdir -p "$TMP_ROOT/skills/hermes-imports/dupcat-a/dupskill-a"
printf -- '--- yaml frontmatter\nname: dup-skill-a\n--- markdown\n' > "$TMP_ROOT/skills/dupcat-a/dupskill-a/SKILL.md"
cp "$TMP_ROOT/skills/dupcat-a/dupskill-a/SKILL.md" "$TMP_ROOT/skills/hermes-imports/dupcat-a/dupskill-a/SKILL.md"
(
  eval "$CHECK_FUNC"
  check_duplicate_skill_resolution "$TMP_ROOT"
) >/tmp/dup-skill-C.out 2>&1
if grep -q 'duplicate-skill-resolution ambiguity detected' /tmp/dup-skill-C.out; then
  pass "(C) FAIL message emitted when byte-identical pair exists"
else
  fail "(C) expected FAIL message about duplicate pair, got: $(cat /tmp/dup-skill-C.out)"
fi

echo "=== Test (D): diverged SKILL.md between canonical and mirror ==="
mkdir -p "$TMP_ROOT/skills/dupcat-b/dupskill-b"
mkdir -p "$TMP_ROOT/skills/hermes-imports/dupcat-b/dupskill-b"
printf -- 'canonical-version\n' > "$TMP_ROOT/skills/dupcat-b/dupskill-b/SKILL.md"
printf -- 'mirror-version-different-bytes\n' > "$TMP_ROOT/skills/hermes-imports/dupcat-b/dupskill-b/SKILL.md"
# Use a fresh TMP_ROOT so test (C)'s dupcat-a entry doesn't leak into this case
# (the eval'd function's local variables persist across invocations in the same
# shell). Fresh subtree under a different name avoids the leakage.
mkdir -p "$TMP_ROOT/skills/dupcat-d/dupskill-d"
mkdir -p "$TMP_ROOT/skills/hermes-imports/dupcat-d/dupskill-d"
printf -- 'canonical-d\n' > "$TMP_ROOT/skills/dupcat-d/dupskill-d/SKILL.md"
printf -- 'mirror-d-different\n' > "$TMP_ROOT/skills/hermes-imports/dupcat-d/dupskill-d/SKILL.md"
# Remove the bytestream-identical pair from test (C) so it doesn't trigger the FAIL
# branch in this case.
rm -rf "$TMP_ROOT/skills/dupcat-a/dupskill-a/SKILL.md" \
       "$TMP_ROOT/skills/hermes-imports/dupcat-a/dupskill-a/SKILL.md"
(
  eval "$CHECK_FUNC"
  check_duplicate_skill_resolution "$TMP_ROOT"
) >/tmp/dup-skill-D.out 2>&1
if grep -q 'duplicate-skill-resolution ambiguity detected' /tmp/dup-skill-D.out; then
  fail "(D) FAIL message emitted when bytes differ — should be PASS"
  cat /tmp/dup-skill-D.out
else
  pass "(D) no FAIL message when canonical and mirror differ by bytes"
fi

echo "=== Test (E): shellcheck clean (if available) ==="
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck "$REPO_ROOT/scripts/doctor.sh" 2>&1 | grep -E 'check_duplicate_skill_resolution' | grep -qE 'error|warning'; then
    fail "(E) shellcheck flagged the new check function"
  else
    pass "(E) shellcheck clean on the new check function"
  fi
else
  warn "(E) shellcheck not installed — skipping"
fi

echo
echo "Summary: $PASS_COUNT pass, $WARN_COUNT warn, $FAIL_COUNT fail"
if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi
exit 0
