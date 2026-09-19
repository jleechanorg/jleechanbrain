#!/usr/bin/env python3
"""
testing_ui/test_my_campaigns_mobile_ux_regression.py

CI regression test + visual-evidence harness for mobile UX bugs on the
"My Campaigns" list. Copy this template, change the selectors + bug names
to match your page. Run locally:

    TESTING_AUTH_BYPASS=true python3 -m testing_ui.test_my_campaigns_mobile_ux_regression

For the originating case (PR #9178, 2026-08-20) this test was written to
reproduce three bugs reported via Android screenshot in
Slack C0AH3RY3DK6/p1787261209.775249:
  - BUG A: .duplicate-campaign-btn text truncated to "Du" (clientWidth=24, scrollWidth=77)
  - BUG B: "Last played" date clipped at right edge
  - BUG C: #theme-menu dropdown overflows past viewport right edge
"""

import json
import os
import sys
import time
from pathlib import Path

from playwright.sync_api import sync_playwright

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EVIDENCE_DIR = Path("/tmp/wa_my_campaigns_mobile_evidence")
EVIDENCE_DIR.mkdir(parents=True, exist_ok=True)

# iPhone 14 Pro: matches the user's Android screenshot ~393x852
IPHONE_VIEWPORT = {
    "viewport": {"width": 393, "height": 852},
    "screen": {"width": 393, "height": 852},
    "device_scale_factor": 3,
    "is_mobile": True,
    "has_touch": True,
    "user_agent": (
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
        "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 "
        "Mobile/15E148 Safari/604.1"
    ),
}


def render_synthetic_campaign_into_dom(page) -> None:
    """Lift the three CSS gates that hide #dashboard-view, then inject a
    campaign-list row that mirrors renderCampaignListUI() in
    mvp_site/frontend_v1/app.js:3006."""
    page.evaluate("""() => {
        document.body.classList.remove('is-logged-out');
        document.querySelectorAll('.active-view')
            .forEach(v => v.classList.remove('active-view'));
        const dash = document.getElementById('dashboard-view');
        if (dash) dash.classList.add('active-view');

        const list = document.getElementById('campaign-list') || document.body;
        const wrap = document.createElement('div');
        wrap.className = 'list-group-item';
        wrap.setAttribute('data-campaign-id', 'synthetic-1');
        wrap.innerHTML = `
          <div class="d-flex flex-column flex-sm-row w-100 justify-content-sm-between align-items-sm-center campaign-list-header">
            <h5 class="mb-2 mb-sm-0 text-break"><span class="campaign-title-text campaign-title-link">Dragon Knight</span></h5>
            <div class="d-flex align-items-center flex-shrink-0 campaign-list-actions mt-1 mt-sm-0">
              <button class="btn btn-sm btn-outline-primary edit-campaign-btn me-2" title="Edit campaign title">Edit</button>
              <button class="btn btn-sm btn-outline-secondary duplicate-campaign-btn me-2" title="Duplicate campaign">Duplicate</button>
              <small class="text-muted text-nowrap">Last played: 20/08/2026, 22:05:28</small>
            </div>
          </div>
          <p class="text-warning mb-0 mt-2">Character: Ser Arion | Setting: World of Assiah. Caught between an oath to a ruthless tyrant who enf...</p>
        `;
        list.appendChild(wrap);
    }""")


def assert_no_bug_a(page) -> dict:
    """BUG A: .duplicate-campaign-btn text is clipped inside its box."""
    info = page.evaluate("""() => {
        const btn = document.querySelector('.duplicate-campaign-btn');
        if (!btn) return {found: false};
        const r = btn.getBoundingClientRect();
        const cs = getComputedStyle(btn);
        return {
            found: true, text: btn.textContent.trim(),
            offsetWidth: btn.offsetWidth, scrollWidth: btn.scrollWidth,
            clientWidth: btn.clientWidth,
            rect: {x: r.x, y: r.y, w: r.width, h: r.height, right: r.right},
            overflow: cs.overflow, textOverflow: cs.textOverflow,
            whiteSpace: cs.whiteSpace, maxWidth: cs.maxWidth,
        };
    }""")
    if not info.get("found"):
        return {"bug_a": "skipped"}
    if info["scrollWidth"] > info["clientWidth"] + 1:
        return {"bug_a": "FAIL", "evidence": info}
    if info["rect"]["right"] > page.evaluate("() => window.innerWidth") + 1:
        return {"bug_a": "FAIL_RIGHT", "evidence": info}
    return {"bug_a": "PASS", "evidence": info}


def assert_no_bug_b(page) -> dict:
    """BUG B: 'Last played' <small> clipped or page has horizontal overflow."""
    info = page.evaluate("""() => {
        const last = document.querySelector('.campaign-list-actions small.text-muted.text-nowrap');
        if (!last) return {found: false};
        const r = last.getBoundingClientRect();
        const cs = getComputedStyle(last);
        const html = document.documentElement;
        return {
            found: true, text: last.textContent.trim(),
            offsetWidth: last.offsetWidth, scrollWidth: last.scrollWidth,
            clientWidth: last.clientWidth,
            rect: {x: r.x, y: r.y, w: r.width, h: r.height, right: r.right},
            whiteSpace: cs.whiteSpace, overflow: cs.overflow,
            docScrollWidth: html.scrollWidth,
        };
    }""")
    if not info.get("found"):
        return {"bug_b": "skipped"}
    vp_w = page.evaluate("() => window.innerWidth")
    if info["rect"]["right"] > vp_w + 1:
        return {"bug_b": "FAIL_RIGHT", "evidence": info, "viewport": vp_w}
    if info["scrollWidth"] > info["clientWidth"] + 1:
        return {"bug_b": "FAIL_CLIPPED", "evidence": info}
    if info["docScrollWidth"] > vp_w + 1:
        return {"bug_b": "FAIL_DOC_HSCROLL", "evidence": info, "viewport": vp_w}
    return {"bug_b": "PASS", "evidence": info, "viewport": vp_w}


def assert_no_bug_c(page) -> dict:
    """BUG C: #theme-menu dropdown overflows viewport (or page has hscroll)."""
    page.click('button[title="Choose theme"]', timeout=5000)
    page.wait_for_timeout(500)
    info = page.evaluate("""() => {
        const menu = document.getElementById('theme-menu');
        if (!menu) return {found: false};
        const r = menu.getBoundingClientRect();
        return {
            found: true,
            rect: {x: r.x, y: r.y, w: r.width, h: r.height, right: r.right},
            docScrollWidth: document.documentElement.scrollWidth,
        };
    }""")
    vp_w = page.evaluate("() => window.innerWidth")
    if not info.get("found"):
        return {"bug_c": "skipped"}
    r = info["rect"]
    if r["right"] > vp_w + 1 or r["x"] < -1:
        return {"bug_c": "FAIL", "evidence": info, "viewport": vp_w}
    if info["docScrollWidth"] > vp_w + 1:
        return {"bug_c": "FAIL_DOC_HSCROLL", "evidence": info, "viewport": vp_w}
    return {"bug_c": "PASS", "evidence": info, "viewport": vp_w}


def run_capture(base_url: str, scenario: str) -> dict:
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        ctx = browser.new_context(**IPHONE_VIEWPORT)
        page = ctx.new_page()
        page.goto(f"{base_url}/", wait_until="networkidle", timeout=60000)
        page.wait_for_timeout(800)
        render_synthetic_campaign_into_dom(page)
        page.wait_for_selector('.campaign-list-actions', state='attached', timeout=5000)
        page.wait_for_timeout(400)

        page.screenshot(path=str(EVIDENCE_DIR / f"{scenario}_01_initial.png"), full_page=False)
        a = assert_no_bug_a(page)
        b = assert_no_bug_b(page)
        page.evaluate("() => window.scrollTo(0, 0)")
        page.wait_for_timeout(200)
        c = assert_no_bug_c(page)
        page.screenshot(path=str(EVIDENCE_DIR / f"{scenario}_02_theme_open.png"), full_page=False)
        page.keyboard.press("Escape")
        page.wait_for_timeout(200)
        page.evaluate("() => document.querySelector('.list-group-item[data-campaign-id]')?.scrollIntoView({block:'center'})")
        page.wait_for_timeout(400)
        try:
            row = page.query_selector('.list-group-item[data-campaign-id]')
            if row:
                row.screenshot(path=str(EVIDENCE_DIR / f"{scenario}_03_row_zoom.png"))
        except Exception as e:
            print(f"[{scenario}] row zoom failed: {e}")
        browser.close()
        return {"scenario": scenario, "bug_a": a, "bug_b": b, "bug_c": c}


def main():
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default="http://127.0.0.1:8081")
    parser.add_argument("--out", default=str(EVIDENCE_DIR))
    args = parser.parse_args()

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    import urllib.request
    try:
        urllib.request.urlopen(args.base_url + "/", timeout=5)
    except Exception as e:
        print(f"FATAL: server at {args.base_url} not reachable: {e}", file=sys.stderr)
        sys.exit(2)

    print(f"=== Running regression at {args.base_url} (iPhone 14 Pro viewport) ===")
    result = run_capture(args.base_url, "RUN")
    print(json.dumps(result, indent=2, default=str))

    failures = [k for k in ("bug_a", "bug_b", "bug_c")
                if result.get(k, {}).get(k, "").startswith("FAIL")]
    if failures:
        print(f"\n*** BUGS REPRODUCED: {failures} ***", file=sys.stderr)
        sys.exit(1)
    print("\n*** ALL BUGS PASS ***")
    sys.exit(0)


if __name__ == "__main__":
    main()
