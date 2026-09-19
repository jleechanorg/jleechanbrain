#!/usr/bin/env python3
"""
verify_recipe.py — quick smoke check that the wa-mobile-ux-regression
recipe produces the expected Playwright context. Not a CI test — just a
3-line guard so a future agent editing this skill doesn't accidentally
break the viewport-dict contract.

Run from the skill directory:
    python3 scripts/verify_recipe.py

Pass: prints "ok" and exits 0.
Fail: prints the exact TypeError or assertion message and exits 1.
"""

import sys
from playwright.sync_api import sync_playwright

# This is the exact viewport-dict the recipe requires.
VIEWPORT = {
    "viewport": {"width": 393, "height": 852},
    "screen": {"width": 393, "height": 852},
    "device_scale_factor": 3,
    "is_mobile": True,
    "has_touch": True,
    "user_agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) Safari/604.1",
}


def main() -> int:
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        try:
            ctx = browser.new_context(**VIEWPORT)
            page = ctx.new_page()
            page.set_content("<div id='campaign-list'></div>")
            page.evaluate("""() => {
                document.body.classList.remove('is-logged-out');
            }""")
            inner = page.evaluate("() => window.innerWidth")
            assert inner == 393, f"expected 393, got {inner}"
            print("ok")
            return 0
        except Exception as e:
            print(f"FAIL: {type(e).__name__}: {e}", file=sys.stderr)
            return 1
        finally:
            browser.close()


if __name__ == "__main__":
    sys.exit(main())
