#!/usr/bin/env python3
"""Probe a CSS layout/positioning claim instead of trusting a screenshot.

WHY THIS EXISTS
---------------
A screenshot is evidence of pixels, not of CSS behavior. For claims about *how* an
element behaves -- sticky, fixed, pinned, responsive-at-breakpoint -- a screenshot
can look identical whether the claim is true or false.

Canonical failure (2026-08-14, worldarchitect.ai PR #8915): a handoff claimed a
"390x844 responsive mobile viewport with sticky action bar" and shipped
`mobile_04_sticky_actionbar_viewport.png` as proof. The CSS had ZERO
`position: sticky` and ZERO `@media` queries. The screenshot had been captured
*after scrolling to the bottom*, where an ordinary static footer sits flush at the
fold and is pixel-indistinguishable from a sticky bar. The probe caught it at once:

    {"position": "static", "barTop": 2088, "viewportH": 844,
     "pageH": 2218, "pinnedInViewport": false}

`Begin Adventure` sat 2088px down a 2218px page -- invisible at first paint.

USAGE
-----
    python3 probe_layout_claim.py <url-or-file-path> [--selector .actions-bar]
                                 [--width 390] [--height 844]
                                 [--expect sticky|static]
                                 [--out /tmp/probe]

Exits non-zero when the claim fails, so it can gate a CI step or a report.

CHEAP PRE-CHECK -- run this BEFORE launching a browser at all:
    grep -c 'position: sticky' path/to/file.css   # 0 => claim is false, stop
    grep -c '@media'           path/to/file.css   # 0 => not responsive, stop
"""

import argparse
import asyncio
import json
import pathlib
import sys

from playwright.async_api import async_playwright

PROBE_JS = """(sel) => {
    const el = document.querySelector(sel);
    if (!el) return {missing: true};
    const cs = getComputedStyle(el);
    const r = el.getBoundingClientRect();
    return {
        position: cs.position,
        bottom: cs.bottom,
        zIndex: cs.zIndex,
        display: cs.display,
        visibility: cs.visibility,
        opacity: cs.opacity,
        elTop: Math.round(r.top),
        elBottom: Math.round(r.bottom),
        viewportH: window.innerHeight,
        viewportW: window.innerWidth,
        pageH: document.documentElement.scrollHeight,
        pinnedInViewport: r.top < window.innerHeight && r.bottom > 0,
        flushToFold: Math.abs(r.bottom - window.innerHeight) <= 2,
    };
}"""


def resolve(target: str) -> str:
    if target.startswith(("http://", "https://", "file://")):
        return target
    return pathlib.Path(target).resolve().as_uri()


async def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("target", help="URL or local file path")
    ap.add_argument("--selector", default=".actions-bar")
    ap.add_argument("--width", type=int, default=390)
    ap.add_argument("--height", type=int, default=844)
    ap.add_argument("--expect", choices=["sticky", "static"], default="sticky")
    ap.add_argument("--out", default="/tmp/probe_layout")
    args = ap.parse_args()

    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    url = resolve(args.target)
    report = {"target": url, "selector": args.selector,
              "viewport": f"{args.width}x{args.height}", "expect": args.expect}

    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True)
        page = await browser.new_page(
            viewport={"width": args.width, "height": args.height},
            device_scale_factor=2,
        )
        await page.goto(url, wait_until="networkidle")
        await page.wait_for_timeout(500)

        # Scroll-top: the honest test. A static footer is NOT visible here.
        report["at_top"] = await page.evaluate(PROBE_JS, args.selector)
        await page.screenshot(path=str(out / "probe_top.png"), full_page=False)

        # Mid-scroll: a sticky bar stays pinned; a static one drifts.
        await page.evaluate("window.scrollTo(0, document.documentElement.scrollHeight/2)")
        await page.wait_for_timeout(300)
        report["at_midscroll"] = await page.evaluate(PROBE_JS, args.selector)
        await page.screenshot(path=str(out / "probe_midscroll.png"), full_page=False)

        # Scroll-bottom: THE TRAP. static and sticky look identical here.
        await page.evaluate("window.scrollTo(0, document.documentElement.scrollHeight)")
        await page.wait_for_timeout(300)
        report["at_bottom"] = await page.evaluate(PROBE_JS, args.selector)
        await page.screenshot(path=str(out / "probe_bottom.png"), full_page=False)

        # Full page: never let the payoff element fall outside the evidence.
        await page.screenshot(path=str(out / "probe_fullpage.png"), full_page=True)
        await browser.close()

    top, mid = report["at_top"], report["at_midscroll"]
    if top.get("missing"):
        report["verdict"] = "FAIL: selector not found"
        print(json.dumps(report, indent=2))
        return 2

    if args.expect == "sticky":
        ok = (
            top["position"] in ("sticky", "fixed")
            and top["pinnedInViewport"]
            and mid["pinnedInViewport"]
            and mid["flushToFold"]
        )
        report["verdict"] = "PASS: sticky" if ok else "FAIL: claimed sticky, is not"
        if not ok:
            report["why"] = {
                "computed_position": top["position"],
                "visible_at_scroll_top": top["pinnedInViewport"],
                "pinned_midscroll": mid["pinnedInViewport"],
                "scroll_depth_to_reach_px": top["elTop"],
                "page_height_px": top["pageH"],
            }
    else:
        ok = top["position"] == "static"
        report["verdict"] = "PASS: static" if ok else f"FAIL: expected static, got {top['position']}"

    print(json.dumps(report, indent=2))
    print(f"\nscreenshots: {out}/probe_{{top,midscroll,bottom,fullpage}}.png")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
