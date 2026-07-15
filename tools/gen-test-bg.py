#!/usr/bin/env python3
"""Regenerate test/bg_input.inc: a 512x160 multi-palette scrolling test field.

Pure geometry: 16 vertical hue bands, each running 12 brightness steps down
the screen (192 distinct colors -- far past one 15-color palette), with a
checkered top row for scroll visibility. Baked through the asset pipeline's
real bg-bake multi-palette path, so the committed background is a standing
exercise of bank clustering, cross-bank tile dedup, and the 64-tile-wide
map layout. The .inc is committed; rerun this only when the pattern changes.

Usage (from the repo root):
    python tools/gen-test-bg.py
"""
import colorsys
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "assets"))

from PIL import Image                     # noqa: E402
from sprite_lib import bgbake             # noqa: E402

W, H = 512, 160
BANDS = 16
SHADES = 12


def band_color(band: int, shade: int) -> tuple[int, int, int]:
    hue = band / BANDS
    val = 0.35 + 0.60 * (shade / (SHADES - 1))
    r, g, b = colorsys.hsv_to_rgb(hue, 0.8, val)
    return int(r * 255), int(g * 255), int(b * 255)


def main() -> None:
    im = Image.new("RGB", (W, H))
    px = im.load()
    for ty in range(H // 8):
        for tx in range(W // 8):
            band = tx // (W // 8 // BANDS)
            if ty == 0:
                # checkered top row: two shades of the band's own hue
                for y in range(8):
                    for x in range(8):
                        shade = 2 if ((x // 2 + y // 2) % 2) == 0 else 9
                        px[tx * 8 + x, ty * 8 + y] = band_color(band, shade)
            else:
                c = band_color(band, (ty - 1) % SHADES)
                for y in range(8):
                    for x in range(8):
                        px[tx * 8 + x, ty * 8 + y] = c
    src = ROOT / "test" / "bg_input_src.png"
    im.save(src)
    rec = bgbake.bake_bg(src, ROOT / "test" / "bg_input.inc", "BGDEMO",
                         palettes=16, preview=False)
    src.unlink()                           # the source is scratch; the .inc ships
    if rec["tiles_degraded"]:
        sys.exit(f"unexpected degraded tiles: {rec['tiles_degraded']}")
    print(f"bg_input.inc: {rec['map'][0]}x{rec['map'][1]} map, "
          f"{rec['tiles_unique']} tiles, {rec['palettes']} banks, "
          f"{rec['colors_used']} colors")


if __name__ == "__main__":
    main()
