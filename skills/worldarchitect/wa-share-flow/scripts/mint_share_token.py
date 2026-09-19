#!/usr/bin/env python3
"""Mint a WA campaign share token via the legacy-fields API.

Two modes:
  1. PROD (default): Bearer token via OAuth. Point at mvp-site-app-dev-…run.app.
  2. LOCAL (--auth-bypass): Use /api/test_client_token_login on a local Flask server
     on 127.0.0.1:<port>. No OAuth needed; the local Firebase config signs the
     custom token into the browser session.

Pitfall 9 (added 2026-08-22): For campaigns whose character/setting/description
are stored in `initial_prompt` rather than as separate legacy fields, the probe
echoes back empty strings. Skip the probe and POST the legacy fields explicitly.

Usage (PROD):
    python3 mint_share_token.py --campaign-id <id> --firebase-uid <uid> \\
        --server https://mvp-site-app-dev-i6xf2p72ka-uc.a.run.app

Usage (LOCAL):
    python3 mint_share_token.py --campaign-id <id> --firebase-uid <uid> \
        --server http://127.0.0.1:8088 --auth-bypass

Output: {"share_token": "...", "share_url": "...", "verified": true} on success,
        {"error": "..."} on failure.
"""
import argparse
import asyncio
import json
import sys
from pathlib import Path

try:
    from playwright.async_api import async_playwright
except ImportError:
    sys.exit("playwright required: ${HOME}/.local/orch-venv/bin/pip install playwright")


SETTINGS_DEFAULT = "Warcraft III: The Third War (alternate timeline, Lordaeron)"


async def main(args):
    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True, channel="chromium")
        ctx = await browser.new_context(viewport={"width": 1400, "height": 900})
        page = await ctx.new_page()

        if args.auth_bypass:
            # Local-server test bypass
            await page.goto(
                f"{args.server}/api/test_client_token_login?uid={args.firebase_uid}&redirect=/",
                wait_until="networkidle", timeout=30000,
            )
            await page.wait_for_timeout(5000)
        else:
            # OAuth flow on prod — placeholder; real impl uses Aside per wa-share-flow SKILL.md
            sys.exit("OAuth mode not implemented in this script. Use --auth-bypass on local server, or run the Aside REPL recipe from SKILL.md on prod.")

        id_token = await page.evaluate("""
            async () => {
                if (!window.firebase || !window.firebase.auth) return null;
                const u = window.firebase.auth().currentUser;
                if (!u) return null;
                return await u.getIdToken();
            }
        """)
        if not id_token:
            print(json.dumps({"error": "no_id_token", "hint": "Check WORLDAI_DEV_MODE or SMOKE_TOKEN on the local server"}))
            sys.exit(1)

        # Direct mint — skips probe (Pitfall 9 workaround for empty legacy fields)
        description = args.description or "The Deceiver's Crown — gender-neutral Warcraft III / D&D 5e hybrid campaign. Player selects pronouns (he/she/they), presentation (masculine/feminine/androgynous), and honorific (Lord/Lady/Scion) at character creation; mechanics is identical across all choices."
        mint = await page.request.post(
            f"{args.server}/api/campaigns/{args.campaign_id}/share-token",
            headers={"Authorization": f"Bearer {id_token}", "Content-Type": "application/json"},
            data=json.dumps({
                "confirm_legacy_fields": True,
                "legacy_share_fields": {
                    "character": args.character or "Nocturne Ravencrest",
                    "description": description[:300],
                    "setting": args.setting or SETTINGS_DEFAULT,
                }
            }),
        )
        body = json.loads(await mint.text())
        if mint.status != 200:
            print(json.dumps(body))
            sys.exit(2)
        share_url = body["share_url"]

        # Verify signed-out render
        verified = False
        try:
            verify = await ctx.new_page()
            await verify.goto(share_url, wait_until="networkidle", timeout=30000)
            await verify.wait_for_timeout(5000)
            h1 = await verify.evaluate("() => document.querySelector('h1')?.innerText")
            play_link = await verify.query_selector("a:has-text('Play in this world')")
            verified = bool(h1) and bool(play_link)
            if not verified:
                body = {"share_token": body["share_token"], "share_url": share_url, "verified": False,
 "warning": "h1 or Play CTA missing — mint succeeded but rendering is broken"}
            else:
                body = {"share_token": body["share_token"], "share_url": share_url, "verified": True}
        except Exception as e:
            body = {"share_token": body["share_token"], "share_url": share_url, "verified": False, "verify_error": str(e)}

        print(json.dumps(body, indent=2))
        await browser.close()


def main_entry():
    p = argparse.ArgumentParser()
    p.add_argument("--campaign-id", required=True)
    p.add_argument("--firebase-uid", required=True)
    p.add_argument("--server", default="https://mvp-site-app-dev-i6xf2p72ka-uc.a.run.app")
    p.add_argument("--auth-bypass", action="store_true", help="Use /api/test_client_token_login (local-server only)")
    p.add_argument("--character", default="")
    p.add_argument("--setting", default="")
    p.add_argument("--description", default="")
    args = p.parse_args()
    asyncio.run(main(args))


if __name__ == "__main__":
    main_entry()