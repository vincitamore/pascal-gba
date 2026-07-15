"""Nine-slice fixture: 24x24 = 3x3 of 8x8 flat-color cells."""
from __future__ import annotations

from PIL import Image

# Distinct flat colors per cell, row-major TL..BR.
NINE_SLICE_COLORS = [
    (220, 40, 40),   # TL
    (40, 220, 40),   # T
    (40, 40, 220),   # TR
    (220, 220, 40),  # L
    (40, 220, 220),  # C
    (220, 40, 220),  # R
    (180, 100, 40),  # BL
    (100, 40, 180),  # B
    (40, 180, 100),  # BR
]
CELL = 8
GRID = 3


def gen_nine_slice_source(path=None):
    """24x24 image, each 8x8 cell a distinct flat RGB. Saves if path given."""
    im = Image.new("RGB", (CELL * GRID, CELL * GRID))
    for row in range(GRID):
        for col in range(GRID):
            c = NINE_SLICE_COLORS[row * GRID + col]
            for y in range(CELL):
                for x in range(CELL):
                    im.putpixel((col * CELL + x, row * CELL + y), c)
    if path is not None:
        im.save(path)
        return path
    return im
