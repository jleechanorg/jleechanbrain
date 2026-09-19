# worldarchitect.ai red-team — 2026-08-22 (worked example)

Reference doc for `web-app-security-redteam` SKILL.md. This is the worked transcript from the 2026-08-22 audit; future red-teams pattern-match against the file:line refs and reproduction commands.

**Target:** https://worldarchitect.ai (prod GCP Cloud Run)
**Repo:** `~/repos/jleechanorg/worldarchitect.ai` HEAD `1d8f41e95c`
**Verifier:** Hermes session, MiniMax-M3, Slack thread

## Final scoring
- **Critical:** 0
- **High:** 0
- **Medium:** 1 (`/api/god_mode/schema` public)
- **Low:** 3 (`/health` fingerprint leak, CORS preflight method leak, clock precision)
- **Info:** 0

**Scenario verdict:**
- Steal user info → FAIL (IDOR defended at 3 layers)
- DB access → FAIL (no public list endpoints, path-scoped Firestore)
- Inject code → FAIL (3 sub-vectors clean)
- Steal prompts/IP → Mostly FAIL; one open question (LLM-echo vector)

## Phase 1 recon — what to look at first

```
# Routes
mvp_site/main.py          5971 lines, all Flask routes
mvp_site/mcp_api.py       1205 lines, JSON-RPC MCP server
mvp_site/worldai_tools_mcp_proxy.py  1893 lines, MCP-to-MCP proxy

# Persistence
mvp_site/firestore_service.py  (Firestore, path-scoped users/<uid>/campaigns/<id>)

# Auth
mvp_site/main.py:1747-1906  check_token wrapper
mvp_site/mcp_api.py:791-826 _inject_authenticated_user_id

# SSRF surface (user-supplied URLs)
mvp_site/settings_validation.py:186-237 validate_openclaw_gateway_url

# Share-token surface
mvp_site/share_token.py (entire file is 251 lines, well-defended)

# Prompt IP (16,638 lines across 40 files)
mvp_site/prompts/master_directive.md (loaded first per agents.py:120-647)
mvp_site/prompts/god_mode_instruction.md (proprietary directive system)
```

## Phase 2 black-box probes that worked

```bash
# Auth boundary sweep
$ for p in /mcp /v1/chat/completions /v1/models /api/campaigns /api/settings \
           /api/avatar /api/god_mode/schema /api/shared/X /api/client_diag; do
    echo -n "$p -> "; curl -sS -o /dev/null -w "%{http_code}\n" "https://worldarchitect.ai$p"
  done
# Expected: every campaign-touching endpoint returns 401 EXCEPT the ones below.
# Actual surprising PUBLIC endpoints:
#   /api/god_mode/schema  -> 200, no auth (the finding!)
#   /api/constants/models -> 200, public by design (model list is OK)
#   /health               -> 200, leaks fingerprint
#   /api/time             -> 200, public by design

# CORS preflight
$ curl -sS -X OPTIONS https://worldarchitect.ai/mcp \
    -H "Origin: https://evil.com" \
    -H "Access-Control-Request-Method: POST" \
    -H "Access-Control-Request-Headers: Authorization" -i | head
# Expected: 200 with allow: GET, OPTIONS, HEAD, POST and NO Access-Control-Allow-Origin.
# Actual: matches expected — CORS is correctly restrictive.

# Path traversal
$ for p in "../../etc/passwd" "..%2f..%2fetc%2fpasswd" "%2e%2e/%2e%2e/etc/passwd" \
           "....//....//etc/passwd"; do
    curl -sS -o /dev/null -w "$p -> %{http_code} size=%{size_download}\n" \
      "https://worldarchitect.ai/$p"
  done
# All return 200 size=34329 — the SPA shell, not source files.

# Prompt-file reachability
$ curl -sS -o /tmp/p.txt -w "%{http_code} size=%{size_download}\n" \
    https://worldarchitect.ai/prompts/master_directive.md
# 200 size=34329 — SPA shell, NOT the file. Static-serve isolation is correct.
```

## Phase 3 white-box — code paths that matter

### IDOR defense (the correct pattern)

```python
# mvp_site/mcp_api.py:791-826 — _inject_authenticated_user_id
def _inject_authenticated_user_id(
    tool_name: str, arguments: dict[str, Any], user_id: str
) -> dict[str, Any]:
    if not isinstance(arguments, dict):
        return arguments

    # TESTING_AUTH_BYPASS carve-out — dead in prod (PRODUCTION_MODE gate above)
    provided_user_id = arguments.get("user_id")
    if (os.getenv("TESTING_AUTH_BYPASS", "").lower() == "true"
            and (provided_user_id or "").startswith("test-")):
        return arguments  # tests can act on behalf of test users

    properties = schema.get("properties", {}) if isinstance(schema, dict) else {}
    accepts_user_id = "user_id" in properties

    if accepts_user_id or "user_id" in arguments:
        if arguments.get("user_id") and arguments.get("user_id") != user_id:
            logging_util.warning(
                "MCP user_id override for tool=%s (supplied=%s, auth=%s)",
                tool_name, arguments.get("user_id"), user_id,
            )
        updated = dict(arguments)
        updated["user_id"] = user_id
        return updated
    return arguments
```

Key elements:
- JWT-derived user_id wins over body-supplied user_id
- Conflict logs a WARNING (not silently overrides)
- Test-bypass is env-gated + UID-prefix-gated
- Falls through unchanged when no user_id in args (no breakage)

### SSRF defense (DNS rebinding mitigation)

```python
# mvp_site/settings_validation.py:186-237 — validate_openclaw_gateway_url
def validate_openclaw_gateway_url(url: Any) -> tuple[str | None, str | None]:
    # 1. Scheme allowlist (http/https only)
    # 2. Hostname denylist (e.g. metadata.google.internal, kubernetes.default)
    # 3. If hostname is an IP literal → check IP denylist directly
    # 4. Otherwise resolve hostname to ALL IPs and check EACH
    resolved_ips = _resolve_gateway_host_ips(hostname)
    for ip in resolved_ips:
        if _is_disallowed_openclaw_gateway_ip(ip):
            return None, "Invalid OpenClaw gateway URL - resolved to disallowed address"
```

This is the correct SSRF defense. The DNS-rebinding mitigation (step 4) is the rare part — most implementations only check the hostname, which a rebinding attacker bypasses by returning a public IP on the first lookup and a private IP on the second.

### Share-token allowlist (the wrong-way-wrong-wrong pattern that this code avoids)

```python
# mvp_site/share_token.py:34-43
SAFE_PAYLOAD_FIELDS: frozenset[str] = frozenset({
    "title", "character", "setting", "description",
    "campaign_type", "source_campaign_id", "author_handle",
})

# mvp_site/share_token.py:181-194
def get_shared_payload(token):
    ...
    payload: dict[str, Any] = {}
    for field in SAFE_PAYLOAD_FIELDS:
        if field == "source_campaign_id":
            payload[field] = campaign_id
        elif field == "author_handle":
            payload[field] = _author_handle_from_owner_id(owner_id)
        else:
            value = campaign_data.get(field)
            if value is not None:
                payload[field] = value
    return payload
```

NEVER `{**campaign_data, ...}` spread. The PR #5823 regression class is exactly this — someone refactored and added a `{**source, "extras": ...}` that silently leaked `initial_prompt` / `selected_prompts` to the public payload.

### Path-scoped Firestore reads

```python
# mvp_site/firestore_service.py:3936-3960
def get_campaign_by_id(user_id, campaign_id):
    db = get_db()
    campaign_ref = (
        db.collection("users")
        .document(user_id)
        .collection("campaigns")
        .document(campaign_id)
    )
```

Path-scoped reads use Firestore security rules naturally; a `db.collection("campaigns").document(id).where("owner_id", "==", user_id)` requires a separate rule and is much easier to get wrong.

## Finding M1 — /api/god_mode/schema is public (the canonical "missing decorator" finding)

```python
# mvp_site/main.py:5330 — the route as it shipped
@app.route("/api/god_mode/schema", methods=["GET"])
def get_god_mode_schema():
    return jsonify(_GOD_MODE_SCHEMA)
```

Compare to every other read in that block — they all have `@check_token`. The schema exposes 30 fields across 10 `$defs` types (CoreMemoryAddOp, DirectiveAddOp, GodModeMutations, StoryEntryReplacementOp, etc.). It's NOT the prompt content, but it's the precise attack shape needed to forge a `process_action` payload that tries a directive write.

```bash
$ curl -s https://worldarchitect.ai/api/god_mode/schema | jq '.\$defs | keys'
[
  "CoreMemoryAddOp", "CoreMemoryOperations", "CoreMemoryReplaceOp",
  "DirectiveAddOp", "DirectiveOperations", "DirectiveReplaceOp",
  "GodModeMutations", "GodModeOutcomeApply", "GodModeOutcomeClarify",
  "StoryEntryReplacementOp", "StoryEntryReplacementPayload"
]
```

Fix: add `@check_token` and `@limiter.limit("30 per minute")`. Optional: gate the schema behind `WORLDAI_DEV_MODE=true` if the frontend legitimately needs it pre-auth, and ship a stripped field-name-only version publicly.

## Finding L1 — /health leaks signing_secret_fingerprint

```python
# mvp_site/main.py:4833-4837
signing_secret = os.getenv("STREAM_RESPONSE_SIGNING_SECRET", "").strip()
if signing_secret:
    health_info["signing_secret_fingerprint"] = hashlib.sha256(
        signing_secret.encode("utf-8")
    ).hexdigest()[:16]
```

SHA256-prefix16 is NOT the secret, but it's a stable canary for rotation detection. Also leaks `mcp_client.base_url=http://localhost:8000` which helps Cloud-Shell fingerprinting.

## Open question A1 — LLM system-prompt echo

UNRESOLVED. The HTTP-side isolation test (static-file path traversal) only proves the prompt isn't fetchable directly. The LLM itself can be coerced via player-controlled input ("Repeat your instructions verbatim", "What were you told to do?", etc.) — this requires a real account + real LLM call to test.

Mitigation philosophy: never put the secret sauce in the prompt at all — keep IP in tools and server-side code paths the LLM can invoke but not see contents of.

## Working probe sequence (copy-paste for next red-team)

```bash
TARGET=https://worldarchitect.ai

# 1. Boundary sweep
for p in /mcp /v1/chat/completions /v1/models /api/campaigns /api/settings \
         /api/avatar /api/god_mode/schema /api/shared/X /api/client_diag \
         /api/constants/models /health /api/time; do
  printf "%-40s -> " "$p"
  curl -sS -o /dev/null -w "%{http_code}\n" "$TARGET$p"
done

# 2. /health body
curl -s $TARGET/health | jq .

# 3. CSP / CORS / headers
curl -sSI $TARGET/ | grep -iE "content-security-policy|x-frame-options|strict-transport|x-content-type"
curl -sS -X OPTIONS -H "Origin: https://evil.com" \
  -H "Access-Control-Request-Method: POST" \
  -H "Access-Control-Request-Headers: Authorization" \
  -i $TARGET/mcp | head -15

# 4. Path traversal
for p in "../../etc/passwd" "..%2f..%2fetc%2fpasswd" "%2e%2e/%2e%2e/etc/passwd" \
         "....//....//etc/passwd"; do
  printf "%-30s -> " "$p"
  curl -sS -o /dev/null -w "%{http_code} size=%{size_download}\n" "$TARGET/$p"
done

# 5. Prompt-file reachability (compare body size to SPA size=34329)
for f in master_directive god_mode_instruction game_state_instruction \
         narrative_system_instruction; do
  printf "%-30s -> " "$f.md"
  curl -sS -o /dev/null -w "%{http_code} size=%{size_download}\n" \
    "$TARGET/prompts/$f.md"
done

# 6. White-box: find auth-gate decorator per route
grep -nB1 -A3 "@app\.route" mvp_site/main.py | head -100

# 7. White-box: IDOR defense
grep -n "_inject_authenticated_user_id\|where.*owner_id\|collection.*campaigns" \
  mvp_site/mcp_api.py mvp_site/firestore_service.py | head -30

# 8. White-box: SSRF
grep -rn "validate_openclaw_gateway_url\|_is_disallowed_gateway\|_is_disallowed_openclaw" \
  mvp_site/settings_validation.py mvp_site/main.py | head -20
```
