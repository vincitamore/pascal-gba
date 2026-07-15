"""Bake-source fixture: magenta bg + centered solid subject block."""
from __future__ import annotations

from PIL import Image

MAGENTA = (255, 0, 255)
SUBJECT = (255, 0, 0)
MARKER = (0, 255, 0)
SIZE = 64
BLOCK = 24
MARKER_N = 4


def gen_bake_source(path=None):
    """64x64 RGB: solid magenta bg, centered 24x24 red block, 4x4 green corner.

    Corners stay pure magenta so bg_detect corner/auto both succeed.
    Returns PIL Image; if path is given, saves PNG there and returns the path.
    """
    im = Image.new("RGB", (SIZE, SIZE), MAGENTA)
    x0 = (SIZE - BLOCK) // 2
    y0 = (SIZE - BLOCK) // 2
    for y in range(y0, y0 + BLOCK):
        for x in range(x0, x0 + BLOCK):
            im.putpixel((x, y), SUBJECT)
    # top-left of the subject block: known second color for palette asserts
    for y in range(y0, y0 + MARKER_N):
        for x in range(x0, x0 + MARKER_N):
            im.putpixel((x, y), MARKER)
    if path is not None:
        im.save(path)
        return path
    return im


def magenta_pixel_count() -> int:
    """Exact bg pixel count for a full-frame rekey against this fixture."""
    total = SIZE * SIZE
    fg = BLOCK * BLOCK
    return total - fg


def subject_center() -> tuple[int, int]:
    """Pixel inside the solid red block (not the green marker)."""
    return (SIZE // 2 + 4, SIZE // 2 + 4)
