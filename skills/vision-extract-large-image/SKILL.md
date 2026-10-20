---
name: vision-extract-large-image
description: Crop huge PDFs into tiles, read each via vision_analyze.
---

# Vision Extract — Large Images & Scanned PDFs

## Problem

`vision_analyze` and built-in vision tools cannot reliably read very large images. Two failure modes hit on a 5.6 MB single-page scanned W-2 (4284 × 5712 pts):

1. **Image file truncated** — sending the unresized PNG (~4760 × 6347 px) failed with `Native vision failed: image file is truncated`.
2. **Partial read** — even when the load succeeded, only the top strip was returned; the rest of the form was cut off.

`pdftotext -layout` returns empty on scanned image PDFs. `tesseract` on full pages is hit-or-miss on small/dense forms (saw it pull "755531.01 237982.01" then go silent on a W-2).

This skill is the recipe that actually works for extracting structured numeric data from large scanned PDFs and big screenshots.

## When to use

- User asks to read a scanned W-2, contract, receipt, multi-page form, or any image-only PDF.
- `pdftotext` returned empty or whitespace on the PDF.
- `vision_analyze` failed with "image file is truncated" or returned only a partial view.
- The image is >3000 px in either dimension.
- `tesseract` is missing or unreliable on the target form.

## Quick recipe

> **One-shot:** `python3 scripts/tile_for_vision.py input.pdf` writes tiles to `/tmp/vision_in_<ts>/` and prints paths. Skip straight to step 4.

1. **Detect page count and dimensions:**
   ```bash
   pdfinfo input.pdf | grep -i "pages\|page size"
   ```
   Scanned multi-page stacks often ship as ONE giant page (e.g. a W-2 stored as 4284 × 5712 pts, 5.6 MB). That's expected — treat single-page as multi-tile.

2. **Render to PNG at 120 DPI** (sweet spot for OCR-via-vision; lower loses detail, higher blows up file size):
   ```bash
   pdftoppm -png -r 120 input.pdf /tmp/inp
   ```

3. **Crop into ~4 vertical tiles with Pillow** (the key step):
   ```python
   from PIL import Image
   im = Image.open('/tmp/inp-1.png')
   w, h = im.size
   tiles = [(0, h//4), (h//4, h//2), (h//2, 3*h//4), (3*h//4, h)]
   for i, (y0, y1) in enumerate(tiles):
       c = im.crop((0, y0, w, y1))
       c.thumbnail((1800, 1800))   # critical: keep under ~1800px wide
       c.save(f'/tmp/inp_q{i+1}.jpg', 'JPEG', quality=80)
   ```
   - 4 tiles covers most forms; bump to 6 for dense multi-section forms.
   - **1800 px wide is the safe ceiling** for `vision_analyze` JPEG. Going above risks "image is truncated".

4. **Read each tile with `vision_analyze` in parallel** — separate tool calls in the same turn, same targeted question each time ("Read every box/row/value in this section"):

5. **Merge the answers** in your reply. Explicitly note which box came from which tile so the user can spot-check.

## Pitfalls

- **`pdftotext -layout` returns empty on scanned PDFs.** Don't waste time looping on it. Switch to vision immediately.
- **`vision_analyze` silently truncates huge images** — it loads, returns only a visible top strip, and the user never knows the bottom was lost. Always check the rendered tile, not just the tool call's success.
- **Image file is truncated error** — caused by sending a multi-MB PNG without downscaling. Fix: Pillow `thumbnail((1800, 1800))` first, save as JPEG quality 80.
- **One-page-giant-PDFs are common for tax forms** — `pdfinfo` reports `Pages: 1` but `Page size: 4284 x 5712 pts`. Treat as multi-tile.
- **OCR-via-tesseract on forms is unreliable** — picks up the first few boxes then drops. Use `vision_analyze`, not tesseract, when the model is available.
- **Vision can mis-read dollar amounts.** Always quote values with a "via vision on the PDF" annotation so the user can spot-check against the original.
- **Don't auto-merge tiles into one image** — combining loses per-tile question targeting and risks another truncation.
- **`sips --resampleHeight` may produce a tiny thumb** if the source is huge; prefer `pdftoppm` + Pillow thumbnail for predictable output.

## Verification

Before reporting numbers to the user:
- Cross-check at least 2 numeric values across tiles (e.g. Box 1 from tile 1 should match Box 1 from any tile that shows it).
- Compare to known documents: W-2 Box 1 (wages) + Box 12b (401k deferral) + Box 14 (RSU) should be consistent with employer name and pay period.
- If a tile returns only a partial answer ("I see $755,531"), re-ask with a more targeted prompt: "What is the value in Box 1? What about Box 2? List each box on its own line."

## When NOT to use

- Text-extractable PDFs → use `pdftotext -layout` directly. No need for vision.
- Short images (<2000 px in both dims) → send directly to `vision_analyze`, no tiling.
- Receipts with a few lines of text → tesseract is usually fine; no vision cost.

## Companion pattern: locate the artifact first

If the user asks "find my W-2 / contract / receipt", run the 9-store memory fan-out **and** also search filesystem paths the data may live in:
- `~/budget/` — tax docs, financial reconciliation
- `~/Documents/`, `~/Desktop/`, `~/Downloads/`
- `~/agent-f/`, repo `data/` folders
- Workspace-specific dirs (e.g. `~/worldarchitect.ai/...`)

Memory stores rarely hold raw PDFs; the actual file usually lives on disk outside any memory index. Once located, this skill handles the extraction.

## Related skills

- `wa-visual-proof-playwright` — capture BEFORE/AFTER PNG evidence (different intent: visual proof, not data extraction).
- `inline-attach-evidence` — attaching extracted images to PRs/Slack after extraction.
- `memory-search` — finding the artifact in the first place; this skill handles what to do once you have the file.
- `evidence-attach-to-slack` — 3-stage upload recipe for sending extracted images as Slack attachments.
- `references/inbound-video-extraction.md` — companion reference for **video attachments** (`.mp4` / `.mov` / `.webm`) the user sends to the agent: ffmpeg frame sampling, vision_analyze parallel fan-out, and the "[screenshot removed to save context]" re-sample workaround. Inbound counterpart to `evidence-attach-to-slack`'s outbound flow.
