#!/usr/bin/env python3
"""
chrome_stage.py — Stage a single social-media draft in headless Chrome with
cookies decrypted from the local Chrome profile (Default = jleechan signed in
to LinkedIn/Twitter/Facebook/Reddit/Dev.to).

Usage:
  python3 chrome_stage.py \
      --platform twitter \
      --draft /tmp/drafts/worldai-hotd-2026-08-05/twitter.md \
      --compose-url https://x.com/compose/post \
      --screenshot /tmp/drafts/worldai-hotd-2026-08-05/screenshots/twitter_chrome.png

Selectors are the same proven set used by the social-poster skill (HN, Reddit,
Mastodon, Dev.to verified 2026-07-17). Twitter/LinkedIn/Facebook/Threads/Instagram
use the headless-with-cookies path which can defeat the React-controlled-field
truncation that hit Playwright/Aside (cookie-bound sessions skip the OAuth
re-validate step that blanks pasted content).

Returns JSON with:
  {platform, status, body_len_in_field, screenshot, paste_ok, error}
  status: staged | paste_failed | login_wall | failed
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import Optional

from playwright.sync_api import (
    Browser,
    Page,
    Playwright,
    TimeoutError as PWTimeout,
    sync_playwright,
)


# Per-platform paste recipe: (compose_url, list of (mode, selector, value_field))
# mode="title" pastes into selector as the post title
# mode="body"  pastes into selector as the post body
# mode="submit" clicks the submit button (we DON'T click unless --submit)
PLATFORM_RECIPES: dict[str, dict] = {
    "hackernews": {
        "url": "https://news.ycombinator.com/submit",
        "fields": [
            ("title", "input[name='title']"),
            ("body", "textarea[name='text']"),
        ],
        "wait_for": "input[name='title']",
        "post_submit_wait": 2.0,
    },
    "twitter": {
        "url": "https://x.com/compose/post",
        "fields": [
            ("body", "div[contenteditable='true'][data-testid='tweetTextarea_0']"),
        ],
        "wait_for": "div[contenteditable='true'][data-testid='tweetTextarea_0']",
        "post_submit_wait": 2.0,
    },
    "mastodon": {
        "url": "https://mastodon.social/publish",
        "fields": [
            ("body", "textarea#status-input"),
        ],
        "wait_for": "textarea#status-input",
        "post_submit_wait": 2.0,
    },
    "devto": {
        "url": "https://dev.to/new",
        "fields": [
            ("body", "textarea#article_body_markdown"),
            ("title", "textarea#article-form-title"),
        ],
        "wait_for": "textarea#article-form-title",
        "post_submit_wait": 2.0,
    },
    "linkedin": {
        # LinkedIn share box uses a contentEditable div after clicking the trigger.
        # We open the share URL directly; if the share box isn't open, we click
        # the trigger by visible text.
        "url": "https://www.linkedin.com/feed/?shareActive=true",
        "fields": [
            ("body", "div[contenteditable='true'][role='textbox']"),
        ],
        "wait_for": "div.ql-editor[contenteditable='true']",
        "post_submit_wait": 2.0,
    },
    "facebook": {
        "url": "https://www.facebook.com/",
        "fields": [
            ("body", "div[contenteditable='true'][role='textbox']"),
        ],
        "wait_for": "div[contenteditable='true'][role='textbox']",
        "post_submit_wait": 2.0,
    },
    "threads": {
        "url": "https://www.threads.net/",
        "fields": [
            ("body", "div[contenteditable='true']"),
        ],
        "wait_for": "div[contenteditable='true']",
        "post_submit_wait": 2.0,
    },
    "reddit": {
        "url_arg": True,  # compose-url passed via --compose-url (per-sub URL)
        "fields": [
            ("title", "textarea[name='title']"),
            ("body", "textarea[name='text']"),
        ],
        "wait_for": "textarea[name='text']",
        "post_submit_wait": 2.0,
    },
    "reddit_localllama": {
        "url": "https://old.reddit.com/r/LocalLLaMA/submit?selftext=true",
        "fields": [
            ("title", "textarea[name='title']"),
            ("body", "textarea[name='text']"),
        ],
        "wait_for": "textarea[name='text']",
        "post_submit_wait": 2.0,
    },
    "reddit_rag": {
        "url": "https://old.reddit.com/r/Rag/submit?selftext=true",
        "fields": [
            ("title", "textarea[name='title']"),
            ("body", "textarea[name='text']"),
        ],
        "wait_for": "textarea[name='text']",
        "post_submit_wait": 2.0,
    },
    "reddit_openai": {
        "url": "https://old.reddit.com/r/OpenAI/submit?selftext=true",
        "fields": [
            ("title", "textarea[name='title']"),
            ("body", "textarea[name='text']"),
        ],
        "wait_for": "textarea[name='text']",
        "post_submit_wait": 2.0,
    },
    "reddit_ai_rpg_community": {
        "url": "https://old.reddit.com/r/ai_rpg_community/submit?selftext=true",
        "fields": [
            ("title", "textarea[name='title']"),
            ("body", "textarea[name='text']"),
        ],
        "wait_for": "textarea[name='text']",
        "post_submit_wait": 2.0,
    },
    "reddit_AIPlayableFiction": {
        "url": "https://old.reddit.com/r/AIPlayableFiction/submit?selftext=true",
        "fields": [
            ("title", "textarea[name='title']"),
            ("body", "textarea[name='text']"),
        ],
        "wait_for": "textarea[name='text']",
        "post_submit_wait": 2.0,
    },
    "reddit_AIDungeon": {
        "url": "https://old.reddit.com/r/AIDungeon/submit?selftext=true",
        "fields": [
            ("title", "textarea[name='title']"),
            ("body", "textarea[name='text']"),
        ],
        "wait_for": "textarea[name='text']",
        "post_submit_wait": 2.0,
    },
    "reddit_aigamedev": {
        "url": "https://old.reddit.com/r/aigamedev/submit?selftext=true",
        "fields": [
            ("title", "textarea[name='title']"),
            ("body", "textarea[name='text']"),
        ],
        "wait_for": "textarea[name='text']",
        "post_submit_wait": 2.0,
    },
    "reddit_HouseOfTheDragon": {
        "url": "https://old.reddit.com/r/HouseOfTheDragon/submit?selftext=true",
        "fields": [
            ("title", "textarea[name='title']"),
            ("body", "textarea[name='text']"),
        ],
        "wait_for": "textarea[name='text']",
        "post_submit_wait": 2.0,
    },
    "reddit_asoiaf": {
        "url": "https://old.reddit.com/r/asoiaf/submit?selftext=true",
        "fields": [
            ("title", "textarea[name='title']"),
            ("body", "textarea[name='text']"),
        ],
        "wait_for": "textarea[name='text']",
        "post_submit_wait": 2.0,
    },
    "reddit_freefolk": {
        "url": "https://old.reddit.com/r/freefolk/submit?selftext=true",
        "fields": [
            ("title", "textarea[name='title']"),
            ("body", "textarea[name='text']"),
        ],
        "wait_for": "textarea[name='text']",
        "post_submit_wait": 2.0,
    },
}


def decrypt_browser_cookies(
    browser: str, profile: str, domains: list[str]
) -> list[dict]:
    """Use browserclaw cookies decrypt to extract signed-in cookies for domains.
    browser: 'chrome' | 'aside'
    Decrypts each domain in its own call and merges results (browserclaw's
    domain-filter uses SQL LIKE which doesn't OR well; one-call-per-domain
    is more reliable and gives us per-domain feedback).
    """
    if browser == "aside":
        db = f"${HOME}/Library/Application Support/Aside/{profile}/Cookies"
        key_service, key_account = "Aside Safe Storage", "Aside"
    else:
        db = f"${HOME}/Library/Application Support/Google/Chrome/{profile}/Cookies"
        key_service, key_account = "Chrome Safe Storage", "Chrome"
    merged: list[dict] = []
    seen: set[tuple[str, str]] = set()
    for d in domains:
        out = Path("/tmp") / f"{browser}_cookies_{profile}_{d.replace('.','_')}.json"
        cmd = [
            "browserclaw", "cookies", "decrypt",
            "--db", db,
            "--output", str(out),
            "--keychain-service", key_service,
            "--keychain-account", key_account,
            "--domain-filter", f"%{d}%",
        ]
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        if res.returncode != 0:
            continue
        try:
            cookies = json.loads(out.read_text()).get("cookies", [])
        except Exception:
            continue
        for c in cookies:
            k = (c.get("domain", ""), c.get("name", ""))
            if k not in seen:
                seen.add(k)
                merged.append(c)
    return merged


def decrypt_chrome_cookies(profile: str, domains: list[str]) -> list[dict]:
    """Backward-compat shim — Chrome Default profile."""
    return decrypt_browser_cookies("chrome", profile, domains)


def extract_title_and_body(draft_path: Path) -> tuple[Optional[str], str]:
    """For reddit (and any platform with a separate title field), parse the
    markdown draft for a '## Title' first line and a '## Body' section.
    Returns (title, body). For single-body platforms just returns (None, body).
    """
    text = draft_path.read_text(encoding="utf-8")
    # Convention: first H1 or H2 line is the title, everything after is the body
    m = re.match(r"^#\s+(.+?)\n+(.*)$", text, re.DOTALL)
    if m:
        return m.group(1).strip(), m.group(2).strip()
    return None, text.strip()


def paste_into_field(page: Page, selector: str, text: str) -> tuple[bool, int]:
    """Click + focus + fill a field. Returns (ok, length-in-field-after-paste).
    Uses three fallback strategies for React-controlled contentEditable:
      1. locator.click() + keyboard.insertText (preferred for Twitter/LinkedIn)
      2. locator.fill() (for vanilla <textarea> and <input>)
      3. JS-level value setting + input event (last resort)
    """
    try:
        loc = page.locator(selector).first
        loc.wait_for(state="visible", timeout=8000)
        loc.click(timeout=5000)
        time.sleep(0.5)
        # Clear residual content
        page.keyboard.press("Control+a")
        page.keyboard.press("Delete")
        time.sleep(0.3)
        # Strategy 1: keyboard.type (preferred for X/LinkedIn contentEditable —
        # dispatches real keypresses that React tracks; insertText is too fast and
        # X closes the modal on rapid text-injection)
        page.keyboard.type(text, delay=8)
        time.sleep(0.5)
        # Read back
        val = page.evaluate(
            "(sel) => {"
            "  const el = document.querySelector(sel);"
            "  if (!el) return -1;"
            "  if (el.tagName === 'TEXTAREA' || el.tagName === 'INPUT') return (el.value || '').length;"
            "  return (el.innerText || el.textContent || '').length;"
            "}",
            selector,
        )
        n = int(val)
        if n >= int(len(text) * 0.7):
            return True, n
        # Strategy 2: locator.fill (for textarea/input)
        loc.fill(text, timeout=8000)
        time.sleep(0.4)
        val = page.evaluate(
            "(sel) => {"
            "  const el = document.querySelector(sel);"
            "  if (!el) return -1;"
            "  if (el.tagName === 'TEXTAREA' || el.tagName === 'INPUT') return (el.value || '').length;"
            "  return (el.innerText || el.textContent || '').length;"
            "}",
            selector,
        )
        n = int(val)
        if n >= int(len(text) * 0.7):
            return True, n
        # Strategy 3: JS-level value setter + React event
        page.evaluate(
            """([sel, t]) => {
                const el = document.querySelector(sel);
                if (!el) return;
                const proto = el.tagName === 'TEXTAREA' || el.tagName === 'INPUT'
                    ? HTMLTextAreaElement.prototype
                    : HTMLDivElement.prototype;
                const setter = Object.getOwnPropertyDescriptor(proto, 'value')?.set
                    || Object.getOwnPropertyDescriptor(proto, 'textContent')?.set;
                if (setter) setter.call(el, t);
                el.dispatchEvent(new Event('input', { bubbles: true }));
                el.dispatchEvent(new Event('change', { bubbles: true }));
            }""",
            [selector, text],
        )
        time.sleep(0.4)
        val = page.evaluate(
            "(sel) => {"
            "  const el = document.querySelector(sel);"
            "  if (!el) return -1;"
            "  if (el.tagName === 'TEXTAREA' || el.tagName === 'INPUT') return (el.value || '').length;"
            "  return (el.innerText || el.textContent || '').length;"
            "}",
            selector,
        )
        n = int(val)
        return (n >= int(len(text) * 0.7)), n
    except Exception as e:
        return False, 0


def stage_one(
    platform: str,
    draft_path: Path,
    compose_url: str,
    screenshot_path: Path,
    profile: str = "Default",
    browser: str = "chrome",
    wait_extra: float = 4.0,
) -> dict:
    recipe = PLATFORM_RECIPES.get(platform, {})
    if not recipe:
        return {"platform": platform, "status": "failed", "error": f"no recipe for {platform}"}

    title, body = extract_title_and_body(draft_path)
    url = compose_url if recipe.get("url_arg") else recipe["url"]

    domains = {
        "linkedin.com", "twitter.com", "x.com", "facebook.com", "reddit.com",
        "mastodon.social", "dev.to", "threads.net", "news.ycombinator.com",
    }
    cookies = decrypt_browser_cookies(browser, profile, list(domains))
    if not cookies:
        return {"platform": platform, "status": "failed", "error": f"no cookies decrypted (browser={browser})"}

    result = {
        "platform": platform,
        "compose_url": url,
        "title": title,
        "body_len_expected": len(body),
        "body_len_in_field": 0,
        "screenshot": str(screenshot_path),
        "paste_ok": False,
        "status": "failed",
        "error": None,
    }

    with sync_playwright() as p:
        browser: Browser = p.chromium.launch(
            channel="chrome",
            headless=True,
            args=["--no-sandbox", "--disable-dev-shm-usage"],
        )
        context = browser.new_context(
            viewport={"width": 1280, "height": 900},
            storage_state={"cookies": cookies, "origins": []},
        )
        page = context.new_page()
        try:
            page.goto(url, wait_until="domcontentloaded", timeout=30000)
            time.sleep(wait_extra)
            # Wait for the main compose selector
            try:
                page.wait_for_selector(recipe["wait_for"], timeout=15000)
            except PWTimeout:
                # Probably a login wall — capture and report
                screenshot_path.parent.mkdir(parents=True, exist_ok=True)
                page.screenshot(path=str(screenshot_path), full_page=True)
                result["status"] = "login_wall"
                result["error"] = f"wait_for {recipe['wait_for']} timed out"
                return result

            # Paste title and body in the order specified by the recipe
            title_to_paste = title
            body_to_paste = body
            for mode, sel in recipe["fields"]:
                if mode == "title" and title_to_paste:
                    ok, n = paste_into_field(page, sel, title_to_paste)
                    result["title_len_in_field"] = n
                    if not ok:
                        result["status"] = "paste_failed"
                        result["error"] = f"title paste failed ({sel})"
                elif mode == "body":
                    ok, n = paste_into_field(page, sel, body_to_paste)
                    result["body_len_in_field"] = n
                    if not ok or n < len(body_to_paste) * 0.7:
                        result["paste_ok"] = False
                        result["status"] = "paste_failed"
                        result["error"] = f"body paste short ({n}/{len(body_to_paste)} on {sel})"
                    else:
                        result["paste_ok"] = True

            # Screenshot regardless
            screenshot_path.parent.mkdir(parents=True, exist_ok=True)
            page.screenshot(path=str(screenshot_path), full_page=True)

            if result.get("status") not in ("paste_failed", "login_wall"):
                result["status"] = "staged"

        except Exception as e:
            result["status"] = "failed"
            result["error"] = f"{type(e).__name__}: {e}"
        finally:
            context.close()
            browser.close()
    return result


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--platform", required=True)
    ap.add_argument("--draft", required=True)
    ap.add_argument("--compose-url", default="")
    ap.add_argument("--screenshot", required=True)
    ap.add_argument("--profile", default="Default")
    ap.add_argument("--browser", default="chrome", choices=["chrome","aside"])
    ap.add_argument("--wait", type=float, default=4.0)
    args = ap.parse_args()

    res = stage_one(
        platform=args.platform,
        draft_path=Path(args.draft),
        compose_url=args.compose_url,
        screenshot_path=Path(args.screenshot),
        profile=args.profile,
        browser=args.browser,
        wait_extra=args.wait,
    )
    print(json.dumps(res, indent=2))
    return 0 if res.get("status") == "staged" else 1


if __name__ == "__main__":
    sys.exit(main())
