#!/bin/bash
# rollback-aside-default.sh
#
# Reverses the Aside browser default switch made on 2026-06-27.
# Restores:
#   1. macOS default browser → Chrome (http/https/ftp)
#   2. ~/.claude.json → removes aside-mcp entry
#   3. ~/.smartclaw/skills/aside-browser-default/SKILL.md (deleted)
#   4. SOUL.md / AGENTS.md / CLAUDE.md COMMIT blocks → reverts to pre-aside-default state
#
# Snapshot file: ~/.smartclaw/snapshots/pre-aside-default-YYYY-MM-DD.json
# Idempotent — safe to run multiple times.

set -euo pipefail

HERMES="${HOME}/.smartclaw"
HERMES_PROD="${HOME}/.smartclaw"
SNAP_DIR="${HERMES}/snapshots"
CLAUDE_JSON="${HOME}/.claude.json"
CLAUDE_MD="${HOME}/.claude/CLAUDE.md"
CODEX_AGENTS="${HOME}/.codex/AGENTS.md"
ASIDE_SKILL="${HERMES}/skills/aside-browser-default"
ASIDE_SKILL_PROD="${HERMES_PROD}/skills/aside-browser-default"
CORE="${HERMES}/scripts/rollback_aside_default_core.py"

# Color output
RED='\033[0;31m'
GRN='\033[0;32m'
YEL='\033[1;33m'
NC='\033[0m'

echo -e "${YEL}=== Rollback: Aside browser default → Chrome / Playwright MCP ===${NC}"

# Find most recent snapshot
SNAP=$(ls -1t "${SNAP_DIR}"/pre-aside-default-*.json 2>/dev/null | head -1 || echo "")
if [ -z "$SNAP" ]; then
    echo -e "${RED}ERROR: No snapshot found at ${SNAP_DIR}/pre-aside-default-*.json${NC}"
    echo "Cannot rollback safely — refusing to proceed."
    exit 1
fi
echo -e "${GRN}Snapshot found:${NC} $SNAP"

# Step 1: macOS default browser → Chrome + kill running Aside instances
echo ""
echo -e "${YEL}Step 1/4: Restore macOS default browser to Chrome + terminate Aside${NC}"
if command -v duti >/dev/null 2>&1; then
    duti -s com.google.Chrome http viewer && echo "  ✓ http  → com.google.Chrome" || echo "  ✗ http  failed"
    duti -s com.google.Chrome https viewer && echo "  ✓ https → com.google.Chrome" || echo "  ✗ https failed"
    duti -s com.google.Chrome ftp viewer && echo "  ✓ ftp   → com.google.Chrome" || echo "  ✗ ftp   failed"
else
    echo -e "${RED}duti not found — install with: brew install duti${NC}"
fi

# Kill any running Aside instances (process termination per advisory)
if pgrep -x Aside >/dev/null 2>&1; then
    echo "  → Terminating running Aside instances (advisory step)"
    pkill -x Aside 2>/dev/null || true
    sleep 1
    if pgrep -x Aside >/dev/null 2>&1; then
        echo "  ! Aside still running (close manually) — LaunchServices cache may be stale"
    else
        echo "  ✓ Aside terminated"
    fi
else
    echo "  - No Aside instances running (no change)"
fi

# Step 2: ~/.claude.json → remove aside-mcp
echo ""
echo -e "${YEL}Step 2/4: Remove aside-mcp from ${CLAUDE_JSON}${NC}"
if [ -f "$CLAUDE_JSON" ] && [ -f "$CORE" ]; then
    python3 "$CORE" remove-aside-mcp "$CLAUDE_JSON"
else
    echo -e "${RED}Missing ${CLAUDE_JSON} or ${CORE}${NC}"
fi

# Step 3: Delete aside-browser-default skill folder (staging + prod)
echo ""
echo -e "${YEL}Step 3/4: Delete aside-browser-default skill folder${NC}"
for dir in "$ASIDE_SKILL" "$ASIDE_SKILL_PROD"; do
    if [ -d "$dir" ]; then
        rm -rf "$dir"
        echo "  ✓ Deleted $dir"
    else
        echo "  - $dir already gone (no change)"
    fi
done

# Step 4: Revert SOUL.md / AGENTS.md / CLAUDE.md COMMIT blocks
echo ""
echo -e "${YEL}Step 4/4: Revert browser-default COMMIT blocks in policy files${NC}"

if [ -f "$CORE" ]; then
    # SOUL.md COMMIT blocks (staging + prod)
    python3 "$CORE" revert-soul "${HERMES}/SOUL.md" "${HERMES_PROD}/SOUL.md"

    # Browser-default sections in CLAUDE.md / Codex AGENTS.md / browser-headless-default skills / RESOLVER.md
    python3 "$CORE" revert-section \
        "${CLAUDE_MD}" \
        "${CODEX_AGENTS}" \
        "${HERMES}/skills/browser-headless-default/SKILL.md" \
        "${HERMES_PROD}/skills/browser/browser-headless-default/SKILL.md" \
        "${HERMES}/skills/RESOLVER.md"
else
    echo -e "${RED}Core script missing: ${CORE}${NC}"
fi

# Revert the browser-testing skill
BTEST="${HOME}/.claude/skills/browser-testing/SKILL.md"
if [ -f "$BTEST" ]; then
    cat > "$BTEST" <<'ORIG'
---
name: browser-testing
description: "Use when testing localhost URLs or web UIs. Enforces mcp__playwright-mcp (headless); forbids mcp__claude-in-chrome__* (requires extension)."
---

# Browser testing — always use Playwright MCP headless


**Always use `mcp__playwright-mcp` (headless) to test localhost URLs and web UIs.** Never use `mcp__claude-in-chrome__*` tools for localhost testing — those require a connected Chrome extension and will fail or block in headless/CI contexts. `mcp__playwright-mcp` works out-of-the-box with no browser connection required.

ORIG
    echo "  ✓ Reverted $BTEST"
fi

echo ""
echo -e "${GRN}=== Rollback complete ===${NC}"
echo "Snapshot preserved at: $SNAP"
echo ""
echo "Next: restart Claude Code / Codex so MCP config reloads (or run 'doctor' / reopen Claude Code)."
echo "Verify: duti -x https should now show Google Chrome."