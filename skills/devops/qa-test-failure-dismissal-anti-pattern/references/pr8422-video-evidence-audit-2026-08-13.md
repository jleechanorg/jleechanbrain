# PR #8422 video-evidence audit — 2026-08-13

**Trigger:** Operator forwarded `${HOME}/.smartclaw/cache/videos/video_fc01ad2896ba.webm` in Slack with the message *"Playwright Chromium UI Video Evidence for PR #8422 (HEAD 282e8b1b41)"* and asked for a review.

## Probe — what ffprobe said

```
ffprobe -v error -show_entries format=duration,size -show_entries stream=codec_type,codec_name,width,height,r_frame_rate -of json
{
  "streams": [{"codec_name": "vp8", "codec_type": "video", "width": 1280, "height": 720, "r_frame_rate": "25/1"}],
  "format": {"duration": "182.400000", "size": "7036279", "bit_rate": "308608"}
}
```

First red flag: **PR body claims "7s walkthrough"; file is 182.4s** — 26× the claimed duration. Either the capture is wrong or the description is wrong.

## Frame extraction + size table

| Timestamp | File size (bytes) | Size relative to median | Interpretation |
|---|---|---|---|
| 0s | 5,620 | 0.10× | Blank / loading-state / pre-paint |
| 15s | 57,206 | 1.01× | Real rendered content |
| 30s | 57,661 | 1.02× | Real rendered content |
| 60s | 56,944 | 1.00× | Real rendered content |
| 90s | 56,721 | 1.00× | Real rendered content |
| 120s | 56,478 | 1.00× | Real rendered content |
| 150s | 56,806 | 1.00× | Real rendered content |
| 180s | 56,953 | 1.01× | Real rendered content |

The frame-0s outlier is the post-arrival-but-pre-paint frame; everything after is a stable page.

## Vision findings (4 frames spot-checked)

Every real frame (15s / 60s / 120s / 180s) shows the **same dashboard view**:

- WorldAI logo top-left, Knowledge base / wiki / Reddit / Discord nav top
- "My Campaigns" left rail
- A white tile with a **static black lightning-bolt SVG** and label **"Quick Start · Express Launch"** — NOT the WCAG AA green gradient pill described in the PR body
- A smaller secondary button **"📜 Custom Campaign"** underneath, plus a small round target icon
- "Search campaigns…" + sort/order/theme/status filter panel
- Right rail: **"You have no campaigns. Start a new one!"**

No click animation, no redirect, no `/game/quick-start-dragon-knight?qs=1`, no first-run banner, no character-creation review, no `.planning-block` modal. The video never advances past the idle dashboard for the entire 182.4 seconds.

## DOM/CSS cross-check

**`gh api repos/jleechanorg/worldarchitect.ai/contents/mvp_site/frontend_v1/index.html?ref=282e8b1b4`** — grep for the relevant markers:

```
id="quick-start-btn"
class="quick-start-btn-primary"
<span class="quick-start-bolt" aria-hidden="true">
<span>Quick Start<span class="d-none d-sm-inline"> • Express Launch</span></span>
<button id="go-to-new-campaign" class="detailed-campaign-btn">
<span>Custom Campaign</span>
```

Selector and class exist on HEAD. The pill-style `<button id="quick-start-btn">` is in the markup.

**`style.css` at HEAD `282e8b1b4`** — actual `.quick-start-btn-primary` rule:

```css
.quick-start-btn-primary {
  position: relative;
  display: inline-flex;
  align-items: center;
  gap: 0.5rem;
  padding: calc(0.4375rem - 1px) 1.25rem;
  font-weight: 600;
  font-size: 0.95rem;
  line-height: 1.5;
  color: #0b5ed7 !important;
  background: linear-gradient(135deg, rgba(13, 110, 253, 0.1), rgba(13, 110, 253, 0.03));
  border: 2px solid rgba(13, 110, 253, 0.75);
  border-radius: 999px;
  box-shadow: 0 0 12px rgba(13, 110, 253, 0.3);
  ...
}
```

Actual style is a **translucent blue outlined pill** (`#0d6efd` tint, 0.1 → 0.03 gradient, white text+bolt). PR body claims "WCAG AA green gradient `#047857/#065f46/#022c22`" — **the green colors do not exist anywhere in the actual `style.css` for `.quick-start-btn-primary`**.

The video's black-bolt-on-white-tile rendering looks like an **older markup** (likely the pre-rebuild branch where the tile was a `<div class="quick-start-tile">` hero, not the current pill-style button). The capture is running against a build that doesn't match what HEAD actually ships.

## Capture script signature

`testing_ui/capture_quick_start_evidence_pr8422.py` at HEAD `282e8b1b4`:

```
BASE_URL = os.environ.get("QUICK_START_EVIDENCE_BASE_URL", "http://localhost:9291")
page.goto(f"{BASE_URL}/?test_mode=true&test_user_id={TEST_USER_ID}&skip_redirect=true")
page.wait_for_load_state("networkidle", timeout=180000)
page.wait_for_selector("#quick-start-btn", state="visible", timeout=180000)
page.click("#quick-start-btn")
page.wait_for_load_state("networkidle", timeout=180000)
```

The 180s `wait_for_selector` is the smoking gun: if `#quick-start-btn` never becomes visible (e.g. CSS load failure, branch drift, page swapped to a route that doesn't render the button), Playwright Chromium native recording captures **the entire 180s wait window as the video** before throwing. The resulting 6.7MB webm of a static dashboard is the wait, not the walkthrough.

## Verdict

**Video evidence INVALID.** Don't rubber-stamp PR #8422 green based on this capture. All 4 HIGH rows of the video-vs-PR-claim mismatch table fail:

1. `.quick-start-btn-primary` green gradient claim → black bolt on white tile
2. 2.5s auto-redirect to `/game/quick-start-dragon-knight?qs=1` → no click, no redirect, no game page
3. First-run banner visible → banner never appears
4. Character-creation review (`.planning-block`) → never appears

## Recommended remediation

1. **Re-capture against HEAD** — verify `git rev-parse HEAD` matches `282e8b1b415292ceeafe5e216e444b844d210df4` before running the capture script. The current video may be from a stale SHA on the capture-host.
2. **Drop the 180s timeout to 30s** — `wait_for_selector("#quick-start-btn", state="visible", timeout=30000)` — so the script fails fast if the button isn't rendered, rather than producing 3 minutes of idle dashboard.
3. **Add a sanity check at the start of capture** — assert `page.url` starts with `BASE_URL` and that `await page.locator("#quick-start-btn").count() > 0` BEFORE opening the recorder. If the locator returns 0, abort and report "Quick Start button missing from DOM at SHA X" rather than recording 3 minutes of nothing.
4. **Add a post-click assertion** — after `page.click("#quick-start-btn")`, `assert page.url.startswith(f"{BASE_URL}/game/")` to detect when the redirect path is broken.
5. **Verify `duration` of the resulting webm is ≤ 10s** before publishing — if it's longer, the capture script timed out somewhere; do not commit the artifact.

## Mismatch table output (paste-able into bring-to-green report)

```
| Claimed in PR body                                | Observed in video                          | Severity |
|---------------------------------------------------|--------------------------------------------|----------|
| `.quick-start-btn-primary` WCAG AA green pill     | Static black-on-white tile, no badge       | HIGH     |
| 2.5s auto-redirect to /game/...?qs=1 after click  | No click captured, no redirect occurs      | HIGH     |
| First-run banner visible after redirect           | Banner never appears                       | HIGH     |
| Character-creation review (.planning-block)       | Never appears                              | HIGH     |
| `37/37 Node unit tests pass`                      | Not relevant to visual evidence            | LOW      |
| `Playwright 2-viewport behavior suite passed`     | May have passed against a build ≠ HEAD     | MEDIUM   |
```

## Source pointers

- PR: https://github.com/jleechanorg/worldarchitect.ai/pull/8422 (HEAD 282e8b1b415292ceeafe5e216e444b844d210df4)
- Capture script: `testing_ui/capture_quick_start_evidence_pr8422.py`
- Style: `mvp_site/frontend_v1/style.css` (no `#047857` / `#065f46` / `#022c22` in `.quick-start-btn-primary` block)
- Slack upload: `video_fc01ad2896ba.webm`