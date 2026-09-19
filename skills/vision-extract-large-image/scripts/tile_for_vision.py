#!/usr/bin/env python3
"""
tile_for_vision.py — Crop a large scanned PDF/image into ≤1800px-wide tiles for vision_analyze.

Usage:
  python3 tile_for_vision.py input.pdf            # tiles to /tmp/vision_in/
  python3 tile_for_vision.py input.pdf -o ./out    # tiles to ./out/
  python3 tile_for_vision.py input.pdf -t 6        # 6 tiles instead of 4
  python3 tile_for_vision.py input.png            # direct image input

Why this exists:
  vision_analyze silently truncates images >~3000px (top-strip only) and rejects
  multi-MB PNGs with "image file is truncated". Splitting a 4284x5712 W-2 into
  4 vertical JPEG tiles (each ~1800x600) lets vision_analyze read the whole
  form reliably. See SKILL.md "vision-extract-large-image" for context.
"""
import argparse
import os
import subprocess
import sys
import tempfile
from pathlib import Path

MAX_TILE_WIDTH = 1800  # safe ceiling for vision_analyze JPEG
DEFAULT_TILES = 4


def render_pdf_to_png(pdf_path: str, out_dir: str, dpi: int = 120) -> list[str]:
    """Render each page of a PDF to PNG at the given DPI."""
    prefix = os.path.join(out_dir, "page")
    subprocess.run(
        ["pdftoppm", "-png", "-r", str(dpi), pdf_path, prefix],
        check=True,
    )
    return sorted(str(p) for p in Path(out_dir).glob("page-*.png"))


def tile_image(image_path: str, out_dir: str, num_tiles: int = DEFAULT_TILES) -> list[str]:
    """Crop a (potentially huge) image into N vertical tiles, resized to MAX_TILE_WIDTH."""
    from PIL import Image

    im = Image.open(image_path)
    w, h = im.size
    if w == 0 or h == 0:
        raise ValueError(f"Empty image: {image_path}")

    # Choose tile count based on aspect ratio: tall images want more tiles
    aspect = h / w
    n = num_tiles
    if aspect > 2.5 and num_tiles == DEFAULT_TILES:
        n = max(num_tiles, int(aspect / 1.5))

    base = Path(out_dir)
    base.mkdir(parents=True, exist_ok=True)
    tiles = []
    page_stem = Path(image_path).stem
    for i in range(n):
        y0 = (i * h) // n
        y1 = ((i + 1) * h) // n
        c = im.crop((0, y0, w, y1))
        c.thumbnail((MAX_TILE_WIDTH, MAX_TILE_WIDTH))
        out_path = base / f"{page_stem}_tile{i + 1}of{n}.jpg"
        c.save(out_path, "JPEG", quality=80)
        tiles.append(str(out_path))
    return tiles


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("input", help="Path to PDF or image (PNG/JPG/etc.)")
    ap.add_argument("-o", "--out-dir", default=None, help="Output directory (default: /tmp/vision_in/)")
    ap.add_argument("-t", "--tiles", type=int, default=DEFAULT_TILES, help="Number of vertical tiles")
    ap.add_argument("--dpi", type=int, default=120, help="PDF render DPI (default: 120)")
    args = ap.parse_args()

    in_path = Path(args.input).expanduser().resolve()
    if not in_path.exists():
        print(f"ERROR: input not found: {in_path}", file=sys.stderr)
        sys.exit(1)

    out_dir = args.out_dir or tempfile.mkdtemp(prefix="vision_in_")

    suffix = in_path.suffix.lower()
    if suffix == ".pdf":
        with tempfile.TemporaryDirectory() as tmp:
            png_pages = render_pdf_to_png(str(in_path), tmp, dpi=args.dpi)
            all_tiles = []
            for png in png_pages:
                all_tiles.extend(tile_image(png, out_dir, num_tiles=args.tiles))
    elif suffix in {".png", ".jpg", ".jpeg", ".webp", ".tiff", ".bmp"}:
        all_tiles = tile_image(str(in_path), out_dir, num_tiles=args.tiles)
    else:
        print(f"ERROR: unsupported input type: {suffix}", file=sys.stderr)
        sys.exit(1)

    print(f"OUT_DIR: {out_dir}")
    print(f"TILES: {len(all_tiles)}")
    for t in all_tiles:
        size_kb = os.path.getsize(t) // 1024
        print(f"  {t}  ({size_kb} KB)")


if __name__ == "__main__":
    main()
