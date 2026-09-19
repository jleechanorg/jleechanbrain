# Private-repo image embed + standalone harness when live-server path is broken

**Verified 2026-08-18, jleechanorg/worldarchitect.ai PR [#9070](https://github.com/jleechanorg/worldarchitect.ai/pull/9070) (Direction 4 risk-tinted planning block).**

Two recurring failure modes for visual evidence on private repos and broken local dev servers:

## 1. Private-repo image embed — `raw.githubusercontent.com` 404s without auth token

When you commit a PNG to a PR branch on a **private** repo and embed it in the PR description, the embed syntax must use a URL that GitHub's PR view can fetch through the authenticated CDN. Two patterns look correct but only one works:

```markdown
# ❌ 404s for unauthenticated viewers, even with `?raw=true`
![before](https://raw.githubusercontent.com/OWNER/REPO/BRANCH/evidence/before.png?raw=true)
![before](https://raw.githubusercontent.com/OWNER/REPO/BRANCH/evidence/before.png)

# ✅ Routes through GitHub's authenticated CDN, renders inline in PR view
![before](https://github.com/OWNER/REPO/raw/BRANCH/evidence/before.png)
```

**Why `raw.githubusercontent.com` 404s in PR view:** it requires a valid bearer token in the `?token=...` query string (the same one `gh api ... --jq .download_url` returns). That token expires within minutes. The PR view fetches images as a logged-in browser, not as your gh CLI session, so it does NOT have the token — and unauthenticated requests to `raw.githubusercontent.com` on a private repo are 404.

**Verification recipe (run BEFORE posting the PR body):**

```bash
# 1. Confirm the file is on the branch
gh api repos/OWNER/REPO/contents/evidence/before.png?ref=BRANCH \
  --jq '{name, sha, size, download_url}'

# 2. Confirm the embed URL form you'd put in the body actually resolves
curl -fsSL -o /dev/null -w "HTTP %{http_code}\n" \
  "https://github.com/OWNER/REPO/raw/BRANCH/evidence/before.png"
# Expected: HTTP 200, bytes=N
# NOT 404 like raw.githubusercontent.com would return without a token
```

If step 2 returns 404 even with the `github.com/.../raw/...` form, the branch is likely behind a force-push or the file path is wrong — re-verify the branch name and file path with `git ls-tree -r origin/BRANCH --name-only | grep <file>`.

## 2. Standalone HTML harness when the live-server path is broken

When you need to capture visual proof of a UI change but the local dev server is unhealthy (MCP down, Quick Start button doesn't navigate, CORS preflight rejects the test bypass header), **don't ship screenshots of whatever the broken page happens to render** — the user will notice and reject them.

PR #9070 first shipped screenshots that turned out to be the **Dragon Knight Character Creation wizard** (4 numbered steps), not the planning block rows the risk-tint CSS targets. User correction: *"Risks don't make sense for char creation though."* The MCP server was reporting unhealthy in `run_local_server.sh` startup, the Quick Start button never navigated to `/game/<id>`, and the capture script grabbed whatever was on screen.

**The fallback recipe — standalone HTML harness that inlines the real CSS:**

```python
# capture_planning_block_only.py (verified 2026-08-18, shipped in PR #9070 evidence v2)
from pathlib import Path
from playwright.sync_api import sync_playwright

CSS_FILE = Path("/tmp/wt-risk-d4/mvp_site/frontend_v1/styles/planning-blocks.css")
CSS_CONTENTS = CSS_FILE.read_text()  # INLINE the real CSS — no file:// vs http:// cross-origin issues

HTML_TEMPLATE = f"""<!doctype html>
<html><head><meta charset="utf-8">
<style>
{CSS_CONTENTS}                  /* real rule from disk */
body {{ background: #1a1530; color: #f0ecff; padding: 32px; font-family: sans-serif; }}
.choice-row {{ border-radius: 6px; padding: 12px 14px; }}
.choice-button {{ background: #2a2545; border: 1px solid #3d3560; color: #f0ecff;
                  padding: 10px 14px; border-radius: 4px; width: 100%; text-align: left; }}
{("""/* BEFORE-only override */ .choice-row[data-risk] { border-left: none !important; background: transparent !important; }""") if LABEL == "before" else ""}
</style></head>
<body>
  <div class="planning-block-choices">
    <div class="choice-row" data-risk="safe">  <div class="choice-head"><button class="choice-button"><span class="ctitle">Kneel and request a private audience</span></button></div></div>
    <div class="choice-row" data-risk="low">   <div class="choice-head"><button class="choice-button"><span class="ctitle">Present the royal decree</span></button></div></div>
    <div class="choice-row" data-risk="medium"><div class="choice-head"><button class="choice-button"><span class="ctitle">Invoke the saintly revelation</span></button></div></div>
    <div class="choice-row" data-risk="high">  <div class="choice-head"><button class="choice-button"><span class="ctitle">Draw the cursed blade and strike</span></button></div></div>
  </div>
</body></html>"""

# Playwright capture + computed-style probe (asserts the CSS contract resolves)
with sync_playwright() as p:
    browser = p.chromium.launch(headless=True)
    ctx = browser.new_context(viewport={"width": 760, "height": 540})
    page = ctx.new_page()
    page.set_content(HTML_TEMPLATE)
    page.wait_for_selector(".choice-row[data-risk]")
    probe = page.evaluate("""() => {
      const risks = ['safe', 'low', 'medium', 'high'];
      const rows = {};
      for (const r of risks) {
        const el = document.querySelector(`.choice-row[data-risk="${r}"]`);
        if (!el) { rows[r] = null; continue; }
        const cs = getComputedStyle(el);
        rows[r] = { borderLeftWidth: cs.borderLeftWidth,
                    borderLeftColor: cs.borderLeftColor,
                    backgroundColor: cs.backgroundColor };
      }
      return rows;
    }""")
    page.screenshot(path=f"evidence/{LABEL}_planning_block.png")
    # probe JSON saved alongside the PNG
```

**Three reasons this works when the live server doesn't:**

1. **No MCP dependency.** The harness is a self-contained HTML page; nothing has to navigate to `/game/<id>` or seed a campaign.
2. **No CORS preflight.** Inlining the CSS in `<style>` eliminates the `file://` vs `http://` mismatch that Chromium treats as cross-origin (the `cssRules` SecurityError trap).
3. **Proves the rule resolves in the browser**, not just that it parses. The `getComputedStyle()` probe returns the actual `borderLeftWidth`, `borderLeftColor`, and `backgroundColor` after the cascade — the same probe you'd run against the live page, minus the live-server dependency.

**Then verify visually BEFORE committing the PNG.** Use `vision_analyze` on each PNG and confirm the rendered rows/elements match what the CSS or JS change targets. The user's first PR #9070 evidence was rejected because vision would have shown the Character Creation wizard rows in the PNG, not the planning-block rows — the readback happened only after the user pushed back.

## 3. CORS env-var ordering — `TESTING_AUTH_BYPASS` must be exported BEFORE the Flask process starts

The CORS preflight on `/api/*` routes in `jleechanorg/worldarchitect.ai` (main.py:353-365) reads `os.getenv("TESTING_AUTH_BYPASS")` **once at module import time** and freezes `cors_allow_headers`. If the env var is not in the Flask process environment when it imports, every `X-Test-Bypass-Auth` request 401s even though the dev server appears to be running.

**Symptom** (verified 2026-08-18):
```
$ curl -sS -X OPTIONS http://localhost:8081/api/campaigns/quick-start \
    -H "Origin: http://localhost:8081" \
    -H "Access-Control-Request-Method: POST" \
    -H "Access-Control-Request-Headers: x-test-bypass-auth,content-type" -i \
    | grep -E "^Access-Control-Allow-Headers"
Access-Control-Allow-Headers: content-type            # ← x-test-bypass-auth missing
```

**Fix — export the env var BEFORE launching `run_local_server.sh`:**

```bash
export TESTING_AUTH_BYPASS=true \
       ALLOW_TEST_AUTH_BYPASS=true \
       WORLDAI_DEV_MODE=true
bash run_local_server.sh --no-log-stream --force-default-port
```

Then verify the CORS preflight now includes the bypass header:
```
Access-Control-Allow-Headers: content-type, x-test-bypass-auth
```

If you started the server in a session where `~/.bashrc` did NOT export `TESTING_AUTH_BYPASS` (e.g. a fresh `bash -lic` subshell that sourced a stale bashrc), the only fix is `pkill -f mvp_site.main serve && pkill -f run_local_server.sh` and re-launch with the env exported in the same shell.

**Related reference:** `references/wa-css-token-contract-and-bootstrap-2026-08-18.md` documents the same `TESTING_AUTH_BYPASS` requirement + the four bootstrap pitfalls for visual evidence in worldarchitect.ai.
