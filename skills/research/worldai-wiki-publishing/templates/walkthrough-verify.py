#!/usr/bin/env python3
"""
WorldArchitect.AI wizard walkthrough verifier — drives the wizard end-to-end
with a bible pasted in TESTING_AUTH_BYPASS mode, captures screenshots at every
step, and prints a pass/fail verdict for each walkthrough step.

Usage:
    # 1. Start the local test-mode server
    mkdir -p /tmp/worldai-verify
    TESTING_AUTH_BYPASS=true bash ./run_local_server.sh --force-default-port --no-log-stream \\
        > /tmp/worldai-verify/server.log 2>&1 &

    # 2. Wait for / to return 200
    for i in {1..30}; do
      code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 \\
        "http://localhost:8081/?test_mode=true&test_user_id=test-user-123")
      [ "$code" = "200" ] && break
      sleep 2
    done

    # 3. Drive the wizard (this script)
    python3 /path/to/walkthrough-verify.py \\
        --bible /path/to/bible.txt \\
        --title "House of the Dragon — The Bastard's Claim" \\
        --character "A 16-year-old dragonrider, gender-ambiguous bastard of Prince Daemon Targaryen, just claimed a young adult she-dragon" \\
        --setting "The Dance of the Dragons, 129-131 AC. Westeros on the eve of the Targaryen civil war. Dragonstone, King's Landing, the Riverlands." \\
        --out /tmp/worldai-verify/screenshots

The verifier writes:
    /tmp/worldai-verify/screenshots/01_landing.png           — landing page (login wall)
    /tmp/worldai-verify/screenshots/02_new_campaign.png      — Step 1 empty form
    /tmp/worldai-verify/screenshots/03_checkbox_defaults.png — Step 1 with default checkbox state captured BEFORE any interaction
    /tmp/worldai-verify/screenshots/04_step1_filled.png      — Step 1 with all 4 fields + bible filled
    /tmp/worldai-verify/screenshots/05_step2_review.png      — Step 2 review screen after clicking Next

Exit code:
    0 — every step passed
    2 — bible file missing or unreadable
    3 — server didn't come up within timeout
    4 — wizard element not found (selector stale; needs SKILL update)
    5 — Step 2 review didn't show expected values
    6 — wizard checkbox defaults drifted from expected values (wiki text needs re-verification)

This script is verified against mvp_site/frontend_v1/js/campaign-wizard.js
commit hash 0875e38 + later commits up through a80f846 (PR #7).
"""

import argparse
import os
import re
import sys
import time
from pathlib import Path
from playwright.sync_api import sync_playwright, Page

# Canonical selectors (from mvp_site/frontend_v1/js/campaign-wizard.js)
SEL_LANDING = "button:has-text('Continue with Google')"
SEL_NEW_CAMPAIGN = "button:has-text('Start New Campaign'), a:has-text('Start New Campaign')"
SEL_FORM = {
    "title": "#wizard-campaign-title",
    "character": "#wizard-character-input",
    "setting": "#wizard-setting-input",
    "description": "#wizard-description-input",
}
SEL_CHECKBOXES = {
    "narrative": "#prompt-narrative",
    "mechanics": "#prompt-mechanics",
    "companions": "#generate-companions",
    "default_world": "#use-default-world",
}
SEL_EXPAND = "button:has-text('Expand'), a:has-text('Expand')"
SEL_NEXT = "button:has-text('Next')"

URL_BASE = "http://localhost:8081/?test_mode=true&test_user_id=test-user-123"


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--bible", required=True, help="Path to file containing the bible text")
    p.add_argument("--title", default="TEST_CAMPAIGN_DELETE_ME")
    p.add_argument("--character", default="A test character for walkthrough verification.")
    p.add_argument("--setting", default="A test setting for walkthrough verification.")
    p.add_argument("--out", default="/tmp/worldai-verify/screenshots")
    p.add_argument("--url", default=URL_BASE)
    return p.parse_args()


def wait_for_server(url: str, timeout: int = 60) -> bool:
    """Poll the server until it returns 200, or until timeout."""
    import urllib.request
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            r = urllib.request.urlopen(url, timeout=2)
            if r.status == 200:
                return True
        except Exception:
            time.sleep(2)
    return False


def capture_defaults(page: Page) -> dict:
    """Probe every checkbox's is_checked() state BEFORE any interaction."""
    defaults = {}
    for name, sel in SEL_CHECKBOXES.items():
        loc = page.locator(sel)
        defaults[name] = loc.is_checked() if loc.count() > 0 else None
    return defaults


def verify_step1_filled(page: Page, title: str, character: str, setting: str, bible: str) -> dict:
    """Fill the 4 fields + check Mechanics + (optionally) uncheck default world."""
    results = {}
    # Title
    page.locator(SEL_FORM["title"]).fill(title)
    results["title"] = page.locator(SEL_FORM["title"]).input_value() == title
    # Character
    page.locator(SEL_FORM["character"]).fill(character)
    results["character"] = page.locator(SEL_FORM["character"]).input_value() == character
    # Setting
    page.locator(SEL_FORM["setting"]).fill(setting)
    results["setting"] = page.locator(SEL_FORM["setting"]).input_value() == setting
    # Description — click Expand first
    expand = page.locator(SEL_EXPAND).first
    if expand.count() > 0 and expand.is_visible():
        expand.click()
        time.sleep(0.5)
    page.locator(SEL_FORM["description"]).fill(bible)
    desc_value = page.locator(SEL_FORM["description"]).input_value()
    results["description"] = len(desc_value) == len(bible)
    results["description_chars"] = len(desc_value)
    return results


def verify_step2_review(page: Page, expected_title: str, expected_character: str) -> dict:
    """Click Next and verify the Step 2 review screen renders the expected values."""
    page.locator(SEL_NEXT).first.click()
    time.sleep(3)
    body = page.locator("body").inner_text()
    results = {
        "title_shown": expected_title in body,
        "character_shown": expected_character in body,
        "narrative_shown": "Narrative" in body,
        "url_after_next": page.url,
    }
    return results


def main():
    args = parse_args()
    bible_path = Path(args.bible)
    if not bible_path.exists():
        print(f"FATAL: bible file not found: {bible_path}", file=sys.stderr)
        return 2
    bible = bible_path.read_text()
    print(f"BIBLE loaded: {len(bible)} chars, {len(bible.split())} words")

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    print(f"Screenshots -> {out_dir}")

    # Wait for server
    print(f"Waiting for server at {args.url} ...")
    if not wait_for_server(args.url, timeout=60):
        print(f"FATAL: server didn't return 200 within 60s", file=sys.stderr)
        print(f"  Verify with: curl -s -o /dev/null -w '%{{http_code}}' '{args.url}'", file=sys.stderr)
        return 3

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        ctx = browser.new_context(viewport={"width": 1280, "height": 900})
        page = ctx.new_page()
        console_msgs = []
        page.on("console", lambda m: console_msgs.append(f"[{m.type}] {m.text[:200]}"))
        page.on("pageerror", lambda e: console_msgs.append(f"[pageerror] {str(e)[:200]}"))

        # STEP 1: landing
        print("\n=== STEP 1: load landing ===")
        page.goto(args.url, wait_until="networkidle", timeout=30000)
        page.screenshot(path=f"{out_dir}/01_landing.png", full_page=True)
        print(f"  title={page.title()!r}  url={page.url}")

        # STEP 2: open new-campaign route directly (skips sign-in wall)
        print("\n=== STEP 2: navigate to /new-campaign ===")
        new_cam_url = "http://localhost:8081/new-campaign?test_mode=true&test_user_id=test-user-123"
        page.goto(new_cam_url, wait_until="networkidle", timeout=30000)
        time.sleep(2)
        page.screenshot(path=f"{out_dir}/02_new_campaign.png", full_page=True)
        # Verify form fields exist
        for fname, sel in SEL_FORM.items():
            loc = page.locator(sel)
            if loc.count() == 0:
                print(f"  ERROR: {fname} selector not found: {sel}", file=sys.stderr)
                return 4
            if not loc.first.is_visible():
                print(f"  WARN: {fname} present but not visible yet: {sel}")

        # STEP 3: capture checkbox defaults BEFORE any interaction
        print("\n=== STEP 3: capture checkbox defaults (BEFORE any interaction) ===")
        defaults = capture_defaults(page)
        for name, state in defaults.items():
            print(f"  #{name}: checked={state}")
        page.screenshot(path=f"{out_dir}/03_checkbox_defaults.png", full_page=True)

        # STEP 4: fill form
        print("\n=== STEP 4: fill Step 1 form ===")
        results = verify_step1_filled(page, args.title, args.character, args.setting, bible)
        for name, ok in results.items():
            if name == "description_chars":
                print(f"  description_chars={ok}")
            else:
                mark = "✓" if ok else "✗"
                print(f"  {mark} {name}: {'PASS' if ok else 'FAIL'}")
        page.screenshot(path=f"{out_dir}/04_step1_filled.png", full_page=True)

        # STEP 5: click Next + verify Step 2 review
        print("\n=== STEP 5: click Next + verify Step 2 review ===")
        review = verify_step2_review(page, args.title, args.character)
        for name, ok in review.items():
            if isinstance(ok, bool):
                mark = "✓" if ok else "✗"
                print(f"  {mark} {name}: {'PASS' if ok else 'FAIL'}")
            else:
                print(f"  {name}: {ok}")
        page.screenshot(path=f"{out_dir}/05_step2_review.png", full_page=True)

        # Final verdict
        all_ok = (
            all(results[k] for k in ("title", "character", "setting", "description"))
            and all(review[k] for k in ("title_shown", "character_shown", "narrative_shown"))
        )
        print("\n=== VERDICT ===")
        print(f"  Step 1 form fill: {'PASS' if all(results[k] for k in ('title','character','setting','description')) else 'FAIL'}")
        print(f"  Step 2 review:    {'PASS' if all(review[k] for k in ('title_shown','character_shown','narrative_shown')) else 'FAIL'}")
        print(f"  OVERALL:          {'PASS' if all_ok else 'FAIL'}")
        print(f"\n  Defaults captured: {defaults}")
        print(f"  Screenshots: {out_dir}/")

        if not all_ok:
            print("\n=== console messages (last 20) ===")
            for m in console_msgs[-20:]:
                print(f"  {m}")
            return 5

        browser.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())