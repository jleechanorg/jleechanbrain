---
name: headless-browser-qa-fallback
description: "Playwright Python QA when browser tools are blocked."
version: 1.0.0
platforms: [linux, macos, windows]
metadata:
  hermes:
    tags: [qa, browser, playwright, fallback, dogfood]
    related_skills: [dogfood, web-page-screenshots, test-realistic]
  author: Hermes Agent
  license: MIT
---

# Headless Browser QA Fallback

When the user's first instinct is "run /test-realistic" or "run /dogfood" but the project isn't onboarded (missing `.test-realistic.toml`, missing skill config, missing dispatch_command) — OR when the `browser_*` toolset is blocked by Chrome's "Allow remote debugging?" permission popup — fall back to **Playwright Python** directly. This skill documents that fallback and the worked patterns from real sessions.

This skill is intentionally **NOT** a replacement for `dogfood` or `test-realistic`. It's a fallback layer for the common cases where neither of those can run end-to-end without setup.

## When to use this

1. **User asks for a project-bootstrap skill** (`/test-realistic`, `/web-advice` for a new project, etc.) **and the project isn't onboarded** — quick check at the repo root for `.test-realistic.toml` (or equivalent). If missing, do NOT try to bootstrap inline. Default to running this skill's Playwright pattern + report findings as real PRs.
2. **`browser_navigate` is blocked** by Chrome's remote-debugging permission prompt (the "Allow remote debugging? — click Allow in Chrome" popup). Don't wait for the user.
3. **`playwright screenshot` CLI is too limited** for what you actually need (no console capture, no clicks, no form fills). Use Playwright Python instead.

## Why Playwright Python over the `playwright` CLI

| Need | `playwright screenshot` CLI | Playwright Python |
|------|------------------------------|-------------------|
| Static screenshot | ✅ | ✅ |
| Click / fill / submit | ❌ | ✅ |
| Per-route console error capture | ❌ | ✅ |
| Route enumeration via DOM eval | ❌ | ✅ |
| Multi-context (desktop + mobile) | ❌ | ✅ |
| Backend HTTP probes (POST/HEAD) | ❌ | ✅ |
| Runs without permission popup | ✅ | ✅ |

## Pre-flight (always, ~30s total)

1. **Confirm project identity** — `gh repo view <owner>/<repo> --json nameWithOwner`.
2. **Check for project config** — `find . -maxdepth 2 -name ".test-realistic.toml"` (or equivalent). If absent, mention briefly and proceed with this fallback.
3. **Set up a clean worktree from `origin/main`** — `git worktree add -b feat/qa-<topic>-<ts> /tmp/<repo>-qa origin/main`. All PR fixes land here.
4. **Identify the canonical dev URL** — check `docs/deployment-urls.md` (most repos have one). Don't guess.

## Worked Python template (verified 2026-08-20, jleechanorg/ai_universe_frontend → PR #470)

```python
"""Headless browser QA. Captures screenshots + per-route console errors,
enumerates interactive elements, tests forms, probes HTTP, runs mobile viewport."""
from playwright.sync_api import sync_playwright
import json, time, urllib.request, urllib.error
from pathlib import Path

URL = "https://target.example.com/"
OUT = Path("/tmp/dogfood-output")
SHOTS = OUT / "screenshots"
SHOTS.mkdir(parents=True, exist_ok=True)

findings = []
console_errors = []

def capture(page, name):
    path = SHOTS / f"{name}.png"
    page.screenshot(path=str(path), full_page=True)
    return path

def log(severity, category, url, title, repro, expected, actual, screenshot=None):
    findings.append({
        "severity": severity, "category": category, "url": url,
        "title": title, "repro": repro, "expected": expected,
        "actual": actual, "screenshot": str(screenshot) if screenshot else None,
    })

with sync_playwright() as p:
    browser = p.chromium.launch(headless=True)
    ctx = browser.new_context(viewport={"width": 1440, "height": 900})

    def on_console(msg):
        if msg.type in ("error", "warning"):
            console_errors.append({"type": msg.type, "text": msg.text})
    def on_pageerror(err):
        console_errors.append({"type": "pageerror", "text": str(err)})

    page = ctx.new_page()
    page.on("console", on_console)
    page.on("pageerror", on_pageerror)

    # HOME
    console_errors.clear()
    page.goto(URL, wait_until="domcontentloaded", timeout=30000)
    time.sleep(3)  # SPA hydrate
    capture(page, "01-home-initial")

    # Sitemap extraction
    links = page.eval_on_selector_all("a[href]",
        "els => els.map(e => ({text: e.innerText.trim(), href: e.href, visible: e.offsetParent !== null}))")
    forms = page.eval_on_selector_all("form", "els => els.length")  # NOTE: returns int
    inputs = page.eval_on_selector_all("input,textarea,select",
        "els => els.map(e => ({tag: e.tagName, type: e.type, name: e.name, placeholder: e.placeholder, visible: e.offsetParent !== null}))")

    # Route enumeration
    for route in ["/about", "/features", "/pricing", "/login", "/signup",
                  "/dashboard", "/chat", "/contact", "/settings", "/admin"]:
        console_errors.clear()
        try:
            page.goto(URL.rstrip("/") + route, wait_until="domcontentloaded", timeout=15000)
            time.sleep(2)
            capture(page, f"route-{route.strip('/').replace('/', '_') or 'root'}")
            if console_errors:
                for e in console_errors[:5]:
                    print(f"  [{e['type']}] {e['text'][:200]}")
        except Exception as e:
            print(f"  {route} err: {e}")

    # Backend probe
    try:
        req = urllib.request.Request(URL.rstrip("/") + "/api/contact",
            data=json.dumps({"name": "Test", "email": "test@example.com", "message": "Test"}).encode(),
            headers={"Content-Type": "application/json"})
        resp = urllib.request.urlopen(req, timeout=15)
        print(f"  /api/contact POST: {resp.status} {resp.read()[:200]!r}")
    except urllib.error.HTTPError as e:
        body = e.read()[:200]
        if e.code >= 500:
            log("CRITICAL", "Functional", URL, "/api/contact 5xx",
                "POST /api/contact", "2xx", f"HTTP {e.code}: {body!r}")

    # HTTP HEAD check
    resp = page.request.get(URL)
    for h in ["content-security-policy", "x-frame-options", "x-content-type-options",
              "strict-transport-security", "referrer-policy"]:
        v = resp.headers.get(h)
        if not v:
            log("HIGH", "Security", URL, f"Missing header: {h}",
                f"GET {URL}", f"{h} present", "MISSING")
    for path in ["/robots.txt", "/sitemap.xml", "/favicon.ico", "/.well-known/security.txt"]:
        r = page.request.get(URL.rstrip("/") + path)
        if r.status == 404:
            log("MEDIUM", "SEO" if "robots" in path or "sitemap" in path else "UX",
                URL + path, f"{path} returns 404",
                f"GET {URL}{path}", "200", f"{r.status}")

    # Mobile viewport
    mobile_ctx = browser.new_context(viewport={"width": 375, "height": 812})
    mpage = mobile_ctx.new_page()
    console_errors.clear()
    mpage.goto(URL, wait_until="domcontentloaded", timeout=30000)
    time.sleep(3)
    mpage.screenshot(path=str(SHOTS / "mobile-home.png"), full_page=True)
    scroll_w = mpage.evaluate("document.documentElement.scrollWidth")
    client_w = mpage.evaluate("document.documentElement.clientWidth")
    if scroll_w > client_w + 5:
        log("HIGH", "Visual", URL, "Mobile horizontal overflow",
            "Open on 375x812", "No horizontal overflow",
            f"scrollWidth={scroll_w} > clientWidth={client_w}")
    mobile_ctx.close()
    browser.close()

(OUT / "findings.jsonl").write_text("\n".join(json.dumps(f) for f in findings))
print(f"Wrote {len(findings)} findings")
```

## What to look for (canonical 6-finding pattern, 2026-08-20)

1. **WOFF2 corruption** — `Failed to decode downloaded font` + `OTS parsing error` console warnings. Verify with `file <f>`: declared length in WOFF2 header must match actual byte size. If `actual > declared`, binary was UTF-8-decoded and re-encoded (look for `0xef 0xbf 0xbd` U+FFFD bytes). Fix: replace with Google Fonts CDN URLs.
2. **Missing `/robots.txt`, `/sitemap.xml`, `/favicon.ico`** — SEO + tab-icon hygiene, almost universally 404 on real sites.
3. **Missing security headers** — HSTS, X-Frame-Options. **BUT** some projects explicitly omit HSTS/COOP for OAuth compatibility — read `server.cjs` / `nginx.conf` for explicit comments before flagging.
4. **Mobile horizontal overflow** — `document.documentElement.scrollWidth > clientWidth` at 375x812.
5. **Routes that silently render the SPA shell** — `/about`, `/pricing`, etc. returning the same body as `/`. Design choice, not strictly a bug.
6. **Visual confirmation via `vision_analyze`** — load each diagnostic PNG into context and describe what you actually see. Screenshot-only confirmation isn't enough.

## Pitfalls (verified 2026-08-20)

- `eval_on_selector_all("form", "els => els.length")` returns an `int`, not a list. Calling `len()` on it raises `TypeError`.
- `page.request.get()` exists on the `page` object for direct HTTP probes without rendering.
- Wait 2-3s after `domcontentloaded` for SPA hydration.
- `console_errors` persists across navigations by default — call `console_errors.clear()` after each `page.goto` to scope findings per route.
- `full_page=True` screenshots can be 4000+px tall (e.g. `/consulting` was 4249px). Disk fine; PNG takes longer.

## Output

Write the report to `{output_dir}/report.md` using the format from the `dogfood` skill template. Include:
- Executive summary table (severity → count)
- Per-issue sections (severity, category, URL, repro, expected, actual, screenshot, console errors)
- Issues summary table
- Testing coverage (pages tested, features exercised, not tested, blockers)

Then open **one PR per fixable bug** on the project's repo, branched from `origin/main`, with:
- Title: `fix(<area>): <short description>`
- Body: embed screenshots via `MEDIA:/tmp/dogfood-output/screenshots/<file>.png` after committing the PNG into the branch's `evidence/` directory and referencing it via GitHub raw URL per the `evidence-attach-not-path-cite` rule
- Verification: paste the curl/file/console output that proves the bug exists AND that the fix resolves it

## What's NOT in this skill (delegated)

- Cross-browser / cross-engine testing — Playwright defaults to Chromium; add firefox/webkit contexts if needed.
- Authentication flows — `context.add_cookies()` + `context.add_init_script()`; out of scope.
- Performance budgets — Lighthouse via Playwright is a separate concern.
- Visual regression — `pixelmatch` or similar; out of scope.

## See also

- `dogfood` — full project onboarding + report template (bundled; out of curator scope for patches)
- `web-page-screenshots` — static `playwright screenshot` CLI fallback (user-owned; run `hermes curator adopt` to enable patches)
- `test-realistic` — generalized realistic-user-testing pipeline (project-bootstrap, needs `.test-realistic.toml`)
- `inline-attach-evidence` — embed screenshots in PR descriptions via GitHub raw URL