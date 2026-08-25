#!/usr/bin/env bash
# Shell-based contract test for the default coding-routing policy.
#
# Mirrors tests/test_routing_default_claudem.py with grep/jq-style
# assertions for ops who want a quick standalone gate (no pytest
# required). Failed assertions cause a non-zero exit.
#
# Invocation:
#   bash tests/test_routing_default_claudem.sh
#
# The same default-AO policy applies: claudem (claude-code-claudem)
# is the default; AO via /af or explicit AO language is opt-in only.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOUL="$REPO_ROOT/workspace/SOUL.md"
CLAW="$REPO_ROOT/.claude/skills/claw-dispatch/SKILL.md"
RESOLVER="$REPO_ROOT/skills/RESOLVER.md"
DISPATCH="$REPO_ROOT/skills/dispatch-task/SKILL.md"
FINISH="$REPO_ROOT/skills/finish-the-job/SKILL.md"
ALWAYS_PR="$REPO_ROOT/skills/workflow/always-pr-never-local-edit/SKILL.md"

fails=0
passes=0

assert() {
  local name="$1"
  local file="$2"
  local pattern="$3"
  if [ ! -f "$file" ]; then
    echo "FAIL [no-file]: $name — $file"
    fails=$((fails + 1))
    return
  fi
  if grep -qE "$pattern" "$file"; then
    echo "PASS: $name"
    passes=$((passes + 1))
  else
    echo "FAIL [missing pattern]: $name — pattern: $pattern"
    fails=$((fails + 1))
  fi
}

refute() {
  local name="$1"
  local file="$2"
  local pattern="$3"
  if [ ! -f "$file" ]; then
    echo "FAIL [no-file]: $name — $file"
    fails=$((fails + 1))
    return
  fi
  if grep -qE "$pattern" "$file"; then
    echo "FAIL [unexpected pattern]: $name — pattern: $pattern"
    fails=$((fails + 1))
  else
    echo "PASS: $name"
    passes=$((passes + 1))
  fi
}

# 1. workspace/SOUL.md
refute "SOUL.md Agent Dispatch Policy does NOT use 'ao is canonical' headline" \
  "$SOUL" \
  '`ao` is canonical'

assert "SOUL.md Agent Dispatch Policy names claude-code-claudem default" \
  "$SOUL" \
  'claude-code-claudem.*default for ordinary coding work'

assert "SOUL.md retains explicit-af-task-lock block" \
  "$SOUL" \
  '## COMMIT: explicit-af-task-lock'

assert "SOUL.md explicit-af-task-lock trigger names /af" \
  "$SOUL" \
  'COMMIT: explicit-af-task-lock'

# 2. .claude/skills/claw-dispatch/SKILL.md
refute "claw-dispatch does NOT say 'AO workers first'" \
  "$CLAW" \
  '## Default behavior — AO workers first'

assert "claw-dispatch declares /claw as AO" \
  "$CLAW" \
  '/claw.*\(any task\).*Force `ao spawn`'

assert "claw-dispatch declares /af as AO" \
  "$CLAW" \
  '/af` / `/auto-factory`.*Force `ao spawn`'

assert "claw-dispatch mentions claude-code-claudem as the natural-language default" \
  "$CLAW" \
  'claude-code-claudem'

# 3. skills/RESOLVER.md
assert "RESOLVER.md claude-code-claudem block mentions 'default'" \
  "$RESOLVER" \
  '^## claude-code-claudem$'

# Find one block mentioning "default"
if grep -A 25 '^## claude-code-claudem$' "$RESOLVER" | grep -qiE 'default'; then
  echo "PASS: RESOLVER.md claude-code-claudem block mentions default"
  passes=$((passes + 1))
else
  echo "FAIL: RESOLVER.md claude-code-claudem block does not mention default"
  fails=$((fails + 1))
fi

refute "RESOLVER.md does NOT call claudem the 'smaller alternative' to AO" \
  "$RESOLVER" \
  'those spawn AO workers for PR-sized multi-turn work.*claudem.*one-shot'

# 4. skills/dispatch-task/SKILL.md
assert "dispatch-task description references claude-code-claudem" \
  "$DISPATCH" \
  '^description:'

if grep '^description:' "$DISPATCH" | grep -qiE 'opt-in|claude-code-claudem|/af'; then
  echo "PASS: dispatch-task description notes opt-in / claude-code-claudem default"
  passes=$((passes + 1))
else
  echo "FAIL: dispatch-task description missing opt-in language"
  fails=$((fails + 1))
fi

# 5. skills/finish-the-job/SKILL.md
# macOS / BSD awk treats `|` as a literal in BRE — use ERE explicitly.
PHASE2_BLOCK=$(awk '/^### Phase 2/{flag=1; next} /^### Phase 3/{flag=0} flag' "$FINISH")
if printf '%s\n' "$PHASE2_BLOCK" | grep -qE 'claude-code-claudem|`claudem -p`|claudeminimax'; then
  echo "PASS: finish-the-job Phase 2 names claudem default"
  passes=$((passes + 1))
else
  echo "FAIL: finish-the-job Phase 2 does not name claudem default"
  fails=$((fails + 1))
fi

refute "finish-the-job phase 2 does NOT default new features to dispatch-task alone" \
  "$FINISH" \
  '^For new features: dispatch via `dispatch-task` skill \(`ao spawn`\)'

# 6. skills/workflow/always-pr-never-local-edit/SKILL.md
refute "always-pr-never-local-edit step 3 does NOT say 'Dispatch via `ao spawn`'" \
  "$ALWAYS_PR" \
  'Dispatch via `ao spawn`'

assert "always-pr-never-local-edit step 3 references claudem default" \
  "$ALWAYS_PR" \
  '[Dd]elegate to `claude-code-claudem`'

# Summary
echo ""
echo "Summary: $passes passed, $fails failed"
exit "$fails"
