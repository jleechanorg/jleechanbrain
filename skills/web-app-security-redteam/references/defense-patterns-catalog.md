# Defense-patterns catalog

Class-level reference for `web-app-security-redteam` SKILL.md. Five patterns that recur across well-engineered apps. Each entry: pattern → minimal working code → failure-mode story → what to look for during a red-team.

These are the patterns to **call out by name** in the report's "What was tested and came back CLEAN" section when you find them. They give the user the same visibility into what they got RIGHT as the findings give them for what to fix.

---

## 1. Per-tool user_id override (MCP / RPC servers with per-user scoping)

**Pattern.** When a tool-call argument schema accepts `user_id`, the server MUST override any client-supplied value with the JWT-derived one and log the conflict.

**Minimal working code (Python, FastMCP-style):**

```python
def _inject_authenticated_user_id(
    tool_name: str,
    arguments: dict[str, Any],
    authenticated_user_id: str,
    schema: dict[str, Any],
) -> dict[str, Any]:
    if not isinstance(arguments, dict):
        return arguments
    properties = schema.get("properties", {}) if isinstance(schema, dict) else {}
    accepts_user_id = "user_id" in properties
    if not (accepts_user_id or "user_id" in arguments):
        return arguments  # schema doesn't take user_id; nothing to inject

    provided = arguments.get("user_id")
    if provided and provided != authenticated_user_id:
        # NEVER silently override — log the attempted impersonation
        logging_util.warning(
            "tool=%s user_id_override supplied=%s auth=%s",
            tool_name, provided, authenticated_user_id,
        )

    updated = dict(arguments)
    updated["user_id"] = authenticated_user_id
    return updated
```

**Failure-mode story (when the pattern is wrong).** Newer MCP-server code that blindly forwards `arguments["user_id"]` to the tool's implementation. An authenticated user can then call `tools/call get_campaign_state '{"user_id": "<victim>", "campaign_id": "X"}'` and read another user's campaign. This is a one-line IDOR — Trivially exploitable as soon as the attacker has any valid auth token.

**What to look for during a red-team.** Read every tool schema; for any tool that takes `user_id`, trace the dispatch path: does it run the override? Does it log on conflict? Or does the tool implementation just `arguments.get("user_id")` and trust it?

---

## 2. SSRF defense with DNS rebinding mitigation

**Pattern.** When validating a user-supplied URL that will be fetched server-side, three things must hold:
1. Scheme allowlist (typically `http`/`https` only)
2. Hostname/IP denylist (loopback `127.0.0.0/8`, link-local `169.254.0.0/16` INCLUDING `169.254.169.254` for cloud metadata, RFC1918 `10/8` `172.16/12` `192.168/16`, multicast, `0.0.0.0`, `::`, `fc00::/7` for IPv6 ULA)
3. **DNS rebinding mitigation:** resolve the hostname to ALL IPs and deny if ANY is in the denylist — checking only the parsed hostname is insufficient because DNS rebinding returns a public IP first, then a private IP on the second lookup

**Minimal working code (Python, `ipaddress` stdlib):**

```python
from ipaddress import ip_address
from urllib.parse import urlsplit

LOOPBACK = {ip_network("127.0.0.0/8"), ip_network("::1/128")}
PRIVATE = {ip_network("10.0.0.0/8"), ip_network("172.16.0.0/12"),
           ip_network("192.168.0.0/16"), ip_network("169.254.0.0/16"),
           ip_network("fc00::/7")}
DENY = LOOPBACK | PRIVATE

def is_bad_ip(ip: IPv4Address | IPv6Address) -> bool:
    return any(ip in net for net in DENY)

def validate_user_supplied_url(url: str) -> tuple[bool, str]:
    parsed = urlsplit(url)
    if parsed.scheme not in ("http", "https"):
        return False, "scheme"
    host = parsed.hostname
    if not host:
        return False, "no host"
    try:
        ip = ip_address(host)  # literal IP
        if is_bad_ip(ip):
            return False, "ip denied"
    except ValueError:
        # Hostname — resolve to ALL IPs
        try:
            infos = socket.getaddrinfo(host, None)
        except socket.gaierror:
            return False, "no resolve"
        for info in infos:
            try:
                if is_bad_ip(ip_address(info[4][0])):
                    return False, "resolved ip denied"
            except ValueError:
                continue
    return True, ""
```

**Failure-mode story (when the pattern is wrong).** A naive check like `if host in ("localhost", "127.0.0.1", "metadata.google.internal"): deny` misses DNS rebinding AND any RFC1918 IP literal. The 2019 Capital One breach was this pattern failing for `http://169.254.169.254/latest/meta-data/iam/security-credentials/`.

**What to look for during a red-team.** Find any `requests.get(user_url)` / `urllib.request.urlopen(user_url)` / `fetch(user_url)` whose URL comes from request body, settings, or env. Trace the validation path. If the validation only checks the hostname string (not the resolved IP), it's DNS-rebinding-vulnerable.

---

## 3. Share-token explicit allowlist

**Pattern.** Public-facing payloads (campaign shares, public reports, shareable links) must use an explicit field allowlist, NEVER `{**source_dict, "extras": ...}` spread.

**Minimal working code (Python):**

```python
from typing import Any
import secrets

SAFE_PAYLOAD_FIELDS: frozenset[str] = frozenset({
    "title", "character", "setting", "description",
    "campaign_type", "source_id", "author_handle",
})

# Belt + suspenders — fields that are FORBIDDEN even if source has them
FORBIDDEN_FIELDS: frozenset[str] = frozenset({
    "initial_prompt", "system_prompt", "owner_email",
    "user_id", "private_notes", "internal_flags",
})

def build_public_payload(source: dict[str, Any]) -> dict[str, Any]:
    payload: dict[str, Any] = {}
    for field in SAFE_PAYLOAD_FIELDS:
        value = source.get(field)
        if value is not None:
            payload[field] = value
    # Defense in depth — strip forbidden even if somehow present
    for forbidden in FORBIDDEN_FIELDS:
        payload.pop(forbidden, None)
    return payload

def mint_share_token() -> str:
    # 32 bytes → 256 bits of entropy. Not brute-forceable.
    return secrets.token_urlsafe(32)
```

**Failure-mode story (when the pattern is wrong).** PR #5823-style regression: someone refactors `build_public_payload` to `{**source, "share_url": f"https://app.com/s/{token}"}` because they wanted to add a field to the public response, but the spread silently leaks `initial_prompt` (the player's campaign-prompt — proprietary IP) and `owner_email` (PII). The leak persists until somebody reports it or it shows up in the access logs.

**What to look for during a red-team.** Find any share/public/render endpoint that returns user content. Read the response-building code. If you see `{**source, ...}` or `payload.update(source)` or anything that copies keys without enumeration, that's a spread leak waiting to happen. Confirm by enumerating an actual public payload — if the response has fields you didn't expect (especially anything `*_prompt`, `*_email`, `*_id`, `*_token`), that's the leak.

---

## 4. HTML-escape + tight CSP on user-content landing pages

**Pattern.** When a public endpoint renders user-provided content into HTML, escape via `markupsafe.escape` (or equivalent) AND set a tight CSP `script-src 'none'`.

**Minimal working code (Flask):**

```python
from markupsafe import escape
from flask import Response

@app.route("/shared/<token>")
def share_landing(token: str):
    payload = get_shared_payload(token)
    if payload is None:
        return Response("<h1>Not found</h1>", status=404)

    title = escape(payload.get("title") or "")
    setting = escape(payload.get("setting") or "")
    description = escape(payload.get("description") or "")

    # Tight CSP — even if a value bypasses escape, no JS can run
    csp = "default-src 'self'; script-src 'none'; style-src 'self' 'unsafe-inline'"
    html = (
        "<!doctype html><html><head>"
        f'<meta http-equiv="Content-Security-Policy" content="{csp}">'
        f"<title>{title}</title>"
        "</head><body>"
        f"<h1>{title}</h1>"
        f"<div class='setting'>{setting}</div>"
        f"<p>{description}</p>"
        "</body></html>"
    )
    return Response(html, mimetype="text/html")
```

**Failure-mode story (when the pattern is wrong).** A campaign title contains `<img src=x onerror=alert(document.cookie)>`. The page uses `{{ title }}` in a templating engine that double-escapes by default but the developer wrote `{{ title|safe }}` because they wanted to allow basic HTML in descriptions. Now XSS in a public share landing page.

**What to look for during a red-team.** For every public share/render endpoint:
1. Read the response-building code. Confirm every user value goes through `markupsafe.escape` / `e()` / equivalent.
2. Check the CSP response header (`script-src 'none'` is the tightest acceptable for a pure-HTML page; `script-src 'self'` if you need your own JS).
3. Test: submit a campaign with title `<script>alert(1)</script>` and visit the public share. If the alert fires, that's an XSS.

---

## 5. Path-scoped reads in document databases

**Pattern.** Firestore / MongoDB / DynamoDB queries should include the user's identity in the document PATH, not in a WHERE clause on a flat collection.

**Minimal working code (Firestore):**

```python
# GOOD — path-scoped
def get_campaign(user_id: str, campaign_id: str):
    db = firestore.Client()
    ref = (db.collection("users")
             .document(user_id)
             .collection("campaigns")
             .document(campaign_id))
    return ref.get().to_dict()

# BAD — collection-scan + WHERE (requires a security rule to enforce)
def get_campaign_BAD(user_id: str, campaign_id: str):
    db = firestore.Client()
    docs = (db.collection("campaigns")
              .document(campaign_id)
              .collection("_metadata")
              .where("owner_id", "==", user_id)  # developer can forget this
              .get())
```

**Why path-scoping wins.**
- Path-scoping uses the document database's built-in security rules (`request.auth.uid` can match the path component).
- Collection-scan + WHERE requires the developer to remember the WHERE every time. One missed WHERE on a new endpoint is a full data leak.
- Path-scoping has better cache locality.

**Failure-mode story (when the pattern is wrong).** A new endpoint is added that fetches campaign metadata. Developer copies the existing query, forgets the WHERE clause. The endpoint is `/api/admin/campaign-stats/<campaign_id>` — meant to be admin-only — but the admin auth check is misconfigured. Anyone who knows a campaign_id can read its metadata.

**What to look for during a red-team.** For every collection read/write, check whether the query path includes the authenticated user's identity. If you see `db.collection("X").document(id).where("user_id", "==", user_id)`, that's the weaker pattern — check the security rules and the rest of the codebase for similar reads that might have forgotten the WHERE.

---

## Bonus pattern: rate limiting on auth + token-mint endpoints

Not directly found in this audit, but worth mentioning because it's the missing piece in many real-world red-teams:

```python
# Flask-Limiter example
limiter = Limiter(get_remote_address, app=app, default_limits=["100 per hour"])

@app.route("/api/auth/login", methods=["POST"])
@limiter.limit("10 per minute; 100 per hour")
def login(): ...

@app.route("/api/share/create", methods=["POST"])
@limiter.limit("20 per hour")
def create_share(): ...
```

Anything that returns a token (auth, share, reset-password, magic-link) MUST have a per-IP rate limit. The pattern is standard but commonly missed.

---

## How to use this catalog in a red-team report

After you finish Phase 3 (white-box review), grep each pattern. If you find it:
- Note the file:line where it's implemented
- Note the version date / commit SHA if available (so you can detect regressions later)
- Include it in the "What was tested and came back CLEAN" section with a one-line callout

If you find it missing on a feature that NEEDS it:
- Note the file:line where the feature is implemented without the pattern
- Mention it as a finding in the appropriate severity bucket
- Cross-reference the pattern's failure-mode story as the "why it matters"

If you find a half-implementation (e.g. SSRF defense without DNS rebinding mitigation):
- That's a finding, not a "clean" — flag it as Medium severity
- Cross-reference the pattern's "what to look for" entry as the test
