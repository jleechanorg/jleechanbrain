"""Capture Campaign Wizard Step 2 Summary preview at mobile (390x844 iPhone 14).

The dashboard recipe in this skill targets synthetic DOM injection. The
wizard /new-campaign flow does NOT need synthetic injection — the wizard
itself renders the summary card on Step 2 after clicking "Custom" + "Next".

Usage:
    python3 scripts/capture_wizard_step2_mobile.py \
        --base http://localhost:8082 \
        --out-dir evidence/pr-9367 \
        --label before

    # After applying the fix, restart the server (cache_busting rotates the
    # campaign-wizard.HASH.js filename) and re-run with --label after:
    python3 scripts/capture_wizard_step2_mobile.py \
        --base http://localhost:8082 \
        --out-dir evidence/pr-9367 \
        --label after

Output: two PNGs in --out-dir: {label}.png (full-page) and {label}_card.png
(tight crop of .campaign-preview only). The card screenshot is sharper
evidence for PR review.

Mobile viewport (390x844, is_mobile=True, dsf=2) is mandatory — the
desktop 1400x1100 viewport hides flex-collapse bugs.
"""
import argparse
import asyncio
from pathlib import Path

from playwright.async_api import async_playwright


async def capture(base: str, label: str, out_dir: str) -> dict:
    out_dir_path = Path(out_dir)
    out_dir_path.mkdir(parents=True, exist_ok=True)
    full_path = out_dir_path / f"{label}.png"
    card_path = out_dir_path / f"{label}_card.png"

    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True)
        ctx = await browser.new_context(
            viewport={"width": 390, "height": 844},
            device_scale_factor=2,
            is_mobile=True,
            has_touch=True,
            user_agent=(
                "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
                "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 "
                "Mobile/15E148 Safari/604.1"
            ),
        )
        page = await ctx.new_page()
        await page.goto(
            f"{base}/new-campaign?test_mode=true&test_user_id=summary_bug",
            wait_until="domcontentloaded",
            timeout=30000,
        )
        await page.wait_for_timeout(2500)

        # Pick Custom type — the bug only reproduces on the Custom wizard
        # (Dragon Knight has a different summary layout).
        await page.wait_for_selector('div.campaign-type-card[data-type="custom"]', timeout=10000)
        await page.click('div.campaign-type-card[data-type="custom"]')
        await page.wait_for_timeout(600)

        # Click Next EXACTLY ONCE — we want Step 2, not Step 3/Review.
        # The original wa-visual-proof-playwright recipe clicks Next in a
        # 3-iteration loop; that's wrong for Step-2-summary bugs.
        next_btn = page.locator("button:has-text('Next')").first
        await next_btn.wait_for(timeout=10000)
        await next_btn.click()
        await page.wait_for_timeout(1500)

        await page.wait_for_selector(".campaign-preview .preview-item", timeout=10000)
        await page.wait_for_timeout(800)

        # Full-page screenshot — context for the PR.
        await page.screenshot(path=str(full_path), full_page=True)

        # Card-only screenshot — sharper evidence for review.
        await page.locator(".campaign-preview").scroll_into_view_if_needed()
        await page.wait_for_timeout(300)
        await page.locator(".campaign-preview").screenshot(path=str(card_path))

        # Probe the DOM so we can verify the fix programmatically, not just visually.
        rows = await page.locator(".campaign-preview .preview-item").count()
        labels = []
        for i in range(rows):
            lbl = await page.locator(".campaign-preview .preview-item").nth(i).locator("strong").inner_text()
            labels.append(lbl)
        desc_container_count = await page.locator("#preview-description-container").count()
        # If the deleted row is still there, capture its width so the BEFORE
        # evidence can show the collapse quantitatively.
        desc_value_width = None
        try:
            desc_value_width = await page.locator("#preview-description").evaluate(
                "el => el.getBoundingClientRect().width"
            )
        except Exception:
            pass

        await browser.close()
        return {
            "rows": rows,
            "labels": labels,
            "desc_container_present": desc_container_count,
            "desc_value_width_px": desc_value_width,
            "full_png": str(full_path),
            "card_png": str(card_path),
        }


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default="http://localhost:8082")
    parser.add_argument("--out-dir", required=True)
    parser.add_argument("--label", required=True, choices=["before", "after"])
    args = parser.parse_args()
    info = await capture(args.base, args.label, args.out_dir)
    print(f"{args.label.upper()}:", info)


if __name__ == "__main__":
    asyncio.run(main())
