#!/usr/bin/env python3
"""Capture BEFORE/AFTER for a CSS-only mobile fix using a static file:// harness.

This template exists for the specific class of bug where:
  - The user's complaint is "X gets clipped / is too small / looks cramped on mobile"
  - The fix is a CSS rule added inside @media (max-width: 575.98px) in style.css
  - No JS, no HTML, no other CSS files are touched

It avoids the Flask/Firebase/auth-bypass cascade from the full-server path and
produces a deterministic, reproducible, serverless capture.

To customize for a different panel:
  1. Set ELEMENT_SELECTOR to the panel under test (e.g. ".dice-rolls", ".resources").
  2. Update HARNESS_HTML to include that panel + adjacent panels for visual context.
  3. Set RULE_NAME to the rule string your fix adds (e.g. ".dice-rolls { min-height: 7.5rem; }").
     The script extracts the @media (max-width: 575.98px) { ... } block from the worktree's
     style.css, then toggles your RULE_NAME in/out for BEFORE/AFTER.

Reference: PR #9368 (2026-08-25) — Dice Rolls panel 50% taller on mobile.

Pitfall (READ BEFORE USING): if your fixture's content is shorter than the worst-case
content the user reported, the BEFORE state won't actually show clipping and your
BEFORE/AFTER PNGs will look identical (only metadata differs). See
wa-mobile-ux-regression SKILL.md pitfall "Fixture text MUST reproduce the user's exact
screenshot text" before opening your PR.
"""
import json
import re
import sys
import time
from pathlib import Path

from playwright.sync_api import sync_playwright

# ========== CUSTOMIZE THESE 4 LINES PER BUG ==========
WORKTREE_PATH = Path("/private/tmp/wt-YOUR-WORKTREE")
ELEMENT_SELECTOR = ".dice-rolls"     # the panel you're changing
USER_AGENT_SHORT = "iPhone 14 Pro"    # for capture_meta.json metadata only
FIX_DESCRIPTION = "Make Dice Rolls panel 50% taller on mobile"  # for capture_meta.json
# The exact CSS rule your fix adds inside @media (max-width: 575.98px).
# Must match the worktree's style.css byte-for-byte (whitespace matters for the regex).
RULE_PATTERN = r"\.dice-rolls\s*\{\s*min-height:\s*[^}]+\}\s*"

HARNESS_HTML = """
<!doctype html>
<html><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
:root { color-scheme: dark; }
body {
  background: #0f1117;
  color: #d1d5db;
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
  margin: 0; padding: 12px;
}
.panel {
  background: #1a1d2a;
  border: 1px solid #2a2d3a;
  border-radius: 8px;
  padding: 10px;
  margin: 10px 0;
  font-size: 14px;
  line-height: 1.5;
}
.resources { background: #fff3cd; color: #1f2328; border-left: 4px solid #ffc107; }
.dice-rolls {
  background-color: #e8f4e8;
  color: #1f2328;
  padding: 10px;
  margin: 10px 0;
  border-radius: 5px;
  border-left: 4px solid #4caf50;
}
.dice-rolls ul { margin: 5px 0 0 20px; padding: 0; }
.dice-rolls li { margin: 4px 0; }
.meta { color: #6b7280; font-size: 12px; }
HARNESS_CSS_SLOT
</style>
</head><body>
<div class="panel resources"><b>📊 Resources:</b> HD: 1/1, Sneak Attack: 1d6</div>
<div class="dice-rolls">
  <b>🎲 Dice Rolls:</b>
  <ul>
    <li>1d20+2 = 4 vs DC 10 – Failure (Persuading Samwise to bolster his willpower)</li>
  </ul>
</div>
<div class="meta">Time to first token: 27.9s, server gen: 9.6s, total: 37.8s</div>
</body></html>
"""

VIEWPORT = {"width": 393, "height": 852}
DPR = 2
USER_AGENT = ("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
              "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 "
              "Mobile/15E148 Safari/604.1")


def read_mobile_block(worktree: Path) -> tuple[str, "re.Match[str]"]:
    css_path = worktree / "mvp_site/frontend_v1/style.css"
    real_css = css_path.read_text()
    m = re.search(r"@media \(max-width: 575\.98px\) \{(.*?)\n\}\n",
                  real_css, re.DOTALL)
    if not m:
        sys.exit(f"ERROR: cannot find @media (max-width: 575.98px) block in {css_path}")
    return "@media (max-width: 575.98px) {" + m.group(1) + "\n}\n", m


def build_harness(mobile_block: str, include_rule: bool) -> str:
    if include_rule:
        css = mobile_block
    else:
        css = re.sub(RULE_PATTERN, "", mobile_block)
    return HARNESS_HTML.replace("HARNESS_CSS_SLOT", css)


def main() -> None:
    out = Path(__file__).parent
    mobile_block, _ = read_mobile_block(WORKTREE_PATH)
    rule_match = re.search(RULE_PATTERN, mobile_block)
    if not rule_match:
        sys.exit(f"ERROR: cannot find rule matching {RULE_PATTERN!r} in @media block")
    print(f"Found rule: {rule_match.group(0).strip()}")

    (out / "_harness_before.html").write_text(build_harness(mobile_block, include_rule=False))
    (out / "_harness_after.html").write_text(build_harness(mobile_block, include_rule=True))

    meta: dict = {
        "viewport": VIEWPORT,
        "device_scale_factor": DPR,
        "is_mobile": True,
        "user_agent": USER_AGENT,
        "device": USER_AGENT_SHORT,
        "fix_description": FIX_DESCRIPTION,
        "element_selector": ELEMENT_SELECTOR,
    }

    with sync_playwright() as pw:
        browser = pw.chromium.launch()
        ctx = browser.new_context(
            viewport=VIEWPORT,
            screen=VIEWPORT,
            device_scale_factor=DPR,
            is_mobile=True,
            has_touch=True,
            user_agent=USER_AGENT,
        )

        for label, harness, css_state, out_png in [
            ("BEFORE", "_harness_before.html", "rule REMOVED", "before.png"),
            ("AFTER",  "_harness_after.html", "rule PRESENT", "after.png"),
        ]:
            page = ctx.new_page()
            page.goto(f"file://{out / harness}")
            page.wait_for_load_state("domcontentloaded")
            page.wait_for_timeout(150)
            info = page.evaluate(
                """(sel) => {
                    const el = document.querySelector(sel);
                    if (!el) return {found: false};
                    const r = el.getBoundingClientRect();
                    const cs = getComputedStyle(el);
                    return {
                        found: true,
                        minHeight: cs.minHeight,
                        height: cs.height,
                        offsetHeight: el.offsetHeight,
                        clientHeight: el.clientHeight,
                        scrollHeight: el.scrollHeight,
                        boundingRectHeight: r.height,
                        boundingRectWidth: r.width,
                        innerWidth: window.innerWidth,
                        innerHeight: window.innerHeight,
                    };
                }""",
                ELEMENT_SELECTOR,
            )
            info["label"] = label
            info["css_state"] = css_state
            meta[label.lower()] = info
            page.screenshot(path=str(out / out_png), full_page=True)
            print(f"{label}: offsetHeight={info['offsetHeight']}px  minHeight={info['minHeight']}  ({css_state})")
            page.close()

        browser.close()

    b, a = meta["before"], meta["after"]
    if not (a.get("found") and b.get("found")):
        sys.exit(f"ERROR: selector {ELEMENT_SELECTOR!r} not found in one or both harness pages")
    ratio = round(a["offsetHeight"] / b["offsetHeight"], 3) if b["offsetHeight"] else None
    meta["delta"] = {
        "offsetHeight": {
            "before": b["offsetHeight"], "after": a["offsetHeight"],
            "delta_px": a["offsetHeight"] - b["offsetHeight"],
            "ratio_after_over_before": ratio,
        },
        "minHeight": {"before": b["minHeight"], "after": a["minHeight"]},
    }
    meta["captured_at_unix"] = int(time.time())
    (out / "capture_meta.json").write_text(json.dumps(meta, indent=2))
    print(f"\nDelta: {a['offsetHeight']}px / {b['offsetHeight']}px = {ratio}x")
    print("OK — verify with vision_analyze on both PNGs before opening PR.")


if __name__ == "__main__":
    main()
