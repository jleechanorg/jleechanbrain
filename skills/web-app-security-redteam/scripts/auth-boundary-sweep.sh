#!/usr/bin/env bash
# auth-boundary-sweep.sh — probe every common public/private endpoint boundary.
#
# Usage:  ./auth-boundary-sweep.sh https://target.example
# Output: tabular HTTP status per endpoint. Look for unexpected 200s on auth-required
#         endpoints, and unexpected 500s on auth-bypassable ones (means the dev mode
#         is leaking internal state).
#
# What this catches:
#   - Public endpoints that should be auth-gated (unauthenticated 200 on /api/campaigns)
#   - Auth-gated endpoints that crash on bad input (500 instead of 401)
#   - Endpoints that leak information in 404 vs 401 (existence oracle)
#
# Companion skill: web-app-security-redteam

set -u
TARGET="${1:-https://worldarchitect.ai}"

ENDPOINTS=(
  # Public by design — expect 200 (unless behind CDN auth)
  "/"
  "/health"
  "/api/time"
  "/api/constants/models"

  # Should be 401 (auth required)
  "/api/campaigns"
  "/api/campaigns/nonexistent-id-test"
  "/api/settings"
  "/api/campaign_templates/dragon_knight/description"
  "/v1/models"
  "/v1/chat/completions"
  "/api/avatar"
  "/api/campaign/abc/avatar"

  # POST-only public (should not exist as GET — 405 expected)
  "/api/client_diag"

  # MCP / JSON-RPC
  "/mcp"

  # Schema/info dumps — common leak vector
  "/api/god_mode/schema"
  "/api/agents"
  "/api/system_prompt"
  "/api/llm/prompts"
  "/debug/prompts"

  # Static file attempts
  "/prompts/master_directive.md"
  "/mvp_site/prompts/master_directive.md"
  "/static/prompts/master_directive.md"
  "/etc/passwd"
)

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

printf "%-50s %-6s %-8s %s\n" "ENDPOINT" "CODE" "SIZE" "VERDICT"
printf '%.0s-' {1..80}; echo

for p in "${ENDPOINTS[@]}"; do
  TMP=$(mktemp)
  CODE=$(curl -sS -o "$TMP" -w "%{http_code}" --max-time 10 "$TARGET$p" 2>/dev/null || echo "000")
  SIZE=$(wc -c < "$TMP" 2>/dev/null | tr -d ' ')
  BODY_HEAD=$(head -c 80 "$TMP" | tr '\n' ' ' | head -c 80)

  # Verdict logic
  VERDICT="?"
  if [[ "$CODE" == "200" ]]; then
    if echo "$BODY_HEAD" | grep -q '<!doctype html>'; then
      VERDICT="${GREEN}SPA shell (route catch-all)${NC}"
    elif [[ "$p" == "/" || "$p" == "/health" || "$p" == "/api/time" || \
            "$p" == "/api/constants/models" || "$p" == "/api/god_mode/schema" || \
            "$p" == "/api/agents" || "$p" == "/api/system_prompt" || \
            "$p" == "/debug/prompts" ]]; then
      VERDICT="${YELLOW}PUBLIC — verify by design${NC}"
    else
      VERDICT="${RED}!! UNEXPECTED 200 !!${NC}"
    fi
  elif [[ "$CODE" == "401" || "$CODE" == "403" ]]; then
    VERDICT="${GREEN}auth-gated (good)${NC}"
  elif [[ "$CODE" == "404" ]]; then
    if [[ "$p" == "/api/avatar" || "$p" == "/api/agents" || \
          "$p" == "/api/system_prompt" || "$p" == "/debug/prompts" ]]; then
      VERDICT="${GREEN}404 (no such endpoint)${NC}"
    else
      VERDICT="${YELLOW}404 — check whether existence oracle${NC}"
    fi
  elif [[ "$CODE" == "405" ]]; then
    VERDICT="${GREEN}405 method not allowed (good — wrong method)${NC}"
  elif [[ "$CODE" == "410" ]]; then
    VERDICT="${YELLOW}410 gone — check whether intentional${NC}"
  elif [[ "$CODE" == "500" ]]; then
    VERDICT="${RED}!! 500 — server error on unauth !!${NC}"
  fi

  printf "%-50s %-6s %-8s %b\n" "$p" "$CODE" "$SIZE" "$VERDICT"
  rm -f "$TMP"
done

echo
echo "Verdicts:"
echo "  GREEN = expected behavior"
echo "  YELLOW = verify manually"
echo "  RED    = unexpected; investigate"
echo
echo "Common real-app 200s to investigate:"
echo "  /api/god_mode/schema         — info disclosure (attack-shape leak)"
echo "  /api/agents                  — schema leak"
echo "  /debug/prompts               — debug endpoint left in prod"
echo "  /api/system_prompt           — full prompt leak"
